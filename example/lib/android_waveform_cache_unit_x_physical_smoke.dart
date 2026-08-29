// android_waveform_cache_unit_x_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit X / Phase 4-Unit F
// Android Waveform Disk Cache Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidWaveformCacheUnitXPhysicalSmokeApp());
}

class AndroidWaveformCacheUnitXPhysicalSmokeApp extends StatefulWidget {
  const AndroidWaveformCacheUnitXPhysicalSmokeApp({super.key});

  @override
  State<AndroidWaveformCacheUnitXPhysicalSmokeApp> createState() =>
      _AndroidWaveformCacheUnitXPhysicalSmokeAppState();
}

class _AndroidWaveformCacheUnitXPhysicalSmokeAppState
    extends State<AndroidWaveformCacheUnitXPhysicalSmokeApp> {
  String _status =
      'Initializing Android Waveform Cache Physical Smoke (Unit X)...';
  Timer? _timeoutTimer;

  static const MethodChannel _rawChannel = MethodChannel(
    'vanguard_media_engine',
  );

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_WAVEFORM_CACHE_UNIT_X: TIMEOUT (90s exceeded)');
      print('ANDROID_WAVEFORM_CACHE_UNIT_X_PHYSICAL_FAIL');
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  VGAudioWaveformResult _makeResult({
    int pointCount = 8,
    double duration = 4.0,
    int sps = 100,
  }) {
    final samples = Float32List.fromList(
      List.generate(pointCount, (i) => 0.05 * (i + 1)),
    );
    return VGAudioWaveformResult(
      samples: samples,
      durationSeconds: duration,
      samplesPerSecond: sps,
      pointCount: pointCount,
    );
  }

  bool _waveformEquals(VGAudioWaveformResult? a, VGAudioWaveformResult? b) {
    if (a == null || b == null) return false;
    if ((a.durationSeconds - b.durationSeconds).abs() > 0.001) return false;
    if (a.samplesPerSecond != b.samplesPerSecond) return false;
    if (a.pointCount != b.pointCount) return false;
    if (a.samples.length != b.samples.length) return false;
    for (var i = 0; i < a.samples.length; i++) {
      if ((a.samples[i] - b.samples[i]).abs() > 0.0001) return false;
    }
    return true;
  }

  Future<void> _runSmoke() async {
    print('ANDROID_WAVEFORM_CACHE_UNIT_X: START');
    final runId = 'unit_x_${DateTime.now().millisecondsSinceEpoch}';

    var laneAPass = false;
    var laneBPass = false;
    var laneCPass = false;
    var laneDPass = false;
    var laneEPass = false;
    var laneFPass = false;
    var laneGPass = false;
    var laneHPass = false;

    Map<String, dynamic> laneAMap = <String, dynamic>{};
    Map<String, dynamic> laneBMap = <String, dynamic>{};
    Map<String, dynamic> laneCMap = <String, dynamic>{};
    Map<String, dynamic> laneDMap = <String, dynamic>{};
    Map<String, dynamic> laneEMap = <String, dynamic>{};
    Map<String, dynamic> laneFMap = <String, dynamic>{};
    Map<String, dynamic> laneGMap = <String, dynamic>{};
    Map<String, dynamic> laneHMap = <String, dynamic>{};

    String? topLevelError;

    try {
      // ── Lane A: Legacy public save/load round-trip ──────────────────────────
      print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_A: START (legacy save/load)');
      try {
        final legacyKey = '${runId}_legacy_key';
        final initialLoad = await VGAudioWaveformCache.load(
          cacheKey: legacyKey,
        );
        final initialNull = initialLoad == null;

        final testResultA = _makeResult(pointCount: 6, duration: 3.0, sps: 50);
        await VGAudioWaveformCache.save(
          cacheKey: legacyKey,
          result: testResultA,
        );

        final loadedA = await VGAudioWaveformCache.load(cacheKey: legacyKey);
        final matches = _waveformEquals(loadedA, testResultA);

        laneAPass = initialNull && matches;
        laneAMap = <String, dynamic>{
          'pass': laneAPass,
          'initialNull': initialNull,
          'matches': matches,
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_A: DONE (pass=$laneAPass, initialNull=$initialNull, matches=$matches)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_A: ERROR: $e\n$st');
        laneAMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneAPass = false;
      }

      // ── Lane B: Namespaced public lookup miss -> save -> hit ────────────────
      print(
        'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_B: START (namespaced miss -> save -> hit)',
      );
      try {
        final nsB = '${runId}_ns_b';
        final akB = '${runId}_ak_b';
        final testResultB = _makeResult(pointCount: 8, duration: 4.0, sps: 100);

        final lookup1 = await VGAudioWaveformCache.lookupNamespaced(
          namespace: nsB,
          assetKey: akB,
          samplesPerSecond: 100,
        );
        final isMiss1 = lookup1 is VGAudioWaveformLookupMiss;

        var saveOutcomeB = VGAudioWaveformSaveOutcome.stale;
        if (isMiss1) {
          saveOutcomeB = await VGAudioWaveformCache.saveNamespaced(
            lease: lookup1.lease,
            result: testResultB,
          );
        }

        final lookup2 = await VGAudioWaveformCache.lookupNamespaced(
          namespace: nsB,
          assetKey: akB,
          samplesPerSecond: 100,
        );
        final isHit2 = lookup2 is VGAudioWaveformLookupHit;
        final hitMatches =
            isHit2 && _waveformEquals(lookup2.cached, testResultB);

        laneBPass =
            isMiss1 &&
            saveOutcomeB == VGAudioWaveformSaveOutcome.saved &&
            hitMatches;
        laneBMap = <String, dynamic>{
          'pass': laneBPass,
          'isMiss1': isMiss1,
          'saveOutcome': saveOutcomeB.name,
          'isHit2': isHit2,
          'hitMatches': hitMatches,
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_B: DONE (pass=$laneBPass, saveOutcome=${saveOutcomeB.name}, hitMatches=$hitMatches)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_B: ERROR: $e\n$st');
        laneBMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneBPass = false;
      }

      // ── Lane C: Write lease not one-time consumed (saves twice) ─────────────
      print(
        'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_C: START (lease reusable before invalidation)',
      );
      try {
        final nsC = '${runId}_ns_c';
        final akC = '${runId}_ak_c';
        final testResultC = _makeResult(pointCount: 4, duration: 2.0, sps: 100);

        final lookupC = await VGAudioWaveformCache.lookupNamespaced(
          namespace: nsC,
          assetKey: akC,
          samplesPerSecond: 100,
        );
        final isMissC = lookupC is VGAudioWaveformLookupMiss;

        var save1Outcome = VGAudioWaveformSaveOutcome.stale;
        var save2Outcome = VGAudioWaveformSaveOutcome.stale;
        if (isMissC) {
          save1Outcome = await VGAudioWaveformCache.saveNamespaced(
            lease: lookupC.lease,
            result: testResultC,
          );
          save2Outcome = await VGAudioWaveformCache.saveNamespaced(
            lease: lookupC.lease,
            result: testResultC,
          );
        }

        laneCPass =
            isMissC &&
            save1Outcome == VGAudioWaveformSaveOutcome.saved &&
            save2Outcome == VGAudioWaveformSaveOutcome.saved;
        laneCMap = <String, dynamic>{
          'pass': laneCPass,
          'isMiss': isMissC,
          'save1': save1Outcome.name,
          'save2': save2Outcome.name,
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_C: DONE (pass=$laneCPass, save1=${save1Outcome.name}, save2=${save2Outcome.name})',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_C: ERROR: $e\n$st');
        laneCMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneCPass = false;
      }

      // ── Lane D: Raw saveNamespaced SPS mismatch -> CACHE_LEASE_MISMATCH ─────
      print(
        'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_D: START (raw SPS lease mismatch error)',
      );
      try {
        final nsD = '${runId}_ns_d';
        final akD = '${runId}_ak_d';

        final rawLookup = await _rawChannel.invokeMapMethod<String, dynamic>(
          'waveformCache_lookupNamespaced',
          {'namespace': nsD, 'assetKey': akD, 'samplesPerSecond': 100},
        );
        final rawToken = rawLookup?['writeLease'] as String?;

        String? caughtErrorCode;
        final testResultD = _makeResult(pointCount: 4, duration: 2.0, sps: 200);
        final sampleBytesD = testResultD.samples.buffer.asUint8List(
          testResultD.samples.offsetInBytes,
          testResultD.samples.lengthInBytes,
        );

        try {
          await _rawChannel.invokeMapMethod<String, dynamic>(
            'waveformCache_saveNamespaced',
            {
              'token': rawToken,
              'samples': sampleBytesD,
              'durationSeconds': testResultD.durationSeconds,
              'samplesPerSecond': 200, // Token was minted for 100, passing 200
              'pointCount': testResultD.pointCount,
            },
          );
        } on PlatformException catch (pe) {
          caughtErrorCode = pe.code;
        }

        laneDPass = caughtErrorCode == 'CACHE_LEASE_MISMATCH';
        laneDMap = <String, dynamic>{
          'pass': laneDPass,
          'caughtCode': caughtErrorCode,
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_D: DONE (pass=$laneDPass, code=$caughtErrorCode)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_D: ERROR: $e\n$st');
        laneDMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneDPass = false;
      }

      // ── Lane E: Raw saveNamespaced tampered token -> CACHE_TOKEN_INVALID ────
      print(
        'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_E: START (raw tampered token error)',
      );
      try {
        String? caughtErrorCode;
        final testResultE = _makeResult(pointCount: 4, duration: 2.0, sps: 100);
        final sampleBytesE = testResultE.samples.buffer.asUint8List(
          testResultE.samples.offsetInBytes,
          testResultE.samples.lengthInBytes,
        );

        try {
          await _rawChannel.invokeMapMethod<String, dynamic>(
            'waveformCache_saveNamespaced',
            {
              'token': 'eyJ2IjoxLCJucyI6InRlc3QifQ.dGFtcGVyZWRzaWduYXR1cmU',
              'samples': sampleBytesE,
              'durationSeconds': testResultE.durationSeconds,
              'samplesPerSecond': 100,
              'pointCount': testResultE.pointCount,
            },
          );
        } on PlatformException catch (pe) {
          caughtErrorCode = pe.code;
        }

        laneEPass = caughtErrorCode == 'CACHE_TOKEN_INVALID';
        laneEMap = <String, dynamic>{
          'pass': laneEPass,
          'caughtCode': caughtErrorCode,
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_E: DONE (pass=$laneEPass, code=$caughtErrorCode)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_E: ERROR: $e\n$st');
        laneEMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneEPass = false;
      }

      // ── Lane F: invalidateAsset marks lease stale & next lookup misses ──────
      print(
        'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_F: START (invalidateAsset stale lease)',
      );
      try {
        final nsF = '${runId}_ns_f';
        final akF = '${runId}_ak_f';
        final testResultF = _makeResult(pointCount: 4, duration: 2.0, sps: 100);

        final lookupF1 = await VGAudioWaveformCache.lookupNamespaced(
          namespace: nsF,
          assetKey: akF,
          samplesPerSecond: 100,
        );
        final isMissF1 = lookupF1 is VGAudioWaveformLookupMiss;

        var staleOutcome = VGAudioWaveformSaveOutcome.saved;
        if (isMissF1) {
          // Invalidate asset before saving with lease
          await VGAudioWaveformCache.invalidateAsset(
            namespace: nsF,
            assetKey: akF,
          );
          staleOutcome = await VGAudioWaveformCache.saveNamespaced(
            lease: lookupF1.lease,
            result: testResultF,
          );
        }

        final lookupF2 = await VGAudioWaveformCache.lookupNamespaced(
          namespace: nsF,
          assetKey: akF,
          samplesPerSecond: 100,
        );
        final isMissF2 = lookupF2 is VGAudioWaveformLookupMiss;

        laneFPass =
            isMissF1 &&
            staleOutcome == VGAudioWaveformSaveOutcome.stale &&
            isMissF2;
        laneFMap = <String, dynamic>{
          'pass': laneFPass,
          'isMissF1': isMissF1,
          'staleOutcome': staleOutcome.name,
          'isMissF2': isMissF2,
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_F: DONE (pass=$laneFPass, outcome=${staleOutcome.name}, nextMiss=$isMissF2)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_F: ERROR: $e\n$st');
        laneFMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneFPass = false;
      }

      // ── Lane G: invalidateNamespace clears multiple assets ──────────────────
      print(
        'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_G: START (invalidateNamespace multiple assets)',
      );
      try {
        final nsG = '${runId}_ns_g';
        final akG1 = '${runId}_ak_g1';
        final akG2 = '${runId}_ak_g2';
        final akG3 = '${runId}_ak_g3';
        final testResultG = _makeResult(pointCount: 4, duration: 2.0, sps: 100);

        // Save asset 1
        final l1 =
            await VGAudioWaveformCache.lookupNamespaced(
                  namespace: nsG,
                  assetKey: akG1,
                  samplesPerSecond: 100,
                )
                as VGAudioWaveformLookupMiss;
        await VGAudioWaveformCache.saveNamespaced(
          lease: l1.lease,
          result: testResultG,
        );

        // Save asset 2
        final l2 =
            await VGAudioWaveformCache.lookupNamespaced(
                  namespace: nsG,
                  assetKey: akG2,
                  samplesPerSecond: 100,
                )
                as VGAudioWaveformLookupMiss;
        await VGAudioWaveformCache.saveNamespaced(
          lease: l2.lease,
          result: testResultG,
        );

        // Mint lease for asset 3 before invalidation
        final l3 =
            await VGAudioWaveformCache.lookupNamespaced(
                  namespace: nsG,
                  assetKey: akG3,
                  samplesPerSecond: 100,
                )
                as VGAudioWaveformLookupMiss;

        // Invalidate entire namespace
        await VGAudioWaveformCache.invalidateNamespace(namespace: nsG);

        // l3 lease should now be stale
        final staleOutcomeG = await VGAudioWaveformCache.saveNamespaced(
          lease: l3.lease,
          result: testResultG,
        );

        // asset 1 and asset 2 should now miss
        final postLookup1 = await VGAudioWaveformCache.lookupNamespaced(
          namespace: nsG,
          assetKey: akG1,
          samplesPerSecond: 100,
        );
        final postLookup2 = await VGAudioWaveformCache.lookupNamespaced(
          namespace: nsG,
          assetKey: akG2,
          samplesPerSecond: 100,
        );

        final g1Cleared = postLookup1 is VGAudioWaveformLookupMiss;
        final g2Cleared = postLookup2 is VGAudioWaveformLookupMiss;
        final isStale = staleOutcomeG == VGAudioWaveformSaveOutcome.stale;

        laneGPass = isStale && g1Cleared && g2Cleared;
        laneGMap = <String, dynamic>{
          'pass': laneGPass,
          'isStale': isStale,
          'g1Cleared': g1Cleared,
          'g2Cleared': g2Cleared,
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_G: DONE (pass=$laneGPass, isStale=$isStale, g1Cleared=$g1Cleared, g2Cleared=$g2Cleared)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_G: ERROR: $e\n$st');
        laneGMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneGPass = false;
      }

      // ── Lane H: Native diagnostic smoke route ───────────────────────────────
      print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_H: START (native smoke route)');
      try {
        final rawSmoke = await _rawChannel.invokeMapMethod<String, dynamic>(
          'runAndroidWaveformCacheUnitXSmoke',
        );

        final nativePass = rawSmoke?['pass'] == true;
        final phaseMatches = rawSmoke?['phase'] == 'Phase5UnitX';
        final cleanupPass = rawSmoke?['cleanupPass'] == true;

        laneHPass = nativePass && phaseMatches && cleanupPass;
        laneHMap = <String, dynamic>{
          'pass': laneHPass,
          'nativePass': nativePass,
          'phase': rawSmoke?['phase'],
          'cleanupPass': cleanupPass,
          'raw': rawSmoke?['raw'],
        };
        print(
          'ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_H: DONE (pass=$laneHPass, nativePass=$nativePass, cleanup=$cleanupPass, raw=${rawSmoke?['raw']})',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_H: ERROR: $e\n$st');
        laneHMap = <String, dynamic>{'pass': false, 'error': '$e'};
        laneHPass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_WAVEFORM_CACHE_UNIT_X: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    }

    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_A_PASS: $laneAPass');
    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_B_PASS: $laneBPass');
    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_C_PASS: $laneCPass');
    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_D_PASS: $laneDPass');
    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_E_PASS: $laneEPass');
    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_F_PASS: $laneFPass');
    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_G_PASS: $laneGPass');
    print('ANDROID_WAVEFORM_CACHE_UNIT_X_LANE_H_PASS: $laneHPass');

    final allRequiredPass =
        laneAPass &&
        laneBPass &&
        laneCPass &&
        laneDPass &&
        laneEPass &&
        laneFPass &&
        laneGPass &&
        laneHPass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitX_Phase4UnitF',
      'target': 'android_waveform_cache_physical',
      'pass': allRequiredPass,
      'lanes': <String, dynamic>{
        'laneA_legacy_round_trip': laneAMap,
        'laneB_namespaced_round_trip': laneBMap,
        'laneC_lease_reusable': laneCMap,
        'laneD_raw_sps_mismatch': laneDMap,
        'laneE_raw_tampered_token': laneEMap,
        'laneF_invalidate_asset_stale': laneFMap,
        'laneG_invalidate_namespace_multi': laneGMap,
        'laneH_native_diagnostic_smoke': laneHMap,
      },
      'error': topLevelError,
    };

    print('ANDROID_WAVEFORM_CACHE_UNIT_X_JSON:${jsonEncode(payload)}');
    print(
      allRequiredPass
          ? 'ANDROID_WAVEFORM_CACHE_UNIT_X_PHYSICAL_PASS'
          : 'ANDROID_WAVEFORM_CACHE_UNIT_X_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allRequiredPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(allRequiredPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
