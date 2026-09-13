// android_duet_export_static_background_fail_closed_physical_smoke.dart
// Vanguard Media Engine — Android Duet export static background fail-closed
// physical smoke harness.
//
// Proves that offline Duet export on Android fails closed with
// "unsupported_export_feature" when configured with unsupported static/image
// green-screen backgrounds (both solidColor and image backgrounds).
//
// Claims:
//   - android_export_static_green_screen_background_fail_closed
//   - solid_color_rejected
//   - image_rejected
//   - no_final_or_tmp_output_on_rejection
//
// Non-claims:
//   - no successful static/image export
//   - no rendered pixel proof
//   - no live camera
//   - no ML matte
//   - no iOS
//   - no ConnectsApp wiring

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vanguard_media_engine/vg_duet.dart';

// ── Structured log markers ────────────────────────────────────────────────────

const String kStartMarker =
    'ANDROID_DUET_EXPORT_STATIC_BACKGROUND_FAIL_CLOSED_SMOKE_START';
const String kPassMarker =
    'ANDROID_DUET_EXPORT_STATIC_BACKGROUND_FAIL_CLOSED_PHYSICAL_PASS';
const String kFailMarker =
    'ANDROID_DUET_EXPORT_STATIC_BACKGROUND_FAIL_CLOSED_PHYSICAL_FAIL';
const String kJsonPrefix =
    'ANDROID_DUET_EXPORT_STATIC_BACKGROUND_FAIL_CLOSED_JSON:';

// ── Entry point ───────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetExportStaticBackgroundFailClosedSmokeApp());
}

class AndroidDuetExportStaticBackgroundFailClosedSmokeApp
    extends StatelessWidget {
  const AndroidDuetExportStaticBackgroundFailClosedSmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: AndroidDuetExportStaticBackgroundFailClosedSmokePage(),
    );
  }
}

class AndroidDuetExportStaticBackgroundFailClosedSmokePage
    extends StatefulWidget {
  const AndroidDuetExportStaticBackgroundFailClosedSmokePage({super.key});

  @override
  State<AndroidDuetExportStaticBackgroundFailClosedSmokePage> createState() =>
      _AndroidDuetExportStaticBackgroundFailClosedSmokePageState();
}

