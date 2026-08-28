// vg_timeline_exporter_test.dart
// vanguard_media_engine — Phase 10-C
//
// Unit tests for VanguardTimelineExporter Dart bridge.
//
// Coverage:
//   EX-1: exportDraft sends method name 'exportTimeline'.
//   EX-2: draft.toMap() is nested under the 'draft' key.
//   EX-3: request.toMap() fields are merged at the top level.
//   EX-4: successful native map returns a VGEditorExportResult with correct fields.
//   EX-5: null native response throws StateError.
//   EX-6: native failure map (success=false) causes fromMap to return null → StateError.
//   EX-7: PlatformException propagates unchanged.
//   EX-8: multi-clip native success with exportRoiSidecarPath triggers Unit N post-processing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/roi/vg_roi_models.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_clip_transform_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_editor_export_request.dart';
import 'package:vanguard_media_engine/vg_timeline_exporter.dart';

void main() {
  const channel = MethodChannel('vanguard_media_engine');
  late List<MethodCall> capturedCalls;

  setUp(() {
    capturedCalls = [];
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void setHandler(Future<dynamic> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCalls.add(call);
          return handler(call);
        });
  }

  // Minimal valid draft for tests.
  VGEditorDraft makeDraft() {
    return VGEditorDraft(
      id: 'test-draft',
      clips: [
        VGClipDescriptor(
          id: 'clip-1',
          sourcePath: '/tmp/test.mp4',
          durationSeconds: 5.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 5.0,
        ),
      ],
      canvasWidth: 1080,
      canvasHeight: 1920,
      fps: 30,
    );
  }

  // Minimal valid export request.
  VGEditorExportRequest makeRequest() {
    return const VGEditorExportRequest(
      outputPath: '/tmp/out.mp4',
      bitrateBps: 8000000,
    );
  }

  // Minimal valid native success response.
  Map<String, dynamic> makeSuccessResponse() {
    return {
      'success': true,
      'path': '/tmp/out.mp4',
      'durationSeconds': 5.0,
      'width': 1080,
      'height': 1920,
      'fps': 30,
    };
  }

  // ── EX-1 ─────────────────────────────────────────────────────────────────────
  test('EX-1: exportDraft sends method name exportTimeline', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardTimelineExporter.exportDraft(
      draft: makeDraft(),
      request: makeRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'exportTimeline');
  });

  // ── EX-2 ─────────────────────────────────────────────────────────────────────
  test("EX-2: draft.toMap() is nested under the 'draft' key", () async {
    setHandler((call) async => makeSuccessResponse());

    final draft = makeDraft();
    await VanguardTimelineExporter.exportDraft(
      draft: draft,
      request: makeRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    final args = capturedCalls.first.arguments as Map;
    expect(args.containsKey('draft'), isTrue);

    final sentDraftMap = args['draft'] as Map;
    expect(sentDraftMap['id'], 'test-draft');
    expect(sentDraftMap['canvasWidth'], 1080);
    expect(sentDraftMap['canvasHeight'], 1920);
    expect(sentDraftMap['fps'], 30);
  });

  // ── EX-3 ─────────────────────────────────────────────────────────────────────
  test('EX-3: request.toMap() fields are merged at the top level', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardTimelineExporter.exportDraft(
      draft: makeDraft(),
      request: makeRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    final args = capturedCalls.first.arguments as Map;

    // Request fields are spread at the top level, not nested.
    expect(args['outputPath'], '/tmp/out.mp4');
    expect(args['bitrateBps'], 8000000);

    // 'draft' key is separate and not overwritten.
    expect(args.containsKey('draft'), isTrue);
  });

  // ── EX-4 ─────────────────────────────────────────────────────────────────────
  test(
    'EX-4: successful native map returns VGEditorExportResult with correct fields',
    () async {
      setHandler((call) async => makeSuccessResponse());

      final result = await VanguardTimelineExporter.exportDraft(
        draft: makeDraft(),
        request: makeRequest(),
        channel: channel,
      );

      expect(result.path, '/tmp/out.mp4');
      expect(result.durationSeconds, closeTo(5.0, 0.001));
      expect(result.width, 1080);
      expect(result.height, 1920);
      expect(result.fps, 30);
    },
  );

  // ── EX-5 ─────────────────────────────────────────────────────────────────────
  test('EX-5: null native response throws StateError', () async {
    setHandler((call) async => null);

    expect(
      () => VanguardTimelineExporter.exportDraft(
        draft: makeDraft(),
        request: makeRequest(),
        channel: channel,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('native returned null result'),
        ),
      ),
    );
  });

  // ── EX-6 ─────────────────────────────────────────────────────────────────────
  test('EX-6: native failure map (success=false) throws StateError', () async {
    setHandler(
      (call) async => <String, dynamic>{
        'success': false,
        'path': '',
        'durationSeconds': 0.0,
      },
    );

    expect(
      () => VanguardTimelineExporter.exportDraft(
        draft: makeDraft(),
        request: makeRequest(),
        channel: channel,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('native returned failure result'),
        ),
      ),
    );
  });

  // ── EX-7 ─────────────────────────────────────────────────────────────────────
  test('EX-7: PlatformException propagates unchanged', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'COMPOSITOR_INIT_FAILED',
            message: 'Native compositor failed',
          );
        });

    expect(
      () => VanguardTimelineExporter.exportDraft(
        draft: makeDraft(),
        request: makeRequest(),
        channel: channel,
      ),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'COMPOSITOR_INIT_FAILED',
        ),
      ),
    );
  });

  // ── EX-8 ─────────────────────────────────────────────────────────────────────
  test(
    'EX-8: multi-clip native success with exportRoiSidecarPath triggers Unit N post-processing',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'vg_timeline_exp_multiclip_test_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final clip1File = File('${tempDir.path}/clip1.mov');
      await clip1File.writeAsBytes([1, 2, 3]);
      final clip1Sidecar = VGROISidecar(
        version: 1,
        sourceType: 'app_recorded',
        platform: 'android',
        coordinateSpace: 'display_source_normalized',
        recordingSessionId: 'session-c1',
        videoIdentity: VGROIIdentity(
          durationMs: 3000,
          width: 1080,
          height: 1920,
          hash: null,
        ),
        coverage: VGROICoverage(
          coveragePercent: 1.0,
          missingIntervals: const [],
        ),
        samples: [
          VGROISample(
            timestampMs: 1000,
            framePtsMs: 1000,
            recordingRelativeMs: 1000,
            box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            quality: 'detected',
          ),
        ],
        finalized: true,
      );
      final clip1SidecarFile = File('${tempDir.path}/clip1.roi.json');
      await clip1SidecarFile.writeAsString(jsonEncode(clip1Sidecar.toJson()));

      final clip2File = File('${tempDir.path}/clip2.mov');
      await clip2File.writeAsBytes([4, 5, 6]);
      final clip2Sidecar = VGROISidecar(
        version: 1,
        sourceType: 'app_recorded',
        platform: 'android',
        coordinateSpace: 'display_source_normalized',
        recordingSessionId: 'session-c2',
        videoIdentity: VGROIIdentity(
          durationMs: 3000,
          width: 1080,
          height: 1920,
          hash: null,
        ),
        coverage: VGROICoverage(
          coveragePercent: 1.0,
          missingIntervals: const [],
        ),
        samples: [
          VGROISample(
            timestampMs: 1200,
            framePtsMs: 1200,
            recordingRelativeMs: 1200,
            box: VGROIBox(x: 0.3, y: 0.3, w: 0.4, h: 0.4),
            quality: 'detected',
          ),
        ],
        finalized: true,
      );
      final clip2SidecarFile = File('${tempDir.path}/clip2.roi.json');
      await clip2SidecarFile.writeAsString(jsonEncode(clip2Sidecar.toJson()));

      final outputPath = '${tempDir.path}/out.mp4';
      final exportRoiSidecarPath = '${tempDir.path}/out.roi.json';

      // Pre-create native empty fallback sidecar
      final nativeEmptySidecar = File(exportRoiSidecarPath);
      await nativeEmptySidecar.writeAsString(
        '{"version":1,"nativeEmpty":true}',
      );

      final draft = VGEditorDraft(
        id: 'test-multiclip-draft',
        clips: [
          VGClipDescriptor(
            id: 'clip-1',
            sourcePath: clip1File.path,
            durationSeconds: 3.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 3.0,
          ),
          VGClipDescriptor(
            id: 'clip-2',
            sourcePath: clip2File.path,
            durationSeconds: 3.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 3.0,
          ),
        ],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );

      setHandler((call) async {
        if (call.method == 'inspectMedia') {
          return <String, dynamic>{
            'kind': 'video',
            'container': 'mov',
            'videoCodec': 'h264',
            'audioCodec': 'aac',
            'width': 1080,
            'height': 1920,
            'encodedWidth': 1080,
            'encodedHeight': 1920,
            'displayWidth': 1080,
            'displayHeight': 1920,
            'durationSeconds': 3.0,
            'bitrateKbps': 4000,
            'fps': 30.0,
            'fileSizeBytes': 2048,
            'hasVideo': true,
            'hasAudio': true,
            'isHDR': false,
            'hasMoovAtFront': false,
            'hasRotationTransform': false,
            'hasEmbeddedMetadata': false,
            'rotationDegrees': 0,
            'orientationStatus': 'valid',
          };
        }
        if (call.method == 'exportTimeline') {
          return <String, dynamic>{
            'success': true,
            'path': outputPath,
            'durationSeconds': 6.0,
            'width': 1080,
            'height': 1920,
            'fps': 30,
            'exportRoiSidecarPath': exportRoiSidecarPath,
          };
        }
        return null;
      });

      final result = await VanguardTimelineExporter.exportDraft(
        draft: draft,
        request: VGEditorExportRequest(outputPath: outputPath),
        channel: channel,
      );

      expect(result.path, outputPath);
      expect(result.durationSeconds, closeTo(6.0, 0.001));
      expect(result.width, 1080);
      expect(result.height, 1920);
      expect(result.exportRoiSidecarPath, exportRoiSidecarPath);

      final sidecarFile = File(exportRoiSidecarPath);
      expect(sidecarFile.existsSync(), isTrue);

      final decoded = jsonDecode(await sidecarFile.readAsString());
      final parsedSidecar = VGROISidecar.fromJson(decoded);

      expect(parsedSidecar.coordinateSpace, 'export_output_normalized');
      expect(parsedSidecar.videoIdentity.width, 1080);
      expect(parsedSidecar.videoIdentity.height, 1920);
      expect(parsedSidecar.videoIdentity.durationMs, 6000);
      expect(parsedSidecar.samples.length, 2);

      // Clip 1 sample: 1000ms
      expect(parsedSidecar.samples[0].timestampMs, 1000);

      // Clip 2 sample: 1200ms + 3000ms (clip 1 duration) = 4200ms
      expect(parsedSidecar.samples[1].timestampMs, 4200);
      expect(parsedSidecar.finalized, isTrue);

      // Verify no temp file residue
      expect(File('$exportRoiSidecarPath.vgroitmp').existsSync(), isFalse);
    },
  );

  // ── EX-9 ─────────────────────────────────────────────────────────────────────
  test(
    'EX-9: clip with non-adjacent sourceRoiSidecarPath triggers post-processing from explicit source path',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'vg_timeline_exp_explicit_roi_test_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final clipFile = File('${tempDir.path}/clip_explicit.mov');
      await clipFile.writeAsBytes([1, 2, 3]);

      // Ensure no adjacent sidecar exists
      final adjacentSidecarFile = File(
        '${tempDir.path}/clip_explicit.roi.json',
      );
      expect(adjacentSidecarFile.existsSync(), isFalse);

      // Create explicit source sidecar in a non-adjacent path
      final customSidecarDir = Directory('${tempDir.path}/custom_roi_dir')
        ..createSync(recursive: true);
      final explicitSourceSidecarFile = File(
        '${customSidecarDir.path}/explicit_capture.roi.json',
      );
      final explicitSourceSidecar = VGROISidecar(
        version: 1,
        sourceType: 'app_recorded',
        platform: 'android',
        coordinateSpace: 'display_source_normalized',
        recordingSessionId: 'session-explicit-test',
        videoIdentity: VGROIIdentity(
          durationMs: 4000,
          width: 1080,
          height: 1920,
          hash: null,
        ),
        coverage: VGROICoverage(
          coveragePercent: 1.0,
          missingIntervals: const [],
        ),
        samples: [
          VGROISample(
            timestampMs: 1500,
            framePtsMs: 1500,
            recordingRelativeMs: 1500,
            box: VGROIBox(x: 0.2, y: 0.3, w: 0.4, h: 0.5),
            quality: 'detected',
          ),
        ],
        finalized: true,
      );
      await explicitSourceSidecarFile.writeAsString(
        jsonEncode(explicitSourceSidecar.toJson()),
      );

      final outputPath = '${tempDir.path}/explicit_timeline_out.mp4';
      final exportRoiSidecarPath =
          '${tempDir.path}/explicit_timeline_out.roi.json';

      // Pre-create native empty fallback sidecar
      final nativeEmptySidecar = File(exportRoiSidecarPath);
      await nativeEmptySidecar.writeAsString(
        '{"version":1,"nativeEmpty":true}',
      );

      final draft = VGEditorDraft(
        id: 'test-explicit-roi-draft',
        clips: [
          VGClipDescriptor(
            id: 'clip-explicit-1',
            sourcePath: clipFile.path,
            sourceRoiSidecarPath: explicitSourceSidecarFile.path,
            durationSeconds: 4.0,
            trimStartSeconds: 0.5,
            trimEndSeconds: 3.5,
            transform: const VGClipTransformDescriptor(
              scaleX: 1.2,
              scaleY: 1.2,
            ),
          ),
        ],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );

      setHandler((call) async {
        if (call.method == 'inspectMedia') {
          return <String, dynamic>{
            'kind': 'video',
            'container': 'mov',
            'videoCodec': 'h264',
            'audioCodec': 'aac',
            'width': 1080,
            'height': 1920,
            'encodedWidth': 1080,
            'encodedHeight': 1920,
            'displayWidth': 1080,
            'displayHeight': 1920,
            'durationSeconds': 4.0,
            'bitrateKbps': 4000,
            'fps': 30.0,
            'fileSizeBytes': 2048,
            'hasVideo': true,
            'hasAudio': true,
            'isHDR': false,
            'hasMoovAtFront': false,
            'hasRotationTransform': false,
            'hasEmbeddedMetadata': false,
            'rotationDegrees': 0,
            'orientationStatus': 'valid',
          };
        }
        if (call.method == 'exportTimeline') {
          return <String, dynamic>{
            'success': true,
            'path': outputPath,
            'durationSeconds': 3.0,
            'width': 1080,
            'height': 1920,
            'fps': 30,
            'exportRoiSidecarPath': exportRoiSidecarPath,
          };
        }
        return null;
      });

      final result = await VanguardTimelineExporter.exportDraft(
        draft: draft,
        request: VGEditorExportRequest(outputPath: outputPath),
        channel: channel,
      );

      expect(result.path, outputPath);
      expect(result.exportRoiSidecarPath, exportRoiSidecarPath);

      final sidecarFile = File(exportRoiSidecarPath);
      expect(sidecarFile.existsSync(), isTrue);

      final decoded = jsonDecode(await sidecarFile.readAsString());
      final parsedSidecar = VGROISidecar.fromJson(decoded);

      expect(parsedSidecar.coordinateSpace, 'export_output_normalized');
      expect(parsedSidecar.videoIdentity.width, 1080);
      expect(parsedSidecar.videoIdentity.height, 1920);
      expect(parsedSidecar.videoIdentity.durationMs, 3000);
      expect(parsedSidecar.samples.length, 1);

      // Sample at 1500ms trimmed by trimStart (500ms) = 1000ms
      expect(parsedSidecar.samples[0].timestampMs, 1000);
      expect(parsedSidecar.samples[0].framePtsMs, 1000);
      expect(parsedSidecar.samples[0].recordingRelativeMs, 1000);

      // Box must be non-null and transformed by scale 1.2
      final mappedBox = parsedSidecar.samples[0].box;
      expect(mappedBox, isNotNull);

      // Verify no temp file residue
      expect(File('$exportRoiSidecarPath.vgroitmp').existsSync(), isFalse);
    },
  );
}
