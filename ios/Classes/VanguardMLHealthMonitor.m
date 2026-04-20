// VanguardMLHealthMonitor.m
// Phase 4

#import "VanguardMLHealthMonitor.h"

static const NSTimeInterval kCheckInterval     = 3.0;
static const NSInteger      kStallCheckCount   = 2;   // 2 × 3s = 6s stall window

@implementation VanguardMLHealthMonitor {
    VanguardMaskStore*                          _store;
    __weak id<VanguardMLHealthMonitorDelegate>  _delegate;
    dispatch_source_t                           _timer;
    uint64_t                                    _lastGeneration;
    NSInteger                                   _stalledCount;
    BOOL                                        _running;
}

- (instancetype)initWithMaskStore:(VanguardMaskStore *)store
                         delegate:(id<VanguardMLHealthMonitorDelegate>)delegate {
    self = [super init];
    if (!self) return nil;
    _store    = store;
    _delegate = delegate;
    return self;
}

- (void)startMonitoring {
    if (_running) return;
    _running        = YES;
    _lastGeneration = _store.generation;
    _stalledCount   = 0;

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);

    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(kCheckInterval * NSEC_PER_SEC)),
                              (uint64_t)(kCheckInterval * NSEC_PER_SEC),
                              (uint64_t)(0.5 * NSEC_PER_SEC));  // 500ms leeway

    __weak typeof(self) w = self;
    dispatch_source_set_event_handler(_timer, ^{ [w _check]; });
    dispatch_resume(_timer);
}

- (void)stopMonitoring {
    if (!_running) return;
    _running = NO;
    dispatch_source_cancel(_timer);
    _timer = nil;
}

- (void)_check {
    uint64_t gen = _store.generation;

    if (gen == _lastGeneration) {
        _stalledCount++;
        NSLog(@"[VanguardMLHealth] No snapshot advance — stalled %lds (gen=%llu)",
              (long)(_stalledCount * (NSInteger)kCheckInterval), gen);
        if (_stalledCount >= kStallCheckCount) {
            NSLog(@"[VanguardMLHealth] ⚠️ Stall detected — notifying fault handler");
            id<VanguardMLHealthMonitorDelegate> d = _delegate;
            [d mlHealthMonitorDetectedStall:@"snapshot-stall"];
            // Reset so we don't spam fault transitions
            _stalledCount   = 0;
            _lastGeneration = gen;
        }
    } else {
        _stalledCount   = 0;
        _lastGeneration = gen;
    }
}

- (void)dealloc {
    [self stopMonitoring];
}

@end
