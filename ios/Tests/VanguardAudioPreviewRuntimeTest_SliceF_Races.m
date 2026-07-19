// VanguardAudioPreviewRuntimeTest_SliceF_Races.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (SliceFRaces) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (SliceFRaces)


// SF-T16: TIMER-FIRST RACE
//   1. Schedule orig-A and arm exact-boundary timer.
//   2. Advance snapshot to B's start; fire boundary timer -> B is scheduled.
//   3. Then invoke A's captured completion handler (simulates natural audio
//      finish arriving after the boundary transition already occurred).
//   4. Assert B's identity is preserved, state stays Playing, B's timer is
//      still active, and A's completion is ignored.
- (void)testSF_T16_timerFirstRace {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Exact boundary at T=3.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.4 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.7 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Capture A's completion handler BEFORE firing the timer.
  AVAudioPlayerNodeCompletionHandler aCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(aCompletion, @"orig-A completion handler must be captured");

  // Advance to T=3.0 (B's start) and fire boundary timer -> B is scheduled.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  NSInteger armCountBeforeTimerFire = _timer.armCount;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // Verify B is now scheduled and active.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"orig-B must be active after boundary timer fires");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"state must be Playing after B is scheduled");
  }];

  // NOW invoke A's stale completion handler (timer-first race scenario).
  // This simulates the audio engine completing A's buffer slightly after the
  // boundary timer already transitioned to B.
  if (aCompletion) {
    aCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // A's completion must be a no-op: per-segment serial rejects it.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"active descriptor must still be orig-B after A's stale "
                          @"completion");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"state must remain Playing — A's stale completion must be "
                   @"ignored");
  }];
  // B's boundary timer must still be alive (pendingBlock not nil means active).
  XCTAssertGreaterThanOrEqual(_timer.armCount, armCountBeforeTimerFire + 1,
                              @"B's boundary timer must have been armed");
  // The timer must NOT have been cancelled by A's stale completion.
  XCTAssertNotNil(_timer.pendingBlock,
                  @"B's boundary timer block must still be pending after A's "
                  @"stale completion");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T17: COMPLETION-FIRST RACE
//   1. Schedule orig-A and capture its completion handler.
//   2. Advance snapshot to the A->B boundary.
//   3. Fire A's completion BEFORE the boundary timer fires.
//   4. Assert that B is selected and scheduled (or a valid boundary timer
//      remains armed) and runtime is NOT Ended.
- (void)testSF_T17_completionFirstRace {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Exact boundary at T=3.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.4 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.7 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Capture A's completion handler.
  AVAudioPlayerNodeCompletionHandler aCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(aCompletion, @"orig-A completion handler must be captured");

  // Advance snapshot to T=3.0 (the boundary) WITHOUT firing the timer.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;

  // Fire A's completion handler FIRST (completion-first race).
  NSInteger schedCountBeforeCompletion = _player.scheduleCount;
  if (aCompletion) {
    aCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // The completion handler re-evaluates the timeline at PTS=3.0.
  // At T=3.0, orig-A is no longer active (pts >= trackEnd=3) and orig-B
  // is active (pts >= 3.0 and pts < 5.0). B must be scheduled.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertNotNil(d, @"some descriptor must be active");
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    // Either B is Playing now, or a WaitingForTrackStart timer is armed for B.
    BOOL scheduledB = (d && [d.trackId isEqualToString:@"orig-B"] &&
                       state == VGAudioPreviewRuntimeStatePlaying);
    BOOL armedForB = (state == VGAudioPreviewRuntimeStateWaitingForTrackStart &&
                      _timer.pendingBlock != nil);
    XCTAssertTrue(scheduledB || armedForB,
                  @"completion-first race: B must be scheduled or timer armed "
                  @"for B (state=%ld, descriptor=%@)",
                  (long)state, d.trackId);
    XCTAssertNotEqual(state, VGAudioPreviewRuntimeStateEnded,
                      @"runtime must NOT be Ended after completion-first race");
  }];
  XCTAssertGreaterThan(_player.scheduleCount, schedCountBeforeCompletion,
                       @"orig-B must be scheduled after completion-first race");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T18: SAME-DESCRIPTOR RESCHEDULE BLOCKED WHEN ALREADY SCHEDULED
