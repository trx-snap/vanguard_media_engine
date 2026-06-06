// VanguardMultiCamSessionDiagnostic.h
// vanguard_media_engine — MC-3: Non-running MultiCam hardware cost diagnostic.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-3 — MULTICAM HARDWARE COST DIAGNOSTIC
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure read-only diagnostic. Reports the ISP bandwidth cost (hardwareCost)
// of an AVCaptureMultiCamSession configured for a given front/back device pair,
// WITHOUT ever calling startRunning.
//
// ── CONSTRAINTS ──────────────────────────────────────────────────────────────
//
//   DO NOT start the session (startRunning is forbidden).
//   DO NOT set sample-buffer delegates on outputs (no frames delivered).
//   DO NOT report systemPressureCost (only meaningful on a running session).
//   DO NOT request camera permission (check only, never prompt).
//   DO NOT retain the session beyond the scope of measureCostForFrontId:backId:.
//   DO NOT modify VanguardCameraMediaSource or VGCameraGraphSession.
//
// ── AVAILABILITY ─────────────────────────────────────────────────────────────
//
//   iOS 13.0+ only. Returns nil on older OS versions.
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//   NSDictionary *cost = [VanguardMultiCamSessionDiagnostic
//       measureCostForFrontId:frontUniqueId
//                    backId:backUniqueId];
//   // cost[@"hardwareCost"]   — NSNumber (double, 0.0–1.0+)
//   // cost[@"isWithinBudget"] — NSNumber (bool, YES if hardwareCost <= 1.0)
//   // nil on any failure (permission denied, device not found, etc.)
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Measures the `AVCaptureMultiCamSession.hardwareCost` for a given
/// front/back device pair without starting the session.
///
/// This is a developer/diagnostic-only utility. It must not be called on the
/// main thread in production; it is synchronous and allocates AVFoundation
/// objects.
///
/// Requires iOS 13+. Returns nil on older OS versions (guarded in the .m).
@interface VanguardMultiCamSessionDiagnostic : NSObject

/// Measures the hardware cost of simultaneously capturing the specified
/// front and back cameras in an `AVCaptureMultiCamSession`.
///
/// ## Authorization
/// Returns `nil` if camera authorization status is not
/// `AVAuthorizationStatusAuthorized`. Does **not** request authorization.
///
/// ## What this creates (and immediately destroys):
///   - `AVCaptureMultiCamSession`
///   - `AVCaptureDeviceInput` for front and back devices
///   - `AVCaptureVideoDataOutput` for each camera (no delegate set)
///   - `AVCaptureConnection` (implicitly, via addOutput:)
///   - Connection orientation/mirroring configured to match the production contract
///
/// ## What this does NOT do:
///   - Does NOT call `startRunning`.
///   - Does NOT set `setSampleBufferDelegate:queue:`.
///   - Does NOT stream frames.
///   - Does NOT create textures or renderers.
///   - Does NOT read `systemPressureCost` (deferred to MC-4).
///   - Does NOT modify the existing single-camera session.
///
/// ## Return value
/// Returns `@{@"hardwareCost": @(<double>), @"isWithinBudget": @(<BOOL>)}`
/// or `nil` on any failure.
///
/// @param frontId The `uniqueID` of the front-facing AVCaptureDevice.
/// @param backId  The `uniqueID` of the back-facing AVCaptureDevice.
+ (nullable NSDictionary<NSString *, NSNumber *> *)
    measureCostForFrontId:(NSString *)frontId
                   backId:(NSString *)backId;

@end

NS_ASSUME_NONNULL_END
