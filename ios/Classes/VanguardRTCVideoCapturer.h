// VanguardRTCVideoCapturer.h
// Vanguard Media Engine -> LiveKit LiveStreaming Egress Bridge (iOS)

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Flutter/Flutter.h>
#import "VanguardCameraMediaSource.h"  // VanguardCameraFrameReceiver

@class VGCameraGraphSession;

NS_ASSUME_NONNULL_BEGIN

/// Looks up the plugin's *current* camera graph session at call time; returns
/// nil when no camera graph is running.
typedef VGCameraGraphSession * _Nullable (^VGRTCGraphSessionProvider)(void);

/// Egress receiver that forwards Vanguard graph-processed camera frames
/// (post beauty/filter, portrait, the same frames the preview shows) into the
/// WebRTC RTCVideoSource behind a LiveKit LocalVideoTrack.
///
/// Ownership: VanguardMediaEnginePlugin owns the "vanguard_livekit_bridge"
/// MethodChannel and forwards calls here together with the active camera
/// graph session. This class registers nothing itself and never swizzles.
///
/// Frame path: VGCameraGraphSession fan-out → onFrame:pts: (graph execution
/// queue) → RTCCVPixelBuffer/RTCVideoFrame (rotation 0) → RTCVideoSource.
/// Frames are forwarded only while the egress gate is open, which happens
/// after the stock LiveKit capturer has stopped (or 1 s has elapsed).
@interface VanguardRTCVideoCapturer : NSObject <VanguardCameraFrameReceiver>

+ (instancetype)sharedInstance;

/// Installs the provider used to resolve the plugin's current
/// VGCameraGraphSession when a call arrives. Set once at plugin registration.
/// The graph session is pulled lazily so attach always binds to the session
/// that is live at call time, not the one that existed at registration.
- (void)setGraphSessionProvider:(nullable VGRTCGraphSessionProvider)provider;

/// Routes attachVanguardToLiveKitTrack / detachVanguard / getStats, (I1)
/// setMediaSource ({mode: "camera" | "image", imagePath}) and (I2)
/// setInitialMediaSource (same shape). setMediaSource is forwarded to the live
/// VGCameraGraphSession while the camera graph is the producer; while the
/// standalone image-first pump is the producer it is handled here (image hot
/// swap, or the hand-over to a camera graph the app created meanwhile).
/// setInitialMediaSource arms what the NEXT virtual track starts from: image is
/// validated and decoded (VGCreateLivestreamImageBuffer) before the reply so
/// Dart can abort before any track exists; camera clears the armed state. The
/// RTC sink/track is never touched by any of these.
/// Replies exactly once, possibly asynchronously. Main thread.
/// `result` is a real FlutterResult block (never a bit-cast object).
- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result NS_SWIFT_NAME(handle(_:result:));

/// Must be called immediately before `[session invalidate]`. Closes egress
/// if it is bound to that session (or to none); never rebuilds the graph.
- (void)detachForGraphSessionTeardown:(nullable VGCameraGraphSession *)session
    NS_SWIFT_NAME(detach(forGraphSessionTeardown:));

/// Closes the egress gate and drops the WebRTC source/track references.
/// Idempotent. Never rebuilds the graph and never restarts the stock capturer.
- (void)detach;

// ── Virtual camera provider (Option C, local flutter_webrtc fork) ────────────
//
// With the fork's external video source SPI, a LiveKit createCameraTrack with
// deviceId "vanguard_virtual_camera" gets a track fed only by this capturer:
// flutter_webrtc opens no camera and calls the three provider methods below.
// The same gate/receiver path as the attach flow carries the frames, minus the
// stock-capturer stop.

/// Registers this capturer with flutter_webrtc's external video source SPI
/// for deviceId "vanguard_virtual_camera", by name through the ObjC runtime
/// (this pod has no flutter_webrtc dependency). Returns NO and logs when the
/// app's flutter_webrtc has no SPI; the attach flow still works then.
- (BOOL)registerAsVirtualCameraProvider;

/// Removes the registration made by -registerAsVirtualCameraProvider, if any.
- (void)unregisterAsVirtualCameraProvider;

/// FlutterWebRTCExternalVideoSourceProvider: 720×1280 @ 30.
- (NSDictionary<NSString *, NSNumber *> *)externalVideoSourceOutputFormat;

/// FlutterWebRTCExternalVideoSourceProvider. Main thread. Binds egress to
/// @c sink (the track's RTCVideoCapturerDelegate) and opens the gate at once;
/// NO when there is no active camera graph or the receiver cannot connect.
/// I2: when an image start was armed by setInitialMediaSource, no camera graph
/// is required — a standalone 30 fps pump repeating the decoded still feeds
/// @c sink directly and the camera hardware stays closed until the app
/// creates a camera and requests setMediaSource(camera).
- (BOOL)startExternalVideoSourceForTrackId:(NSString *)trackId sink:(id)sink;

/// FlutterWebRTCExternalVideoSourceProvider. Main thread. Detaches egress if
/// it is still bound to @c trackId; otherwise a no-op.
- (void)stopExternalVideoSourceForTrackId:(NSString *)trackId;

/// Number of frames forwarded to WebRTC since the current attach.
@property (nonatomic, readonly) uint64_t framesDelivered;

/// Whether frames are currently being forwarded to WebRTC.
@property (nonatomic, readonly) BOOL isStreaming;

@end

NS_ASSUME_NONNULL_END
