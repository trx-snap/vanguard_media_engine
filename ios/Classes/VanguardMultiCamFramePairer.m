// VanguardMultiCamFramePairer.m
// vanguard_media_engine — MC-6: Reusable MultiCam software timestamp pairer.
//
// ── IMPLEMENTATION NOTE ──────────────────────────────────────────────────────
//
// This is a direct extraction of the nearest-neighbour pairing algorithm from
// _VanguardMC5SoftPairDelegate (VanguardMultiCamSyncDiagnostic.m, MC-5).
//
// The algorithm is identical to the proven MC-5 implementation. The only
// structural change is that the logic is now a first-class object instead of
// an Objective-C delegate, and the entry points accept raw CMTime values
// (extracted by the caller from CMSampleBufferGetPresentationTimeStamp)
// rather than CMSampleBufferRef.
//
// This decoupling means:
//   1. No AVFoundation dependency — the pairer can be unit-tested with
//      synthetic CMTime values without constructing a capture session.
//   2. No sample-buffer retention — the caller never needs to extend the
//      lifetime of a CMSampleBuffer for the sake of the pairer.
//   3. Clean separation — the pairing concern is fully isolated from
//      session lifecycle, delegate wiring, and pixel-buffer management.
//
// ── THREAD SAFETY ────────────────────────────────────────────────────────────
//
// All ivars are accessed without locks. This matches the MC-5 design where
// both front and back delegate callbacks are delivered on the SAME serial
// captureQ, making all accesses to shared pairing state implicitly safe.
//
// Future production source code (MC-7) must preserve this invariant:
// both offerFrontPTS: and offerBackPTS: must always be called from the
// same serial queue.
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamSyncDiagnostic.*     VanguardCameraMediaSource.*
//   VGCameraGraphSession.*               VanguardMediaEnginePlugin.swift
//   connectsapp_*/**                     Android code
//   Phase 8 overlay files

#import "VanguardMultiCamFramePairer.h"

// ─────────────────────────────────────────────────────────────────────────────
// Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardMultiCamFramePairer {
    // ── Pairing threshold ─────────────────────────────────────────────────────
    double _thresholdSeconds;

    // ── Raw frame counts ──────────────────────────────────────────────────────
    int32_t _frontFramesReceived;
    int32_t _backFramesReceived;

    // ── Pairing metrics ───────────────────────────────────────────────────────
    int32_t _pairedFramesReceived;
    int32_t _unmatchedFrontFrames;
    int32_t _unmatchedBackFrames;
    double  _maxDriftSeconds;
    double  _accumulatedDriftSeconds;

    // ── Software pairing state ────────────────────────────────────────────────
    //
    // The PTS of the most recently received frame from each camera that has
    // not yet found a partner. kCMTimeInvalid means "no unmatched frame pending".
    //
    // Written and read only on the owning serial queue — no locks needed.
    CMTime _lastUnmatchedFrontPTS;
    CMTime _lastUnmatchedBackPTS;
}

// ─── Designated initializer ───────────────────────────────────────────────────

- (instancetype)initWithThresholdSeconds:(double)thresholdSeconds {
    self = [super init];
    if (self) {
        _thresholdSeconds        = thresholdSeconds;
        _lastUnmatchedFrontPTS   = kCMTimeInvalid;
        _lastUnmatchedBackPTS    = kCMTimeInvalid;
        // All int32/double ivars default to 0 via Objective-C zero-init.
    }
    return self;
}

// ─── Metric properties ────────────────────────────────────────────────────────

- (int32_t)pairedFramesReceived  { return _pairedFramesReceived;  }
- (int32_t)frontFramesReceived   { return _frontFramesReceived;   }
- (int32_t)backFramesReceived    { return _backFramesReceived;    }
- (int32_t)unmatchedFrontFrames  { return _unmatchedFrontFrames;  }
- (int32_t)unmatchedBackFrames   { return _unmatchedBackFrames;   }
- (double)maxDriftSeconds        { return _maxDriftSeconds;       }
- (double)pairingThresholdSeconds { return _thresholdSeconds;     }

- (double)averageDriftSeconds {
    if (_pairedFramesReceived <= 0) return 0.0;
    return _accumulatedDriftSeconds / (double)_pairedFramesReceived;
}

// ─── offerFrontPTS: ───────────────────────────────────────────────────────────

- (BOOL)offerFrontPTS:(CMTime)pts {
    _frontFramesReceived++;

    // Non-numeric PTS: count the frame but skip pairing.
    if (!CMTIME_IS_NUMERIC(pts)) {
        return NO;
    }

    return [self _offerPTS:pts isFront:YES];
}

// ─── offerBackPTS: ────────────────────────────────────────────────────────────

- (BOOL)offerBackPTS:(CMTime)pts {
    _backFramesReceived++;

    // Non-numeric PTS: count the frame but skip pairing.
    if (!CMTIME_IS_NUMERIC(pts)) {
        return NO;
    }

    return [self _offerPTS:pts isFront:NO];
}

// ─── _offerPTS:isFront: ──────────────────────────────────────────────────────
//
// Core nearest-neighbour pairing algorithm — extracted verbatim from
// _VanguardMC5SoftPairDelegate._pairNewPTS:isFront: (MC-5).
//
// Invariant: pts is guaranteed to be CMTIME_IS_NUMERIC on entry.
// Called from the owning serial queue only.
//
// Returns YES if a pair was formed (|newPTS - otherPTS| <= threshold).

