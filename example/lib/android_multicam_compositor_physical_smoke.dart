// android_multicam_compositor_physical_smoke.dart
// Vanguard Media Engine — P3-MULTICAM-NODE: Android True-DAG MultiCamCompositorNode
// native topology + PiP/split layout-math diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true.
//   Lane 2: smoke report nodeTopologyPass == true (metrics['nodeOk'] == 'true').
//   Lane 3: smoke report pipFreeFloatingPass == true (metrics['pipFreeFloatOk'] == 'true').
//   Lane 4: smoke report anchorsPass == true (metrics['anchorsOk'] == 'true').
//   Lane 5: smoke report splitPass == true (metrics['splitOk'] == 'true').
//   Lane 6: smoke report clampPass == true (metrics['clampOk'] == 'true').
//   Lane 7: smoke report hasCanonicalProofBoundary == true (proofBoundary matches canonical constant).
//   Lane 8: smoke report allNativeLanesPass == true && report.isPass && toMap() matches.
//
// Target / proof boundary:
//   native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording
//   Pure in-memory native C++ graph topology + layout math validation only.
//   No render, no camera opening, no recording, no export, and no app/editor UI.
//
// P3-MULTICAM-NODE-DART-TO-NATIVE-LAYOUT-MAP-BRIDGE proof lanes (distinct from
// the topology smoke lanes above): proves a Dart layout map
// (VGLivePreviewConfig.toMap()) can be consumed by the Android bridge and
// converted into the native MultiCamCompositorNode layout math.
//   Lane 9:  freeFloating PiP bridge report pass == true.
//   Lane 10: freeFloating PiP bridge pipCenterApplicable && pipCenterPass == true
//            (native secondary-viewport center reproduces centerX=0.35, centerY=0.65).
//   Lane 11: freeFloating PiP bridge hasCanonicalProofBoundary == true.
//   Lane 12: leftRight split bridge report pass == true.
//   Lane 13: leftRight split bridge splitConsumptionApplicable && splitConsumptionPass == true
//            (native primary/secondary viewport widths reproduce splitRatio=0.65).
//   Lane 14: leftRight split bridge hasCanonicalProofBoundary == true.
//
// Malformed descriptor layout map fail-closed proof lanes: proves the real
// Kotlin `AndroidMultiCamCompositorSmokeCoordinator.runDescriptorBridgeSmoke`
// malformed-map branch (`makeFailedMap("malformed_descriptor_layout_map", ...)`)
// on-device via the real MethodChannel, with a malformed nested numeric field
// (`pipLayout.centerX` sent as a non-numeric string) so the map never reaches
// [VGLivePreviewConfig]/[VGPiPLayoutDescriptor], forcing the raw MethodChannel
// invocation below.
//   Lane 15: malformed descriptor bridge report pass == false (fail-closed).
//   Lane 16: malformed descriptor bridge metrics['status'] == 'FAIL' &&
//            metrics['reason'] == 'malformed_descriptor_layout_map'.
//   Lane 17: malformed descriptor bridge hasCanonicalProofBoundary == true.
//
// Target / proof boundary (bridge lanes):
//   dart_layout_map_to_native_multicam_layout_diagnostic_only_no_camera_no_render_no_recording_no_product
//   Dart layout-map consumption into native layout math only. No camera open,
//   no concurrent capture, no render, no OES, no recording/export, no
//   product/editor UI, and no iOS.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiCamCompositorPhysicalSmokeApp());
}

class AndroidMultiCamCompositorPhysicalSmokeApp extends StatefulWidget {
  const AndroidMultiCamCompositorPhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiCamCompositorPhysicalSmokeApp> createState() =>
      _AndroidMultiCamCompositorPhysicalSmokeAppState();
}

