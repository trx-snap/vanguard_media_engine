// VanguardMultiCamMediaSource.h
// vanguard_media_engine — MC-7/MC-8/MC-20: Production MultiCam media source.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-7/MC-8 — MULTICAM MEDIA SOURCE (LIFECYCLE DIAGNOSTIC + BUFFER LIFECYCLE)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Production AVCaptureMultiCamSession source that manages independent
// front/back camera delegates, software PTS pairing, and session lifecycle.
//
// ── MC-7 SCOPE ────────────────────────────────────────────────────────────────
//
//   MC-7 is a lifecycle diagnostic slice. The source is instantiated and
//   driven exclusively through the `runMultiCamSourceLifecycleDiagnostic`
//   plugin route. It is NOT wired to VGCameraGraphSession, NOT assigned an
//   engine mode, and does NOT render to any Flutter texture.
//
//   The primary proof is:
//     1. AVCaptureMultiCamSession can be fully configured, started, and
//        cleanly stopped within a standalone production object.
//     2. VanguardMultiCamFramePairer (MC-6) integrates correctly with a
//        real session delegate lifecycle.
//     3. Pairing metrics match MC-5 benchmarks (~85 paired frames, ~26 FPS,
//        ~20ms drift) through the production source.
//
// ── WHAT IT DOES ─────────────────────────────────────────────────────────────
//
//   Creates and manages an AVCaptureMultiCamSession with:
//     - Independent front/back AVCaptureVideoDataOutput delegates on a
//       shared serial captureQ (same proven pattern as MC-4/MC-5).
//     - PTS extraction from each callback via CMSampleBufferGetPresentationTimeStamp.
//     - PTS fed into VanguardMultiCamFramePairer for nearest-neighbour pairing.
//     - Peak systemPressureCost and hardwareCost tracking.
//     - Clean start/stop lifecycle with idempotent stop.
//
// ── WHAT IT DOES NOT DO ──────────────────────────────────────────────────────
//
//   Does NOT conform to <VanguardMediaSource> (deferred to MC-8+).
//     Rationale: <VanguardMediaSource> is a single-stream protocol (one
//     CVPixelBuffer callback, seekTo:, audio) that does not model paired
//     MultiCam output. Conformance would require dead stubs that the engine
//     never calls.
//
//   Does NOT retain CMSampleBuffer.
//     MC-8: retains at most one pending CVPixelBuffer per camera side
//     (front/back). Released on displacement, stop, and dealloc.
//
//   Does NOT create Flutter textures, Metal renderers, or compositors.
//
//   Does NOT modify VGCameraGraphSession, VanguardCameraMediaSource, or any
//     existing camera source.
//
//   Does NOT add VanguardEngineMode.multiCam.
//
// ── SESSION CONFIGURATION ─────────────────────────────────────────────────────
//
//   Uses addInputWithNoConnections: / addOutputWithNoConnections: for both
//   cameras, then creates manual AVCaptureConnections. This is required for
//   AVCaptureMultiCamSession (standard addInput: / addOutput: create implicit
//   connections that are not compatible with MultiCam).
//
// ── ORIENTATION / MIRRORING CONTRACT ─────────────────────────────────────────
//
//   Portrait-canonical: videoOrientation = AVCaptureVideoOrientationPortrait.
//   No landscape-follow behavior.
//   automaticallyAdjustsVideoMirroring = NO.
//   Front camera: videoMirrored = YES.
//   Back camera:  videoMirrored = NO.
//
// ── THREAD SAFETY ─────────────────────────────────────────────────────────────
//
//   start / stop must NOT be called on the main thread.
//   startRunning is synchronous and blocks for hardware initialization.
//   The plugin route dispatches to DispatchQueue.global(qos: .userInitiated).
//
//   Delegate callbacks fire on a dedicated serial captureQ.
//   All VanguardMultiCamFramePairer access is serialized by captureQ —
//   no locks required (same invariant as MC-5).
//
// ── AVAILABILITY ─────────────────────────────────────────────────────────────
//
//   iOS 13.0+ only. initWithFrontDeviceId:backDeviceId:frameRate: returns nil
//   on iOS < 13.0. The @interface bears NO API_AVAILABLE decorator so Swift in
//   the same CocoaPods target can see the class; the plugin route guards with
//   `if #available(iOS 13.0, *)` before instantiating (matching MC-5 pattern).
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//   // On a background queue:
//   VanguardMultiCamMediaSource *source =
//       [[VanguardMultiCamMediaSource alloc] initWithFrontDeviceId:frontId
//                                                     backDeviceId:backId
//                                                        frameRate:30];
//   if (!source) { /* device not found, not authorized, etc. */ }
//
//   if (![source start]) { /* session failed to start */ }
//   [NSThread sleepForTimeInterval:3.0];
//   [source stop];
//
//   NSDictionary *m = [source metrics];
//   // m[@"pairedFramesReceived"], m[@"pairedFPS"], m[@"maxDriftSeconds"] ...
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamSyncDiagnostic.*     VanguardCameraMediaSource.*
//   VGCameraGraphSession.*               VanguardMediaEnginePlugin.swift
//   VanguardMultiCamFramePairer.*        VanguardMediaSource.h
//   connectsapp_*/**                     Android code
//   Phase 8 overlay files

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class VanguardMultiCamFramePairer;
@class VanguardMultiCamPairedFrame;
@class VanguardMultiCamMediaSource;

