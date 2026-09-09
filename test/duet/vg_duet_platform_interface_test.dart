// Copyright 2026, Connects. All rights reserved.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_source.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_composition_descriptor.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_platform_interface.dart';

const _channelName = 'vanguard_media_engine';
const _sessionId = 'test-session-001';

/// Records the last method call name and arguments.
class _FakeMethodChannel extends Fake implements MethodChannel {
  String? lastMethod;
  dynamic lastArgs;
  dynamic returnValue;

  @override
  String get name => _channelName;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    lastMethod = method;
    lastArgs = arguments;
    if (returnValue is T?) return returnValue as T?;
    return null;
  }
}

void main() {
  late _FakeMethodChannel fakeChannel;
  late MethodChannelVGDuetPlatform platform;

  setUp(() {
    fakeChannel = _FakeMethodChannel();
    platform = MethodChannelVGDuetPlatform(channel: fakeChannel);
  });

  group('MethodChannelVGDuetPlatform method names', () {
    test('initializeSession calls initializeDuetSession', () async {
      fakeChannel.returnValue = 'session-abc';
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      final trim = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 10.0);
      await platform.initializeSession(source: src, trimWindow: trim);
      expect(fakeChannel.lastMethod, 'initializeDuetSession');
    });

    test('initializeSession payload contains source and trimWindow', () async {
      fakeChannel.returnValue = 'session-abc';
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      final trim = VGDuetTrimWindow(startSeconds: 2.0, endSeconds: 12.0);
      await platform.initializeSession(source: src, trimWindow: trim);
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect((args['source'] as Map)['filePath'], '/tmp/clip.mp4');
      expect((args['trimWindow'] as Map)['startSeconds'], closeTo(2.0, 1e-10));
    });

    test('updateLayout calls updateDuetLayout with sessionId', () async {
      final config = VGDuetLayoutConfig(mode: VGDuetLayoutMode.pip);
      await platform.updateLayout(sessionId: _sessionId, layoutConfig: config);
      expect(fakeChannel.lastMethod, 'updateDuetLayout');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
      expect((args['layoutConfig'] as Map)['mode'], 'pip');
    });

    test('setRecordingSpeed calls setDuetRecordingSpeed', () async {
      await platform.setRecordingSpeed(sessionId: _sessionId, speed: 2.0);
      expect(fakeChannel.lastMethod, 'setDuetRecordingSpeed');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
      expect(args['speed'], closeTo(2.0, 1e-10));
    });

    test('setAudioMixGains calls setDuetAudioMixGains', () async {
      await platform.setAudioMixGains(
        sessionId: _sessionId,
        sourceGain: 0.7,
        micGain: 0.5,
      );
      expect(fakeChannel.lastMethod, 'setDuetAudioMixGains');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sourceGain'], closeTo(0.7, 1e-10));
      expect(args['micGain'], closeTo(0.5, 1e-10));
    });

    test('startRecording calls startDuetRecording', () async {
      await platform.startRecording(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'startDuetRecording');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
    });

    test('pauseRecording calls pauseDuetRecording', () async {
      await platform.pauseRecording(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'pauseDuetRecording');
    });

    test('resumeRecording calls resumeDuetRecording', () async {
      await platform.resumeRecording(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'resumeDuetRecording');
    });

    test('deleteLastSegment calls deleteLastDuetSegment', () async {
      await platform.deleteLastSegment(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'deleteLastDuetSegment');
    });

    test('disposeSession calls disposeDuetSession', () async {
      await platform.disposeSession(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'disposeDuetSession');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
    });
  });

  group('MethodChannelVGDuetPlatform error handling', () {
    test('initializeSession wraps null return in VGDuetException', () async {
      fakeChannel.returnValue = null;
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      final trim = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0);
      expect(
        () => platform.initializeSession(source: src, trimWindow: trim),
        throwsA(isA<VGDuetException>()),
      );
    });

    test(
      'initializeSession wraps empty sessionId in VGDuetException',
      () async {
        fakeChannel.returnValue = '';
        final src = VGDuetSource.localFile('/tmp/clip.mp4');
        final trim = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0);
        expect(
          () => platform.initializeSession(source: src, trimWindow: trim),
          throwsA(isA<VGDuetException>()),
        );
      },
    );
  });

  // ── Fix 1: stopRecording preserves native segmentCount ────────────────────

  group('stopRecording (Fix 1)', () {
    /// Minimal fake compositionDescriptor map that round-trips through
    /// VGDuetCompositionDescriptor.fromMap.
    Map<String, dynamic> _descriptorMap() => {
      'source': {'filePath': '/tmp/source.mp4'},
      'layoutConfig': {
        'mode': 'splitLeftRight',
        'isSideSwapped': false,
        'isTopBottomSwapped': false,
      },
      'trimWindow': {'startSeconds': 0.0, 'endSeconds': 10.0},
      'initialSpeed': 1.0,
      'segments': [],
      'sourceAudioGain': 1.0,
      'micAudioGain': 1.0,
      'sourceAudioMuted': false,
      'micAudioMuted': false,
    };

    test(
      'uses native segmentCount when present, ignores top-level segments',
      () async {
        fakeChannel.returnValue = {
          'compositionDescriptor': _descriptorMap(),
          'segmentAssets': ['/tmp/seg0.mp4', '/tmp/seg1.mp4', '/tmp/seg2.mp4'],
          'totalDurationMs': 6000,
          'segmentCount': 3, // native-provided; no top-level segments key
        };

        final result = await platform.stopRecording(sessionId: _sessionId);

        expect(result.segmentCount, 3);
        expect(
          result.compositionDescriptor,
          isA<VGDuetCompositionDescriptor>(),
        );
        expect(fakeChannel.lastMethod, 'stopDuetRecording');
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect(args['sessionId'], _sessionId);
      },
    );

    test(
      'falls back to segmentAssets.length when segmentCount absent',
      () async {
        fakeChannel.returnValue = {
          'compositionDescriptor': _descriptorMap(),
          'segmentAssets': ['/tmp/seg0.mp4', '/tmp/seg1.mp4'],
          'totalDurationMs': 4000,
          // no segmentCount key
        };

        final result = await platform.stopRecording(sessionId: _sessionId);
        expect(result.segmentCount, 2);
      },
    );

    test(
      'throws VGDuetException when segmentCount absent and no assets/segments',
      () async {
        fakeChannel.returnValue = {
          'compositionDescriptor': _descriptorMap(),
          'segmentAssets': [],
          'totalDurationMs': 1000,
          // no segmentCount, no segments, no assets
        };

        expect(
          () => platform.stopRecording(sessionId: _sessionId),
          throwsA(isA<VGDuetException>()),
        );
      },
    );
  });
}
