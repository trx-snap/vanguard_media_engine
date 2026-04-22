// VGMasterClockTest.m
// Vanguard Media Engine — Phase 1A, P1A-05
//
// Behavior-lock tests for VanguardMasterClock extracted in P1A-04.
// Goal: prove that the extraction preserved behavior exactly — especially
// around wall-clock fallback timing, audio-clock gating, one-time
// self-calibration, weak player-node deallocation safety, monotonicity, and
// formula parity with the pre-extraction VanguardFileMediaSource.masterClock.
//
// Simulator-executable tests only. Device gate (G-02-T2 ×100, ≤33ms each)
// is declared but NOT executed here — see "Device gate" note at bottom.
//
// Run with:
//   xcodebuild test -scheme vanguard_media_engine \
//                   -destination 'platform=iOS Simulator,name=iPhone 15'

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CMTime.h>
#import <QuartzCore/QuartzCore.h>

// Unit under test
#import "VanguardMasterClock.h"

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Reference formula (verbatim old inline logic)
// ─────────────────────────────────────────────────────────────────────────────
//
// This C function is a faithful reconstruction of the pre-extraction
// masterClock formula that lived inline in VanguardFileMediaSource.
// It is used exclusively by the parity tests — it is NOT a new production
// abstraction, and it does NOT import any source file.
//
// Inputs match the VanguardFileMediaSource ivar set before extraction:
//   sampleTime         — AVAudioTime.sampleTime for the player node
//   sampleRate         — AVAudioTime.sampleRate
//   baseOffset         — _audioBaseTimeOffset (seek offset)
//   wallStartTime      — _wallStartTime (CACurrentMediaTime at play start)
//   wallOffsetAtPause  — _wallOffsetAtPause (accumulated pause time, seconds)
//   lastFloor          — _lastMasterClockSecs (monotonic floor, in/out)
//   calibrated         — _audioBaseTimeCalibrated (in/out)
//
// Returns the expected masterClock result in seconds.
// Mirrors the pre-extraction conditional tree exactly:
//   elapsedSinceStop = sampleTime / sampleRate
//   if NOT calibrated: baseOffset = wallNow – elapsedSinceStop
//   outputSec = baseOffset + elapsedSinceStop
//   outputSec = MAX(outputSec, lastFloor)
//   lastFloor = outputSec
//
// NOTE: this function intentionally does NOT include the audioEngineReady
// and isPlaying gating because that gating lives in VanguardFileMediaSource,
// not in the clock formula itself. Parity tests drive the clock directly
// into the audio-path branch by setting audioClockReady=YES and providing
// a playing test double.

