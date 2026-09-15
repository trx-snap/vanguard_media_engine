// android_greenscreen_export_api_static_physical_smoke.dart
// Vanguard Media Engine — ANDROID-GREENSCREEN-EXPORT-API-STATIC: diagnostic-only
// physical proof of the PUBLIC generic green-screen export API
// (VGGreenScreenPlatformInterface.exportGreenScreenComposition through the
// default MethodChannelVGGreenScreenPlatform) on static backgrounds.
//
// The engine is caller-agnostic (Duet, live meeting/calling, going live,
// camera, Universal Editor). Never touches Duet sessions, ConnectsApp, or the
// Universal Editor. Fixtures are the bundled manual test clip (foreground) and
// still image (image background); no fixture generation happens in Dart.
//
// Lanes (all through the public Dart API, sequential unless stated):
//   solid_color          : solidColor background + constantAlpha(0) mask
//   image_aspect_fit     : imageFile(aspectFit) background + constantAlpha(0)
//   image_aspect_fill    : imageFile(aspectFill) background + constantAlpha(255)
//   invalid_argument     : missing foreground file → VGGreenScreenException
//                          with code invalidArgument, nothing written
//   export_busy          : two exports started back-to-back → the second fails
//                          with code exportBusy while the first passes
//
// Per positive lane the Dart side asserts: terminalState == success,
// renderedFrames == writtenVideoSamples == outputFrameCount, fileSizeBytes > 0
// and equal to the file on disk, tmpExists == false, backgroundSourceType
// matches, backgroundGeneratedFrames == outputFrameCount, no generated
// background tmp left, and the generated background lane paired 1:1
// (0 dropped, 0 held). Pixel content is NOT asserted here (see the native
// production export smoke for decoded-pixel proof).
//
// Prints:
//   ANDROID_GREENSCREEN_EXPORT_API_STATIC_SMOKE_START
//   ANDROID_GREENSCREEN_EXPORT_API_STATIC_JSON:<json>
//   ANDROID_GREENSCREEN_EXPORT_API_STATIC_PHYSICAL_PASS | ..._PHYSICAL_FAIL

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_green_screen.dart';

const String _startMarker = 'ANDROID_GREENSCREEN_EXPORT_API_STATIC_SMOKE_START';
const String _jsonPrefix = 'ANDROID_GREENSCREEN_EXPORT_API_STATIC_JSON:';
const String _passMarker =
    'ANDROID_GREENSCREEN_EXPORT_API_STATIC_PHYSICAL_PASS';
const String _failMarker =
    'ANDROID_GREENSCREEN_EXPORT_API_STATIC_PHYSICAL_FAIL';
const String _errorPrefix = 'ANDROID_GREENSCREEN_EXPORT_API_STATIC_ERROR: ';
const String _proofBoundary =
    'android_greenscreen_export_public_api_static_background_lanes';

const int _outputFrameCount = 30;
const int _fps = 30;
const int _videoBitRate = 2000000;
const VGGreenScreenSize _targetSize = VGGreenScreenSize(540, 960);

void main() {
  runApp(const AndroidGreenScreenExportApiStaticSmokeApp());
}

class AndroidGreenScreenExportApiStaticSmokeApp extends StatefulWidget {
  const AndroidGreenScreenExportApiStaticSmokeApp({super.key});

  @override
  State<AndroidGreenScreenExportApiStaticSmokeApp> createState() =>
      _AndroidGreenScreenExportApiStaticSmokeAppState();
}

