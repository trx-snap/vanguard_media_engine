// Phase 5: Android MediaCodec encoder input surface smoke.
//
// Native DAG/Vulkan rendering presents into MediaCodec input surface ->
// deterministic CFR H.264 MP4 through MediaMuxer.
//
// Dart responsibilities:
//   - Create a unique output path under Directory.systemTemp.
//   - Invoke MethodChannel('vanguard_media_engine').invokeMethod(
//       'runAndroidDagPhase5EncoderSurfaceSmoke',
//       {
//         'width': 64,
//         'height': 64,
//         'frameCount': 10,
//         'frameDurationUs': 33333,
//         'bitrate': 1000000,
//         'outputPath': outputPath,
//       }
//     )
//   - Print ANDROID_DAG_PHASE5_ENCODER_SURFACE_JSON:<json>
//   - Print ANDROID_DAG_PHASE5_ENCODER_SURFACE_PHYSICAL_SMOKE_PASS or ..._FAIL
//   - Preserve output on pass for inspection, include outputPath/outputSize in UI/status
//   - Best-effort delete on fail

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase5EncoderSurfaceSmokeApp());
}

class AndroidDagPhase5EncoderSurfaceSmokeApp extends StatefulWidget {
  const AndroidDagPhase5EncoderSurfaceSmokeApp({super.key});

  @override
  State<AndroidDagPhase5EncoderSurfaceSmokeApp> createState() =>
      _AndroidDagPhase5EncoderSurfaceSmokeAppState();
}

class _AndroidDagPhase5EncoderSurfaceSmokeAppState
    extends State<AndroidDagPhase5EncoderSurfaceSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 5 encoder-surface smoke…';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '${tempDir.path}/phase5_encoder_smoke_$timestamp.mp4';

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase5EncoderSurfaceSmoke',
        <String, Object>{
          'width': 64,
          'height': 64,
          'frameCount': 10,
          'frameDurationUs': 33333,
          'bitrate': 1000000,
          'outputPath': outputPath,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE5_ENCODER_SURFACE_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception;detail=$error',
        'width': 64,
        'height': 64,
        'frameCount': 10,
        'encodedFrames': 0,
        'frameDurationUs': 33333,
        'outputPath': outputPath,
        'outputSize': 0,
      };
    }

    final pass = payload['pass'] == true;
    final outputSize = (payload['outputSize'] as num?)?.toInt() ?? 0;
    final reportedPath = payload['outputPath'] as String? ?? outputPath;

    // Clean up partial output file on failure if still lingering.
    if (!pass) {
      try {
        final f = File(outputPath);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }

    // ignore: avoid_print
    print('ANDROID_DAG_PHASE5_ENCODER_SURFACE_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE5_ENCODER_SURFACE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE5_ENCODER_SURFACE_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status = 'PASS\nPath: $reportedPath\nSize: $outputSize bytes';
        } else {
          _status = 'FAIL: ${payload['raw']}';
        }
      });
    }
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
