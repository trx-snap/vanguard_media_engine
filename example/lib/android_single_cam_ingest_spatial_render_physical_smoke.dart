// android_single_cam_ingest_spatial_render_physical_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-
// SPATIAL-RENDER: Android True-DAG Phase 3 physical proof that one real
// Camera2 ImageReader(YUV_420_888) buffer-queue frame plus one synthetic
// RGBA_8888 HardwareBuffer are laid out by a caller-supplied Dart layout
// descriptor through native ComputeMultiCamLayout(), rendered by the
// existing GLES/OES spatial compositor, structurally read back, and
// presented to a Flutter SurfaceProducer.
//
// Route:
//   startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke /
//   disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke /
//   onAndroidDagPhase3SingleCamIngestSpatialRenderSmokeComplete.
//
// Dart responsibilities:
//   - Print ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_SMOKE_START.
//   - Sequentially run three lanes (never concurrent -- each is a full
//     start -> complete -> dispose cycle before the next begins):
//       1. freeFloatingPip: real camera frame (OES primary) + synthetic PiP
//          box (RGBA secondary, solid blue).
//       2. leftRightSplit: real camera frame (OES primary, left/right half)
//          + synthetic RGBA secondary (solid blue, the other half).
//       3. malformedUnknownLayoutMode: a well-typed but unrecognized
//          `layoutMode` value -- the camera still fully opens/captures a
//          frame, but native's strict descriptor resolver rejects it before
//          any AHardwareBuffer import or GLES work, expected to fail closed.
//   - Print explicit setup/permission/open/session/frame/import/render/
//     present/teardown/dispose diagnostics per lane.
//   - Mount Texture(textureId) while each lane runs.
//   - Always dispose each lane in finally; require surfaceProducerReleased.
//   - If a positive lane reports decision=cameraIngestUnsupported (this
//     device/format cannot import its camera's YUV_420_888 buffer as
//     GL_TEXTURE_EXTERNAL_OES), print a clear BLOCKED diagnostic and do NOT
//     report the overall run as PASS.
//   - Print ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_JSON:<json>
//   - Print ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_PASS only
//     when both positive lanes pass and the malformed lane fails closed for
//     descriptor parse; otherwise print _FAIL.
//   - Exit 0 on overall PASS, 1 on FAIL/BLOCKED after a short delay.
//
// Non-claims: single-camera ingest diagnostic proof only. No concurrent/dual
// camera, no Vulkan, no recording, no export, no product/editor UI. Camera-
// side readback assertions are structural only (resolved OES target,
// render/readback success) -- never hue/luma/content, since the real camera
// frame's pixel content is unconstrained.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidSingleCamIngestSpatialRenderPhysicalSmokeApp());
}

class AndroidSingleCamIngestSpatialRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidSingleCamIngestSpatialRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidSingleCamIngestSpatialRenderPhysicalSmokeApp> createState() =>
      _AndroidSingleCamIngestSpatialRenderPhysicalSmokeAppState();
}

class _LaneOutcome {
  _LaneOutcome({
    required this.name,
    required this.startPayload,
    required this.report,
    required this.disposeReleased,
    required this.expectPass,
  });

  final String name;
  final Map<String, dynamic> startPayload;
  final VGSingleCamIngestSpatialRenderSmokeReport report;
  final bool disposeReleased;
  final bool expectPass;

  bool get isBlockedByDeviceCapability => report.isCameraIngestUnsupported;

  bool get laneOk {
    final lastErrorOk = report.lastError.isEmpty || report.lastError == 'none';
    if (expectPass) {
      // A device/format that cannot ingest this camera's YUV_420_888 buffer
      // as GL_TEXTURE_EXTERNAL_OES is a capability gap, not a code bug --
      // but it must never be reported as PASS either.
      if (isBlockedByDeviceCapability) return false;
      return report.success &&
          report.textureId >= 0 &&
          report.hasCanonicalProofBoundary &&
          report.allNativeLanesPass &&
          disposeReleased &&
          lastErrorOk;
    }
    // Deliberate fail-closed lane: overall success must be false and the
    // failure must be attributable specifically to descriptor rejection
    // (after a full camera open/capture), not an unrelated crash -- proving
    // the malformed enum value was rejected before any AHardwareBuffer
    // import or GLES work, not merely that "something" failed.
    return !report.success &&
        report.isDescriptorRejected &&
        report.attemptedOpen &&
        report.frameReceived &&
        !report.descriptorParsePass &&
        report.hasCanonicalProofBoundary &&
        disposeReleased;
  }
}

