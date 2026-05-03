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
#import <UIKit/UIKit.h>

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

/// Convert a UIImage to a pool-backed CVPixelBufferRef, honouring imageOrientation.
/// Use this instead of pixelBufferFromCGImage: whenever EXIF orientation must be
/// respected (e.g. gallery photos picked via image_picker). UIGraphicsImageRenderer
/// automatically applies the UIImage's imageOrientation transform during draw.
/// Synchronous. Caller must CVPixelBufferRelease the returned buffer.
/// Returns nil on pool exhaustion or draw failure.
- (nullable CVPixelBufferRef)pixelBufferFromUIImage:(UIImage *)image;

/// Apply a GPU filter chain to a buffer. Phase 4: iterates filter nodes.
/// Ownership contract:
///   - If chain is empty or all nodes passthrough → returns input unchanged (no extra retain).
///   - If a node produces a new buffer → returns it with +1 retain; caller must CVPixelBufferRelease.
///   - Caller always checks: if (output != input) CVPixelBufferRelease(output) after use.
- (CVPixelBufferRef)applyFilterChain:(NSArray *)chain
                            toBuffer:(CVPixelBufferRef)input
                              atTime:(CMTime)t
                              device:(id<MTLDevice>)device;

/// Async batch processor for filmstrip thumbnail generation.
/// Calls completion on a background queue with an array of CVPixelBufferRefs.
/// Caller must CVPixelBufferRelease each buffer in the array.
- (void)processImages:(NSArray<NSURL *> *)urls
           completion:(void(^)(NSArray<NSValue *> *buffers))completion;

@end

NS_ASSUME_NONNULL_END
