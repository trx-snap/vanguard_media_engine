// ios_duet_export_composition_physical_smoke.dart
// Vanguard Media Engine — iOS Duet descriptor-bound offline export
// physical smoke (Slice 5B-A).
//
// Claims:
//   - Descriptor-bound iOS offline video-only composited MP4.
//   - Source video decode/encode path via VGTimelineExportHelper.
//   - Synthetic foreground geometry route via VGDuetLayoutGeometry.
//   - Atomic final output (write to tmp, rename on success).
//
// Non-claims:
//   - No live camera, no ML/human matte, no audio/mic/sync, no Android.
//   - No ConnectsApp/Universal Editor/upload/backend wiring.
//   - No rendered pixel assertion (synthetic foreground is magenta rectangle).
//   - No low-end iOS or device matrix proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vanguard_media_engine/vg_duet.dart';

// ── Structured log markers ────────────────────────────────────────────────────

const String kStartMarker = 'IOS_DUET_EXPORT_COMPOSITION_SMOKE_START';
const String kPassMarker  = 'IOS_DUET_EXPORT_COMPOSITION_PHYSICAL_PASS';
const String kFailMarker  = 'IOS_DUET_EXPORT_COMPOSITION_PHYSICAL_FAIL';
const String kJsonPrefix  = 'IOS_DUET_EXPORT_COMPOSITION_JSON:';

// ── Entry point ───────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IosDuetExportCompositionSmokeApp());
}

class IosDuetExportCompositionSmokeApp extends StatelessWidget {
  const IosDuetExportCompositionSmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: IosDuetExportCompositionSmokePage());
  }
}

class IosDuetExportCompositionSmokePage extends StatefulWidget {
  const IosDuetExportCompositionSmokePage({super.key});

  @override
  State<IosDuetExportCompositionSmokePage> createState() =>
      _IosDuetExportCompositionSmokePageState();
}

class _IosDuetExportCompositionSmokePageState
    extends State<IosDuetExportCompositionSmokePage> {
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
      appBar: AppBar(title: const Text('iOS Duet Export Composition Smoke')),
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
      tmpDir = await Directory.systemTemp.createTemp('ios_duet_export_smoke_');
      await _runSmoke(tmpDir);
    } catch (e, st) {
      _fail({'error': '$e', 'stack': '$st'});
    } finally {
      // Cleanup temp dir in all terminal paths.
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

    // ── 2. Build greenScreen descriptor ──────────────────────────────────────
    final source = VGDuetSource.localFile(clipFile.path);
    final descriptor = VGDuetCompositionDescriptor(
      source: source,
      layoutConfig: VGDuetLayoutConfig(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
      ),
      trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
      initialSpeed: 1.0,
      segments: [],
    );

    _log({
      'phase': 'descriptor_built',
      'source': source.filePath,
      'layoutMode': 'greenScreen',
      'fgTransformScale': VGDuetForegroundTransform.creatorOverlay.scale,
    });

    // ── 3. Prepare output path ────────────────────────────────────────────────
    final outputPath = '${tmpDir.path}/duet_export_output.mp4';

    // ── 4. Call public exportDuetComposition ─────────────────────────────────
    _log({'phase': 'export_start', 'outputPath': outputPath});

    final platform = const MethodChannelVGDuetPlatform();
    final VGDuetExportResult result;
    try {
      result = await platform.exportDuetComposition(
        descriptor: descriptor,
        outputPath: outputPath,
        targetSize: const VGDuetSize(1080, 1920),
        videoBitRate: 8000000,
      );
    } on VGDuetException catch (e) {
      _fail({
        'phase': 'export_failed',
        'code': e.code.name,
        'message': e.message,
      });
      return;
    }

    _log({
      'phase': 'export_returned',
      'outputPath': result.outputPath,
      'durationMs': result.durationMs,
      'fileSizeBytes': result.fileSizeBytes,
    });

    // ── 5. Assertions ─────────────────────────────────────────────────────────

    // 5a. returned path matches requested path
    if (result.outputPath != outputPath) {
      _fail({
        'assertion': 'outputPath_mismatch',
        'expected': outputPath,
        'got': result.outputPath,
      });
      return;
    }

    // 5b. output file exists
    final outFile = File(result.outputPath);
    if (!outFile.existsSync()) {
      _fail({'assertion': 'output_file_missing', 'path': result.outputPath});
      return;
    }

    // 5c. size > 0
    final fileLength = outFile.lengthSync();
    if (fileLength <= 0) {
      _fail({'assertion': 'output_file_empty', 'path': result.outputPath});
      return;
    }

    // 5d. fileSizeBytes matches actual file length
    if (result.fileSizeBytes != fileLength) {
      _fail({
        'assertion': 'file_size_mismatch',
        'reported': result.fileSizeBytes,
        'actual': fileLength,
      });
      return;
    }

    // 5e. durationMs > 0
    if (result.durationMs <= 0) {
      _fail({
        'assertion': 'duration_nonpositive',
        'durationMs': result.durationMs,
      });
      return;
    }

    // 5f. tmp file must NOT exist (atomic cleanup)
    final tmpOutputFile = File('${result.outputPath}.tmp');
    if (tmpOutputFile.existsSync()) {
      _fail({
        'assertion': 'tmp_file_not_cleaned',
        'tmpPath': tmpOutputFile.path,
      });
      return;
    }

    // ── 6. Pass ───────────────────────────────────────────────────────────────
    final passPayload = <String, dynamic>{
      'verdict': 'PASS',
      'outputPath': result.outputPath,
      'durationMs': result.durationMs,
      'fileSizeBytes': result.fileSizeBytes,
      'claims': [
        'descriptor_bound_ios_offline_video_only_composited_mp4',
        'source_video_decode_encode_path',
        'synthetic_foreground_geometry_route',
        'atomic_final_output',
      ],
      'nonClaims': [
        'no_live_camera',
        'no_ml_human_matte',
        'no_audio_mic_sync',
        'no_android',
        'no_connects_app_wiring',
        'no_rendered_pixel_assertion',
        'no_low_end_ios_or_device_matrix_proof',
      ],
    };
    print('$kJsonPrefix${json.encode(passPayload)}');
    print(kPassMarker);
    setState(
      () => _status =
          'PASS — ${result.durationMs}ms, ${result.fileSizeBytes} bytes',
    );
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
