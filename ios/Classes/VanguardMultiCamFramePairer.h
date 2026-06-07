// VanguardMultiCamFramePairer.h
// vanguard_media_engine — MC-6: Reusable MultiCam software timestamp pairer.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-6 — MULTICAM FRAME PAIRER (EXTRACTION)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Reusable nearest-neighbour CMTime pairing component extracted from the
// software timestamp-pairing algorithm proven by MC-5
// (VanguardMultiCamSyncDiagnostic / _VanguardMC5SoftPairDelegate).
//
// ── WHAT IT DOES ─────────────────────────────────────────────────────────────
//
//   Accepts CMTime values from front and back cameras and attempts a
//   nearest-neighbour match: two frames are considered "paired" if
//   |frontPTS − backPTS| ≤ pairingThreshold.
//
//   Tracks pairing metrics (paired count, unmatched counts, drift statistics)
//   in the same shape as VGMultiCamSyncReport.
//
//   Callers inform the pairer of each PTS arrival via offerFrontPTS: /
//   offerBackPTS:, which return YES if a pair was formed.
//
// ── WHAT IT DOES NOT DO ──────────────────────────────────────────────────────
//
//   Does NOT depend on AVCaptureSession, AVCaptureVideoDataOutput,
//   AVCaptureMultiCamSession, CMSampleBuffer, or CVPixelBuffer.
//
//   Does NOT retain any sample buffers or pixel buffers.
//
//   Does NOT manage a capture queue. Callers own the threading model.
//
//   Does NOT provide a paired-frame delivery delegate (the BOOL return value
//   from offerFrontPTS: / offerBackPTS: is the signal; production source
//   wiring is deferred to MC-7).
//
// ── PAIRING ALGORITHM ────────────────────────────────────────────────────────
//
//   State:
//     CMTime lastUnmatchedFrontPTS = kCMTimeInvalid
//     CMTime lastUnmatchedBackPTS  = kCMTimeInvalid
//
//   On offerFrontPTS: (symmetric for back)
//     1. Increment frontFramesReceived.
//     2. If lastUnmatchedBackPTS is numeric:
//        a. drift = |frontPTS − lastUnmatchedBackPTS|
//        b. If drift ≤ threshold:
//             pairedFramesReceived++; update max/avg drift;
//             clear lastUnmatchedBackPTS; return YES (paired)
//        c. Else (stale back):
//             unmatchedBackFrames++; clear lastUnmatchedBackPTS
//             store front as new lastUnmatchedFrontPTS (displacing prior
//             unmatched front, which is counted first); return NO
//     3. If no unmatched back:
//        store front as lastUnmatchedFrontPTS (displacing prior, counted
//        first); return NO.
//
//   flushPendingUnmatched:
//     Remaining pending PTS on either side at teardown → counted as unmatched.
//
// ── THREAD SAFETY ────────────────────────────────────────────────────────────
//
//   NOT thread-safe. All methods MUST be called from the same serial queue.
//   In production use (MC-7+), share the capture serial queue between both
//   camera delegates and the pairer, matching the MC-4/MC-5 pattern.
//
// ── AVAILABILITY ─────────────────────────────────────────────────────────────
//
//   No AVFoundation. Requires only Foundation and CoreMedia.
//   Available on all iOS versions supported by the engine.
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//   VanguardMultiCamFramePairer *pairer =
//       [[VanguardMultiCamFramePairer alloc] initWithThresholdSeconds:1.0 / 30.0];
//
//   // On each front camera frame (from serial captureQ):
//   BOOL paired = [pairer offerFrontPTS:CMSampleBufferGetPresentationTimeStamp(sb)];
//
//   // On each back camera frame (same serial captureQ):
//   BOOL paired = [pairer offerBackPTS:CMSampleBufferGetPresentationTimeStamp(sb)];
//
//   // At teardown (after stopRunning + delegate nil):
//   [pairer flushPendingUnmatched];
//
//   NSDictionary *metrics = [pairer metrics];
//   // metrics[@"pairedFramesReceived"], [@"maxDriftSeconds"], etc.
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamSyncDiagnostic.*     VanguardCameraMediaSource.*
//   VGCameraGraphSession.*               VanguardMediaEnginePlugin.swift
//   connectsapp_*/**                     Android code
//   Phase 8 overlay files

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VanguardMultiCamFramePairer ──────────────────────────────────────────────

