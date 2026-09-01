// android_timeline_compositor_physical_smoke.dart
// Vanguard Media Engine — P5-COMPOSITOR-TRANS (sub-slice NODE-TOPOLOGY-MATH):
// Android True-DAG VGTimelineCompositorNode native topology + timeline clip
// overlap / transition progress math diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true.
//   Lane 2: smoke report topologyPass == true (kind/type/port count/port ids).
//   Lane 3: smoke report mathPass == true (hard cut, crossfade start/mid/end,
//           slide-left mid, wipe-left mid, speed mapping, outside timeline,
//           invalid transition ignored, zero-duration safe, overflow safe).
//   Lane 4: smoke report hasPassMarker == true (canonical PASS marker).
//   Lane 5: smoke report hasCanonicalProofBoundary == true.
//   Lane 6: smoke report isVerifiedPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && toMap() round-trips.
//
// Target / proof boundary:
//   native_vg_timeline_compositor_node_topology_and_transition_math_only_no_render_no_decode
//   Pure in-memory native C++ graph topology + transition math validation only.
//   No render, no decode, no export session, and no app/editor UI.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_timeline_compositor_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR';

void main() {
  runApp(const AndroidTimelineCompositorPhysicalSmokeApp());
}

class AndroidTimelineCompositorPhysicalSmokeApp extends StatefulWidget {
  const AndroidTimelineCompositorPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineCompositorPhysicalSmokeApp> createState() =>
      _AndroidTimelineCompositorPhysicalSmokeAppState();
}

class _AndroidTimelineCompositorPhysicalSmokeAppState
    extends State<AndroidTimelineCompositorPhysicalSmokeApp> {
  String _status =
      'Initializing VGTimelineCompositorNode Topology/Math Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('${_logPrefix}_SMOKE_START');
    String? topLevelError;
    VGTimelineCompositorSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;

    try {
      report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            timeout: const Duration(seconds: 10),
          ).timeout(const Duration(seconds: 20));

      lane1Pass = report.pass == true;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} failureReason=${report.failureReason}',
      );

      lane2Pass = report.topologyPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass topologyPass=${report.topologyPass} '
        'kindOk=${report.kindPass} typeOk=${report.typePass} '
        'inputPortCountOk=${report.inputPortCountPass} '
        'outputPortCountOk=${report.outputPortCountPass} '
        'portIdsOk=${report.portIdsPass}',
      );

      lane3Pass = report.mathPass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass mathPass=${report.mathPass} '
        'hardCutOk=${report.hardCutPass} '
        'crossfadeStartOk=${report.crossfadeStartPass} '
        'crossfadeMidOk=${report.crossfadeMidPass} '
        'crossfadeEndOk=${report.crossfadeEndPass} '
        'slideLeftMidOk=${report.slideLeftMidPass} '
        'wipeLeftMidOk=${report.wipeLeftMidPass} '
        'speedMappingOk=${report.speedMappingPass} '
        'outsideTimelineOk=${report.outsideTimelinePass} '
        'invalidTransitionIgnoredOk=${report.invalidTransitionIgnoredPass} '
        'zeroDurationSafeOk=${report.zeroDurationSafePass} '
        'overflowSafeOk=${report.overflowSafePass}',
      );

      lane4Pass = report.hasPassMarker;
      print('${_logPrefix}_LANE_4: pass=$lane4Pass marker=${report.marker}');

      lane5Pass = report.hasCanonicalProofBoundary;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass proofBoundary=${report.proofBoundary}',
      );

      final map = report.toMap();
      final roundTrip = VGTimelineCompositorSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane6Pass =
          report.isVerifiedPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass isVerifiedPass=${report.isVerifiedPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: VGTimelineCompositorNode smoke exceeded timeout: $te';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } finally {
      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          lane6Pass &&
          topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidTimelineCompositorSmokeHarness',
        'slice': 'P5-COMPOSITOR-TRANS-NODE-TOPOLOGY-MATH',
        'target': VGTimelineCompositorSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_pass': {'pass': lane1Pass, 'reportPass': report?.pass},
          'lane2_topology': {
            'pass': lane2Pass,
            'topologyPass': report?.topologyPass,
          },
          'lane3_math': {'pass': lane3Pass, 'mathPass': report?.mathPass},
          'lane4_marker': {'pass': lane4Pass, 'marker': report?.marker},
          'lane5_proofBoundary': {
            'pass': lane5Pass,
            'proofBoundary': report?.proofBoundary,
          },
          'lane6_verifiedAndContract': {
            'pass': lane6Pass,
            'isVerifiedPass': report?.isVerifiedPass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'nativeAllLanesPass': report?.nativeAllLanesPass,
          },
        },
        'smokeReport': report?.toMap(),
        'error': topLevelError,
      };

      print('${_logPrefix}_JSON:${jsonEncode(payload)}');
      print(allPass ? _passMarker : _failMarker);

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
