// VGAudioPreviewAutomationTimer.m
// Vanguard Media Engine — Audio Slice J

#import "VGAudioPreviewAutomationTimer.h"

#if VG_USE_V2_GRAPH

/// Leeway for the repeating timer (10 ms).
static const uint64_t kVGAutomationTimerLeewayNs = 10 * NSEC_PER_MSEC;

@interface VGProductionAudioPreviewAutomationTimer () {
  dispatch_queue_t _targetQueue;
  dispatch_source_t _Nullable _source;
  uint64_t _generation; ///< Incremented on every start/cancel.
}
@end

@implementation VGProductionAudioPreviewAutomationTimer

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
  self = [super init];
  if (self) {
    _targetQueue = queue;
    _source = nil;
    _generation = 0;
  }
  return self;
}

- (void)startWithInterval:(NSTimeInterval)interval block:(dispatch_block_t)block {
  // Cancel existing source and increment generation so any enqueued callbacks
  // from the old source are rejected.
  [self _cancelSourceAndIncrementGeneration];

  uint64_t capturedGen = _generation;
  __weak typeof(self) weakSelf = self;
  dispatch_block_t capturedBlock = [block copy];

  dispatch_source_t src =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _targetQueue);

  uint64_t intervalNs = (uint64_t)(interval * NSEC_PER_SEC);
  dispatch_source_set_timer(src,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
                            intervalNs,
                            kVGAutomationTimerLeewayNs);

  dispatch_source_set_event_handler(src, ^{
    // Source-generation guard: reject callbacks from old cancelled/replaced sources.
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    if (strongSelf->_generation != capturedGen)
      return;
    capturedBlock();
  });

  _source = src;
  dispatch_resume(src);
}

- (void)cancel {
  [self _cancelSourceAndIncrementGeneration];
}

- (void)_cancelSourceAndIncrementGeneration {
  _generation++;
  if (_source) {
    dispatch_source_set_event_handler(_source, nil);
    dispatch_source_cancel(_source);
    _source = nil;
  }
}

- (void)dealloc {
  // Safety-net: cancel on dealloc in case invalidate was not called.
  [self _cancelSourceAndIncrementGeneration];
}

@end

#endif // VG_USE_V2_GRAPH