NS_ASSUME_NONNULL_BEGIN

// ─── VanguardMultiCamMediaSourceDelegate ─────────────────────────────────────

/// Delegate for receiving software-paired front/back pixel buffer frames.
///
/// Called synchronously on the source's internal serial captureQ.
/// Implementations MUST return quickly — no GPU work, no blocking I/O.
/// The paired frame is released (via ARC) after this method returns;
/// retain it if you need it beyond the callback scope.
@protocol VanguardMultiCamMediaSourceDelegate <NSObject>

/// Delivered when a front/back frame pair has formed within the pairing threshold.
///
/// @param source       The source that formed the pair.
/// @param pairedFrame  The paired frame holding both retained pixel buffers.
///                     The delegate does NOT own this object; it will be
///                     released by ARC after this method returns unless retained.
- (void)multiCamMediaSource:(VanguardMultiCamMediaSource *)source
       didOutputPairedFrame:(VanguardMultiCamPairedFrame *)pairedFrame;

@optional

/// MC-20: Delivered when an audio sample buffer arrives from the microphone.
///
/// Called synchronously on the source's internal serial captureQ.
/// Implementations MUST return quickly — no blocking I/O, no GPU work.
/// The sample buffer is valid only for the duration of this callback.
/// Implementations that need it beyond the callback MUST CFRetain it.
///
/// This method is @optional. Sources that do not need audio may ignore it.
/// The source only calls this method when a microphone input was successfully
/// configured (best-effort). No call is made when mic permission is denied
/// or when hardware setup fails.
///
/// @param source        The source delivering the audio.
/// @param sampleBuffer  The audio CMSampleBufferRef. The delegate does NOT own
///                      this buffer; it will be released by the session.
- (void)multiCamMediaSource:(VanguardMultiCamMediaSource *)source
  didOutputAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

// ─── VanguardMultiCamMediaSource ──────────────────────────────────────────────

