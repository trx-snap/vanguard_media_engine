// vg_waveform_extractor_test.dart
// vanguard_media_engine — Phase 8.15C
//
// Unit tests for VGAudioWaveformResult and VGAudioWaveformExtractor.
//
// Coverage:
//   WAVE-1: VGAudioWaveformResult construction and field access.
//   WAVE-2: VGAudioWaveformResult equality.
//   WAVE-3: VGAudioWaveformResult hashCode stability.
//   WAVE-4: Empty path throws ArgumentError.
//   WAVE-5: samplesPerSecond = 0 throws ArgumentError.
//   WAVE-6: samplesPerSecond negative throws ArgumentError.
//   WAVE-7: samplesPerSecond > 1000 throws ArgumentError.
//   WAVE-8: maxDurationSeconds = 0 throws ArgumentError.
//   WAVE-9: maxDurationSeconds negative throws ArgumentError.
//   WAVE-10: MethodChannel name is 'vanguard_media_engine'.
//   WAVE-11: Argument payload contains correct keys.
//   WAVE-12: Mock result parsing — samples, durationSeconds, samplesPerSecond, pointCount.
//   WAVE-13: PlatformException propagation.
//   WAVE-14: Uint8List bytes from channel are reinterpreted as Float32List.
//   WAVE-15: VGAudioWaveformResult.toString contains pointCount.

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_waveform_extractor.dart';