- (BOOL)_offerPTS:(CMTime)newPTS isFront:(BOOL)isFront {
    BOOL otherHasPending = isFront
        ? CMTIME_IS_NUMERIC(_lastUnmatchedBackPTS)
        : CMTIME_IS_NUMERIC(_lastUnmatchedFrontPTS);

    if (otherHasPending) {
        CMTime otherPTS = isFront ? _lastUnmatchedBackPTS
                                  : _lastUnmatchedFrontPTS;

        // Compute absolute drift in seconds.
        double drift = fabs(CMTimeGetSeconds(newPTS) - CMTimeGetSeconds(otherPTS));

        if (drift <= _thresholdSeconds) {
            // ── Paired ──────────────────────────────────────────────────────
            _pairedFramesReceived++;

            if (drift > _maxDriftSeconds) {
                _maxDriftSeconds = drift;
            }
            _accumulatedDriftSeconds += drift;

            // Clear the other pending PTS — it was consumed in this pair.
            // Do NOT store newPTS — it was also consumed.
            if (isFront) {
                _lastUnmatchedBackPTS  = kCMTimeInvalid;
            } else {
                _lastUnmatchedFrontPTS = kCMTimeInvalid;
            }
            return YES;

        } else {
            // ── Stale other frame — too far apart to pair ────────────────────
            // Count the other pending frame as unmatched and clear it.
            if (isFront) {
                _unmatchedBackFrames++;
                _lastUnmatchedBackPTS  = kCMTimeInvalid;
            } else {
                _unmatchedFrontFrames++;
                _lastUnmatchedFrontPTS = kCMTimeInvalid;
            }
            // Store the new frame as the pending unmatched on its own side.
            [self _storePendingPTS:newPTS isFront:isFront];
            return NO;
        }

    } else {
        // ── No other pending frame yet ───────────────────────────────────────
        // Store this PTS as the pending unmatched on its side.
        [self _storePendingPTS:newPTS isFront:isFront];
        return NO;
    }
}

// ─── _storePendingPTS:isFront: ────────────────────────────────────────────────
//
// Stores newPTS as the latest unmatched frame on the given side.
// If there is already a pending PTS on the same side, it is counted as
// unmatched first (the newer frame replaces it).
//
// Extracted verbatim from _VanguardMC5SoftPairDelegate._storePendingPTS:isFront:

- (void)_storePendingPTS:(CMTime)newPTS isFront:(BOOL)isFront {
    if (isFront) {
        if (CMTIME_IS_NUMERIC(_lastUnmatchedFrontPTS)) {
            // The previous front frame never found a partner.
            _unmatchedFrontFrames++;
        }
        _lastUnmatchedFrontPTS = newPTS;
    } else {
        if (CMTIME_IS_NUMERIC(_lastUnmatchedBackPTS)) {
            // The previous back frame never found a partner.
            _unmatchedBackFrames++;
        }
        _lastUnmatchedBackPTS = newPTS;
    }
}

// ─── flushPendingUnmatched ────────────────────────────────────────────────────
//
// Counts any remaining pending PTS at teardown as unmatched.
// Call after stopRunning has drained the capture queue and delegates are nil.
//
// Extracted from _VanguardMC5SoftPairDelegate.flushPendingUnmatched (MC-5).

- (void)flushPendingUnmatched {
    if (CMTIME_IS_NUMERIC(_lastUnmatchedFrontPTS)) {
        _unmatchedFrontFrames++;
        _lastUnmatchedFrontPTS = kCMTimeInvalid;
    }
    if (CMTIME_IS_NUMERIC(_lastUnmatchedBackPTS)) {
        _unmatchedBackFrames++;
        _lastUnmatchedBackPTS = kCMTimeInvalid;
    }
}

// ─── reset ────────────────────────────────────────────────────────────────────

- (void)reset {
    _frontFramesReceived     = 0;
    _backFramesReceived      = 0;
    _pairedFramesReceived    = 0;
    _unmatchedFrontFrames    = 0;
    _unmatchedBackFrames     = 0;
    _maxDriftSeconds         = 0.0;
    _accumulatedDriftSeconds = 0.0;
    _lastUnmatchedFrontPTS   = kCMTimeInvalid;
    _lastUnmatchedBackPTS    = kCMTimeInvalid;
}

// ─── metrics ──────────────────────────────────────────────────────────────────

- (NSDictionary<NSString *, NSNumber *> *)metrics {
    double avg = (_pairedFramesReceived > 0)
        ? (_accumulatedDriftSeconds / (double)_pairedFramesReceived)
        : 0.0;

    return @{
        @"pairedFramesReceived":    @(_pairedFramesReceived),
        @"frontFramesReceived":     @(_frontFramesReceived),
        @"backFramesReceived":      @(_backFramesReceived),
        @"unmatchedFrontFrames":    @(_unmatchedFrontFrames),
        @"unmatchedBackFrames":     @(_unmatchedBackFrames),
        @"maxDriftSeconds":         @(_maxDriftSeconds),
        @"averageDriftSeconds":     @(avg),
        @"pairingThresholdSeconds": @(_thresholdSeconds),
    };
}

@end
