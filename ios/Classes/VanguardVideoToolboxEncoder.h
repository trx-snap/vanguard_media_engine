// VanguardVideoToolboxEncoder.h
// Phase 4: iOS Hardware H.264 Encoder via VideoToolbox
//
// Accepts raw CVPixelBuffer frames from the Metal compositor and encodes
// them directly on the Apple Neural Engine / VideoToolbox hardware.
// No libx264. No CPU re-compression. Just the silicon Apple built into the SoC.

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VanguardEncodedPacketHandler)(NSData* _Nullable nalData,
                                              CMTime pts,
                                              BOOL isKeyFrame,
                                              NSError* _Nullable error);

@interface VanguardVideoToolboxEncoder : NSObject

@property(nonatomic, readonly) BOOL isReady;

/// Initialise the hardware encoder.
/// @param width   Frame width in pixels (e.g. 1080)
/// @param height  Frame height in pixels (e.g. 1920)
/// @param bitrate Target average bitrate in bits/second (e.g. 1_200_000 for 1.2Mbps)
/// @param fps     Frame rate (e.g. 30)
/// @param handler Called for each encoded NAL unit — use it to feed the muxer
- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      bitrate:(int)bitrate
                          fps:(int)fps
               packetHandler:(VanguardEncodedPacketHandler)handler;

/// Submit a decoded frame (from AVAssetReader or Metal render pass) for encoding.
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer presentationTime:(CMTime)pts;

/// Finalise and flush the encoder. Call before releasing.
- (void)finish;

/// Release VideoToolbox resources.
- (void)invalidate;

/// G-04: Update the encoder's target bitrate at runtime (thermal degradation).
/// Uses VTSessionSetProperty — takes effect on the next encode call.
/// @param kbps  New target bitrate in kilobits/second (e.g. 4000 = 4Mbps).
- (void)setBitrateKbps:(int)kbps;

/// P3-T3: Pre-warms the VTCompressionSession without submitting any frames.
/// Call at startCamera so the hardware encoder is ready before the user taps Record.
/// Idempotent. The first 5 real encode calls are discarded automatically.
- (void)prewarm;

/// Internal: called by the VTCompressionOutputCallback C function.
/// Must be visible to ARC for the __bridge cast to work correctly.
- (void)_handleEncodedSample:(CMSampleBufferRef)sampleBuffer;

/// P5-C: Monotonic count of frames that completed VTCompressionOutputCallback.
/// This is the ground truth for encoder flush completeness.
/// Atomically readable from any thread.
@property(atomic, readonly) int64_t vtCallbackCount;

/// P5-C: Reset the vtCallbackCount to zero before starting a flush-completeness test.
/// Call before startRecording to get a per-session count.
- (void)resetCallbackCount;

@end

NS_ASSUME_NONNULL_END