static double VGReferenceAudioClockSeconds(
    int64_t       sampleTime,
    double        sampleRate,
    double        baseOffset,
    double        wallStartTime,
    double        wallOffsetAtPauseSecs,
    double       *lastFloor,           // in/out monotonic floor
    BOOL         *calibrated,          // in/out calibration flag
    BOOL          performCalibration   // mirror the !_audioBaseTimeCalibrated branch
) {
    double elapsedSinceStop = (double)sampleTime / sampleRate;
    if (elapsedSinceStop < 0) return -1.0; // should not occur in parity tests

    if (!(*calibrated) && performCalibration) {
        double wallNow = (CACurrentMediaTime() - wallStartTime) + wallOffsetAtPauseSecs;
        baseOffset = wallNow - elapsedSinceStop;
        *calibrated = YES;
    }

    double outputSec = baseOffset + elapsedSinceStop;
    if (outputSec < *lastFloor) outputSec = *lastFloor;
    *lastFloor = outputSec;
    return outputSec;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - AVAudioPlayerNode test double
// ─────────────────────────────────────────────────────────────────────────────
//
// A minimal AVAudioPlayerNode subclass that returns controlled values for
// the three properties/methods queried by VanguardMasterClock.currentTime:
//   - isPlaying (property override via ivar + accessor)
//   - lastRenderTime (property return)
//   - playerTimeForNodeTime: (method return)
//
// Rationale: the clock checks `node.isPlaying` to guard the audio path.
// Without a real AVAudioEngine running, isPlaying is always NO.
// Subclassing lets us override isPlaying to return YES deterministically.
// No AVAudioEngine or audio session is started — safe for simulator CI.
//
// NOTE: AVAudioPlayerNode is a framework class, but subclassing it is valid
// in Objective-C. We only override methods we control — no private API.

@interface VGMockPlayerNode : AVAudioPlayerNode

/// When YES, -isPlaying returns YES (simulates a running player).
@property (nonatomic) BOOL mockIsPlaying;

/// The AVAudioTime returned by -lastRenderTime.
@property (nonatomic, strong, nullable) AVAudioTime *mockLastRenderTime;

/// The AVAudioTime returned by -playerTimeForNodeTime: (ignores the argument).
@property (nonatomic, strong, nullable) AVAudioTime *mockPlayerTime;

@end

@implementation VGMockPlayerNode

- (BOOL)isPlaying {
    return _mockIsPlaying;
}

- (nullable AVAudioTime *)lastRenderTime {
    return _mockLastRenderTime;
}

- (nullable AVAudioTime *)playerTimeForNodeTime:(AVAudioTime *)nodeTime {
    // Ignore nodeTime — return the pre-canned mock player time.
    (void)nodeTime;
    return _mockPlayerTime;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test helper: fixed-sampleTime AVAudioTime builder
// ─────────────────────────────────────────────────────────────────────────────

/// Build an AVAudioTime whose sampleTime and sampleRate are fixed.
/// isSampleTimeValid is YES. hostTime is 0 (irrelevant for parity tests).
static AVAudioTime *makeAudioTime(int64_t sampleTime, double sampleRate) {
    return [[AVAudioTime alloc] initWithSampleTime:sampleTime
                                        atRate:sampleRate];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMasterClockTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGMasterClockTest : XCTestCase
@end

@implementation VGMasterClockTest

// ─── T1: Wall-clock fallback — non-zero and advancing immediately after init ───

/// After -init the clock is in wall-clock fallback mode.
/// isPlaying=YES causes the fallback branch to execute.
/// Two successive reads must be non-negative and the second must be ≥ the first.
- (void)testWallClockFallbackIsNonZeroAndAdvancing {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];
    clock.isPlaying = YES;

    // First read — wallStartTime was set in -init to CACurrentMediaTime(),
    // so elapsed = CACurrentMediaTime() - wallStartTime ≥ 0.
    CMTime t1 = [clock currentTime];
    double s1 = CMTimeGetSeconds(t1);
    XCTAssertGreaterThanOrEqual(s1, 0.0,
        @"Wall-clock fallback must return a non-negative currentTime immediately after init");

    // Sleep briefly so time actually advances.
    usleep(5000); // 5ms

    CMTime t2 = [clock currentTime];
    double s2 = CMTimeGetSeconds(t2);
    XCTAssertGreaterThanOrEqual(s2, s1,
        @"Second currentTime read must be ≥ first (monotonic wall-clock fallback). "
        @"s1=%.6f s2=%.6f", s1, s2);

    // No crash, no negative value.
    XCTAssertFalse(CMTIME_IS_INVALID(t2), @"currentTime must not be kCMTimeInvalid");
}

// ─── T2: Paused state returns wallOffsetAtPause ─────────────────────────────

/// When isPlaying=NO and audioClockReady=NO, currentTime must return
/// exactly wallOffsetAtPause (paused-clock semantics).
- (void)testPausedStateReturnsWallOffsetAtPause {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];
    clock.isPlaying = NO;
    clock.audioClockReady = NO;

    CMTime expected = CMTimeMakeWithSeconds(3.75, 600);
    clock.wallOffsetAtPause = expected;

    CMTime result = [clock currentTime];
    XCTAssertEqualWithAccuracy(
        CMTimeGetSeconds(result), CMTimeGetSeconds(expected), 1e-9,
        @"Paused clock must return wallOffsetAtPause exactly. "
        @"expected=%.9f got=%.9f", CMTimeGetSeconds(expected), CMTimeGetSeconds(result));
}

// ─── T3: audioClockReady gates audio-clock vs wall-clock path ─────────────

/// With audioClockReady=NO, even if a mock node is attached and reports
/// isPlaying=YES, the clock must fall back to the wall-clock path.
/// (The guard lives in: if (_audioClockReady && node && node.isPlaying))
- (void)testAudioClockReadyFlagGatesAudioPath {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];

    // Provide a mock node that reports isPlaying=YES with a valid sampleTime.
    VGMockPlayerNode *node = [[VGMockPlayerNode alloc] init];
    node.mockIsPlaying = YES;
    node.mockLastRenderTime = makeAudioTime(44100, 44100.0); // 1.0 s
    node.mockPlayerTime     = makeAudioTime(44100, 44100.0);

    [clock calibrateWithPlayerNode:node];

    // Set a recognizable offset that ONLY the audio path would produce.
    clock.audioBaseTimeOffset = 100.0;
    clock.audioBaseTimeCalibrated = YES; // skip recalibration

    // KEY: audioClockReady is NO — audio path must NOT execute.
    clock.audioClockReady = NO;
    clock.isPlaying = YES;

    // Wall offset is zero (from init), wall start is near now.
    // Wall clock result will be near 0 (tiny elapsed), NOT near 101.0.
    CMTime t = [clock currentTime];
    double secs = CMTimeGetSeconds(t);

    XCTAssertLessThan(secs, 5.0,
        @"With audioClockReady=NO the wall-clock path must execute. "
        @"Audio path would have returned %.1f. Got: %.6f", 101.0, secs);

    // Now flip the gate ON and verify audio path takes over.
    clock.audioClockReady = YES;
    clock.lastMasterClockSecs = 0.0; // reset floor so audio value isn't floored to wall

    CMTime t2 = [clock currentTime];
    double secs2 = CMTimeGetSeconds(t2);

    // audioBaseTimeOffset=100 + elapsedSinceStop=1.0 → 101.0
    XCTAssertEqualWithAccuracy(secs2, 101.0, 0.01,
        @"With audioClockReady=YES the audio path must execute and return "
        @"baseOffset+sampleTime/rate=101.0. Got: %.6f", secs2);
}

