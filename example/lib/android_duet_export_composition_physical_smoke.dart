// android_duet_export_composition_physical_smoke.dart
// Vanguard Media Engine — Android Duet descriptor-bound offline export
// physical smoke (Slice 5B-A).
//
// Claims:
//   - Descriptor-bound Android offline video-only composited MP4.
//   - Source video decode/encode path via AndroidTimelineVideoEncoder.
//   - Synthetic foreground geometry route via AndroidDuetLayoutGeometry.
//   - Slice 3 creator overlay carriage and export integration (TEXT overlay in VGDuetCompositionDescriptor.overlays).
//   - Atomic final output (write to tmp, rename on success).
//   - Selector-driven, vulkan-first Android duet export (render backend
//     must resolve to vulkan; no silent GLES fallback tolerated here).
//
// Non-claims:
//   - No live camera, no ML/human matte, no audio/mic/sync, no iOS.
//   - No ConnectsApp/Universal Editor/upload/backend wiring.
//   - No rendered pixel assertion (synthetic foreground is magenta rectangle; creator overlay verified through descriptor carriage and native export completion without automated pixel sampling).
//   - No low-end Android proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vanguard_media_engine/vg_duet.dart';
import 'package:vanguard_media_engine/vg_overlay_descriptor.dart';

// ── Structured log markers ────────────────────────────────────────────────────

const String kStartMarker = 'ANDROID_DUET_EXPORT_COMPOSITION_SMOKE_START';
const String kPassMarker = 'ANDROID_DUET_EXPORT_COMPOSITION_PHYSICAL_PASS';
const String kFailMarker = 'ANDROID_DUET_EXPORT_COMPOSITION_PHYSICAL_FAIL';
const String kJsonPrefix = 'ANDROID_DUET_EXPORT_COMPOSITION_JSON:';

// ── Entry point ───────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetExportCompositionSmokeApp());
}

class AndroidDuetExportCompositionSmokeApp extends StatelessWidget {
  const AndroidDuetExportCompositionSmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: AndroidDuetExportCompositionSmokePage());
  }
}

class AndroidDuetExportCompositionSmokePage extends StatefulWidget {
  const AndroidDuetExportCompositionSmokePage({super.key});

  @override
  State<AndroidDuetExportCompositionSmokePage> createState() =>
      _AndroidDuetExportCompositionSmokePageState();
}

class _AndroidDuetExportCompositionSmokePageState
    extends State<AndroidDuetExportCompositionSmokePage> {
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
      appBar: AppBar(title: const Text('Duet Export Composition Smoke')),
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
      tmpDir = await Directory.systemTemp.createTemp('duet_export_smoke_');
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

    // ── 2. Build greenScreen descriptor with creator overlay (Slice 3) ───────
    final source = VGDuetSource.localFile(clipFile.path);
    final creatorOverlay = VGOverlayDescriptor(
      id: 'slice3_creator_overlay_1',
      type: VGOverlayType.text,
      startTimeSeconds: 0.0,
      durationSeconds: 5.0,
      translationX: 100.0,
      translationY: 200.0,
      width: 400.0,
      height: 120.0,
      rotation: 0.0,
      scale: 1.0,
      opacity: 1.0,
      zIndex: 0,
      textContent: 'SLICE3',
    );

    final descriptor = VGDuetCompositionDescriptor(
      source: source,
      layoutConfig: VGDuetLayoutConfig(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
      ),
      trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
      initialSpeed: 1.0,
      segments: [],
      overlays: [creatorOverlay],
    );

    _log({
      'phase': 'descriptor_built',
      'source': source.filePath,
      'layoutMode': 'greenScreen',
      'fgTransformScale': VGDuetForegroundTransform.creatorOverlay.scale,
      'creatorOverlayCount': descriptor.overlays.length,
      'creatorOverlayIds': descriptor.overlays.map((o) => o.id).toList(),
      'creatorOverlayTypes': descriptor.overlays
          .map((o) => o.type.value)
          .toList(),
    });

    // ── 3. Prepare output path ────────────────────────────────────────────────
    final outputPath = '${tmpDir.path}/duet_export_output.mp4';

    // ── 4. Call public exportDuetComposition ─────────────────────────────────
    _log({
      'phase': 'export_start',
      'outputPath': outputPath,
      'creatorOverlayCount': descriptor.overlays.length,
      'creatorOverlayIds': descriptor.overlays.map((o) => o.id).toList(),
      'creatorOverlayTypes': descriptor.overlays
          .map((o) => o.type.value)
          .toList(),
    });

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
      'renderBackend': result.renderBackend,
      'preferredRenderBackend': result.preferredRenderBackend,
      'renderBackendReason': result.renderBackendReason,
      'renderBackendFallbackReason': result.renderBackendFallbackReason,
      'vulkanSupported': result.vulkanSupported,
      'glesSupported': result.glesSupported,
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

    // 5g. render backend must be vulkan (selector-driven, vulkan-first route)
    if (result.renderBackend != 'vulkan') {
      _fail({
        'assertion': 'render_backend_not_vulkan',
        'renderBackend': result.renderBackend,
        'preferredRenderBackend': result.preferredRenderBackend,
        'renderBackendReason': result.renderBackendReason,
        'renderBackendFallbackReason': result.renderBackendFallbackReason,
      });
      return;
    }

    // ── 6. Pass ───────────────────────────────────────────────────────────────
    final passPayload = <String, dynamic>{
      'verdict': 'PASS',
      'outputPath': result.outputPath,
      'durationMs': result.durationMs,
      'fileSizeBytes': result.fileSizeBytes,
      'renderBackend': result.renderBackend,
      'preferredRenderBackend': result.preferredRenderBackend,
      'renderBackendReason': result.renderBackendReason,
      'renderBackendFallbackReason': result.renderBackendFallbackReason,
      'vulkanSupported': result.vulkanSupported,
      'glesSupported': result.glesSupported,
      'creatorOverlayCount': descriptor.overlays.length,
      'creatorOverlayIds': descriptor.overlays.map((o) => o.id).toList(),
      'creatorOverlayTypes': descriptor.overlays
          .map((o) => o.type.value)
          .toList(),
      'claims': [
        'descriptor_bound_android_offline_video_only_composited_mp4',
        'source_video_decode_encode_path',
        'synthetic_foreground_geometry_route',
        'slice3_creator_overlay_descriptor_carriage_and_native_export_route',
        'atomic_final_output',
        'selector_driven_vulkan_first_android_duet_export',
      ],
      'nonClaims': [
        'no_live_camera',
        'no_ml_human_matte',
        'no_audio_mic_sync',
        'no_ios',
        'no_connects_app_wiring',
        'no_rendered_pixel_assertion',
        'no_low_end_android_proof',
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
