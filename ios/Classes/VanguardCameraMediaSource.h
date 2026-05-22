// VanguardCameraMediaSource.h
// Phase 3: Camera source implementing VanguardMediaSource protocol.
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

// ── POC2: Raw forwarding gate ─────────────────────────────────────────────────
// When YES (default), the POC1 raw direct delivery path in captureOutput: is
// active: each camera frame is forwarded to frameReceiver.onFrame:pts: directly
// (pre-graph, raw pixel data).
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

// ── Recording state
// ───────────────────────────────────────────────────────────

/// YES while AVAssetWriter is active. Used by the plugin to guard switchCamera
/// against being called during an active recording (would corrupt the output
/// file).
@property(nonatomic, readonly) BOOL isRecording;

// ── Device Controls (Phase 2)
// ─────────────────────────────────────────────────

/// Sets camera zoom. factor=1.0=no zoom. Clamped to
/// activeFormat.videoMaxZoomFactor.
- (void)setZoom:(CGFloat)factor;

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
            completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion;

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
