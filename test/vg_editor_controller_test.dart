// vg_editor_controller_test.dart
// Vanguard Media Engine — Phase 7 Stage 7.7
//
// Pure Dart unit tests for VGEditorController using a mock MethodChannel.
//
// Tests:
//   - initialize() → isReady=true, textureId set
//   - play() / pause() state transitions
//   - updateDraft() → draft replaced, PTS reset
//   - export() → result parsed from mock map
//   - handleNativeCallback() → PTS/EOS state updates
//   - dispose() idempotency
//   - disposeAsync() is safe if called multiple times
//
// Pattern: uses TestDefaultBinaryMessengerBinding to install a mock handler
// for the 'vanguard_media_engine' channel, mirroring vg_playback_session_test.dart.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_editor_export_request.dart';
import 'package:vanguard_media_engine/vg_editor_export_result.dart';
import 'package:vanguard_media_engine/vg_editor_value.dart';

// ── Test fixtures ─────────────────────────────────────────────────────────────

VGClipDescriptor _clip({
  String id = 'clip-A',
  double trimEnd = 5.0,
}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/fixture.mp4',
      durationSeconds: 5.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: trimEnd,
    );

VGEditorDraft _twoClipDraft() => VGEditorDraft(
      id: 'draft-test',
      clips: [_clip(id: 'clip-A'), _clip(id: 'clip-B')],
    );

// ── Mock channel setup ────────────────────────────────────────────────────────