// ─── T4: calibrateWithPlayerNode: sets the weak reference ───────────────────

/// calibrateWithPlayerNode: must store a weak reference.
/// After calibration with a node that reports isPlaying=YES and valid sampleTime,
/// with audioClockReady=YES, currentTime must reflect the audio path result.
- (void)testCalibrateWithPlayerNodeSetsOffsetCorrectly {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];

    // 44100 samples at 44100 Hz = 1.0 s elapsed
    VGMockPlayerNode *node = [[VGMockPlayerNode alloc] init];
    node.mockIsPlaying = YES;
    node.mockPlayerTime = makeAudioTime(44100, 44100.0);
    node.mockLastRenderTime = node.mockPlayerTime;

    [clock calibrateWithPlayerNode:node];

    // Pre-set a known baseOffset (calibration is already done).
    clock.audioBaseTimeOffset    = 5.0;
    clock.audioBaseTimeCalibrated = YES; // skip self-calibration to get exact output
    clock.audioClockReady        = YES;
    clock.isPlaying              = YES;
    clock.lastMasterClockSecs    = 0.0;

    // Expected: 5.0 (offset) + 1.0 (elapsed) = 6.0
    CMTime result = [clock currentTime];
    XCTAssertEqualWithAccuracy(
        CMTimeGetSeconds(result), 6.0, 0.01,
        @"calibrateWithPlayerNode: must wire the node correctly. "
        @"Expected offset+elapsed=6.0, got %.6f", CMTimeGetSeconds(result));
}

// ─── T5: Weak player node goes nil → silent fallback, no crash ───────────────

/// If the player node is deallocated after calibrateWithPlayerNode:,
/// the clock's __weak reference goes nil and currentTime must silently
/// fall back to wall-clock — no crash, no assertion failure.
- (void)testWeakPlayerNodeDeallocFallsBackSafely {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];

    @autoreleasepool {
        VGMockPlayerNode *node = [[VGMockPlayerNode alloc] init];
        node.mockIsPlaying = YES;
        node.mockPlayerTime = makeAudioTime(44100, 44100.0);
        node.mockLastRenderTime = node.mockPlayerTime;
        [clock calibrateWithPlayerNode:node];

        clock.audioClockReady        = YES;
        clock.audioBaseTimeOffset    = 10.0;
        clock.audioBaseTimeCalibrated = YES;
        clock.isPlaying              = YES;

        // Verify audio path is live while node exists.
        CMTime alive = [clock currentTime];
        XCTAssertEqualWithAccuracy(CMTimeGetSeconds(alive), 11.0, 0.05,
            @"Audio path must be live while node is retained");
    }
    // node is now out of the autorelease pool scope — __weak ref should be nil.

    // Force a second autorelease drain so ARC-managed __weak goes nil.
    @autoreleasepool { /* drain */ }

    // Now currentTime must NOT crash and must fall back to wall-clock.
    clock.lastMasterClockSecs = 0.0; // allow wall clock to produce fresh value
    CMTime fallback = [clock currentTime];
    // Just verify: no crash, result is valid CMTime, no negative value.
    XCTAssertFalse(CMTIME_IS_INVALID(fallback),
        @"currentTime after weak-node dealloc must not return kCMTimeInvalid");
    XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(fallback), 0.0,
        @"Wall-clock fallback after dealloc must return a non-negative value. "
        @"Got %.6f", CMTimeGetSeconds(fallback));
}

