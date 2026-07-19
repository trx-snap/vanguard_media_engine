// vg_audio_parity_slice_l_test.dart
// Vanguard Media Engine — Slice L Preview/Export Parity Gate Tests
//
// Verifies that:
// 1. Scenarios A, B, C, D produce the expected ducking/muting layout.
// 2. The serialized audioSidecar plan sent to preview (createTimelineTexture/updateTimeline)
//    and export (exportTimeline) are structurally identical.
// 3. The raw authoring VGEditorDraft is never mutated by these operations.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_editor_export_request.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('vanguard_media_engine');

  VGClipDescriptor clip({required String id, double duration = 5.0}) =>
      VGClipDescriptor(
        id: id,
        sourcePath: '/tmp/clip_$id.mp4',
        durationSeconds: duration,
        trimStartSeconds: 0.0,
        trimEndSeconds: duration,
      );

  VGAudioSidecarTrack track({
    required String id,
    required String role,
    double volume = 1.0,
    double startTime = 0.0,
    double duration = 5.0,
  }) =>
      VGAudioSidecarTrack(
        trackId: id,
        url: '/tmp/track_$id.mp3',
        startTime: startTime,
        duration: duration,
        volume: volume,
        role: role,
      );

  // Helper to extract tracks list from raw channel invocation map
  List<Map<dynamic, dynamic>> getTracks(Map? draftMap) {
    if (draftMap == null) return [];
    final sidecar = draftMap['audioSidecar'] as Map?;
    if (sidecar == null) return [];
    final tracks = sidecar['tracks'] as List?;
    if (tracks == null) return [];
    return tracks.cast<Map<dynamic, dynamic>>();
  }

  group('Slice L - Dart Preview/Export Audio Parity Tests', () {
    late List<Map<dynamic, dynamic>> capturedPreviewTracks;
    late List<Map<dynamic, dynamic>> capturedExportTracks;

    setUp(() {
      capturedPreviewTracks = [];
      capturedExportTracks = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'createTimelineTexture') {
          final draft = call.arguments['draft'] as Map?;
          capturedPreviewTracks = getTracks(draft);
          return {'textureId': 100, 'width': 640, 'height': 360};
        }
        if (call.method == 'updateTimeline') {
          final draft = call.arguments['draft'] as Map?;
          capturedPreviewTracks = getTracks(draft);
          return {'textureId': 100, 'width': 640, 'height': 360};
        }
        if (call.method == 'exportTimeline') {
          final draft = call.arguments['draft'] as Map?;
          capturedExportTracks = getTracks(draft);
          return {'path': '/tmp/out.mp4', 'durationSeconds': 5.0};
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario A: Video only (Original normal, no Added/VO)
    // ─────────────────────────────────────────────────────────────────────────
    test('Scenario A: Video only (Original normal, no Added/VO)', () async {
      final rawDraft = VGEditorDraft(
        id: 'scenario-A',
        clips: [clip(id: 'A', duration: 4.0)],
        audioSidecarPlan: null, // no external tracks
      );

      final controller = VGEditorController(initialDraft: rawDraft);
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.export(const VGEditorExportRequest(outputPath: '/tmp/out.mp4'));

      expect(capturedPreviewTracks, hasLength(1));
      expect(capturedExportTracks, hasLength(1));

      final pTrack = capturedPreviewTracks.first;
      final eTrack = capturedExportTracks.first;

      // Both must have role original, normal volume (1.0), and matching identifiers
      expect(pTrack['role'], 'original');
      expect(eTrack['role'], 'original');
      expect((pTrack['volume'] as num).toDouble(), closeTo(1.0, 0.001));
      expect((eTrack['volume'] as num).toDouble(), closeTo(1.0, 0.001));

      // Assert complete structural parity
      expect(pTrack, equals(eTrack));
      // Assert raw draft was not mutated
      expect(rawDraft.audioSidecarPlan, isNull);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario B: Added only (Original muted, Added normal)
    // ─────────────────────────────────────────────────────────────────────────
    test('Scenario B: Added only (Original muted, Added normal)', () async {
      final rawDraft = VGEditorDraft(
        id: 'scenario-B',
        clips: [clip(id: 'A', duration: 5.0)],
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [
            track(id: 'music-1', role: 'music', volume: 0.8, startTime: 0.0, duration: 5.0),
          ],
        ),
      );

      final controller = VGEditorController(initialDraft: rawDraft);
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.export(const VGEditorExportRequest(outputPath: '/tmp/out.mp4'));

      expect(capturedPreviewTracks, hasLength(2));
      expect(capturedExportTracks, hasLength(2));

      // Match tracks by role
      final pOrig = capturedPreviewTracks.firstWhere((t) => t['role'] == 'original');
      final eOrig = capturedExportTracks.firstWhere((t) => t['role'] == 'original');
      final pMusic = capturedPreviewTracks.firstWhere((t) => t['role'] == 'music');
      final eMusic = capturedExportTracks.firstWhere((t) => t['role'] == 'music');

      // Original must be muted (volume = 0.0) due to presence of music
      expect((pOrig['volume'] as num).toDouble(), closeTo(0.0, 0.001));
      expect((eOrig['volume'] as num).toDouble(), closeTo(0.0, 0.001));

      // Music remains normal (0.8)
      expect((pMusic['volume'] as num).toDouble(), closeTo(0.8, 0.001));
      expect((eMusic['volume'] as num).toDouble(), closeTo(0.8, 0.001));

      expect(capturedPreviewTracks, equals(capturedExportTracks));
      // Assert raw draft was not mutated (no original track in the authoring model)
      expect(rawDraft.audioSidecarPlan!.tracks, hasLength(1));
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario C: VO only (Original muted, VO dominant)
    // ─────────────────────────────────────────────────────────────────────────
    test('Scenario C: VO only (Original muted, VO dominant)', () async {
      final rawDraft = VGEditorDraft(
        id: 'scenario-C',
        clips: [clip(id: 'A', duration: 6.0)],
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [
            track(id: 'vo-1', role: 'voiceover', volume: 1.0, startTime: 1.0, duration: 3.0),
          ],
        ),
      );

      final controller = VGEditorController(initialDraft: rawDraft);
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.export(const VGEditorExportRequest(outputPath: '/tmp/out.mp4'));

      expect(capturedPreviewTracks, hasLength(2));
      expect(capturedExportTracks, hasLength(2));

      final pOrig = capturedPreviewTracks.firstWhere((t) => t['role'] == 'original');
      final eOrig = capturedExportTracks.firstWhere((t) => t['role'] == 'original');
      final pVO = capturedPreviewTracks.firstWhere((t) => t['role'] == 'voiceover');
      final eVO = capturedExportTracks.firstWhere((t) => t['role'] == 'voiceover');

      // Original must be muted (volume = 0.0)
      expect((pOrig['volume'] as num).toDouble(), closeTo(0.0, 0.001));
      expect((eOrig['volume'] as num).toDouble(), closeTo(0.0, 0.001));

      // VO remains dominant (1.0)
      expect((pVO['volume'] as num).toDouble(), closeTo(1.0, 0.001));
      expect((eVO['volume'] as num).toDouble(), closeTo(1.0, 0.001));

      expect(capturedPreviewTracks, equals(capturedExportTracks));
      expect(rawDraft.audioSidecarPlan!.tracks, hasLength(1));
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario D: Added + VO (Original muted, Added ducked, VO dominant)
    // ─────────────────────────────────────────────────────────────────────────
    test('Scenario D: Added + VO (Original muted, Added ducked, VO dominant)', () async {
      final rawDraft = VGEditorDraft(
        id: 'scenario-D',
        clips: [clip(id: 'A', duration: 8.0)],
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [
            track(id: 'music-1', role: 'music', volume: 0.8, startTime: 0.0, duration: 8.0),
            track(id: 'vo-1', role: 'voiceover', volume: 1.0, startTime: 2.0, duration: 4.0),
          ],
        ),
      );

      final controller = VGEditorController(initialDraft: rawDraft);
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.export(const VGEditorExportRequest(outputPath: '/tmp/out.mp4'));

      expect(capturedPreviewTracks, hasLength(3));
      expect(capturedExportTracks, hasLength(3));

      final pOrig = capturedPreviewTracks.firstWhere((t) => t['role'] == 'original');
      final eOrig = capturedExportTracks.firstWhere((t) => t['role'] == 'original');
      final pMusic = capturedPreviewTracks.firstWhere((t) => t['role'] == 'music');
      final eMusic = capturedExportTracks.firstWhere((t) => t['role'] == 'music');
      final pVO = capturedPreviewTracks.firstWhere((t) => t['role'] == 'voiceover');
      final eVO = capturedExportTracks.firstWhere((t) => t['role'] == 'voiceover');

      // Original muted
      expect((pOrig['volume'] as num).toDouble(), closeTo(0.0, 0.001));
      expect((eOrig['volume'] as num).toDouble(), closeTo(0.0, 0.001));

      // VO dominant
      expect((pVO['volume'] as num).toDouble(), closeTo(1.0, 0.001));
      expect((eVO['volume'] as num).toDouble(), closeTo(1.0, 0.001));

      // Music must be ducked. Let's verify that both contain keyframes and are identical.
      expect(pMusic['volumeKeyframes'], isNotNull);
      expect(eMusic['volumeKeyframes'], isNotNull);
      expect(pMusic['volumeKeyframes'], equals(eMusic['volumeKeyframes']));

      expect(capturedPreviewTracks, equals(capturedExportTracks));
      expect(rawDraft.audioSidecarPlan!.tracks, hasLength(2));
    });
  });
}
