// VanguardAudioPreviewRuntimeTest_SliceN_Recovery.m
// Vanguard Media Engine — Audio Slice N
//
// Category (SliceNRecovery) on VanguardAudioPreviewRuntimeTest.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

@implementation VanguardAudioPreviewRuntimeTest (SliceNRecovery)

- (void)testSliceN_recoveryAudibleStateRestartsEngine {
    // 1. Create runtime in ReadySilent or audible state.
    // ReadySilent is a quick way to test recovery no-op.
    VanguardAudioPreviewRuntime *rt = [self makeRuntime];

    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
        NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
        XCTAssertEqual(state, VGAudioPreviewRuntimeStateUnprepared);
    }];

    // Let's stub snapshot for a prepared state
    double sr = 44100.0, fileDur = 5.0;
    AVAudioFramePosition totalFrames = (AVAudioFramePosition)(fileDur * sr);
    NSURL *url = VGAPrCreateTempWAVURL(totalFrames, sr);
    if (!url) {
        XCTSkip(@"temp WAV needed for Slice N recovery test");
        return;
    }

    NSError *openErr = nil;
    _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&openErr];
    if (!_fileProvider.stubbedFile) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        XCTSkip(@"could not open WAV for Slice N recovery test");
        return;
    }

    _stubbedSnapshot = (VGTimelineStateSnapshot){
        .timelinePTS       = 1.0,
        .playStartPTS      = 1.0,
        .playStartHostTime = 0.0,
        .generation        = 1,
        .isPlaying         = YES,
        .isValid           = YES,
    };

    NSDictionary *trackDict = [self trackDictWithStartTime:1.0 duration:3.0 volume:1.0];
    VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                                          volumeKeyframes:nil
                                                            waveformCache:nil
                                                     timeRemapAudioPolicy:nil];

    VGAudioPreviewPreparationResult prep = [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
    XCTAssertEqual(prep, VGAudioPreviewPreparationResultReady);

    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
        NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
        XCTAssertEqual(state, VGAudioPreviewRuntimeStatePaused);
    }];

    // 2. Trigger recovery after session transition
    XCTestExpectation *exp = [self expectationWithDescription:@"recovery completion"];
    _engine.shouldFailStart = NO;

    [rt commandRecoverAfterSessionTransitionWithCompletion:^(NSError * _Nullable error) {
        XCTAssertNil(error);
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:2.0];
    XCTAssertEqual(self->_engine.stopCount, 1);
    XCTAssertEqual(self->_engine.prepareCount, 2); // 1 during prepare/init, 1 during recovery
    XCTAssertEqual(self->_engine.startCount, 2); // 1 during prepare/init, 1 during recovery

    [self invalidateAndWait:rt];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

- (void)testSliceN_recoveryEngineFailureHandlesError {
    VanguardAudioPreviewRuntime *rt = [self makeRuntime];

    double sr = 44100.0, fileDur = 5.0;
    AVAudioFramePosition totalFrames = (AVAudioFramePosition)(fileDur * sr);
    NSURL *url = VGAPrCreateTempWAVURL(totalFrames, sr);
    if (!url) {
        XCTSkip(@"temp WAV needed for Slice N recovery test");
        return;
    }

    NSError *openErr = nil;
    _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&openErr];

    _stubbedSnapshot = (VGTimelineStateSnapshot){
        .timelinePTS       = 1.0,
        .playStartPTS      = 1.0,
        .playStartHostTime = 0.0,
        .generation        = 1,
        .isPlaying         = YES,
        .isValid           = YES,
    };

    NSDictionary *trackDict = [self trackDictWithStartTime:1.0 duration:3.0 volume:1.0];
    VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                                          volumeKeyframes:nil
                                                            waveformCache:nil
                                                     timeRemapAudioPolicy:nil];

    VGAudioPreviewPreparationResult prep = [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
    XCTAssertEqual(prep, VGAudioPreviewPreparationResultReady);

    // Make engine start fail during recovery
    _engine.shouldFailStart = YES;

    XCTestExpectation *exp = [self expectationWithDescription:@"recovery failure completion"];
    [rt commandRecoverAfterSessionTransitionWithCompletion:^(NSError * _Nullable error) {
        XCTAssertNotNil(error);
        XCTAssertEqual(error.code, VGAudioPreviewRecoveryErrorEngineStartFailed);
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:2.0];

    [self invalidateAndWait:rt];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// ── Slice N engine-stop guard: commandPlay restarts a stopped engine ───────────
//
// Simulates the physical failure: engine was stopped asynchronously by the OS
// after commandRecoverAfterSessionTransition completed, then the user taps Play.
// commandPlay must detect _engine.isRunning == NO and restart+reschedule.

- (void)testSliceN_commandPlay_restartsStoppedEngine {
    double sr = 44100.0, fileDur = 5.0;
    AVAudioFramePosition frames = (AVAudioFramePosition)(fileDur * sr);
    NSURL *url = VGAPrCreateTempWAVURL(frames, sr);
    if (!url) { XCTSkip(@"temp WAV needed"); return; }

    NSError *openErr = nil;
    _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&openErr];
    if (!_fileProvider.stubbedFile) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        XCTSkip(@"could not open WAV");
        return;
    }

    // Snapshot: playing at PTS 1.0 with track starting at 0.0 (so PTS is inside track).
    _stubbedSnapshot = (VGTimelineStateSnapshot){
        .timelinePTS       = 1.0,
        .playStartPTS      = 1.0,
        .playStartHostTime = CACurrentMediaTime(),
        .generation        = 1,
        .isPlaying         = YES,
        .isValid           = YES,
    };

    NSDictionary *trackDict = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
    VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                                          volumeKeyframes:nil
                                                            waveformCache:nil
                                                     timeRemapAudioPolicy:nil];
    VanguardAudioPreviewRuntime *rt = [self makeRuntime];
    VGAudioPreviewPreparationResult prep = [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
    XCTAssertEqual(prep, VGAudioPreviewPreparationResultReady);

    // After prepare the mock engine is running (simulatedRunning=YES from start call).
    // Simulate the OS silently stopping the engine (iounit configuration changed).
    _engine.simulatedRunning = NO;
    NSInteger startCountBeforePlay = _engine.startCount;

    // commandPlay must detect the stopped engine and restart it.
    XCTestExpectation *exp = [self expectationWithDescription:@"play dispatched"];
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
        [rt commandPlay]; // dispatches async — fulfill after queue drains
        dispatch_async(dispatch_get_main_queue(), ^{ [exp fulfill]; });
    }];
    // commandPlay is async; drain the queue.
    [self waitForExpectations:@[exp] timeout:2.0];

    // Give the scheduler queue one more pass to process commandPlay.
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

    // Engine must have been restarted and segment scheduled.
    XCTAssertGreaterThan(_engine.startCount, startCountBeforePlay,
                         @"commandPlay must restart a stopped engine");
    XCTAssertGreaterThan(_player.scheduleCount, 0,
                         @"commandPlay must schedule audio after engine restart");
    XCTAssertGreaterThan(_player.playCount, 0,
                         @"commandPlay must call play after scheduling");

    [self invalidateAndWait:rt];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// ── Slice N engine-stop guard: stale scheduledEndPTS cleared on engine stop ───
