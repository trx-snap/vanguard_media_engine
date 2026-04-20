// VanguardMasterClock.m
// Vanguard Media Engine — Phase 1A, P1A-04
//
// Concrete implementation extracted verbatim from VanguardFileMediaSource.masterClock.
// All formulas, conditionals, and comments are preserved exactly as they appeared
// in the pre-extraction code. No behavioral changes. Structural extraction only.
//
// EXTRACTION SUMMARY — state moved from VanguardFileMediaSource ivars:
//   _audioBaseTimeOffset      → self.audioBaseTimeOffset
//   _audioClockReady          → self.audioClockReady
//   _audioBaseTimeCalibrated  → self.audioBaseTimeCalibrated
//   _wallStartTime            → self.wallStartTime
//   _wallOffsetAtPause        → self.wallOffsetAtPause
//   _lastMasterClockSecs      → self.lastMasterClockSecs
//
// VanguardFileMediaSource retains:
//   _audioEngineReady  — engine lifecycle, not clock logic
//   _playerNode        — audio hardware, not clock logic
//   _isPlaying         — playback state, forwarded to clock via .isPlaying
//
// NOT WIRED to any production code path yet. VanguardFileMediaSource.masterClock
// and .currentTime delegate to this object. No plugin, graph runtime, or Dart
// changes. (Phase 1B wiring: P1B-01.)

#import "VanguardMasterClock.h"
#import <QuartzCore/QuartzCore.h>  // CACurrentMediaTime

@implementation VanguardMasterClock {
    // Weak reference to player node — ADR-009 (prevents retain cycle when
    // VanguardFileMediaSource is torn down while the clock still exists).
    __weak AVAudioPlayerNode *_playerNode;
}

// Synthesise all settable properties explicitly so write-sites in
// VanguardFileMediaSource can assign them directly.
@synthesize audioBaseTimeOffset    = _audioBaseTimeOffset;
@synthesize audioClockReady        = _audioClockReady;
@synthesize audioBaseTimeCalibrated = _audioBaseTimeCalibrated;
@synthesize wallStartTime          = _wallStartTime;
@synthesize wallOffsetAtPause      = _wallOffsetAtPause;
@synthesize lastMasterClockSecs    = _lastMasterClockSecs;
@synthesize isPlaying              = _isPlaying;
@synthesize rate                   = _rate;

// ─── Init ─────────────────────────────────────────────────────────────────────

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // Wall-clock fallback must be active from creation (RR-5):
    // snapshot the current time so currentTime returns a valid advancing value
    // immediately, before calibrateWithPlayerNode: is ever called.
    _wallStartTime       = CACurrentMediaTime();
    _wallOffsetAtPause   = kCMTimeZero;
    _audioBaseTimeOffset = 0.0;
    _lastMasterClockSecs = 0.0;
    _rate                = 1.0;
    // _audioClockReady and _audioBaseTimeCalibrated default to NO (BOOL zero-init).

    return self;
}

// ─── VGMasterClock — calibration ──────────────────────────────────────────────

- (void)calibrateWithPlayerNode:(AVAudioPlayerNode *)playerNode {
    // Store __weak to prevent retain cycle (ADR-009).
    _playerNode = playerNode;
}

// ─── VGMasterClock — hostTimeAtOrigin ─────────────────────────────────────────

- (double)hostTimeAtOrigin {
    // Returns the wall-start time that was most recently set, which corresponds
    // to when the current play session began. 0.0 before any session starts.
    return _wallStartTime;
}

// ─── VGMasterClock — currentTime ──────────────────────────────────────────────
//
// VERBATIM EXTRACTION from VanguardFileMediaSource.masterClock (P2-T1 core).
// All formulas, branch conditions, and monotonic-floor logic are preserved
// exactly as they appeared before extraction.
//
// Thread safety: main thread only (mirrors pre-extraction threading model).

- (CMTime)currentTime {
    // ── Primary path: AVAudioPlayerNode sample time ────────────────────────
    // _audioClockReady guards this path: it is only YES after [_playerNode play]
    // has FULLY RETURNED on its background thread, meaning the internal
    // AVAudioPlayerNode lock is no longer held. Querying lastRenderTime /
    // playerTimeForNodeTime before that point risks a main-thread lock contention
    // that blocks Flutter's event loop and starves Dart timers.
    //
    // NOTE: _audioEngineReady is checked by VanguardFileMediaSource before
    // calling currentTime on this clock, so we mirror the same guard here
    // by testing audioClockReady (which is only set to YES after the engine
    // is ready AND playing).
    AVAudioPlayerNode *node = _playerNode; // strong capture from __weak
    if (_audioClockReady && node && node.isPlaying) {
        AVAudioTime *nodeTime =
            [node playerTimeForNodeTime:[node lastRenderTime]];
        if (nodeTime && nodeTime.isSampleTimeValid && nodeTime.sampleRate > 0) {
            double elapsedSinceStop =
                (double)nodeTime.sampleTime / nodeTime.sampleRate;
            if (elapsedSinceStop >= 0) {
                // ONE-TIME SELF-CALIBRATION ────────────────────────────────────
                // On the first valid sampleTime observation after play() starts,
                // recompute _audioBaseTimeOffset so that (offset + sampleTime/rate)
                // equals the current wall clock.  This absorbs the variable hardware
                // startup latency (10–31ms per run) that exists between:
                //   • [_playerNode play] returning (where we previously set the offset)
                //   • the first PCM sample reaching the DAC (where sampleTime starts)
                // Without this, the clock is systematically behind wall by that
                // latency, causing T2 to flake 12–41ms depending on system load. After
                // calibration: delta = sampleTime quantization only (~6ms max).
                if (!_audioBaseTimeCalibrated) {
                    double wallNow = (CACurrentMediaTime() - _wallStartTime) +
                                     CMTimeGetSeconds(_wallOffsetAtPause);
                    _audioBaseTimeOffset = wallNow - elapsedSinceStop;
                    _audioBaseTimeCalibrated = YES;
                }
                double outputSec = _audioBaseTimeOffset + elapsedSinceStop;

                // Enforce monotonic output — use dedicated floor, NOT _currentTime
                // (_currentTime is the seek-position ivar; writing it here caused
                //  cross-path contamination that made the clock run at 2× wall speed)
                if (outputSec < _lastMasterClockSecs)
                    outputSec = _lastMasterClockSecs;
                _lastMasterClockSecs = outputSec;
                return CMTimeMakeWithSeconds(outputSec, 600);
            }
        }
    }

    // ── Fallback: wall clock (video-only, or before first audio frame) ─────
    if (_isPlaying) {
        double elapsed = (CACurrentMediaTime() - _wallStartTime) +
                         CMTimeGetSeconds(_wallOffsetAtPause);
        // Enforce monotonic output — do not use _currentTime here; that is the
        // seek-position ivar and must not be contaminated by clock reads.
        if (elapsed < _lastMasterClockSecs)
            elapsed = _lastMasterClockSecs;
        _lastMasterClockSecs = elapsed;
        return CMTimeMakeWithSeconds(elapsed, 600);
    }

    return _wallOffsetAtPause;
}

@end
