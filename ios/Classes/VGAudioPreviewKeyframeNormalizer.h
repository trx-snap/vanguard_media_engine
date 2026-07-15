// VGAudioPreviewKeyframeNormalizer.h
// Vanguard Media Engine — Audio Slice J
//
// Pure keyframe normalization utility for the preview runtime.
// Applies the 12-step normalization contract to raw track keyframe data
// and returns an immutable sorted array of VGAudioPreviewVolumeKeyframe
// objects, or nil when no valid keyframes remain.
//
// All methods are stateless class methods.  No runtime state, timers or
// player access occurs here.
//
// Package-internal only.  Do NOT add to public_header_files.

#pragma once

#import "VGAudioPreviewVolumeKeyframe.h"
#import <Foundation/Foundation.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@interface VGAudioPreviewKeyframeNormalizer : NSObject

/// Normalizes a raw keyframe array into an immutable sorted envelope.
///
/// @param rawKeyframes   Raw NSArray from the track dictionary (entries may be
///                       any type; invalid entries are discarded).
/// @param timelineStart  effectiveStart = MAX(0, descriptor.timelineStart).
/// @param effectiveEnd   effectiveStart + activeDuration.
///
/// @return Immutable NSArray<VGAudioPreviewVolumeKeyframe *> with ≥2 entries,
///         or nil if no valid keyframes remain after all filtering steps.
+ (nullable NSArray<VGAudioPreviewVolumeKeyframe *> *)
    normalizeKeyframes:(NSArray *)rawKeyframes
         timelineStart:(NSTimeInterval)timelineStart
          effectiveEnd:(NSTimeInterval)effectiveEnd;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
