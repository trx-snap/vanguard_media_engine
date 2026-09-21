// Copyright 2026, Connects. All rights reserved.
// ios_duet_export_transform_pixel_proof_physical_smoke.dart
// Vanguard Media Engine — IOS-DUET-EXPORT-TRANSFORM-PIXEL-PROOF: narrow
// diagnostic proof that the real public MethodChannel `exportDuetComposition`
// (via `MethodChannelVGDuetPlatform.exportDuetComposition`) carries
// `foregroundTransform.rotationDegrees` into the produced MP4, mirroring
// android_duet_export_transform_pixel_proof_physical_smoke.dart's structure,
// sample geometry, and gates exactly (iOS names/markers).
//
// Prints:
//   IOS_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_START
//   IOS_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_JSON:<json>
//   IOS_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_PHYSICAL_PASS | ..._PHYSICAL_FAIL
//
// Non-claims: no live camera, no ML matte quality, no Android, no
// ConnectsApp UI/upload, no arbitrary anchor pivot parity beyond
// center-anchor 90-degree proof.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vanguard_media_engine/vg_duet.dart';

const String _startMarker = 'IOS_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_START';
const String _jsonPrefix = 'IOS_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_JSON:';
const String _passMarker =
    'IOS_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_PHYSICAL_PASS';
const String _failMarker =
    'IOS_DUET_EXPORT_TRANSFORM_PIXEL_PROOF_PHYSICAL_FAIL';
const String _proofBoundary =
    'ios_duet_export_public_api_foreground_transform_rotation_pixel_proof';

const String _methodChannelName = 'vanguard_media_engine';

const int _width = 360;
const int _height = 640;
const int _fps = 30;
const int _frameCount = 6;
const int _videoBitRate = 1500000;
const int _pixelTolerance = 80;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IosDuetExportTransformPixelProofSmokeApp());
}

class IosDuetExportTransformPixelProofSmokeApp extends StatefulWidget {
  const IosDuetExportTransformPixelProofSmokeApp({super.key});

  @override
  State<IosDuetExportTransformPixelProofSmokeApp> createState() =>
      _IosDuetExportTransformPixelProofSmokeAppState();
}

