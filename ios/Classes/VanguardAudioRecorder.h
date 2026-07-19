// VanguardAudioRecorder.h
// Vanguard Media Engine — Audio Slice N
//
// Minimal microphone capture helper backed by AVAudioRecorder.
//
// VISIBILITY: Module-visible (not in private_header_files).
// Do NOT add to public_header_files.
// Do NOT import from VanguardGraphRuntime.h.
//
// Responsibility (Slice N — capture only):
//   - Owns AVAudioRecorder lifecycle (via VGAudioRecorderBackend seam).
//   - Does NOT own or call AVAudioSession. The caller (VGAudioRecordingHandler)
//     activates PlayAndRecord before calling startRecording and restores Playback
//     after stopRecording, using VGAudioSessionTransitionCoordinator.
//   - Constructs the backend and calls prepareToRecord first.
//   - Only after prepare succeeds does it read VGTimelineStateSnapshot from the
//     supplied runtime and compute startPTS immediately before calling record.
//     This minimises the skew between the snapshot read and the first recorded
//     sample.
//   - Does NOT carry headphonesConnected. The handler derives that flag from
//     VGAudioRouteSnapshot.hasHeadphoneOutput and includes it in the result map.
//
// Explicit deferrals (Slices N/O):
//   - No AVAudioSession management (moved to VGAudioSessionTransitionCoordinator).
//   - No route-change notification handling.
//   - No AVAudioSession interruption handling.
//   - No background-audio hardening.
//
// Mockable seams for unit tests:
//   - VGAudioRecorderTimeProvider  — injectable for CACurrentMediaTime().
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
// only needs the class name so Swift can pass a runtime reference safely.
@class VanguardGraphRuntime;

NS_ASSUME_NONNULL_BEGIN

// ─── Mockable seam protocols ──────────────────────────────────────────────────

/// Returns the current host wall-clock time in seconds.
/// Production: wraps CACurrentMediaTime(). Inject a stub in tests.
@protocol VGAudioRecorderTimeProvider <NSObject>
- (NSTimeInterval)currentTime;
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
///
/// headphonesConnected is NOT carried here. The handler derives that flag from
/// VGAudioRouteSnapshot.hasHeadphoneOutput and includes it in the Flutter result.
@interface VGAudioRecordingStartInfo : NSObject

/// Absolute path to the recording file (mirrors the supplied outputPath).
@property(nonatomic, readonly) NSString *filePath;

/// Authoritative timeline PTS at the moment recording began.
/// Read from VGTimelineStateSnapshot immediately before record is called.
@property(nonatomic, readonly) double startPTS;

- (instancetype)initWithFilePath:(NSString *)filePath
                        startPTS:(double)startPTS NS_DESIGNATED_INITIALIZER;
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
///
/// Start sequence (enforced internally):
///   1. Construct backend (AVAudioRecorder init).
///   2. prepareToRecord — allocates file and hardware resources.
///   3. Read VGTimelineStateSnapshot → compute startPTS.
///   4. record — begins capture.
/// This order minimises the skew between the PTS read and first audio sample.
@interface VanguardAudioRecorder : NSObject

- (instancetype)initWithTimeProvider:(nullable id<VGAudioRecorderTimeProvider>)timeProvider
                      backendFactory:(nullable id<VGAudioRecorderBackendFactory>)backendFactory
    NS_DESIGNATED_INITIALIZER;

/// Convenience initialiser that uses all production defaults.
- (instancetype)init;

/// Starts recording to |outputPath|.
///
/// The caller is responsible for activating PlayAndRecord via
/// VGAudioSessionTransitionCoordinator BEFORE calling this method.
///
/// Internal sequence: backend init → prepareToRecord → snapshot read → record.
/// Snapshot is read immediately before record to minimise PTS skew.
///
///   snapshot.isValid == NO  → fails with VGRecorderErrorInvalidSnapshot.
///   snapshot.isPlaying      → startPTS = playStartPTS + max(0, now − playStartHostTime)
///   paused                  → startPTS = timelinePTS
///
/// Fails with VGRecorderErrorAlreadyRecording if a recording is in progress.
/// |runtime| must not be nil and must not have been invalidated.
///
/// Returns a VGAudioRecordingStartInfo on success, nil + *outError on failure.
- (nullable VGAudioRecordingStartInfo *)
    startRecordingWithRuntime:(VanguardGraphRuntime *)runtime
                   outputPath:(NSString *)outputPath
                        error:(NSError * _Nullable * _Nullable)outError;

/// Stops the active recording and finalises the file.
///
/// |completion| is called on the main thread with the stop result on success
/// or a non-nil error on failure.
///
/// The caller (VGAudioRecordingHandler) must call
/// coordinator.restorePlayback() after this method's completion fires.
///
/// No-op (calls completion with an error) if no recording is active.
- (void)stopRecordingWithCompletion:
    (void (^)(VGAudioRecordingStopInfo * _Nullable info,
              NSError * _Nullable error))completion;

/// Cancels and discards the active recording without returning a result.
/// Idempotent.
- (void)cancelRecording;

/// Whether a recording is currently in progress.
@property(nonatomic, readonly, getter=isRecording) BOOL recording;

@end

// ─── Error domain and codes ───────────────────────────────────────────────────

extern NSString * const VGRecorderErrorDomain;

typedef NS_ENUM(NSInteger, VGRecorderError) {
  VGRecorderErrorNoRuntime           = 1, ///< runtime argument was nil.
  VGRecorderErrorInvalidSnapshot     = 2, ///< snapshot.isValid == NO.
  VGRecorderErrorSessionActivation   = 3, ///< AVAudioSession activation failed (reserved).
  VGRecorderErrorRecorderInit        = 4, ///< backend init/prepare/record failed.
  VGRecorderErrorNotRecording        = 5, ///< stopRecording called with no active session.
  VGRecorderErrorBadOutputPath       = 6, ///< outputPath is nil or empty.
  VGRecorderErrorAlreadyRecording    = 7, ///< startRecording called while already recording.
};

NS_ASSUME_NONNULL_END
