// Copyright 2026, Connects. All rights reserved.
//
// VG-DUET-SLICE-3: Duet Source Video Decoder, Preview Clock & Frame Provider Seam Tests.
//
// Verifies Dart/channel payload and clock/segment contract expectations:
//   - initialize primes decoder at trimStart for valid local .mp4/.mov after source validation
//   - start/pause/resume/stop produce segment maps whose source/output PTS reflect speed and trimStart, not raw wall-clock from zero
//   - deleteLastSegment rolls back clock/segment cursor
//   - auto-stopped/completed state still allows stopDuetRecording to return descriptor
//   - dispose releases decoder resources without blocking
//   - failure mapping: source_invalid, composition_failed, session_not_found, invalid_state
//
// NOTE: Dart tests verify channel payload contracts and timing math expectations;
// they do not claim to prove native hardware video decoding.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_composition_descriptor.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_platform_interface.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_source.dart';

const _channelName = 'vanguard_media_engine';
const _testSessionId = 'test-duet-slice3-session-42';

/// Fake MethodChannel that tracks calls and allows configuring return values or errors.
class _MockDuetChannel extends Fake implements MethodChannel {
  final List<String> callLog = [];
  final Map<String, dynamic> recordedArgs = {};
  dynamic nextReturnValue;
  PlatformException? nextError;

  @override
  String get name => _channelName;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    callLog.add(method);
    if (arguments is Map) {
      recordedArgs[method] = Map<String, dynamic>.from(arguments);
    }
    if (nextError != null) {
      final err = nextError!;
      nextError = null;
      throw err;
    }
    if (nextReturnValue is T?) {
      final val = nextReturnValue as T?;
      return val;
    }
    return null;
  }
}

Map<String, dynamic> _buildStopPayload({
  required List<Map<String, dynamic>> segments,
  required double trimStart,
  required double trimEnd,
  required int totalDurationMs,
  String filePath = '/tmp/source_test.mp4',
}) {
  return {
    'compositionDescriptor': {
      'source': {'filePath': filePath},
      'layoutConfig': {
        'mode': 'splitLeftRight',
        'isSideSwapped': false,
        'isTopBottomSwapped': false,
      },
      'trimWindow': {'startSeconds': trimStart, 'endSeconds': trimEnd},
      'initialSpeed': 1.0,
      'segments': segments,
      'sourceAudioGain': 1.0,
      'micAudioGain': 1.0,
      'sourceAudioMuted': false,
      'micAudioMuted': false,
    },
    'totalDurationMs': totalDurationMs,
    'segmentCount': segments.length,
    'segmentAssets': <String>[],
    'proofOutputPath': null,
  };
}

