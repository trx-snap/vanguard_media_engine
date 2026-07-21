// vg_waveform_extractor_test.dart
// vanguard_media_engine — Phase 8.15C / Phase 8.18
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
//
//   Phase 8.18 cache integration tests:
//   WAVE-16: null cacheKey bypasses cache, calls native extraction.
//   WAVE-17: empty cacheKey bypasses cache, calls native extraction.
//   WAVE-18: cache hit returns cached result, does not call native extraction.
//   WAVE-19: cache miss calls native extraction and then saves result.
//   WAVE-20: cache load throws, falls back to native extraction and saves result.
//   WAVE-21: cache save throws after extraction, still returns extracted result.
//   WAVE-22: native extraction error still propagates when cacheKey is provided.
//   WAVE-23: cache hit does not call waveformCache_save.

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_waveform_cache.dart';
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

  // ── Phase 8.18 cache integration tests ──────────────────────────────────────
  group('Phase 8.18: cache integration', () {
    const channel = MethodChannel('vanguard_media_engine');
    late List<MethodCall> capturedCalls;

    // Shared mock native extraction result (pointCount=3 to distinguish from cache).
    final nativeResult = {
      'samples': Float32List.fromList([0.1, 0.2, 0.3]),
      'durationSeconds': 3.0,
      'samplesPerSecond': 100,
      'pointCount': 3,
    };

    // Shared cached result payload (pointCount=2, durationSeconds=2.0 to distinguish).
    final cachedSamples = Float32List.fromList([0.9, 0.8]);
    final Map<String, dynamic> cachedResultPayload = <String, dynamic>{
      'durationSeconds': 2.0,
      'samplesPerSecond': 50,
      'pointCount': 2,
      'samples': cachedSamples.buffer.asUint8List(
        cachedSamples.offsetInBytes,
        cachedSamples.lengthInBytes,
      ),
    };

    setUp(() {
      capturedCalls = [];
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    // ── WAVE-16 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-16: null cacheKey bypasses cache, calls native extraction',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'extractWaveform') return nativeResult;
              if (call.method == 'waveformCache_load' ||
                  call.method == 'waveformCache_save') {
                fail('Cache must not be touched when cacheKey is null');
              }
              return null;
            });

        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          cacheKey: null,
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('extractWaveform'));
        expect(methods, isNot(contains('waveformCache_load')));
        expect(methods, isNot(contains('waveformCache_save')));
        expect(result.pointCount, 3);
      },
    );

    // ── WAVE-17 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-17: empty cacheKey bypasses cache, calls native extraction',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'extractWaveform') return nativeResult;
              if (call.method == 'waveformCache_load' ||
                  call.method == 'waveformCache_save') {
                fail('Cache must not be touched when cacheKey is empty');
              }
              return null;
            });

        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          cacheKey: '',
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('extractWaveform'));
        expect(methods, isNot(contains('waveformCache_load')));
        expect(methods, isNot(contains('waveformCache_save')));
        expect(result.pointCount, 3);
      },
    );

    // ── WAVE-18 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-18: cache hit returns cached result, native extraction skipped',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_load')
                return cachedResultPayload;
              if (call.method == 'extractWaveform') {
                fail('Native extraction must not be called on cache hit');
              }
              return null;
            });

        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          samplesPerSecond: 50,
          cacheKey: 'track-abc',
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('waveformCache_load'));
        expect(methods, isNot(contains('extractWaveform')));
        expect(methods, isNot(contains('waveformCache_save')));
        expect(result.durationSeconds, closeTo(2.0, 0.001));
        expect(result.samplesPerSecond, 50);
        expect(result.pointCount, 2);
        expect(result.samples.length, 2);
      },
    );

    // ── WAVE-19 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-19: cache miss calls native extraction and then saves result',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_load')
                return null; // cache miss
              if (call.method == 'extractWaveform') return nativeResult;
              if (call.method == 'waveformCache_save') return null;
              return null;
            });

        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          cacheKey: 'track-xyz',
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('waveformCache_load'));
        expect(methods, contains('extractWaveform'));
        expect(methods, contains('waveformCache_save'));
        // Load must precede extractWaveform, save must follow.
        final loadIdx = methods.indexOf('waveformCache_load');
        final extractIdx = methods.indexOf('extractWaveform');
        final saveIdx = methods.indexOf('waveformCache_save');
        expect(loadIdx, lessThan(extractIdx));
        expect(extractIdx, lessThan(saveIdx));
        // Result must be the native extraction result.
        expect(result.pointCount, 3);
        expect(result.durationSeconds, closeTo(3.0, 0.001));
        // Save payload must carry the correct cacheKey.
        final saveArgs =
            capturedCalls
                    .firstWhere((c) => c.method == 'waveformCache_save')
                    .arguments
                as Map;
        expect(saveArgs['cacheKey'], 'track-xyz');
      },
    );

    // ── WAVE-20 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-20: cache load throws, falls back to native extraction and saves',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_load') {
                throw PlatformException(
                  code: 'CACHE_ERROR',
                  message: 'Disk read failed',
                );
              }
              if (call.method == 'extractWaveform') return nativeResult;
              if (call.method == 'waveformCache_save') return null;
              return null;
            });

        // Must not throw even though cache load threw.
        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          cacheKey: 'track-fallback',
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('waveformCache_load'));
        expect(methods, contains('extractWaveform'));
        expect(methods, contains('waveformCache_save'));
        expect(result.pointCount, 3);
      },
    );

    // ── WAVE-21 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-21: cache save throws after extraction, still returns extracted result',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_load') return null; // miss
              if (call.method == 'extractWaveform') return nativeResult;
              if (call.method == 'waveformCache_save') {
                throw PlatformException(
                  code: 'CACHE_SAVE_FAILED',
                  message: 'Disk full',
                );
              }
              return null;
            });

        // Must not throw even though save threw.
        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          cacheKey: 'track-save-fails',
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('waveformCache_save'));
        expect(result.pointCount, 3);
        expect(result.samples.length, isPositive);
      },
    );

    // ── WAVE-22 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-22: native extraction error propagates when cacheKey is provided',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_load') return null; // miss
              if (call.method == 'extractWaveform') {
                throw PlatformException(
                  code: 'NO_AUDIO_TRACK',
                  message: 'no audio',
                );
              }
              return null;
            });

        await expectLater(
          () => VGAudioWaveformExtractor.extract(
            path: '/tmp/silent.mp4',
            cacheKey: 'track-error',
          ),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'NO_AUDIO_TRACK',
            ),
          ),
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('waveformCache_load'));
        expect(methods, contains('extractWaveform'));
        expect(methods, isNot(contains('waveformCache_save')));
      },
    );

    // ── WAVE-23 ──────────────────────────────────────────────────────────────
    test('WAVE-23: cache hit does not call waveformCache_save', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedCalls.add(call);
            if (call.method == 'waveformCache_load') return cachedResultPayload;
            if (call.method == 'waveformCache_save') {
              fail('waveformCache_save must not be called on cache hit');
            }
            return null;
          });

      await VGAudioWaveformExtractor.extract(
        path: '/tmp/test.mp4',
        cacheKey: 'track-hit-no-save',
      );

      final methods = capturedCalls.map((c) => c.method).toList();
      expect(methods, isNot(contains('waveformCache_save')));
    });

    // ── WAVE-24 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-24: cacheKey and namespacedCacheAddress are mutually exclusive',
      () async {
        expect(
          () => VGAudioWaveformExtractor.extract(
            path: '/tmp/test.mp4',
            cacheKey: 'flat-key',
            namespacedCacheAddress: const VGAudioWaveformCacheAddress(
              'ns',
              'ak',
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    // ── WAVE-25 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-25: namespaced cache hit returns cached result without native extraction',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_lookupNamespaced') {
                return {'status': 'hit', 'result': cachedResultPayload};
              }
              if (call.method == 'extractWaveform') {
                fail(
                  'Native extraction must not be called on namespaced cache hit',
                );
              }
              return null;
            });

        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          samplesPerSecond: 50,
          namespacedCacheAddress: const VGAudioWaveformCacheAddress(
            'ns1',
            'ak1',
          ),
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('waveformCache_lookupNamespaced'));
        expect(methods, isNot(contains('extractWaveform')));
        expect(result.samplesPerSecond, 50);
        expect(result.pointCount, 2);
      },
    );

    // ── WAVE-26 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-26: namespaced cache miss extracts and saves via write lease',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_lookupNamespaced') {
                return {'status': 'miss', 'writeLease': 'token.123'};
              }
              if (call.method == 'extractWaveform') return nativeResult;
              if (call.method == 'waveformCache_saveNamespaced') {
                return {'status': 'saved'};
              }
              return null;
            });

        final result = await VGAudioWaveformExtractor.extract(
          path: '/tmp/test.mp4',
          samplesPerSecond: 100,
          namespacedCacheAddress: const VGAudioWaveformCacheAddress(
            'ns1',
            'ak1',
          ),
        );

        final methods = capturedCalls.map((c) => c.method).toList();
        expect(methods, contains('waveformCache_lookupNamespaced'));
        expect(methods, contains('extractWaveform'));
        expect(methods, contains('waveformCache_saveNamespaced'));
        expect(result.pointCount, 3);
      },
    );

    // ── WAVE-27 ──────────────────────────────────────────────────────────────
    test(
      'WAVE-27: cached duration > maxDurationSeconds throws DURATION_EXCEEDED',
      () async {
        final longCachedPayload = {
          'durationSeconds': 900.0,
          'samplesPerSecond': 100,
          'pointCount': 2,
          'samples': cachedSamples.buffer.asUint8List(
            cachedSamples.offsetInBytes,
            cachedSamples.lengthInBytes,
          ),
        };

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCalls.add(call);
              if (call.method == 'waveformCache_lookupNamespaced') {
                return {'status': 'hit', 'result': longCachedPayload};
              }
              return null;
            });

        expect(
          () => VGAudioWaveformExtractor.extract(
            path: '/tmp/test.mp4',
            samplesPerSecond: 100,
            maxDurationSeconds: 600.0,
            namespacedCacheAddress: const VGAudioWaveformCacheAddress(
              'ns1',
              'ak1',
            ),
          ),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'DURATION_EXCEEDED',
            ),
          ),
        );
      },
    );
  });
}