class _AndroidMultiCamCompositorPhysicalSmokeAppState
    extends State<AndroidMultiCamCompositorPhysicalSmokeApp> {
  String _status =
      'Initializing MultiCamCompositorNode Layout Math Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_SMOKE_START');
    String? topLevelError;
    VGMultiCamCompositorSmokeReport? report;
    VGMultiCamDescriptorBridgeSmokeReport? freeFloatingReport;
    VGMultiCamDescriptorBridgeSmokeReport? leftRightReport;
    VGMultiCamDescriptorBridgeSmokeReport? malformedReport;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;
    var lane9Pass = false;
    var lane10Pass = false;
    var lane11Pass = false;
    var lane12Pass = false;
    var lane13Pass = false;
    var lane14Pass = false;
    var lane15Pass = false;
    var lane16Pass = false;
    var lane17Pass = false;

    try {
      // 1. Invoke MultiCamCompositorNode smoke harness
      report =
          await VGMultiCamCompositorSmokeReport.runAndroidDagPhase3MultiCamCompositorSmoke(
            timeout: const Duration(seconds: 10),
          ).timeout(const Duration(seconds: 20));

      // Lane 1: report.pass == true
      lane1Pass = report.pass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_1: pass=$lane1Pass reportPass=${report.pass}',
      );

      // Lane 2: report.nodeTopologyPass == true
      lane2Pass = report.nodeTopologyPass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_2: pass=$lane2Pass nodeTopologyPass=${report.nodeTopologyPass} nodeOk=${report.metrics['nodeOk']}',
      );

      // Lane 3: report.pipFreeFloatingPass == true
      lane3Pass = report.pipFreeFloatingPass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_3: pass=$lane3Pass pipFreeFloatingPass=${report.pipFreeFloatingPass} pipFreeFloatOk=${report.metrics['pipFreeFloatOk']}',
      );

      // Lane 4: report.anchorsPass == true
      lane4Pass = report.anchorsPass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_4: pass=$lane4Pass anchorsPass=${report.anchorsPass} anchorsOk=${report.metrics['anchorsOk']}',
      );

      // Lane 5: report.splitPass == true
      lane5Pass = report.splitPass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_5: pass=$lane5Pass splitPass=${report.splitPass} splitOk=${report.metrics['splitOk']}',
      );

      // Lane 6: report.clampPass == true
      lane6Pass = report.clampPass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_6: pass=$lane6Pass clampPass=${report.clampPass} clampOk=${report.metrics['clampOk']}',
      );

      // Lane 7: report.hasCanonicalProofBoundary == true
      lane7Pass = report.hasCanonicalProofBoundary == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_7: pass=$lane7Pass hasCanonicalProofBoundary=${report.hasCanonicalProofBoundary} proofBoundary=${report.proofBoundary}',
      );

      // Lane 8: report.allNativeLanesPass == true && isPass == true && toMap() matches
      final map = report.toMap();
      final mapMatches =
          map['pass'] == report.pass &&
          map['decision'] == report.decision.name &&
          map['raw'] == report.raw &&
          map['proofBoundary'] == report.proofBoundary &&
          mapEquals(map['metrics'] as Map<String, String>?, report.metrics);

      lane8Pass = report.allNativeLanesPass && report.isPass && mapMatches;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_LANE_8: pass=$lane8Pass allNativeLanesPass=${report.allNativeLanesPass} isPass=${report.isPass} mapMatches=$mapMatches',
      );

      // 2. Invoke the P3-MULTICAM-NODE-DART-TO-NATIVE-LAYOUT-MAP-BRIDGE
      //    diagnostic with a freeFloating PiP descriptor layout map.
      const freeFloatingConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.freeFloating,
          centerX: 0.35,
          centerY: 0.65,
          aspectRatio: 1.0,
        ),
      );
      freeFloatingReport =
          await VGMultiCamDescriptorBridgeSmokeReport.runAndroidDagPhase3MultiCamDescriptorBridgeSmoke(
            config: freeFloatingConfig,
            timeout: const Duration(seconds: 10),
          ).timeout(const Duration(seconds: 20));

      // Lane 9: freeFloating PiP bridge report.pass == true
      lane9Pass = freeFloatingReport.pass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_9: pass=$lane9Pass reportPass=${freeFloatingReport.pass}',
      );

      // Lane 10: freeFloating PiP center-geometry consumption proof
      lane10Pass =
          freeFloatingReport.pipCenterApplicable == true &&
          freeFloatingReport.pipCenterPass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_10: pass=$lane10Pass pipCenterApplicable=${freeFloatingReport.pipCenterApplicable} pipCenterPass=${freeFloatingReport.pipCenterPass} pipSecondaryCenterX=${freeFloatingReport.metrics['pipSecondaryCenterX']} pipSecondaryCenterY=${freeFloatingReport.metrics['pipSecondaryCenterY']}',
      );

      // Lane 11: freeFloating PiP bridge canonical proof boundary
      lane11Pass = freeFloatingReport.hasCanonicalProofBoundary == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_11: pass=$lane11Pass hasCanonicalProofBoundary=${freeFloatingReport.hasCanonicalProofBoundary} proofBoundary=${freeFloatingReport.proofBoundary}',
      );

      // 3. Invoke the same bridge diagnostic with a leftRight split
      //    descriptor layout map.
      const leftRightConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        splitLayout: VGSplitScreenLayoutDescriptor(
          splitRatio: 0.65,
          direction: VGSplitScreenDirection.leftRight,
        ),
      );
      leftRightReport =
          await VGMultiCamDescriptorBridgeSmokeReport.runAndroidDagPhase3MultiCamDescriptorBridgeSmoke(
            config: leftRightConfig,
            timeout: const Duration(seconds: 10),
          ).timeout(const Duration(seconds: 20));

      // Lane 12: leftRight split bridge report.pass == true
      lane12Pass = leftRightReport.pass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_12: pass=$lane12Pass reportPass=${leftRightReport.pass}',
      );

      // Lane 13: leftRight split-consumption proof
      lane13Pass =
          leftRightReport.splitConsumptionApplicable == true &&
          leftRightReport.splitConsumptionPass == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_13: pass=$lane13Pass splitConsumptionApplicable=${leftRightReport.splitConsumptionApplicable} splitConsumptionPass=${leftRightReport.splitConsumptionPass} splitPrimaryWidth=${leftRightReport.metrics['splitPrimaryWidth']} splitSecondaryWidth=${leftRightReport.metrics['splitSecondaryWidth']}',
      );

      // Lane 14: leftRight split bridge canonical proof boundary
      lane14Pass = leftRightReport.hasCanonicalProofBoundary == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_14: pass=$lane14Pass hasCanonicalProofBoundary=${leftRightReport.hasCanonicalProofBoundary} proofBoundary=${leftRightReport.proofBoundary}',
      );

      // 4. Invoke the same bridge MethodChannel directly with a malformed
      //    layout map (a non-numeric `pipLayout.centerX`) to prove the real
      //    Kotlin fail-closed path (`makeFailedMap("malformed_descriptor_
      //    layout_map", ...)`) on-device. This bypasses VGLivePreviewConfig
      //    (whose typed fields cannot hold a malformed value) and calls the
      //    MethodChannel directly, since the point of this lane is proving
      //    the native fail-closed branch, not Dart-side validation.
      const malformedDescriptorBridgeMap = <String, Object?>{
        'layoutMode': 'pip',
        'pipLayout': <String, Object?>{
          'anchor': 'freeFloating',
          'widthFraction': 0.35,
          'marginFraction': 0.018,
          'cornerRadius': 24.0,
          'opacity': 1.0,
          'centerX': 'not_a_number',
          'centerY': 0.65,
          'aspectRatio': 1.0,
        },
        'splitLayout': <String, Object?>{
          'splitRatio': 0.5,
          'direction': 'topBottom',
        },
      };
      const bridgeChannel = MethodChannel('vanguard_media_engine');
      final malformedRaw = await bridgeChannel
          .invokeMethod<Object?>(
            'runAndroidDagPhase3MultiCamDescriptorBridgeSmoke',
            malformedDescriptorBridgeMap,
          )
          .timeout(const Duration(seconds: 20));
      malformedReport = VGMultiCamDescriptorBridgeSmokeReport.fromMap(
        malformedRaw,
      );

      // Lane 15: malformed descriptor bridge report.pass == false (fail-closed)
      lane15Pass = malformedReport.pass == false;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_15: pass=$lane15Pass reportPass=${malformedReport.pass}',
      );

      // Lane 16: malformed descriptor bridge metrics status/reason
      lane16Pass =
          malformedReport.metrics['status'] == 'FAIL' &&
          malformedReport.metrics['reason'] ==
              'malformed_descriptor_layout_map';
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_16: pass=$lane16Pass status=${malformedReport.metrics['status']} reason=${malformedReport.metrics['reason']}',
      );

      // Lane 17: malformed descriptor bridge canonical proof boundary
      lane17Pass = malformedReport.hasCanonicalProofBoundary == true;
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DESCRIPTOR_BRIDGE_LANE_17: pass=$lane17Pass hasCanonicalProofBoundary=${malformedReport.hasCanonicalProofBoundary} proofBoundary=${malformedReport.proofBoundary}',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: MultiCamCompositorNode Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          lane6Pass &&
          lane7Pass &&
          lane8Pass &&
          lane9Pass &&
          lane10Pass &&
          lane11Pass &&
          lane12Pass &&
          lane13Pass &&
          lane14Pass &&
          lane15Pass &&
          lane16Pass &&
          lane17Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidMultiCamCompositorSmokeHarness',
        'slice': 'P3-MULTICAM-NODE',
        'target':
            'native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_pass': {'pass': lane1Pass, 'reportPass': report?.pass},
          'lane2_nodeTopology': {
            'pass': lane2Pass,
            'nodeTopologyPass': report?.nodeTopologyPass,
          },
          'lane3_pipFreeFloating': {
            'pass': lane3Pass,
            'pipFreeFloatingPass': report?.pipFreeFloatingPass,
          },
          'lane4_anchors': {
            'pass': lane4Pass,
            'anchorsPass': report?.anchorsPass,
          },
          'lane5_split': {'pass': lane5Pass, 'splitPass': report?.splitPass},
          'lane6_clamp': {'pass': lane6Pass, 'clampPass': report?.clampPass},
          'lane7_proofBoundary': {
            'pass': lane7Pass,
            'proofBoundary': report?.proofBoundary,
            'hasCanonicalProofBoundary': report?.hasCanonicalProofBoundary,
          },
          'lane8_allLanesAndContract': {
            'pass': lane8Pass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'isPass': report?.isPass,
          },
          'lane9_descriptorBridgeFreeFloatingPass': {
            'pass': lane9Pass,
            'reportPass': freeFloatingReport?.pass,
          },
          'lane10_descriptorBridgeFreeFloatingCenterConsumption': {
            'pass': lane10Pass,
            'pipCenterApplicable': freeFloatingReport?.pipCenterApplicable,
            'pipCenterPass': freeFloatingReport?.pipCenterPass,
          },
          'lane11_descriptorBridgeFreeFloatingProofBoundary': {
            'pass': lane11Pass,
            'proofBoundary': freeFloatingReport?.proofBoundary,
            'hasCanonicalProofBoundary':
                freeFloatingReport?.hasCanonicalProofBoundary,
          },
          'lane12_descriptorBridgeLeftRightPass': {
            'pass': lane12Pass,
            'reportPass': leftRightReport?.pass,
          },
          'lane13_descriptorBridgeLeftRightSplitConsumption': {
            'pass': lane13Pass,
            'splitConsumptionApplicable':
                leftRightReport?.splitConsumptionApplicable,
            'splitConsumptionPass': leftRightReport?.splitConsumptionPass,
          },
          'lane14_descriptorBridgeLeftRightProofBoundary': {
            'pass': lane14Pass,
            'proofBoundary': leftRightReport?.proofBoundary,
            'hasCanonicalProofBoundary':
                leftRightReport?.hasCanonicalProofBoundary,
          },
          'lane15_descriptorBridgeMalformedFailClosed': {
            'pass': lane15Pass,
            'reportPass': malformedReport?.pass,
          },
          'lane16_descriptorBridgeMalformedStatusReason': {
            'pass': lane16Pass,
            'status': malformedReport?.metrics['status'],
            'reason': malformedReport?.metrics['reason'],
          },
          'lane17_descriptorBridgeMalformedProofBoundary': {
            'pass': lane17Pass,
            'proofBoundary': malformedReport?.proofBoundary,
            'hasCanonicalProofBoundary':
                malformedReport?.hasCanonicalProofBoundary,
          },
        },
        'smokeReport': report?.toMap(),
        'descriptorBridgeFreeFloatingReport': freeFloatingReport?.toMap(),
        'descriptorBridgeLeftRightReport': leftRightReport?.toMap(),
        'descriptorBridgeMalformedReport': malformedReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_MULTICAM_COMPOSITOR_SMOKE_FAIL',
      );

      if (mounted) {
        setState(() {
          _status = allPass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(allPass ? 0 : 1);
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
