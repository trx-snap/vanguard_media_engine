// VanguardMultiCamStreamingDiagnostic.h
// vanguard_media_engine — MC-4: Running MultiCam streaming diagnostic.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-4 — MULTICAM LIVE STREAMING DIAGNOSTIC
// ═══════════════════════════════════════════════════════════════════════════════
//
// Starts an AVCaptureMultiCamSession, counts frames from both the front and
// back cameras for a fixed 3-second window, samples systemPressureCost while
// running, then stops and destroys the session.
//
// ── CONTRAST WITH MC-3 ───────────────────────────────────────────────────────
//
//   MC-3 (VanguardMultiCamSessionDiagnostic): non-running — reads hardwareCost
//     only, never calls startRunning.
//   MC-4 (VanguardMultiCamStreamingDiagnostic): running — calls startRunning,
//     delivers frames via sample-buffer delegates, measures systemPressureCost,
//     counts frames.
//
// ── CONSTRAINTS ──────────────────────────────────────────────────────────────
//
//   DO NOT call startRunning from main thread (dispatched to background queue).
//   DO NOT set sample-buffer delegate to render or display frames.
//   DO NOT create Flutter textures, Metal renderers, or compositors.
//   DO NOT create AVCaptureDataOutputSynchronizer.
//   DO NOT request camera permission (check only, never prompt).
//   DO NOT retain the session beyond runForFrontId:backId:.
//   DO NOT call stopRunning except at the end of the 3-second window.
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
//   NSDictionary *report = [VanguardMultiCamStreamingDiagnostic
//       runForFrontId:frontUniqueId
//              backId:backUniqueId];
//   // report[@"frontFramesReceived"]    — NSNumber (int)
//   // report[@"backFramesReceived"]     — NSNumber (int)
//   // report[@"peakSystemPressureCost"] — NSNumber (double)
//   // report[@"hardwareCost"]           — NSNumber (double)
//   // report[@"durationSeconds"]        — NSNumber (double)
//   // nil on any failure (permission denied, device not found, etc.)
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a 3-second MultiCam streaming diagnostic for the given front/back
/// device pair.
///
/// Starts a real `AVCaptureMultiCamSession`, counts frames independently from
/// each camera, samples `systemPressureCost` while running, then stops and
/// destroys the session.
///
/// ## Thread Requirements
/// This method is **synchronous** and **blocking** for approximately 3 seconds
/// due to `startRunning` + the run window. It must NOT be called on the main
/// thread. The plugin route dispatches it to a dedicated background serial queue.
///
/// ## Preconditions
/// The plugin route that calls this method is responsible for enforcing the
/// `currentMode == .idle` precondition. This class does not check engine mode.
///
/// ## Authorization
/// Returns `nil` if camera authorization status is not
/// `AVAuthorizationStatusAuthorized`. Does **not** request authorization.
///
/// ## Session cleanup
/// `stopRunning` is called in all paths after `startRunning` succeeds.
/// All AVFoundation objects are local — ARC destroys them at method return.
/// The green camera indicator disappears after `stopRunning`.
///
/// ## Return value
/// Returns a dictionary with keys:
///   - `frontFramesReceived`    (NSNumber, int)
///   - `backFramesReceived`     (NSNumber, int)
///   - `peakSystemPressureCost` (NSNumber, double, 0.0 if session never ran)
///   - `hardwareCost`           (NSNumber, double, re-read from running session)
///   - `durationSeconds`        (NSNumber, double, actual elapsed time in seconds)
/// or `nil` on any failure.
///
/// ## iOS availability
/// Returns `nil` on iOS < 13.0. Internally guarded with `@available(iOS 13.0, *)`.
///
/// @param frontId The `uniqueID` of the front-facing AVCaptureDevice.
/// @param backId  The `uniqueID` of the back-facing AVCaptureDevice.
@interface VanguardMultiCamStreamingDiagnostic : NSObject

+ (nullable NSDictionary<NSString *, NSNumber *> *)
    runForFrontId:(NSString *)frontId
           backId:(NSString *)backId;

@end

NS_ASSUME_NONNULL_END
