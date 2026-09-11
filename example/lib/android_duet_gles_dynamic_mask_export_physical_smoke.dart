// android_duet_gles_dynamic_mask_export_physical_smoke.dart
// Vanguard Media Engine - Android Duet deterministic per-frame GLES mask upload export
// physical smoke: proves Android can upload a time-varying single-channel GL_LUMINANCE
// mask per encoded frame, blend foreground/background in GLES, encode the result to MP4
// via MediaCodec input surface, and verify decoded pixels.
//
// Proof boundary:
//   android_duet_gles_dynamic_mask_export_per_frame_upload_mediacodec_mp4_only
//
// Non-claims (echoed by the native harness; also see its `nonClaims` field):
//   - No live ML human matte quality.
//   - No live CameraX/OES lifecycle.
//   - No production Duet recording/export branch.
//   - No source-video decoder composition.
//   - No multi-track audio/A-V sync.
//   - No ConnectsApp/Universal Editor/upload wiring.
//   - No low-end Android proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kStartMarker = 'ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_START';
const String kMaskUploadPassMarker =
    'ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_MASK_UPLOAD_PASS';
const String kFrameVariationPassMarker =
    'ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_FRAME_VARIATION_PASS';
const String kPassMarker =
    'ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_PHYSICAL_PASS';
const String kFailMarker =
    'ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_PHYSICAL_FAIL';
const String kJsonPrefix = 'ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_JSON:';

const String kExpectedProofBoundary =
    'android_duet_gles_dynamic_mask_export_per_frame_upload_mediacodec_mp4_only';

const String kChannelName =
    'vanguard_media_engine_example/duet_gles_dynamic_mask_export';
const String kMethodName = 'runAndroidDuetGlesDynamicMaskExportSmoke';

const List<String> kRequiredGates = <String>[
  'inputValidationOk',
  'codecSetupOk',
  'eglSetupOk',
  'shaderProgramOk',
  'dynamicMaskUploadOk',
  'encodedMp4Ok',
  'frameExtractOk',
  'alphaZeroBackgroundOk',
  'alphaFullForegroundOk',
  'alphaFractionalBlendOk',
  'frameVariationOk',
  'cleanupOk',
  'canonical',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGlesDynamicMaskExportSmokeApp());
}

class AndroidDuetGlesDynamicMaskExportSmokeApp extends StatefulWidget {
  const AndroidDuetGlesDynamicMaskExportSmokeApp({super.key});

  @override
  State<AndroidDuetGlesDynamicMaskExportSmokeApp> createState() =>
      _AndroidDuetGlesDynamicMaskExportSmokeAppState();
}

class _AndroidDuetGlesDynamicMaskExportSmokeAppState
    extends State<AndroidDuetGlesDynamicMaskExportSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kChannelName);

  String _status = 'Initializing Duet GLES dynamic mask export smoke...';
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
    _updateStatus('RUNNING', 'Preparing output directory...');

    Directory? tempDir;
    String? errorMessage;
    Map<String, dynamic>? resultMap;

    try {
      tempDir = await Directory.systemTemp.createTemp(
        'vg_duet_gles_dyn_mask_export_',
      );

      final outDir = Directory('${tempDir.path}/out');
      await outDir.create(recursive: true);

      _updateStatus(
        'RUNNING',
        'Invoking native GLES dynamic mask export harness...',
      );

      final dynamic rawResult = await _channel
          .invokeMethod<dynamic>(kMethodName, <String, dynamic>{
            'outputDir': outDir.path,
          })
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw TimeoutException(
              'Duet GLES dynamic mask export smoke timed out after 45 seconds',
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
      final rawSampleCount = resultMap['sampleCount'];
      final gates = resultMap['gates'];
      final mismatches = resultMap['mismatches'];

      final maxDelta = rawMaxDelta is num ? rawMaxDelta.toInt() : null;
      final tolerance = rawTolerance is num ? rawTolerance.toInt() : null;
      final sampleCount = rawSampleCount is num ? rawSampleCount.toInt() : 0;
      final withinTolerance =
          maxDelta != null && tolerance != null && maxDelta <= tolerance;
      final sampleCountOk = sampleCount >= 4;
      final mismatchesEmpty = mismatches is List && mismatches.isEmpty;

      bool requiredGatesOk = false;
      if (gates is Map) {
        requiredGatesOk = kRequiredGates.every((key) => gates[key] == true);
      }

      if (rawPass &&
          rawMarker == kPassMarker &&
          rawBoundary == kExpectedProofBoundary &&
          withinTolerance &&
          sampleCountOk &&
          mismatchesEmpty &&
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
            'sampleCount=$sampleCount, mismatchesEmpty=$mismatchesEmpty, '
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
      _updateStatus('PASS', 'Duet GLES dynamic mask export proof passed');
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
                  'Android Duet GLES Dynamic Mask Export',
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
