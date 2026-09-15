// ios_greenscreen_export_api_pixel_proof_physical_smoke.dart
// Vanguard Media Engine — IOS-GREENSCREEN-EXPORT-API-PIXEL-PROOF: diagnostic-only
// physical proof of the PUBLIC generic green-screen export API
// (VGGreenScreenPlatformInterface.exportGreenScreenComposition through the
// default MethodChannelVGGreenScreenPlatform) with decoded-pixel assertions on iOS.
//
// The engine is caller-agnostic (Duet, live meeting/calling, going live,
// camera, Universal Editor). Never touches Duet sessions, ConnectsApp, or the
// Universal Editor.
//
// Native code provides deterministic fixture setup and decoded-pixel validation
// helpers only; all exports run strictly through the public Dart API.
//
// Lanes:
//   1. solid_r8_ladder: solid blue background + red foreground video +
//      R8 frame-file mask alternating 0/255. Proves R8 file mask support and
//      polarity (0 = background blue, 255 = foreground red).
//   2. image_fit_background: landscape image aspectFit + constantAlpha(0) mask.
//      Decoded pixels assert top-center black letterbox and center image color.
//   3. image_fill_background: landscape image aspectFill + constantAlpha(0) mask.
//      Decoded pixels assert top-center non-black/image color and center image color.
//
// Prints:
//   IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_SMOKE_START
//   IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_JSON:<json>
//   IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_PHYSICAL_PASS | ..._PHYSICAL_FAIL

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_green_screen.dart';

const String _startMarker =
    'IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_SMOKE_START';
const String _jsonPrefix = 'IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_JSON:';
const String _passMarker =
    'IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_PHYSICAL_PASS';
const String _failMarker =
    'IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_PHYSICAL_FAIL';
const String _errorPrefix = 'IOS_GREENSCREEN_EXPORT_API_PIXEL_PROOF_ERROR: ';
const String _proofBoundary =
    'ios_greenscreen_export_public_api_decoded_pixel_proof';

const int _outputFrameCount = 6;
const int _fps = 30;
const int _videoBitRate = 1500000;
const int _width = 360;
const int _height = 640;
const VGGreenScreenSize _targetSize = VGGreenScreenSize(_width, _height);
const int _pixelTolerance = 80;

void main() {
  runApp(const IosGreenScreenExportApiPixelProofSmokeApp());
}

class IosGreenScreenExportApiPixelProofSmokeApp extends StatefulWidget {
  const IosGreenScreenExportApiPixelProofSmokeApp({super.key});

  @override
  State<IosGreenScreenExportApiPixelProofSmokeApp> createState() =>
      _IosGreenScreenExportApiPixelProofSmokeAppState();
}