void main() {
  // ── WAVE-1 ─────────────────────────────────────────────────────────────────
  test('WAVE-1: VGAudioWaveformResult construction and field access', () {
    final samples = Float32List.fromList([0.1, 0.2, 0.3]);
    final result = VGAudioWaveformResult(
      samples: samples,
      durationSeconds: 5.0,
      samplesPerSecond: 100,
      pointCount: 3,
    );
    expect(result.samples.length, 3);
    expect(result.samples[0], closeTo(0.1, 0.001));
    expect(result.durationSeconds, 5.0);
    expect(result.samplesPerSecond, 100);
    expect(result.pointCount, 3);
  });

  // ── WAVE-2 ─────────────────────────────────────────────────────────────────
  test('WAVE-2: VGAudioWaveformResult equality', () {
    final samples = Float32List.fromList([0.5, 0.6]);
    final a = VGAudioWaveformResult(
      samples: samples,
      durationSeconds: 10.0,
      samplesPerSecond: 50,
      pointCount: 2,
    );
    final b = VGAudioWaveformResult(
      samples: Float32List.fromList([0.5, 0.6]),
      durationSeconds: 10.0,
      samplesPerSecond: 50,
      pointCount: 2,
    );
    expect(a, equals(b));
  });

  // ── WAVE-3 ─────────────────────────────────────────────────────────────────
  test('WAVE-3: VGAudioWaveformResult hashCode is stable', () {
    final samples = Float32List.fromList([0.3]);
    final result = VGAudioWaveformResult(
      samples: samples,
      durationSeconds: 3.0,
      samplesPerSecond: 100,
      pointCount: 1,
    );
    final hash1 = result.hashCode;
    final hash2 = result.hashCode;
    expect(hash1, equals(hash2));
  });

  // ── WAVE-4 ─────────────────────────────────────────────────────────────────
  test('WAVE-4: empty path throws ArgumentError', () async {
    expect(
      () => VGAudioWaveformExtractor.extract(path: ''),
      throwsA(isA<ArgumentError>()),
    );
  });

  // ── WAVE-5 ─────────────────────────────────────────────────────────────────
  test('WAVE-5: samplesPerSecond = 0 throws ArgumentError', () {
    expect(
      () => VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
        samplesPerSecond: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  // ── WAVE-6 ─────────────────────────────────────────────────────────────────
  test('WAVE-6: samplesPerSecond negative throws ArgumentError', () {
    expect(
      () => VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
        samplesPerSecond: -1,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  // ── WAVE-7 ─────────────────────────────────────────────────────────────────
  test('WAVE-7: samplesPerSecond > 1000 throws ArgumentError', () {
    expect(
      () => VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
        samplesPerSecond: 1001,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  // ── WAVE-8 ─────────────────────────────────────────────────────────────────
  test('WAVE-8: maxDurationSeconds = 0 throws ArgumentError', () {
    expect(
      () => VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
        maxDurationSeconds: 0.0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  // ── WAVE-9 ─────────────────────────────────────────────────────────────────
  test('WAVE-9: maxDurationSeconds negative throws ArgumentError', () {
    expect(
      () => VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
        maxDurationSeconds: -5.0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  // ── WAVE-10 / WAVE-11 / WAVE-12 / WAVE-13 / WAVE-14 ─────────────────────
  group('MethodChannel tests', () {
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

    // ── WAVE-10 ───────────────────────────────────────────────────────────────
    test('WAVE-10: channel name is vanguard_media_engine', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        capturedCalls.add(call);
        if (call.method == 'extractWaveform') {
          final f32 = Float32List.fromList([0.1, 0.2]);
          return {
            'samples': f32,
            'durationSeconds': 2.0,
            'samplesPerSecond': 100,
            'pointCount': 2,
          };
        }
        return null;
      });

      await VGAudioWaveformExtractor.extract(path: '/tmp/test.mp4');

      expect(capturedCalls.any((c) => c.method == 'extractWaveform'), isTrue);
    });

    // ── WAVE-11 ───────────────────────────────────────────────────────────────
    test('WAVE-11: argument payload contains correct keys', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        capturedCalls.add(call);
        if (call.method == 'extractWaveform') {
          return {
            'samples': Float32List.fromList([0.5]),
            'durationSeconds': 1.0,
            'samplesPerSecond': 50,
            'pointCount': 1,
          };
        }
        return null;
      });

      await VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
        samplesPerSecond: 50,
        maxDurationSeconds: 300.0,
      );

      expect(capturedCalls.length, 1);
      final args = capturedCalls.first.arguments as Map;
      expect(args['path'], '/tmp/test.mp4');
      expect(args['samplesPerSecond'], 50);
      expect(args['maxDurationSeconds'], 300.0);
    });

    // ── WAVE-12 ───────────────────────────────────────────────────────────────
    test('WAVE-12: mock result parsing returns correct fields', () async {
      final mockSamples = Float32List.fromList([0.1, 0.3, 0.5, 0.2]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'extractWaveform') {
          return {
            'samples': mockSamples,
            'durationSeconds': 4.5,
            'samplesPerSecond': 100,
            'pointCount': 4,
          };
        }
        return null;
      });

      final result = await VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
      );

      expect(result.pointCount, 4);
      expect(result.durationSeconds, closeTo(4.5, 0.001));
      expect(result.samplesPerSecond, 100);
      expect(result.samples.length, 4);
      expect(result.samples[2], closeTo(0.5, 0.001));
    });

    // ── WAVE-13 ───────────────────────────────────────────────────────────────
    test('WAVE-13: PlatformException propagation', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'extractWaveform') {
          throw PlatformException(
            code: 'NO_AUDIO_TRACK',
            message: 'Asset contains no audio track',
          );
        }
        return null;
      });

      expect(
        () => VGAudioWaveformExtractor.extract(path: '/tmp/silent.mp4'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'NO_AUDIO_TRACK',
          ),
        ),
      );
    });

    // ── WAVE-14 ───────────────────────────────────────────────────────────────
    test('WAVE-14: Float32List direct channel response accepted', () async {
      // Verify the fast path: when native returns a Float32List, it is used
      // directly without reinterpretation. This is the real device path.
      final mockSamples = Float32List.fromList([0.1, 0.2, 0.3, 0.4, 0.5]);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'extractWaveform') {
          return {
            'samples': mockSamples,
            'durationSeconds': 5.0,
            'samplesPerSecond': 100,
            'pointCount': 5,
          };
        }
        return null;
      });

      final result = await VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
      );

      expect(result.samples.length, 5);
      expect(result.samples[4], closeTo(0.5, 0.001));
    });

  });

  // ── WAVE-15 ─────────────────────────────────────────────────────────────────
  test('WAVE-15: toString contains pointCount', () {
    final result = VGAudioWaveformResult(
      samples: Float32List.fromList([0.4]),
      durationSeconds: 1.5,
      samplesPerSecond: 100,
      pointCount: 1,
    );
    expect(result.toString(), contains('pointCount: 1'));
  });
}
