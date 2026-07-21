// vg_waveform_cache_test.dart
// vanguard_media_engine — Phase 8.17
//
// Unit tests for VGAudioWaveformCache Dart bridge.
//
// Coverage:
//   WC-1:  save sends waveformCache_save.
//   WC-2:  save payload includes cacheKey, samples bytes, durationSeconds,
//           samplesPerSecond, pointCount.
//   WC-3:  load sends waveformCache_load with cacheKey.
//   WC-4:  load returns VGAudioWaveformResult on cache hit.
//   WC-5:  load returns null on cache miss (native returns nil).
//   WC-6:  empty cacheKey throws ArgumentError on save (no channel call).
//   WC-7:  empty cacheKey throws ArgumentError on load (no channel call).
//   WC-8:  empty samples throws ArgumentError on save.
//   WC-9:  non-positive durationSeconds throws ArgumentError on save.
//   WC-10: non-positive samplesPerSecond throws ArgumentError on save.
//   WC-11: pointCount != samples.length throws ArgumentError on save.
//   WC-12: native CACHE_SAVE_FAILED propagates as PlatformException on save.
//   WC-13: non-finite durationSeconds throws ArgumentError on save.

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_waveform_cache.dart';
import 'package:vanguard_media_engine/vg_waveform_extractor.dart';

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

  /// Helper: builds a minimal valid VGAudioWaveformResult.
  VGAudioWaveformResult makeResult({
    int pointCount = 4,
    double duration = 2.0,
    int sps = 100,
  }) {
    final samples = Float32List.fromList(
      List.generate(pointCount, (i) => 0.1 * i),
    );
    return VGAudioWaveformResult(
      samples: samples,
      durationSeconds: duration,
      samplesPerSecond: sps,
      pointCount: pointCount,
    );
  }

  // ── WC-1 ────────────────────────────────────────────────────────────────────
  test('WC-1: save sends waveformCache_save', () async {
    setHandler((call) async => null);

    await VGAudioWaveformCache.save(
      cacheKey: 'track-abc',
      result: makeResult(),
    );

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'waveformCache_save');
  });

  // ── WC-2 ────────────────────────────────────────────────────────────────────
  test(
    'WC-2: save payload includes cacheKey, samples, durationSeconds, samplesPerSecond, pointCount',
    () async {
      setHandler((call) async => null);

      final result = makeResult(pointCount: 3, duration: 5.0, sps: 50);
      await VGAudioWaveformCache.save(cacheKey: 'my-key', result: result);

      expect(capturedCalls.length, 1);
      final args = capturedCalls.first.arguments as Map;
      expect(args['cacheKey'], 'my-key');
      expect(args['durationSeconds'], closeTo(5.0, 0.001));
      expect(args['samplesPerSecond'], 50);
      expect(args['pointCount'], 3);
      // samples should be a Uint8List of 3*4=12 bytes
      expect(args['samples'], isA<Uint8List>());
      expect((args['samples'] as Uint8List).length, 3 * 4);
    },
  );

  // ── WC-3 ────────────────────────────────────────────────────────────────────
  test('WC-3: load sends waveformCache_load with cacheKey', () async {
    setHandler((call) async => null);

    await VGAudioWaveformCache.load(cacheKey: 'track-abc');

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'waveformCache_load');
    final args = capturedCalls.first.arguments as Map;
    expect(args['cacheKey'], 'track-abc');
  });

  // ── WC-4 ────────────────────────────────────────────────────────────────────
  test('WC-4: load returns VGAudioWaveformResult on cache hit', () async {
    // Build a fake cached Float32List: [0.1, 0.5, 0.9]
    final fakeSamples = Float32List.fromList([0.1, 0.5, 0.9]);
    final fakeSampleBytes = fakeSamples.buffer.asUint8List(
      fakeSamples.offsetInBytes,
      fakeSamples.lengthInBytes,
    );

    setHandler((call) async {
      if (call.method == 'waveformCache_load') {
        return {
          'durationSeconds': 3.14,
          'samplesPerSecond': 100,
          'pointCount': 3,
          'samples': fakeSampleBytes,
        };
      }
      return null;
    });

    final result = await VGAudioWaveformCache.load(cacheKey: 'track-abc');

    expect(result, isNotNull);
    expect(result!.durationSeconds, closeTo(3.14, 0.001));
    expect(result.samplesPerSecond, 100);
    expect(result.pointCount, 3);
    expect(result.samples.length, 3);
    expect(result.samples[0], closeTo(0.1, 0.001));
    expect(result.samples[1], closeTo(0.5, 0.001));
    expect(result.samples[2], closeTo(0.9, 0.001));
  });

  // ── WC-5 ────────────────────────────────────────────────────────────────────
  test('WC-5: load returns null on cache miss (native returns nil)', () async {
    setHandler((call) async => null);

    final result = await VGAudioWaveformCache.load(cacheKey: 'missing-key');

    expect(result, isNull);
  });

  // ── WC-6 ────────────────────────────────────────────────────────────────────
  test(
    'WC-6: empty cacheKey throws ArgumentError on save (no channel call)',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioWaveformCache.save(cacheKey: '', result: makeResult()),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── WC-7 ────────────────────────────────────────────────────────────────────
  test(
    'WC-7: empty cacheKey throws ArgumentError on load (no channel call)',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioWaveformCache.load(cacheKey: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── WC-8 ────────────────────────────────────────────────────────────────────
  test('WC-8: empty samples throws ArgumentError on save', () async {
    setHandler((call) async => null);

    final badResult = VGAudioWaveformResult(
      samples: Float32List(0),
      durationSeconds: 2.0,
      samplesPerSecond: 100,
      pointCount: 0,
    );
    expect(
      () => VGAudioWaveformCache.save(cacheKey: 'key', result: badResult),
      throwsA(isA<ArgumentError>()),
    );
    expect(capturedCalls, isEmpty);
  });

  // ── WC-9 ────────────────────────────────────────────────────────────────────
  test(
    'WC-9: non-positive durationSeconds throws ArgumentError on save',
    () async {
      setHandler((call) async => null);

      // Zero duration
      expect(
        () => VGAudioWaveformCache.save(
          cacheKey: 'key',
          result: makeResult(duration: 0.0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      // Negative duration
      expect(
        () => VGAudioWaveformCache.save(
          cacheKey: 'key',
          result: makeResult(duration: -1.0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── WC-10 ───────────────────────────────────────────────────────────────────
  test(
    'WC-10: non-positive samplesPerSecond throws ArgumentError on save',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioWaveformCache.save(
          cacheKey: 'key',
          result: makeResult(sps: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── WC-11 ───────────────────────────────────────────────────────────────────
  test(
    'WC-11: pointCount != samples.length throws ArgumentError on save',
    () async {
      setHandler((call) async => null);

      // Build result where pointCount doesn't match samples.length
      final samples = Float32List.fromList([0.1, 0.2, 0.3]);
      final mismatchedResult = VGAudioWaveformResult(
        samples: samples,
        durationSeconds: 1.0,
        samplesPerSecond: 100,
        pointCount: 99, // wrong — samples.length is 3
      );
      expect(
        () => VGAudioWaveformCache.save(
          cacheKey: 'key',
          result: mismatchedResult,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── WC-12 ───────────────────────────────────────────────────────────────────
  test(
    'WC-12: native CACHE_SAVE_FAILED propagates as PlatformException',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'waveformCache_save') {
              throw PlatformException(
                code: 'CACHE_SAVE_FAILED',
                message: 'Disk full',
              );
            }
            return null;
          });

      expect(
        () => VGAudioWaveformCache.save(cacheKey: 'key', result: makeResult()),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'CACHE_SAVE_FAILED',
          ),
        ),
      );
    },
  );

  // ── WC-13 ───────────────────────────────────────────────────────────────────
  test(
    'WC-13: non-finite durationSeconds throws ArgumentError on save',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioWaveformCache.save(
          cacheKey: 'key',
          result: makeResult(duration: double.nan),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGAudioWaveformCache.save(
          cacheKey: 'key',
          result: makeResult(duration: double.infinity),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── Slice Q Namespaced Cache Tests (WC-14..WC-22) ──────────────────────────

  test('WC-14: lookupNamespaced returns hit on cached result', () async {
    final fakeSamples = Float32List.fromList([0.2, 0.4]);
    final fakeBytes = fakeSamples.buffer.asUint8List(
      fakeSamples.offsetInBytes,
      fakeSamples.lengthInBytes,
    );
    setHandler((call) async {
      if (call.method == 'waveformCache_lookupNamespaced') {
        return {
          'status': 'hit',
          'result': {
            'durationSeconds': 2.0,
            'samplesPerSecond': 100,
            'pointCount': 2,
            'samples': fakeBytes,
          },
        };
      }
      return null;
    });

    final res = await VGAudioWaveformCache.lookupNamespaced(
      namespace: 'ns1',
      assetKey: 'ak1',
      samplesPerSecond: 100,
    );

    expect(res, isA<VGAudioWaveformLookupHit>());
    final hit = res as VGAudioWaveformLookupHit;
    expect(hit.cached.pointCount, 2);
    expect(hit.cached.samplesPerSecond, 100);
  });

  test(
    'WC-15: lookupNamespaced returns miss with write lease on cache miss',
    () async {
      setHandler((call) async {
        if (call.method == 'waveformCache_lookupNamespaced') {
          return {'status': 'miss', 'writeLease': 'token123.sig456'};
        }
        return null;
      });

      final res = await VGAudioWaveformCache.lookupNamespaced(
        namespace: 'ns1',
        assetKey: 'ak1',
        samplesPerSecond: 100,
      );

      expect(res, isA<VGAudioWaveformLookupMiss>());
      final miss = res as VGAudioWaveformLookupMiss;
      expect(miss.lease.samplesPerSecond, 100);
    },
  );

  test(
    'WC-16: lookupNamespaced throws ArgumentError for invalid args',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioWaveformCache.lookupNamespaced(
          namespace: '',
          assetKey: 'ak1',
          samplesPerSecond: 100,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGAudioWaveformCache.lookupNamespaced(
          namespace: 'ns1',
          assetKey: '',
          samplesPerSecond: 100,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGAudioWaveformCache.lookupNamespaced(
          namespace: 'ns1',
          assetKey: 'ak1',
          samplesPerSecond: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('WC-17: saveNamespaced returns saved outcome', () async {
    setHandler((call) async {
      if (call.method == 'waveformCache_lookupNamespaced') {
        return {'status': 'miss', 'writeLease': 'valid.token'};
      }
      if (call.method == 'waveformCache_saveNamespaced') {
        return {'status': 'saved'};
      }
      return null;
    });

    final lookup =
        await VGAudioWaveformCache.lookupNamespaced(
              namespace: 'ns1',
              assetKey: 'ak1',
              samplesPerSecond: 100,
            )
            as VGAudioWaveformLookupMiss;

    final outcome = await VGAudioWaveformCache.saveNamespaced(
      lease: lookup.lease,
      result: makeResult(pointCount: 2, duration: 1.0, sps: 100),
    );

    expect(outcome, equals(VGAudioWaveformSaveOutcome.saved));
  });

  test('WC-18: saveNamespaced returns stale outcome', () async {
    setHandler((call) async {
      if (call.method == 'waveformCache_lookupNamespaced') {
        return {'status': 'miss', 'writeLease': 'stale.token'};
      }
      if (call.method == 'waveformCache_saveNamespaced') {
        return {'status': 'stale'};
      }
      return null;
    });

    final lookup =
        await VGAudioWaveformCache.lookupNamespaced(
              namespace: 'ns1',
              assetKey: 'ak1',
              samplesPerSecond: 100,
            )
            as VGAudioWaveformLookupMiss;

    final outcome = await VGAudioWaveformCache.saveNamespaced(
      lease: lookup.lease,
      result: makeResult(pointCount: 2, duration: 1.0, sps: 100),
    );

    expect(outcome, equals(VGAudioWaveformSaveOutcome.stale));
  });

  test(
    'WC-19: saveNamespaced throws ArgumentError for invalid result metadata',
    () async {
      setHandler((call) async {
        if (call.method == 'waveformCache_lookupNamespaced') {
          return {'status': 'miss', 'writeLease': 'tok'};
        }
        return null;
      });

      final lookup =
          await VGAudioWaveformCache.lookupNamespaced(
                namespace: 'ns1',
                assetKey: 'ak1',
                samplesPerSecond: 100,
              )
              as VGAudioWaveformLookupMiss;

      expect(
        () => VGAudioWaveformCache.saveNamespaced(
          lease: lookup.lease,
          result: makeResult(duration: 0.0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('WC-20: invalidateAsset sends waveformCache_invalidateAsset', () async {
    setHandler((call) async => null);

    await VGAudioWaveformCache.invalidateAsset(
      namespace: 'ns1',
      assetKey: 'ak1',
    );

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'waveformCache_invalidateAsset');
    final args = capturedCalls.first.arguments as Map;
    expect(args['namespace'], 'ns1');
    expect(args['assetKey'], 'ak1');
  });

  test(
    'WC-21: invalidateNamespace sends waveformCache_invalidateNamespace',
    () async {
      setHandler((call) async => null);

      await VGAudioWaveformCache.invalidateNamespace(namespace: 'ns1');

      expect(capturedCalls.length, 1);
      expect(capturedCalls.first.method, 'waveformCache_invalidateNamespace');
      final args = capturedCalls.first.arguments as Map;
      expect(args['namespace'], 'ns1');
    },
  );

  test(
    'WC-22: invalidation methods throw ArgumentError on empty identifiers',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioWaveformCache.invalidateAsset(
          namespace: '',
          assetKey: 'ak1',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGAudioWaveformCache.invalidateAsset(
          namespace: 'ns1',
          assetKey: '',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGAudioWaveformCache.invalidateNamespace(namespace: ''),
        throwsA(isA<ArgumentError>()),
      );
    },
  );
}
