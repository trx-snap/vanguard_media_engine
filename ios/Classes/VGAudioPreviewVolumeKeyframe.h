// VGAudioPreviewVolumeKeyframe.h
// Vanguard Media Engine — Audio Slice J
//
// Immutable value object representing one normalized volume keyframe in the
// preview timeline coordinate system.  Time is expressed as absolute output-
// timeline seconds.  Volume is clamped to [0.0, 1.0].
//
// Package-internal only.  Do NOT add to public_header_files.

#pragma once

#import <Foundation/Foundation.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

/// Immutable normalized volume keyframe.
/// Created exclusively by VGAudioPreviewKeyframeNormalizer.
@interface VGAudioPreviewVolumeKeyframe : NSObject

/// Absolute output-timeline position in seconds.
@property(nonatomic, readonly) NSTimeInterval time;

/// Normalized gain in [0.0, 1.0].
@property(nonatomic, readonly) float volume;

/// Designated initializer.
- (instancetype)initWithTime:(NSTimeInterval)time
                      volume:(float)volume NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
