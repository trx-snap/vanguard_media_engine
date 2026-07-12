// VGTimelineSnapshotTest.m
// Vanguard Media Engine — Phase 10-C Slice C
//
// Deterministic unit tests for the VanguardGraphRuntime timeline-state snapshot
// contract established by Slice C (RR-186 mitigation).
//
// Test isolation: all mock classes use the VGSnap_ prefix to avoid Objective-C
// runtime name collisions with mocks declared in other test files in the same
// bundle (e.g. VGGraphRuntimeLifecycleTest.m).

#import <XCTest/XCTest.h>
#import <stdint.h>
#import <stdatomic.h>

#import "VanguardGraphRuntime.h"
#import "VGTimelineStateSnapshot.h"

#if VG_USE_V2_GRAPH

// ─── Private selector declarations ───────────────────────────────────────────
// These redeclare verified private methods from VanguardGraphRuntime.m for
// test access only. No production code is modified.

@interface VanguardGraphRuntime (VGSnapTestSeam)
- (void)_timelinePlay;
- (void)_timelinePause;
- (void)_publishTimelineSnapshot;
// Expose writable timeline properties for deterministic state injection.
@property(nonatomic, assign) double timelineCurrentPTS;
@property(nonatomic, assign) double timelinePlayStartTime;
@property(nonatomic, assign) double timelineBasePTS;
@property(atomic, assign)   uint64_t timelineGeneration;
@property(nonatomic, assign) BOOL timelineIsPlaying;
@end

// ─── VGSnap_MockTextureRegistry ──────────────────────────────────────────────

@interface VGSnap_MockTextureRegistry : NSObject <FlutterTextureRegistry>
@end

@implementation VGSnap_MockTextureRegistry
- (int64_t)registerTexture:(id<FlutterTexture>)texture {
  return 42;
}
- (void)textureFrameAvailable:(int64_t)textureId {}
- (void)unregisterTexture:(int64_t)textureId {}
@end

// ─── VGSnap_MockMethodChannel ─────────────────────────────────────────────────

@interface VGSnap_MockMethodChannel : NSObject
@property(nonatomic) NSInteger callCount;
@property(nonatomic, copy, nullable) NSString *lastMethod;
@property(nonatomic, strong, nullable) id lastArguments;
- (void)invokeMethod:(NSString *)method arguments:(id _Nullable)arguments;
@end

@implementation VGSnap_MockMethodChannel
- (void)invokeMethod:(NSString *)method arguments:(id _Nullable)arguments {
  self.callCount++;
  self.lastMethod = method;
  self.lastArguments = arguments;
}
@end

// ─── VGSnap_EOSMethodChannel ──────────────────────────────────────────────────
// Method-channel stub for EOS-path tests. Fulfills an XCTestExpectation
// when invokeMethod:@"onTimelineEOS" is received.

@interface VGSnap_EOSMethodChannel : NSObject
@property(nonatomic, strong, nullable) XCTestExpectation *eosExpectation;
@property(nonatomic) NSInteger callCount;
@property(nonatomic, copy, nullable) NSString *lastMethod;
@property(nonatomic, strong, nullable) id lastArguments;
- (void)invokeMethod:(NSString *)method arguments:(id _Nullable)arguments;
@end

@implementation VGSnap_EOSMethodChannel
- (void)invokeMethod:(NSString *)method arguments:(id _Nullable)arguments {
  self.callCount++;
  self.lastMethod = method;
  self.lastArguments = arguments;
  if ([method isEqualToString:@"onTimelineEOS"] && self.eosExpectation) {
    [self.eosExpectation fulfill];
  }
}
@end

// ─── VGSnap_MockSourceNode ────────────────────────────────────────────────────
// Minimal stub satisfying <VGSourceNode> (which extends <VGNode>).
// pullFrame: always returns skipped — used for lifecycle/state tests.

#import <UMF/VGSourceNode.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGFrameRequest.h>

@interface VGSnap_MockSourceNode : NSObject <VGSourceNode>
@property(nonatomic, copy) NSString *nodeId;
@property(nonatomic, copy) NSString *nodeClass;
@property(nonatomic) VGNodeRole nodeRole;
@end

