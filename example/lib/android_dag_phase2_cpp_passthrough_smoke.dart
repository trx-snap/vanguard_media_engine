// Android DAG Phase 2: C++ PassthroughRemuxSinkNode verification physical smoke.
//
// Dart responsibilities:
//   - Copy assets/manual_test_clips/clip_B.mov from rootBundle to a unique temp file
//     using only Dart SDK APIs.
//   - Include a 60s timeout that prints FAIL and exits 1.
//   - Invoke MethodChannel 'vanguard_media_engine' method
//     'runAndroidDagPhase2CppPassthroughSmoke' with sourcePath and outputDir.
//   - Validate returned map:
//     * pass == true
//     * native direct raw includes status=PASS
//     * native ineligible raw includes status=FAIL;reason=not_direct_path
//     * remuxExecutedAfterNativePass == true
//     * ineligibleRemuxExecuted == false
//     * videoSamples > 0
//     * audioSamples > 0
//     * outputSizeBytes > 0
//     * video/audio integrity maps have pass == true
//   - Print exactly ANDROID_DAG_PHASE2_CPP_PASSTHROUGH_JSON:<json>
//   - Print ANDROID_DAG_PHASE2_CPP_PASSTHROUGH_PHYSICAL_SMOKE_PASS or FAIL
//   - Update visible status, cancel timer, wait ~300ms, then exit(pass ? 0 : 1)
//   - Delete only copied temp source in finally.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase2CppPassthroughSmokeApp());
}

class AndroidDagPhase2CppPassthroughSmokeApp extends StatefulWidget {
  const AndroidDagPhase2CppPassthroughSmokeApp({super.key});

  @override
  State<AndroidDagPhase2CppPassthroughSmokeApp> createState() =>
      _AndroidDagPhase2CppPassthroughSmokeAppState();
}

class _AndroidDagPhase2CppPassthroughSmokeAppState
    extends State<AndroidDagPhase2CppPassthroughSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 2 C++ passthrough smoke…';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 60), () {
      print('ANDROID_DAG_PHASE2_CPP_PASSTHROUGH: TIMEOUT (60s exceeded)');
      print('ANDROID_DAG_PHASE2_CPP_PASSTHROUGH_PHYSICAL_SMOKE_FAIL');
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
      final clipBData =
          await rootBundle.load('assets/manual_test_clips/clip_B.mov');
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile =
          File('${tempDir.path}/p2_cpp_passthrough_source_$timestamp.mov');

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2CppPassthroughSmoke',
        <String, Object>{
          'sourcePath': tempSourceFile.path,
          'outputDir': tempDir.path,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_DAG_PHASE2_CPP_PASSTHROUGH_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'proofBoundary':
            'native_passthrough_remux_sink_node_validation_and_real_remux_sample_integrity',
        'nativeDirectRaw': 'status=FAIL;reason=dart_exception;$error',
        'nativeDirectDestroyRaw': 'status=FAIL;reason=dart_exception;$error',
        'nativeIneligibleRaw': 'status=FAIL;reason=dart_exception;$error',
        'nativeIneligibleDestroyRaw': 'status=FAIL;reason=dart_exception;$error',
        'remuxExecutedAfterNativePass': false,
        'ineligibleRemuxExecuted': false,
        'remuxSuccess': false,
        'remuxReason': 'dart_exception;$error',
        'videoSamples': 0,
        'audioSamples': 0,
        'outputSizeBytes': 0,
        'videoIntegrity': null,
        'audioIntegrity': null,
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
    final nativeDirectRaw = payload['nativeDirectRaw'] as String? ?? '';
    final nativeIneligibleRaw = payload['nativeIneligibleRaw'] as String? ?? '';
    final remuxExecutedAfterNativePass =
        payload['remuxExecutedAfterNativePass'] == true;
    final ineligibleRemuxExecuted =
        payload['ineligibleRemuxExecuted'] == false;
    final videoSamples = (payload['videoSamples'] as num?)?.toInt() ?? 0;
    final audioSamples = (payload['audioSamples'] as num?)?.toInt() ?? 0;
    final outputSizeBytes = (payload['outputSizeBytes'] as num?)?.toInt() ?? 0;

    final videoIntegrity = payload['videoIntegrity'] as Map?;
    final audioIntegrity = payload['audioIntegrity'] as Map?;
    final videoIntegrityPass = videoIntegrity?['pass'] == true;
    final audioIntegrityPass = audioIntegrity?['pass'] == true;

    final nativeDirectPass = nativeDirectRaw.contains('status=PASS');
    final nativeIneligiblePass =
        nativeIneligibleRaw.contains('status=FAIL;reason=not_direct_path');

    final pass = passBool &&
        nativeDirectPass &&
        nativeIneligiblePass &&
        remuxExecutedAfterNativePass &&
        ineligibleRemuxExecuted &&
        videoSamples > 0 &&
        audioSamples > 0 &&
        outputSizeBytes > 0 &&
        videoIntegrityPass &&
        audioIntegrityPass;

    print('ANDROID_DAG_PHASE2_CPP_PASSTHROUGH_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE2_CPP_PASSTHROUGH_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE2_CPP_PASSTHROUGH_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${payload['remuxReason']}';
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
            child: Text(
              _status,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