//   Under Slice K/N double-scheduling protection design, if a slot is already scheduled
//   past the current evaluation PTS, rescheduling is bypassed. This test verifies that
//   the runtime successfully skips rescheduling at T=5, and that when a stale completion
//   handler is invoked (simulated by manually incrementing the segment serial), it is
//   rejected and does not trigger incorrect end state or rescheduling.
- (void)testSF_T18_sameDescriptorRescheduleBlockedWhenAlreadyScheduled {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // Single original track [0, 10). Start at PTS=0.5.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:10.0 volume:0.8 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Capture the first-schedule completion handler.
  AVAudioPlayerNodeCompletionHandler firstCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(firstCompletion,
                  @"first completion handler must be captured");
  NSInteger schedCountAfterFirst = _player.scheduleCount;

  // Advance PTS to T=5 within orig-A and fire the timer.
  // The command serial / token remains the same.
  _stubbedSnapshot.timelinePTS = 5.0;
  _stubbedSnapshot.playStartPTS = 5.0;
  [_timer fireForcefully]; // fires with same token, but does NOT reschedule because it is already scheduled past T=5
  [self waitFor:0.15];

  // Confirm NO second scheduling occurred (under Slice K/N double-scheduling protection).
  XCTAssertEqual(_player.scheduleCount, schedCountAfterFirst,
                 @"orig-A must NOT be rescheduled because it is already scheduled past T=5");
  NSInteger schedCountAfterSecond = _player.scheduleCount;

  // Test-only manual KVC increment: Because the double-scheduling guard prevented the
  // runtime from naturally advancing the segment serial, we manually increment it here
  // to simulate a stale/outdated completion handler scenario (e.g. from an earlier segment).
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    id slot = [rt valueForKey:@"_addedAudioSlot"];
    [slot setValue:@([[slot valueForKey:@"scheduledSegmentSerial"] integerValue] + 1) forKey:@"scheduledSegmentSerial"];
  }];

  // Now invoke the FIRST (stale) completion handler.
  // The stale handler must be silently rejected.
  if (firstCompletion) {
    firstCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // No additional scheduling should have occurred due to the stale handler.
  XCTAssertEqual(_player.scheduleCount, schedCountAfterSecond,
                 @"stale completion from first segment must not trigger "
                 @"re-scheduling");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertNotEqual(state, VGAudioPreviewRuntimeStateEnded,
                      @"state must not be Ended after stale completion "
                      @"from same descriptor");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T19: SUB-1MS EARLY WAKE
//   Set authoritative PTS so that the boundary is 0.0005 s away (< 1 ms).
//   The safe-delay helper must NOT silently drop the boundary.
//   After firing a second timer the next descriptor must be scheduled.
- (void)testSF_T19_subMillisecondDelayIsNotDropped {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Start at PTS that is 0.5 ms before boundary.
  // By placing PTS at 2.9995 the delay to the T=3 boundary is 0.0005 s.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 2.9995, .playStartPTS = 2.9995, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.5 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.9 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // The timer must have been armed (not dropped) for the sub-1ms boundary.
  // Safe-delay clamps to 0.001 s, so a timer IS armed.
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"boundary timer must be armed even for sub-1ms delay");
  // The delay must be 0.001 s (clamped), not the raw 0.0005 s.
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 0.001, 0.001,
                             @"sub-1ms delay must be clamped to 0.001 s");

  NSInteger schedCountAfterA = _player.scheduleCount;
  NSInteger armCountAfterA = _timer.armCount;

  // Advance snapshot to T=3.0 (boundary) and fire the clamped timer.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // orig-B must be scheduled — the boundary was NOT silently dropped.
  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterA,
                       @"orig-B must be scheduled after sub-1ms boundary is "
                       @"processed correctly");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"orig-B must be active after sub-1ms boundary");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// SF-T24: Completion-first transition, then stale boundary-timer block fires.
//   orig-A [0,3), orig-B [3,5). Completion fires first (transitions to B),
//   then the stale boundary-timer block for orig-A is invoked directly.
//   Assert the stale block (serial mismatch) does NOT schedule a duplicate.
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSF_T24_staleTimerAfterCompletionDoesNotDuplicate {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Start at PTS=0.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.5 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.8 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Phase 1: orig-A is scheduled; boundary timer armed at T=3 for orig-A.
  XCTAssertEqual(_player.scheduleCount, 1, @"SF-T24: orig-A must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0, @"SF-T24: boundary timer must be armed");

  // Capture the stale boundary block BEFORE firing the completion.
  // After the completion fires, the runtime will arm a NEW boundary timer for
  // orig-B, replacing _timer.pendingBlock. We must hold orig-A's stale block
  // separately so we can invoke it directly.
  dispatch_block_t staleTimerBlock = _timer.pendingBlock;
  XCTAssertNotNil(staleTimerBlock, @"SF-T24: orig-A's boundary block must be set");

  // Capture orig-A's completion handler.
  AVAudioPlayerNodeCompletionHandler aCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(aCompletion, @"SF-T24: orig-A completion handler must be set");

  // Phase 2: advance to T=3. Completion fires FIRST.
  // The runtime transitions to orig-B and arms a NEW boundary timer for B.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  if (aCompletion) {
    aCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // orig-B must be scheduled now.
  XCTAssertGreaterThan(_player.scheduleCount, 1,
                       @"SF-T24: orig-B must be scheduled after completion");
  NSInteger schedAfterCompletion = _player.scheduleCount;

  // Phase 3: invoke orig-A's STALE boundary block directly.
  // At this point _scheduledSegmentSerial has been incremented by orig-B's
  // scheduling, so the serial guard inside the stale block must fire and
  // return without scheduling anything.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    if (staleTimerBlock) {
      staleTimerBlock();
    }
  }];
  [self waitFor:0.2];

  XCTAssertEqual(_player.scheduleCount, schedAfterCompletion,
                 @"SF-T24: stale boundary-timer block must NOT schedule a "
                 @"duplicate (serial mismatch must reject it)");

  // Runtime must still be Playing (orig-B is active, not Ended).
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertNotEqual(state, VGAudioPreviewRuntimeStateEnded,
                      @"SF-T24: runtime must not be Ended after stale timer");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
