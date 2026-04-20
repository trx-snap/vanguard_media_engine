// VanguardImageProcessor.h
// Phase 2 — P2-T4: CGImage → CVPixelBuffer processing component
//
// Extracts the 30-line CGImage → CVPixelBuffer block that existed in both
// VanguardMetalRenderer.m and VanguardFileMediaSource.m into a single shared
// component. Zero allocation after warmup (pool-backed).
//
// Phase 4: filterChain GPU processing is added to applyFilterChain:toBuffer:atTime:

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stateful CGImage → CVPixelBuffer processor.
/// Shared between VanguardFileMediaSource (seek frames) and VanguardImageMediaSource (photos).
/// Designed for zero-allocation operation after the first buffer is produced.
@interface VanguardImageProcessor : NSObject

/// @param device  Metal device (used for IOSurface-backed pool allocation)
/// @param pool    Shared CVPixelBufferPool — pass nil for deferred backfill;
///                set the pool property before calling pixelBufferFromCGImage:.
- (instancetype)initWithDevice:(id<MTLDevice>)device
                          pool:(nullable CVPixelBufferPoolRef)pool NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Phase A1-S1: allows deferred pool wiring after renderer creation.
/// Set before calling pixelBufferFromCGImage: — once set, all subsequent
/// allocations use the pool's IOSurface-backed Metal-compatible buffers.
/// NOTE: does NOT transfer ownership. The caller (VanguardMetalRenderer)
/// retains the pool for its lifetime. Setting this to nil reverts to the
/// direct-alloc fallback path (CVPixelBufferCreate).
@property (nonatomic, nullable) CVPixelBufferPoolRef pool;

/// Convert a CGImageRef to a pool-backed CVPixelBufferRef.
/// Synchronous. Caller must CVPixelBufferRelease the returned buffer.
/// Returns nil if the pool is exhausted or the image cannot be drawn.
- (nullable CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image;

/// Apply a GPU filter chain to a buffer. Phase 4 populates this.
/// Phase 2: passthrough — returns inputBuffer unchanged (no filterChain nodes yet).
/// Caller does NOT need to retain/release — the returned buffer is the same as input.
- (CVPixelBufferRef)applyFilterChain:(NSArray *)chain
                            toBuffer:(CVPixelBufferRef)input
                              atTime:(CMTime)t;

/// Async batch processor for filmstrip thumbnail generation.
/// Calls completion on a background queue with an array of CVPixelBufferRefs.
/// Caller must CVPixelBufferRelease each buffer in the array.
- (void)processImages:(NSArray<NSURL *> *)urls
           completion:(void(^)(NSArray<NSValue *> *buffers))completion;

@end

NS_ASSUME_NONNULL_END
