// VGAudioPreviewEnvelopeEvaluator.h
// Vanguard Media Engine — Audio Slice J
//
// Pure linear envelope evaluator.  Stateless.  No timers or player access.
//
// Package-internal only.  Do NOT add to public_header_files.

#pragma once

#import "VGAudioPreviewVolumeKeyframe.h"
#import <Foundation/Foundation.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@interface VGAudioPreviewEnvelopeEvaluator : NSObject

/// Evaluates the normalized envelope at the given absolute timeline PTS.
///
/// Semantics:
///   before first point → first volume
///   exact match         → that volume
///   between points      → linear interpolation
///   after last point    → last volume
///
/// @param envelope  Non-empty sorted array from VGAudioPreviewKeyframeNormalizer.
/// @param pts       Absolute output-timeline position in seconds.
/// @return          Interpolated gain in [0.0, 1.0].
+ (float)evaluateEnvelope:(NSArray<VGAudioPreviewVolumeKeyframe *> *)envelope
                    atPTS:(NSTimeInterval)pts;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