@implementation VGSnap_MockSourceNode

- (instancetype)init {
  if ((self = [super init])) {
    _nodeId    = @"vgsnap_mock_source";
    _nodeClass = @"VGSnap_MockSourceNode";
    _nodeRole  = VGNodeRoleSource;
  }
  return self;
}

// VGSourceNode
- (void)startProducing {}
- (void)stopProducing {}
- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
  return [VGFrameResult skippedWithGeneration:request.generation];
}
- (void)seekTo:(CMTime)time generation:(uint64_t)gen {}

// VGNode
- (NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError * _Nullable))completion {
  completion(nil);
}
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
  return nil;
}
@end

// ─── VGSnap_EOSSourceNode ─────────────────────────────────────────────────────
// Minimal source stub that returns endOfStream on every pullFrame: call.
// Used exclusively for the EOS production-path test.

@interface VGSnap_EOSSourceNode : NSObject <VGSourceNode>
@property(nonatomic, copy) NSString *nodeId;
@property(nonatomic, copy) NSString *nodeClass;
@property(nonatomic) VGNodeRole nodeRole;
@end

@implementation VGSnap_EOSSourceNode

- (instancetype)init {
  if ((self = [super init])) {
    _nodeId    = @"vgsnap_eos_source";
    _nodeClass = @"VGSnap_EOSSourceNode";
    _nodeRole  = VGNodeRoleSource;
  }
  return self;
}

// VGSourceNode — always signals EOS.
- (void)startProducing {}
- (void)stopProducing {}
- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
  return [VGFrameResult endOfStreamWithGeneration:request.generation];
}
- (void)seekTo:(CMTime)time generation:(uint64_t)gen {}

// VGNode
- (NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError * _Nullable))completion {
  completion(nil);
}
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
  return nil;
}
@end

// ─── VGTimelineSnapshotTest ───────────────────────────────────────────────────

@interface VGTimelineSnapshotTest : XCTestCase
@end

@implementation VGTimelineSnapshotTest

// Convenience: build a runtime with unique mocks (no shared state).
- (VanguardGraphRuntime *)makeRuntime {
  VGSnap_MockTextureRegistry *reg =
      [[VGSnap_MockTextureRegistry alloc] init];
  VGSnap_MockMethodChannel *ch =
      [[VGSnap_MockMethodChannel alloc] init];
  return [[VanguardGraphRuntime alloc]
      initWithTextureRegistry:reg
                methodChannel:(FlutterMethodChannel *)ch];
}