//
// After a successful commandRecoverAfterSessionTransition the engine scheduled
// buffers (scheduledEndPTS > 0). Simulate the OS stopping the engine and
// posting AVAudioEngineConfigurationChangeNotification, then confirm that
// scheduledEndPTS is reset to 0 on both slots so the next commandPlay does not
// falsely think the lane is still buffered.

- (void)testSliceN_configChangeNotification_clearsStaleScheduledEndPTS {
    double sr = 44100.0, fileDur = 5.0;
    AVAudioFramePosition frames = (AVAudioFramePosition)(fileDur * sr);
    NSURL *url = VGAPrCreateTempWAVURL(frames, sr);
    if (!url) { XCTSkip(@"temp WAV needed"); return; }

    NSError *openErr = nil;
    _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&openErr];
    if (!_fileProvider.stubbedFile) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        XCTSkip(@"could not open WAV");
        return;
    }

    // Snapshot: paused (simulating state after stop-recording recovery completed).
    _stubbedSnapshot = (VGTimelineStateSnapshot){
        .timelinePTS       = 2.0,
        .playStartPTS      = 0.0,
        .playStartHostTime = 0.0,
        .generation        = 2,
        .isPlaying         = NO,
        .isValid           = YES,
    };

    NSDictionary *trackDict = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
    VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                                          volumeKeyframes:nil
                                                            waveformCache:nil
                                                     timeRemapAudioPolicy:nil];
    VanguardAudioPreviewRuntime *rt = [self makeRuntime];
    VGAudioPreviewPreparationResult prep = [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
    XCTAssertEqual(prep, VGAudioPreviewPreparationResultReady);

    // Artificially set scheduledEndPTS > 0 on the added audio slot to simulate
    // stale state left by a recovery that scheduled buffers before the OS stopped
    // the engine.
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
        id addedSlot = [rt valueForKey:@"_addedAudioSlot"];
        [addedSlot setValue:@9.0 forKey:@"scheduledEndPTS"]; // stale value from prior scheduling
    }];

    // Post the configuration-change notification (on main thread — dispatcher
    // will route to scheduler queue internally).
    [[NSNotificationCenter defaultCenter]
        postNotificationName:AVAudioEngineConfigurationChangeNotification
                      object:nil];

    // Drain the scheduler queue so the notification handler runs.
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

    // scheduledEndPTS must be cleared because the engine was stopped and buffers
    // were flushed.
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
        id addedSlot = [rt valueForKey:@"_addedAudioSlot"];
        double endPTS = [[addedSlot valueForKey:@"scheduledEndPTS"] doubleValue];
        XCTAssertEqual(endPTS, 0.0,
                       @"scheduledEndPTS must be cleared after engine config change");
    }];

    [self invalidateAndWait:rt];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end

#endif // VG_USE_V2_GRAPH