class _AndroidSingleCamIngestSpatialRenderPhysicalSmokeAppState
    extends State<AndroidSingleCamIngestSpatialRenderPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase3SingleCamIngestSpatialRenderSmokeComplete';
  static const _maxWidth = 640;
  static const _maxHeight = 480;

  String _status =
      'Running Android DAG Phase 3 single-cam ingest spatial render smoke...';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<_LaneOutcome> _runLane({
    required String name,
    required Map<String, Object?> descriptor,
    required bool expectPass,
  }) async {
    int? activeTextureId;
    var startPayload = <String, dynamic>{};
    var completionPayload = <String, dynamic>{};
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
          await VGSingleCamIngestSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
            descriptor: descriptor,
            maxWidth: _maxWidth,
            maxHeight: _maxHeight,
            channel: _channel,
          );

      activeTextureId = startResult.textureId;
      startPayload = <String, dynamic>{
        'textureId': activeTextureId,
        'maxWidth': startResult.maxWidth,
        'maxHeight': startResult.maxHeight,
      };

      if (mounted && activeTextureId >= 0) {
        setState(() {
          _textureId = activeTextureId;
          _status = 'Running lane "$name" (textureId=$activeTextureId)...';
        });
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 20),
      );
    } catch (error, stack) {
      print(
        'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_ERROR[$name]: $error\n$stack',
      );
      completionPayload = <String, dynamic>{
        'success': false,
        'raw': 'status=FAIL;lastError=dart_invoke_exception',
        'textureId': activeTextureId ?? -1,
        'proofBoundary':
            VGSingleCamIngestSpatialRenderSmokeReport.proofBoundaryConstant,
        'surfaceProducerReleased': false,
        'lastError': 'dart_invoke_exception',
        'decision': 'nativeRenderFailed',
        'reasons': const <String>['dart_invoke_exception'],
        'metrics': const <String, String>{},
      };
    } finally {
      _channel.setMethodCallHandler(null);
      if (activeTextureId != null && activeTextureId >= 0) {
        try {
          disposeReleased =
              await VGSingleCamIngestSpatialRenderSmokeReport.disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
                textureId: activeTextureId,
                channel: _channel,
              );
        } catch (_) {
          disposeReleased = false;
        }
      }
    }

    final report = VGSingleCamIngestSpatialRenderSmokeReport.fromMap(
      completionPayload,
    );

    // Explicit setup/permission/open/session/frame diagnostics.
    print(
      '  [LANE $name] setup: apiLevel=${report.apiLevel}, '
      'hasCameraPermission=${report.hasCameraPermission}, '
      'cameraId=${report.cameraId}, selectedLensFacing=${report.selectedLensFacing}, '
      'selectedWidth=${report.selectedWidth}, selectedHeight=${report.selectedHeight}',
    );
    print(
      '  [LANE $name] open/session/frame: attemptedOpen=${report.attemptedOpen}, '
      'opened=${report.opened}, sessionConfigured=${report.sessionConfigured}, '
      'repeatingStarted=${report.repeatingStarted}, frameReceived=${report.frameReceived}, '
      'hardwareBufferAvailable=${report.hardwareBufferAvailable}, '
      'syncFenceAwaited=${report.syncFenceAwaited}',
    );
    print(
      '  [LANE $name] import: cameraDescribe=${report.cameraDescribePass}, '
      'cameraFormatIsYcbcr420=${report.cameraFormatIsYcbcr420}, '
      'importCamera=${report.importCameraPass}, rgbaDescribe=${report.rgbaDescribePass}, '
      'rgbaFill=${report.rgbaFillPass}, importRgba=${report.importRgbaPass}',
    );
    print(
      '  [LANE $name] descriptor: descriptorParse=${report.descriptorParsePass}, '
      'layoutModeResolved=${report.layoutModeResolved}, anchorResolved=${report.anchorResolved}, '
      'directionResolved=${report.directionResolved}, layoutConvert=${report.layoutConvertPass}',
    );
    print(
      '  [LANE $name] render/present: renderDraw=${report.renderDrawPass}, '
      'primaryTargetOk(camera/OES)=${report.primaryTargetOkPass}, '
      'secondaryTargetOk(synthetic/2D)=${report.secondaryTargetOkPass}, '
      'primarySampleReadOk=${report.primarySampleReadOkPass}, '
      'secondarySampleReadOk=${report.secondarySampleReadOkPass}, '
      'secondaryColorOk(blue)=${report.secondaryColorOkPass}, '
      'present=${report.presentLanePass}',
    );
    print(
      '  [LANE $name] teardown/dispose: releaseCamera=${report.releaseCameraPass}, '
      'releaseRgba=${report.releaseRgbaPass}, postRelease=${report.postReleaseLanePass}, '
      'detach=${report.detachPass}, shutdown=${report.shutdownPass}, '
      'idempotentShutdown=${report.idempotentShutdownPass}, '
      'sessionClosed=${report.sessionClosed}, deviceClosed=${report.deviceClosed}, '
      'imageReaderClosed=${report.imageReaderClosed}, '
      'syntheticBufferClosed=${report.syntheticBufferClosed}, '
      'disposeReleased=$disposeReleased',
    );
    print(
      '  [LANE $name] decision=${report.decision.name}, '
      'proofBoundary canonical=${report.hasCanonicalProofBoundary}, '
      'lastError=${report.lastError}',
    );

    if (expectPass && report.isCameraIngestUnsupported) {
      print(
        '  [LANE $name] BLOCKED: this device/format cannot ingest the '
        'camera YUV_420_888 buffer as GL_TEXTURE_EXTERNAL_OES '
        '(reasons=${report.reasons}) -- capability gap, not a code bug. '
        'Not reporting PASS.',
      );
    }

    return _LaneOutcome(
      name: name,
      startPayload: startPayload,
      report: report,
      disposeReleased: disposeReleased,
      expectPass: expectPass,
    );
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_SMOKE_START');

    final freeFloatingLane = await _runLane(
      name: 'freeFloatingPip',
      descriptor:
          VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
              .toMap(),
      expectPass: true,
    );

    final leftRightLane = await _runLane(
      name: 'leftRightSplit',
      descriptor: VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit()
          .toMap(),
      expectPass: true,
    );

    final malformedLane = await _runLane(
      name: 'malformedUnknownLayoutMode',
      descriptor: const <String, Object?>{
        'layoutMode': 'notARealLayoutMode',
        'pipAnchor': 'freeFloating',
        'pipCenterX': 0.5,
        'pipCenterY': 0.5,
        'pipWidthFraction': 0.3,
        'pipAspectRatio': 1.0,
        'pipMarginFraction': 0.05,
        'splitDirection': 'topBottom',
        'splitRatio': 0.5,
      },
      expectPass: false,
    );

    final lanes = <_LaneOutcome>[
      freeFloatingLane,
      leftRightLane,
      malformedLane,
    ];
    final anyBlocked = lanes.any((lane) => lane.isBlockedByDeviceCapability);
    final pass = !anyBlocked && lanes.every((lane) => lane.laneOk);

    final summaryReport = <String, dynamic>{
      'lanes': {
        for (final lane in lanes)
          lane.name: {
            'start': lane.startPayload,
            'completion': lane.report.toMap(),
            'disposeReleased': lane.disposeReleased,
            'expectPass': lane.expectPass,
            'laneOk': lane.laneOk,
            'blockedByDeviceCapability': lane.isBlockedByDeviceCapability,
          },
      },
      'pass': pass,
      'blocked': anyBlocked,
    };

    print(
      'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_JSON:${jsonEncode(summaryReport)}',
    );
    if (anyBlocked) {
      print(
        'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_BLOCKED: at least '
        'one positive lane could not ingest the camera buffer on this '
        'device -- see per-lane logs above.',
      );
    }
    print(
      pass
          ? 'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_PASS'
          : 'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_SPATIAL_RENDER_FAIL',
    );

    if (mounted) {
      setState(() {
        _textureId = null;
        _status = pass
            ? 'PASS (all lanes ok)'
            : (anyBlocked
                  ? 'BLOCKED: see per-lane logs above'
                  : 'FAIL: see per-lane logs above');
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
                  width: _maxWidth.toDouble(),
                  height: _maxHeight.toDouble(),
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