// Convenience: prepare a runtime with a mock VGSourceNode and wait for
// the completion callback on the main queue. Returns the prepared runtime.
// Fails the test if preparation does not succeed within 5 s.
- (VanguardGraphRuntime *)makePreparedRuntime {
  VanguardGraphRuntime *rt = [self makeRuntime];
  VGSnap_MockSourceNode *src = [[VGSnap_MockSourceNode alloc] init];

  XCTestExpectation *exp =
      [self expectationWithDescription:@"prepare"];
  [rt prepareWithSourceNode:src
                 completion:^(int64_t tid, NSError *_Nullable err) {
    XCTAssertNil(err, @"preparation must succeed");
    XCTAssertEqual(tid, 42LL);
    [exp fulfill];
  }];
  [self waitForExpectations:@[exp] timeout:5.0];
  return rt;
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. testSnapshotIsInvalidBeforePreparation
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotIsInvalidBeforePreparation {
  VanguardGraphRuntime *rt = [self makeRuntime];
  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertFalse(s.isValid,            @"snapshot must be invalid before preparation");
  XCTAssertFalse(s.isPlaying,          @"isPlaying must be NO before preparation");
  XCTAssertEqual(s.timelinePTS,        0.0);
  XCTAssertEqual(s.playStartHostTime,  0.0);
  XCTAssertEqual(s.playStartPTS,       0.0);
  XCTAssertEqual(s.generation,         0ULL);

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. testSnapshotIsValidAfterSuccessfulPreparation
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotIsValidAfterSuccessfulPreparation {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertTrue(s.isValid,   @"snapshot must be valid after successful preparation");
  XCTAssertFalse(s.isPlaying);
  XCTAssertEqual(s.timelinePTS, 0.0, @"initial PTS must be 0");
  XCTAssertEqual(s.generation,  0ULL, @"initial generation must be 0");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. testSnapshotPublishesPlayAnchorsTogether
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotPublishesPlayAnchorsTogether {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];

  // _timelinePlay must be called on the main thread.
  XCTAssertTrue([NSThread isMainThread]);
  [rt _timelinePlay];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertTrue(s.isValid);
  XCTAssertTrue(s.isPlaying);
  XCTAssertGreaterThan(s.playStartHostTime, 0.0,
                       @"host-time anchor must be a positive CACurrentMediaTime value");
  // After playing from PTS 0, basePTS was 0 at anchor time.
  XCTAssertEqual(s.playStartPTS, 0.0,
                 @"playStartPTS corresponds to timelineBasePTS at play");
  XCTAssertEqual(s.generation, 0ULL, @"play must not increment generation");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. testSnapshotPublishesPauseStateWithFrozenPTS
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotPublishesPauseStateWithFrozenPTS {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  XCTAssertTrue([NSThread isMainThread]);

  [rt _timelinePlay];

  // Inject a known PTS deterministically (no wall-clock dependency).
  rt.timelineCurrentPTS = 3.75;
  [rt _publishTimelineSnapshot];

  [rt _timelinePause];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertTrue(s.isValid);
  XCTAssertFalse(s.isPlaying);
  XCTAssertEqual(s.timelinePTS, 3.75,
                 @"paused snapshot must carry the frozen PTS");
  XCTAssertEqual(s.generation, 0ULL);

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. testSnapshotPublishesResumeAnchorsTogether
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotPublishesResumeAnchorsTogether {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  XCTAssertTrue([NSThread isMainThread]);

  [rt _timelinePlay];
  rt.timelineCurrentPTS = 7.5;
  [rt _publishTimelineSnapshot]; // update snapshot with known PTS

  [rt _timelinePause];

  // Verify paused PTS
  VGTimelineStateSnapshot paused = [rt readTimelineStateSnapshot];
  XCTAssertEqual(paused.timelinePTS, 7.5);

  // Resume: _timelinePlay sets timelineBasePTS = timelineCurrentPTS = 7.5
  [rt _timelinePlay];
  VGTimelineStateSnapshot resumed = [rt readTimelineStateSnapshot];

  XCTAssertTrue(resumed.isValid);
  XCTAssertTrue(resumed.isPlaying);
  // playStartPTS must equal the PTS at the moment of resume
  XCTAssertEqual(resumed.playStartPTS, 7.5,
                 @"playStartPTS must equal timelineBasePTS at resume");
  XCTAssertGreaterThan(resumed.playStartHostTime, 0.0);
  XCTAssertEqual(resumed.generation, 0ULL, @"resume must not increment generation");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. testSnapshotPublishesSeekWhilePausedAtomically
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotPublishesSeekWhilePausedAtomically {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];

  // Dispatch seek; seekTimelineTo: internally dispatches to main queue.
  // Since we are already on the main thread, enqueue the seek and then
  // drain via another main-queue dispatch so the seek block executes.
  XCTestExpectation *exp = [self expectationWithDescription:@"seekDrained"];
  [rt seekTimelineTo:5.25];
  // Enqueue a sentinel block: when it runs, the seek block has already run
  // (FIFO ordering on the main queue).
  dispatch_async(dispatch_get_main_queue(), ^{
    [exp fulfill];
  });
  [self waitForExpectations:@[exp] timeout:5.0];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertTrue(s.isValid);
  XCTAssertFalse(s.isPlaying);
  XCTAssertEqual(s.timelinePTS, 5.25,
                 @"timelinePTS must equal seek target");
  XCTAssertEqual(s.generation, 1ULL,
                 @"seek must increment generation exactly once");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. testSnapshotPublishesSeekWhilePlayingAtomically
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotPublishesSeekWhilePlayingAtomically {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  XCTAssertTrue([NSThread isMainThread]);

  [rt _timelinePlay];

  XCTestExpectation *exp = [self expectationWithDescription:@"seekDrained"];
  [rt seekTimelineTo:9.0];
  dispatch_async(dispatch_get_main_queue(), ^{ [exp fulfill]; });
  [self waitForExpectations:@[exp] timeout:5.0];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertTrue(s.isValid);
  XCTAssertTrue(s.isPlaying);
  XCTAssertEqual(s.timelinePTS, 9.0,
                 @"timelinePTS must equal seek target");
  XCTAssertEqual(s.playStartPTS, 9.0,
                 @"playStartPTS must be reanchored to seek target");
  XCTAssertGreaterThan(s.playStartHostTime, 0.0,
                       @"playStartHostTime must be reanchored");
  XCTAssertEqual(s.generation, 1ULL);

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. testSnapshotGenerationIncrementsExactlyOncePerSeek
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotGenerationIncrementsExactlyOncePerSeek {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];

  // Dispatch three seeks (two distinct targets + one repeated).
  [rt seekTimelineTo:1.0];
  [rt seekTimelineTo:2.0];
  [rt seekTimelineTo:2.0]; // repeated seek to same PTS must still increment

  // Drain: sentinel executes after all three seek blocks.
  XCTestExpectation *exp = [self expectationWithDescription:@"threeSeeksDrained"];
  dispatch_async(dispatch_get_main_queue(), ^{ [exp fulfill]; });
  [self waitForExpectations:@[exp] timeout:5.0];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];
  XCTAssertEqual(s.generation, 3ULL,
                 @"generation must equal number of seeks regardless of target");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. testSnapshotFieldMappingUsesTimelineBasePTSForPlayStartPTS
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotFieldMappingUsesTimelineBasePTSForPlayStartPTS {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  XCTAssertTrue([NSThread isMainThread]);

  // Inject a sentinel value that would only appear in playStartPTS if the
  // field correctly maps from timelineBasePTS (not timelineCurrentPTS).
  rt.timelineBasePTS    = 12.34;
  rt.timelineCurrentPTS = 99.99; // different value
  [rt _publishTimelineSnapshot];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertEqual(s.playStartPTS, 12.34,
                 @"playStartPTS must map from timelineBasePTS, not timelineCurrentPTS");
  XCTAssertEqual(s.timelinePTS,  99.99,
                 @"timelinePTS must map from timelineCurrentPTS");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. testSnapshotPublishesEndOfStreamStoppedState
//
// Exercises the real production VGFrameStatusEndOfStream branch inside
// _timelineDisplayLinkFired:. A dedicated EOS source node always returns
// endOfStreamWithGeneration: so the first pull drives the real EOS path.
//
// The EOS path (VanguardGraphRuntime.m ~line 2114):
//   case VGFrameStatusEndOfStream:
//     dispatch_async(main_queue, ^{
//       ss.timelineIsPlaying = NO;
//       [ss _publishTimelineSnapshot];        // <-- real publication
//       [ss.methodChannel invokeMethod:@"onTimelineEOS" ...];
//     });
//
// The test fulfills an XCTestExpectation from the mock method channel when
// @"onTimelineEOS" is received, proving the real branch ran and published.
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotPublishesEndOfStreamStoppedState {
  XCTAssertTrue([NSThread isMainThread]);

  // Build runtime with the EOS-capable channel.
  VGSnap_MockTextureRegistry *reg = [[VGSnap_MockTextureRegistry alloc] init];
  VGSnap_EOSMethodChannel *eosCh = [[VGSnap_EOSMethodChannel alloc] init];

  VanguardGraphRuntime *rt = [[VanguardGraphRuntime alloc]
      initWithTextureRegistry:reg
                methodChannel:(FlutterMethodChannel *)eosCh];

  // Prepare with the EOS source — pullFrame: always returns EOS.
  VGSnap_EOSSourceNode *eosSrc = [[VGSnap_EOSSourceNode alloc] init];
  XCTestExpectation *prepDone =
      [self expectationWithDescription:@"eosPrepare"];
  [rt prepareWithSourceNode:eosSrc
                 completion:^(int64_t tid, NSError *_Nullable err) {
    XCTAssertNil(err, @"EOS runtime preparation must succeed");
    [prepDone fulfill];
  }];
  [self waitForExpectations:@[prepDone] timeout:5.0];

  // Establish a known pre-EOS state.
  rt.timelineCurrentPTS = 4.0;
  rt.timelineGeneration = 2ULL;
  [rt _publishTimelineSnapshot];

  // Register the EOS expectation on the mock channel before starting play.
  XCTestExpectation *eosReceived =
      [self expectationWithDescription:@"onTimelineEOS"];
  eosCh.eosExpectation = eosReceived;

  // Start playing. The CADisplayLink fires during waitForExpectations:,
  // pulls the EOS source on the pull queue, and the real EOS main-queue
  // block runs — fulfilling eosReceived via the channel callback.
  [rt _timelinePlay];

  // Allow up to 5 s for the display link to fire, pull, and EOS to arrive.
  [self waitForExpectations:@[eosReceived] timeout:5.0];

  // Read the snapshot produced by the real EOS branch.
  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertTrue(s.isValid,
                @"EOS snapshot must remain valid until invalidation");
  XCTAssertFalse(s.isPlaying,
                 @"EOS branch must set isPlaying to NO");
  // PTS and generation are not mutated by the EOS branch — they must retain
  // the values published by _timelinePlay (PTS may advance by display-link
  // ticks, but generation must be exactly 2).
  XCTAssertEqual(s.generation, 2ULL,
                 @"EOS must not change generation");
  XCTAssertEqual(eosCh.lastMethod, @"onTimelineEOS",
                 @"real EOS branch must invoke onTimelineEOS on the method channel");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. testSnapshotBecomesInvalidDuringInvalidation
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotBecomesInvalidDuringInvalidation {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  XCTAssertTrue([NSThread isMainThread]);

  [rt _timelinePlay];
  rt.timelineCurrentPTS = 6.0;
  rt.timelineGeneration = 3ULL;
  [rt _publishTimelineSnapshot];

  [rt invalidate];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];

  XCTAssertFalse(s.isValid,   @"snapshot must be invalid after invalidation");
  XCTAssertFalse(s.isPlaying, @"isPlaying must be NO after invalidation");
  // Timing and generation fields are preserved for forensic readers.
  XCTAssertEqual(s.timelinePTS,  6.0,  @"last PTS is preserved after invalidation");
  XCTAssertEqual(s.generation,   3ULL, @"last generation is preserved after invalidation");
}

// ─────────────────────────────────────────────────────────────────────────────
// 12. testLatePublicationCannotRestoreValidityAfterInvalidation
//
// Directly exercises the monotonic-invalidity contract of _publishTimelineSnapshot:
// even if called on a prepared-looking runtime after invalidation, isValid
// must remain NO.
// ─────────────────────────────────────────────────────────────────────────────

- (void)testLatePublicationCannotRestoreValidityAfterInvalidation {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  XCTAssertTrue([NSThread isMainThread]);

  [rt invalidate];

  // Attempt a late publication. _publishTimelineSnapshot must detect
  // _invalidated == YES and refuse to set isValid = YES.
  [rt _publishTimelineSnapshot];

  VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];
  XCTAssertFalse(s.isValid,
                 @"_publishTimelineSnapshot must not restore isValid after invalidation");
  XCTAssertFalse(s.isPlaying,
                 @"_publishTimelineSnapshot must not restore isPlaying after invalidation");
}

// ─────────────────────────────────────────────────────────────────────────────
// 13. testSnapshotConcurrentReadersNeverObserveTornTuple
//
// Proves that readers always observe one of a finite set of exact, complete
// known tuples — not any mix of fields from different tuples.
//
// Three known tuples with mutually distinct values across all six fields:
//
//   Tuple A: PTS=10, hostTime=1000, basePTS=10, gen=100, playing=YES,  valid=YES
//   Tuple B: PTS=20, hostTime=2000, basePTS=20, gen=200, playing=YES,  valid=YES
//   Tuple C: PTS=30, hostTime=3000, basePTS=30, gen=300, playing=NO,   valid=YES
//
// Writer injects one complete tuple at a time (all fields set atomically under
// the runtime properties, then _publishTimelineSnapshot called once), then
// cycles among them for a bounded number of iterations.
//
// Reader overlap is guaranteed: readers block on startSem until the first
// writer tuple is published; the semaphore is signalled inside the first
// writer step before releasing the orchestrator loop.
//
// All reader and writer tasks are joined before the test returns.
// ─────────────────────────────────────────────────────────────────────────────

// Known-tuple descriptor — all six fields that must appear together.
typedef struct {
  double   timelinePTS;
  double   playStartHostTime;
  double   playStartPTS;
  uint64_t generation;
  BOOL     isPlaying;
  BOOL     isValid;
} VGSnapKnownTuple;

static BOOL VGSnapTupleMatches(VGTimelineStateSnapshot s,
                                VGSnapKnownTuple t) {
  return s.timelinePTS       == t.timelinePTS
      && s.playStartHostTime == t.playStartHostTime
      && s.playStartPTS      == t.playStartPTS
      && s.generation        == t.generation
      && s.isPlaying         == t.isPlaying
      && s.isValid           == t.isValid;
}

// File-scope known-tuple table for testSnapshotConcurrentReadersNeverObserveTornTuple.
// Declared at file scope so Objective-C blocks can reference the array directly
// (automatic C arrays cannot be captured by blocks).
//
//   Tuple A: PTS=10, hostTime=1000, basePTS=10, gen=100, playing=YES, valid=YES
//   Tuple B: PTS=20, hostTime=2000, basePTS=20, gen=200, playing=YES, valid=YES
//   Tuple C: PTS=30, hostTime=3000, basePTS=30, gen=300, playing=NO,  valid=YES
static const VGSnapKnownTuple kVGSnapKnownTuples[] = {
  { 10.0, 1000.0, 10.0, 100, YES, YES },  // Tuple A
  { 20.0, 2000.0, 20.0, 200, YES, YES },  // Tuple B
  { 30.0, 3000.0, 30.0, 300,  NO, YES },  // Tuple C
};
static const NSUInteger kVGSnapKnownTupleCount =
    sizeof(kVGSnapKnownTuples) / sizeof(kVGSnapKnownTuples[0]);

- (void)testSnapshotConcurrentReadersNeverObserveTornTuple {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];

  // kVGSnapKnownTuples and kVGSnapKnownTupleCount are declared at file scope
  // (above @implementation) so blocks can reference the array without capture.
  const NSInteger kWriterCycles   = 90;   // 30 full ABC cycles = 90 steps
  const NSInteger kReadsPerReader = 10000;
  const NSInteger kReaderCount    = 4;

  // Helper: inject one known tuple then publish.
  // Must be called on the main thread (runtime properties are main-thread-only).
  void (^publishTuple)(VGSnapKnownTuple) = ^(VGSnapKnownTuple t) {
    NSAssert([NSThread isMainThread], @"publishTuple must run on main thread");
    rt.timelineCurrentPTS   = t.timelinePTS;
    rt.timelinePlayStartTime = t.playStartHostTime;
    rt.timelineBasePTS      = t.playStartPTS;
    rt.timelineGeneration   = t.generation;
    rt.timelineIsPlaying    = t.isPlaying;
    [rt _publishTimelineSnapshot];
  };

  // Shared failure flag — written from reader queues.
  __block atomic_bool tornSeen = ATOMIC_VAR_INIT(false);

  // Dispatch group joins all four reader queues.
  dispatch_group_t readersGroup = dispatch_group_create();

  // Signal readers to start after the first known tuple is published.
  dispatch_semaphore_t startSem = dispatch_semaphore_create(0);

  // Launch readers (concurrent background queues — NOT main thread).
  for (NSInteger r = 0; r < kReaderCount; r++) {
    dispatch_group_enter(readersGroup);
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
          dispatch_semaphore_wait(startSem, DISPATCH_TIME_FOREVER);
          for (NSInteger i = 0; i < kReadsPerReader; i++) {
            VGTimelineStateSnapshot s = [rt readTimelineStateSnapshot];
            // Every snapshot must exactly match one of the approved tuples.
            BOOL matched = NO;
            for (NSUInteger k = 0; k < kVGSnapKnownTupleCount; k++) {
              if (VGSnapTupleMatches(s, kVGSnapKnownTuples[k])) {
                matched = YES;
                break;
              }
            }
            if (!matched) {
              atomic_store(&tornSeen, true);
            }
          }
          dispatch_group_leave(readersGroup);
        });
  }

  // Orchestrate writer from a background queue so the main thread remains
  // free to process dispatched transition blocks.
  XCTestExpectation *orchestratorDone =
      [self expectationWithDescription:@"orchestratorDone"];

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSInteger w = 0; w < kWriterCycles; w++) {
          VGSnapKnownTuple tuple = kVGSnapKnownTuples[w % kVGSnapKnownTupleCount];

          // Dispatch one complete tuple publication to main and wait for it.
          dispatch_semaphore_t stepDone = dispatch_semaphore_create(0);
          dispatch_async(dispatch_get_main_queue(), ^{
            publishTuple(tuple);
            dispatch_semaphore_signal(stepDone);
          });
          // Wait runs on the background orchestrator — NOT main thread.
          dispatch_semaphore_wait(stepDone, DISPATCH_TIME_FOREVER);

          // After the first tuple is published, release all readers.
          if (w == 0) {
            for (NSInteger r = 0; r < kReaderCount; r++) {
              dispatch_semaphore_signal(startSem);
            }
          }
        }
        [orchestratorDone fulfill];
      });

  // Allow up to 15 s for writer and readers to complete.
  [self waitForExpectations:@[orchestratorDone] timeout:15.0];
  dispatch_group_wait(readersGroup, DISPATCH_TIME_FOREVER);

  XCTAssertFalse(atomic_load(&tornSeen),
                 @"concurrent readers must only observe exact known tuples");

  [rt invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// 14. testSnapshotPublicationDoesNotChangeExistingTimelineSemantics
//
// Regression test: verify that snapshot publication is purely additive and
// does not alter the runtime's existing property behaviour.
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSnapshotPublicationDoesNotChangeExistingTimelineSemantics {
  VanguardGraphRuntime *rt = [self makePreparedRuntime];
  XCTAssertTrue([NSThread isMainThread]);

  XCTAssertFalse(rt.timelineIsPlaying, @"must start paused");

  [rt _timelinePlay];
  XCTAssertTrue(rt.timelineIsPlaying, @"timelineIsPlaying must be YES after play");
  XCTAssertEqual(rt.state, VGRuntimeStateRunning);

  [rt _timelinePause];
  XCTAssertFalse(rt.timelineIsPlaying, @"timelineIsPlaying must be NO after pause");
  XCTAssertEqual(rt.state, VGRuntimeStatePaused);

  // Seek and drain.
  XCTestExpectation *exp =
      [self expectationWithDescription:@"seekDrained"];
  [rt seekTimelineTo:2.5];
  dispatch_async(dispatch_get_main_queue(), ^{ [exp fulfill]; });
  [self waitForExpectations:@[exp] timeout:5.0];

  XCTAssertEqual(rt.timelineCurrentPTS, 2.5,
                 @"timelineCurrentPTS must be 2.5 after seek");
  XCTAssertEqual(rt.timelineGeneration, 1ULL,
                 @"timelineGeneration must be 1 after one seek");

  // Play again, then invalidate.
  [rt _timelinePlay];
  XCTAssertEqual(rt.timelineBasePTS, 2.5,
                 @"timelineBasePTS must be reanchored to seek target on play");

  [rt invalidate];
}

@end

#endif // VG_USE_V2_GRAPH
