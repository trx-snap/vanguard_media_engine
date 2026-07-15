// VanguardAudioPreviewRuntimeTest_SliceJ_TimerProduction.m
// Vanguard Media Engine — Audio Slice J
//
// 6 production timer selectors: testJ_TP1 through testJ_TP6.
// Tests VGProductionAudioPreviewAutomationTimer directly.

#import "VanguardAudioPreviewRuntimeTest.h"
#import "VGAudioPreviewAutomationTimer.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (SliceJTimerProduction)

// TP1: start then cancel — block not called after cancel.
- (void)testJ_TP1_startThenCancelBlockNotCalled {
  dispatch_queue_t q = dispatch_queue_create("vg.test.tp1", DISPATCH_QUEUE_SERIAL);
  VGProductionAudioPreviewAutomationTimer *timer =
      [[VGProductionAudioPreviewAutomationTimer alloc] initWithQueue:q];
  __block NSInteger callCount = 0;
  [timer startWithInterval:0.01 block:^{ callCount++; }];
  [timer cancel];
  [self waitFor:0.05];
  XCTAssertEqual(callCount, 0,
                 @"Block must not fire after cancel");
}

// TP2: start twice — only latest block fires.
- (void)testJ_TP2_startTwiceOnlyLatestBlockFires {
  dispatch_queue_t q = dispatch_queue_create("vg.test.tp2", DISPATCH_QUEUE_SERIAL);
  VGProductionAudioPreviewAutomationTimer *timer =
      [[VGProductionAudioPreviewAutomationTimer alloc] initWithQueue:q];
  __block NSInteger firstCount = 0;
  __block NSInteger secondCount = 0;
  [timer startWithInterval:0.05 block:^{ firstCount++; }];
  [timer startWithInterval:0.01 block:^{ secondCount++; }];
  [self waitFor:0.05];
  [timer cancel];
  XCTAssertGreaterThan(secondCount, 0, @"Latest block must fire");
  // firstCount should be 0 — the first source was replaced.
  XCTAssertEqual(firstCount, 0, @"Replaced block must not fire");
}

// TP3: cancel is idempotent.
- (void)testJ_TP3_cancelIsIdempotent {
  dispatch_queue_t q = dispatch_queue_create("vg.test.tp3", DISPATCH_QUEUE_SERIAL);
  VGProductionAudioPreviewAutomationTimer *timer =
      [[VGProductionAudioPreviewAutomationTimer alloc] initWithQueue:q];
  [timer cancel];
  [timer cancel]; // must not crash
}

// TP4: block fires repeatedly at interval.
- (void)testJ_TP4_blockFiresRepeatedly {
  dispatch_queue_t q = dispatch_queue_create("vg.test.tp4", DISPATCH_QUEUE_SERIAL);
  VGProductionAudioPreviewAutomationTimer *timer =
      [[VGProductionAudioPreviewAutomationTimer alloc] initWithQueue:q];
  __block NSInteger callCount = 0;
  [timer startWithInterval:0.01 block:^{ callCount++; }];
  [self waitFor:0.06];
  [timer cancel];
  XCTAssertGreaterThanOrEqual(callCount, 3,
                              @"Repeating timer must fire multiple times");
}

// TP5: cancelled timer's enqueued callback is a no-op.
- (void)testJ_TP5_enqueuedCallbackNoOpAfterCancel {
  // We cannot easily verify an already-enqueued GCD callback was rejected,
  // but we can verify that cancelling and restarting the timer results in
  // only the new block incrementing.
  dispatch_queue_t q = dispatch_queue_create("vg.test.tp5", DISPATCH_QUEUE_SERIAL);
  VGProductionAudioPreviewAutomationTimer *timer =
      [[VGProductionAudioPreviewAutomationTimer alloc] initWithQueue:q];
  __block NSInteger oldCount = 0;
  __block NSInteger newCount = 0;
  [timer startWithInterval:0.01 block:^{ oldCount++; }];
  [timer cancel]; // generation incremented
  [timer startWithInterval:0.01 block:^{ newCount++; }];
  [self waitFor:0.05];
  [timer cancel];
  XCTAssertEqual(oldCount, 0, @"Old generation block must be rejected");
  XCTAssertGreaterThan(newCount, 0, @"New generation block must fire");
}

// TP6: No retain cycle between timer and its dispatch source.
// Uses @autoreleasepool + __weak to verify the timer is deallocated after
// cancel() when no external strong references remain. If the event handler
// captured 'self' strongly (i.e., lacked __weak weakSelf), the timer would
// be retained by the dispatch source and weakTimer would remain non-nil.
- (void)testJ_TP6_noRetainCycleAfterCancel {
  dispatch_queue_t q = dispatch_queue_create("vg.test.tp6", DISPATCH_QUEUE_SERIAL);
  __weak VGProductionAudioPreviewAutomationTimer *weakTimer = nil;
  @autoreleasepool {
    VGProductionAudioPreviewAutomationTimer *timer =
        [[VGProductionAudioPreviewAutomationTimer alloc] initWithQueue:q];
    weakTimer = timer;
    [timer startWithInterval:0.01 block:^{}];
    [timer cancel];
    // 'timer' exits scope here. If no retain cycle exists, it is released.
  }
  // If the event handler formed a retain cycle with the timer, weakTimer would
  // still be non-nil here. cancel() sets the event handler to nil, which must
  // break any cycle before the last strong reference drops.
  XCTAssertNil(weakTimer,
               @"Timer must not form a retain cycle with its dispatch source");
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
