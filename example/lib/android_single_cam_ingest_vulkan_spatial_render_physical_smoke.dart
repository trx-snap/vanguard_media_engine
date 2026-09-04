// android_single_cam_ingest_vulkan_spatial_render_physical_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER:
// Android True-DAG Phase 3 physical proof that one real Camera2
// ImageReader(YUV_420_888) buffer-queue frame plus one synthetic RGBA8
// Vulkan scratch image are laid out by a caller-supplied Dart layout
// descriptor through native ComputeMultiCamLayout(), rendered by the
// VulkanMultiCamSpatialCompositor, structurally read back, and torn down
// synchronously.
//
// Route:
//   startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke /
//   disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke /
//   onAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeComplete.
//
// Dart responsibilities:
//   - Print ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_SMOKE_START.
//   - Sequentially run three lanes (never concurrent -- each is a full
//     start -> complete -> dispose cycle before the next begins):
//       1. freeFloatingPip: real camera frame (primary) + synthetic Vulkan scratch
//          image (secondary, solid blue PiP box).
//       2. leftRightSplit: real camera frame (primary, left/right half)
//          + synthetic Vulkan scratch image (secondary, solid blue, other half).
//       3. malformedUnknownLayoutMode: a well-typed but unrecognized
//          `layoutMode` value via raw descriptor path -- camera still fully
//          opens/captures a frame, but native's strict resolver rejects it before
//          any Vulkan scratch setup, expected to fail closed.
//   - Print explicit setup/permission/open/session/frame/import/render/teardown diagnostics.
//   - Always dispose each lane in finally.
//   - If a positive lane reports cameraIngestUnsupported or nativeUnsupported,
//     print BLOCKED and do not report overall PASS.
//   - Print ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_JSON:<json>.
//   - Print ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_PASS only
//     when expected lane outcomes are met; otherwise print _FAIL.
//   - Exit 0 on overall PASS, 1 on FAIL/BLOCKED after a short delay.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_FAIL';
const String _logPrefix =
    'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER';

void main() {
  runApp(const AndroidSingleCamIngestVulkanSpatialRenderPhysicalSmokeApp());
}

class AndroidSingleCamIngestVulkanSpatialRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidSingleCamIngestVulkanSpatialRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidSingleCamIngestVulkanSpatialRenderPhysicalSmokeApp>
  createState() =>
      _AndroidSingleCamIngestVulkanSpatialRenderPhysicalSmokeAppState();
}

class _LaneOutcome {
  _LaneOutcome({
    required this.name,
    required this.report,
    required this.expectPass,
  });

  final String name;
  final VGSingleCamIngestVulkanSpatialRenderSmokeReport report;
  final bool expectPass;

  bool get isBlockedByCapability =>
      report.isCameraIngestUnsupported || report.isUnsupported;

  bool get laneOk {
    if (expectPass) {
      if (isBlockedByCapability) return false;
      return report.isVerifiedPass;
    }
    return report.isVerifiedDescriptorRejection ||
        (!report.pass && report.isDescriptorRejected);
  }
}

