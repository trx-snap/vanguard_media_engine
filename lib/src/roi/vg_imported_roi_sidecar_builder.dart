// vg_imported_roi_sidecar_builder.dart
// ROI-5E.1 — In-Memory Single-Sample Imported ROI Sidecar Builder
//
// Converts one accepted ROI-5C face scan evidence result into an in-memory
// VGROISidecar following the Opus-approved ROI-5D contract.
//
// Contract (UMF commit 051576f, §19.7):
//   version             = 1
//   sourceType          = "imported_gallery"
//   coordinateSpace     = "display_source_normalized"
//   videoIdentity.width = mediaInfo.displayWidth
//   videoIdentity.height= mediaInfo.displayHeight
//   timing              = actualTimeSeconds from face scan evidence
//   face selection      = single largest face by normalized area
//   orientation gate    = only "valid" permitted
//   clamped / rawVision = not persisted in the sidecar model
//
// Design decisions (see ROI-5D.1 UMF docs):
//   - VGROIIdentity does not yet carry the optional traceability fields
//     (encodedWidth, encodedHeight, rotationDegrees, orientationStatus).
//     These are approved as optional JSON keys in the contract docs but
//     require a future Dart model extension (ROI-5E.2 or later).
//     When that extension lands, callers can read them from the raw JSON;
//     the existing VGROIIdentity.fromJson silently ignores unknown keys.
//   - No file writes. No native calls. No background scanning.
//   - No multi-sample loops (single sample at t=0 only in this slice).
//   - No export integration. No server-ready ROI.
//   - Android: not implemented in this slice. Callers must guard on platform.

import 'vg_roi_models.dart';
import '../../vanguard_media_preparer.dart';

/// ROI-5E.1: Pure Dart builder that converts a single accepted ROI-5C face scan
/// evidence result into an in-memory [VGROISidecar].
///
/// ## Usage
///
/// ```dart
/// final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
///   mediaInfo: mediaInfo,
///   faceScanEvidence: evidence,
/// );
/// if (sidecar != null) {
///   // Sidecar is valid — use for downstream processing.
/// }
/// ```
///
/// ## Returns null when:
/// - [MediaInfo.orientationStatus] is not exactly `"valid"`.
/// - [MediaInfo.displayWidth] or [MediaInfo.displayHeight] is zero.
/// - `faceScanEvidence['frameWidth']` does not match [MediaInfo.displayWidth].
/// - `faceScanEvidence['frameHeight']` does not match [MediaInfo.displayHeight].
/// - `faceScanEvidence` is missing required keys.
class VGImportedROISidecarBuilder {
  // Significant out-of-bounds rejection threshold per ROI-5D.1 §19.7.5.
  // Box coordinates that exceed [0,1] by more than this value are rejected
  // (box set to null). Wrong ROI is strictly worse than missing ROI.
  static const double _kClampRejectThreshold = 0.05;