class _AndroidDuetExportStaticBackgroundFailClosedSmokePageState
    extends State<AndroidDuetExportStaticBackgroundFailClosedSmokePage> {
  String _status = 'Idle';
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duet Export Static Background Fail-Closed Smoke'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(_status, textAlign: TextAlign.center),
        ),
      ),
    );
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    setState(() => _status = 'Running…');

    print(kStartMarker);
    print(
      '$kJsonPrefix${json.encode({'phase': 'start', 'ts': DateTime.now().toIso8601String()})}',
    );

    Directory? tmpDir;
    try {
      tmpDir = await Directory.systemTemp.createTemp(
        'duet_export_static_bg_fail_closed_',
      );
      await _runSmoke(tmpDir);
    } catch (e, st) {
      _fail({'error': '$e', 'stack': '$st'});
    } finally {
      // cleanup
      try {
        tmpDir?.deleteSync(recursive: true);
      } catch (_) {}
      _running = false;
    }
  }

  Future<void> _runSmoke(Directory tmpDir) async {
    // ── 1. Stage source clip from assets ─────────────────────────────────────
    final assetBytes = await rootBundle.load(
      'assets/manual_test_clips/clip_B.mov',
    );
    final clipFile = File('${tmpDir.path}/clip_B.mov');
    await clipFile.writeAsBytes(assetBytes.buffer.asUint8List());

    _log({
      'phase': 'clip_staged',
      'path': clipFile.path,
      'size': clipFile.lengthSync(),
    });

    if (!clipFile.existsSync() || clipFile.lengthSync() == 0) {
      throw StateError('clip_B.mov staged but missing or empty.');
    }

    // ── 2. Create tiny local PNG in temp dir ──────────────────────────────────
    final imageFile = File('${tmpDir.path}/tiny_sample.png');
    const minimalPng = <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ];
    await imageFile.writeAsBytes(minimalPng);

    _log({
      'phase': 'image_staged',
      'path': imageFile.path,
      'size': imageFile.lengthSync(),
    });

    if (!imageFile.existsSync() || imageFile.lengthSync() == 0) {
      throw StateError('tiny_sample.png created but missing or empty.');
    }

    // ── 3. Build two descriptors ─────────────────────────────────────────────
    final source = VGDuetSource.localFile(clipFile.path);

    // Lane 1: solidColor background
    final solidColorDescriptor = VGDuetCompositionDescriptor(
      source: source,
      layoutConfig: VGDuetLayoutConfig(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
        greenScreenBackground: const VGDuetGreenScreenBackground.solidColor(
          0xFF00AA66,
        ),
      ),
      trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
      initialSpeed: 1.0,
      segments: const [],
    );

    // Lane 2: image background
    final imageDescriptor = VGDuetCompositionDescriptor(
      source: source,
      layoutConfig: VGDuetLayoutConfig(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
        greenScreenBackground: VGDuetGreenScreenBackground.imageFile(
          imageFile.path,
          scaleMode: VGDuetBackgroundScaleMode.aspectFill,
        ),
      ),
      trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
      initialSpeed: 1.0,
      segments: const [],
    );

    const platform = MethodChannelVGDuetPlatform();

    // ── 4. Execute Lane 1: solidColor ────────────────────────────────────────
    final solidColorOutputPath = '${tmpDir.path}/duet_export_solid_color.mp4';
    final solidColorReport = await _runLane(
      platform: platform,
      laneId: 'solid_color',
      backgroundType: 'solidColor',
      descriptor: solidColorDescriptor,
      outputPath: solidColorOutputPath,
    );

    // ── 5. Execute Lane 2: image ─────────────────────────────────────────────
    final imageOutputPath = '${tmpDir.path}/duet_export_image.mp4';
    final imageReport = await _runLane(
      platform: platform,
      laneId: 'image',
      backgroundType: 'image',
      descriptor: imageDescriptor,
      outputPath: imageOutputPath,
    );

    // ── 6. Pass ───────────────────────────────────────────────────────────────
    final passPayload = <String, dynamic>{
      'verdict': 'PASS',
      'proofBoundary':
          'android_duet_export_static_background_fail_closed_physical_smoke',
      'lanes': [solidColorReport, imageReport],
      'claims': <String>[
        'android_export_static_green_screen_background_fail_closed',
        'solid_color_rejected',
        'image_rejected',
        'no_final_or_tmp_output_on_rejection',
      ],
      'nonClaims': <String>[
        'no successful static/image export',
        'no rendered pixel proof',
        'no live camera',
        'no ML matte',
        'no iOS',
        'no ConnectsApp wiring',
      ],
    };

    print('$kJsonPrefix${json.encode(passPayload)}');
    print(kPassMarker);
    setState(
      () => _status =
          'PASS — Android Duet export failed closed for static/image backgrounds',
    );
  }

  Future<Map<String, dynamic>> _runLane({
    required VGDuetPlatformInterface platform,
    required String laneId,
    required String backgroundType,
    required VGDuetCompositionDescriptor descriptor,
    required String outputPath,
  }) async {
    _log({
      'phase': 'lane_start',
      'laneId': laneId,
      'backgroundType': backgroundType,
      'outputPath': outputPath,
    });

    const expectedNativeCode = 'unsupported_export_feature';
    String? actualTopLevelVGDuetCode;
    String? actualPlatformExceptionCode;
    String? actualPlatformExceptionMessage;
    String? failureReason;
    bool caughtExpectedException = false;

    try {
      final result = await platform.exportDuetComposition(
        descriptor: descriptor,
        outputPath: outputPath,
        targetSize: const VGDuetSize(1080, 1920),
        videoBitRate: 8000000,
      );
      failureReason =
          'export_unexpectedly_succeeded: produced output at ${result.outputPath}';
    } on VGDuetException catch (e) {
      actualTopLevelVGDuetCode = e.code.name;
      final cause = e.cause;
      if (cause is PlatformException) {
        actualPlatformExceptionCode = cause.code;
        actualPlatformExceptionMessage = cause.message;
        if (e.code == VGDuetErrorCode.compositionFailed &&
            cause.code == expectedNativeCode) {
          caughtExpectedException = true;
        } else {
          failureReason =
              'unexpected_exception_codes: vgDuetCode=${e.code.name} '
              '(expected ${VGDuetErrorCode.compositionFailed.name}), '
              'platformCode=${cause.code} (expected $expectedNativeCode), '
              'message=${cause.message}';
        }
      } else {
        failureReason =
            'cause_not_platform_exception: vgDuetCode=${e.code.name}, '
            'message=${e.message}, cause=$cause';
      }
    } catch (e, st) {
      failureReason = 'unexpected_exception_type: $e (stack: $st)';
    }

    final outputExists = File(outputPath).existsSync();
    final tmpExists = File('$outputPath.tmp').existsSync();

    if (caughtExpectedException) {
      if (outputExists) {
        failureReason = 'output_file_exists_after_rejection: $outputPath';
      } else if (tmpExists) {
        failureReason = 'tmp_file_exists_after_rejection: $outputPath.tmp';
      }
    }

    final lanePassed = caughtExpectedException && !outputExists && !tmpExists;

    final laneReport = <String, dynamic>{
      'laneId': laneId,
      'backgroundType': backgroundType,
      'phase': 'lane_result',
      'result': lanePassed ? 'REJECTED_AS_EXPECTED' : 'FAIL',
      'expectedNativeCode': expectedNativeCode,
      'actualTopLevelVGDuetCode': actualTopLevelVGDuetCode,
      'actualPlatformExceptionCode': actualPlatformExceptionCode,
      'actualPlatformExceptionMessage': actualPlatformExceptionMessage,
      'outputExists': outputExists,
      'tmpExists': tmpExists,
      'failureReason': ?failureReason,
    };

    _log(laneReport);

    if (!lanePassed) {
      throw StateError('Lane $laneId failed: $failureReason');
    }

    return laneReport;
  }

  void _log(Map<String, dynamic> payload) {
    print('$kJsonPrefix${json.encode(payload)}');
  }

  void _fail(Map<String, dynamic> payload) {
    final failPayload = <String, dynamic>{'verdict': 'FAIL', ...payload};
    print('$kJsonPrefix${json.encode(failPayload)}');
    print(kFailMarker);
    setState(() => _status = 'FAIL — ${json.encode(payload)}');
  }
}