class _IosDuetExportTransformPixelProofSmokeAppState
    extends State<IosDuetExportTransformPixelProofSmokeApp> {
  static const MethodChannel _channel = MethodChannel(_methodChannelName);
  static const MethodChannelVGDuetPlatform _platform =
      MethodChannelVGDuetPlatform();

  String _status = 'Initializing iOS Duet export transform pixel proof…';

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
      'vg_ios_duet_transform_proof_',
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
    Map<String, dynamic>? export0Payload;
    Map<String, dynamic>? export90Payload;
    Map<String, dynamic>? nativeAssertResult;
    final failureReasons = <String>[];

    final rotation0Path = '${tempDir.path}/duet_export_rot0.mp4';
    final rotation90Path = '${tempDir.path}/duet_export_rot90.mp4';

    try {
      // Step 1: Prepare deterministic native fixtures (deterministic solid
      // red MP4), via the existing green-screen export diagnostic route —
      // NOT a Duet-owned route, but the shared fixture-preparation seam both
      // platforms' transform proofs already reuse.
      try {
        fixtureResult = await _channel.invokeMapMethod<String, dynamic>(
          'prepareIosGreenScreenExportApiPixelProofFixtures',
          <String, dynamic>{
            'workDir': tempDir.path,
            'width': _width,
            'height': _height,
            'fps': _fps,
            'frameCount': _frameCount,
            'bitrate': _videoBitRate,
          },
        );
      } catch (e) {
        failureReasons.add('fixture_preparation_invocation_failed:$e');
      }

      final redVideoPath = fixtureResult?['foregroundVideoPath'] as String?;
      fixtureOk =
          fixtureResult?['pass'] == true &&
          redVideoPath != null &&
          File(redVideoPath).existsSync() &&
          File(redVideoPath).lengthSync() > 0;

      if (!fixtureOk) {
        failureReasons.add(
          'fixture_preparation_failed:${fixtureResult?['reason']}',
        );
      } else {
        // Step 2: Export Duet composition A (greenScreen, rotationDegrees: 0)
        // via the public typed MethodChannelVGDuetPlatform.exportDuetComposition
        // route. The fixture's own duration is exactly frameCount/fps = 0.2s
        // (6 frames @ 30fps); VGDuetTrimWindow enforces a Dart-side >= 1.0s
        // minimum window duration, so the requested window is [0.0, 1.0] --
        // VGDuetExportSession clamps the effective trim end to the source's
        // real 0.2s duration natively, so the EFFECTIVE exported range is
        // still the whole 0.2s fixture either way.
        final descriptorRot0 = VGDuetCompositionDescriptor(
          source: VGDuetSource.localFile(redVideoPath),
          layoutConfig: VGDuetLayoutConfig(
            mode: VGDuetLayoutMode.greenScreen,
            foregroundTransform: const VGDuetForegroundTransform(
              scale: 0.4,
              offset: VGDuetPoint.zero,
              anchor: VGDuetPoint(0.5, 0.5),
              rotationDegrees: 0.0,
            ),
          ),
          trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 1.0),
          initialSpeed: 1.0,
          segments: const [],
        );

        try {
          final export0 = await _platform.exportDuetComposition(
            descriptor: descriptorRot0,
            outputPath: rotation0Path,
            targetSize: VGDuetSize(_width.toDouble(), _height.toDouble()),
            videoBitRate: _videoBitRate,
          );
          export0Payload = <String, dynamic>{
            'outputPath': export0.outputPath,
            'durationMs': export0.durationMs,
            'fileSizeBytes': export0.fileSizeBytes,
          };
          exportRotation0Ok =
              export0.outputPath.isNotEmpty && export0.fileSizeBytes > 0;
          if (!exportRotation0Ok) {
            failureReasons.add('export_rotation0_invalid_result');
          }
        } on VGDuetException catch (e) {
          failureReasons.add(
            'export_rotation0_failed:${e.code.name}:${e.message}',
          );
        } catch (e) {
          failureReasons.add('export_rotation0_failed:$e');
        }

        // Step 3: Export Duet composition B (greenScreen, rotationDegrees: 90)
        final descriptorRot90 = VGDuetCompositionDescriptor(
          source: VGDuetSource.localFile(redVideoPath),
          layoutConfig: VGDuetLayoutConfig(
            mode: VGDuetLayoutMode.greenScreen,
            foregroundTransform: const VGDuetForegroundTransform(
              scale: 0.4,
              offset: VGDuetPoint.zero,
              anchor: VGDuetPoint(0.5, 0.5),
              rotationDegrees: 90.0,
            ),
          ),
          trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 1.0),
          initialSpeed: 1.0,
          segments: const [],
        );

        try {
          final export90 = await _platform.exportDuetComposition(
            descriptor: descriptorRot90,
            outputPath: rotation90Path,
            targetSize: VGDuetSize(_width.toDouble(), _height.toDouble()),
            videoBitRate: _videoBitRate,
          );
          export90Payload = <String, dynamic>{
            'outputPath': export90.outputPath,
            'durationMs': export90.durationMs,
            'fileSizeBytes': export90.fileSizeBytes,
          };
          exportRotation90Ok =
              export90.outputPath.isNotEmpty && export90.fileSizeBytes > 0;
          if (!exportRotation90Ok) {
            failureReasons.add('export_rotation90_invalid_result');
          }
        } on VGDuetException catch (e) {
          failureReasons.add(
            'export_rotation90_failed:${e.code.name}:${e.message}',
          );
        } catch (e) {
          failureReasons.add('export_rotation90_failed:$e');
        }

        // Verify output files exist and are non-empty.
        final f0 = File(rotation0Path);
        final f90 = File(rotation90Path);
        outputFilesOk =
            f0.existsSync() &&
            f0.lengthSync() > 0 &&
            f90.existsSync() &&
            f90.lengthSync() > 0;
        if (!outputFilesOk) {
          failureReasons.add('output_files_missing_or_empty');
        }

        if (outputFilesOk) {
          // Step 4: Validate decoded pixels via the native diagnostic route
          // (VGDuetExportTransformPixelProofDiagnostics, routed directly by
          // VGDuetMethodHandler — never through generic green-screen export
          // production code).
          try {
            nativeAssertResult = await _channel
                .invokeMapMethod<String, dynamic>(
                  'assertIosDuetExportTransformPixelProofOutput',
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
      // Step 5: Cleanup temp dir in finally.
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
        cleanupOk = !await tempDir.exists();
      } catch (e) {
        cleanupOk = false;
        failureReasons.add('cleanup_failed:$e');
      }

      canonical =
          fixtureOk &&
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
          'rotation0': export0Payload,
          'rotation90': export90Payload,
        },
        'nonClaims': <String>[
          'no_live_camera',
          'no_ml_matte_quality',
          'no_android',
          'no_connectsapp_ui_upload',
          'no_arbitrary_anchor_pivot_parity_beyond_center_anchor_90_degree_proof',
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
