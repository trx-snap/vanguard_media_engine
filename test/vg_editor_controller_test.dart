// vg_editor_controller_test.dart
// Vanguard Media Engine — Phase 7 Stage 7.8
//
// Pure Dart unit tests for VGEditorController using a mock MethodChannel.
//
// Phase 7.8 changes:
//   - Production routes (createTimelineTexture, updateTimeline, timelinePlay,
//     timelinePause, timelineSeek, exportTimeline, disposeTimeline) replace
//     the legacy dev_* route names in the controller.
//   - initialize() sends { 'draft': draft.toMap() }.
//   - updateDraft() sends { 'draft': draft.toMap() }.
//   - export() sends { 'draft': draft.toMap(), ...request.toMap() }.
//   - Legacy dev_* mock handlers retained in separate group tests to verify
//     the controller no longer calls them on production paths.
//
// Tests:
//   - initialize() → invokes createTimelineTexture, sends draft payload
//   - play() / pause() → invoke timelinePlay / timelinePause
//   - seek() → invokes timelineSeek
//   - updateDraft() → invokes updateTimeline, sends draft payload, resets PTS
//   - export() → invokes exportTimeline, includes draft map
//   - dispose() → invokes disposeTimeline
//   - handleNativeCallback() → PTS/EOS state updates
//   - dispose() idempotency
//   - disposeAsync() is safe if called multiple times
//   - useRealVideoClips is still accepted by constructor (backward compat)
//   - Production routes do NOT send useRealVideoClips

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_transition_descriptor.dart';

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

    test('EC-1b useRealVideoClips constructor param is accepted (deprecated)',
        () {
      // ignore: deprecated_member_use
      final controller = VGEditorController(
        initialDraft: _twoClipDraft(),
        // ignore: deprecated_member_use
        useRealVideoClips: false,
      );
      addTearDown(() => controller.dispose());
      // Should construct without error — backward compat only.
      expect(controller, isNotNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // initialize() — production route
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — initialize() [production route]', () {
    test('EC-3  initialize invokes createTimelineTexture (not dev_)', () async {
      String? capturedMethod;
      dynamic capturedArgs;

      _setMockHandler((method, args) async {
        capturedMethod = method;
        capturedArgs = args;
        if (method == 'createTimelineTexture') {
          return {'textureId': 42, 'width': 640, 'height': 360};
        }
        if (method == 'disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();

      expect(capturedMethod, 'createTimelineTexture');
      expect(capturedArgs, isA<Map>());
      addTearDown(() => controller.dispose());
    });

    test('EC-3b initialize sets isReady=true and textureId', () async {
      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          return {'textureId': 42, 'width': 640, 'height': 360};
        }
        if (method == 'disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();

      expect(controller.value.isReady, isTrue);
      expect(controller.value.textureId, 42);
      addTearDown(() => controller.dispose());
    });

    test('EC-3c initialize sends draft.toMap() under draft key', () async {
      dynamic capturedArgs;

      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          capturedArgs = args;
          return {'textureId': 7, 'width': 640, 'height': 360};
        }
        if (method == 'disposeTimeline') return null;
        return null;
      });

      final draft = _twoClipDraft();
      final controller = VGEditorController(initialDraft: draft);
      await controller.initialize();

      expect(capturedArgs, isA<Map>());
      final argsMap = capturedArgs as Map;
      expect(argsMap.containsKey('draft'), isTrue,
          reason: 'Production route must send draft key');
      expect(argsMap['draft'], isA<Map>(),
          reason: 'draft value must be a Map');
      // Draft map must NOT be empty.
      expect((argsMap['draft'] as Map).isNotEmpty, isTrue);
      // Must include clips key.
      expect((argsMap['draft'] as Map).containsKey('clips'), isTrue);
      addTearDown(() => controller.dispose());
    });

    test('EC-3d initialize does NOT send useRealVideoClips on production route',
        () async {
      dynamic capturedArgs;

      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          capturedArgs = args;
          return {'textureId': 7, 'width': 640, 'height': 360};
        }
        if (method == 'disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();

      final argsMap = capturedArgs as Map;
      expect(argsMap.containsKey('useRealVideoClips'), isFalse,
          reason: 'Production route must not send useRealVideoClips');
      expect(argsMap.containsKey('useSyntheticClips'), isFalse,
          reason: 'Production route must not send useSyntheticClips');
      addTearDown(() => controller.dispose());
    });

    test('EC-4  initialize throws if native returns negative textureId',
        () async {
      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          return {'textureId': -1};
        }
        if (method == 'disposeTimeline') return null;
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
  // play() / pause() — production routes
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — play() / pause() [production routes]', () {
    late VGEditorController controller;
    final List<String> calledMethods = [];

    setUp(() async {
      calledMethods.clear();
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        switch (method) {
          case 'createTimelineTexture':
            return {'textureId': 99, 'width': 640, 'height': 360};
          case 'timelinePlay':
          case 'timelinePause':
          case 'disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('EC-5  play() invokes timelinePlay (not dev_timelinePlay)', () async {
      calledMethods.clear();
      await controller.play();
      expect(calledMethods, contains('timelinePlay'));
      expect(calledMethods, isNot(contains('dev_timelinePlay')));
    });

    test('EC-5b play() sets isPlaying=true', () async {
      await controller.play();
      expect(controller.value.isPlaying, isTrue);
    });

    test('EC-6  pause() invokes timelinePause (not dev_timelinePause)',
        () async {
      await controller.play();
      calledMethods.clear();
      await controller.pause();
      expect(calledMethods, contains('timelinePause'));
      expect(calledMethods, isNot(contains('dev_timelinePause')));
    });

    test('EC-6b pause() sets isPlaying=false', () async {
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
  // seek() — production route
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — seek() [production route]', () {
    late VGEditorController controller;
    final List<String> calledMethods = [];

    setUp(() async {
      calledMethods.clear();
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        if (method == 'createTimelineTexture') {
          return {'textureId': 55, 'width': 640, 'height': 360};
        }
        return null;
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('EC-SK1 seek() invokes timelineSeek (not dev_timelineSeek)', () async {
      calledMethods.clear();
      await controller.seek(2.5);
      expect(calledMethods, contains('timelineSeek'));
      expect(calledMethods, isNot(contains('dev_timelineSeek')));
    });

    test('EC-SK2 seek() updates currentPTS', () async {
      await controller.seek(3.7);
      expect(controller.value.currentPTS, closeTo(3.7, 0.001));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // updateDraft() — production route
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — updateDraft() [production route]', () {
    late VGEditorController controller;
    final List<String> calledMethods = [];
    dynamic capturedUpdateArgs;

    setUp(() async {
      calledMethods.clear();
      capturedUpdateArgs = null;
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        switch (method) {
          case 'createTimelineTexture':
            return {'textureId': 10, 'width': 640, 'height': 360};
          case 'updateTimeline':
            capturedUpdateArgs = args;
            return {'textureId': 11, 'width': 640, 'height': 360};
          case 'timelinePause':
          case 'disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('EC-9  updateDraft invokes updateTimeline (not dev_updateTimeline)',
        () async {
      calledMethods.clear();
      final trimmedDraft = VGEditorDraft(
        id: 'draft-test',
        clips: [_clip(id: 'clip-A', trimEnd: 4.0), _clip(id: 'clip-B')],
      );
      await controller.updateDraft(trimmedDraft);
      expect(calledMethods, contains('updateTimeline'));
      expect(calledMethods, isNot(contains('dev_updateTimeline')));
    });

    test('EC-9b updateDraft sends draft.toMap() under draft key', () async {
      final trimmedDraft = VGEditorDraft(
        id: 'draft-test',
        clips: [_clip(id: 'clip-A', trimEnd: 4.0), _clip(id: 'clip-B')],
      );
      await controller.updateDraft(trimmedDraft);

      expect(capturedUpdateArgs, isA<Map>());
      final argsMap = capturedUpdateArgs as Map;
      expect(argsMap.containsKey('draft'), isTrue,
          reason: 'Production updateTimeline must send draft key');
      expect(argsMap['draft'], isA<Map>());
      expect((argsMap['draft'] as Map).containsKey('clips'), isTrue);
    });

    test('EC-9c updateDraft does NOT send useRealVideoClips', () async {
      final trimmedDraft = VGEditorDraft(
        id: 'draft-test',
        clips: [_clip(id: 'clip-A', trimEnd: 4.0), _clip(id: 'clip-B')],
      );
      await controller.updateDraft(trimmedDraft);

      final argsMap = capturedUpdateArgs as Map;
      expect(argsMap.containsKey('useRealVideoClips'), isFalse,
          reason: 'Production route must not send useRealVideoClips');
    });

    test('EC-9d updateDraft replaces draft and resets PTS', () async {
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
  // export() — production route
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — export() [production route]', () {
    late VGEditorController controller;
    final List<String> calledMethods = [];
    dynamic capturedExportArgs;

    setUp(() async {
      calledMethods.clear();
      capturedExportArgs = null;
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        switch (method) {
          case 'createTimelineTexture':
            return {'textureId': 5, 'width': 640, 'height': 360};
          case 'exportTimeline':
            capturedExportArgs = args;
            return {
              'success': true,
              'path': '/tmp/vg_timeline_export_proof.mp4',
              'durationSeconds': 10.0,
              'width': 640,
              'height': 360,
            };
          case 'disposeTimeline':
          case 'timelinePause':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('EC-EX1 export() invokes exportTimeline (not dev_timelineExport)',
        () async {
      calledMethods.clear();
      await controller.export(const VGEditorExportRequest());
      expect(calledMethods, contains('exportTimeline'));
      expect(calledMethods, isNot(contains('dev_timelineExport')));
    });

    test('EC-EX2 export() sends draft map under draft key', () async {
      await controller.export(const VGEditorExportRequest());

      expect(capturedExportArgs, isA<Map>());
      final argsMap = capturedExportArgs as Map;
      expect(argsMap.containsKey('draft'), isTrue,
          reason: 'exportTimeline must send draft key');
      expect(argsMap['draft'], isA<Map>());
      expect((argsMap['draft'] as Map).containsKey('clips'), isTrue);
    });

    test('EC-EX3 export() does NOT send useRealVideoClips', () async {
      await controller.export(const VGEditorExportRequest());

      final argsMap = capturedExportArgs as Map;
      expect(argsMap.containsKey('useRealVideoClips'), isFalse,
          reason: 'Production export must not send useRealVideoClips');
    });

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

    test('EC-EX4 export() merges request fields with draft', () async {
      await controller.export(
        const VGEditorExportRequest(
          outputPath: '/tmp/custom.mp4',
          bitrateBps: 8000000,
        ),
      );

      final argsMap = capturedExportArgs as Map;
      expect(argsMap.containsKey('outputPath'), isTrue);
      expect(argsMap['outputPath'], '/tmp/custom.mp4');
      expect(argsMap['bitrateBps'], 8000000);
      // draft key must still be present
      expect(argsMap.containsKey('draft'), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // dispose() — production route
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — dispose() [production route]', () {
    test('EC-D1 disposeAsync() invokes disposeTimeline (not dev_)', () async {
      final List<String> called = [];
      _setMockHandler((method, args) async {
        called.add(method);
        return null;
      });
      final controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.disposeAsync();
      controller.dispose();

      expect(called, contains('disposeTimeline'));
      expect(called, isNot(contains('dev_disposeTimeline')));
    });

    test('EC-18 dispose() is idempotent', () {
      _setMockHandler((method, args) async {
        if (method == 'disposeTimeline') return null;
        return null;
      });
      final controller = VGEditorController(initialDraft: _twoClipDraft());
      controller.dispose();
      expect(() => controller.dispose(), returnsNormally);
    });

    test('EC-19 methods throw StateError after dispose', () async {
      _setMockHandler((method, args) async {
        if (method == 'disposeTimeline') return null;
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
        if (method == 'disposeTimeline') return null;
        return null;
      });
      final controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.disposeAsync();
      await expectLater(controller.disposeAsync(), completes);
      controller.dispose();
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // handleNativeCallback()
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — handleNativeCallback()', () {
    late VGEditorController controller;

    setUp(() {
      _setMockHandler((method, args) async {
        if (method == 'disposeTimeline') return null;
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

    test('EC-15 onTimelineEOS sets isPlaying=false and pins currentPTS to durationSeconds', () async {
      // Send a sub-duration frame first so currentPTS is not already at duration.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 4.5}),
      );
      expect(controller.value.currentPTS, closeTo(4.5, 0.001));

      await controller.handleNativeCallback(
        const MethodCall('onTimelineEOS', null),
      );
      expect(controller.value.isPlaying, isFalse);
      expect(
        controller.value.currentPTS,
        closeTo(controller.value.draft.durationSeconds, 0.001),
        reason: 'onTimelineEOS must pin currentPTS to durationSeconds',
      );
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

  // ───────────────────────────────────────────────────────────────────────────
  // play() — replay-at-end behaviour
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — play() replay-at-end', () {
    // EC-RAE0 covers the critical real-device scenario that was missed before:
    // the last onTimelineFrame delivers a PTS *slightly below* durationSeconds
    // (e.g. 9.97s on a 10.0s timeline). Without the EOS currentPTS pin in
    // handleNativeCallback, play() would see 9.97 >= 10.0 → false, send no
    // seek, and native immediately re-fires EOS. This appeared on device as
    // pressing Play doing nothing.
    late VGEditorController controller;
    final List<String> calledMethods = [];
    final List<Map<String, dynamic>> capturedSeekArgs = [];

    setUp(() async {
      calledMethods.clear();
      capturedSeekArgs.clear();
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        if (method == 'timelineSeek') {
          capturedSeekArgs.add(Map<String, dynamic>.from(args as Map));
        }
        switch (method) {
          case 'createTimelineTexture':
            return {'textureId': 77, 'width': 640, 'height': 360};
          case 'timelinePlay':
          case 'timelinePause':
          case 'timelineSeek':
          case 'disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test(
        'EC-RAE0 play() after EOS with sub-duration last frame seeks to 0.0 (real-device scenario)',
        () async {
      // REAL-DEVICE SCENARIO: the last onTimelineFrame delivers a PTS slightly
      // below durationSeconds (as seen on physical iPhone). EOS fires on the
      // next compositor tick. The onTimelineEOS handler must pin currentPTS to
      // durationSeconds so play() replay-at-end condition fires correctly.
      final duration = controller.value.draft.durationSeconds; // 10.0
      const lastFramePTS = 9.967; // typical real-device last-frame PTS

      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': lastFramePTS}),
      );
      // Verify PTS was set from the frame callback.
      expect(controller.value.currentPTS, closeTo(lastFramePTS, 0.001));

      // EOS fires — controller must pin currentPTS to durationSeconds.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineEOS', null),
      );

      expect(controller.value.isPlaying, isFalse);
      // KEY ASSERTION: PTS is pinned to duration, not left at lastFramePTS.
      expect(
        controller.value.currentPTS,
        closeTo(duration, 0.001),
        reason: 'onTimelineEOS must pin currentPTS to durationSeconds so '
            'play() replay-at-end condition fires even when last frame '
            'PTS is slightly below duration (real-device behaviour)',
      );

      calledMethods.clear();
      capturedSeekArgs.clear();

      // Press play — must seek to 0 even though lastFramePTS < duration.
      await controller.play();

      expect(calledMethods, contains('timelineSeek'),
          reason: 'play() after sub-duration EOS must seek to 0.0');
      final seekIndex = calledMethods.indexOf('timelineSeek');
      final playIndex = calledMethods.indexOf('timelinePlay');
      expect(seekIndex, lessThan(playIndex),
          reason: 'seek must precede timelinePlay');
      expect(capturedSeekArgs.last['seconds'], closeTo(0.0, 0.001));
      expect(controller.value.currentPTS, closeTo(0.0, 0.001));
      expect(controller.value.isPlaying, isTrue);
    });

    test(
        'EC-RAE1 play() after EOS seeks to 0.0 then starts playback',
        () async {
      // Draft duration is 10.0s (two untrimmed 5s clips with sequential start times).
      // Send PTS at exactly end boundary so the replay-at-end condition fires.
      final duration = controller.value.draft.durationSeconds; // 10.0
      await controller.handleNativeCallback(
        MethodCall('onTimelineFrame', {'pts': duration}),
      );
      await controller.handleNativeCallback(
        const MethodCall('onTimelineEOS', null),
      );

      expect(controller.value.isPlaying, isFalse);
      expect(controller.value.currentPTS, closeTo(duration, 0.001));

      calledMethods.clear();
      capturedSeekArgs.clear();

      // Press play again — should seek to 0 first.
      await controller.play();

      // timelineSeek must have been called before timelinePlay.
      expect(calledMethods, contains('timelineSeek'),
          reason: 'play() after EOS must seek to 0.0 before starting');
      final seekIndex = calledMethods.indexOf('timelineSeek');
      final playIndex = calledMethods.indexOf('timelinePlay');
      expect(seekIndex, lessThan(playIndex),
          reason: 'seek must precede timelinePlay');

      // Seek must target 0.0s.
      expect(capturedSeekArgs.isNotEmpty, isTrue);
      expect(capturedSeekArgs.last['seconds'], closeTo(0.0, 0.001));

      // Controller PTS resets and isPlaying is true.
      expect(controller.value.currentPTS, closeTo(0.0, 0.001));
      expect(controller.value.isPlaying, isTrue);
    });

    test(
        'EC-RAE2 play() when PTS exactly equals durationSeconds seeks first',
        () async {
      // Draft duration is 10.0s (two 5s clips).
      final duration = controller.value.draft.durationSeconds;

      // Simulate PTS at exact end boundary.
      await controller.handleNativeCallback(
        MethodCall('onTimelineFrame', {'pts': duration}),
      );
      // EOS sets isPlaying=false.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineEOS', null),
      );

      calledMethods.clear();
      capturedSeekArgs.clear();

      await controller.play();

      expect(calledMethods, contains('timelineSeek'));
      expect(capturedSeekArgs.last['seconds'], closeTo(0.0, 0.001));
      expect(controller.value.isPlaying, isTrue);
    });

    test(
        'EC-RAE3 play() mid-timeline does NOT seek to 0 unnecessarily',
        () async {
      // Simulate PTS partway through the timeline.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 4.5}),
      );
      expect(controller.value.currentPTS, closeTo(4.5, 0.001));

      calledMethods.clear();
      capturedSeekArgs.clear();

      await controller.play();

      // Should NOT have sent a seek before play.
      expect(calledMethods, isNot(contains('timelineSeek')),
          reason: 'play() mid-timeline must not auto-seek to 0');
      expect(calledMethods, contains('timelinePlay'));
      expect(controller.value.isPlaying, isTrue);
    });

    test(
        'EC-RAE4 play() at time 0.0 does NOT seek unnecessarily',
        () async {
      // PTS is already 0.0 (initial state).
      expect(controller.value.currentPTS, closeTo(0.0, 0.001));

      calledMethods.clear();
      capturedSeekArgs.clear();

      await controller.play();

      expect(calledMethods, isNot(contains('timelineSeek')),
          reason: 'play() at 0.0 must not auto-seek');
      expect(calledMethods, contains('timelinePlay'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // trimClip() — Phase 7.13 / DEC-146
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — trimClip() (Phase 7.13)', () {
    late VGEditorController controller;
    final List<String> calledMethods = [];
    dynamic capturedUpdateArgs;

    setUp(() async {
      calledMethods.clear();
      capturedUpdateArgs = null;
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        switch (method) {
          case 'createTimelineTexture':
            return {'textureId': 20, 'width': 640, 'height': 360};
          case 'updateTimeline':
            capturedUpdateArgs = args;
            return {'textureId': 21, 'width': 640, 'height': 360};
          case 'timelinePause':
          case 'disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('TR-EC1 trimClip invokes updateTimeline exactly once', () async {
      calledMethods.clear();
      await controller.trimClip(
        clipId: 'clip-A',
        trimStartSeconds: 1.0,
        trimEndSeconds: 4.0,
      );

      expect(
        calledMethods.where((m) => m == 'updateTimeline').length,
        1,
        reason: 'trimClip must invoke updateTimeline exactly once',
      );
    });

    test('TR-EC2 trimClip updates draft and resets currentPTS to 0.0', () async {
      // Advance PTS via callback.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 3.5}),
      );
      expect(controller.value.currentPTS, closeTo(3.5, 0.001));

      await controller.trimClip(
        clipId: 'clip-A',
        trimStartSeconds: 1.0,
        trimEndSeconds: 4.0,
      );

      // PTS must reset to 0.
      expect(controller.value.currentPTS, closeTo(0.0, 0.001));
      // Controller must be ready again.
      expect(controller.value.isReady, isTrue);
      // Draft trim values must be reflected.
      expect(controller.draft.clips[0].trimStartSeconds, closeTo(1.0, 1e-9));
      expect(controller.draft.clips[0].trimEndSeconds, closeTo(4.0, 1e-9));
      // Draft duration must shrink: A=3s, B=5s → 8s.
      expect(controller.draft.durationSeconds, closeTo(8.0, 0.001));
      // updateTimeline payload must contain the updated draft.
      expect(capturedUpdateArgs, isA<Map>());
      final argsMap = capturedUpdateArgs as Map;
      expect(argsMap.containsKey('draft'), isTrue);
    });

    test('TR-EC3 trimClip throws StateError after dispose', () async {
      controller.dispose();
      await expectLater(
        controller.trimClip(
          clipId: 'clip-A',
          trimStartSeconds: 1.0,
          trimEndSeconds: 4.0,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('TR-EC4 trimClip propagates ArgumentError without calling updateTimeline',
        () async {
      calledMethods.clear();
      await expectLater(
        controller.trimClip(
          clipId: 'clip-A',
          trimStartSeconds: 0.0,
          trimEndSeconds: 99.0, // exceeds source duration → ArgumentError
        ),
        throwsA(isA<ArgumentError>()),
      );
      // updateTimeline must NOT have been called.
      expect(calledMethods, isNot(contains('updateTimeline')),
          reason: 'ArgumentError from draft validation must not reach channel');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // splitClip() — Phase 7.14 / DEC-147
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — splitClip() (Phase 7.14)', () {
    late VGEditorController controller;
    final List<String> calledMethods = [];
    dynamic capturedUpdateArgs;

    setUp(() async {
      calledMethods.clear();
      capturedUpdateArgs = null;
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        switch (method) {
          case 'createTimelineTexture':
            return {'textureId': 30, 'width': 640, 'height': 360};
          case 'updateTimeline':
            capturedUpdateArgs = args;
            return {'textureId': 31, 'width': 640, 'height': 360};
          case 'timelinePause':
          case 'disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      controller = VGEditorController(initialDraft: _twoClipDraft());
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('TR-SEC1 splitClip invokes updateTimeline exactly once', () async {
      calledMethods.clear();
      await controller.splitClip(
        clipId: 'clip-A',
        splitSeconds: 3.0,
      );

      expect(
        calledMethods.where((m) => m == 'updateTimeline').length,
        1,
        reason: 'splitClip must invoke updateTimeline exactly once',
      );
    });

    test('TR-SEC2 splitClip updates draft value notifier and resets currentPTS to 0.0', () async {
      // Advance PTS via callback.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 2.5}),
      );
      expect(controller.value.currentPTS, closeTo(2.5, 0.001));

      await controller.splitClip(
        clipId: 'clip-A',
        splitSeconds: 3.0,
      );

      // PTS must reset to 0.
      expect(controller.value.currentPTS, closeTo(0.0, 0.001));
      // Controller must be ready again.
      expect(controller.value.isReady, isTrue);
      // Draft must now have 3 clips.
      expect(controller.draft.clips.length, 3);
      // Left clip retains original ID.
      expect(controller.draft.clips[0].id, 'clip-A');
      // Right clip has generated ID.
      expect(controller.draft.clips[1].id, 'clip-A-split-1');
      // updateTimeline payload must contain the updated draft.
      expect(capturedUpdateArgs, isA<Map>());
      final argsMap = capturedUpdateArgs as Map;
      expect(argsMap.containsKey('draft'), isTrue);
    });

    test('TR-SEC3 splitClip throws StateError after dispose', () async {
      controller.dispose();
      await expectLater(
        controller.splitClip(
          clipId: 'clip-A',
          splitSeconds: 3.0,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('TR-SEC4 splitClip propagates ArgumentError without calling updateTimeline',
        () async {
      calledMethods.clear();
      await expectLater(
        controller.splitClip(
          clipId: 'clip-A',
          splitSeconds: 99.0, // out of [trimStart, trimEnd] range → ArgumentError
        ),
        throwsA(isA<ArgumentError>()),
      );
      // updateTimeline must NOT have been called.
      expect(calledMethods, isNot(contains('updateTimeline')),
          reason: 'ArgumentError from draft validation must not reach channel');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // reorderClip() — Phase 7.15 / DEC-148
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorController — reorderClip() (Phase 7.15)', () {
    late VGEditorController controller;
    final List<String> calledMethods = [];
    dynamic capturedUpdateArgs;

    setUp(() async {
      calledMethods.clear();
      capturedUpdateArgs = null;
      _setMockHandler((method, args) async {
        calledMethods.add(method);
        switch (method) {
          case 'createTimelineTexture':
            return {'textureId': 40, 'width': 640, 'height': 360};
          case 'updateTimeline':
            capturedUpdateArgs = args;
            return {'textureId': 41, 'width': 640, 'height': 360};
          case 'timelinePause':
          case 'disposeTimeline':
            return null;
          default:
            return null;
        }
      });
      // Use a three-clip draft so reorder is meaningful.
      final threeClipDraft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-reorder-ec',
        clips: [
          VGClipDescriptor(
            id: 'clip-A',
            sourcePath: '/tmp/clip_a.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
          VGClipDescriptor(
            id: 'clip-B',
            sourcePath: '/tmp/clip_b.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
          VGClipDescriptor(
            id: 'clip-C',
            sourcePath: '/tmp/clip_c.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
        ],
      );
      controller = VGEditorController(initialDraft: threeClipDraft);
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('RO-EC1 reorderClip invokes updateTimeline exactly once', () async {
      calledMethods.clear();
      await controller.reorderClip(fromIndex: 0, toIndex: 2);

      expect(
        calledMethods.where((m) => m == 'updateTimeline').length,
        1,
        reason: 'reorderClip must invoke updateTimeline exactly once',
      );
    });

    test('RO-EC2 reorderClip updates draft value notifier and resets currentPTS to 0.0', () async {
      // Advance PTS via callback.
      await controller.handleNativeCallback(
        const MethodCall('onTimelineFrame', {'pts': 3.0}),
      );
      expect(controller.value.currentPTS, closeTo(3.0, 0.001));

      await controller.reorderClip(fromIndex: 0, toIndex: 2);

      // PTS must reset to 0.
      expect(controller.value.currentPTS, closeTo(0.0, 0.001));
      // Controller must be ready again.
      expect(controller.value.isReady, isTrue);
      // Draft clip order must reflect the move: [B, C, A].
      expect(controller.draft.clips[0].id, 'clip-B');
      expect(controller.draft.clips[1].id, 'clip-C');
      expect(controller.draft.clips[2].id, 'clip-A');
      // updateTimeline payload must contain the updated draft.
      expect(capturedUpdateArgs, isA<Map>());
      final argsMap = capturedUpdateArgs as Map;
      expect(argsMap.containsKey('draft'), isTrue);
    });

    test('RO-EC3 reorderClip throws StateError after dispose', () async {
      controller.dispose();
      await expectLater(
        controller.reorderClip(fromIndex: 0, toIndex: 1),
        throwsA(isA<StateError>()),
      );
    });

    test('RO-EC4 reorderClip propagates ArgumentError for out-of-range index without calling updateTimeline',
        () async {
      calledMethods.clear();
      // fromIndex out of range → ArgumentError from draft validation.
      await expectLater(
        controller.reorderClip(fromIndex: 99, toIndex: 0),
        throwsA(isA<ArgumentError>()),
      );
      // updateTimeline must NOT have been called.
      expect(calledMethods, isNot(contains('updateTimeline')),
          reason: 'ArgumentError from draft validation must not reach channel');
    });

    test(
        'RO-EC5 reorderClip no-op (fromIndex == toIndex) does not call updateTimeline and leaves state unchanged',
        () async {
      calledMethods.clear();
      final ptsBefore = controller.value.currentPTS;
      final draftBefore = controller.value.draft;
      final textureIdBefore = controller.value.textureId;

      // fromIndex == toIndex → no-op; must not throw.
      await controller.reorderClip(fromIndex: 1, toIndex: 1);

      // MethodChannel must NOT have been called.
      expect(calledMethods, isNot(contains('updateTimeline')),
          reason: 'No-op reorder must not invoke the MethodChannel');
      // Controller state must be completely stable.
      expect(controller.value.currentPTS, closeTo(ptsBefore, 0.001),
          reason: 'currentPTS must not change on no-op');
      expect(identical(controller.value.draft, draftBefore), isTrue,
          reason: 'Draft instance must be unchanged on no-op');
      expect(controller.value.textureId, textureIdBefore,
          reason: 'textureId must be unchanged on no-op');
      expect(controller.value.isReady, isTrue,
          reason: 'isReady must remain true on no-op');
    });

    test(
        'RO-EC6 Option D: relinked transition fromClipId/toClipId reach updateTimeline payload',
        () async {
      // The controller setUp uses a three-clip draft with no transitions.
      // Build a two-clip controller with a fade A→B so we can verify relinking.
      final twoClipDraft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ec6',
        clips: [
          const VGClipDescriptor(
            id: 'clip-A',
            sourcePath: '/tmp/clip_a.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
          const VGClipDescriptor(
            id: 'clip-B',
            sourcePath: '/tmp/clip_b.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
        ],
        transitions: [
          const VGTransitionDescriptor(
            id: 'tr-fade',
            type: VGTransitionType.fade,
            durationSeconds: 1.0,
            fromClipId: 'clip-A',
            toClipId: 'clip-B',
          ),
        ],
      );
      final ec6Controller = VGEditorController(initialDraft: twoClipDraft);
      await ec6Controller.initialize();

      dynamic ec6CapturedArgs;
      _setMockHandler((method, args) async {
        if (method == 'updateTimeline') ec6CapturedArgs = args;
        if (method == 'createTimelineTexture') {
          return {'textureId': 50, 'width': 640, 'height': 360};
        }
        if (method == 'updateTimeline') {
          return {'textureId': 51, 'width': 640, 'height': 360};
        }
        return null;
      });

      // Reinitialise ec6Controller with the override handler.
      // (setUp already ran initialize; we just need the next updateTimeline call.)
      await ec6Controller.reorderClip(fromIndex: 0, toIndex: 1);
      ec6Controller.dispose();

      // Verify payload contains the relinked transition.
      expect(ec6CapturedArgs, isA<Map>(),
          reason: 'updateTimeline must have been called');
      final draftMap = (ec6CapturedArgs as Map)['draft'] as Map;
      final transitionsList = draftMap['transitions'] as List;
      expect(transitionsList.length, 1,
          reason: 'Relinked transition must be present in payload');
      final tMap = transitionsList[0] as Map;
      expect(tMap['id'], 'tr-fade', reason: 'Transition ID preserved');
      expect(tMap['type'], 'fade', reason: 'Transition type preserved');
      expect(tMap['fromClipId'], 'clip-B',
          reason: 'fromClipId rewritten to new left clip B');
      expect(tMap['toClipId'], 'clip-A',
          reason: 'toClipId rewritten to new right clip A');
    });
  });
}
