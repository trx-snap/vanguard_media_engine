// android_duet_export_transform_pixel_proof_physical_smoke.dart
// Vanguard Media Engine — ANDROID-DUET-EXPORT-TRANSFORM-PIXEL-PROOF: narrow diagnostic
// proof that real public MethodChannel `exportDuetComposition` carries
// `foregroundTransform.rotationDegrees` into the produced MP4.
//
// Prints:
//   ANDROID_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_START
//   ANDROID_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_JSON:<json>
//   ANDROID_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_PHYSICAL_PASS | ..._PHYSICAL_FAIL

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String _startMarker =
    'ANDROID_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_START';
const String _jsonPrefix =
    'ANDROID_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_JSON:';
const String _passMarker =
    'ANDROID_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_PHYSICAL_PASS';
const String _failMarker =
    'ANDROID_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_PHYSICAL_FAIL';
const String _proofBoundary =
    'android_duet_export_public_api_foreground_transform_rotation_pixel_proof';

const int _width = 360;
const int _height = 640;
const int _fps = 30;
const int _frameCount = 6;
const int _videoBitRate = 1500000;
const int _pixelTolerance = 80;

void main() {
  runApp(const AndroidDuetExportTransformPixelProofSmokeApp());
}

class AndroidDuetExportTransformPixelProofSmokeApp extends StatefulWidget {
  const AndroidDuetExportTransformPixelProofSmokeApp({super.key});

  @override
  State<AndroidDuetExportTransformPixelProofSmokeApp> createState() =>
      _AndroidDuetExportTransformPixelProofSmokeAppState();
}

