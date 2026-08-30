// Android DAG Phase 2: DecodedAudioPcmSourceNode audio decode bridge verification physical smoke.
//
// Dart responsibilities:
//   - Copy assets/manual_test_clips/clip_B.mov from rootBundle to a unique temp file
//     using only Dart SDK APIs.
//   - Include a 60s timeout that prints FAIL and exits 1.
//   - Invoke MethodChannel 'vanguard_media_engine' method
//     'runAndroidDagPhase2AudioDecodeBridgeSmoke' with sourcePath and durationSec: 1.0.
//   - Validate returned map:
//     * pass == true
//     * proofBoundary == 'native_decoded_pcm_audio_source_bridge_validation_no_mixbus_no_export_route'
//     * decodeSampleRate > 0
//     * decodeChannelCount in 1..2
//     * decodeFrameCount > 0
//     * positiveCreateRaw starts with status=PASS
//     * positiveLastIngestRaw contains status=PASS and isEndOfStream=true
//     * positiveValidateRaw starts with status=PASS
//     * positiveDestroyRaw starts with status=PASS
//     * negativeCreateRaw starts with status=PASS
//     * negativeValidateRaw contains status=FAIL;reason=expected_frame_count_mismatch
//     * negativeDestroyRaw starts with status=PASS
//     * nonClaims: productionMixdownRoute, audioMixBus, exportRoute, appWiring, iOS, mediaCodecInCpp all false
//   - Print exactly ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE_JSON:<json>
//   - Print ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE_PHYSICAL_SMOKE_PASS or FAIL
//   - Update visible status, cancel timer, wait ~300ms, then exit(pass ? 0 : 1)
//   - Delete only copied temp source in finally.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase2AudioDecodeBridgeSmokeApp());
}

class AndroidDagPhase2AudioDecodeBridgeSmokeApp extends StatefulWidget {
  const AndroidDagPhase2AudioDecodeBridgeSmokeApp({super.key});

  @override
  State<AndroidDagPhase2AudioDecodeBridgeSmokeApp> createState() =>
      _AndroidDagPhase2AudioDecodeBridgeSmokeAppState();
}

class _AndroidDagPhase2AudioDecodeBridgeSmokeAppState
    extends State<AndroidDagPhase2AudioDecodeBridgeSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 2 audio decode bridge smoke…';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 60), () {
      print('ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE: TIMEOUT (60s exceeded)');
      print('ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE_PHYSICAL_SMOKE_FAIL');
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

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p2_audio_decode_bridge_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2AudioDecodeBridgeSmoke',
        <String, Object>{'sourcePath': tempSourceFile.path, 'durationSec': 1.0},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'proofBoundary':
            'native_decoded_pcm_audio_source_bridge_validation_no_mixbus_no_export_route',
        'decodeSampleRate': 0,
        'decodeChannelCount': 0,
        'decodeFrameCount': 0,
        'positiveCreateRaw': 'status=FAIL;reason=dart_exception;$error',
        'positiveLastIngestRaw': 'status=FAIL;reason=dart_exception;$error',
        'positiveValidateRaw': 'status=FAIL;reason=dart_exception;$error',
        'positiveDestroyRaw': 'status=FAIL;reason=dart_exception;$error',
        'negativeCreateRaw': 'status=FAIL;reason=dart_exception;$error',
        'negativeValidateRaw': 'status=FAIL;reason=dart_exception;$error',
        'negativeDestroyRaw': 'status=FAIL;reason=dart_exception;$error',
        'nonClaims': <String, bool>{
          'productionMixdownRoute': false,
          'audioMixBus': false,
          'exportRoute': false,
          'appWiring': false,
          'iOS': false,
          'mediaCodecInCpp': false,
        },
      };
    } finally {
      if (tempSourceFile != null) {
        try {
          if (await tempSourceFile.exists()) {
            await tempSourceFile.delete();
          }
        } catch (_) {}
      }
    }

    final passBool = payload['pass'] == true;
    final proofBoundary = payload['proofBoundary'] as String? ?? '';
    final proofBoundaryPass =
        proofBoundary ==
        'native_decoded_pcm_audio_source_bridge_validation_no_mixbus_no_export_route';

    final decodeSampleRate =
        (payload['decodeSampleRate'] as num?)?.toInt() ?? 0;
    final decodeChannelCount =
        (payload['decodeChannelCount'] as num?)?.toInt() ?? 0;
    final decodeFrameCount =
        (payload['decodeFrameCount'] as num?)?.toInt() ?? 0;

    final positiveCreateRaw = payload['positiveCreateRaw'] as String? ?? '';
    final positiveLastIngestRaw =
        payload['positiveLastIngestRaw'] as String? ?? '';
    final positiveValidateRaw = payload['positiveValidateRaw'] as String? ?? '';
    final positiveDestroyRaw = payload['positiveDestroyRaw'] as String? ?? '';

    final negativeCreateRaw = payload['negativeCreateRaw'] as String? ?? '';
    final negativeValidateRaw = payload['negativeValidateRaw'] as String? ?? '';
    final negativeDestroyRaw = payload['negativeDestroyRaw'] as String? ?? '';

    final nonClaims = payload['nonClaims'] as Map? ?? {};
    final nonClaimsPass =
        nonClaims['productionMixdownRoute'] == false &&
        nonClaims['audioMixBus'] == false &&
        nonClaims['exportRoute'] == false &&
        nonClaims['appWiring'] == false &&
        nonClaims['iOS'] == false &&
        nonClaims['mediaCodecInCpp'] == false;

    final positiveCreatePass = positiveCreateRaw.startsWith('status=PASS');
    final positiveIngestPass =
        positiveLastIngestRaw.contains('status=PASS') &&
        positiveLastIngestRaw.contains('isEndOfStream=true');
    final positiveValidatePass = positiveValidateRaw.startsWith('status=PASS');
    final positiveDestroyPass = positiveDestroyRaw.startsWith('status=PASS');

    final negativeCreatePass = negativeCreateRaw.startsWith('status=PASS');
    final negativeValidatePass = negativeValidateRaw.contains(
      'status=FAIL;reason=expected_frame_count_mismatch',
    );
    final negativeDestroyPass = negativeDestroyRaw.startsWith('status=PASS');

    final pass =
        passBool &&
        proofBoundaryPass &&
        decodeSampleRate > 0 &&
        (decodeChannelCount >= 1 && decodeChannelCount <= 2) &&
        decodeFrameCount > 0 &&
        positiveCreatePass &&
        positiveIngestPass &&
        positiveValidatePass &&
        positiveDestroyPass &&
        negativeCreatePass &&
        negativeValidatePass &&
        negativeDestroyPass &&
        nonClaimsPass;

    print('ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE2_AUDIO_DECODE_BRIDGE_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
