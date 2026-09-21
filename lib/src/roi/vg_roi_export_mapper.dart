// vg_roi_export_mapper.dart
// UMF V2 ROI Signal / Server-Ready Sidecar Export Mapper (ROI-4A)
//
// Converts a capture-time ROI sidecar (coordinateSpace:
// "portrait_capture_normalized") into a server-ready export-space sidecar
// (coordinateSpace: "export_output_normalized") after Universal Editor export.
//
// Design rules (ROI-4A):
//   - Pure Dart. No native calls. No ConnectsApp imports.
//   - Depends only on vg_roi_models.dart and vg_roi_transform_mapper.dart.
//   - No VGClipTransformDescriptor or timeline/editor coupling.
//   - Returns a new VGROISidecar; never mutates the input.
//   - Missing ROI (null box) is acceptable; wrong ROI is not.
//   - If a mapped box falls fully outside the export canvas, the sample is
//     kept but its box is set to null (preserves timeline continuity).

import 'vg_roi_models.dart';
import 'vg_roi_transform_mapper.dart';

/// Maps a capture-time [VGROISidecar] to an export-space sidecar.
///
/// The output sidecar has:
///   - `coordinateSpace == "export_output_normalized"`
///   - `videoIdentity.width/height` set to the export canvas dimensions
///   - Samples trimmed and timestamp-shifted per `trimStartSeconds`
///   - Boxes transformed via [VGROITransformMapper.mapBox]
///   - All other sidecar fields preserved from the capture sidecar
///
/// ## Typical usage
/// ```dart
/// final exportSidecar = VGROISidecarExportMapper.mapSidecar(
///   captureSidecar: captureSidecar,
///   sourceWidth: 1080,
///   sourceHeight: 1920,
///   canvasWidth: 1080,
///   canvasHeight: 1920,
/// );
/// ```
class VGROISidecarExportMapper {
  /// Converts [captureSidecar] from capture-space coordinates to
  /// export-output-normalized coordinates.
  ///
  /// ## Parameters
  ///
  /// - [captureSidecar]: The capture-time sidecar written by ROI-3.
  /// - [sourceWidth] / [sourceHeight]: Natural pixel dimensions of the source
  ///   video **as presented to the compositor** (post-orientation-fix,
  ///   post-editor-rotation). Must be finite and > 0.
  /// - [canvasWidth] / [canvasHeight]: Export canvas dimensions in pixels.
  ///   Must be finite and > 0.
  /// - [scaleX] / [scaleY]: Scale factors applied by the editor. Already
  ///   coverScale-adjusted when coming from Universal Editor. Must be finite
  ///   and > 0. Default 1.0 (identity).
  /// - [rotation]: Rotation in radians, clockwise-positive. Default 0.0.
  /// - [translationX] / [translationY]: Translation in canvas pixels,
  ///   center-anchored. Default 0.0.
  /// - [trimStartSeconds]: Trim start in seconds. Samples before this time
  ///   (based on `recordingRelativeMs`) are dropped; surviving timestamps are
  ///   shifted. Must be finite and >= 0. Default 0.0.
  /// - [trimEndSeconds]: Trim end in seconds. Samples after this time are
  ///   dropped. May be [double.infinity] (no end trim). When finite must be
  ///   >= [trimStartSeconds].
  ///
  /// ## Throws
  ///
  /// [ArgumentError] for invalid dimension or parameter values.
  static VGROISidecar mapSidecar({
    required VGROISidecar captureSidecar,
    required double sourceWidth,
    required double sourceHeight,
    required double canvasWidth,
    required double canvasHeight,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double rotation = 0.0,
    double translationX = 0.0,
    double translationY = 0.0,
    double trimStartSeconds = 0.0,
    double trimEndSeconds = double.infinity,
  }) {
    // ── Input validation ────────────────────────────────────────────────────

    if (sourceWidth.isNaN || sourceWidth.isInfinite || sourceWidth <= 0.0 ||
        sourceHeight.isNaN || sourceHeight.isInfinite || sourceHeight <= 0.0 ||
        canvasWidth.isNaN || canvasWidth.isInfinite || canvasWidth <= 0.0 ||
        canvasHeight.isNaN || canvasHeight.isInfinite || canvasHeight <= 0.0) {
      throw ArgumentError(
        'sourceWidth, sourceHeight, canvasWidth, and canvasHeight must be '
        'finite and greater than 0.',
      );
    }

    if (scaleX.isNaN || scaleX.isInfinite || scaleX <= 0.0 ||
        scaleY.isNaN || scaleY.isInfinite || scaleY <= 0.0) {
      throw ArgumentError(
        'scaleX and scaleY must be finite and greater than 0.',
      );
    }

    if (rotation.isNaN || rotation.isInfinite ||
        translationX.isNaN || translationX.isInfinite ||
        translationY.isNaN || translationY.isInfinite) {
      throw ArgumentError(
        'rotation, translationX, and translationY must be finite.',
      );
    }

    if (trimStartSeconds.isNaN || trimStartSeconds.isInfinite ||
        trimStartSeconds < 0.0) {
      throw ArgumentError(
        'trimStartSeconds must be finite and >= 0.',
      );
    }

    if (!trimEndSeconds.isInfinite &&
        (trimEndSeconds.isNaN || trimEndSeconds < trimStartSeconds)) {
      throw ArgumentError(
        'trimEndSeconds must be double.infinity or a finite value >= trimStartSeconds.',
      );
    }

    // ── Trim bounds in milliseconds ─────────────────────────────────────────

    final int trimStartMs = (trimStartSeconds * 1000).round();
    final int? trimEndMs = trimEndSeconds.isInfinite
        ? null
        : (trimEndSeconds * 1000).round();

    // ── Trim and transform samples ──────────────────────────────────────────

    final List<VGROISample> exportSamples = [];

    final bool isSingleSample = captureSidecar.samples.length == 1;

    for (final sample in captureSidecar.samples) {
      final int shiftedTimestampMs;
      final int shiftedFramePtsMs;
      final int shiftedRecordingRelativeMs;

      if (isSingleSample && sample.recordingRelativeMs < trimStartMs) {
        // Re-anchor the single keyframe sample to the start of the trimmed clip (t=0)
        // rather than dropping the only face representation for this video.
        if (trimEndMs != null && trimStartMs > trimEndMs) continue;
        shiftedTimestampMs = 0;
        shiftedFramePtsMs = 0;
        shiftedRecordingRelativeMs = 0;
      } else {
        // Multi-sample or in-window: drop samples outside the trim window.
        if (sample.recordingRelativeMs < trimStartMs) continue;
        if (trimEndMs != null && sample.recordingRelativeMs > trimEndMs) continue;

        // Shift timestamps by trimStartMs.
        shiftedTimestampMs =
            (sample.timestampMs - trimStartMs).clamp(0, _kMaxMs);
        shiftedFramePtsMs =
            (sample.framePtsMs - trimStartMs).clamp(0, _kMaxMs);
        shiftedRecordingRelativeMs =
            (sample.recordingRelativeMs - trimStartMs).clamp(0, _kMaxMs);
      }

      // Map box coordinates.
      VGROIBox? exportBox;
      if (sample.box != null) {
        // VGROITransformMapper.mapBox returns null if the box is entirely
        // outside the canvas after transformation. In that case we keep the
        // sample but set box to null (preserves timeline continuity per
        // ROI-4A out-of-canvas policy).
        exportBox = VGROITransformMapper.mapBox(
          captureBox: sample.box!,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          canvasWidth: canvasWidth,
          canvasHeight: canvasHeight,
          scaleX: scaleX,
          scaleY: scaleY,
          rotation: rotation,
          translationX: translationX,
          translationY: translationY,
        );
        // exportBox is null when the ROI is fully outside the canvas —
        // this is valid per schema (VGROISample.box is nullable).
      }

      exportSamples.add(VGROISample(
        timestampMs: shiftedTimestampMs,
        framePtsMs: shiftedFramePtsMs,
        recordingRelativeMs: shiftedRecordingRelativeMs,
        box: exportBox,
        quality: sample.quality,
        confidence: sample.confidence,
        paddingPolicy: sample.paddingPolicy,
      ));
    }

    // ── Build export videoIdentity ──────────────────────────────────────────

    final int exportDurationMs = trimEndMs != null
        ? (trimEndMs - trimStartMs).clamp(0, _kMaxMs)
        : captureSidecar.videoIdentity.durationMs;

    final exportIdentity = VGROIIdentity(
      durationMs: exportDurationMs,
      width: canvasWidth.round(),
      height: canvasHeight.round(),
      hash: null, // Hash of export video not computed at export time.
    );

    // ── Build export sidecar ────────────────────────────────────────────────
    //
    // Preservation policy:
    //   - version, sourceType, platform, recordingSessionId: preserved.
    //   - coordinateSpace: changed to "export_output_normalized".
    //   - coverage (coveragePercent, missingIntervals): preserved as-is.
    //     True recomputation after trim is deferred to a future slice.
    //   - finalized: always true for the export sidecar.

    return VGROISidecar(
      version: captureSidecar.version,
      sourceType: captureSidecar.sourceType,
      platform: captureSidecar.platform,
      coordinateSpace: 'export_output_normalized',
      recordingSessionId: captureSidecar.recordingSessionId,
      videoIdentity: exportIdentity,
      coverage: VGROICoverage(
        coveragePercent: captureSidecar.coverage.coveragePercent,
        missingIntervals: List.unmodifiable(
          captureSidecar.coverage.missingIntervals,
        ),
      ),
      samples: exportSamples,
      finalized: true,
    );
  }

  // Maximum practical millisecond value used in clamp guards (≈ 277 hours).
  static const int _kMaxMs = 999_999_999;
}
