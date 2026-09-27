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

/// Routes attachVanguardToLiveKitTrack / detachVanguard / getStats.
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

/// Number of frames forwarded to WebRTC since the current attach.
@property (nonatomic, readonly) uint64_t framesDelivered;

/// Whether frames are currently being forwarded to WebRTC.
@property (nonatomic, readonly) BOOL isStreaming;

@end

NS_ASSUME_NONNULL_END
