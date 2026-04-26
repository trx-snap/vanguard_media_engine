// VanguardBeautyFilterNode.h
// Phase 4 — P4-FN-5/6: Edge-preserving bilateral filter (skin smoothing).
//
// Conforms to VanguardFilterNode protocol.
// • Uses the vanguard_bilateral_filter Metal compute kernel (VanguardEffects.metal).
// • At intensity=0.0: sigma_color→0 → identity on any image (P4-FN-5).
// • Respects enabled=NO gate from VanguardMLGate thermal authority (P4-FN-6).
// • Thread-safe: processBuffer:atTime:device: may be called from any queue.

#pragma once
#import "VanguardFilterNode.h"
// Phase 3 (P3-1) — VGMetalFilterNode conformance (additive; existing VanguardFilterNode retained)
#import "VGMetalFilterNode.h"
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface VanguardBeautyFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode (additive — P3-1) ────────────────────────────────────────────
/// Stable node identifier. Set to a UUID string at init time.
@property (nonatomic, readonly, copy) NSString *nodeId;
/// Node type tag for logging. Value: @"VGBeautyFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

@property (readonly, nonatomic, copy) NSString *filterName;

/// When NO, returns input buffer unchanged (zero GPU cost). Default: YES.
/// Set to NO by VanguardMLGate when thermal or pressure signals fire.
@property (nonatomic, assign) BOOL enabled;

/// Smoothing intensity [0.0, 1.0]. Maps to sigmaColor range [0.001, 0.3]. Default: 0.5.
/// At 0.0: identity (no smoothing). At 1.0: maximum bilateral smoothing.
@property (atomic) float intensity;

/// Filter radius in pixels [1, 4]. Default: 2 (5×5 kernel). Higher = stronger + slower.
@property (atomic) int radius;

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
