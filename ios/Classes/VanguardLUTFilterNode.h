// VanguardLUTFilterNode.h
// Phase 4 — P4-FN-1/2/3/4: 3D LUT color-grading filter node.
//
// Conforms to VanguardFilterNode protocol.
// • Loads a 32³ or 64³ rgba8Unorm 3D LUT from a .cube resource or raw data.
// • Applies via the vanguard_lut_apply Metal compute kernel (VanguardEffects.metal).
// • Identity LUT produces ≤2/255 output deviation (P4-FN-1).
// • Nil LUT (enabled=NO) passes through input unchanged via blit (P4-FN-3).
// • LUT swap is os_unfair_lock protected (P4-FN-4).
// • Thread-safe: processBuffer:atTime:device: may be called from any queue.

#pragma once
#import "VanguardFilterNode.h"
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface VanguardLUTFilterNode : NSObject <VanguardFilterNode>

/// Human-readable name. Default: "LUT".
@property (readonly, nonatomic, copy) NSString *filterName;

/// When NO, returns the input buffer unchanged (zero GPU cost). Default: YES.
@property (nonatomic, assign) BOOL enabled;

/// LUT intensity blend [0.0, 1.0]. 0.0 = identity, 1.0 = full LUT. Default: 1.0.
@property (atomic) float intensity;

/// Designated initialiser.
/// @param pool   The renderer's CVPixelBufferPool — output buffers are drawn from here.
/// @param device The shared MTLDevice.
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Load a LUT from a .cube file URL.
/// Parses the DOMAIN SIZE and LUT table to populate a Metal 3D texture.
/// Call from a background queue; completion is dispatched on the calling queue.
- (void)loadLUTFromCubeURL:(NSURL *)url completion:(void (^)(NSError *_Nullable))completion;

/// Load a LUT directly from pre-built rgba8Unorm data.
/// @param size    Cubic edge length (e.g. 32 for 32³ LUT).
/// @param data    size³ × 4 bytes of rgba8Unorm data (r=R, g=G, b=B, a=255).
- (void)loadLUTWithSize:(NSInteger)size data:(NSData *)data;

/// Clear the active LUT. Equivalent to setting enabled=NO until next load.
- (void)clearLUT;

@end

NS_ASSUME_NONNULL_END
