// Phase 4A: MediaCodec decode → ImageReader → Image.getHardwareBuffer →
// native DAG evaluation → Vulkan render smoke.
//
// Dart responsibilities:
//   - Copy assets/manual_test_clips/clip_B.mov from rootBundle to a temp file
//     using only Dart SDK APIs (no path_provider, no file_picker).
//   - Invoke the MethodChannel with path + frameCount=10.
//   - Print ANDROID_DAG_PHASE4A_JSON:{...} and ANDROID_DAG_PHASE4A_PHYSICAL_SMOKE_PASS.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4ADecoderSmokeApp());
}

class AndroidDagPhase4ADecoderSmokeApp extends StatefulWidget {
  const AndroidDagPhase4ADecoderSmokeApp({super.key});

  @override
  State<AndroidDagPhase4ADecoderSmokeApp> createState() =>
      _AndroidDagPhase4ADecoderSmokeAppState();
}

class _AndroidDagPhase4ADecoderSmokeAppState
    extends State<AndroidDagPhase4ADecoderSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 4A decoder smoke…';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      // Copy the bundled clip to a temp file using only dart:io + dart:typed_data.
      final clipBytes =
          await rootBundle.load('assets/manual_test_clips/clip_B.mov');
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/phase4a_clip_b_smoke.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4ADecoderSmoke',
        <String, Object>{
          'path': tempFile.path,
          'frameCount': 10,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);

      // Best-effort temp file cleanup — ignore errors.
      try { await tempFile.delete(); } catch (_) {}
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4A_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;decoder=dart_exception;session=not_run;'
            'renderedFrames=0;frameCount=10;width=0;height=0',
        'width': 0,
        'height': 0,
        'frameCount': 10,
        'renderedFrames': 0,
      };
    }

    final pass = payload['pass'] == true;
    // ignore: avoid_print
    print('ANDROID_DAG_PHASE4A_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4A_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4A_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${payload['raw']}';
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
