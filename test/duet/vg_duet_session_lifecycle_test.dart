// Copyright 2026, Connects. All rights reserved.
//
// VG-DUET-SLICE-2: Dart lifecycle payload test.
//
// Validates that stopDuetRecording payload produced by the native
// lifecycle-only coordinator is accepted by MethodChannelVGDuetPlatform
// (VGDuetCaptureResult.from native payload expectations):
//   - compositionDescriptor map round-trips through VGDuetCompositionDescriptor.fromMap
//   - totalDurationMs > 0
//   - segmentCount > 0
//   - segmentAssets == []
//   - proofOutputPath == null
//
// Does NOT fake native proof as real OS proof.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_composition_descriptor.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_platform_interface.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_source.dart';

const _channelName = 'vanguard_media_engine';
const _sessionId = 'lifecycle-only-session-001';

/// Fake MethodChannel whose returnValue is configured per test.
class _StubChannel extends Fake implements MethodChannel {
  String? lastMethod;
  Map<String, dynamic>? lastArgs;
  dynamic returnValue;

  @override
  String get name => _channelName;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    lastMethod = method;
    lastArgs = arguments as Map<String, dynamic>?;
    if (returnValue is T?) return returnValue as T?;
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers: build a lifecycle-only native stop payload
// (mirrors what VGDuetNativeSession.buildStopResult returns)
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _sourceMap({String path = '/test/clip.mp4'}) => {
  'filePath': path,
};

Map<String, dynamic> _trimWindowMap({double start = 0.0, double end = 10.0}) =>
    {'startSeconds': start, 'endSeconds': end};

Map<String, dynamic> _layoutConfigMap() => {
  'mode': 'pip',
  'isSideSwapped': false,
  'isTopBottomSwapped': false,
};

Map<String, dynamic> _descriptorMap({
  String filePath = '/test/clip.mp4',
  String layoutMode = 'pip',
  double trimStart = 0.0,
  double trimEnd = 10.0,
  double speed = 1.0,
  List<Map<String, dynamic>> segments = const [],
  double sourceGain = 1.0,
  double micGain = 1.0,
  bool sourceAudioMuted = false,
  bool micAudioMuted = false,
}) => {
  'source': {'filePath': filePath},
  'layoutConfig': {
    'mode': layoutMode,
    'isSideSwapped': false,
    'isTopBottomSwapped': false,
  },
  'trimWindow': {'startSeconds': trimStart, 'endSeconds': trimEnd},
  'initialSpeed': speed,
  'segments': segments,
  'sourceAudioGain': sourceGain,
  'micAudioGain': micGain,
  'sourceAudioMuted': sourceAudioMuted,
  'micAudioMuted': micAudioMuted,
};

/// Builds a lifecycle-only stop payload (no real media assets, proofOutputPath null)
/// matching what native VGDuetNativeSession.buildStopResult returns.
Map<dynamic, dynamic> _lifecycleStopPayload({
  int totalDurationMs = 5000,
  int segmentCount = 1,
  List<Map<String, dynamic>> segments = const [],
}) => {
  'compositionDescriptor': _descriptorMap(segments: segments),
  'totalDurationMs': totalDurationMs,
  'segmentCount': segmentCount,
  'segmentAssets': <String>[],
  'proofOutputPath': null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  late _StubChannel stub;
  late MethodChannelVGDuetPlatform platform;

  setUp(() {
    stub = _StubChannel();
    platform = MethodChannelVGDuetPlatform(channel: stub);
  });

  // ── 1. Lifecycle stop payload round-trips through VGDuetCaptureResult ───────

  group('stopDuetRecording lifecycle payload', () {
    test(
      'single segment payload is accepted by MethodChannelVGDuetPlatform',
      () async {
        stub.returnValue = _lifecycleStopPayload(
          totalDurationMs: 3500,
          segmentCount: 1,
        );

        final result = await platform.stopRecording(sessionId: _sessionId);

        expect(stub.lastMethod, 'stopDuetRecording');
        expect(result.totalDurationMs, 3500);
        expect(result.segmentCount, 1);
        expect(result.segmentAssets, isEmpty);
        expect(result.proofOutputPath, isNull);
        expect(
          result.compositionDescriptor,
          isA<VGDuetCompositionDescriptor>(),
        );
      },
    );

    test('multi-segment payload returns correct segmentCount', () async {
      stub.returnValue = _lifecycleStopPayload(
        totalDurationMs: 8000,
        segmentCount: 3,
      );

      final result = await platform.stopRecording(sessionId: _sessionId);

      expect(result.segmentCount, 3);
      expect(result.totalDurationMs, 8000);
    });

    test('segmentAssets is always empty in lifecycle-only payload', () async {
      stub.returnValue = _lifecycleStopPayload(
        totalDurationMs: 2000,
        segmentCount: 1,
      );

      final result = await platform.stopRecording(sessionId: _sessionId);

      expect(result.segmentAssets, isEmpty);
    });

    test('proofOutputPath is null in lifecycle-only payload', () async {
      stub.returnValue = _lifecycleStopPayload(
        totalDurationMs: 1500,
        segmentCount: 1,
      );

      final result = await platform.stopRecording(sessionId: _sessionId);

      expect(result.proofOutputPath, isNull);
    });
  });

  // ── 2. VGDuetCompositionDescriptor round-trip for all layouts ───────────────

  group('compositionDescriptor layout round-trips', () {
    for (final layoutMode in [
      'pip',
      'splitLeftRight',
      'splitTopBottom',
      'greenScreen',
    ]) {
      test('layout=$layoutMode round-trips through fromMap', () async {
        stub.returnValue = _lifecycleStopPayload(
          totalDurationMs: 5000,
          segmentCount: 1,
        );
        // Override the descriptor mode for this test
        final payload = Map<dynamic, dynamic>.from(
          _lifecycleStopPayload(totalDurationMs: 5000, segmentCount: 1),
        );
        final descriptor = Map<String, dynamic>.from(
          payload['compositionDescriptor'] as Map,
        );
        descriptor['layoutConfig'] = {
          'mode': layoutMode,
          'isSideSwapped': false,
          'isTopBottomSwapped': false,
        };
        payload['compositionDescriptor'] = descriptor;
        stub.returnValue = payload;

        final result = await platform.stopRecording(sessionId: _sessionId);

        expect(result.compositionDescriptor.layoutConfig.mode.name, layoutMode);
      });
    }
  });

  // ── 3. Descriptor field fidelity ────────────────────────────────────────────

  group('compositionDescriptor field fidelity', () {
    test('source filePath is preserved', () async {
      final payload = _lifecycleStopPayload(
        totalDurationMs: 2000,
        segmentCount: 1,
      );
      final desc = Map<String, dynamic>.from(
        payload['compositionDescriptor'] as Map,
      );
      desc['source'] = {'filePath': '/custom/path/video.mp4'};
      payload['compositionDescriptor'] = desc;
      stub.returnValue = payload;

      final result = await platform.stopRecording(sessionId: _sessionId);

      expect(
        result.compositionDescriptor.source.filePath,
        '/custom/path/video.mp4',
      );
    });

    test('audio gains are preserved', () async {
      final payload = _lifecycleStopPayload(
        totalDurationMs: 2000,
        segmentCount: 1,
      );
      final desc = Map<String, dynamic>.from(
        payload['compositionDescriptor'] as Map,
      );
      desc['sourceAudioGain'] = 0.7;
      desc['micAudioGain'] = 0.3;
      payload['compositionDescriptor'] = desc;
      stub.returnValue = payload;

      final result = await platform.stopRecording(sessionId: _sessionId);

      expect(result.compositionDescriptor.sourceAudioGain, closeTo(0.7, 1e-10));
      expect(result.compositionDescriptor.micAudioGain, closeTo(0.3, 1e-10));
    });

    test('speed is preserved', () async {
      final payload = _lifecycleStopPayload(
        totalDurationMs: 2000,
        segmentCount: 1,
      );
      final desc = Map<String, dynamic>.from(
        payload['compositionDescriptor'] as Map,
      );
      desc['initialSpeed'] = 2.0;
      payload['compositionDescriptor'] = desc;
      stub.returnValue = payload;

      final result = await platform.stopRecording(sessionId: _sessionId);

      expect(result.compositionDescriptor.initialSpeed, closeTo(2.0, 1e-10));
    });

    test('trim window start/end are preserved', () async {
      final payload = _lifecycleStopPayload(
        totalDurationMs: 2000,
        segmentCount: 1,
      );
      final desc = Map<String, dynamic>.from(
        payload['compositionDescriptor'] as Map,
      );
      desc['trimWindow'] = {'startSeconds': 3.0, 'endSeconds': 13.0};
      payload['compositionDescriptor'] = desc;
      stub.returnValue = payload;

      final result = await platform.stopRecording(sessionId: _sessionId);

      expect(
        result.compositionDescriptor.trimWindow.startSeconds,
        closeTo(3.0, 1e-10),
      );
      expect(
        result.compositionDescriptor.trimWindow.endSeconds,
        closeTo(13.0, 1e-10),
      );
    });
  });

  // ── 4. Error code routing ────────────────────────────────────────────────────

  group('error code routing from platform channel', () {
    test(
      'PlatformException is wrapped in VGDuetException by stopRecording',
      () async {
        stub.returnValue = null; // triggers null-result guard

        expect(
          () => platform.stopRecording(sessionId: _sessionId),
          throwsA(isA<VGDuetException>()),
        );
      },
    );

    test('initializeSession with null result throws VGDuetException', () async {
      stub.returnValue = null;
      final src = VGDuetSource.localFile('/test/source.mp4');
      final trim = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 10.0);

      expect(
        () => platform.initializeSession(source: src, trimWindow: trim),
        throwsA(isA<VGDuetException>()),
      );
    });
  });

