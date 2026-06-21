// VanguardCameraMediaSource.h
// Phase 3 / Phase 6E.1C: Camera source implementing VanguardMediaSource protocol.
// Preview: AVCaptureVideoDataOutput → CVPixelBuffer → videoCallback → MTKView
// (Metal) Recording: AVAssetWriter (internal H.264) +
// AVAssetWriterInputPixelBufferAdaptor Audio: AVCaptureAudioDataOutput added at
// session config (not deferred to record start) Clock: AVCaptureSession
// hardware CMClock — both A/V tracks hardware-synchronized

#import "VanguardMediaSource.h"
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration — full definition is at bottom of this header.
@protocol VanguardCameraFrameReceiver;

@interface VanguardCameraMediaSource : NSObject <VanguardMediaSource>

/// Designated initialiser. Does NOT start the session.
/// Position: AVCaptureDevicePositionBack or Front.
/// fps: target frame rate (30 or 60). Session preset always 1920×1080.
- (instancetype)initWithPosition:(AVCaptureDevicePosition)position
                       frameRate:(int)fps NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// ── VanguardMediaSource (preview path) ───────────────────────────────────────
// start / stop / seekTo: / setVideoCallback: / setAudioCallback:
// are implemented from the protocol. seekTo: is a deliberate no-op (live
// source).

// ── Recording lifecycle
// ───────────────────────────────────────────────────────

/// Adds AVAssetWriter for video+audio and begins writing.
/// Must be called after start. Calls completion on main thread.
- (void)startRecordingToURL:(NSURL *)url
                 completion:(void (^)(NSError *_Nullable error))completion;

/// Finalises the AVAssetWriter asynchronously.
/// Calls completion on main thread with the output URL and recording stats.
- (void)stopRecordingWithCompletion:
    (void (^)(NSURL *_Nullable url, NSUInteger droppedFrames,
              NSUInteger totalFrames, NSError *_Nullable error))completion;

/// Synchronously finalises any active recording.
/// Blocks the calling thread until AVAssetWriter
/// finishWritingWithCompletionHandler: fires. MUST NOT be called from
/// _captureQueue — will deadlock. Safe to call when not recording (immediate
/// no-op). teardownCurrentMode calls this before transitioning to .editor or
/// .export to ensure the shared H.264 hardware encoder slot is released before
/// AVAssetReader claims it.
- (void)stopRecordingAndWait;

// ── Session access for PlatformView ──────────────────────────────────────────

/// The underlying AVCaptureSession — PlatformView uses this for connection.
/// VanguardCameraMediaSource owns and configures the session exclusively.
@property(nonatomic, readonly) AVCaptureSession *captureSession;

// ── MTKView integration
// ───────────────────────────────────────────────────────

/// Weak reference to the platform view's MTKView-based renderer.
/// Set by the plugin after the PlatformView is created.
/// VanguardCameraMediaSource calls onFrame:pts: on this object each capture
/// frame.
@property(nonatomic, weak, nullable) id<VanguardCameraFrameReceiver>
    frameReceiver;

// ── POC2: Raw forwarding gate
// ───────────────────────────────────────────────── When YES (default), the
// POC1 raw direct delivery path in captureOutput: is active: each camera frame
// is forwarded to frameReceiver.onFrame:pts: directly (pre-graph, raw pixel
// data).
//
// When NO, the raw forwarding block is skipped. Set to NO by
// VGCameraGraphSession.connectPlatformViewReceiver: when the two-child
// VGFanOutSink is installed, so the MTKView PlatformView receives only
// graph-processed frames and not a second raw copy.
//
// Thread-safe: atomic property; written once from _sessionQueue, read from
// _captureQueue (both serial — no races for a single BOOL).
//
// POC2 ONLY — Remove before Phase 7 / production.
@property(atomic, assign) BOOL platformViewRawForwardingEnabled;

