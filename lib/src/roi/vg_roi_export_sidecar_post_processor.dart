// vg_roi_export_sidecar_post_processor.dart
// Vanguard Media Engine — Phase 5-Unit M (Android Source ROI Sidecar
// Ingestion & Export Transform Mapping Parity) / Phase 5-Unit N (Android
// hard-cut multi-clip source ROI sidecar composition and export mapping
// parity).
//
// Best-effort post-processor that upgrades the native mandatory empty ROI
// sidecar (always written by the Android export/passthrough-remux native
// sessions) into a real, mapped export-space ROI sidecar when a source
// capture-time sidecar exists alongside the source video.
//
// Design rules:
//   - Pure Dart orchestration: reads the source sidecar(s), probes source
//     media via [VanguardMediaPreparer.inspectMedia], and delegates all
//     coordinate math to [VGROISidecarExportMapper.mapSidecar] -- no
//     coordinate math is duplicated here.
//   - Fails closed: any missing, unsupported, or malformed input leaves the
//     native empty sidecar in place untouched and returns false. Wrong ROI is
//     worse than missing ROI.
//   - Writes via a temp file next to the final sidecar, then renames into
//     place, so the final sidecar is never observed in a partially-written
//     state. On any failure, only this processor's own temp file is deleted;
//     the native empty sidecar already at the final path is never touched.
//
// Phase 5-Unit N adds [processTimeline], which composes per-clip mapped ROI
// samples across a hard-cut multi-clip timeline into a single export-space
// sidecar, timestamp-shifted by cumulative output time. A single clip's ROI
// failure never aborts the whole timeline -- it only drops that clip's
// samples, and the timeline cursor still advances so later clips stay
// aligned.
//
// Phase 5-Unit O adds explicit per-clip source sidecar and transform
// support:
//   - [process] / [_mapClipSidecar] accept an optional explicit
//     `sourceRoiSidecarPath`, preferred over the derived
//     `_sidecarPathForVideoPath(sourceVideoPath)` path. When an explicit path
//     is supplied but is missing, malformed, or unsupported, mapping fails
//     closed -- it never silently falls back to the derived adjacent path.
//     When no explicit path is supplied, the existing derived-path fallback
//     is preserved unchanged.
//   - [process] / [_mapClipSidecar] also accept scaleX/scaleY/rotation/
//     translationX/translationY and forward them to
//     [VGROISidecarExportMapper.mapSidecar] so editor-applied spatial
//     transforms are reflected in the mapped ROI boxes.
//   - [processTimeline] reads each clip's own `clip.sourceRoiSidecarPath` and
//     `clip.transform` -- there is no single scalar sidecar path or transform
//     applied uniformly across all clips.

import 'dart:convert';
import 'dart:io';

