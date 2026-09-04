// android_multicam_spatial_gles_oes_render_physical_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: Android
// True-DAG Phase 3 GLES-first spatial multi-texture diagnostic render pass
// OES physical proof harness.
//
// Route:
//   startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke /
//   disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke /
//   onAndroidDagPhase3MultiCamSpatialGlesOesRenderSmokeComplete.
//
// Dart responsibilities:
//   - Print ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_SMOKE_START.
//   - Start the smoke with width=128, height=128.
//   - Mount Texture(textureId) once start returns.
//   - Await completion callback with bounded timeout.
//   - Print per-lane diagnostic logs.
//   - Always dispose in finally; require surfaceProducerReleased == true for PASS.
//   - Print ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_JSON:<json>
//   - Print ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_SMOKE_PASS/FAIL.
//   - Exit 0 on PASS, 1 on FAIL after a short delay.
//
// Non-claims: diagnostic render only; no camera open, no Vulkan, no opacity,
// no corner radius, no recording, no export, no product/editor UI. OES lanes
// assert render/readback success and resolved texture target only -- never
// deterministic color content for the never-CPU-filled YCBCR buffers.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiCamSpatialGlesOesRenderPhysicalSmokeApp());
}

class AndroidMultiCamSpatialGlesOesRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidMultiCamSpatialGlesOesRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiCamSpatialGlesOesRenderPhysicalSmokeApp> createState() =>
      _AndroidMultiCamSpatialGlesOesRenderPhysicalSmokeAppState();
}

class _AndroidMultiCamSpatialGlesOesRenderPhysicalSmokeAppState
    extends State<AndroidMultiCamSpatialGlesOesRenderPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase3MultiCamSpatialGlesOesRenderSmokeComplete';
  static const _width = 128;
  static const _height = 128;

  String _status =
      'Running Android DAG Phase 3 MultiCam spatial GLES OES render smoke...';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_SMOKE_START');

    int? activeTextureId;
    var startPayload = <String, dynamic>{};
    var completionPayload = <String, dynamic>{};
    var disposePayload = <String, dynamic>{};
    var completionReached = false;
    var disposeReleased = false;

    final completer = Completer<Map<String, dynamic>>();

    _channel.setMethodCallHandler((call) async {
      if (call.method == _completeMethod) {
        if (!completer.isCompleted) {
          final args = call.arguments;
          completer.complete(
            args is Map ? Map<String, dynamic>.from(args) : <String, dynamic>{},
          );
        }
      }
    });

    try {
      final startResult =
          await VGMultiCamSpatialGlesOesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
            width: _width,
            height: _height,
            channel: _channel,
          );

      activeTextureId = startResult.textureId;
      startPayload = <String, dynamic>{
        'textureId': activeTextureId,
        'width': startResult.width,
        'height': startResult.height,
      };

      if (mounted && activeTextureId >= 0) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Rendering Android DAG Phase 3 spatial GLES OES smoke (textureId=$activeTextureId)...';
        });
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 20),
      );
      completionReached = true;
    } catch (error, stack) {
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_ERROR: $error\n$stack',
      );
      completionPayload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;lastError=dart_invoke_exception',
        'textureId': activeTextureId ?? -1,
        'width': _width,
        'height': _height,
        'proofBoundary':
            VGMultiCamSpatialGlesOesRenderSmokeReport.proofBoundaryConstant,
        'surfaceProducerReleased': false,
        'lastError': 'dart_invoke_exception',
        'metrics': const <String, String>{'reason': 'dart_invoke_exception'},
      };
    } finally {
      _channel.setMethodCallHandler(null);
      if (activeTextureId != null && activeTextureId >= 0) {
        try {
          disposeReleased =
              await VGMultiCamSpatialGlesOesRenderSmokeReport.disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
                textureId: activeTextureId,
                channel: _channel,
              );
          disposePayload = <String, dynamic>{
            'textureId': activeTextureId,
            'surfaceProducerReleased': disposeReleased,
          };
        } catch (e) {
          disposePayload = <String, dynamic>{
            'textureId': activeTextureId,
            'surfaceProducerReleased': false,
            'error': e.toString(),
          };
        }
      }
    }

    final report = VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap(
      completionPayload,
    );

    // Print per-lane diagnostic logs
    print(
      '  [LANE] Setup/Import: rgbaADescribe=${report.rgbaADescribePass}, '
      'rgbaAFill=${report.rgbaAFillPass}, rgbaBDescribe=${report.rgbaBDescribePass}, '
      'rgbaBFill=${report.rgbaBFillPass}, ycbcrADescribe=${report.ycbcrADescribePass}, '
      'ycbcrAFormat420888=${report.ycbcrAFormatIs420888}, ycbcrBDescribe=${report.ycbcrBDescribePass}, '
      'ycbcrBFormat420888=${report.ycbcrBFormatIs420888}, preInit=${report.preInitLanePass}, '
      'init=${report.initializePass}, attach=${report.attachPass}, '
      'importRgbaA=${report.importRgbaAPass}, importRgbaB=${report.importRgbaBPass}, '
      'importYcbcrA=${report.importYcbcrAPass}, importYcbcrB=${report.importYcbcrBPass}',
    );
    print(
      '  [LANE] Error Rejection: invalidHandle=${report.invalidHandleLanePass}, '
      'invalidRect=${report.invalidRectLanePass}',
    );
    print(
      '  [LANE] OES Spatial Layouts: twoDOes=${report.twoDOesPass}, '
      'oesTwoD=${report.oesTwoDPass}, oesOes=${report.oesOesPass}, '
      'present=${report.presentOesOesPass}',
    );
    print(
      '  [LANE] Release/Teardown: releaseRgbaA=${report.releaseRgbaAPass}, '
      'releaseRgbaB=${report.releaseRgbaBPass}, releaseYcbcrA=${report.releaseYcbcrAPass}, '
      'releaseYcbcrB=${report.releaseYcbcrBPass}, hasRgbaAAfterRelease=${report.hasRgbaAAfterReleasePass}, '
      'hasRgbaBAfterRelease=${report.hasRgbaBAfterReleasePass}, hasYcbcrAAfterRelease=${report.hasYcbcrAAfterReleasePass}, '
      'hasYcbcrBAfterRelease=${report.hasYcbcrBAfterReleasePass}, postRelease=${report.postReleaseLanePass}, '
      'detach=${report.detachPass}, shutdown=${report.shutdownPass}, '
      'idempotentShutdown=${report.idempotentShutdownPass}',
    );
    print(
      '  [LANE] Proof Boundary: canonical=${report.hasCanonicalProofBoundary}',
    );
    print('  [LANE] SurfaceProducer Dispose: released=$disposeReleased');

    final lastErrorOk = report.lastError.isEmpty || report.lastError == 'none';

    final completionOk =
        completionReached &&
        report.pass &&
        report.textureId >= 0 &&
        report.textureId == activeTextureId &&
        report.hasCanonicalProofBoundary &&
        report.allNativeLanesPass &&
        lastErrorOk;

    final pass = completionOk && disposeReleased;

    final summaryReport = <String, dynamic>{
      'start': startPayload,
      'completion': report.toMap(),
      'dispose': disposePayload,
      'pass': pass,
    };

    print(
      'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_JSON:${jsonEncode(summaryReport)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (allNativeLanesPass=true, disposeReleased=true)'
            : 'FAIL: lastError=${report.lastError}, raw=${report.raw}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_textureId != null && _textureId! >= 0)
                SizedBox(
                  width: _width.toDouble(),
                  height: _height.toDouble(),
                  child: Texture(textureId: _textureId!),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_status, textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