class _AndroidSingleCamIngestVulkanSpatialRenderPhysicalSmokeAppState
    extends State<AndroidSingleCamIngestVulkanSpatialRenderPhysicalSmokeApp> {
  String _status =
      'Initializing Single-Cam Ingest Vulkan Spatial Render Physical Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<_LaneOutcome> _runLaneWithTypedDescriptor({
    required String name,
    required VGMultiCamDynamicDescriptorSpatialRenderInput descriptor,
    required bool expectPass,
  }) async {
    print('  [LANE $name] Starting lane with typed descriptor...');
    final report =
        await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
          descriptor: descriptor,
          timeout: const Duration(seconds: 25),
        );
    _logReport(name, report, expectPass);
    return _LaneOutcome(name: name, report: report, expectPass: expectPass);
  }

  Future<_LaneOutcome> _runLaneWithRawDescriptor({
    required String name,
    required Map<String, Object?> rawDescriptor,
    required bool expectPass,
  }) async {
    print('  [LANE $name] Starting lane with raw descriptor...');
    final report =
        await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeWithRawDescriptor(
          rawDescriptor,
          timeout: const Duration(seconds: 25),
        );
    _logReport(name, report, expectPass);
    return _LaneOutcome(name: name, report: report, expectPass: expectPass);
  }

  void _logReport(
    String name,
    VGSingleCamIngestVulkanSpatialRenderSmokeReport report,
    bool expectPass,
  ) {
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
      '  [LANE $name] gates: descriptorParseOk=${report.descriptorParseOk}, '
      'descriptorRejectedBeforeVulkanOk=${report.descriptorRejectedBeforeVulkanOk}, '
      'vulkanSetupOk=${report.vulkanSetupOk}, cameraImportOk=${report.cameraImportOk}, '
      'syntheticImportOk=${report.syntheticImportOk}, layoutConvertOk=${report.layoutConvertOk}, '
      'renderReadbackOk=${report.renderReadbackOk}, helperResourcesReleasedOk=${report.helperResourcesReleasedOk}, '
      'diagnosticTeardownOk=${report.diagnosticTeardownOk}',
    );
    print(
      '  [LANE $name] descriptor: layoutModeResolved=${report.layoutModeResolved}, '
      'pipAnchorResolved=${report.pipAnchorResolved}, '
      'splitDirectionResolved=${report.splitDirectionResolved}, '
      'rejectionReason=${report.rejectionReason}',
    );
    print(
      '  [LANE $name] teardown: sessionClosed=${report.sessionClosed}, '
      'deviceClosed=${report.deviceClosed}, imageReaderClosed=${report.imageReaderClosed}',
    );
    print(
      '  [LANE $name] decision=${report.decision.name}, pass=${report.pass}, '
      'status=${report.status}, marker=${report.marker}, '
      'proofBoundary canonical=${report.hasCanonicalProofBoundary}, '
      'failureReason=${report.failureReason}',
    );

    if (report.isCameraIngestUnsupported || report.isUnsupported) {
      print(
        '  [LANE $name] BLOCKED: capability gap (cameraIngestUnsupported=${report.isCameraIngestUnsupported}, '
        'vulkanUnsupported=${report.isUnsupported}, reasons=${report.reasons}).',
      );
    }
  }

  Future<void> _runSmoke() async {
    print('${_logPrefix}_SMOKE_START');
    String? topLevelError;
    final outcomes = <_LaneOutcome>[];

    try {
      if (mounted) {
        setState(() {
          _status = 'Running lane 1: freeFloatingPip...';
        });
      }
      final lane1 = await _runLaneWithTypedDescriptor(
        name: 'freeFloatingPip',
        descriptor:
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
        expectPass: true,
      );
      outcomes.add(lane1);

      if (mounted) {
        setState(() {
          _status = 'Running lane 2: leftRightSplit...';
        });
      }
      final lane2 = await _runLaneWithTypedDescriptor(
        name: 'leftRightSplit',
        descriptor:
            VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit(),
        expectPass: true,
      );
      outcomes.add(lane2);

      if (mounted) {
        setState(() {
          _status = 'Running lane 3: malformedUnknownLayoutMode...';
        });
      }
      final lane3 = await _runLaneWithRawDescriptor(
        name: 'malformedUnknownLayoutMode',
        rawDescriptor: const <String, Object?>{
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
      outcomes.add(lane3);
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_ERROR: $topLevelError');
    } finally {
      final anyBlocked = outcomes.any((l) => l.isBlockedByCapability);
      final allLanesOk =
          outcomes.length == 3 &&
          outcomes.every((l) => l.laneOk) &&
          topLevelError == null;
      final overallPass = !anyBlocked && allLanesOk;

      final summary = <String, dynamic>{
        'unit': 'AndroidCamera2SingleCamIngestVulkanSpatialSmokeHarness',
        'slice': 'P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER',
        'proofBoundary': VGSingleCamIngestVulkanSpatialRenderSmokeReport
            .proofBoundaryConstant,
        'pass': overallPass,
        'marker': overallPass ? _passMarker : _failMarker,
        'blocked': anyBlocked,
        'lanes': {
          for (final outcome in outcomes)
            outcome.name: {
              'laneOk': outcome.laneOk,
              'expectPass': outcome.expectPass,
              'blocked': outcome.isBlockedByCapability,
              'report': outcome.report.toMap(),
            },
        },
        'error': topLevelError,
      };

      print('${_logPrefix}_JSON:${jsonEncode(summary)}');
      if (anyBlocked) {
        print(
          '${_logPrefix}_BLOCKED: device capability gap detected -- not reporting PASS',
        );
      }
      print(overallPass ? _passMarker : _failMarker);

      if (mounted) {
        setState(() {
          _status = overallPass
              ? 'PASS (all lanes passed)'
              : (anyBlocked ? 'BLOCKED: capability gap' : 'FAIL: lane failure');
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(overallPass ? 0 : 1);
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
            padding: const EdgeInsets.all(24),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}
