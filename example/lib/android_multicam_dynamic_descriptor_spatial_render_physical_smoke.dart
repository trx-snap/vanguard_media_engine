// android_multicam_dynamic_descriptor_spatial_render_physical_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER:
// Android True-DAG Phase 3 physical proof that a caller-supplied Dart layout
// descriptor map drives native GLES/OES spatial rendering.
//
// Route:
//   startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke /
//   disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke /
//   onAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmokeComplete.
//
// Dart responsibilities:
//   - Print ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_SMOKE_START.
//   - Sequentially run three lanes, each a full start -> complete -> dispose
//     cycle with width=128, height=128:
//       1. freeFloatingPip: caller descriptor -> native ComputeMultiCamLayout
//          -> GLES spatial render with RGBA primary (red) + OES secondary.
//       2. leftRightSplit: caller descriptor -> native ComputeMultiCamLayout
//          -> GLES spatial render with OES primary + RGBA secondary (blue).
//       3. malformedUnknownLayoutMode: a well-typed but unrecognized
//          `layoutMode` value, expected to fail closed natively with an
//          explicit descriptorParse reason before any GLES work.
//   - Mount Texture(textureId) while each lane runs.
//   - Print per-lane diagnostic logs.
//   - Always dispose each lane in finally; require surfaceProducerReleased
//     for each lane.
//   - Print ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_JSON:<json>
//   - Print ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_PASS/FAIL.
//   - Exit 0 on overall PASS, 1 on FAIL after a short delay.
//
// Non-claims: diagnostic render only; no camera open, no Vulkan, no
// opacity, no corner radius, no recording, no export, no product/editor UI.
// OES lanes assert render/readback success and resolved texture target
// only -- never deterministic color content for the never-CPU-filled
// YCBCR buffers.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiCamDynamicDescriptorSpatialRenderPhysicalSmokeApp());
}

class AndroidMultiCamDynamicDescriptorSpatialRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidMultiCamDynamicDescriptorSpatialRenderPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidMultiCamDynamicDescriptorSpatialRenderPhysicalSmokeApp>
  createState() =>
      _AndroidMultiCamDynamicDescriptorSpatialRenderPhysicalSmokeAppState();
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
  final VGMultiCamDynamicDescriptorSpatialRenderSmokeReport report;
  final bool disposeReleased;
  final bool expectPass;

  bool get laneOk {
    final lastErrorOk = report.lastError.isEmpty || report.lastError == 'none';
    if (expectPass) {
      return report.pass &&
          report.textureId >= 0 &&
          report.hasCanonicalProofBoundary &&
          report.allNativeLanesPass &&
          disposeReleased &&
          lastErrorOk;
    }
    // Deliberate fail-closed lane: overall pass must be false and the
    // failure must be attributable specifically to descriptor parsing, not
    // an unrelated GL/native crash -- proving the malformed enum value was
    // rejected before any render work, not merely that "something" failed.
    return !report.pass &&
        !report.descriptorParsePass &&
        report.hasCanonicalProofBoundary &&
        disposeReleased;
  }
}

class _AndroidMultiCamDynamicDescriptorSpatialRenderPhysicalSmokeAppState
    extends
        State<AndroidMultiCamDynamicDescriptorSpatialRenderPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmokeComplete';
  static const _width = 128;
  static const _height = 128;

  String _status =
      'Running Android DAG Phase 3 dynamic-descriptor spatial render smoke...';
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
          await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
            descriptor: descriptor,
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
          _status = 'Running lane "$name" (textureId=$activeTextureId)...';
        });
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 20),
      );
    } catch (error, stack) {
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_ERROR[$name]: $error\n$stack',
      );
      completionPayload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;lastError=dart_invoke_exception',
        'textureId': activeTextureId ?? -1,
        'width': _width,
        'height': _height,
        'proofBoundary': VGMultiCamDynamicDescriptorSpatialRenderSmokeReport
            .proofBoundaryConstant,
        'surfaceProducerReleased': false,
        'lastError': 'dart_invoke_exception',
        'metrics': const <String, String>{'reason': 'dart_invoke_exception'},
      };
    } finally {
      _channel.setMethodCallHandler(null);
      if (activeTextureId != null && activeTextureId >= 0) {
        try {
          disposeReleased =
              await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
                textureId: activeTextureId,
                channel: _channel,
              );
        } catch (_) {
          disposeReleased = false;
        }
      }
    }

    final report = VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.fromMap(
      completionPayload,
    );

    print(
      '  [LANE $name] descriptor: descriptorParse=${report.descriptorParsePass}, '
      'layoutModeResolved=${report.layoutModeResolved}, anchorResolved=${report.anchorResolved}, '
      'directionResolved=${report.directionResolved}, layoutConvert=${report.layoutConvertPass}',
    );
    print(
      '  [LANE $name] render: renderLaneMode=${report.renderLaneMode}, '
      'primaryTextureKind=${report.primaryTextureKind}, secondaryTextureKind=${report.secondaryTextureKind}, '
      'renderDraw=${report.renderDrawPass}, primaryTargetOk=${report.primaryTargetOkPass}, '
      'secondaryTargetOk=${report.secondaryTargetOkPass}, primarySampleReadOk=${report.primarySampleReadOkPass}, '
      'secondarySampleReadOk=${report.secondarySampleReadOkPass}, '
      'deterministicColorSide=${report.deterministicColorSide}, '
      'deterministicColorOk=${report.deterministicColorOkPass}, present=${report.presentLanePass}',
    );
    print(
      '  [LANE $name] release/teardown: releaseRgbaA=${report.releaseRgbaAPass}, '
      'releaseRgbaB=${report.releaseRgbaBPass}, releaseYcbcrA=${report.releaseYcbcrAPass}, '
      'releaseYcbcrB=${report.releaseYcbcrBPass}, postRelease=${report.postReleaseLanePass}, '
      'detach=${report.detachPass}, shutdown=${report.shutdownPass}, '
      'idempotentShutdown=${report.idempotentShutdownPass}, disposeReleased=$disposeReleased',
    );
    print(
      '  [LANE $name] proofBoundary canonical=${report.hasCanonicalProofBoundary}, '
      'lastError=${report.lastError}',
    );

    return _LaneOutcome(
      name: name,
      startPayload: startPayload,
      report: report,
      disposeReleased: disposeReleased,
      expectPass: expectPass,
    );
  }

  Future<void> _runSmoke() async {
    print(
      'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_SMOKE_START',
    );

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
    final pass = lanes.every((lane) => lane.laneOk);

    final summaryReport = <String, dynamic>{
      'lanes': {
        for (final lane in lanes)
          lane.name: {
            'start': lane.startPayload,
            'completion': lane.report.toMap(),
            'disposeReleased': lane.disposeReleased,
            'expectPass': lane.expectPass,
            'laneOk': lane.laneOk,
          },
      },
      'pass': pass,
    };

    print(
      'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_JSON:${jsonEncode(summaryReport)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_PASS'
          : 'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_FAIL',
    );

    if (mounted) {
      setState(() {
        _textureId = null;
        _status = pass
            ? 'PASS (all lanes ok)'
            : 'FAIL: see per-lane logs above';
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
