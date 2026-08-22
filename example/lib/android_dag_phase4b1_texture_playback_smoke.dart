// Vanguard Android True-DAG Phase 4B1A: Texture playback smoke.
//
// Route:
//   MediaExtractor/MediaCodec -> ImageReader/HardwareBuffer ->
//   native DAG evaluation -> VulkanBackend render ->
//   Flutter TextureRegistry texture.
//
// Dart responsibilities:
//   - Copy assets/manual_test_clips/clip_B.mov to a temporary file.
//   - Invoke runAndroidDagPhase4B1TexturePlaybackSmoke with frameCount=12.
//   - Display Texture(textureId) if present in response.
//   - Print ANDROID_DAG_PHASE4B1A_JSON:<json> and PASS only if pass == true
//     and renderedFrames == 12.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4B1TexturePlaybackSmokeApp());
}

class AndroidDagPhase4B1TexturePlaybackSmokeApp extends StatefulWidget {
  const AndroidDagPhase4B1TexturePlaybackSmokeApp({super.key});

  @override
  State<AndroidDagPhase4B1TexturePlaybackSmokeApp> createState() =>
      _AndroidDagPhase4B1TexturePlaybackSmokeAppState();
}

class _AndroidDagPhase4B1TexturePlaybackSmokeAppState
    extends State<AndroidDagPhase4B1TexturePlaybackSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 4B1A texture playback smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    File? tempFile;
    int? activeTextureId;
    Map<String, dynamic> payload;

    final completer = Completer<Map<String, dynamic>>();

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAndroidDagPhase4B1TexturePlaybackSmokeComplete') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (!completer.isCompleted) {
          completer.complete(args);
        }
      }
    });

    try {
      final clipBytes =
          await rootBundle.load('assets/manual_test_clips/clip_B.mov');
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/phase4b1a_clip_b_smoke.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final startResponse = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4B1TexturePlaybackSmoke',
        <String, Object>{
          'path': tempFile.path,
          'frameCount': 12,
        },
      );

      final startMap = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startMap['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Playing Android DAG Phase 4B1A texture smoke (textureId=$activeTextureId)…';
        });
      }

      payload = await completer.future;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B1A_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception;renderedFrames=0;frameCount=12',
        'width': 0,
        'height': 0,
        'frameCount': 12,
        'renderedFrames': 0,
      };
    }

    final pass = payload['pass'] == true && payload['renderedFrames'] == 12;
    final textureId =
        (payload['textureId'] as num?)?.toInt() ?? activeTextureId;

    // ignore: avoid_print
    print('ANDROID_DAG_PHASE4B1A_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4B1A_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4B1A_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _textureId = textureId;
        _status = pass ? 'PASS' : 'FAIL: ${payload['raw']}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));

    if (textureId != null) {
      try {
        await _channel.invokeMethod<Object?>(
          'disposeAndroidDagPhase4B1TexturePlaybackSmoke',
          <String, Object>{'textureId': textureId},
        );
      } catch (_) {}
    }

    try {
      await tempFile?.delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_textureId != null)
                SizedBox(
                  width: 320,
                  height: 240,
                  child: Texture(textureId: _textureId!),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
