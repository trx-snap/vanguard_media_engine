// vg_roi_export_sidecar_post_processor.dart
// Vanguard Media Engine — Phase 5-Unit M (Android Source ROI Sidecar
// Ingestion & Export Transform Mapping Parity).
//
// Best-effort post-processor that upgrades the native mandatory empty ROI
// sidecar (always written by the Android export/passthrough-remux native
// sessions) into a real, mapped export-space ROI sidecar when a source
// capture-time sidecar exists alongside the source video.
//
// Design rules:
//   - Pure Dart orchestration: reads the source sidecar, probes source media
//     via [VanguardMediaPreparer.inspectMedia], and delegates all coordinate
//     math to [VGROISidecarExportMapper.mapSidecar] -- no coordinate math is
//     duplicated here.
//   - Fails closed: any missing, unsupported, or malformed input leaves the
//     native empty sidecar in place untouched and returns false. Wrong ROI is
//     worse than missing ROI.
//   - Writes via a temp file next to the final sidecar, then renames into
//     place, so the final sidecar is never observed in a partially-written
//     state. On any failure, only this processor's own temp file is deleted;
//     the native empty sidecar already at the final path is never touched.

import 'dart:convert';
import 'dart:io';

import 'vg_roi_export_mapper.dart';
import 'vg_roi_models.dart';
import '../../vanguard_media_preparer.dart';

/// Best-effort export-space ROI sidecar post-processor for Android exports.
class VGRoiExportSidecarPostProcessor {
  const VGRoiExportSidecarPostProcessor._();

  /// Attempts to replace the native empty ROI sidecar at
  /// [exportRoiSidecarPath] with a real sidecar mapped from the source
  /// video's capture-time `.roi.json`, if one exists.
  ///
  /// [sourceVideoPath] and [outputVideoPath] are used to derive the source
  /// and (as a consistency check) output sidecar paths using the same
  /// extension-replacement rule as the native
  /// `AndroidTimelineRoiSidecarEmitter.sidecarPathForVideoPath`. When the
  /// derived output path does not match [exportRoiSidecarPath], processing
  /// is aborted.
  ///
  /// [canvasWidth] / [canvasHeight] describe the export output canvas.
  /// [trimStartSeconds] / [trimEndSeconds] describe the trim window applied
  /// to the single source clip, in source-asset seconds.
  ///
  /// [passthroughPreservesSourceGeometry] must be set only for a zero-reencode
  /// passthrough remux, where the encoded track dimensions in
  /// [canvasWidth]/[canvasHeight] are storage geometry, not playable display
  /// geometry. When true and the trim window is a no-op, the effective output
  /// canvas is instead derived from the same source-dimension policy used for
  /// the source sidecar's coordinate space.
  ///
  /// Returns true only if the mapped sidecar was written and finalized.
  /// Never throws.
  static Future<bool> process({
    required String sourceVideoPath,
    required String outputVideoPath,
    required String exportRoiSidecarPath,
    required int canvasWidth,
    required int canvasHeight,
    double trimStartSeconds = 0.0,
    double trimEndSeconds = double.infinity,
    bool passthroughPreservesSourceGeometry = false,
  }) async {
    try {
      if (canvasWidth <= 0 || canvasHeight <= 0) return false;

      final derivedOutputSidecarPath = _sidecarPathForVideoPath(
        outputVideoPath,
      );
      if (derivedOutputSidecarPath != exportRoiSidecarPath) return false;

      final sourceSidecarPath = _sidecarPathForVideoPath(sourceVideoPath);
      final sourceSidecarFile = File(sourceSidecarPath);
      if (!sourceSidecarFile.existsSync()) return false;

      final decoded = jsonDecode(await sourceSidecarFile.readAsString());
      if (decoded is! Map<String, dynamic>) return false;
      final captureSidecar = VGROISidecar.fromJson(decoded);

      final mediaInfo = await VanguardMediaPreparer.inspectMedia(
        sourceVideoPath,
      );
      if (mediaInfo == null) return false;

      final isPassthroughNoTrim =
          trimStartSeconds == 0.0 && trimEndSeconds.isInfinite;
      final preserveSourceGeometry =
          passthroughPreservesSourceGeometry && isPassthroughNoTrim;

      double sourceWidth;
      double sourceHeight;
      double effectiveCanvasWidth = canvasWidth.toDouble();
      double effectiveCanvasHeight = canvasHeight.toDouble();
      switch (captureSidecar.coordinateSpace) {
        case 'display_source_normalized':
          sourceWidth = mediaInfo.displayWidth.toDouble();
          sourceHeight = mediaInfo.displayHeight.toDouble();
          if (preserveSourceGeometry) {
            effectiveCanvasWidth = sourceWidth;
            effectiveCanvasHeight = sourceHeight;
          }
          break;
        case 'portrait_capture_normalized':
          sourceWidth = mediaInfo.width.toDouble();
          sourceHeight = mediaInfo.height.toDouble();
          if (preserveSourceGeometry) {
            effectiveCanvasWidth = sourceWidth;
            effectiveCanvasHeight = sourceHeight;
          }
          break;
        case 'export_output_normalized':
          // Only valid to reuse as a "source" space for a passthrough
          // export with no trim.
          if (!isPassthroughNoTrim) return false;
          if (preserveSourceGeometry) {
            final identityWidth = captureSidecar.videoIdentity.width;
            final identityHeight = captureSidecar.videoIdentity.height;
            if (identityWidth <= 0 || identityHeight <= 0) return false;
            sourceWidth = identityWidth.toDouble();
            sourceHeight = identityHeight.toDouble();
            effectiveCanvasWidth = sourceWidth;
            effectiveCanvasHeight = sourceHeight;
          } else {
            if (captureSidecar.videoIdentity.width != canvasWidth ||
                captureSidecar.videoIdentity.height != canvasHeight) {
              return false;
            }
            sourceWidth = canvasWidth.toDouble();
            sourceHeight = canvasHeight.toDouble();
          }
          break;
        default:
          return false;
      }

      if (sourceWidth <= 0 || sourceHeight <= 0) return false;
      if (effectiveCanvasWidth <= 0 || effectiveCanvasHeight <= 0) {
        return false;
      }

      final exportSidecar = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: captureSidecar,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        canvasWidth: effectiveCanvasWidth,
        canvasHeight: effectiveCanvasHeight,
        trimStartSeconds: trimStartSeconds,
        trimEndSeconds: trimEndSeconds,
      );

      final tempPath = '$exportRoiSidecarPath.vgroitmp';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsString(jsonEncode(exportSidecar.toJson()));
        await tempFile.rename(exportRoiSidecarPath);
        return true;
      } catch (_) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {
          // Best-effort cleanup only.
        }
        return false;
      }
    } catch (_) {
      // Any ROI failure (parse error, mapper ArgumentError, I/O error, etc.)
      // must leave the native empty sidecar in place, never propagate.
      return false;
    }
  }

  /// Derives the ROI sidecar path for [videoPath] using extension
  /// replacement, mirroring
  /// `AndroidTimelineRoiSidecarEmitter.sidecarPathForVideoPath`:
  /// `/tmp/out.mp4` -> `/tmp/out.roi.json`.
  static String _sidecarPathForVideoPath(String videoPath) {
    final lastSeparator = videoPath.lastIndexOf('/');
    final lastDot = videoPath.lastIndexOf('.');
    if (lastDot <= lastSeparator) {
      return '$videoPath.roi.json';
    }
    return '${videoPath.substring(0, lastDot)}.roi.json';
  }
}