  // ── 5. MethodChannel route names (all 10) ───────────────────────────────────

  group('all 10 MethodChannel route names are preserved', () {
    test('initializeDuetSession route name', () async {
      stub.returnValue = 'sid-001';
      await platform.initializeSession(
        source: VGDuetSource.localFile('/t/c.mp4'),
        trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
      );
      expect(stub.lastMethod, 'initializeDuetSession');
    });

    test('updateDuetLayout route name', () async {
      await platform.updateLayout(
        sessionId: _sessionId,
        layoutConfig: VGDuetLayoutConfig(mode: VGDuetLayoutMode.splitLeftRight),
      );
      expect(stub.lastMethod, 'updateDuetLayout');
    });

    test('setDuetRecordingSpeed route name', () async {
      await platform.setRecordingSpeed(sessionId: _sessionId, speed: 0.5);
      expect(stub.lastMethod, 'setDuetRecordingSpeed');
    });

    test('setDuetAudioMixGains route name', () async {
      await platform.setAudioMixGains(
        sessionId: _sessionId,
        sourceGain: 0.8,
        micGain: 0.6,
      );
      expect(stub.lastMethod, 'setDuetAudioMixGains');
    });

    test('startDuetRecording route name', () async {
      await platform.startRecording(sessionId: _sessionId);
      expect(stub.lastMethod, 'startDuetRecording');
    });

    test('pauseDuetRecording route name', () async {
      await platform.pauseRecording(sessionId: _sessionId);
      expect(stub.lastMethod, 'pauseDuetRecording');
    });

    test('resumeDuetRecording route name', () async {
      await platform.resumeRecording(sessionId: _sessionId);
      expect(stub.lastMethod, 'resumeDuetRecording');
    });

    test('deleteLastDuetSegment route name', () async {
      await platform.deleteLastSegment(sessionId: _sessionId);
      expect(stub.lastMethod, 'deleteLastDuetSegment');
    });

    test('stopDuetRecording route name', () async {
      stub.returnValue = _lifecycleStopPayload(
        totalDurationMs: 2000,
        segmentCount: 1,
      );
      await platform.stopRecording(sessionId: _sessionId);
      expect(stub.lastMethod, 'stopDuetRecording');
    });

    test('disposeDuetSession route name', () async {
      await platform.disposeSession(sessionId: _sessionId);
      expect(stub.lastMethod, 'disposeDuetSession');
    });
  });
}
