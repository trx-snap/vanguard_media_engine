// VanguardSegmentationFilterNode.h
// Phase 4 — P4-SEG-1 through P4-SEG-6: Person segmentation composite.
//
// Conforms to VanguardFilterNode protocol.
// • Reads the current VanguardMaskStore snapshot for the segmentation mask.
// • Applies vanguard_segmentation_composite kernel (VanguardEffects.metal).
// • Mask must be r8Unorm 256×256 (P4-SEG-5).
// • White mask (0xFF) = full foreground passthrough (P4-SEG-1).
// • Black mask (0x00) = full background replacement (P4-SEG-2).
// • Stale mask (>100ms) falls back to default white mask (P4-SEG-3).
// • Frozen generation (no advance in >100ms) detected and flagged (P4-SEG-4).
// • Background source: a caller-provided MTLTexture (solid colour, blur, or image).

#pragma once
#import "VanguardFilterNode.h"
#import "VanguardMaskStore.h"
// Phase 3 (P3-1) — VGMetalFilterNode conformance (additive; existing VanguardFilterNode retained)
#import "VGMetalFilterNode.h"
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface VanguardSegmentationFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode (additive — P3-1) ────────────────────────────────────────────
/// Stable node identifier. Set to a UUID string at init time.
@property (nonatomic, readonly, copy) NSString *nodeId;
/// Node type tag for logging. Value: @"VGSegmentationFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

@property (readonly, nonatomic, copy) NSString *filterName;
@property (nonatomic, assign) BOOL enabled;

/// Mask store polled on each frame. Not retained beyond processBuffer:atTime:device:.
@property (nonatomic, weak, nullable) VanguardMaskStore *maskStore;

/// Background texture to composite behind the person.
/// Must be bgra8Unorm and same dimensions as input. May be swapped atomically.
@property (atomic, retain, nullable) id<MTLTexture> backgroundTexture;

/// Stale threshold in seconds. Masks older than this use the default. Default: 0.100s.
@property (atomic) NSTimeInterval staleThreshold;

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
