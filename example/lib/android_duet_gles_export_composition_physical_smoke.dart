// android_duet_gles_export_composition_physical_smoke.dart
// Vanguard Media Engine - Android Duet deterministic GLES export composition
// physical smoke: proves the production AndroidTimelineVideoEncoder
// GLES/MediaCodec export route can carry a pre-matted, alpha-varying RGBA
// overlay through to a produced MP4.
//
// Proof boundary:
//   android_duet_gles_export_composition_rgba_matte_overlay_mediacodec_mp4_only
//
// Non-claims (echoed by the native harness; also see its `nonClaims` field):
//   - No real ML human matte quality.
//   - No per-frame GL_LUMINANCE mask upload inside export (DEC-V2-105 covers
//     synthetic mask upload/blend separately).
//   - No live CameraX/OES preview lifecycle.
//   - No multi-track audio pass-2 mux or A/V sync.
//   - No ConnectsApp, Universal Editor UI, upload, share, caption, or backend
//     admission wiring.
//   - No GPU delegate/TFLite/MediaPipe production promotion.
//   - No low-end/budget Android proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kStartMarker = 'ANDROID_DUET_GLES_EXPORT_COMPOSITION_START';
const String kPassMarker = 'ANDROID_DUET_GLES_EXPORT_COMPOSITION_PHYSICAL_PASS';
const String kFailMarker = 'ANDROID_DUET_GLES_EXPORT_COMPOSITION_PHYSICAL_FAIL';
const String kJsonPrefix = 'ANDROID_DUET_GLES_EXPORT_COMPOSITION_JSON:';

const String kExpectedProofBoundary =
    'android_duet_gles_export_composition_rgba_matte_overlay_mediacodec_mp4_only';

const String kChannelName =
    'vanguard_media_engine_example/duet_gles_export_composition';
const String kMethodName = 'runAndroidDuetGlesExportCompositionSmoke';

const List<String> kRequiredGates = <String>[
  'inputValidationOk',
  'sourceMetadataOk',
  'baselineEncodeOk',
  'compositionEncodeOk',
  'compositionFrameCountOk',
  'frameExtractOk',
  'outputMp4Ok',
  'alphaZeroPreservesBackgroundOk',
  'alphaFullForegroundOk',
  'alphaFractionalBlendOk',
  'cleanupOk',
  'canonical',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGlesExportCompositionSmokeApp());
}

class AndroidDuetGlesExportCompositionSmokeApp extends StatefulWidget {
  const AndroidDuetGlesExportCompositionSmokeApp({super.key});

  @override
  State<AndroidDuetGlesExportCompositionSmokeApp> createState() =>
      _AndroidDuetGlesExportCompositionSmokeAppState();
}

class _AndroidDuetGlesExportCompositionSmokeAppState
    extends State<AndroidDuetGlesExportCompositionSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kChannelName);

  String _status = 'Initializing Duet GLES export composition smoke...';
  String _step = 'INIT';
  Map<String, dynamic>? _resultDetails;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  void _updateStatus(String step, String status) {
    if (mounted) {
      setState(() {
        _step = step;
        _status = status;
      });
    }
  }

  Future<void> _runSmoke() async {
    print(kStartMarker);
    _updateStatus('RUNNING', 'Staging clip and invoking native harness...');

    Directory? tempDir;
    String? errorMessage;
    Map<String, dynamic>? resultMap;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );

      tempDir = await Directory.systemTemp.createTemp(
        'vg_duet_gles_export_composition_',
      );

      final videoFile = File('${tempDir.path}/clip_B.mov');
      await videoFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final outDir = Directory('${tempDir.path}/out');
      await outDir.create(recursive: true);

      _updateStatus(
        'RUNNING',
        'Invoking native GLES export composition harness...',
      );

      final dynamic rawResult = await _channel
          .invokeMethod<dynamic>(kMethodName, <String, dynamic>{
            'videoPath': videoFile.path,
            'outputDir': outDir.path,
          })
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw TimeoutException(
              'Duet GLES export composition smoke timed out after 45 seconds',
            ),
          );

      if (rawResult is Map) {
        resultMap = Map<String, dynamic>.from(rawResult);
      } else {
        errorMessage = 'Harness returned unexpected non-map result: $rawResult';
      }
    } on TimeoutException catch (te) {
      errorMessage = 'Watchdog timeout: $te';
    } catch (e, st) {
      errorMessage = '$e\n$st';
    } finally {
      if (tempDir != null) {
        try {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }

    bool pass = false;
    if (errorMessage == null && resultMap != null) {
      final rawPass = resultMap['pass'] == true;
      final rawMarker = resultMap['marker'];
      final rawBoundary = resultMap['proofBoundary'];
      final rawMaxDelta = resultMap['maxDelta'];
      final rawTolerance = resultMap['lossyRgbTolerance'];
      final gates = resultMap['gates'];

      final maxDelta = rawMaxDelta is num ? rawMaxDelta.toInt() : null;
      final tolerance = rawTolerance is num ? rawTolerance.toInt() : null;
      final withinTolerance =
          maxDelta != null && tolerance != null && maxDelta <= tolerance;

      bool requiredGatesOk = false;
      if (gates is Map) {
        requiredGatesOk = kRequiredGates.every((key) => gates[key] == true);
      }

      if (rawPass &&
          rawMarker == kPassMarker &&
          rawBoundary == kExpectedProofBoundary &&
          withinTolerance &&
          requiredGatesOk) {
        pass = true;
        if (mounted) {
          setState(() {
            _resultDetails = resultMap;
          });
        }
      } else {
        errorMessage =
            'Result validation failed: pass=$rawPass, '
            'marker=$rawMarker, boundary=$rawBoundary, '
            'maxDelta=$maxDelta, tolerance=$tolerance, '
            'requiredGatesOk=$requiredGatesOk, gates=$gates';
      }
    }

    final Map<String, Object?> fallbackMap = <String, Object?>{
      'pass': false,
      'marker': kFailMarker,
      'proofBoundary': kExpectedProofBoundary,
    };
    if (errorMessage != null) {
      fallbackMap['error'] = errorMessage;
    }
    final Map<String, dynamic> jsonMap = resultMap ?? fallbackMap;

    print('$kJsonPrefix${jsonEncode(jsonMap)}');

    if (pass) {
      print(kPassMarker);
      _updateStatus('PASS', 'Duet GLES export composition proof passed');
    } else {
      print(kFailMarker);
      _updateStatus('FAIL', errorMessage ?? 'Proof failed');
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Android Duet GLES Export Composition',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Step: $_step',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  'Status: $_status',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                if (_resultDetails != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Proof Details:',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Text(
                    jsonEncode(_resultDetails),
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