/// Reusable nearest-neighbour CMTime software pairer for MultiCam frame pairs.
///
/// Extracted from the algorithm proven by MC-5
/// (`_VanguardMC5SoftPairDelegate._pairNewPTS:isFront:`).
///
/// Operates purely on `CMTime` values — no AVFoundation session, no
/// `CMSampleBuffer`, no `CVPixelBuffer` dependency.
///
/// NOT thread-safe. All methods must be called from the same serial queue.
///
/// The `offerFrontPTS:` / `offerBackPTS:` return value signals whether a pair
/// was formed. Future production source code (MC-7+) uses this signal to
/// decide when to composite the corresponding pixel buffers.
@interface VanguardMultiCamFramePairer : NSObject

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize with the PTS drift tolerance used for pairing.
///
/// @param thresholdSeconds  Maximum absolute drift (|frontPTS − backPTS|, in
///   seconds) for two frames to be considered a valid pair.
///   Typical value: `1.0 / 30.0` ≈ 33.3ms (one full frame interval at 30fps),
///   matching the proven MC-5 constant `kPairingThresholdSeconds`.
- (instancetype)initWithThresholdSeconds:(double)thresholdSeconds
    NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use `initWithThresholdSeconds:`.
- (instancetype)init NS_UNAVAILABLE;

// ─── Pairing methods ──────────────────────────────────────────────────────────

/// Offer a front-camera presentation timestamp for pairing.
///
/// Increments `frontFramesReceived`. Attempts to pair with the most recent
/// unmatched back-camera PTS. Returns `YES` if a pair was formed (drift was
/// within threshold), `NO` otherwise.
///
/// Must be called from the owning serial queue.
///
/// @param pts  The front-camera presentation timestamp.
///             Non-numeric PTS (kCMTimeInvalid, kCMTimeIndefinite) is accepted
///             without pairing: frontFramesReceived is still incremented, and
///             the method returns NO.
/// @return YES if a pair was formed with a pending back-camera PTS.
- (BOOL)offerFrontPTS:(CMTime)pts;

/// Offer a back-camera presentation timestamp for pairing.
///
/// Symmetric to `offerFrontPTS:`. Increments `backFramesReceived`.
/// Returns `YES` if a pair was formed.
///
/// Must be called from the owning serial queue.
- (BOOL)offerBackPTS:(CMTime)pts;

// ─── Teardown ─────────────────────────────────────────────────────────────────

/// Flush any pending unmatched PTS at the end of a capture run.
///
/// After the capture session has stopped and any remaining delegate callbacks
/// have drained, call this once to count any PTS that never found a partner.
/// Increments `unmatchedFrontFrames` / `unmatchedBackFrames` as appropriate
/// and clears pending state.
///
/// Idempotent: safe to call multiple times.
/// Must be called from the owning serial queue (or after delegate teardown).
- (void)flushPendingUnmatched;

// ─── Reset ────────────────────────────────────────────────────────────────────

/// Reset all counters and pending PTS state to zero / kCMTimeInvalid.
///
/// Enables reuse across repeated diagnostic runs without allocating a new
/// instance.
///
/// Must be called from the owning serial queue (or before a new run starts).
- (void)reset;

// ─── Metrics (readonly) ───────────────────────────────────────────────────────

/// Number of frame pairs successfully formed (drift ≤ threshold).
@property (nonatomic, readonly) int32_t pairedFramesReceived;

/// Total front-camera frames offered (including unmatched and non-numeric PTS).
@property (nonatomic, readonly) int32_t frontFramesReceived;

/// Total back-camera frames offered (including unmatched and non-numeric PTS).
@property (nonatomic, readonly) int32_t backFramesReceived;

/// Front frames that were displaced without ever finding a back partner.
@property (nonatomic, readonly) int32_t unmatchedFrontFrames;

/// Back frames that were displaced without ever finding a front partner.
@property (nonatomic, readonly) int32_t unmatchedBackFrames;

/// Peak drift (in seconds) observed across all successful pairs.
/// 0.0 if no pairs formed.
@property (nonatomic, readonly) double maxDriftSeconds;

/// Mean drift (in seconds) across all successful pairs.
/// Computed as accumulatedDriftSeconds / pairedFramesReceived.
/// 0.0 if no pairs formed.
@property (nonatomic, readonly) double averageDriftSeconds;

/// The pairing threshold passed to the initializer (in seconds).
@property (nonatomic, readonly) double pairingThresholdSeconds;

// ─── Metrics snapshot ─────────────────────────────────────────────────────────

/// Returns a dictionary snapshot of all pairing metrics.
///
/// Dictionary keys (all NSNumber):
///   @"pairedFramesReceived"    — int32_t
///   @"frontFramesReceived"     — int32_t
///   @"backFramesReceived"      — int32_t
///   @"unmatchedFrontFrames"    — int32_t
///   @"unmatchedBackFrames"     — int32_t
///   @"maxDriftSeconds"         — double
///   @"averageDriftSeconds"     — double
///   @"pairingThresholdSeconds" — double
///
/// Safe to call at any time; computes averageDriftSeconds lazily.
/// Must be called from the owning serial queue for consistency.
- (NSDictionary<NSString *, NSNumber *> *)metrics;

@end

NS_ASSUME_NONNULL_END