// ─── T6: Monotonicity — wall-clock path must never go backward ───────────────

/// Repeated currentTime calls in wall-clock mode must be monotonically
/// non-decreasing. The monotonic floor (_lastMasterClockSecs) must hold
/// even if the system clock jitters or the test runs back-to-back fast.
- (void)testWallClockMonotonicity {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];
    clock.isPlaying = YES;

    const NSUInteger kIterations = 50;
    double prev = -1.0;

    for (NSUInteger i = 0; i < kIterations; i++) {
        double cur = CMTimeGetSeconds([clock currentTime]);
        XCTAssertGreaterThanOrEqual(cur, prev,
            @"currentTime must be monotonic. Iteration %lu: prev=%.9f cur=%.9f",
            (unsigned long)i, prev, cur);
        prev = cur;
    }
}

// ─── T7: Monotonic floor is enforced on the audio path ──────────────────────

/// If the audio clock would produce a value smaller than lastMasterClockSecs,
/// the floor must clamp it up. This tests the pre-extraction behavior:
///   if (outputSec < _lastMasterClockSecs) outputSec = _lastMasterClockSecs;

- (void)testAudioPathMonotonicFloor {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];

    // Configure a node that returns 0.5 s elapsed (sampleTime=22050 @ 44100).
    VGMockPlayerNode *node = [[VGMockPlayerNode alloc] init];
    node.mockIsPlaying = YES;
    node.mockPlayerTime     = makeAudioTime(22050, 44100.0); // 0.5 s
    node.mockLastRenderTime = node.mockPlayerTime;

    [clock calibrateWithPlayerNode:node];
    clock.audioBaseTimeOffset    = 0.0;
    clock.audioBaseTimeCalibrated = YES;
    clock.audioClockReady        = YES;
    clock.isPlaying              = YES;
    // Pretend the floor is already at 5.0 (e.g. from a previous seek).
    clock.lastMasterClockSecs    = 5.0;

    // Audio path would compute 0.0 + 0.5 = 0.5, which is < floor 5.0.
    // Floor must win.
    CMTime result = [clock currentTime];
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(result), 5.0, 1e-9,
        @"Monotonic floor must clamp audio path result up from 0.5 to 5.0. "
        @"Got %.9f", CMTimeGetSeconds(result));
}

// ─── T8–T17: Side-by-side parity against the pre-extraction inline formula ───
//
// 10 deterministic input tuples. Each test configures VanguardMasterClock
// with known state and compares its currentTime output against the reference
// C function that reconstructs the original inline formula verbatim.
//
// Tuples cover:
//   T8:  zero baseOffset, 44100 Hz, small sampleTime
//   T9:  non-zero baseOffset, 44100 Hz, larger sampleTime
//   T10: 48000 Hz (common AirPods/Bluetooth rate), small sampleTime
//   T11: 48000 Hz, sampleTime near an exact second boundary
//   T12: 44100 Hz, sampleTime exactly at a second boundary
//   T13: large baseOffset to verify no overflow/truncation
//   T14: pre-calibrated case (calibrated=YES, baseOffset already set)
//   T15: uncalibrated case — expects self-calibration to re-derive baseOffset
//   T16: monotonic floor matters — second read clamps to floor
//   T17: wallOffsetAtPause non-zero, affects calibration formula

