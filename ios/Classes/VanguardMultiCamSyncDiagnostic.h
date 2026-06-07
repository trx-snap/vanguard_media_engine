// VanguardMultiCamSyncDiagnostic.h
// vanguard_media_engine — MC-5: MultiCam software timestamp-pairing diagnostic.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-5 — MULTICAM SOFTWARE TIMESTAMP-PAIRING DIAGNOSTIC
// ═══════════════════════════════════════════════════════════════════════════════
//
// Proves that AVCaptureMultiCamSession delivers front and back frames whose
// presentation timestamps are closely aligned, and measures the PTS drift
// between temporally-adjacent front/back frame pairs for a fixed 3-second run.
//
// ── WHY SOFTWARE PAIRING, NOT AVCaptureDataOutputSynchronizer ────────────────
//
//   AVCaptureDataOutputSynchronizer was designed for outputs that share the
//   same hardware capture event (e.g., video + depth from a single device).
//   It uses a primary/secondary model: the primary output's PTS triggers the
//   callback; the secondary is waited on. With alwaysDiscardsLateVideoFrames=YES
//   (honored by the synchronizer per Apple documentation), independent front/back
//   cameras — running at slightly different phase offsets — result in the
//   secondary being consistently discarded before it can be paired.
//
//   Physical-device measurement confirmed: syncCallbackCount ≈ 179,
//   pairedFramesReceived = 0, droppedFront ≈ 89, droppedBack ≈ 90.
//   AVCaptureDataOutputSynchronizer is NOT used in this implementation.
//
// ── WHAT IT DOES ─────────────────────────────────────────────────────────────
//
//   • Creates a temporary AVCaptureMultiCamSession with front + back inputs
//     and independent AVCaptureVideoDataOutput instances (identical lifecycle
//     to MC-4).
//   • Sets individual AVCaptureVideoDataOutputSampleBufferDelegate on each
//     output — the same approach proven by MC-4.
//   • Both outputs share a single serial dispatch queue, enabling lock-free
//     software pairing.
//   • On each frame callback, reads PTS via
//     CMSampleBufferGetPresentationTimeStamp and attempts a nearest-neighbour
//     match with the most recent unmatched frame from the other camera.
//   • A frame is considered "paired" if |frontPTS − backPTS| ≤ pairingThreshold
//     (fixed at 1/30s ≈ 33.3ms — one full frame interval at 30fps).
//   • Runs for 3 seconds, counts paired frames, measures drift, tracks
//     unmatched frames.
//   • Stops, clears delegates, returns a metrics dictionary.
//
// ── PAIRING ALGORITHM ────────────────────────────────────────────────────────
//
//   State (on the serial captureQ, no locks needed):
//     CMTime  lastUnmatchedFrontPTS = kCMTimeInvalid
//     CMTime  lastUnmatchedBackPTS  = kCMTimeInvalid
//
//   On front frame:
//     frontFramesReceived++
//     if lastUnmatchedBackPTS is valid:
//       drift = |frontPTS − lastUnmatchedBackPTS|
//       if drift ≤ threshold:
//         pairedFramesReceived++; update max/avg drift; clear back PTS
//       else:
//         unmatchedBackFrames++; clear back PTS; store front PTS
//     else:
//       if lastUnmatchedFrontPTS is valid: unmatchedFrontFrames++
//       store front PTS
//
//   On back frame: symmetric.
//   At teardown: any remaining unmatched PTS → unmatchedFrontFrames /
//   unmatchedBackFrames.
//
// ── CONSTRAINTS ──────────────────────────────────────────────────────────────
//
//   DO NOT set AVCaptureDataOutputSynchronizer on these outputs.
//   DO NOT retain CMSampleBuffer or CVPixelBuffer beyond the delegate callback.
//   DO NOT call startRunning from main thread (dispatched to background queue).
//   DO NOT create Flutter textures, Metal renderers, or compositors.
//   DO NOT request camera permission (check only, never prompt).
//   DO NOT retain the session beyond runForFrontId:backId:.
//   DO NOT modify VanguardCameraMediaSource or VGCameraGraphSession.
//   DO NOT call from the plugin unless currentMode == .idle.
//
// ── AVAILABILITY ─────────────────────────────────────────────────────────────
//
//   iOS 13.0+ only. Returns nil on older OS versions.
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//   // Must be called from a background queue — startRunning blocks the thread.
//   NSDictionary *report = [VanguardMultiCamSyncDiagnostic
//       runForFrontId:frontUniqueId
//              backId:backUniqueId];
//   // report[@"pairedFramesReceived"]    — NSNumber (int)    software-paired frames
//   // report[@"frontFramesReceived"]     — NSNumber (int)    total front frames
//   // report[@"backFramesReceived"]      — NSNumber (int)    total back frames
//   // report[@"unmatchedFrontFrames"]    — NSNumber (int)    front frames that expired
//   // report[@"unmatchedBackFrames"]     — NSNumber (int)    back frames that expired
//   // report[@"maxDriftSeconds"]         — NSNumber (double) peak |frontPTS − backPTS|
//   // report[@"averageDriftSeconds"]     — NSNumber (double) mean |frontPTS − backPTS|
//   // report[@"peakSystemPressureCost"]  — NSNumber (double) peak while running
//   // report[@"hardwareCost"]            — NSNumber (double) read from session after config
//   // report[@"durationSeconds"]         — NSNumber (double) actual elapsed time
//   // report[@"pairingThresholdSeconds"] — NSNumber (double) threshold used (1/30s)
//   // nil on any failure (permission denied, device not found, unsupported, etc.)
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a 3-second MultiCam software timestamp-pairing diagnostic for the given
/// front/back device pair.
///
/// ## Approach
/// Uses independent `AVCaptureVideoDataOutputSampleBufferDelegate` callbacks for
/// front and back outputs on a shared serial queue (same as MC-4). Pairs frames
/// by comparing presentation timestamps within a 33.3ms threshold.
///
/// ## Critical difference from AVCaptureDataOutputSynchronizer
/// `AVCaptureDataOutputSynchronizer` was tested and found unsuitable for
/// independent front/back cameras: with `alwaysDiscardsLateVideoFrames = YES`
/// (honored by the synchronizer per Apple docs), the secondary camera's frames
/// were consistently dropped before pairing. This implementation does NOT use
/// `AVCaptureDataOutputSynchronizer`.
///
/// ## Thread Requirements
/// This method is **synchronous** and **blocking** for approximately 3 seconds.
/// Must NOT be called on the main thread. The plugin route dispatches it to a
/// background queue.
///
/// ## Sample buffer lifetime
/// `CMSampleBuffer` references are used only for PTS extraction within the
/// delegate callback scope. No `CMSampleBuffer` or `CVPixelBuffer` is retained.
///
/// ## Return value
/// Returns a dictionary with keys:
///   - `pairedFramesReceived`    (int)    — frames software-paired within threshold
///   - `frontFramesReceived`     (int)    — total front frames delivered
///   - `backFramesReceived`      (int)    — total back frames delivered
///   - `unmatchedFrontFrames`    (int)    — front frames that expired without a pair
///   - `unmatchedBackFrames`     (int)    — back frames that expired without a pair
///   - `maxDriftSeconds`         (double) — peak |frontPTS − backPTS| across pairs
///   - `averageDriftSeconds`     (double) — mean |frontPTS − backPTS| across pairs
///   - `peakSystemPressureCost`  (double) — peak systemPressureCost while running
///   - `hardwareCost`            (double) — ISP bandwidth cost after configuration
///   - `durationSeconds`         (double) — actual elapsed time in seconds
///   - `pairingThresholdSeconds` (double) — threshold used for pairing (1/30s)
/// or `nil` on any failure.
///
/// @param frontId The `uniqueID` of the front-facing AVCaptureDevice.
/// @param backId  The `uniqueID` of the back-facing AVCaptureDevice.
@interface VanguardMultiCamSyncDiagnostic : NSObject

+ (nullable NSDictionary<NSString *, NSNumber *> *)
    runForFrontId:(NSString *)frontId
           backId:(NSString *)backId;

@end

NS_ASSUME_NONNULL_END