// ── Phase 6E.1C: Graph-backed recording gate
// ─────────────────────────────────────────────
//
// When YES, VGRecordingSinkNode forwards processed graph frames to the writer
// via appendProcessedVideoFrame:pts:. Defaults to NO — raw recording path
// remains the sole active write path.
//
// Phase 6E.1D will set this to YES at startRecording time and gate the raw
// append path behind !graphRecordingEnabled.
//
// Thread-safe: atomic BOOL; written once at session start, read on the graph
// execution queue (com.vanguard.cameraGraphExecution).
@property(atomic, assign) BOOL graphRecordingEnabled;

// ── Recording state
// ───────────────────────────────────────────────────────────

/// YES while AVAssetWriter is active. Used by the plugin to guard switchCamera
/// against being called during an active recording (would corrupt the output
/// file).
@property(nonatomic, readonly) BOOL isRecording;

/// YES after the first video frame has been delivered by AVFoundation.
///
/// Thread-safe: reads _latestBuffer under _latestBufferLock (nanosecond hold).
/// Use this to gate the Record button — recording should not be started before
/// the camera is producing frames.
///
/// Resets to NO after stop is called. A fresh session always starts as NO.
@property(nonatomic, readonly) BOOL isCameraReady;

/// YES when AVAssetWriter has started its writing session and is actively
/// receiving video frames.
///
/// This is strictly stronger than isRecording:
///   isRecording  — YES as soon as startRecordingToURL: creates the writer
///   isRecordingActive — YES only after the first video frame is received and
///                       startSessionAtSourceTime: has been called
///
/// Uses compound check: _recordingState == Writing && _sessionStarted.
/// During Finishing, _sessionStarted may still be YES — the compound check
/// prevents a stale-true result during teardown.
///
/// Thread-safe for point-in-time snapshots: _recordingState (NSInteger) and
/// _sessionStarted (BOOL) are each atomic reads on ARM64.
@property(nonatomic, readonly) BOOL isRecordingActive;

// ── Device Controls (Phase 2)
// ─────────────────────────────────────────────────

/// Sets camera zoom. factor=1.0=no zoom. Clamped to
/// activeFormat.videoMaxZoomFactor.
- (void)setZoom:(CGFloat)factor;

/// Returns a dictionary of zoom capability values from the active AVCaptureDevice.
///
/// Returns nil if no device is currently active (_captureDevice is nil).
///
/// Keys:
///   minZoomFactor                     — minAvailableVideoZoomFactor (iOS 11+; 1.0 fallback)
///   maxZoomFactor                     — RECOMMENDED quality-safe maximum for pinch-zoom clamping.
///                                       Front camera: min(2.0, technicalMaxZoomFactor)
///                                       Back camera:  min(upscaleThreshold × 2.5, 10.0)
///                                       Both: clamped to technicalMaxZoomFactor.
///   technicalMaxZoomFactor            — maxAvailableVideoZoomFactor (iOS 11+; videoMaxZoomFactor fallback)
///                                       The absolute ceiling — may be 150× or higher. Do NOT use
///                                       as UI zoom limit.
///   upscaleThresholdZoomFactor        — activeFormat.videoZoomFactorUpscaleThreshold (iOS 11+; technicalMax fallback)
///                                       Zoom factors above this threshold produce digitally upscaled output.
///   defaultZoomFactor                 — always 1.0 in the wide-angle-first phase
///   displayZoomFactorMultiplier       — displayVideoZoomFactorMultiplier (iOS 18+; 1.0 fallback)
///   virtualDeviceSwitchOverZoomFactors — virtualDeviceSwitchOverVideoZoomFactors (iOS 13+; [] fallback)
///   isVirtualDevice                   — YES if the device is a virtual multi-camera device (iOS 13+; NO fallback)
///   cameraPosition                    — @"front" | @"back" | @"unknown"
///
/// Wide-angle-first: virtual multi-camera discovery is deferred. On the current
/// wide-angle-only binding, virtualDeviceSwitchOverZoomFactors is always empty
/// and isVirtualDevice is always NO.
- (nullable NSDictionary *)zoomCapabilities;


