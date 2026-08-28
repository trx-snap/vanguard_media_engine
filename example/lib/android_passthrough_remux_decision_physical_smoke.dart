// android_passthrough_remux_decision_physical_smoke.dart
// Vanguard Media Engine -- Phase 2-Unit AB
// Public Passthrough Remux Decision Planner Physical Smoke Test.
//
// Invariants:
// - Uses public VGPassthroughRemuxDecisionPlanner API from package:vanguard_media_engine.
// - Pure Dart advisory planner composing preflight evaluation and native capability probing.
// - Zero native muxing, zero sample reads, zero output writing, zero codec allocation.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidPassthroughRemuxDecisionPhysicalSmokeApp());
}

class AndroidPassthroughRemuxDecisionPhysicalSmokeApp extends StatefulWidget {
  const AndroidPassthroughRemuxDecisionPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxDecisionPhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxDecisionPhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxDecisionPhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxDecisionPhysicalSmokeApp> {
  String _status =
      'Initializing Android Passthrough Remux Decision Smoke (Unit AB)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      print(
        'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB: TIMEOUT (30s exceeded)',
      );
      print('ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_PHYSICAL_FAIL');
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  VGClipDescriptor _makeClip({
    String id = 'clip-1',
    required String sourcePath,
    double durationSeconds = 10.0,
    double trimStartSeconds = 0.0,
    double trimEndSeconds = 10.0,
  }) {
    return VGClipDescriptor(
      id: id,
      sourcePath: sourcePath,
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: durationSeconds,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      speed: 1.0,
    );
  }

  Future<void> _runSmoke() async {
    print('ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB: START');
    Map<String, dynamic> resultMap = <String, dynamic>{};
    var overallPass = false;
    File? fixtureFile;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final runId = DateTime.now().millisecondsSinceEpoch;

      fixtureFile = File(
        '${tempDir.path}/passthrough_remux_decision_unit_ab_${runId}_clip_b.mov',
      );
      await fixtureFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // -- Lane 1: Eligible single-clip draft + default native planner --------
      final lane1Draft = VGEditorDraft(
        id: 'draft-lane-1',
        clips: [_makeClip(id: 'c1', sourcePath: fixtureFile.path)],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      const lane1Planner = VGPassthroughRemuxDecisionPlanner();
      final lane1Report = await lane1Planner.evaluate(
        draft: lane1Draft,
        request: const VGEditorExportRequest(
          outputPath: '/data/user/0/cache/export.mp4',
        ),
      );

      final lane1Pass =
          lane1Report.isReady == true &&
          lane1Report.canPassthroughRemux == true &&
          lane1Report.isBlocked == false &&
          lane1Report.capabilityProbeAttempted == true &&
          lane1Report.capabilityReport != null &&
          lane1Report.capabilityReport!.canPassthroughRemux == true &&
          lane1Report.reason == 'ready';

      print(
        'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_LANE1_PASS: $lane1Pass',
      );

      // -- Lane 2: Ineligible multi-clip draft + fake probe (verify probe not called) --
      var lane2ProbeCalled = false;
      final lane2Planner = VGPassthroughRemuxDecisionPlanner(
        capabilityProbe: (sourcePath) async {
          lane2ProbeCalled = true;
          return VGPassthroughRemuxCapabilityReport.failure('should_not_probe');
        },
      );
      final lane2Draft = VGEditorDraft(
        id: 'draft-lane-2',
        clips: [
          _makeClip(
            id: 'c1',
            sourcePath: fixtureFile.path,
            durationSeconds: 5.0,
            trimEndSeconds: 5.0,
          ),
          _makeClip(
            id: 'c2',
            sourcePath: fixtureFile.path,
            durationSeconds: 5.0,
            trimEndSeconds: 5.0,
          ),
        ],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      final lane2Report = await lane2Planner.evaluate(draft: lane2Draft);

      final lane2Pass =
          lane2Report.isReady == false &&
          lane2Report.canPassthroughRemux == false &&
          lane2Report.isBlocked == true &&
          lane2Report.capabilityProbeAttempted == false &&
          lane2ProbeCalled == false &&
          lane2Report.capabilityReport == null &&
          lane2Report.reason == 'preflight_ineligible';

      print(
        'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_LANE2_PASS: $lane2Pass',
      );

      // -- Lane 3: Eligible draft with missing source path + native probe -----
      const missingSourcePath =
          '/data/user/0/com.connects.vanguard/cache/missing_non_existent_clip_12345.mp4';
      final lane3Draft = VGEditorDraft(
        id: 'draft-lane-3',
        clips: [_makeClip(id: 'c1', sourcePath: missingSourcePath)],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      const lane3Planner = VGPassthroughRemuxDecisionPlanner();
      final lane3Report = await lane3Planner.evaluate(draft: lane3Draft);

      final lane3Pass =
          lane3Report.isReady == false &&
          lane3Report.canPassthroughRemux == false &&
          lane3Report.isBlocked == true &&
          lane3Report.capabilityProbeAttempted == true &&
          lane3Report.capabilityReport != null &&
          lane3Report.capabilityReport!.fileExists == false &&
          lane3Report.reason.contains('capability_ineligible');

      print(
        'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_LANE3_PASS: $lane3Pass',
      );

      // -- Lane 4: Proof boundary + Non-claims on Lane 1 Report -----------------
      final proofBoundaryPass =
          lane1Report.proofBoundaryMatches == true &&
          lane1Report.proofBoundary ==
              'passthrough_remux_decision_planner_preflight_composite_advisory';

      final nonClaimsPass = lane1Report.diagnosticNonClaimsHold == true;

      final lane4Pass = proofBoundaryPass && nonClaimsPass;

      print(
        'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_PROOF_BOUNDARY: $proofBoundaryPass',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_NON_CLAIMS: $nonClaimsPass',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_LANE4_PASS: $lane4Pass',
      );

      overallPass = lane1Pass && lane2Pass && lane3Pass && lane4Pass;

      resultMap = <String, dynamic>{
        'pass': overallPass,
        'lane1Pass': lane1Pass,
        'lane2Pass': lane2Pass,
        'lane3Pass': lane3Pass,
        'lane4Pass': lane4Pass,
        'proofBoundaryMatches': proofBoundaryPass,
        'diagnosticNonClaimsHold': nonClaimsPass,
        'lane1Report': lane1Report.toMap(),
        'lane2Report': lane2Report.toMap(),
        'lane3Report': lane3Report.toMap(),
      };
    } catch (e, st) {
      print('ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB: ERROR: $e\n$st');
      resultMap = <String, dynamic>{'pass': false, 'error': '$e'};
      overallPass = false;
    } finally {
      if (fixtureFile != null) {
        try {
          if (await fixtureFile.exists()) {
            await fixtureFile.delete();
          }
        } catch (_) {}
      }
    }

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitAB',
      'target': 'android_passthrough_remux_decision_physical',
      'pass': overallPass,
      'result': resultMap,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_JSON:${jsonEncode(payload)}',
    );
    print(
      overallPass
          ? 'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_DECISION_UNIT_AB_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(overallPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
