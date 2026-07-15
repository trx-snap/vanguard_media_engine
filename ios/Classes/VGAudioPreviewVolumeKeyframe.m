// VGAudioPreviewVolumeKeyframe.m
// Vanguard Media Engine — Audio Slice J

#import "VGAudioPreviewVolumeKeyframe.h"

#if VG_USE_V2_GRAPH

@implementation VGAudioPreviewVolumeKeyframe

- (instancetype)initWithTime:(NSTimeInterval)time volume:(float)volume {
  self = [super init];
  if (self) {
    _time = time;
    _volume = volume;
  }
  return self;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"<VGAudioPreviewVolumeKeyframe t=%.4f v=%.4f>",
          _time, _volume];
}

@end

#endif // VG_USE_V2_GRAPH
