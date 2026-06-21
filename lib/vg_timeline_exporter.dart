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

import 'package:flutter/services.dart';

import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';
import 'vg_editor_export_result.dart';

/// One-shot, headless timeline export API.
///
/// Invokes the `exportTimeline` native route on the `vanguard_media_engine`
/// MethodChannel. The native handler is fully independent of the playback
/// runtime — it does not require a preview texture, a timeline runtime, or a
/// [VGEditorController] to have been initialised.
///
/// **Audio:** The caller must apply any required audio transforms to the draft
/// (e.g. [VGEditorDraft.flattenOriginalClipAudio] and
/// [VGEditorDraft.applyAudioDucking]) before passing it here.
///
/// **Progress:** The native `exportTimeline` route does not stream progress
/// events. Progress tracking beyond 0 → 1 is not supported by this API.
///
/// **Cancellation:** The native compositor is not cancellable once started.
/// Post-export output cleanup is the caller's responsibility.
///
/// ```dart
/// final exportDraft = draft.flattenOriginalClipAudio().applyAudioDucking();
/// final result = await VanguardTimelineExporter.exportDraft(
///   draft: exportDraft,
///   request: VGEditorExportRequest(outputPath: '/tmp/out.mp4', bitrateBps: 8000000),
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
  /// [draft] must be a fully prepared [VGEditorDraft] — audio flattening and
  /// ducking must have been applied before calling this method.
  ///
  /// [request] configures the output path, bitrate, dimensions, and fps.
  /// Null fields in [request] fall back to native defaults (the draft's own
  /// canvas dimensions and fps, and a 2 Mbps default bitrate).
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
    MethodChannel channel = _defaultChannel,
  }) async {
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
  }
}