void main() {
  late _MockDuetChannel mockChannel;
  late MethodChannelVGDuetPlatform platform;

  setUp(() {
    mockChannel = _MockDuetChannel();
    platform = MethodChannelVGDuetPlatform(channel: mockChannel);
  });

  // ── Scenario 1: initialize primes decoder at trimStart for valid source ───

  group('Scenario 1: initializeSession primes at trimStart', () {
    test('passes source and trimWindow parameters to native channel', () async {
      mockChannel.nextReturnValue = _testSessionId;

      final sessionId = await platform.initializeSession(
        source: VGDuetSource.localFile('/storage/clips/duet_source.mp4'),
        trimWindow: VGDuetTrimWindow(startSeconds: 2.5, endSeconds: 12.5),
      );

      expect(sessionId, _testSessionId);
      expect(mockChannel.callLog, contains('initializeDuetSession'));

      final args = mockChannel.recordedArgs['initializeDuetSession'];
      expect(args, isNotNull);
      final srcMap = args!['source'] as Map;
      expect(srcMap['filePath'], '/storage/clips/duet_source.mp4');

      final trimMap = args['trimWindow'] as Map;
      expect(trimMap['startSeconds'], closeTo(2.5, 1e-6));
      expect(trimMap['endSeconds'], closeTo(12.5, 1e-6));
    });

    test('maps source_invalid PlatformException to VGDuetErrorCode.sourceInvalid', () async {
      mockChannel.nextError = PlatformException(
        code: 'source_invalid',
        message: 'Source file does not exist or has no video track.',
      );

      expect(
        () => platform.initializeSession(
          source: VGDuetSource.localFile('/nonexistent.mp4'),
          trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
        ),
        throwsA(
          isA<VGDuetException>().having(
            (e) => e.code,
            'code',
            VGDuetErrorCode.sourceInvalid,
          ),
        ),
      );
    });
  });

  // ── Scenario 2: start/pause/resume/stop reflect speed and trimStart ─────────

  group('Scenario 2: segments reflect speed and trimStart offset', () {
    test('multi-segment payload has clock-derived source PTS starting at trimStart', () async {
      // trimStart = 2000 ms, trimEnd = 10000 ms
      // Seg 0: 1.0x, wall 1500 ms -> source: [2000, 3500], output: [0, 1500], duration: 1500
      // Seg 1: 2.0x, wall 2000 ms -> source: [3500, 7500], output: [1500, 5500], duration: 4000 (2000 * 2.0 = 4000)
      // Seg 2: 0.5x, wall 1000 ms -> source: [7500, 8000], output: [5500, 6000], duration: 500 (1000 * 0.5 = 500)
      final segmentMaps = [
        {
          'segmentIndex': 0,
          'durationMs': 1500,
          'speedMultiplier': 1.0,
          'sourceStartMs': 2000,
          'sourceEndMs': 3500,
          'outputStartMs': 0,
          'outputEndMs': 1500,
        },
        {
          'segmentIndex': 1,
          'durationMs': 4000,
          'speedMultiplier': 2.0,
          'sourceStartMs': 3500,
          'sourceEndMs': 7500,
          'outputStartMs': 1500,
          'outputEndMs': 5500,
        },
        {
          'segmentIndex': 2,
          'durationMs': 500,
          'speedMultiplier': 0.5,
          'sourceStartMs': 7500,
          'sourceEndMs': 8000,
          'outputStartMs': 5500,
          'outputEndMs': 6000,
        },
      ];

      mockChannel.nextReturnValue = _buildStopPayload(
        segments: segmentMaps,
        trimStart: 2.0,
        trimEnd: 10.0,
        totalDurationMs: 6000,
      );

      final result = await platform.stopRecording(sessionId: _testSessionId);

      expect(result.segmentCount, 3);
      expect(result.totalDurationMs, 6000);

      final segments = result.compositionDescriptor.segments;
      expect(segments.length, 3);

      // Verify Segment 0: start at trimStart (2000), not zero
      expect(segments[0].sourceStartMs, 2000);
      expect(segments[0].sourceEndMs, 3500);
      expect(segments[0].outputStartMs, 0);
      expect(segments[0].outputEndMs, 1500);
      expect(segments[0].durationMs, 1500);
      expect(segments[0].speedMultiplier, 1.0);

      // Verify Segment 1: speed 2.0x scales progression by 2.0x
      expect(segments[1].sourceStartMs, 3500);
      expect(segments[1].sourceEndMs, 7500);
      expect(segments[1].sourceEndMs - segments[1].sourceStartMs, 4000);
      expect(segments[1].durationMs, 4000);
      expect(segments[1].speedMultiplier, 2.0);

      // Verify Segment 2: speed 0.5x scales progression by 0.5x
      expect(segments[2].sourceStartMs, 7500);
      expect(segments[2].sourceEndMs, 8000);
      expect(segments[2].sourceEndMs - segments[2].sourceStartMs, 500);
      expect(segments[2].durationMs, 500);
      expect(segments[2].speedMultiplier, 0.5);

      // Verify composition timeline continuity
      expect(segments[0].outputEndMs, segments[1].outputStartMs);
      expect(segments[1].outputEndMs, segments[2].outputStartMs);
    });
  });

  // ── Scenario 3: deleteLastSegment rolls back cursor ───────────────────────

  group('Scenario 3: deleteLastSegment rolls back segment cursor', () {
    test('routes deleteLastDuetSegment and updates subsequent stop payload', () async {
      mockChannel.nextReturnValue = null;
      await platform.deleteLastSegment(sessionId: _testSessionId);
      expect(mockChannel.callLog, contains('deleteLastDuetSegment'));

      // If segment 2 was rolled back, remaining segments are 0 and 1
      final rolledBackSegments = [
        {
          'segmentIndex': 0,
          'durationMs': 1500,
          'speedMultiplier': 1.0,
          'sourceStartMs': 2000,
          'sourceEndMs': 3500,
          'outputStartMs': 0,
          'outputEndMs': 1500,
        },
        {
          'segmentIndex': 1,
          'durationMs': 4000,
          'speedMultiplier': 2.0,
          'sourceStartMs': 3500,
          'sourceEndMs': 7500,
          'outputStartMs': 1500,
          'outputEndMs': 5500,
        },
      ];

      mockChannel.nextReturnValue = _buildStopPayload(
        segments: rolledBackSegments,
        trimStart: 2.0,
        trimEnd: 10.0,
        totalDurationMs: 5500,
      );

      final result = await platform.stopRecording(sessionId: _testSessionId);
      expect(result.segmentCount, 2);
      expect(result.totalDurationMs, 5500);
      expect(result.compositionDescriptor.segments.last.sourceEndMs, 7500);
      expect(result.compositionDescriptor.segments.last.outputEndMs, 5500);
    });
  });

  // ── Scenario 4: auto-stopped/completed state allows stopDuetRecording ───────

  group('Scenario 4: auto-stopped state returns descriptor without error', () {
    test('stopDuetRecording returns composition descriptor when trimEnd reached', () async {
      // Full trim window consumed: source starts at 1000, ends at trimEnd 6000
      final fullTakeSegments = [
        {
          'segmentIndex': 0,
          'durationMs': 5000,
          'speedMultiplier': 1.0,
          'sourceStartMs': 1000,
          'sourceEndMs': 6000,
          'outputStartMs': 0,
          'outputEndMs': 5000,
        },
      ];

      mockChannel.nextReturnValue = _buildStopPayload(
        segments: fullTakeSegments,
        trimStart: 1.0,
        trimEnd: 6.0,
        totalDurationMs: 5000,
      );

      // Calling stop when completed/autoStopped must return descriptor normally
      final result = await platform.stopRecording(sessionId: _testSessionId);
      expect(result.segmentCount, 1);
      expect(result.totalDurationMs, 5000);
      expect(result.compositionDescriptor.segments.first.sourceEndMs, 6000);
      expect(result.compositionDescriptor.trimWindow.endSeconds, 6.0);
    });
  });

  // ── Scenario 5: dispose and error mapping ───────────────────────────────────

  group('Scenario 5: dispose and failure mapping contracts', () {
    test('disposeSession invokes disposeDuetSession cleanly', () async {
      mockChannel.nextReturnValue = null;
      await platform.disposeSession(sessionId: _testSessionId);
      expect(mockChannel.callLog, contains('disposeDuetSession'));
      expect(
        mockChannel.recordedArgs['disposeDuetSession']?['sessionId'],
        _testSessionId,
      );
    });

    test('composition_failed maps to VGDuetErrorCode.compositionFailed', () async {
      mockChannel.nextError = PlatformException(
        code: 'composition_failed',
        message: 'Surface decoder failed to decode frame at target PTS.',
      );

      expect(
        () => platform.stopRecording(sessionId: _testSessionId),
        throwsA(
          isA<VGDuetException>().having(
            (e) => e.code,
            'code',
            VGDuetErrorCode.compositionFailed,
          ),
        ),
      );
    });

    test('invalid_state throws VGDuetException', () async {
      mockChannel.nextError = PlatformException(
        code: 'invalid_state',
        message: 'Operation not valid in current state.',
      );

      expect(
        () => platform.startRecording(sessionId: _testSessionId),
        throwsA(isA<VGDuetException>()),
      );
    });
  });

  // ── PreviewClock pure Dart contract verification ───────────────────────────

  group('PreviewClock timing math contract simulation', () {
    test('speed scaling math: T_out = S * T_wall and source PTS advances in lockstep', () {
      const trimStartMs = 1500;
      const trimEndMs = 9500;

      // Simulate clock state
      var sourceCursor = trimStartMs;
      var outputCursor = 0;

      // Segment 1: 0.5x speed for 1000 ms wall -> 500 ms source/output
      const speed1 = 0.5;
      const wallMs1 = 1000;
      final progression1 = (wallMs1 * speed1).round();
      expect(progression1, 500);

      final seg1SourceStart = sourceCursor;
      final seg1SourceEnd = seg1SourceStart + progression1;
      final seg1OutputStart = outputCursor;
      final seg1OutputEnd = seg1OutputStart + progression1;

      sourceCursor = seg1SourceEnd;
      outputCursor = seg1OutputEnd;

      expect(seg1SourceStart, 1500);
      expect(seg1SourceEnd, 2000);
      expect(seg1OutputStart, 0);
      expect(seg1OutputEnd, 500);

      // Segment 2: 2.0x speed for 2000 ms wall -> 4000 ms source/output, clamped at trimEnd
      const speed2 = 2.0;
      const wallMs2 = 2000;
      final nominalProgression2 = (wallMs2 * speed2).round();
      expect(nominalProgression2, 4000);

      final maxAvailableSrc = trimEndMs - sourceCursor; // 9500 - 2000 = 7500
      final progression2 = nominalProgression2 < maxAvailableSrc ? nominalProgression2 : maxAvailableSrc;
      expect(progression2, 4000);

      final seg2SourceStart = sourceCursor;
      final seg2SourceEnd = seg2SourceStart + progression2;
      final seg2OutputStart = outputCursor;
      final seg2OutputEnd = seg2OutputStart + progression2;

      sourceCursor = seg2SourceEnd;
      outputCursor = seg2OutputEnd;

      expect(seg2SourceStart, 2000);
      expect(seg2SourceEnd, 6000);
      expect(seg2OutputStart, 500);
      expect(seg2OutputEnd, 4500);

      // Verify trimEnd clamp threshold
      final remainingSrc = trimEndMs - sourceCursor; // 9500 - 6000 = 3500 ms remaining
      expect(remainingSrc, 3500);
    });
  });
}