class _AndroidDuetExportTransformPixelProofSmokeAppState
    extends State<AndroidDuetExportTransformPixelProofSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  String _status = 'Initializing Android Duet export transform pixel proof…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(_startMarker);

    final tempDir = await Directory.systemTemp.createTemp(
      'vg_duet_transform_proof_',
    );
    var fixtureOk = false;
    var exportRotation0Ok = false;
    var exportRotation90Ok = false;
    var outputFilesOk = false;
    var decodeOk = false;
    var centerOverlayOk = false;
    var rightArmRotationDifferentiatesOk = false;
    var lowerArmRotationDifferentiatesOk = false;
    var farCornerBackgroundOk = false;
    var cleanupOk = false;
    var canonical = false;

    Map<String, dynamic>? fixtureResult;
    Map<String, dynamic>? export0Result;
    Map<String, dynamic>? export90Result;
    Map<String, dynamic>? nativeAssertResult;
    final failureReasons = <String>[];

    final rotation0Path = '${tempDir.path}/duet_export_rot0.mp4';
    final rotation90Path = '${tempDir.path}/duet_export_rot90.mp4';

    try {
      // Step 1: Prepare deterministic native fixtures (deterministic solid red MP4)
      fixtureResult = await _channel.invokeMapMethod<String, dynamic>(
        'prepareAndroidGreenScreenExportApiPixelProofFixtures',
        <String, dynamic>{
          'workDir': tempDir.path,
          'width': _width,
          'height': _height,
          'fps': _fps,
          'frameCount': _frameCount,
          'bitrate': _videoBitRate,
        },
      );

      final redVideoPath = fixtureResult?['foregroundVideoPath'] as String?;
      fixtureOk = fixtureResult?['pass'] == true &&
          redVideoPath != null &&
          File(redVideoPath).existsSync() &&
          File(redVideoPath).lengthSync() > 0;

      if (!fixtureOk) {
        failureReasons.add(
          'fixture_preparation_failed:${fixtureResult?['reason']}',
        );
      } else {
        // Step 2: Export Duet composition A (greenScreen, rotationDegrees: 0)
        final descriptorRot0 = <String, dynamic>{
          'source': <String, dynamic>{
            'filePath': redVideoPath,
          },
          'trimWindow': <String, dynamic>{
            'startSeconds': 0.0,
            'endSeconds': 0.2,
          },
          'layoutConfig': <String, dynamic>{
            'mode': 'greenScreen',
            'foregroundTransform': <String, dynamic>{
              'scale': 0.4,
              'offset': <String, dynamic>{'x': 0.0, 'y': 0.0},
              'anchor': <String, dynamic>{'x': 0.5, 'y': 0.5},
              'rotationDegrees': 0.0,
            },
          },
        };

        try {
          export0Result = await _channel.invokeMapMethod<String, dynamic>(
            'exportDuetComposition',
            <String, dynamic>{
              'descriptor': descriptorRot0,
              'outputPath': rotation0Path,
              'targetSize': <String, dynamic>{
                'width': _width,
                'height': _height,
              },
              'videoBitRate': _videoBitRate,
            },
          );
          final out0Path = export0Result?['outputPath'] as String?;
          final size0 = (export0Result?['fileSizeBytes'] as num?)?.toInt() ?? 0;
          exportRotation0Ok = out0Path != null && size0 > 0;
          if (!exportRotation0Ok) {
            failureReasons.add('export_rotation0_invalid_result');
          }
        } catch (e) {
          failureReasons.add('export_rotation0_failed:$e');
        }

        // Step 3: Export Duet composition B (greenScreen, rotationDegrees: 90)
        final descriptorRot90 = <String, dynamic>{
          'source': <String, dynamic>{
            'filePath': redVideoPath,
          },
          'trimWindow': <String, dynamic>{
            'startSeconds': 0.0,
            'endSeconds': 0.2,
          },
          'layoutConfig': <String, dynamic>{
            'mode': 'greenScreen',
            'foregroundTransform': <String, dynamic>{
              'scale': 0.4,
              'offset': <String, dynamic>{'x': 0.0, 'y': 0.0},
              'anchor': <String, dynamic>{'x': 0.5, 'y': 0.5},
              'rotationDegrees': 90.0,
            },
          },
        };

        try {
          export90Result = await _channel.invokeMapMethod<String, dynamic>(
            'exportDuetComposition',
            <String, dynamic>{
              'descriptor': descriptorRot90,
              'outputPath': rotation90Path,
              'targetSize': <String, dynamic>{
                'width': _width,
                'height': _height,
              },
              'videoBitRate': _videoBitRate,
            },
          );
          final out90Path = export90Result?['outputPath'] as String?;
          final size90 =
              (export90Result?['fileSizeBytes'] as num?)?.toInt() ?? 0;
          exportRotation90Ok = out90Path != null && size90 > 0;
          if (!exportRotation90Ok) {
            failureReasons.add('export_rotation90_invalid_result');
          }
        } catch (e) {
          failureReasons.add('export_rotation90_failed:$e');
        }

        // Verify output files exist and are non-empty
        final f0 = File(rotation0Path);
        final f90 = File(rotation90Path);
        outputFilesOk = f0.existsSync() &&
            f0.lengthSync() > 0 &&
            f90.existsSync() &&
            f90.lengthSync() > 0;
        if (!outputFilesOk) {
          failureReasons.add('output_files_missing_or_empty');
        }

        if (outputFilesOk) {
          // Step 4: Validate decoded pixels via native assertion helper
          try {
            nativeAssertResult = await _channel.invokeMapMethod<String, dynamic>(
              'assertAndroidDuetExportTransformPixelProofOutput',
              <String, dynamic>{
                'rotation0Path': rotation0Path,
                'rotation90Path': rotation90Path,
                'width': _width,
                'height': _height,
                'fps': _fps,
                'tolerance': _pixelTolerance,
              },
            );

            decodeOk = nativeAssertResult?['decodeOk'] == true;
            centerOverlayOk = nativeAssertResult?['centerOverlayOk'] == true;
            rightArmRotationDifferentiatesOk =
                nativeAssertResult?['rightArmRotationDifferentiatesOk'] == true;
            lowerArmRotationDifferentiatesOk =
                nativeAssertResult?['lowerArmRotationDifferentiatesOk'] == true;
            farCornerBackgroundOk =
                nativeAssertResult?['farCornerBackgroundOk'] == true;

            if (nativeAssertResult?['pass'] != true) {
              failureReasons.add(
                'native_assert_failed:${nativeAssertResult?['reason']}',
              );
            }
          } catch (e) {
            failureReasons.add('native_assert_invocation_failed:$e');
          }
        }
      }
    } catch (e) {
      failureReasons.add('unexpected_error:$e');
    } finally {
      // Step 5: Cleanup temp dir in finally
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
        cleanupOk = !await tempDir.exists();
      } catch (e) {
        cleanupOk = false;
        failureReasons.add('cleanup_failed:$e');
      }

      canonical = fixtureOk &&
          exportRotation0Ok &&
          exportRotation90Ok &&
          outputFilesOk &&
          decodeOk &&
          centerOverlayOk &&
          rightArmRotationDifferentiatesOk &&
          lowerArmRotationDifferentiatesOk &&
          farCornerBackgroundOk &&
          cleanupOk;

      final pass = canonical;
      final reason = pass ? 'pass' : failureReasons.join(';');

      final payload = <String, dynamic>{
        'pass': pass,
        'reason': reason,
        'proofBoundary': _proofBoundary,
        'gates': <String, dynamic>{
          'fixtureOk': fixtureOk,
          'exportRotation0Ok': exportRotation0Ok,
          'exportRotation90Ok': exportRotation90Ok,
          'outputFilesOk': outputFilesOk,
          'decodeOk': decodeOk,
          'centerOverlayOk': centerOverlayOk,
          'rightArmRotationDifferentiatesOk': rightArmRotationDifferentiatesOk,
          'lowerArmRotationDifferentiatesOk': lowerArmRotationDifferentiatesOk,
          'farCornerBackgroundOk': farCornerBackgroundOk,
          'cleanupOk': cleanupOk,
          'canonical': canonical,
        },
        'sampling': <String, dynamic>{
          'targetWidth': _width,
          'targetHeight': _height,
          'fps': _fps,
          'pixelTolerance': _pixelTolerance,
          'nativeAssertResult': nativeAssertResult,
        },
        'exports': <String, dynamic>{
          'rotation0': export0Result,
          'rotation90': export90Result,
        },
        'nonClaims': <String>[
          'no_live_camera',
          'no_ml_matte_quality',
          'no_ios',
          'no_connectsapp_ui_upload',
          'no_arbitrary_anchor_pivot_parity_beyond_center_anchor_90_degree_proof',
          'no_low_end_android_proof',
        ],
      };

      print('$_jsonPrefix${jsonEncode(payload)}');
      print(pass ? _passMarker : _failMarker);

      if (mounted) {
        setState(() {
          _status = pass ? 'PASS' : 'FAIL: $reason';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
