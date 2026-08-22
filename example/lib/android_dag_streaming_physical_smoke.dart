// Vanguard Android True-DAG Phase 4C1D1C: Physical HLS streaming smoke test.
//
// Route:
//   HttpAdaptivePlaybackAdapter (Media3 ExoPlayer) ->
//   HttpAdaptiveImageReaderBridge -> HardwareBuffer ->
//   native DAG generation-aware evaluation -> Vulkan render ->
//   Flutter TextureRegistry SurfaceProducer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String _streamUrl = String.fromEnvironment(
  'STREAM_URL',
  defaultValue: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
);

const String _streamFormat = String.fromEnvironment(
  'STREAM_FORMAT',
  defaultValue: 'HLS',
);

const int _initialWidth = int.fromEnvironment(
  'INITIAL_WIDTH',
  defaultValue: 640,
);

const int _initialHeight = int.fromEnvironment(
  'INITIAL_HEIGHT',
  defaultValue: 360,
);

const int _waitSeconds = int.fromEnvironment('WAIT_SECONDS', defaultValue: 12);

void main() {
  runApp(const AndroidDagStreamingPhysicalSmokeApp());
}

class AndroidDagStreamingPhysicalSmokeApp extends StatefulWidget {
  const AndroidDagStreamingPhysicalSmokeApp({super.key});

  @override
  State<AndroidDagStreamingPhysicalSmokeApp> createState() =>
      _AndroidDagStreamingPhysicalSmokeAppState();
}

class _AndroidDagStreamingPhysicalSmokeAppState
    extends State<AndroidDagStreamingPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android DAG streaming smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    int? activeTextureId;
    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      // 1. Create streaming playback session
      final createResponse = await _channel.invokeMethod<Object?>(
        'createAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object>{
          'uri': _streamUrl,
          'formatHint': _streamFormat,
          'initialWidth': _initialWidth,
          'initialHeight': _initialHeight,
          'autoPlay': true,
        },
      );

      if (createResponse == null || createResponse is! Map) {
        throw Exception(
          'createAndroidDagPhase4C1D1StreamingPlayback returned invalid response: $createResponse',
        );
      }

      final createMap = Map<String, dynamic>.from(createResponse);
      final createPass = createMap['pass'] == true;
      activeTextureId = (createMap['textureId'] as num?)?.toInt();
      diagMap = createMap;

      // 2. If create fails or no textureId: log fail and exit nonzero after cleanup
      if (!createPass || activeTextureId == null || activeTextureId < 0) {
        throw Exception(
          'Create streaming playback failed: ${createMap['raw']} (textureId: $activeTextureId)',
        );
      }

      // 3. Show Texture(textureId: textureId)
      if (mounted) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Streaming playback active (textureId=$activeTextureId), waiting ${_waitSeconds}s…';
        });
      }

      // 4. Wait WAIT_SECONDS
      await Future<void>.delayed(Duration(seconds: _waitSeconds));

      // 5. Diagnose
      final diagResponse = await _channel.invokeMethod<Object?>(
        'diagnoseAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object>{'textureId': activeTextureId},
      );

      if (diagResponse != null && diagResponse is Map) {
        diagMap = Map<String, dynamic>.from(diagResponse);
      } else {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=diagnose_null_response',
          'renderedFrames': 0,
        };
      }

      final renderedFrames = (diagMap['renderedFrames'] as num?)?.toInt() ?? 0;
      final diagPass = diagMap['pass'] != false;
      final surfaceLost = diagMap['surfaceLost'] == true;
      final state = diagMap['state'] as String? ?? '';

      // 6. Pass if renderedFrames > 0, pass != false, surfaceLost != true, state is not Failed
      pass =
          renderedFrames > 0 && diagPass && !surfaceLost && state != 'Failed';
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_STREAMING_PHYSICAL_ERROR: $error\n$stack');
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
          'renderedFrames': 0,
        };
      }
      pass = false;
    } finally {
      // 7. Always dispose if textureId exists
      if (activeTextureId != null && activeTextureId >= 0) {
        try {
          await _channel.invokeMethod<Object?>(
            'disposeAndroidDagPhase4C1D1StreamingPlayback',
            <String, Object>{'textureId': activeTextureId},
          );
        } catch (e) {
          // ignore: avoid_print
          print('Dispose error: $e');
        }
      }
    }

    // 8. Print terminal marker with diagnostic map
    // ignore: avoid_print
    print('ANDROID_DAG_STREAMING_PHYSICAL_JSON:${jsonEncode(diagMap)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_STREAMING_PHYSICAL_PASS'
          : 'ANDROID_DAG_STREAMING_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (frames: ${diagMap['renderedFrames']})'
            : 'FAIL: ${diagMap['raw']}';
      });
    }

    // 9. Exit process after marker so flutter run can finish unattended
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_textureId != null)
                SizedBox(
                  width: 320,
                  height: 180,
                  child: Texture(textureId: _textureId!),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
