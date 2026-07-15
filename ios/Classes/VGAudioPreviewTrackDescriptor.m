// VGAudioPreviewTrackDescriptor.m
// Vanguard Media Engine — Audio Modularity M2A
//
// Implementation of VGAudioPreviewTrackDescriptor.
// See VGAudioPreviewTrackDescriptor.h for API docs.

#import "VGAudioPreviewTrackDescriptor.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGAudioPreviewTrackDescriptor
// ─────────────────────────────────────────────────────────────────────────────

// Private extension — keeps role internal to .m (Slice F Mandatory Correction 3).
@interface VGAudioPreviewTrackDescriptor () {
  NSString *_role; ///< One of @"music", @"original", @"sfx", @"voiceover". Never nil.
}
@end

@implementation VGAudioPreviewTrackDescriptor

- (NSString *)role { return _role; }


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
  return self;
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
