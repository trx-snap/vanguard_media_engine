// VanguardAudioRecorder.h
// Vanguard Media Engine — Audio Slice N/O
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
//   - VGAudioRecorderDurationProbe — injectable finalized-file duration reader.
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

/// Probes the finalized encoded file for its true container duration after
/// the recorder backend has flushed and stopped.
///
/// Production: backed by AVURLAsset / CoreMedia.
/// Tests: backed by a synchronous stub that returns a controlled value.
///
/// Threading contract:
///   - |probeDurationOfFileAtURL:completion:| is called on the main thread.
///   - The probe may perform I/O on any queue internally.
///   - Conforming probes SHOULD invoke |completion| at most once; probes that
///     call back multiple times, call back late, or never call back are
///     tolerated — the recorder owns bounded, exactly-once terminal delivery.
///   - The production implementation always marshals |completion| to the main
///     thread. Injected probes SHOULD do the same; the recorder defensively
///     re-dispatches any off-main callback to the main queue before resolving.
///   - Callbacks that arrive after the recorder has already resolved the stop
///     (either via an earlier probe callback or via timeout) are ignored.
///
/// |completion| receives the encoded file duration in seconds, or a value
/// that is not (isfinite && > 0) to indicate probe failure.
@protocol VGAudioRecorderDurationProbe <NSObject>
- (void)probeDurationOfFileAtURL:(NSURL *)fileURL
                      completion:(void (^)(NSTimeInterval duration))completion;
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
/// Sourced from the finalized container file when the probe succeeds;
/// falls back to monotonic elapsed time otherwise.
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
///
/// Stop sequence:
///   1. [backend stop] — finalises the encoded file.
///   2. Active state cleared synchronously on the main thread.
///   3. Duration probe dispatches container read off-main; a bounded timeout
///      guards against indefinite quiescence delay.
///   4. Finalized-file duration is authoritative if finite and > 0.
///      Monotonic elapsed is the fallback only when probing fails or times out.
///   5. completion(info, nil) fires on the main thread exactly once.
@interface VanguardAudioRecorder : NSObject

/// Full test-injection initializer.
///
/// |timeProvider|     — nil → production CACurrentMediaTime() wrapper.
/// |backendFactory|   — nil → production AVAudioRecorder factory.
/// |durationProbe|    — nil → production AVURLAsset-backed probe.
/// |probeTimeoutSecs| — duration-probe watchdog in seconds.
///                      Replaced with the 2.0-second production default whenever
///                      the value is not (isfinite && > 0): NaN, ±infinity,
///                      zero, and negative values all select the default.
///
/// This is the designated initializer. All other initializers forward here.
- (instancetype)initWithTimeProvider:(nullable id<VGAudioRecorderTimeProvider>)timeProvider
                      backendFactory:(nullable id<VGAudioRecorderBackendFactory>)backendFactory
                       durationProbe:(nullable id<VGAudioRecorderDurationProbe>)durationProbe
                   probeTimeoutSecs:(NSTimeInterval)probeTimeoutSecs
    NS_DESIGNATED_INITIALIZER;

/// Initializer that accepts time-provider and backend-factory overrides.
/// Uses the production duration probe and a 2.0-second probe timeout.
/// All nil arguments default to their production implementations.
- (instancetype)initWithTimeProvider:(nullable id<VGAudioRecorderTimeProvider>)timeProvider
                      backendFactory:(nullable id<VGAudioRecorderBackendFactory>)backendFactory;

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
/// Idempotent. Does NOT trigger a duration probe.
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
