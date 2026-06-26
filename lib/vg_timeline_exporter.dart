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
//   - Audio flattening (flattenOriginalClipAudio / applyAudioDucking) is the
//     caller's responsibility — this class receives a fully prepared draft.
//   - The optional [channel] parameter enables test injection without
//     depending on the iOS/native runtime.
//
// Phase 10 Real Export Progress:
//   - [exportDraft] accepts an optional [onProgress] callback (0.0 -> 1.0).
//   - A temporary setMethodCallHandler is registered on [channel] for the
//     duration of the export to receive 'onExportProgress' MethodChannel events
//     fired by the native VGExportScheduler via VGTimelineExportHelper.
//   - The handler is cleared in a finally block.
//   - Progress values are clamped to [0.0, 1.0].
//   - Amendment 3: This resolves the MethodChannel multiplexing gap -- without
//     this temporary handler, onExportProgress events are silently dropped
//     because VanguardTimelineExporter does not allocate a VanguardEngine
//     instance (which is the only existing listener for onExportProgress).

import 'package:flutter/services.dart';

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
/// [VGEditorDraft.applyAudioDucking]) before passing it here.
///
/// **Progress:** When [onProgress] is supplied, real frame-level progress
/// events (0.0 -> 1.0) are received from the native VGExportScheduler via
/// VGTimelineExportHelper. A temporary MethodChannel handler is registered for
/// the duration of the export and cleared in a finally block. Progress values
/// are clamped to [0.0, 1.0].
///
/// **Cancellation:** The native compositor is not cancellable once started.
/// Post-export output cleanup is the caller's responsibility.
///
/// ```dart
/// final exportDraft = draft.flattenOriginalClipAudio().applyAudioDucking();
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

  static const MethodChannel _defaultChannel =
      MethodChannel('vanguard_media_engine');

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
  /// no progress handler is registered and the export runs as before.
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
    // Phase 10 Amendment 3: register a temporary MethodChannel handler to
    // receive 'onExportProgress' events fired by the native VGExportScheduler
    // via VGTimelineExportHelper.
    //
    // VanguardTimelineExporter does not allocate a VanguardEngine instance --
    // VanguardEngine is the only existing listener for onExportProgress (via
    // its setMethodCallHandler in its constructor). Without this temporary
    // handler, all onExportProgress events are silently dropped.
    //
    // The handler is cleared in a finally block to avoid leaving stale
    // handlers on the channel after export completes or throws.
    if (onProgress != null) {
      channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'onExportProgress') {
          final raw = call.arguments;
          if (raw is num) {
            final clamped = raw.toDouble().clamp(0.0, 1.0);
            onProgress(clamped);
          }
        }
        // Silently ignore any other calls during export.
        // This handler is only in place for the export duration.
      });
    }

    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'exportTimeline',
        <String, Object?>{
          'draft': draft.toMap(),
          ...request.toMap(),
        },
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

      return exportResult;
    } finally {
      // Always clear the temporary handler after export -- whether success,
      // failure, or cancellation. This restores the channel to its normal
      // state (no handler on VanguardTimelineExporter's channel instance).
      if (onProgress != null) {
        channel.setMethodCallHandler(null);
      }
    }
  }
}