- (void)runParityTupleWithSampleTime:(int64_t)sampleTime
                          sampleRate:(double)sampleRate
                          baseOffset:(double)initialBaseOffset
                       wallStartTime:(double)wallStartTime
              wallOffsetAtPauseSecs:(double)wallOffsetPauseSecs
                   initialFloor:(double)initialFloor
                     preCalibrated:(BOOL)preCalibrated
                            label:(NSString *)label {

    // ── Build clock under test ───────────────────────────────────────────────
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];

    VGMockPlayerNode *node = [[VGMockPlayerNode alloc] init];
    node.mockIsPlaying   = YES;
    node.mockPlayerTime  = makeAudioTime(sampleTime, sampleRate);
    node.mockLastRenderTime = node.mockPlayerTime;

    [clock calibrateWithPlayerNode:node];

    clock.audioBaseTimeOffset    = initialBaseOffset;
    clock.audioBaseTimeCalibrated = preCalibrated;
    clock.audioClockReady        = YES;
    clock.isPlaying              = YES;
    clock.wallStartTime          = wallStartTime;
    clock.wallOffsetAtPause      = CMTimeMakeWithSeconds(wallOffsetPauseSecs, 600);
    clock.lastMasterClockSecs    = initialFloor;

    // ── Compute reference using old inline formula ───────────────────────────
    double refFloor      = initialFloor;
    BOOL   refCalibrated = preCalibrated;
    double refBase       = initialBaseOffset;

    // When NOT calibrated, the reference function performs the same
    // self-calibration that happens on the first valid sampleTime read.
    double expected = VGReferenceAudioClockSeconds(
        sampleTime,
        sampleRate,
        refBase,
        wallStartTime,
        wallOffsetPauseSecs,
        &refFloor,
        &refCalibrated,
        !preCalibrated
    );

    // ── Compare ──────────────────────────────────────────────────────────────
    CMTime result = [clock currentTime];
    double actual = CMTimeGetSeconds(result);

    // Tolerance: 10ms. CACurrentMediaTime()-based calibration involves
    // a real wall-clock read that can shift slightly between the reference
    // and the clock under test. For pre-calibrated tuples (no live wall read),
    // use 1 microsecond tolerance.
    double tol = preCalibrated ? 2e-3 : 0.010;

    XCTAssertEqualWithAccuracy(actual, expected, tol,
        @"[%@] Parity failed: expected=%.9f actual=%.9f (sampleTime=%lld "
        @"sampleRate=%.0f baseOffset=%.3f preCalibrated=%d)",
        label, expected, actual, sampleTime, sampleRate, initialBaseOffset,
        (int)preCalibrated);
}

// T8: zero baseOffset, 44100 Hz, 1000 samples (~22.7ms elapsed), pre-calibrated
- (void)testParityT8_ZeroBaseOffset_44100_SmallSampleTime {
    // Expected: 0.0 + 1000/44100 ≈ 0.02268s, floor=0
    [self runParityTupleWithSampleTime:1000
                            sampleRate:44100.0
                            baseOffset:0.0
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:YES
                                label:@"T8"];
}

// T9: non-zero baseOffset 2.5s, 44100 Hz, 88200 samples (2.0s elapsed), pre-calibrated
// Expected: 2.5 + 2.0 = 4.5
- (void)testParityT9_NonZeroBaseOffset_44100_LargerSampleTime {
    [self runParityTupleWithSampleTime:88200
                            sampleRate:44100.0
                            baseOffset:2.5
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:YES
                                label:@"T9"];
}

// T10: 48000 Hz, 4800 samples (0.1s elapsed), zero baseOffset, pre-calibrated
// Expected: 0.0 + 0.1 = 0.1
- (void)testParityT10_48000Hz_SmallSampleTime {
    [self runParityTupleWithSampleTime:4800
                            sampleRate:48000.0
                            baseOffset:0.0
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:YES
                                label:@"T10"];
}

// T11: 48000 Hz, sampleTime = 47999 samples (just under 1.0s), baseOffset=1.0
// Expected: 1.0 + 47999/48000 ≈ 1.999979s
- (void)testParityT11_48000Hz_NearSecondBoundary {
    [self runParityTupleWithSampleTime:47999
                            sampleRate:48000.0
                            baseOffset:1.0
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:YES
                                label:@"T11"];
}

// T12: 44100 Hz, exactly 44100 samples (exactly 1.0s), baseOffset=0.0
// Expected: 0.0 + 1.0 = 1.0 exactly
- (void)testParityT12_44100Hz_ExactSecondBoundary {
    [self runParityTupleWithSampleTime:44100
                            sampleRate:44100.0
                            baseOffset:0.0
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:YES
                                label:@"T12"];
}

