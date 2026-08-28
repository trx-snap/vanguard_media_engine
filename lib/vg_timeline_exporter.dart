// vg_timeline_exporter.dart
// Vanguard Media Engine — Phase 10-C Typed Headless Timeline Export API.
//
// One-shot, headless timeline export bridge.
//
// Design rules:
//   - Stateless. No instance state, no lifecycle.
//   - Does not initialise VGEditorController.
//   - Does not allocate or require a preview texture.
//   - Does not depend on VGGraphRuntime or the playback runtime.
//   - Audio flattening (flattenOriginalClipAudio / applyAudioCompositionPolicy)
//     is the caller's responsibility — this class receives a fully prepared draft.
//   - The optional [channel] parameter enables test injection without
//     depending on the iOS/native runtime.
//
// Export progress:
//   - [exportDraft] accepts an optional [onProgress] callback (0.0 → 1.0).
//   - A [VGExportSubscription] is registered with [VanguardChannelDispatcher]
//     for the duration of the export to receive 'onExportProgress' events.
//   - The subscription is unregistered in a finally block (success, error,
//     cancellation).
//   - Progress values are clamped to [0.0, 1.0] by the dispatcher.
//
// Export concurrency note:
//   exportTimeline has no native single-export guard. Concurrent exports
//   may both execute. The most recent export subscription receives shared
//   onExportProgress events. Older export Futures complete via their own
//   result() callbacks regardless.

import 'package:flutter/services.dart';

import 'src/channel/vanguard_channel_dispatcher.dart';
import 'src/roi/vg_roi_export_sidecar_post_processor.dart';
import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';
import 'vg_editor_export_result.dart';

/// One-shot, headless timeline export API.
///
/// Invokes the `exportTimeline` native route on the `vanguard_media_engine`
/// MethodChannel. The native handler is fully independent of the playback
/// runtime -- it does not require a preview texture, a timeline runtime, or a
/// [VGEditorController] to have been initialised.
///
/// **Audio:** The caller must apply any required audio transforms to the draft
/// (e.g. [VGEditorDraft.flattenOriginalClipAudio] and
/// [VGEditorDraft.applyAudioCompositionPolicy]) before passing it here.
///
/// **Progress:** When [onProgress] is supplied, real frame-level progress
/// events (0.0 → 1.0) are received from the native VGExportScheduler via
/// a [VGExportSubscription] registered with [VanguardChannelDispatcher].
/// The subscription is unregistered in a finally block on all exit paths.
///
/// **Cancellation:** The native compositor is not cancellable once started.
/// Post-export output cleanup is the caller's responsibility.
///
/// **Concurrency:** [exportTimeline] has no native single-export guard.
/// Concurrent calls may both execute natively. The most recent progress
/// registration receives shared progress events; older Futures still complete.
///
/// ```dart
/// final exportDraft =
///     draft.flattenOriginalClipAudio().applyAudioCompositionPolicy();
/// final result = await VanguardTimelineExporter.exportDraft(
///   draft: exportDraft,
///   request: VGEditorExportRequest(outputPath: '/tmp/out.mp4', bitrateBps: 8000000),
///   onProgress: (p) => print('Export: ${(p * 100).toStringAsFixed(0)}%'),
/// );
/// print(result.path);
/// ```
final class VanguardTimelineExporter {
  // Private constructor: stateless static API only.
  const VanguardTimelineExporter._();

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Exports a timeline draft as an MP4 file.
  ///
  /// [draft] must be a fully prepared [VGEditorDraft] -- audio flattening and
  /// ducking must have been applied before calling this method.
  ///
  /// [request] configures the output path, bitrate, dimensions, and fps.
  /// Null fields in [request] fall back to native defaults (the draft's own
  /// canvas dimensions and fps, and a 2 Mbps default bitrate).
  ///
  /// [onProgress] is an optional callback that receives real frame-level
  /// progress values in [0.0, 1.0] as the native export proceeds. When null,
  /// no progress subscription is registered.
  ///
  /// [channel] is optional and exists only for test injection. Production
  /// callers must not supply it.
  ///
  /// Returns a [VGEditorExportResult] on success.
  ///
  /// Throws [PlatformException] on native compositor failure.
  /// Throws [StateError] if the native response is null or reports a failure.
  static Future<VGEditorExportResult> exportDraft({
    required VGEditorDraft draft,
    required VGEditorExportRequest request,
    void Function(double progress)? onProgress,
    MethodChannel channel = _defaultChannel,
  }) async {
    // Register with the dispatcher (not setMethodCallHandler) to receive
    // 'onExportProgress' events. The subscription is unregistered in the
    // finally block on all exit paths (success, error, cancellation).
    //
    // The dispatcher is the sole handler owner — this exporter must not
    // call channel.setMethodCallHandler directly.
    VGExportSubscription? exportSub;
    if (onProgress != null) {
      exportSub = VanguardChannelDispatcher.instance.registerExportListener(
        onProgress,
      );
    }

    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'exportTimeline',
        <String, Object?>{'draft': draft.toMap(), ...request.toMap()},
      );

      if (result == null) {
        throw StateError(
          '[VanguardTimelineExporter] exportDraft: native returned null result',
        );
      }

      final exportResult = VGEditorExportResult.fromMap(
        result.map((key, value) => MapEntry<Object?, Object?>(key, value)),
      );

      if (exportResult == null) {
        throw StateError(
          '[VanguardTimelineExporter] exportDraft: native returned failure result',
        );
      }

      // Best-effort ROI sidecar upgrade. Single-clip exports use the direct
      // per-clip mapping; any other clip count (including hard-cut
      // multi-clip timelines, Phase 5-Unit N) is composed via
      // processTimeline. Never affects the returned result: the
      // post-processor fails closed and leaves the native empty sidecar in
      // place on any error.
      final sidecarPath = exportResult.exportRoiSidecarPath;
      final width = exportResult.width;
      final height = exportResult.height;
      if (sidecarPath != null &&
          width != null &&
          width > 0 &&
          height != null &&
          height > 0 &&
          exportResult.durationSeconds > 0) {
        if (draft.clips.length == 1) {
          final clip = draft.clips.single;
          await VGRoiExportSidecarPostProcessor.process(
            sourceVideoPath: clip.sourcePath,
            outputVideoPath: exportResult.path,
            exportRoiSidecarPath: sidecarPath,
            canvasWidth: width,
            canvasHeight: height,
            trimStartSeconds: clip.trimStartSeconds,
            trimEndSeconds: clip.trimEndSeconds,
          );
        } else {
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: draft.clips,
            outputVideoPath: exportResult.path,
            exportRoiSidecarPath: sidecarPath,
            canvasWidth: width,
            canvasHeight: height,
            exportDurationSeconds: exportResult.durationSeconds,
          );
        }
      }

      return exportResult;
    } finally {
      // Always unregister the export subscription — success, error, or
      // cancellation. This prevents the callback from receiving events from
      // a subsequent export.
      if (exportSub != null) {
        VanguardChannelDispatcher.instance.unregisterExportListener(exportSub);
      }
    }
  }
}
