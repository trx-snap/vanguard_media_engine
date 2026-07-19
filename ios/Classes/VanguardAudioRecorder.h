// VanguardAudioRecorder.h
// Vanguard Media Engine — Audio Slice M
//
// Minimal microphone capture helper backed by AVAudioRecorder.
//
// VISIBILITY: Package-internal only. Do NOT add to public_header_files.
// Do NOT import from VanguardGraphRuntime.h.
//
// Responsibility:
//   - Owns AVAudioRecorder lifecycle (via VGAudioRecorderBackend seam).
//   - Owns AVAudioSession minimal category switch:
//       start → PlayAndRecord (with MixWithOthers option)
//       stop / cancel / error → restore Playback
//   - Reads VGTimelineStateSnapshot from the supplied runtime to compute
//     the authoritative start PTS atomically at record time.
//   - Exposes the current AVAudioSession route to the caller for UX gating
//     (headphone detection — policy is the caller's responsibility).
//
// Explicit deferrals (Slices N/O):
//   - No route-change notification handling.
//   - No AVAudioSession interruption handling.
//   - No background-audio hardening.
//
// Mockable seams for unit tests:
//   - VGAudioRecorderTimeProvider  — injectable for CACurrentMediaTime().
//   - VGAudioRecorderSessionManager — injectable AVAudioSession abstraction.
//   - VGAudioRecorderBackend       — injectable recorder (avoids real AVAudioRecorder).
//   - VGAudioRecorderBackendFactory — injectable builder for the backend.
//   All seams default to real implementations; override in tests only.
//
// Threading:
//   All public methods must be called on the main thread.
//   Completion callbacks fire on the main thread.

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Forward-declare the concrete runtime type. The .m file imports
// VGTimelineStateSnapshot.h to access readTimelineStateSnapshot; this header
// only needs the class name so Swift can pass _timelineRuntime safely.
@class VanguardGraphRuntime;

NS_ASSUME_NONNULL_BEGIN

// ─── Mockable seam protocols ──────────────────────────────────────────────────

/// Returns the current host wall-clock time in seconds.
/// Production: wraps CACurrentMediaTime(). Inject a stub in tests.
@protocol VGAudioRecorderTimeProvider <NSObject>
- (NSTimeInterval)currentTime;
@end

/// Wraps AVAudioSession category management for testability.
@protocol VGAudioRecorderSessionManager <NSObject>
/// Switches the shared AVAudioSession to PlayAndRecord (with MixWithOthers).
/// Returns YES on success; on failure sets *error.
- (BOOL)activatePlayAndRecordWithError:(NSError * _Nullable * _Nullable)error;
/// Restores the shared AVAudioSession to Playback.
/// Idempotent; best-effort on failure.
- (void)restorePlayback;
/// Returns YES if a wired or Bluetooth headphone output is active.
- (BOOL)isHeadphonesConnected;
@end

/// Abstracts the recording back-end so tests can operate without a real
/// AVAudioRecorder (which requires a real audio session and microphone).
///
/// Production: backed by AVAudioRecorder.
/// Tests: backed by a simple stub that records method calls.
@protocol VGAudioRecorderBackend <NSObject>
/// Prepares the recorder. Returns YES on success.
- (BOOL)prepareToRecord;
/// Begins recording. Returns YES on success.
- (BOOL)record;
/// Stops recording and flushes output.
- (void)stop;
/// Returns YES while recording is in progress.
@property(nonatomic, readonly) BOOL isRecording;
/// The elapsed recording time in seconds.
@property(nonatomic, readonly) NSTimeInterval currentTime;
@end

/// Builds a VGAudioRecorderBackend for the given URL and settings.
/// Inject a stub in tests so no real microphone access is required.
@protocol VGAudioRecorderBackendFactory <NSObject>
/// Returns a new backend ready to record to |url| with |settings|,
/// or nil on failure. On failure sets *error.
- (nullable id<VGAudioRecorderBackend>)backendWithURL:(NSURL *)url
                                             settings:(NSDictionary<NSString *, id> *)settings
                                                error:(NSError * _Nullable * _Nullable)error;
@end

// ─── VGAudioRecordingStartInfo ────────────────────────────────────────────────

/// Returned from a successful startRecording call.
@interface VGAudioRecordingStartInfo : NSObject

/// Absolute path to the recording file (mirrors the supplied outputPath).
@property(nonatomic, readonly) NSString *filePath;

