// VGAudioPreviewTrackDescriptor.h
// Vanguard Media Engine — Audio Modularity M2A / Slice J
//
// Immutable, normalised descriptor produced from one eligible track
// dictionary in VGAudioSidecarPlan.tracks. Once constructed it is the
// sole source of truth for the scheduled segment; no raw dictionary reads
// occur during scheduling.
//
// Package-internal only. Do NOT add to public_header_files.

#pragma once

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── VGAudioPreviewTrackDescriptor ───────────────────────────────────────────
//
// Immutable, normalised descriptor produced from the first eligible 'music'
// track dictionary in VGAudioSidecarPlan.tracks. Once constructed it is the
// sole source of truth for the scheduled segment; no raw dictionary reads
// occur during scheduling.

@interface VGAudioPreviewTrackDescriptor : NSObject

/// Non-empty; copied from track dict[@"trackId"].
@property(nonatomic, readonly, copy) NSString *trackId;
/// Local file URL; resolved from track dict[@"url"] via [NSURL
/// fileURLWithPath:].
@property(nonatomic, readonly, strong) NSURL *fileURL;
/// Seconds from timeline origin where playback begins. >= 0.0.
@property(nonatomic, readonly) NSTimeInterval timelineStart;
/// Source-file seek offset in seconds. >= 0.0.
@property(nonatomic, readonly) NSTimeInterval sourceTrimStart;
/// Requested active duration in seconds. -1.0 means use full remaining file.
@property(nonatomic, readonly) NSTimeInterval requestedDuration;
/// Static gain applied to AVAudioPlayerNode.volume. 0.0–1.0.
@property(nonatomic, readonly) float staticVolume;
/// The track role accepted by the scheduler: @"music", @"original",
/// @"sfx", or @"voiceover".
/// Raw volumeKeyframes array from the track dictionary, or nil if absent or
/// empty.  Entries are unvalidated NSDictionary objects; normalization is
/// performed externally by VGAudioPreviewKeyframeNormalizer.
@property(nonatomic, readonly, nullable) NSArray *rawVolumeKeyframes;
/// YES if rawVolumeKeyframes is non-nil and contains at least one entry.
@property(nonatomic, readonly) BOOL hasRawKeyframes;
@property(nonatomic, readonly, copy) NSString *role;

/// Designated initialiser. Returns nil if any field fails validation.
///
/// Validation rules (plan §D item 4):
///   - role is one of @"music", @"original", @"sfx", @"voiceover"
///   - trackId non-empty string
///   - url non-empty string resolvable to a local file NSURL
///   - startTime finite, >= 0.0
///   - sourceTrimStart finite, >= 0.0
///   - volume finite, 0.0 <= volume <= 1.0
///   - duration finite and either == -1.0 or >= 0.0
- (nullable instancetype)initWithDictionary:(NSDictionary<NSString *, id> *)dict
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
