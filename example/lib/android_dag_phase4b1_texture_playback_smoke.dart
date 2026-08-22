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
//
// Phase 4B2C rotation correction:
//   - The native session now returns displayWidth/displayHeight (post-rotation).
//   - The Texture widget is sized to a compact box that preserves that aspect
//     ratio (max 320 px on longest edge), so portrait-rotated clips render in a
//     portrait box instead of the old hardcoded 320×240 landscape box.

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

  /// Display dimensions from the native session (post-rotation).
  int _displayWidth = 320;
  int _displayHeight = 240;

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

      // Capture display dimensions returned by the native session so the
      // Texture widget respects the post-rotation aspect ratio.
      final startDw = (startMap['displayWidth'] as num?)?.toInt();
      final startDh = (startMap['displayHeight'] as num?)?.toInt();
      if (startDw != null && startDw > 0 && startDh != null && startDh > 0) {
        if (mounted) {
          setState(() {
            _displayWidth = startDw;
            _displayHeight = startDh;
          });
        }
      }

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

    // Update display dimensions from the final result map if available.
    final dw = (payload['displayWidth'] as num?)?.toInt();
    final dh = (payload['displayHeight'] as num?)?.toInt();
    if (dw != null && dw > 0 && dh != null && dh > 0) {
      _displayWidth = dw;
      _displayHeight = dh;
    }

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

  /// Returns a [Size] that fits [displayWidth]×[displayHeight] within a
  /// [maxLongestEdge]-px bounding box while preserving the aspect ratio.
  Size _constrainedSize({double maxLongestEdge = 320}) {
    final w = _displayWidth.toDouble();
    final h = _displayHeight.toDouble();
    if (w <= 0 || h <= 0) return const Size(320, 240);
    final scale = maxLongestEdge / (w > h ? w : h);
    return Size(w * scale, h * scale);
  }

  @override
  Widget build(BuildContext context) {
    final textureSize = _constrainedSize();
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_textureId != null)
                SizedBox(
                  width: textureSize.width,
                  height: textureSize.height,
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