/// Production MultiCam media source — manages an AVCaptureMultiCamSession
/// with independent front/back camera delegates and VanguardMultiCamFramePairer
/// software PTS pairing.
///
/// MC-7: lifecycle diagnostic. MC-8: adds paired-frame buffer delivery.
/// Not wired to VGCameraGraphSession.
///
/// ## Protocol conformance
/// Does NOT conform to `<VanguardMediaSource>`. That protocol models
/// a single-stream source (one CVPixelBuffer callback) and is unsuitable for
/// paired MultiCam output.
///
/// ## Buffer retention (MC-8)
/// Retains at most one pending `CVPixelBuffer` per camera side at a time.
/// Released on displacement, `stop`, or `dealloc`.
/// Does NOT retain `CMSampleBuffer`.
///
/// ## Thread safety
/// `start` / `stop` must be called from a background thread.
/// Delegate callbacks are serialized on an internal captureQ.
///
/// ## Availability
/// iOS 13.0+. `initWithFrontDeviceId:backDeviceId:frameRate:` returns nil on
/// iOS < 13.0. The @interface has no API_AVAILABLE attribute so that Swift in
/// the same CocoaPods target can reference the class directly (matching the
/// MC-5 pattern — iOS 13 guard lives entirely inside the .m implementation).
@interface VanguardMultiCamMediaSource : NSObject

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initializes the source with the given device IDs and frame rate.
///
/// Configures the AVCaptureMultiCamSession (inputs, outputs, connections,
/// orientation, mirroring) but does NOT start the session.
///
/// Returns nil if:
///   - iOS < 13.0
///   - AVCaptureMultiCamSession.isMultiCamSupported == NO
///   - Camera authorization status != AVAuthorizationStatusAuthorized
///   - Front or back device not found by uniqueID
///   - Session configuration fails (canAddInput / canAddOutput / canAddConnection)
///
/// @param frontId  The uniqueID of the front-facing AVCaptureDevice.
/// @param backId   The uniqueID of the back-facing AVCaptureDevice.
/// @param fps      Target frame rate hint (30). Session uses automatic preset.
- (nullable instancetype)initWithFrontDeviceId:(NSString *)frontId
                                  backDeviceId:(NSString *)backId
                                     frameRate:(int)fps
    NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithFrontDeviceId:backDeviceId:frameRate:.
- (instancetype)init NS_UNAVAILABLE;

// ─── Lifecycle ────────────────────────────────────────────────────────────────

/// Starts the AVCaptureMultiCamSession.
///
/// Synchronous — blocks until hardware initializes (typically 50–200ms).
/// Must NOT be called on the main thread.
/// Must NOT be called if the session is already running.
///
/// @return YES if the session started successfully (session.isRunning == YES),
///         NO otherwise.
- (BOOL)start;

/// Stops the AVCaptureMultiCamSession and tears down delegate references.
///
/// Idempotent: safe to call multiple times.
/// After this returns:
///   - session.isRunning == NO
///   - Both output delegates are nil
///   - pairer.flushPendingUnmatched has been called exactly once
///   - durationSeconds is finalized
///
/// May be called from any thread.
- (void)stop;

// ─── Metrics ──────────────────────────────────────────────────────────────────

/// Returns a snapshot of all pairing and session metrics.
///
/// Combines VanguardMultiCamFramePairer.metrics with session-level metrics.
///
/// Dictionary keys (all NSNumber) — matches VGMultiCamSyncReport native shape:
///   @"pairedFramesReceived"    — int32_t:  pairs formed within threshold
///   @"frontFramesReceived"     — int32_t:  total front frames delivered
///   @"backFramesReceived"      — int32_t:  total back frames delivered
///   @"unmatchedFrontFrames"    — int32_t:  front frames without a partner
///   @"unmatchedBackFrames"     — int32_t:  back frames without a partner
///   @"maxDriftSeconds"         — double:   peak |frontPTS − backPTS| in seconds
///   @"averageDriftSeconds"     — double:   mean |frontPTS − backPTS| in seconds
///   @"pairingThresholdSeconds" — double:   threshold used for pairing (1/30 s)
///   @"peakSystemPressureCost"  — double:   peak systemPressureCost while running
///   @"hardwareCost"            — double:   ISP bandwidth cost after configuration
///   @"durationSeconds"         — double:   elapsed time from start to stop
///
/// Safe to call before stop (returns current counters) or after stop (final).
- (NSDictionary<NSString *, NSNumber *> *)metrics;

// ─── Delegate ─────────────────────────────────────────────────────────────────

/// Delegate to receive paired-frame callbacks.
///
/// The delegate is held weakly to avoid retain cycles.
/// Callbacks fire synchronously on the internal serial captureQ.
/// Delegate methods must return quickly — no GPU work, no blocking I/O.
@property (nonatomic, weak, nullable) id<VanguardMultiCamMediaSourceDelegate> delegate;

// ─── Pairer access ────────────────────────────────────────────────────────────

/// The internal frame pairer. Readonly access for inspection.
///
/// All mutations to this object happen on the internal captureQ — callers
/// reading metrics from a different thread should use the `metrics` snapshot
/// method instead of accessing pairer properties directly.
@property (nonatomic, strong, readonly) VanguardMultiCamFramePairer *pairer;

@end

NS_ASSUME_NONNULL_END
