// android_duet_export_composition_physical_smoke.dart
// Vanguard Media Engine — Android Duet descriptor-bound offline export
// physical smoke (Slice 5B-A / Slice 4).
//
// Claims:
//   - Descriptor-bound Android offline video-only composited MP4 (synthetic lane).
//   - Real-take export lane with segmentAssets (Slice 4 real-take proof lane).
//   - Source video decode/encode path via AndroidTimelineVideoEncoder.
//   - Synthetic foreground geometry route via AndroidDuetLayoutGeometry.
//   - Slice 3 creator overlay carriage and export integration (TEXT overlay in VGDuetCompositionDescriptor.overlays).
//   - Atomic final output (write to tmp, rename on success).
//   - Selector-driven, vulkan-first Android duet export (render backend
//     must resolve to vulkan for synthetic lane; no silent GLES fallback tolerated here).
//
// Non-claims:
//   - No live camera, no ML/human matte, no iOS.
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
      tmpDir = await Directory.systemTemp.createTemp(
        'android_duet_export_smoke_',
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
    final platform = const MethodChannelVGDuetPlatform();

    // ═════════════════════════════════════════════════════════════════════════
    // LANE 1: Synthetic Export Lane (Slice 5B-A / Slice 3)
    // ═════════════════════════════════════════════════════════════════════════

    // ── 1. Stage synthetic source clip from assets ──────────────────────────
    final syntheticAssetBytes = await rootBundle.load(
      'assets/manual_test_clips/clip_B.mov',
    );
    final syntheticClipFile = File('${tmpDir.path}/clip_B.mov');
    await syntheticClipFile.writeAsBytes(
      syntheticAssetBytes.buffer.asUint8List(),
    );

    _log({
      'lane': 'synthetic',
      'phase': 'synthetic_clip_staged',
      'path': syntheticClipFile.path,
      'size': syntheticClipFile.lengthSync(),
    });

    if (!syntheticClipFile.existsSync() ||
        syntheticClipFile.lengthSync() == 0) {
      throw StateError('clip_B.mov staged but missing or empty.');
    }

    // ── 2. Build greenScreen descriptor with creator overlay (Slice 3) ───────
    final syntheticSource = VGDuetSource.localFile(syntheticClipFile.path);
    final syntheticCreatorOverlay = VGOverlayDescriptor(
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

    final syntheticDescriptor = VGDuetCompositionDescriptor(
      source: syntheticSource,
      layoutConfig: VGDuetLayoutConfig(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
      ),
      trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
      initialSpeed: 1.0,
      segments: [],
      overlays: [syntheticCreatorOverlay],
    );

    _log({
      'lane': 'synthetic',
      'phase': 'synthetic_descriptor_built',
      'source': syntheticSource.filePath,
      'layoutMode': 'greenScreen',
      'fgTransformScale': VGDuetForegroundTransform.creatorOverlay.scale,
      'creatorOverlayCount': syntheticDescriptor.overlays.length,
      'creatorOverlayIds': syntheticDescriptor.overlays
          .map((o) => o.id)
          .toList(),
      'creatorOverlayTypes': syntheticDescriptor.overlays
          .map((o) => o.type.value)
          .toList(),
    });

    // ── 3. Prepare synthetic output path ─────────────────────────────────────
    final syntheticOutputPath = '${tmpDir.path}/duet_export_output.mp4';

    // ── 4. Call public exportDuetComposition for synthetic lane ──────────────
    _log({
      'lane': 'synthetic',
      'phase': 'synthetic_export_start',
      'outputPath': syntheticOutputPath,
      'creatorOverlayCount': syntheticDescriptor.overlays.length,
      'creatorOverlayIds': syntheticDescriptor.overlays
          .map((o) => o.id)
          .toList(),
      'creatorOverlayTypes': syntheticDescriptor.overlays
          .map((o) => o.type.value)
          .toList(),
    });

    final VGDuetExportResult syntheticResult;
    try {
      syntheticResult = await platform.exportDuetComposition(
        descriptor: syntheticDescriptor,
        outputPath: syntheticOutputPath,
        targetSize: const VGDuetSize(1080, 1920),
        videoBitRate: 8000000,
      );
    } on VGDuetException catch (e) {
      _fail({
        'lane': 'synthetic',
        'phase': 'synthetic_export_failed',
        'code': e.code.name,
        'message': e.message,
      });
      return;
    }

    _log({
      'lane': 'synthetic',
      'phase': 'synthetic_export_returned',
      'outputPath': syntheticResult.outputPath,
      'durationMs': syntheticResult.durationMs,
      'fileSizeBytes': syntheticResult.fileSizeBytes,
      'renderBackend': syntheticResult.renderBackend,
      'preferredRenderBackend': syntheticResult.preferredRenderBackend,
      'renderBackendReason': syntheticResult.renderBackendReason,
      'renderBackendFallbackReason':
          syntheticResult.renderBackendFallbackReason,
      'vulkanSupported': syntheticResult.vulkanSupported,
      'glesSupported': syntheticResult.glesSupported,
    });

    // ── 5. Synthetic Lane Assertions ─────────────────────────────────────────
    if (syntheticResult.outputPath != syntheticOutputPath) {
      _fail({
        'lane': 'synthetic',
        'assertion': 'outputPath_mismatch',
        'expected': syntheticOutputPath,
        'got': syntheticResult.outputPath,
      });
      return;
    }

    final syntheticOutFile = File(syntheticResult.outputPath);
    if (!syntheticOutFile.existsSync()) {
      _fail({
        'lane': 'synthetic',
        'assertion': 'output_file_missing',
        'path': syntheticResult.outputPath,
      });
      return;
    }

    final syntheticFileLength = syntheticOutFile.lengthSync();
    if (syntheticFileLength <= 0) {
      _fail({
        'lane': 'synthetic',
        'assertion': 'output_file_empty',
        'path': syntheticResult.outputPath,
      });
      return;
    }

    if (syntheticResult.fileSizeBytes != syntheticFileLength) {
      _fail({
        'lane': 'synthetic',
        'assertion': 'file_size_mismatch',
        'reported': syntheticResult.fileSizeBytes,
        'actual': syntheticFileLength,
      });
      return;
    }

    if (syntheticResult.durationMs <= 0) {
      _fail({
        'lane': 'synthetic',
        'assertion': 'duration_nonpositive',
        'durationMs': syntheticResult.durationMs,
      });
      return;
    }

    final syntheticTmpFile = File('${syntheticResult.outputPath}.tmp');
    if (syntheticTmpFile.existsSync()) {
      _fail({
        'lane': 'synthetic',
        'assertion': 'tmp_file_not_cleaned',
        'tmpPath': syntheticTmpFile.path,
      });
      return;
    }

    if (syntheticResult.renderBackend != 'vulkan') {
      _fail({
        'lane': 'synthetic',
        'assertion': 'render_backend_not_vulkan',
        'renderBackend': syntheticResult.renderBackend,
        'preferredRenderBackend': syntheticResult.preferredRenderBackend,
        'renderBackendReason': syntheticResult.renderBackendReason,
        'renderBackendFallbackReason':
            syntheticResult.renderBackendFallbackReason,
      });
      return;
    }

    _log({
      'lane': 'synthetic',
      'phase': 'synthetic_lane_passed',
      'outputPath': syntheticResult.outputPath,
      'durationMs': syntheticResult.durationMs,
      'fileSizeBytes': syntheticResult.fileSizeBytes,
    });

    // ═════════════════════════════════════════════════════════════════════════
    // LANE 2: Real-Take Export Lane (Slice 4)
    // ═════════════════════════════════════════════════════════════════════════

    // ── 1. Stage real-take assets (source: clip_A.mov, segment: clip_B.mov) ──
    final sourceAssetBytes = await rootBundle.load(
      'assets/manual_test_clips/clip_A.mov',
    );
    final sourceClip = File('${tmpDir.path}/clip_A.mov');
    await sourceClip.writeAsBytes(sourceAssetBytes.buffer.asUint8List());

    final segmentAssetBytes = await rootBundle.load(
      'assets/manual_test_clips/clip_B.mov',
    );
    final segmentClip = File('${tmpDir.path}/clip_B.mov');
    if (!segmentClip.existsSync() || segmentClip.lengthSync() == 0) {
      await segmentClip.writeAsBytes(segmentAssetBytes.buffer.asUint8List());
    }

    if (!sourceClip.existsSync() || sourceClip.lengthSync() == 0) {
      throw StateError('clip_A.mov staged but missing or empty.');
    }
    if (!segmentClip.existsSync() || segmentClip.lengthSync() == 0) {
      throw StateError('clip_B.mov staged but missing or empty.');
    }

    _log({
      'lane': 'real_take',
      'phase': 'real_take_clips_staged',
      'sourceAsset': 'assets/manual_test_clips/clip_A.mov',
      'sourcePath': sourceClip.path,
      'sourceSize': sourceClip.lengthSync(),
      'segmentAsset': 'assets/manual_test_clips/clip_B.mov',
      'segmentPath': segmentClip.path,
      'segmentSize': segmentClip.lengthSync(),
    });

    // ── 2. Build PiP descriptor with creator TEXT overlay (Slice 3 carriage) ──
    final realTakeCreatorOverlay = VGOverlayDescriptor(
      id: 'slice4_real_take_text_overlay',
      type: VGOverlayType.text,
      startTimeSeconds: 0.0,
      durationSeconds: 5.0,
      translationX: 80.0,
      translationY: 160.0,
      width: 350.0,
      height: 100.0,
      rotation: 0.0,
      scale: 1.0,
      opacity: 1.0,
      zIndex: 0,
      textContent: 'SLICE4_REAL_TAKE',
    );

    final realTakeDescriptor = VGDuetCompositionDescriptor(
      source: VGDuetSource.localFile(sourceClip.path),
      layoutConfig: VGDuetLayoutConfig(mode: VGDuetLayoutMode.pip),
      trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
      initialSpeed: 1.0,
      segments: [],
      overlays: [realTakeCreatorOverlay],
    );

    _log({
      'lane': 'real_take',
      'phase': 'real_take_descriptor_built',
      'source': sourceClip.path,
      'layoutMode': 'pip',
      'segmentCount': 1,
      'creatorOverlayCount': realTakeDescriptor.overlays.length,
      'creatorOverlayIds': realTakeDescriptor.overlays
          .map((o) => o.id)
          .toList(),
      'creatorOverlayTypes': realTakeDescriptor.overlays
          .map((o) => o.type.value)
          .toList(),
    });

    // ── 3. Prepare real-take output path ──────────────────────────────────────
    final realTakeOutputPath =
        '${tmpDir.path}/duet_real_take_export_output.mp4';

    // ── 4. Call public exportDuetComposition with segmentAssets ───────────────
    _log({
      'lane': 'real_take',
      'phase': 'real_take_export_start',
      'outputPath': realTakeOutputPath,
      'sourceAsset': 'assets/manual_test_clips/clip_A.mov',
      'segmentAsset': 'assets/manual_test_clips/clip_B.mov',
      'segmentAssets': [segmentClip.path],
      'segmentAssetsCount': 1,
      'layoutMode': 'pip',
      'outputSize': {'width': 1080, 'height': 1920},
      'targetWidth': 1080,
      'targetHeight': 1920,
    });

    final VGDuetExportResult realTakeResult;
    try {
      realTakeResult = await platform.exportDuetComposition(
        descriptor: realTakeDescriptor,
        outputPath: realTakeOutputPath,
        targetSize: const VGDuetSize(1080, 1920),
        videoBitRate: 8000000,
        segmentAssets: [segmentClip.path],
      );
    } on VGDuetException catch (e) {
      _fail({
        'lane': 'real_take',
        'phase': 'real_take_export_failed',
        'code': e.code.name,
        'message': e.message,
      });
      return;
    }

    _log({
      'lane': 'real_take',
      'phase': 'real_take_export_returned',
      'sourceAsset': 'assets/manual_test_clips/clip_A.mov',
      'segmentAsset': 'assets/manual_test_clips/clip_B.mov',
      'sourcePath': sourceClip.path,
      'segmentPath': segmentClip.path,
      'segmentAssets': [segmentClip.path],
      'segmentAssetsCount': 1,
      'layoutMode': 'pip',
      'outputSize': {'width': 1080, 'height': 1920},
      'targetWidth': 1080,
      'targetHeight': 1920,
      'outputPath': realTakeResult.outputPath,
      'durationMs': realTakeResult.durationMs,
      'fileSizeBytes': realTakeResult.fileSizeBytes,
    });

    // ── 5. Real-Take Lane Assertions ──────────────────────────────────────────
    // 5a. returned outputPath matches requested
    if (realTakeResult.outputPath != realTakeOutputPath) {
      _fail({
        'lane': 'real_take',
        'assertion': 'outputPath_mismatch',
        'expected': realTakeOutputPath,
        'got': realTakeResult.outputPath,
      });
      return;
    }

    // 5b. output file exists
    final realTakeOutFile = File(realTakeResult.outputPath);
    if (!realTakeOutFile.existsSync()) {
      _fail({
        'lane': 'real_take',
        'assertion': 'output_file_missing',
        'path': realTakeResult.outputPath,
      });
      return;
    }

    // 5c. size > 0
    final realTakeFileLength = realTakeOutFile.lengthSync();
    if (realTakeFileLength <= 0) {
      _fail({
        'lane': 'real_take',
        'assertion': 'output_file_empty',
        'path': realTakeResult.outputPath,
      });
      return;
    }

    // 5d. durationMs > 0
    if (realTakeResult.durationMs <= 0) {
      _fail({
        'lane': 'real_take',
        'assertion': 'duration_nonpositive',
        'durationMs': realTakeResult.durationMs,
      });
      return;
    }

    // 5e. fileSizeBytes matches actual length
    if (realTakeResult.fileSizeBytes != realTakeFileLength) {
      _fail({
        'lane': 'real_take',
        'assertion': 'file_size_mismatch',
        'reported': realTakeResult.fileSizeBytes,
        'actual': realTakeFileLength,
      });
      return;
    }

    // 5f. .tmp/.video.tmp/.audio.tmp leftovers do not exist
    final realTakeTmpFile = File('$realTakeOutputPath.tmp');
    if (realTakeTmpFile.existsSync()) {
      _fail({
        'lane': 'real_take',
        'assertion': 'tmp_file_not_cleaned',
        'tmpPath': realTakeTmpFile.path,
      });
      return;
    }

    final realTakeVideoTmpFile = File('$realTakeOutputPath.video.tmp');
    if (realTakeVideoTmpFile.existsSync()) {
      _fail({
        'lane': 'real_take',
        'assertion': 'video_tmp_file_not_cleaned',
        'tmpPath': realTakeVideoTmpFile.path,
      });
      return;
    }

    final realTakeAudioTmpFile = File('$realTakeOutputPath.audio.tmp');
    if (realTakeAudioTmpFile.existsSync()) {
      _fail({
        'lane': 'real_take',
        'assertion': 'audio_tmp_file_not_cleaned',
        'tmpPath': realTakeAudioTmpFile.path,
      });
      return;
    }

    _log({
      'lane': 'real_take',
      'phase': 'real_take_lane_passed',
      'sourceAsset': 'assets/manual_test_clips/clip_A.mov',
      'segmentAsset': 'assets/manual_test_clips/clip_B.mov',
      'sourcePath': sourceClip.path,
      'segmentPath': segmentClip.path,
      'segmentAssets': [segmentClip.path],
      'segmentAssetsCount': 1,
      'layoutMode': 'pip',
      'outputSize': {'width': 1080, 'height': 1920},
      'targetWidth': 1080,
      'targetHeight': 1920,
      'outputPath': realTakeResult.outputPath,
      'durationMs': realTakeResult.durationMs,
      'fileSizeBytes': realTakeResult.fileSizeBytes,
    });

    // ═════════════════════════════════════════════════════════════════════════
    // PASS: Both lanes complete
    // ═════════════════════════════════════════════════════════════════════════
    final passPayload = <String, dynamic>{
      'verdict': 'PASS',
      'outputPath': realTakeResult.outputPath,
      'durationMs': realTakeResult.durationMs,
      'fileSizeBytes': realTakeResult.fileSizeBytes,
      'renderBackend': syntheticResult.renderBackend,
      'preferredRenderBackend': syntheticResult.preferredRenderBackend,
      'renderBackendReason': syntheticResult.renderBackendReason,
      'renderBackendFallbackReason':
          syntheticResult.renderBackendFallbackReason,
      'vulkanSupported': syntheticResult.vulkanSupported,
      'glesSupported': syntheticResult.glesSupported,
      'lanes': {
        'synthetic': {
          'lane': 'synthetic',
          'outputPath': syntheticResult.outputPath,
          'durationMs': syntheticResult.durationMs,
          'fileSizeBytes': syntheticResult.fileSizeBytes,
          'renderBackend': syntheticResult.renderBackend,
          'preferredRenderBackend': syntheticResult.preferredRenderBackend,
          'renderBackendReason': syntheticResult.renderBackendReason,
          'renderBackendFallbackReason':
              syntheticResult.renderBackendFallbackReason,
          'vulkanSupported': syntheticResult.vulkanSupported,
          'glesSupported': syntheticResult.glesSupported,
          'creatorOverlayCount': syntheticDescriptor.overlays.length,
          'creatorOverlayIds': syntheticDescriptor.overlays
              .map((o) => o.id)
              .toList(),
          'creatorOverlayTypes': syntheticDescriptor.overlays
              .map((o) => o.type.value)
              .toList(),
        },
        'real_take': {
          'lane': 'real_take',
          'sourceAsset': 'assets/manual_test_clips/clip_A.mov',
          'segmentAsset': 'assets/manual_test_clips/clip_B.mov',
          'sourcePath': sourceClip.path,
          'segmentPath': segmentClip.path,
          'segmentAssets': [segmentClip.path],
          'segmentAssetsCount': 1,
          'layoutMode': 'pip',
          'outputSize': {'width': 1080, 'height': 1920},
          'targetWidth': 1080,
          'targetHeight': 1920,
          'outputPath': realTakeResult.outputPath,
          'durationMs': realTakeResult.durationMs,
          'fileSizeBytes': realTakeResult.fileSizeBytes,
          'creatorOverlayCount': realTakeDescriptor.overlays.length,
          'creatorOverlayIds': realTakeDescriptor.overlays
              .map((o) => o.id)
              .toList(),
          'creatorOverlayTypes': realTakeDescriptor.overlays
              .map((o) => o.type.value)
              .toList(),
        },
      },
      'claims': [
        'descriptor_bound_android_offline_video_only_composited_mp4',
        'source_video_decode_encode_path',
        'synthetic_foreground_geometry_route',
        'slice3_creator_overlay_descriptor_carriage_and_native_export_route',
        'slice4_real_take_export_route_with_segment_assets',
        'atomic_final_output',
        'selector_driven_vulkan_first_android_duet_export',
      ],
      'nonClaims': [
        'no_live_camera',
        'no_ml_human_matte',
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
          'PASS — both lanes complete (synthetic: ${syntheticResult.durationMs}ms, ${syntheticResult.fileSizeBytes} bytes; real_take: ${realTakeResult.durationMs}ms, ${realTakeResult.fileSizeBytes} bytes)',
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
