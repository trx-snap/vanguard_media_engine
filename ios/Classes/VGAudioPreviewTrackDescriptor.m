// VGAudioPreviewTrackDescriptor.m
// Vanguard Media Engine — Audio Modularity M2A / Slice J
//
// Implementation of VGAudioPreviewTrackDescriptor.
// See VGAudioPreviewTrackDescriptor.h for API docs.

#import "VGAudioPreviewTrackDescriptor.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGAudioPreviewTrackDescriptor
// ─────────────────────────────────────────────────────────────────────────────

// Private extension — keeps role and rawVolumeKeyframes internal to .m.
@interface VGAudioPreviewTrackDescriptor () {
  NSString *
      _role; ///< One of @"music", @"original", @"sfx", @"voiceover". Never nil.
  NSArray *_Nullable _rawVolumeKeyframes; ///< Copied nonempty raw keyframe
                                          ///< array or nil.
  float _committedMixGain; ///< V-B1/V-B2: parsed from sidecar 'mixGain'. Default 1.0.
}
@end

@implementation VGAudioPreviewTrackDescriptor

- (NSString *)role {
  return _role;
}

- (nullable NSArray *)rawVolumeKeyframes {
  return _rawVolumeKeyframes;
}

- (BOOL)hasRawKeyframes {
  return _rawVolumeKeyframes != nil && _rawVolumeKeyframes.count > 0;
}

- (float)committedMixGain {
  return _committedMixGain;
}

- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dict {
  // 1. Role must be music, original, sfx, or voiceover; all others rejected.
  id roleRaw = dict[@"role"];
  if (![roleRaw isKindOfClass:[NSString class]])
    return nil;
  NSString *role = (NSString *)roleRaw;
  BOOL isMusicRole = [role isEqualToString:@"music"];
  BOOL isOriginalRole = [role isEqualToString:@"original"];
  BOOL isSfxRole = [role isEqualToString:@"sfx"];
  BOOL isVoiceoverRole = [role isEqualToString:@"voiceover"];
  if (!isMusicRole && !isOriginalRole && !isSfxRole && !isVoiceoverRole)
    return nil;

  // 2. trackId non-empty string.
  id trackIdRaw = dict[@"trackId"];
  if (![trackIdRaw isKindOfClass:[NSString class]])
    return nil;
  NSString *trackId = (NSString *)trackIdRaw;
  if (trackId.length == 0)
    return nil;

  // 3. url non-empty string → local file NSURL.
  id urlRaw = dict[@"url"];
  if (![urlRaw isKindOfClass:[NSString class]])
    return nil;
  NSString *urlStr = (NSString *)urlRaw;
  if (urlStr.length == 0)
    return nil;
  NSURL *fileURL = [NSURL fileURLWithPath:urlStr];
  if (!fileURL)
    return nil;

  // 4. Numeric fields — finite bounds.
  id startTimeRaw = dict[@"startTime"];
  id trimStartRaw = dict[@"sourceTrimStart"];
  id volumeRaw = dict[@"volume"];
  id durationRaw = dict[@"duration"];

  if (![startTimeRaw isKindOfClass:[NSNumber class]])
    return nil;

  // sourceTrimStart defaults to 0.0 if nil.
  double trimStart = 0.0;
  if (trimStartRaw != nil) {
    if (![trimStartRaw isKindOfClass:[NSNumber class]])
      return nil;
    trimStart = [trimStartRaw doubleValue];
  }

  // volume defaults to 1.0 if nil.
  double volume = 1.0;
  if (volumeRaw != nil) {
    if (![volumeRaw isKindOfClass:[NSNumber class]])
      return nil;
    volume = [volumeRaw doubleValue];
  }
  if (![durationRaw isKindOfClass:[NSNumber class]])
    return nil;

  double startTime = [startTimeRaw doubleValue];
  double duration = [durationRaw doubleValue];

  // Finite checks.
  if (!isfinite(startTime))
    return nil;
  if (!isfinite(trimStart))
    return nil;
  if (!isfinite(volume))
    return nil;
  if (!isfinite(duration) && duration != -1.0)
    return nil;

  // Bound checks.
  if (startTime < 0.0)
    return nil;
  if (trimStart < 0.0)
    return nil;
  if (volume < 0.0 || volume > 1.0)
    return nil;
  if (duration != -1.0 && duration < 0.0)
    return nil;

  self = [super init];
  if (!self)
    return nil;
  _trackId = [trackId copy];
  _fileURL = fileURL;
  _timelineStart = startTime;
  _sourceTrimStart = trimStart;
  _requestedDuration = duration;
  _staticVolume = (float)volume;
  _role = [role copy];

  // Parse raw volumeKeyframes (Slice J). Store a copied nonempty array or nil.
  id rawKfs = dict[@"volumeKeyframes"];
  if ([rawKfs isKindOfClass:[NSArray class]] && [(NSArray *)rawKfs count] > 0) {
    _rawVolumeKeyframes = [(NSArray *)rawKfs copy];
  } else {
    _rawVolumeKeyframes = nil;
  }

  // V-B1/V-B2: parse committedMixGain from sidecar; default 1.0 when absent.
  // Valid range [0.0, 1.0]; clamped defensively.
  id mixGainRaw = dict[@"mixGain"];
  if ([mixGainRaw isKindOfClass:[NSNumber class]]) {
    float mg = [mixGainRaw floatValue];
    _committedMixGain = MAX(0.0f, MIN(1.0f, mg));
  } else {
    _committedMixGain = 1.0f;
  }

  return self;
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
