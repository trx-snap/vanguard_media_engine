// VGAudioPreviewEnvelopeEvaluator.m
// Vanguard Media Engine — Audio Slice J

#import "VGAudioPreviewEnvelopeEvaluator.h"

#if VG_USE_V2_GRAPH

@implementation VGAudioPreviewEnvelopeEvaluator

+ (float)evaluateEnvelope:(NSArray<VGAudioPreviewVolumeKeyframe *> *)envelope
                    atPTS:(NSTimeInterval)pts {
  NSUInteger count = envelope.count;
  if (count == 0)
    return 0.0f;

  VGAudioPreviewVolumeKeyframe *first = envelope[0];
  if (pts <= first.time)
    return first.volume;

  VGAudioPreviewVolumeKeyframe *last = envelope[count - 1];
  if (pts >= last.time)
    return last.volume;

  // Binary search for the segment containing pts.
  NSUInteger lo = 0;
  NSUInteger hi = count - 1;
  while (lo + 1 < hi) {
    NSUInteger mid = (lo + hi) / 2;
    if (envelope[mid].time <= pts)
      lo = mid;
    else
      hi = mid;
  }

  VGAudioPreviewVolumeKeyframe *a = envelope[lo];
  VGAudioPreviewVolumeKeyframe *b = envelope[hi];

  NSTimeInterval span = b.time - a.time;
  if (span <= 0.0)
    return b.volume;

  double t = (pts - a.time) / span;
  float result = (float)(a.volume + t * (b.volume - a.volume));
  return MAX(0.0f, MIN(1.0f, result));
}

@end

#endif // VG_USE_V2_GRAPH