class _IosGreenScreenExportApiPixelProofSmokeAppState
    extends State<IosGreenScreenExportApiPixelProofSmokeApp> {
  static const VGGreenScreenPlatformInterface _platform =
      MethodChannelVGGreenScreenPlatform();
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  String _status = 'Initializing iOS green-screen export API pixel proof…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(_startMarker);
    final lanes = <Map<String, dynamic>>[];
    final tempDir = await Directory.systemTemp.createTemp(
      'vg_ios_gs_pixel_smoke_',
    );
    final cleanupPaths = <String>[];
    var pass = false;
    var reason = 'not_run';

    try {
      // 1. Prepare deterministic native fixtures
      final fixtureResult = await _channel.invokeMapMethod<String, dynamic>(
        'prepareIosGreenScreenExportApiPixelProofFixtures',
        <String, dynamic>{
          'workDir': tempDir.path,
          'width': _width,
          'height': _height,
          'fps': _fps,
          'frameCount': _outputFrameCount,
          'bitrate': _videoBitRate,
        },
      );

      if (fixtureResult == null || fixtureResult['pass'] != true) {
        throw StateError(
          'Fixture preparation failed: ${fixtureResult?['reason'] ?? 'null_result'}',
        );
      }

      final fgVideoPath = fixtureResult['foregroundVideoPath'] as String;
      final bgImagePath = fixtureResult['backgroundImagePath'] as String;
      final maskPaths = List<String>.from(
        fixtureResult['maskFramePaths'] as List,
      );
      final expectedFgRgb = List<int>.from(
        (fixtureResult['expectedForegroundRgb'] as List).cast<int>(),
      );
      final expectedSolidBgRgb = List<int>.from(
        (fixtureResult['expectedSolidBackgroundRgb'] as List).cast<int>(),
      );
      final expectedImgCenterRgb = List<int>.from(
        (fixtureResult['expectedImageCenterRgb'] as List).cast<int>(),
      );
      final expectedLetterboxRgb = List<int>.from(
        (fixtureResult['expectedLetterboxRgb'] as List).cast<int>(),
      );

      cleanupPaths.addAll(<String>[fgVideoPath, bgImagePath, ...maskPaths]);

      String outputPathFor(String lane) {
        final path = '${tempDir.path}/gs_pixel_$lane.mp4';
        cleanupPaths.addAll(<String>[path, '$path.tmp', '$path.bg.tmp.mp4']);
        return path;
      }

      // Lane 1: solid_r8_ladder (blue bg + red fg + alternating 0/255 mask)
      lanes.add(
        await _runLane(
          lane: 'solid_r8_ladder',
          request: VGGreenScreenExportRequest(
            foregroundVideoPath: fgVideoPath,
            background: const VGGreenScreenBackgroundSource.solidColor(
              0xFF1414F0, // blue matching [20, 20, 240]
            ),
            mask: VGGreenScreenMaskSource.r8FrameFiles(
              maskPaths,
              width: 64,
              height: 64,
            ),
            outputPath: outputPathFor('solid_r8_ladder'),
            targetSize: _targetSize,
            fps: _fps,
            videoBitRate: _videoBitRate,
            outputFrameCount: _outputFrameCount,
          ),
          expectedForegroundRgb: expectedFgRgb,
          expectedBackgroundRgb: expectedSolidBgRgb,
          expectedImageCenterRgb: expectedImgCenterRgb,
          expectedLetterboxRgb: expectedLetterboxRgb,
        ),
      );

      // Lane 2: image_fit_background (aspectFit landscape image + alpha 0 mask)
      lanes.add(
        await _runLane(
          lane: 'image_fit_background',
          request: VGGreenScreenExportRequest(
            foregroundVideoPath: fgVideoPath,
            background: VGGreenScreenBackgroundSource.imageFile(
              bgImagePath,
              scaleMode: VGGreenScreenScaleMode.aspectFit,
            ),
            mask: const VGGreenScreenMaskSource.constantAlpha(0),
            outputPath: outputPathFor('image_fit_background'),
            targetSize: _targetSize,
            fps: _fps,
            videoBitRate: _videoBitRate,
            outputFrameCount: _outputFrameCount,
          ),
          expectedForegroundRgb: expectedFgRgb,
          expectedBackgroundRgb: expectedSolidBgRgb,
          expectedImageCenterRgb: expectedImgCenterRgb,
          expectedLetterboxRgb: expectedLetterboxRgb,
        ),
      );

      // Lane 3: image_fill_background (aspectFill landscape image + alpha 0 mask)
      lanes.add(
        await _runLane(
          lane: 'image_fill_background',
          request: VGGreenScreenExportRequest(
            foregroundVideoPath: fgVideoPath,
            background: VGGreenScreenBackgroundSource.imageFile(
              bgImagePath,
              scaleMode: VGGreenScreenScaleMode.aspectFill,
            ),
            mask: const VGGreenScreenMaskSource.constantAlpha(0),
            outputPath: outputPathFor('image_fill_background'),
            targetSize: _targetSize,
            fps: _fps,
            videoBitRate: _videoBitRate,
            outputFrameCount: _outputFrameCount,
          ),
          expectedForegroundRgb: expectedFgRgb,
          expectedBackgroundRgb: expectedSolidBgRgb,
          expectedImageCenterRgb: expectedImgCenterRgb,
          expectedLetterboxRgb: expectedLetterboxRgb,
        ),
      );

      pass = lanes.isNotEmpty && lanes.every((l) => l['pass'] == true);
      reason = pass
          ? 'pass'
          : lanes
                .where((l) => l['pass'] != true)
                .map((l) => '${l['lane']}:${l['reason']}')
                .join(';');
    } catch (error, stack) {
      print('$_errorPrefix$error\n$stack');
      pass = false;
      reason = 'dart_exception:$error';
    } finally {
      for (final path in cleanupPaths) {
        await _deleteQuietly(path);
      }
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }

    final payload = <String, dynamic>{
      'pass': pass,
      'reason': reason,
      'proofBoundary': _proofBoundary,
      'outputFrameCount': _outputFrameCount,
      'fps': _fps,
      'targetSize': _targetSize.toMap(),
      'pixelTolerance': _pixelTolerance,
      'lanes': lanes,
      'claims': pass
          ? <String>[
              'public_dart_green_screen_export_api',
              'decoded_pixel_proof',
              'r8_frame_files_mask_lane',
              'mask_polarity_zero_bg_255_fg',
              'solid_color_pixel_output',
              'image_aspect_fit_letterbox_pixel_output',
              'image_aspect_fill_pixel_output',
              'clean_tmp_and_generated_background_cleanup',
            ]
          : <String>[],
      'nonClaims': <String>[
        'no_ml_matte',
        'no_live_camera',
        'no_video_background',
        'no_connectsapp_or_universal_editor_wiring',
      ],
    };
    print('$_jsonPrefix${jsonEncode(payload)}');
    print(pass ? _passMarker : _failMarker);

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS\n${lanes.length} lanes' : 'FAIL: $reason';
      });
    }
  }

  Future<void> _cleanLaneOutputs(VGGreenScreenExportRequest request) async {
    await _deleteQuietly(request.outputPath);
    await _deleteQuietly('${request.outputPath}.tmp');
    await _deleteQuietly('${request.outputPath}.bg.tmp.mp4');
  }

  Future<Map<String, dynamic>> _runLane({
    required String lane,
    required VGGreenScreenExportRequest request,
    required List<int> expectedForegroundRgb,
    required List<int> expectedBackgroundRgb,
    required List<int> expectedImageCenterRgb,
    required List<int> expectedLetterboxRgb,
  }) async {
    await _cleanLaneOutputs(request);
    try {
      // 1. Export strictly via public Dart API
      final result = await _platform.exportGreenScreenComposition(
        request: request,
      );

      final file = File(result.outputPath);
      final exists = await file.exists();
      final onDiskBytes = exists ? await file.length() : 0;
      final tmpLeft = await File('${request.outputPath}.tmp').exists();
      final bgTmpLeft = await File('${request.outputPath}.bg.tmp.mp4').exists();

      final exportFailures = <String>[
        if (result.terminalState != 'success')
          'terminal_${result.terminalState}',
        if (result.renderedFrames != _outputFrameCount)
          'rendered_frames_mismatch:${result.renderedFrames}!=expected:$_outputFrameCount',
        if (result.writtenVideoSamples != _outputFrameCount)
          'written_samples_mismatch:${result.writtenVideoSamples}!=expected:$_outputFrameCount',
        if (!result.renderedEqualsWritten) 'rendered_not_equal_written',
        if (result.fileSizeBytes <= 0) 'file_size_zero',
        if (!exists || onDiskBytes != result.fileSizeBytes)
          'on_disk_size_mismatch:exists=$exists,disk=$onDiskBytes,result=${result.fileSizeBytes}',
        if (result.tmpExists || tmpLeft) 'tmp_leftover',
        if (result.backgroundGeneratedTmpExists || bgTmpLeft)
          'generated_background_leftover',
        if (result.backgroundSourceType != request.background.type)
          'background_source_type_mismatch:${result.backgroundSourceType}!=${request.background.type}',
        if (result.backgroundGeneratedFrames != _outputFrameCount)
          'background_generated_frames_mismatch:${result.backgroundGeneratedFrames}!=expected:$_outputFrameCount',
        if (result.foreground.decodedFrames <= 0) 'foreground_not_decoded',
      ];

      // 2. Validate decoded pixels via native helper
      final validatorResult = await _channel.invokeMapMethod<String, dynamic>(
        'assertIosGreenScreenExportApiPixelProofOutput',
        <String, dynamic>{
          'outputPath': result.outputPath,
          'lane': lane,
          'width': _width,
          'height': _height,
          'fps': _fps,
          'frameCount': _outputFrameCount,
          'tolerance': _pixelTolerance,
          'expectedForegroundRgb': expectedForegroundRgb,
          'expectedBackgroundRgb': expectedBackgroundRgb,
          'expectedImageCenterRgb': expectedImageCenterRgb,
          'expectedLetterboxRgb': expectedLetterboxRgb,
        },
      );

      final validatorPass = validatorResult?['pass'] == true;
      final validatorReason = validatorResult?['reason'] ?? 'validator_null';
      if (!validatorPass) {
        exportFailures.add('validator_failed:$validatorReason');
      }

      final lanePass = exportFailures.isEmpty && validatorPass;
      final laneReason = lanePass ? 'pass' : exportFailures.join(';');

      return <String, dynamic>{
        'lane': lane,
        'pass': lanePass,
        'reason': laneReason,
        'onDiskBytes': onDiskBytes,
        'exportResult': result.toMap(),
        'validatorResult': validatorResult,
      };
    } on VGGreenScreenException catch (e) {
      return <String, dynamic>{
        'lane': lane,
        'pass': false,
        'reason': 'exception:${e.code.name}:${e.message}',
        'details': e.details?.toString(),
      };
    } catch (e) {
      return <String, dynamic>{
        'lane': lane,
        'pass': false,
        'reason': 'unexpected_exception:$e',
      };
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
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
