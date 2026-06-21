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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
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
  VGEditorDraft _makeDraft() {
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
  VGEditorExportRequest _makeRequest() {
    return const VGEditorExportRequest(
      outputPath: '/tmp/out.mp4',
      bitrateBps: 8000000,
    );
  }

  // Minimal valid native success response.
  Map<String, dynamic> _makeSuccessResponse() {
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
    setHandler((call) async => _makeSuccessResponse());

    await VanguardTimelineExporter.exportDraft(
      draft: _makeDraft(),
      request: _makeRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'exportTimeline');
  });

  // ── EX-2 ─────────────────────────────────────────────────────────────────────
  test("EX-2: draft.toMap() is nested under the 'draft' key", () async {
    setHandler((call) async => _makeSuccessResponse());

    final draft = _makeDraft();
    await VanguardTimelineExporter.exportDraft(
      draft: draft,
      request: _makeRequest(),
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
    setHandler((call) async => _makeSuccessResponse());

    await VanguardTimelineExporter.exportDraft(
      draft: _makeDraft(),
      request: _makeRequest(),
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
      setHandler((call) async => _makeSuccessResponse());

      final result = await VanguardTimelineExporter.exportDraft(
        draft: _makeDraft(),
        request: _makeRequest(),
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
        draft: _makeDraft(),
        request: _makeRequest(),
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
  test(
    'EX-6: native failure map (success=false) throws StateError',
    () async {
      setHandler(
        (call) async => <String, dynamic>{
          'success': false,
          'path': '',
          'durationSeconds': 0.0,
        },
      );

      expect(
        () => VanguardTimelineExporter.exportDraft(
          draft: _makeDraft(),
          request: _makeRequest(),
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
    },
  );

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
        draft: _makeDraft(),
        request: _makeRequest(),
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
}
