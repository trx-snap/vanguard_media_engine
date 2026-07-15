// VGAudioPreviewKeyframeNormalizer.m
// Vanguard Media Engine — Audio Slice J
//
// 12-step normalization contract (matches VGAudioExportMuxer semantics):
//
//  1.  Ignore non-dictionary entries.
//  2.  Reject missing or nonnumeric "time" or "volume".
//  3.  Reject nonfinite time or volume.
//  4.  Accept absent curve or "linear"; reject other curve values.
//  5.  Clamp volume to [0.0, 1.0].
//  6.  Discard timestamps outside [effectiveStart, effectiveEnd].
//  7.  Stable-sort by ascending time.
//  8.  Merge adjacent entries < 0.001 s apart; later entry wins.
//  9.  If first valid point > effectiveStart + 0.001, prepend (effectiveStart, 0.0).
// 10.  If last valid point < effectiveEnd − 0.001, append (effectiveEnd, lastVolume).
// 11.  Return nil when no valid keyframes remain.

#import "VGAudioPreviewKeyframeNormalizer.h"

#if VG_USE_V2_GRAPH

static const NSTimeInterval kVGKeyframeMergeThreshold = 0.001;

@implementation VGAudioPreviewKeyframeNormalizer

+ (nullable NSArray<VGAudioPreviewVolumeKeyframe *> *)
    normalizeKeyframes:(NSArray *)rawKeyframes
         timelineStart:(NSTimeInterval)timelineStart
          effectiveEnd:(NSTimeInterval)effectiveEnd {

  if (!rawKeyframes || rawKeyframes.count == 0)
    return nil;
  if (effectiveEnd <= timelineStart)
    return nil;

  // Steps 1–6: parse and validate each entry.
  NSMutableArray<VGAudioPreviewVolumeKeyframe *> *valid =
      [NSMutableArray arrayWithCapacity:rawKeyframes.count];

  for (id entry in rawKeyframes) {
    // Step 1: must be a dictionary.
    if (![entry isKindOfClass:[NSDictionary class]])
      continue;
    NSDictionary *dict = (NSDictionary *)entry;

    // Step 2: require numeric "time" and "volume".
    id timeRaw = dict[@"time"];
    id volumeRaw = dict[@"volume"];
    if (![timeRaw isKindOfClass:[NSNumber class]])
      continue;
    if (![volumeRaw isKindOfClass:[NSNumber class]])
      continue;

    // Step 3: reject nonfinite values.
    double t = [timeRaw doubleValue];
    double v = [volumeRaw doubleValue];
    if (!isfinite(t) || !isfinite(v))
      continue;

    // Step 4: curve must be absent or "linear".
    id curveRaw = dict[@"curve"];
    if (curveRaw != nil) {
      if (![curveRaw isKindOfClass:[NSString class]])
        continue;
      if (![(NSString *)curveRaw isEqualToString:@"linear"])
        continue;
    }

    // Step 5: clamp volume.
    float volume = (float)MAX(0.0, MIN(1.0, v));

    // Step 6: discard timestamps outside [effectiveStart, effectiveEnd].
    if (t < timelineStart || t > effectiveEnd)
      continue;

    [valid addObject:[[VGAudioPreviewVolumeKeyframe alloc] initWithTime:t
                                                                  volume:volume]];
  }

  if (valid.count == 0)
    return nil;

  // Step 7: stable-sort by ascending time.
  // Use index-based stable sort to preserve original order for equal times.
  NSMutableArray<VGAudioPreviewVolumeKeyframe *> *sorted =
      [NSMutableArray arrayWithArray:valid];
  [sorted sortWithOptions:NSSortStable
          usingComparator:^NSComparisonResult(VGAudioPreviewVolumeKeyframe *a,
                                              VGAudioPreviewVolumeKeyframe *b) {
            if (a.time < b.time)
              return NSOrderedAscending;
            if (a.time > b.time)
              return NSOrderedDescending;
            return NSOrderedSame;
          }];

  // Step 8: merge adjacent entries < kVGKeyframeMergeThreshold apart;
  // later entry (higher index after sort) wins.
  NSMutableArray<VGAudioPreviewVolumeKeyframe *> *merged =
      [NSMutableArray arrayWithCapacity:sorted.count];
  for (VGAudioPreviewVolumeKeyframe *kf in sorted) {
    if (merged.count > 0) {
      VGAudioPreviewVolumeKeyframe *last = merged.lastObject;
      if ((kf.time - last.time) < kVGKeyframeMergeThreshold) {
        // Later entry wins — replace last.
        [merged removeLastObject];
      }
    }
    [merged addObject:kf];
  }

  if (merged.count == 0)
    return nil;

  // Step 9: if first point is later than effectiveStart + threshold,
  // prepend boundary at effectiveStart with volume 0.0.
  VGAudioPreviewVolumeKeyframe *first = merged.firstObject;
  if (first.time > timelineStart + kVGKeyframeMergeThreshold) {
    VGAudioPreviewVolumeKeyframe *boundary =
        [[VGAudioPreviewVolumeKeyframe alloc] initWithTime:timelineStart
                                                    volume:0.0f];
    [merged insertObject:boundary atIndex:0];
  }

  // Step 10: if last point is earlier than effectiveEnd − threshold,
  // append boundary at effectiveEnd holding the last volume.
  VGAudioPreviewVolumeKeyframe *last = merged.lastObject;
  if (last.time < effectiveEnd - kVGKeyframeMergeThreshold) {
    VGAudioPreviewVolumeKeyframe *boundary =
        [[VGAudioPreviewVolumeKeyframe alloc] initWithTime:effectiveEnd
                                                    volume:last.volume];
    [merged addObject:boundary];
  }

  // Step 11: return nil when nothing valid remains.
  if (merged.count == 0)
    return nil;

  return [merged copy];
}

@end

#endif // VG_USE_V2_GRAPH