import 'vg_roi_export_mapper.dart';
import 'vg_roi_models.dart';
import '../../vanguard_media_preparer.dart';
import '../../vg_clip_descriptor.dart';

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
  /// [sourceRoiSidecarPath] is an optional explicit path to the source
  /// clip's capture-time sidecar (Phase 5-Unit O, e.g.
  /// [VGClipDescriptor.sourceRoiSidecarPath]). When supplied it takes strict
  /// precedence over the path derived from [sourceVideoPath]: if the
  /// explicit path is missing, malformed, or unsupported, this call returns
  /// false without falling back to the derived adjacent path. When omitted,
  /// the existing derived-path fallback behavior is preserved.
  ///
  /// [scaleX] / [scaleY] / [rotation] / [translationX] / [translationY]
  /// describe the editor-applied spatial transform for this clip and are
  /// forwarded to [VGROISidecarExportMapper.mapSidecar] unchanged.
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
    String? sourceRoiSidecarPath,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double rotation = 0.0,
    double translationX = 0.0,
    double translationY = 0.0,
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

      final exportSidecar = await _mapClipSidecar(
        sourceVideoPath: sourceVideoPath,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        explicitSourceRoiSidecarPath: sourceRoiSidecarPath,
        scaleX: scaleX,
        scaleY: scaleY,
        rotation: rotation,
        translationX: translationX,
        translationY: translationY,
        trimStartSeconds: trimStartSeconds,
        trimEndSeconds: trimEndSeconds,
        passthroughPreservesSourceGeometry: passthroughPreservesSourceGeometry,
      );
      if (exportSidecar == null) return false;

      return await _writeSidecarAtomically(exportSidecar, exportRoiSidecarPath);
    } catch (_) {
      // Any ROI failure (parse error, mapper ArgumentError, I/O error, etc.)
      // must leave the native empty sidecar in place, never propagate.
      return false;
    }
  }

  /// Attempts to compose a single export-space ROI sidecar for a hard-cut
  /// multi-clip timeline by mapping each clip's source capture-time sidecar
  /// independently and concatenating the surviving samples, timestamp-shifted
  /// by cumulative output time.
  ///
  /// [clips] is the ordered list of clips exactly as exported (hard cuts
  /// only -- transitions and animated compositor behavior are not modeled by
  /// this mapping, but each clip's own static [VGClipDescriptor.transform] is
  /// forwarded to [_mapClipSidecar] when present). [outputVideoPath] and
  /// [exportRoiSidecarPath] are used for
  /// the same output-sidecar-path consistency check as [process].
  /// [canvasWidth] / [canvasHeight] describe the export output canvas.
  /// [exportDurationSeconds] is the measured duration of the exported output.
  ///
  /// A clip's own ROI mapping failure (missing/malformed source sidecar,
  /// unsupported coordinate space, mapper error, or media probe failure)
  /// only drops that clip's samples -- it never aborts the whole timeline.
  /// The output timeline cursor still advances by that clip's output
  /// duration so later clips remain aligned.
  ///
  /// Returns true only if at least one sample survived across all clips and
  /// the composed sidecar was written and finalized. Never throws.
  static Future<bool> processTimeline({
    required List<VGClipDescriptor> clips,
    required String outputVideoPath,
    required String exportRoiSidecarPath,
    required int canvasWidth,
    required int canvasHeight,
    required double exportDurationSeconds,
  }) async {
    try {
      if (canvasWidth <= 0 || canvasHeight <= 0) return false;
      if (exportDurationSeconds.isNaN ||
          exportDurationSeconds.isInfinite ||
          exportDurationSeconds <= 0) {
        return false;
      }

      final derivedOutputSidecarPath = _sidecarPathForVideoPath(
        outputVideoPath,
      );
      if (derivedOutputSidecarPath != exportRoiSidecarPath) return false;

      if (clips.isEmpty) return false;

      final List<VGROISample> aggregatedSamples = [];
      VGROISidecar? metadataSource;
      int cumulativeOutputMs = 0;

      for (final clip in clips) {
        final clipOutputDurationSeconds =
            clip.trimEndSeconds - clip.trimStartSeconds;
        final hasValidDuration =
            !clipOutputDurationSeconds.isNaN &&
            !clipOutputDurationSeconds.isInfinite &&
            clipOutputDurationSeconds > 0;
        // A clip with a degenerate output duration cannot safely advance the
        // shared output cursor, so it is skipped entirely (no ROI mapping,
        // no cursor advance) rather than risk misaligning later clips.
        if (!hasValidDuration) continue;

        final clipTransform = clip.transform;
        final mapped = await _mapClipSidecar(
          sourceVideoPath: clip.sourcePath,
          canvasWidth: canvasWidth,
          canvasHeight: canvasHeight,
          explicitSourceRoiSidecarPath: clip.sourceRoiSidecarPath,
          scaleX: clipTransform?.scaleX ?? 1.0,
          scaleY: clipTransform?.scaleY ?? 1.0,
          rotation: clipTransform?.rotation ?? 0.0,
          translationX: clipTransform?.translationX ?? 0.0,
          translationY: clipTransform?.translationY ?? 0.0,
          trimStartSeconds: clip.trimStartSeconds,
          trimEndSeconds: clip.trimEndSeconds,
        );

        if (mapped != null && mapped.samples.isNotEmpty) {
          metadataSource ??= mapped;
          for (final sample in mapped.samples) {
            aggregatedSamples.add(
              VGROISample(
                timestampMs: sample.timestampMs + cumulativeOutputMs,
                framePtsMs: sample.framePtsMs + cumulativeOutputMs,
                recordingRelativeMs:
                    sample.recordingRelativeMs + cumulativeOutputMs,
                box: sample.box,
                quality: sample.quality,
                confidence: sample.confidence,
                paddingPolicy: sample.paddingPolicy,
              ),
            );
          }
        }

        cumulativeOutputMs += (clipOutputDurationSeconds * 1000).round();
      }

      if (aggregatedSamples.isEmpty || metadataSource == null) return false;

      aggregatedSamples.sort((a, b) {
        final byTimestamp = a.timestampMs.compareTo(b.timestampMs);
        if (byTimestamp != 0) return byTimestamp;
        return a.framePtsMs.compareTo(b.framePtsMs);
      });

      final exportSidecar = VGROISidecar(
        version: metadataSource.version,
        sourceType: metadataSource.sourceType,
        platform: metadataSource.platform,
        coordinateSpace: 'export_output_normalized',
        recordingSessionId: metadataSource.recordingSessionId,
        videoIdentity: VGROIIdentity(
          durationMs: (exportDurationSeconds * 1000).round(),
          width: canvasWidth,
          height: canvasHeight,
          hash: null,
        ),
        coverage: metadataSource.coverage,
        samples: aggregatedSamples,
        finalized: true,
      );

      return await _writeSidecarAtomically(exportSidecar, exportRoiSidecarPath);
    } catch (_) {
      // Any ROI failure must leave the native empty sidecar in place, never
      // propagate.
      return false;
    }
  }

  /// Maps a single clip's source capture-time ROI sidecar into export-space,
  /// mirroring the coordinate-space / source-dimension policy of [process].
  ///
  /// [explicitSourceRoiSidecarPath], when non-null, takes strict precedence
  /// over the path derived from [sourceVideoPath] via
  /// [_sidecarPathForVideoPath]: if the explicit path is missing, malformed,
  /// or unsupported, this returns null -- it never falls back to the derived
  /// adjacent path. When null, the existing derived-path lookup is used.
  ///
  /// Returns null on any missing, unsupported, or malformed input -- never
  /// throws.
  static Future<VGROISidecar?> _mapClipSidecar({
    required String sourceVideoPath,
    required int canvasWidth,
    required int canvasHeight,
    String? explicitSourceRoiSidecarPath,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double rotation = 0.0,
    double translationX = 0.0,
    double translationY = 0.0,
    double trimStartSeconds = 0.0,
    double trimEndSeconds = double.infinity,
    bool passthroughPreservesSourceGeometry = false,
  }) async {
    try {
      final bool hasExplicitPath =
          explicitSourceRoiSidecarPath != null &&
          explicitSourceRoiSidecarPath.isNotEmpty;
      final sourceSidecarPath = hasExplicitPath
          ? explicitSourceRoiSidecarPath
          : _sidecarPathForVideoPath(sourceVideoPath);
      final sourceSidecarFile = File(sourceSidecarPath);
      if (!sourceSidecarFile.existsSync()) return null;

      final decoded = jsonDecode(await sourceSidecarFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final captureSidecar = VGROISidecar.fromJson(decoded);

      final mediaInfo = await VanguardMediaPreparer.inspectMedia(
        sourceVideoPath,
      );
      if (mediaInfo == null) return null;

      final isPassthroughNoTrim =
          trimStartSeconds == 0.0 && trimEndSeconds.isInfinite;
      final preserveSourceGeometry =
          passthroughPreservesSourceGeometry && isPassthroughNoTrim;

      double sourceWidth;
      double sourceHeight;
      double effectiveCanvasWidth = canvasWidth.toDouble();
      double effectiveCanvasHeight = canvasHeight.toDouble();
      switch (captureSidecar.coordinateSpace) {
        // Phase 5-Unit U: supports still images now that Android inspectMedia
        // returns real EXIF display bounds instead of zero dimensions.
        case 'display_source_normalized':
          sourceWidth = mediaInfo.displayWidth.toDouble();
          sourceHeight = mediaInfo.displayHeight.toDouble();
          if (preserveSourceGeometry) {
            effectiveCanvasWidth = sourceWidth;
            effectiveCanvasHeight = sourceHeight;
          }
          break;
        // portrait_capture_normalized for EXIF-rotated stills remains deferred.
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
          if (!isPassthroughNoTrim) return null;
          if (preserveSourceGeometry) {
            final identityWidth = captureSidecar.videoIdentity.width;
            final identityHeight = captureSidecar.videoIdentity.height;
            if (identityWidth <= 0 || identityHeight <= 0) return null;
            sourceWidth = identityWidth.toDouble();
            sourceHeight = identityHeight.toDouble();
            effectiveCanvasWidth = sourceWidth;
            effectiveCanvasHeight = sourceHeight;
          } else {
            if (captureSidecar.videoIdentity.width != canvasWidth ||
                captureSidecar.videoIdentity.height != canvasHeight) {
              return null;
            }
            sourceWidth = canvasWidth.toDouble();
            sourceHeight = canvasHeight.toDouble();
          }
          break;
        default:
          return null;
      }

      if (sourceWidth <= 0 || sourceHeight <= 0) return null;
      if (effectiveCanvasWidth <= 0 || effectiveCanvasHeight <= 0) {
        return null;
      }

      return VGROISidecarExportMapper.mapSidecar(
        captureSidecar: captureSidecar,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        canvasWidth: effectiveCanvasWidth,
        canvasHeight: effectiveCanvasHeight,
        scaleX: scaleX,
        scaleY: scaleY,
        rotation: rotation,
        translationX: translationX,
        translationY: translationY,
        trimStartSeconds: trimStartSeconds,
        trimEndSeconds: trimEndSeconds,
      );
    } catch (_) {
      // Any per-clip failure (parse error, mapper ArgumentError, I/O error,
      // etc.) must only drop this clip's ROI, never propagate.
      return null;
    }
  }

  /// Writes [sidecar] to [exportRoiSidecarPath] via a temp file next to it,
  /// then renames into place. On any write failure, only the temp file is
  /// deleted; the file already at [exportRoiSidecarPath] is never touched.
  static Future<bool> _writeSidecarAtomically(
    VGROISidecar sidecar,
    String exportRoiSidecarPath,
  ) async {
    final tempPath = '$exportRoiSidecarPath.vgroitmp';
    final tempFile = File(tempPath);
    try {
      await tempFile.writeAsString(jsonEncode(sidecar.toJson()));
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
