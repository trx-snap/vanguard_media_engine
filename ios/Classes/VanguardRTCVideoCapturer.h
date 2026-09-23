// VanguardRTCVideoCapturer.h
// Vanguard Media Engine -> LiveKit LiveStreaming Egress Bridge
// Isolated Proof of Concept

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

/// Egress video capturer that bridges Vanguard Metal-processed camera frames
/// directly into WebRTC (used by LiveKit) as a zero-copy hardware pipeline.
@interface VanguardRTCVideoCapturer : NSObject <FlutterPlugin>

+ (instancetype)sharedInstance;

/// Registers the MethodChannel 'vanguard_livekit_bridge' with Flutter.
+ (void)setupMethodChannelWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

/// Delivers a processed frame (post-beauty, post-filter) from Vanguard to WebRTC.
+ (void)deliverFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts;

/// Attaches Vanguard to an existing WebRTC local track ID.
- (BOOL)attachToTrackId:(NSString *)trackId error:(NSError * _Nullable * _Nullable)error;

/// Detaches Vanguard and stops frame egress.
- (void)detach;

/// Number of frames successfully delivered to WebRTC since attach.
@property (nonatomic, readonly) uint64_t framesDelivered;

/// Whether frames are currently being forwarded to WebRTC.
@property (nonatomic, readonly) BOOL isStreaming;

@end

NS_ASSUME_NONNULL_END