class _AndroidGreenScreenExportApiStaticSmokeAppState
    extends State<AndroidGreenScreenExportApiStaticSmokeApp> {
  static const VGGreenScreenPlatformInterface _platform =
      MethodChannelVGGreenScreenPlatform();

  String _status = 'Initializing Android green-screen export API smoke…';

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
    final tempDir = await Directory.systemTemp.createTemp('vg_gs_api_smoke_');
    final cleanupPaths = <String>[];
    var pass = false;
    var reason = 'not_run';

    try {
      final clipPath = await _stageAsset(
        'assets/manual_test_clips/clip_A.mov',
        '${tempDir.path}/clip_A.mov',
      );
      final imagePath = await _stageAsset(
        'assets/manual_test_clips/still_C.png',
        '${tempDir.path}/still_C.png',
      );

      String outputPathFor(String lane) {
        final path = '${tempDir.path}/gs_api_$lane.mp4';
        cleanupPaths.addAll(<String>[path, '$path.tmp', '$path.bg.tmp.mp4']);
        return path;
      }

      VGGreenScreenExportRequest request({
        required String lane,
        required VGGreenScreenBackgroundSource background,
        required int alpha,
        String? foregroundVideoPath,
      }) => VGGreenScreenExportRequest(
        foregroundVideoPath: foregroundVideoPath ?? clipPath,
        background: background,
        mask: VGGreenScreenMaskSource.constantAlpha(alpha),
        outputPath: outputPathFor(lane),
        targetSize: _targetSize,
        fps: _fps,
        videoBitRate: _videoBitRate,
        outputFrameCount: _outputFrameCount,
      );

      lanes.add(
        await _runPositiveLane(
          'solid_color',
          request(
            lane: 'solid_color',
            background: const VGGreenScreenBackgroundSource.solidColor(
              0xFF2040C0,
            ),
            alpha: 0,
          ),
        ),
      );
      lanes.add(
        await _runPositiveLane(
          'image_aspect_fit',
          request(
            lane: 'image_aspect_fit',
            background: VGGreenScreenBackgroundSource.imageFile(
              imagePath,
              scaleMode: VGGreenScreenScaleMode.aspectFit,
            ),
            alpha: 0,
          ),
        ),
      );
      lanes.add(
        await _runPositiveLane(
          'image_aspect_fill',
          request(
            lane: 'image_aspect_fill',
            background: VGGreenScreenBackgroundSource.imageFile(
              imagePath,
              scaleMode: VGGreenScreenScaleMode.aspectFill,
            ),
            alpha: 255,
          ),
        ),
      );
      lanes.add(
        await _runInvalidArgumentLane(
          request(
            lane: 'invalid_argument',
            background: const VGGreenScreenBackgroundSource.solidColor(
              0xFF000000,
            ),
            alpha: 0,
            foregroundVideoPath: '${tempDir.path}/does_not_exist.mov',
          ),
        ),
      );
      lanes.add(
        await _runExportBusyLane(
          first: request(
            lane: 'export_busy_first',
            background: const VGGreenScreenBackgroundSource.solidColor(
              0xFF20C040,
            ),
            alpha: 0,
          ),
          second: request(
            lane: 'export_busy_second',
            background: const VGGreenScreenBackgroundSource.solidColor(
              0xFFC02020,
            ),
            alpha: 0,
          ),
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
      'lanes': lanes,
      'claims': pass
          ? <String>[
              'public_dart_green_screen_export_api',
              'solid_color_background_generated_lane',
              'image_background_aspect_fit_and_fill_generated_lanes',
              'generated_background_one_to_one_pairing',
              'invalid_argument_fail_closed',
              'export_busy_fail_closed',
              'clean_tmp_and_generated_background_cleanup',
            ]
          : <String>[],
      'nonClaims': <String>[
        'no_decoded_pixel_assertion',
        'no_r8_frame_files_mask_lane',
        'no_video_background_lane',
        'no_rect_rotation_mirror_coverage',
        'no_ml_matte',
        'no_production_duet_wiring',
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

  Future<Map<String, dynamic>> _runPositiveLane(
    String lane,
    VGGreenScreenExportRequest request,
  ) async {
    try {
      final result = await _platform.exportGreenScreenComposition(
        request: request,
      );
      final file = File(result.outputPath);
      final exists = await file.exists();
      final onDiskBytes = exists ? await file.length() : 0;
      final tmpLeft = await File('${request.outputPath}.tmp').exists();
      final failures = <String>[
        if (result.terminalState != 'success')
          'terminal_${result.terminalState}',
        if (result.renderedFrames != _outputFrameCount)
          'rendered_frames_mismatch',
        if (!result.renderedEqualsWritten) 'rendered_not_equal_written',
        if (result.fileSizeBytes <= 0) 'file_size_zero',
        if (!exists || onDiskBytes != result.fileSizeBytes)
          'on_disk_size_mismatch',
        if (result.tmpExists || tmpLeft) 'tmp_leftover',
        if (result.backgroundSourceType != request.background.type)
          'background_source_type_mismatch',
        if (result.backgroundGeneratedFrames != _outputFrameCount)
          'background_generated_frames_mismatch',
        if (result.backgroundGeneratedTmpExists)
          'generated_background_leftover',
        if (result.background.droppedFrames != 0 ||
            result.background.heldFrames != 0)
          'generated_background_pairing_not_one_to_one',
        if (result.foreground.decodedFrames <= 0) 'foreground_not_decoded',
      ];
      return <String, dynamic>{
        'lane': lane,
        'pass': failures.isEmpty,
        'reason': failures.isEmpty ? 'pass' : failures.join(','),
        'onDiskBytes': onDiskBytes,
        'result': result.toMap(),
      };
    } on VGGreenScreenException catch (e) {
      return <String, dynamic>{
        'lane': lane,
        'pass': false,
        'reason': 'exception:${e.code.name}:${e.message}',
        'details': e.details?.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> _runInvalidArgumentLane(
    VGGreenScreenExportRequest request,
  ) async {
    const lane = 'invalid_argument';
    try {
      final result = await _platform.exportGreenScreenComposition(
        request: request,
      );
      return <String, dynamic>{
        'lane': lane,
        'pass': false,
        'reason': 'unexpected_success',
        'result': result.toMap(),
      };
    } on VGGreenScreenException catch (e) {
      final outputLeft = await File(request.outputPath).exists();
      final tmpLeft = await File('${request.outputPath}.tmp').exists();
      final codeOk = e.code == VGGreenScreenErrorCode.invalidArgument;
      return <String, dynamic>{
        'lane': lane,
        'pass': codeOk && !outputLeft && !tmpLeft,
        'reason': codeOk && !outputLeft && !tmpLeft
            ? 'pass'
            : 'code=${e.code.name};outputLeft=$outputLeft;tmpLeft=$tmpLeft',
        'message': e.message,
      };
    }
  }

  Future<Map<String, dynamic>> _runExportBusyLane({
    required VGGreenScreenExportRequest first,
    required VGGreenScreenExportRequest second,
  }) async {
    const lane = 'export_busy';
    // Start both without awaiting between them: the platform thread admits
    // the first and must reject the second synchronously with export_busy.
    final firstFuture = _platform.exportGreenScreenComposition(request: first);
    final secondFuture = _platform.exportGreenScreenComposition(
      request: second,
    );

    String secondOutcome;
    try {
      await secondFuture;
      secondOutcome = 'unexpected_success';
    } on VGGreenScreenException catch (e) {
      secondOutcome = e.code == VGGreenScreenErrorCode.exportBusy
          ? 'export_busy'
          : 'wrong_code:${e.code.name}:${e.message}';
    }

    String firstOutcome;
    Map<String, dynamic>? firstResult;
    try {
      final result = await firstFuture;
      firstResult = result.toMap();
      firstOutcome =
          result.terminalState == 'success' &&
              result.renderedFrames == _outputFrameCount &&
              result.renderedEqualsWritten &&
              !result.tmpExists
          ? 'pass'
          : 'first_failed:${result.reason}';
    } on VGGreenScreenException catch (e) {
      firstOutcome = 'first_exception:${e.code.name}:${e.message}';
    }
    final secondOutputLeft = await File(second.outputPath).exists();
    final ok =
        secondOutcome == 'export_busy' &&
        firstOutcome == 'pass' &&
        !secondOutputLeft;
    return <String, dynamic>{
      'lane': lane,
      'pass': ok,
      'reason': ok
          ? 'pass'
          : 'second=$secondOutcome;first=$firstOutcome;'
                'secondOutputLeft=$secondOutputLeft',
      'firstResult': firstResult,
    };
  }

  Future<String> _stageAsset(String assetKey, String destinationPath) async {
    final data = await rootBundle.load(assetKey);
    final file = File(destinationPath);
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('Staged fixture missing or empty: $assetKey');
    }
    return file.path;
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