/// Authoritative timeline PTS at the moment recording began.
@property(nonatomic, readonly) double startPTS;

/// Whether headphones (wired or Bluetooth) were connected at start time.
@property(nonatomic, readonly) BOOL isHeadphonesConnected;

- (instancetype)initWithFilePath:(NSString *)filePath
                        startPTS:(double)startPTS
             isHeadphonesConnected:(BOOL)isHeadphonesConnected NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// ─── VGAudioRecordingStopInfo ─────────────────────────────────────────────────

/// Returned from a successful stopRecording call.
@interface VGAudioRecordingStopInfo : NSObject

/// Absolute path to the completed recording file.
@property(nonatomic, readonly) NSString *filePath;

/// The authoritative start PTS captured when recording began.
@property(nonatomic, readonly) double startPTS;

/// Duration of the recorded audio in seconds.
@property(nonatomic, readonly) double durationSeconds;

- (instancetype)initWithFilePath:(NSString *)filePath
                        startPTS:(double)startPTS
                 durationSeconds:(double)durationSeconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// ─── VanguardAudioRecorder ────────────────────────────────────────────────────

/// Minimal AVAudioRecorder-backed microphone capture helper.
///
/// One instance is held by VGAudioRecordingHandler during an active recording.
/// After stop or error it is discarded. All methods must be called on the main
/// thread.
@interface VanguardAudioRecorder : NSObject

/// Designated initialiser. All collaborator parameters are optional;
/// pass nil to use the production default implementations.
- (instancetype)initWithTimeProvider:(nullable id<VGAudioRecorderTimeProvider>)timeProvider
                      sessionManager:(nullable id<VGAudioRecorderSessionManager>)sessionManager
                      backendFactory:(nullable id<VGAudioRecorderBackendFactory>)backendFactory
    NS_DESIGNATED_INITIALIZER;

/// Convenience initialiser that uses all production defaults.
- (instancetype)init;

/// Starts recording to |outputPath|.
///
/// Reads VGTimelineStateSnapshot from |runtime| to compute the authoritative
/// startPTS:
///   - snapshot.isValid == NO  → fails with VGRecorderErrorInvalidSnapshot.
///   - snapshot.isPlaying      → startPTS = playStartPTS + max(0, now − playStartHostTime)
///   - paused                  → startPTS = timelinePTS
///
/// Switches AVAudioSession to PlayAndRecord + MixWithOthers on success.
/// On failure, always restores Playback before returning.
///
/// Fails with VGRecorderErrorAlreadyRecording if a recording is in progress.
///
/// |runtime| must not be nil and must not have been invalidated.
///
/// Returns a VGAudioRecordingStartInfo on success, nil + *error on failure.
- (nullable VGAudioRecordingStartInfo *)
    startRecordingWithRuntime:(VanguardGraphRuntime *)runtime
                   outputPath:(NSString *)outputPath
                        error:(NSError * _Nullable * _Nullable)outError;

/// Stops the active recording, finalises the file, and restores Playback.
///
/// |completion| is called on the main thread with the stop result on success
/// or a non-nil error on failure. Always restores AVAudioSession to Playback
/// whether or not an error occurs.
///
/// No-op (calls completion with an error) if no recording is active.
- (void)stopRecordingWithCompletion:
    (void (^)(VGAudioRecordingStopInfo * _Nullable info,
              NSError * _Nullable error))completion;

/// Cancels and discards the active recording without returning a result.
/// Restores AVAudioSession to Playback. Idempotent.
- (void)cancelRecording;

/// Whether a recording is currently in progress.
@property(nonatomic, readonly, getter=isRecording) BOOL recording;

@end

// ─── Error domain and codes ───────────────────────────────────────────────────

extern NSString * const VGRecorderErrorDomain;

typedef NS_ENUM(NSInteger, VGRecorderError) {
  VGRecorderErrorNoRuntime           = 1, ///< runtime argument was nil.
  VGRecorderErrorInvalidSnapshot     = 2, ///< snapshot.isValid == NO.
  VGRecorderErrorSessionActivation   = 3, ///< AVAudioSession activation failed.
  VGRecorderErrorRecorderInit        = 4, ///< backend init/prepare/record failed.
  VGRecorderErrorNotRecording        = 5, ///< stopRecording called with no active session.
  VGRecorderErrorBadOutputPath       = 6, ///< outputPath is nil or empty.
  VGRecorderErrorAlreadyRecording    = 7, ///< startRecording called while already recording.
};

NS_ASSUME_NONNULL_END