  /// Builds a single-sample [VGROISidecar] from imported face scan evidence.
  ///
  /// ## Parameters
  ///
  /// - [mediaInfo]: The result of [VanguardMediaPreparer.inspectMedia]. Used
  ///   for display dimensions, orientation gate, and duration.
  /// - [faceScanEvidence]: The result map from
  ///   [VanguardMediaPreparer.extractImportedFaceScanEvidence]. Must contain
  ///   at minimum: `frameWidth`, `frameHeight`, `actualTimeSeconds`, `faceCount`,
  ///   and `faces` (list, may be empty).
  /// - [recordingSessionId]: Optional stable identifier for this import session.
  ///   When null, a timestamp-based ID is generated. Must never be a raw file path.
  /// - [videoHash]: Optional content hash of the source video file. Passed
  ///   through to [VGROIIdentity.hash]. Null is accepted.
  /// - [platform]: Platform identifier written into the sidecar. Defaults to
  ///   `'ios'` since only iOS is supported for imported ROI in this slice.
  ///
  /// ## Returns
  ///
  /// A finalized [VGROISidecar] on success, or `null` if any gate check fails.
  static VGROISidecar? buildSingleSample({
    required MediaInfo mediaInfo,
    required Map<String, dynamic> faceScanEvidence,
    String? recordingSessionId,
    String? videoHash,
    String platform = 'ios',
  }) {
    // ── Gate 1: Orientation check ────────────────────────────────────────────
    // Only "valid" (cardinal, non-mirrored) orientation is permitted.
    // Block: "validMirrored", "ambiguous", "noVideoTrack".
    if (mediaInfo.orientationStatus != 'valid') {
      return null;
    }

    // ── Gate 2: Display dimensions must be non-zero ──────────────────────────
    if (mediaInfo.displayWidth <= 0 || mediaInfo.displayHeight <= 0) {
      return null;
    }

    // ── Gate 3: Parse face scan evidence keys ────────────────────────────────
    final frameWidth  = faceScanEvidence['frameWidth']  as int?;
    final frameHeight = faceScanEvidence['frameHeight'] as int?;
    final actualTimeSeconds =
        (faceScanEvidence['actualTimeSeconds'] as num?)?.toDouble();

    if (frameWidth == null || frameHeight == null || actualTimeSeconds == null) {
      return null;
    }

    // ── Gate 4: Frame dimensions must match display dimensions ───────────────
    // This validates that the face scan evidence was produced from a
    // display-oriented frame that matches the asset's declared display size.
    if (frameWidth != mediaInfo.displayWidth ||
        frameHeight != mediaInfo.displayHeight) {
      return null;
    }

    // ── Timing (ROI-5D §19.7.3) ──────────────────────────────────────────────
    // Use actualTimeSeconds as the sole source of truth.
    // Do NOT use requestedTimeSeconds — the decoder may snap to the nearest
    // keyframe, so actual and requested times may differ.
    final int timestampMs = (actualTimeSeconds * 1000).round().clamp(0, _kMaxMs);

    // ── Face selection (ROI-5D §19.7.4) ─────────────────────────────────────
    // Single largest face by normalized area. If no faces: null box.
    final faceCount = (faceScanEvidence['faceCount'] as num?)?.toInt() ?? 0;
    final faces = faceScanEvidence['faces'] as List?;

    VGROIBox? box;
    if (faceCount > 0 && faces != null && faces.isNotEmpty) {
      // Find largest face by normalizedWidth * normalizedHeight.
      Map<String, dynamic>? largest;
      double largestArea = -1.0;

      for (final face in faces) {
        if (face == null) continue;
        final faceMap = face as Map<Object?, Object?>;
        final nw = (faceMap['normalizedWidth']  as num?)?.toDouble() ?? 0.0;
        final nh = (faceMap['normalizedHeight'] as num?)?.toDouble() ?? 0.0;
        final area = nw * nh;
        if (area > largestArea) {
          largestArea = area;
          largest = faceMap.map((k, v) => MapEntry(k.toString(), v));
        }
      }

      if (largest != null) {
        box = _buildBox(largest);
        // If box construction returns null, we fall through to null box
        // (wrong ROI is worse than missing ROI).
      }
    }

    // ── Sample (ROI-5D §19.7) ────────────────────────────────────────────────
    final quality = box != null ? 'detected' : 'missing';
    final sample = VGROISample(
      timestampMs:          timestampMs,
      framePtsMs:           timestampMs,
      recordingRelativeMs:  timestampMs,
      box:                  box,
      quality:              quality,
      confidence:           null,    // No reliable confidence from VNDetectFaceRectanglesRequest
      paddingPolicy:        null,    // Deferred
    );

    // ── Video identity (ROI-5D §19.7.2) ─────────────────────────────────────
    // width/height = display-oriented dimensions (not encoded/raw dimensions).
    // Optional traceability fields (encodedWidth, encodedHeight,
    // rotationDegrees, orientationStatus) are approved in the contract docs
    // but require a Dart model extension — not added here.
    final durationMs = _computeDurationMs(mediaInfo, actualTimeSeconds);

    final videoIdentity = VGROIIdentity(
      durationMs: durationMs,
      width:      mediaInfo.displayWidth,
      height:     mediaInfo.displayHeight,
      hash:       videoHash,
    );

    // ── Recording session ID (ROI-5D §19.7.7 privacy) ────────────────────────
    // Use caller-provided ID if present; otherwise generate a non-path ID.
    // Never use raw file paths.
    final sessionId = recordingSessionId?.isNotEmpty == true
        ? recordingSessionId!
        : 'imported-${DateTime.now().microsecondsSinceEpoch}';

    // ── Assemble sidecar (ROI-5D §19.7.1) ───────────────────────────────────
    return VGROISidecar(
      version:            1,
      sourceType:         'imported_gallery',
      platform:           platform,
      coordinateSpace:    'display_source_normalized',
      recordingSessionId: sessionId,
      videoIdentity:      videoIdentity,
      coverage: VGROICoverage(
        // Single-sample scan of one frame: treat as 100% coverage for this
        // minimal slice. True multi-frame coverage analysis is deferred.
        coveragePercent:  1.0,
        missingIntervals: const [],
      ),
      samples:   [sample],
      finalized: true,
    );
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  /// Attempts to build a [VGROIBox] from the largest-face map entry.
  ///
  /// Returns null when:
  /// - Any required key is missing or non-finite.
  /// - Coordinates significantly exceed [0,1] by more than [_kClampRejectThreshold].
  /// - Minor float-drift values are clamped silently and accepted.
  static VGROIBox? _buildBox(Map<String, dynamic> face) {
    final rawX = (face['normalizedX']      as num?)?.toDouble();
    final rawY = (face['normalizedY']      as num?)?.toDouble();
    final rawW = (face['normalizedWidth']  as num?)?.toDouble();
    final rawH = (face['normalizedHeight'] as num?)?.toDouble();

    // All four coordinates must be present and finite.
    if (rawX == null || rawY == null || rawW == null || rawH == null) {
      return null;
    }
    if (!rawX.isFinite || !rawY.isFinite || !rawW.isFinite || !rawH.isFinite) {
      return null;
    }

    // Reject: significant out-of-bounds exceeding the 5% threshold.
    // Wrong ROI is worse than missing ROI.
    if (rawX < -_kClampRejectThreshold ||
        rawY < -_kClampRejectThreshold ||
        rawW < -_kClampRejectThreshold ||
        rawH < -_kClampRejectThreshold ||
        rawX > 1.0 + _kClampRejectThreshold ||
        rawY > 1.0 + _kClampRejectThreshold ||
        rawW > 1.0 + _kClampRejectThreshold ||
        rawH > 1.0 + _kClampRejectThreshold ||
        (rawX + rawW) > 1.0 + _kClampRejectThreshold ||
        (rawY + rawH) > 1.0 + _kClampRejectThreshold) {
      return null;
    }

    // Clamp minor float-drift to exact [0,1] before VGROIBox construction.
    // VGROIBox has its own strict [0,1] validator; clamping prevents
    // spurious ArgumentError from sub-epsilon drift.
    final x = rawX.clamp(0.0, 1.0);
    final y = rawY.clamp(0.0, 1.0);
    final w = rawW.clamp(0.0, 1.0 - x);
    final h = rawH.clamp(0.0, 1.0 - y);

    // Reject degenerate zero-area boxes.
    if (w <= 0.0 || h <= 0.0) return null;

    try {
      return VGROIBox(x: x, y: y, w: w, h: h);
    } on ArgumentError {
      // Defensive catch — should not reach here after the clamping above,
      // but treat any construction error as a rejected (null) box.
      return null;
    }
  }

  /// Computes the asset duration in milliseconds.
  ///
  /// Priority:
  /// 1. [MediaInfo.durationSeconds] when it is a valid positive value.
  /// 2. Fall back to `actualTimeSeconds` (last decoded frame time) when the
  ///    media duration is unknown (-1) or zero.
  static int _computeDurationMs(MediaInfo info, double actualTimeSeconds) {
    if (info.durationSeconds > 0) {
      return (info.durationSeconds * 1000).round().clamp(0, _kMaxMs);
    }
    // Fallback: use actual decoded frame time as a lower-bound estimate.
    return (actualTimeSeconds * 1000).round().clamp(0, _kMaxMs);
  }

  // Maximum practical millisecond value (≈ 277 hours). Mirrors vg_roi_export_mapper.
  static const int _kMaxMs = 999_999_999;
}
