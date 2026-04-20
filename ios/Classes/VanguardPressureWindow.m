// VanguardPressureWindow.m
// Phase 4 — Sliding-window backpressure aggregator

#import "VanguardPressureWindow.h"

static const NSTimeInterval kWindowDuration       = 2.0;  // seconds per window
static const NSInteger      kRecoveryWindowsNeeded = 2;   // consecutive clean windows to recover

@implementation VanguardPressureWindow {
    NSString*                          _name;
    NSInteger                          _threshold;
    NSInteger                          _recovery;
    __weak id<VanguardPressureWindowDelegate> _delegate;

    // Current window state
    NSInteger                          _windowDrops;
    NSTimeInterval                     _windowStart;

    // Pressure / recovery tracking
    BOOL                               _isPressured;
    NSInteger                          _cleanWindowCount;  // consecutive windows below recovery
}

@synthesize isPressured = _isPressured;

- (instancetype)initWithName:(NSString *)name
                   threshold:(NSInteger)threshold
                    recovery:(NSInteger)recovery
                    delegate:(id<VanguardPressureWindowDelegate>)delegate {
    NSAssert(recovery < threshold, @"VanguardPressureWindow: recovery must be < threshold");
    self = [super init];
    if (!self) return nil;
    _name           = [name copy];
    _threshold      = threshold;
    _recovery       = recovery;
    _delegate       = delegate;
    _windowDrops    = 0;
    _windowStart    = CACurrentMediaTime();
    _isPressured    = NO;
    _cleanWindowCount = 0;
    return self;
}

- (NSInteger)currentWindowDrops { return _windowDrops; }

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Public API
// ─────────────────────────────────────────────────────────────────────────────

- (void)recordDrop {
    _windowDrops++;
    [self _maybeRollWindow];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Private
// ─────────────────────────────────────────────────────────────────────────────

- (void)_maybeRollWindow {
    NSTimeInterval now     = CACurrentMediaTime();
    NSTimeInterval elapsed = now - _windowStart;
    if (elapsed < kWindowDuration) return;

    NSInteger drops = _windowDrops;

    // Roll window
    _windowDrops = 0;
    _windowStart = now;

    // Evaluate against thresholds
    if (!_isPressured && drops > _threshold) {
        _isPressured      = YES;
        _cleanWindowCount = 0;
        NSLog(@"[VanguardPressure:%@] Threshold exceeded: %ld drops/2s (threshold=%ld)",
              _name, (long)drops, (long)_threshold);
        [_delegate pressureWindowDidExceedThreshold:self drops:drops];

    } else if (_isPressured && drops <= _recovery) {
        _cleanWindowCount++;
        NSLog(@"[VanguardPressure:%@] Clean window %ld/%ld (drops=%ld)",
              _name, (long)_cleanWindowCount, (long)kRecoveryWindowsNeeded, (long)drops);
        if (_cleanWindowCount >= kRecoveryWindowsNeeded) {
            _isPressured      = NO;
            _cleanWindowCount = 0;
            NSLog(@"[VanguardPressure:%@] Recovered", _name);
            [_delegate pressureWindowDidRecover:self];
        }
    } else {
        // Drops between recovery and threshold: hold current state, reset clean streak
        _cleanWindowCount = 0;
    }
}

@end