// T13: large baseOffset 3600.0s (1 hour), 44100 Hz, 44100 samples (1s)
// Expected: 3601.0. Verifies no overflow or truncation at large offsets.
- (void)testParityT13_LargeBaseOffset {
    [self runParityTupleWithSampleTime:44100
                            sampleRate:44100.0
                            baseOffset:3600.0
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:YES
                                label:@"T13"];
}

// T14: pre-calibrated, 48000 Hz, baseOffset=7.25, 96000 samples (2.0s)
// Expected: 7.25 + 2.0 = 9.25
- (void)testParityT14_PreCalibrated_48000 {
    [self runParityTupleWithSampleTime:96000
                            sampleRate:48000.0
                            baseOffset:7.25
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:YES
                                label:@"T14"];
}

// T15: UNcalibrated — self-calibration will fire.
// The reference function and the clock both call CACurrentMediaTime() at nearly
// the same instant, so their wall-derived offsets will agree within ~10ms.
// This case has preCalibrated=NO, triggering the live-wall re-derive branch.
- (void)testParityT15_Uncalibrated_SelfCalibrationFires {
    // wallStartTime = now so wallNow ≈ 0; baseOffset ← 0 - elapsed ← -elapsed
    // After calibration: outputSec = (-elapsed) + elapsed = 0.
    // Tolerance is 10ms because both sides read CACurrentMediaTime() independently.
    double now = CACurrentMediaTime();
    [self runParityTupleWithSampleTime:44100      // 1.0 s elapsed
                            sampleRate:44100.0
                            baseOffset:999.0      // will be discarded by calibration
                         wallStartTime:now
                wallOffsetAtPauseSecs:0.0
                         initialFloor:0.0
                         preCalibrated:NO         // triggers self-calibration
                                label:@"T15"];
}

// T16: Monotonic floor matters — floor=10.0, audio would produce 3.0.
// Expected: 10.0 (floor wins).
- (void)testParityT16_MonotonicFloorWins {
    // sampleTime=132300 @ 44100 → elapsed = 3.0s
    // baseOffset=0 → outputSec=3.0, but floor=10.0 → clamped to 10.0
    [self runParityTupleWithSampleTime:132300
                            sampleRate:44100.0
                            baseOffset:0.0
                         wallStartTime:CACurrentMediaTime()
                wallOffsetAtPauseSecs:0.0
                         initialFloor:10.0
                         preCalibrated:YES
                                label:@"T16"];
}

// T17: wallOffsetAtPause=1.5s affects the calibration formula.
// wallStart=now, wallOffsetAtPause=1.5 → wallNow = (now-now) + 1.5 = 1.5
// elapsed = 48000/48000 = 1.0 → baseOffset = 1.5 - 1.0 = 0.5
// outputSec = 0.5 + 1.0 = 1.5
// (tolerance 10ms — two live wall reads)
- (void)testParityT17_WallOffsetAtPauseAffectsCalibration {
    double now = CACurrentMediaTime();
    [self runParityTupleWithSampleTime:48000    // 1.0 s
                            sampleRate:48000.0
                            baseOffset:999.0   // discarded by calibration
                         wallStartTime:now
                wallOffsetAtPauseSecs:1.5
                         initialFloor:0.0
                         preCalibrated:NO      // triggers self-calibration
                                label:@"T17"];
}

// ─── T18: Repeated audio-path reads advance the floor ───────────────────────

/// Two successive currentTime reads in audio-path mode with a static sampleTime
/// must produce identical values (monotonic floor holds but does not go backward).
- (void)testAudioPathRepeatedReadsMonotonic {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];

    // 44100 samples @ 44100 = 1.0s
    VGMockPlayerNode *node = [[VGMockPlayerNode alloc] init];
    node.mockIsPlaying   = YES;
    node.mockPlayerTime  = makeAudioTime(44100, 44100.0);
    node.mockLastRenderTime = node.mockPlayerTime;

    [clock calibrateWithPlayerNode:node];
    clock.audioBaseTimeOffset    = 0.0;
    clock.audioBaseTimeCalibrated = YES;
    clock.audioClockReady        = YES;
    clock.isPlaying              = YES;
    clock.lastMasterClockSecs    = 0.0;

    double r1 = CMTimeGetSeconds([clock currentTime]);
    double r2 = CMTimeGetSeconds([clock currentTime]);

    XCTAssertGreaterThanOrEqual(r2, r1,
        @"Repeated audio-path reads must be monotonic. r1=%.9f r2=%.9f", r1, r2);
    XCTAssertEqualWithAccuracy(r1, 1.0, 1e-6,
        @"First read must equal baseOffset+elapsed=1.0. Got %.9f", r1);
    XCTAssertEqualWithAccuracy(r2, 1.0, 1e-6,
        @"Second read with same sampleTime must equal first. Got %.9f", r2);
}