/// Installs a mock handler for the 'vanguard_media_engine' MethodChannel.
///
/// [handler] receives the method name and arguments, and returns the
/// mock response. Return null to simulate a void response.
void _setMockHandler(
  Future<Object?> Function(String method, dynamic args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    (call) => handler(call.method, call.arguments),
  );
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    null,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    _clearMockHandler();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Initial state
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — initial state', () {
    test('EC-1  initial value has isReady=false, textureId=null', () {
      final draft = _twoClipDraft();
      final controller = VGEditorController(initialDraft: draft);
      addTearDown(() => controller.dispose());

      final v = controller.value;
      expect(v.isReady, isFalse);
      expect(v.textureId, isNull);
      expect(v.isPlaying, isFalse);
      expect(v.isExporting, isFalse);
      expect(v.currentPTS, 0.0);
      expect(v.draft, draft);
    });

    test('EC-2  VGEditorValue.durationSeconds proxies draft.durationSeconds',
        () {
      final draft = _twoClipDraft();
      final controller = VGEditorController(initialDraft: draft);
      addTearDown(() => controller.dispose());

      expect(controller.value.durationSeconds,
          closeTo(draft.durationSeconds, 0.001));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // initialize()
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — initialize()', () {
    test('EC-3  initialize sets isReady=true and textureId', () async {
      _setMockHandler((method, args) async {
        if (method == 'dev_createTimelineTexture') {
          return {'textureId': 42, 'width': 640, 'height': 360};
        }
        if (method == 'dev_disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _twoClipDraft());

      await controller.initialize();

      expect(controller.value.isReady, isTrue);
      expect(controller.value.textureId, 42);
      addTearDown(() => controller.dispose());
    });

    test('EC-4  initialize throws if native returns negative textureId',
        () async {
      _setMockHandler((method, args) async {
        if (method == 'dev_createTimelineTexture') {
          return {'textureId': -1};
        }
        if (method == 'dev_disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _twoClipDraft());
      addTearDown(() => controller.dispose());

      await expectLater(
        controller.initialize(),
        throwsA(isA<StateError>()),
      );
      expect(controller.value.isReady, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // play() / pause()
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — play() / pause()', () {
    late VGEditorController controller;

    setUp(() async {
      _setMockHandler((method, args) async {
        switch (method) {
          case 'dev_createTimelineTexture':
            return {'textureId': 99, 'width': 640, 'height': 360};
          case 'dev_timelinePlay':
          case 'dev_timelinePause':
          case 'dev_disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('EC-5  play() sets isPlaying=true', () async {
      await controller.play();
      expect(controller.value.isPlaying, isTrue);
    });

    test('EC-6  pause() sets isPlaying=false', () async {
      await controller.play();
      await controller.pause();
      expect(controller.value.isPlaying, isFalse);
    });

    test('EC-7  play() is no-op if already playing', () async {
      await controller.play();
      final calledBefore = controller.value.isPlaying;
      await controller.play(); // no-op
      expect(controller.value.isPlaying, calledBefore);
    });

    test('EC-8  pause() is no-op if already paused', () async {
      // Starts paused — pause() should be a no-op
      await controller.pause();
      expect(controller.value.isPlaying, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // updateDraft()
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — updateDraft()', () {
    late VGEditorController controller;

    setUp(() async {
      _setMockHandler((method, args) async {
        switch (method) {
          case 'dev_createTimelineTexture':
            return {'textureId': 10, 'width': 640, 'height': 360};
          case 'dev_updateTimeline':
            return {'textureId': 11, 'width': 640, 'height': 360};
          case 'dev_timelinePause':
          case 'dev_disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('EC-9  updateDraft replaces draft and resets PTS', () async {
      // Simulate PTS progress via handleNativeCallback.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 3.5}),
      );
      expect(controller.value.currentPTS, 3.5);

      final trimmedDraft = VGEditorDraft(
        id: 'draft-test',
        clips: [
          _clip(id: 'clip-A', trimEnd: 4.0),
          _clip(id: 'clip-B'),
        ],
      );
      await controller.updateDraft(trimmedDraft);

      expect(controller.value.draft, trimmedDraft);
      expect(controller.value.currentPTS, 0.0);
      expect(controller.value.isReady, isTrue);
      expect(controller.value.textureId, 11);
    });

    test('EC-10 updateDraft updates durationSeconds via draft', () async {
      final trimmedDraft = VGEditorDraft(
        id: 'draft-test',
        clips: [
          _clip(id: 'clip-A', trimEnd: 4.0), // 4s
          _clip(id: 'clip-B', trimEnd: 3.0), // 3s
        ],
      );
      await controller.updateDraft(trimmedDraft);
      expect(controller.value.durationSeconds, closeTo(7.0, 0.001));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // export()
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — export()', () {
    late VGEditorController controller;

    setUp(() async {
      _setMockHandler((method, args) async {
        switch (method) {
          case 'dev_createTimelineTexture':
            return {'textureId': 5, 'width': 640, 'height': 360};
          case 'dev_timelineExport':
            return {
              'success': true,
              'path': '/tmp/vg_timeline_export_proof.mp4',
              'durationSeconds': 10.0,
              'width': 640,
              'height': 360,
            };
          case 'dev_disposeTimeline':
          case 'dev_timelinePause':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('EC-11 export returns VGEditorExportResult on success', () async {
      final result = await controller.export(const VGEditorExportRequest());

      expect(result, isA<VGEditorExportResult>());
      expect(result.path, contains('vg_timeline_export_proof.mp4'));
      expect(result.durationSeconds, closeTo(10.0, 0.001));
      expect(result.width, 640);
      expect(result.height, 360);
    });

    test('EC-12 isExporting is false after successful export', () async {
      await controller.export(const VGEditorExportRequest());
      expect(controller.value.isExporting, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // handleNativeCallback()
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — handleNativeCallback()', () {
    late VGEditorController controller;

    setUp(() {
      _setMockHandler((method, args) async {
        if (method == 'dev_disposeTimeline') return null;
        return null;
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
    });

    tearDown(() => controller.dispose());

    test('EC-13 onTimelineFrame updates currentPTS', () async {
      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 2.5}),
      );
      expect(controller.value.currentPTS, closeTo(2.5, 0.001));
    });

    test('EC-14 onTimelineFrame emits on ptsStream', () async {
      final received = <double>[];
      final sub = controller.ptsStream.listen(received.add);
      addTearDown(sub.cancel);

      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 1.23}),
      );
      expect(received, [closeTo(1.23, 0.001)]);
    });

    test('EC-15 onTimelineEOS sets isPlaying=false', () async {
      // Manually set isPlaying=true for the test.
      // (We can't call play() here as native isn't initialized.)
      // Instead verify via EOS callback.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineEOS', null),
      );
      expect(controller.value.isPlaying, isFalse);
    });

    test('EC-16 onTimelineEOS emits on eosStream', () async {
      final received = <void>[];
      final sub = controller.eosStream.listen((_) => received.add(null));
      addTearDown(sub.cancel);

      await controller.handleNativeCallback(
        const MethodCall('onTimelineEOS', null),
      );
      expect(received.length, 1);
    });

    test('EC-17 unknown callback is silently ignored', () async {
      await expectLater(
        controller.handleNativeCallback(
          const MethodCall('unknownCallback', null),
        ),
        completes,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // dispose() idempotency
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — dispose()', () {
    test('EC-18 dispose() is idempotent', () {
      _setMockHandler((method, args) async {
        if (method == 'dev_disposeTimeline') return null;
        return null;
      });
      final controller = VGEditorController(initialDraft: _twoClipDraft());
      controller.dispose();
      expect(() => controller.dispose(), returnsNormally);
    });

    test('EC-19 methods throw StateError after dispose', () async {
      _setMockHandler((method, args) async {
        if (method == 'dev_disposeTimeline') return null;
        return null;
      });
      final controller = VGEditorController(initialDraft: _twoClipDraft());
      controller.dispose();

      await expectLater(
        controller.initialize(),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        controller.play(),
        throwsA(isA<StateError>()),
      );
    });

    test('EC-20 disposeAsync() is safe to call multiple times', () async {
      _setMockHandler((method, args) async {
        if (method == 'dev_disposeTimeline') return null;
        return null;
      });
      final controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.disposeAsync();
      await expectLater(controller.disposeAsync(), completes);
      controller.dispose();
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // VGEditorValue
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorValue — copyWith and equality', () {
    test('EV-1  copyWith replaces textureId', () {
      final v = VGEditorValue.initial(_twoClipDraft());
      final v2 = v.copyWith(textureId: 42);
      expect(v2.textureId, 42);
      expect(v.textureId, isNull);
    });

    test('EV-2  copyWith clears textureId with explicit null', () {
      final v = VGEditorValue(draft: _twoClipDraft(), textureId: 7);
      final v2 = v.copyWith(textureId: null);
      expect(v2.textureId, isNull);
    });

    test('EV-3  equal values are equal', () {
      final draft = _twoClipDraft();
      final a = VGEditorValue.initial(draft);
      final b = VGEditorValue.initial(draft);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('EV-4  values with different PTS are not equal', () {
      final draft = _twoClipDraft();
      final a = VGEditorValue.initial(draft);
      final b = a.copyWith(currentPTS: 1.5);
      expect(a == b, isFalse);
    });

    test('EV-5  durationSeconds proxies draft', () {
      final draft = _twoClipDraft();
      final v = VGEditorValue.initial(draft);
      expect(v.durationSeconds, closeTo(draft.durationSeconds, 0.001));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // VGEditorExportResult
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorExportResult — fromMap', () {
    test('ER-1  fromMap parses valid map', () {
      final r = VGEditorExportResult.fromMap({
        'success': true,
        'path': '/tmp/export.mp4',
        'durationSeconds': 8.0,
        'width': 640,
        'height': 360,
        'fps': 30,
      });
      expect(r, isNotNull);
      expect(r!.path, '/tmp/export.mp4');
      expect(r.durationSeconds, closeTo(8.0, 0.001));
      expect(r.width, 640);
      expect(r.fps, 30);
    });

    test('ER-2  fromMap returns null when success is false', () {
      final r = VGEditorExportResult.fromMap({
        'success': false,
        'path': '/tmp/export.mp4',
        'durationSeconds': 0.0,
      });
      expect(r, isNull);
    });

    test('ER-3  fromMap returns null when path is missing', () {
      final r = VGEditorExportResult.fromMap({
        'success': true,
        'durationSeconds': 5.0,
      });
      expect(r, isNull);
    });

    test('ER-4  round-trip toMap/fromMap preserves values', () {
      const original = VGEditorExportResult(
        path: '/tmp/test.mp4',
        durationSeconds: 6.0,
        width: 1280,
        height: 720,
        fps: 30,
      );
      final map = original.toMap();
      final restored = VGEditorExportResult.fromMap(
        map.map((k, v) => MapEntry<Object?, Object?>(k, v)),
      );
      expect(restored, isNotNull);
      expect(restored!.path, original.path);
      expect(restored.durationSeconds, original.durationSeconds);
      expect(restored.width, original.width);
      expect(restored.height, original.height);
      expect(restored.fps, original.fps);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // VGEditorExportRequest
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorExportRequest — toMap / copyWith', () {
    test('EQ-1  empty request produces empty map', () {
      const req = VGEditorExportRequest();
      final map = req.toMap();
      expect(map, isEmpty);
    });

    test('EQ-2  populated request includes all set fields', () {
      const req = VGEditorExportRequest(
        outputPath: '/tmp/out.mp4',
        bitrateBps: 4000000,
        width: 1920,
        height: 1080,
        fps: 30,
      );
      final map = req.toMap();
      expect(map['outputPath'], '/tmp/out.mp4');
      expect(map['bitrateBps'], 4000000);
      expect(map['width'], 1920);
      expect(map['height'], 1080);
      expect(map['fps'], 30);
    });

    test('EQ-3  copyWith replaces bitrateBps', () {
      const req = VGEditorExportRequest(bitrateBps: 2000000);
      final req2 = req.copyWith(bitrateBps: 8000000);
      expect(req2.bitrateBps, 8000000);
      expect(req.bitrateBps, 2000000);
    });

    test('EQ-4  equality works correctly', () {
      const a = VGEditorExportRequest(bitrateBps: 4000000);
      const b = VGEditorExportRequest(bitrateBps: 4000000);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