/// Tap-to-focus + tap-to-expose at normalised point (0.0–1.0, 0.0–1.0),
/// AVFoundation coordinate space: x left→right, y top→bottom.
/// Renamed applyFocusPoint: (not setFocusPoint:) to avoid the Swift ObjC-bridge
/// stripping the 'set' prefix and colliding with focusPoint property patterns.
- (void)applyFocusPoint:(CGPoint)point;

/// Continuous video torch. mode: @"on" | @"off".
/// No-op if device has no torch (front camera, simulator).
- (void)setTorchMode:(NSString *)mode;

// ── Camera Switching (Phase 3)
// ────────────────────────────────────────────────

/// Swaps sensor without session teardown (~150 ms). Texture id is unchanged.
/// MUST NOT be called while isRecording is YES.
/// Renamed moveCameraToPosition: (not switchToPosition:) to avoid the Swift
/// ObjC-bridge translating 'switch' to a reserved keyword.
- (void)moveCameraToPosition:(AVCaptureDevicePosition)position;

// ── Phase 6C: Preview orientation lock ──────────────────────────────────────

/// Forces AVCaptureConnection.videoOrientation = portrait for the duration of
/// native camera preview. Suppresses orientation-change updates that would flip
/// buffer dimensions. moveCameraToPosition: re-applies the lock automatically
/// if called while the lock is active.
///
/// Typical caller: VGNativeCameraViewController at openNativeCamera time.
/// Paired with unlockPreviewOrientation on VC dismissal.
- (void)lockPreviewOrientationToPortrait;

/// Removes the portrait orientation lock and restores normal
/// _applyConnectionOrientationContract behaviour.
- (void)unlockPreviewOrientation;

// ── Photo Capture (Phase 4) ──────────────────────────────────────────────────

/// Captures the current live frame as a JPEG and writes it atomically to url.
/// Must be called after start; safe to call while a video recording is active.
///
/// completion is always called on the main thread with exactly one of:
///   url non-nil, error nil    — success; file is complete and readable
///   url nil,     error non-nil — failure; no file was written
///
/// Error codes (domain "VanguardCamera"):
///   1  NO_FRAME   — no frame delivered yet (startup window ~100ms)
///   2  ENCODE_FAIL — CIContext JPEG encoding returned nil
///   3  SWITCHING  — moveCameraToPosition: reconfiguration in progress
- (void)takePhotoToURL:(NSURL *)url
            completion:
                (void (^)(NSURL *_Nullable, NSError *_Nullable))completion;

// ── Phase 6E.1C: Processed-frame append entry point ─────────────────────────

/// Appends a processed (effects-applied) video frame to the active AVAssetWriter.
///
/// Called by VGRecordingSinkNode.presentEnvelope: on the graph execution queue
/// (com.vanguard.cameraGraphExecution). Internally dispatches to _captureQueue
/// to share the existing recording state machine, backpressure accounting,
/// and AVAssetWriter access.
///
/// No-op when:
///   - graphRecordingEnabled is NO (default in Phase 6E.1C)
///   - _recordingState != VanguardRecordingStateWriting
///   - pixelBuffer is NULL
///
/// Buffer ownership: caller passes +0. This method retains the buffer
/// across the async dispatch to _captureQueue and releases after append.
///
/// Phase 6E.1C: graphRecordingEnabled defaults to NO. No current code sets
/// it to YES — this method is unreachable at runtime in this phase.
/// Phase 6E.1D will enable graph recording and gate the raw append path.
///
/// @param pixelBuffer The processed CVPixelBuffer from graph output.
/// @param pts         Presentation timestamp from the original VGFrameEnvelope.
- (void)appendProcessedVideoFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts;

@end

// ── Frame receiver protocol (implemented by VanguardCameraPlatformView)
// ───────

@protocol VanguardCameraFrameReceiver <NSObject>
/// Called on _captureQueue with every video frame.
/// Implementation must be fast (< 0.5ms) — runs on capture queue.
- (void)onFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts;
/// Adjusts MTKView preferredFramesPerSecond (jitter-triggered throttle).
/// Called from _captureQueue — implementation dispatches to main thread
/// internally.
- (void)setPreviewFPS:(NSInteger)fps;
@end

NS_ASSUME_NONNULL_END