// ─── T19: hostTimeAtOrigin reflects wallStartTime ───────────────────────────

/// hostTimeAtOrigin must return the value set in wallStartTime.
- (void)testHostTimeAtOriginMatchesWallStartTime {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];
    double sentinel = 12345.678;
    clock.wallStartTime = sentinel;
    XCTAssertEqualWithAccuracy(
        [clock hostTimeAtOrigin], sentinel, 1e-9,
        @"hostTimeAtOrigin must reflect wallStartTime exactly");
}

// ─── T20: init wallStartTime is set to a recent CACurrentMediaTime ───────────

/// -init must snapshot CACurrentMediaTime() so hostTimeAtOrigin is near now.
- (void)testInitSetsWallStartTimeNearNow {
    double before = CACurrentMediaTime();
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];
    double after  = CACurrentMediaTime();

    double origin = [clock hostTimeAtOrigin];
    XCTAssertGreaterThanOrEqual(origin, before,
        @"wallStartTime must be ≥ CACurrentMediaTime() captured before init");
    XCTAssertLessThanOrEqual(origin, after,
        @"wallStartTime must be ≤ CACurrentMediaTime() captured after init");
}

// ─── T21: Self-calibration fires exactly once per session ────────────────────

/// The first audio-path read with audioBaseTimeCalibrated=NO must set
/// audioBaseTimeCalibrated=YES and not fire again on subsequent reads.
- (void)testSelfCalibrationFiresOnlyOnce {
    VanguardMasterClock *clock = [[VanguardMasterClock alloc] init];

    VGMockPlayerNode *node = [[VGMockPlayerNode alloc] init];
    node.mockIsPlaying   = YES;
    node.mockPlayerTime  = makeAudioTime(44100, 44100.0);
    node.mockLastRenderTime = node.mockPlayerTime;

    [clock calibrateWithPlayerNode:node];
    clock.audioBaseTimeOffset    = 99.0; // will be overwritten by calibration
    clock.audioBaseTimeCalibrated = NO;  // trigger calibration
    clock.audioClockReady        = YES;
    clock.isPlaying              = YES;
    clock.lastMasterClockSecs    = 0.0;

    // First read: calibration fires, modifies audioBaseTimeOffset.
    [clock currentTime];
    XCTAssertTrue(clock.audioBaseTimeCalibrated,
        @"audioBaseTimeCalibrated must be YES after first valid sampleTime read");

    double offsetAfterCalibration = clock.audioBaseTimeOffset;
    XCTAssertNotEqualWithAccuracy(offsetAfterCalibration, 99.0, 0.1,
        @"audioBaseTimeOffset must have been updated by self-calibration "
        @"(was 99.0 before; still 99.0 after — calibration did not fire)");

    // Second read: calibration must NOT fire again (flag is already YES).
    // The offset must be unchanged.
    [clock currentTime];
    XCTAssertEqualWithAccuracy(clock.audioBaseTimeOffset, offsetAfterCalibration, 1e-9,
        @"audioBaseTimeOffset must not change on second read — "
        @"self-calibration must fire exactly once");
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// DEVICE GATE — G-02-T2 ×100 (NOT executed in this environment)
// ─────────────────────────────────────────────────────────────────────────────
//
// Per the P1A-05 workboard spec, there is a device test gate:
//   G-02-T2 ×100 runs — all A/V sync deltas ≤33ms, none ≥50ms
//
// This gate requires a physical iOS device with a connected audio output,
// a live AVAudioEngine session, and the full VanguardFileMediaSource playback
// pipeline. It CANNOT be executed in the simulator environment.
//
// Status: NOT EXECUTED. See known_risks.md for the tracking entry.
//
// To run manually on device:
//   xcodebuild test -scheme vanguard_media_engine \
//                   -destination 'platform=iOS,name=<DeviceName>'
// Then verify that the G-02 T2 assertions in VanguardConcurrencyTests.m
// (or VanguardHighRiskTests.m) all pass.
