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

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;

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
        },
        'smokeReport': report?.toMap(),
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
