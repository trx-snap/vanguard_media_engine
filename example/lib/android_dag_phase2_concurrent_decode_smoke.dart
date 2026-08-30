// Android DAG Phase 2: Concurrent hardware decode ingest validation physical smoke.
//
// Dart responsibilities:
//   - Copy assets/manual_test_clips/clip_A.mov and clip_B.mov from rootBundle to unique temp files
//     using only Dart SDK APIs (no path_provider, no file_picker).
//   - Invoke the MethodChannel 'vanguard_media_engine' method 'runAndroidDagPhase2ConcurrentDecodeSmoke'
//     with source IDs 'p2_source_a' and 'p2_source_b', frameCount 3 each.
//   - Print ANDROID_DAG_PHASE2_CONCURRENT_DECODE_JSON:<json>
//   - Print ANDROID_DAG_PHASE2_CONCURRENT_DECODE_PHYSICAL_SMOKE_PASS or FAIL
//   - Best-effort delete temp files in finally.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase2ConcurrentDecodeSmokeApp());
}

class AndroidDagPhase2ConcurrentDecodeSmokeApp extends StatefulWidget {
  const AndroidDagPhase2ConcurrentDecodeSmokeApp({super.key});

  @override
  State<AndroidDagPhase2ConcurrentDecodeSmokeApp> createState() =>
      _AndroidDagPhase2ConcurrentDecodeSmokeAppState();
}

class _AndroidDagPhase2ConcurrentDecodeSmokeAppState
    extends State<AndroidDagPhase2ConcurrentDecodeSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 2 concurrent decode smoke…';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    File? tempFileA;
    File? tempFileB;
    try {
      final clipAData =
          await rootBundle.load('assets/manual_test_clips/clip_A.mov');
      final clipBData =
          await rootBundle.load('assets/manual_test_clips/clip_B.mov');
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempFileA = File('${tempDir.path}/p2_concurrent_clip_a_$timestamp.mov');
      tempFileB = File('${tempDir.path}/p2_concurrent_clip_b_$timestamp.mov');

      await tempFileA.writeAsBytes(
        clipAData.buffer.asUint8List(
          clipAData.offsetInBytes,
          clipAData.lengthInBytes,
        ),
        flush: true,
      );
      await tempFileB.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2ConcurrentDecodeSmoke',
        <String, Object>{
          'streams': [
            {
              'sourceNodeId': 'p2_source_a',
              'path': tempFileA.path,
              'frameCount': 3,
            },
            {
              'sourceNodeId': 'p2_source_b',
              'path': tempFileB.path,
              'frameCount': 3,
            },
          ],
          'generationId': 1,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE2_CONCURRENT_DECODE_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception;$error',
        'streamCount': 0,
        'totalFramesIngested': 0,
      };
    } finally {
      // Best-effort temp file cleanup.
      if (tempFileA != null) {
        try {
          await tempFileA.delete();
        } catch (_) {}
      }
      if (tempFileB != null) {
        try {
          await tempFileB.delete();
        } catch (_) {}
      }
    }

    final passBool = payload['pass'] == true;
    final streamCount = (payload['streamCount'] as num?)?.toInt() ?? 0;
    final totalFrames =
        (payload['totalFramesIngested'] as num?)?.toInt() ?? 0;
    final framesBySource =
        payload['framesIngestedBySourceNodeId'] as Map?;
    final aFrames =
        (framesBySource?['p2_source_a'] as num?)?.toInt() ?? 0;
    final bFrames =
        (framesBySource?['p2_source_b'] as num?)?.toInt() ?? 0;
    final errors = payload['errorsBySourceNodeId'] as Map?;
    final noErrors = errors == null || errors.isEmpty;

    final pass = passBool &&
        streamCount == 2 &&
        totalFrames >= 6 &&
        aFrames >= 3 &&
        bFrames >= 3 &&
        noErrors;

    // ignore: avoid_print
    print('ANDROID_DAG_PHASE2_CONCURRENT_DECODE_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE2_CONCURRENT_DECODE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE2_CONCURRENT_DECODE_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${payload['raw']}';
      });
    }

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
