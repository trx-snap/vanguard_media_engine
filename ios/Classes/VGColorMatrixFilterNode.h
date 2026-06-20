// VGColorMatrixFilterNode.h
// vanguard_media_engine — Phase 10-C-3L.1C
//
// Lightweight GPU filter node that applies a 4×5 row-major color matrix to
// each pixel of a CVPixelBufferRef via the `vanguard_color_matrix_apply`
// Metal compute kernel (VanguardEffects.metal).
//
// Matrix convention matches Flutter's ColorFilter.matrix:
//   Columns : [R_in, G_in, B_in, A_in, constant]
//   Rows    : [R_out, G_out, B_out, A_out]
// The constant term (column 4) is treated as a 0–255 additive offset,
// divided by 255.0 inside the kernel to yield a normalised value.
//
// Design rules:
//   • Conforms to both <VGMetalFilterNode> (Phase 3 V2 pipeline) and the
//     legacy <VanguardFilterNode> (Phase 1 backward compat).
//   • All public state is thread-safe: matrix swap is os_unfair_lock protected.
//   • processBuffer:atTime:device: allocates a new output buffer from the pool
//     (+1 retain). Passthrough (enabled=NO) returns the input with +1 retain.
//   • DEC-44/RR-28 buffer ownership: caller releases the returned buffer.
//   • estimatedGPUCostMs: 1.5ms (A14, 1080p BGRA). Faster than LUT (2ms)
//     because the matrix is an ALU-only operation with no texture fetch.
//
// Single-shot use (export): Allocate, set matrix, call processBuffer once.
// No lifetime management beyond dealloc is required.

#pragma once

#import "VanguardFilterNode.h"
// Phase 3 (P3-1) — VGMetalFilterNode conformance (additive; VanguardFilterNode retained)
#import <UMF/VGMetalFilterNode.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// A GPU filter node that applies a 4×5 row-major color matrix to each pixel.
///
/// Matrix layout (Flutter ColorFilter.matrix convention):
/// ```
///   [r0, r1, r2, r3, r4,    // R_out = r0*R + r1*G + r2*B + r3*A + r4/255
///    g0, g1, g2, g3, g4,    // G_out = g0*R + g1*G + g2*B + g3*A + g4/255
///    b0, b1, b2, b3, b4,    // B_out = b0*R + b1*G + b2*B + b3*A + b4/255
///    a0, a1, a2, a3, a4]    // A_out = a0*R + a1*G + a2*B + a3*A + a4/255
/// ```
/// The constant term (column 4) is treated as a 0–255 value; the kernel divides
/// by 255.0 internally. All output channels are clamped to [0, 1].
@interface VGColorMatrixFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode (additive — P3-1) ────────────────────────────────────────────
/// Stable node identifier (UUID string, set at init time).
@property (nonatomic, readonly, copy) NSString *nodeId;
/// Node type tag for logging. Value: @"VGColorMatrixFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

/// Human-readable name. Default: "ColorMatrix".
@property (readonly, nonatomic, copy) NSString *filterName;

/// When NO, returns the input buffer unchanged (zero GPU cost). Default: YES.
@property (nonatomic, assign) BOOL enabled;

/// The active 4×5 color matrix as an array of exactly 20 floats (row-major).
///
/// The setter performs a lock-protected swap. Pass an array of 20 NSNumber
/// objects. Values outside a valid 4×5 matrix dimension are ignored.
/// Must not be nil; an assertion fires in debug builds if nil is passed.
@property (atomic, copy) NSArray<NSNumber *> *colorMatrix;

/// Designated initialiser.
/// @param pool   The renderer's CVPixelBufferPool — output buffers are drawn from here.
/// @param device The shared MTLDevice.
/// @param matrix 20-element NSArray<NSNumber*> of float values (row-major 4×5 matrix).
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                      matrix:(NSArray<NSNumber *> *)matrix NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
