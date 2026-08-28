// android_passthrough_export_admission_physical_smoke.dart
// Vanguard Media Engine -- Phase 2-Unit AC
// Public Export Route Admission Planner Physical Smoke Test.
//
// Invariants:
// - Uses public VGEditorExportAdmissionPlanner API from package:vanguard_media_engine.
// - Pure Dart advisory planner composing Unit J readiness and Unit AB passthrough remux decision.
// - Zero native muxing, zero sample reads, zero output writing, zero codec allocation.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidPassthroughExportAdmissionPhysicalSmokeApp());
}

class AndroidPassthroughExportAdmissionPhysicalSmokeApp extends StatefulWidget {
  const AndroidPassthroughExportAdmissionPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughExportAdmissionPhysicalSmokeApp> createState() =>
      _AndroidPassthroughExportAdmissionPhysicalSmokeAppState();
}

class _AndroidPassthroughExportAdmissionPhysicalSmokeAppState
    extends State<AndroidPassthroughExportAdmissionPhysicalSmokeApp> {
  String _status =
      'Initializing Android Passthrough Export Admission Smoke (Unit AC)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC: TIMEOUT (30s exceeded)',
      );
      print('ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_PHYSICAL_FAIL');
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
    print('ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC: START');
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
        '${tempDir.path}/passthrough_export_admission_unit_ac_${runId}_clip_b.mov',
      );
      await fixtureFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // -- Lane 1: Valid single clip default planner -> passthroughRemux -------
      final lane1Draft = VGEditorDraft(
        id: 'draft-lane-1',
        clips: [_makeClip(id: 'c1', sourcePath: fixtureFile.path)],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      const lane1Planner = VGEditorExportAdmissionPlanner();
      final lane1Report = await lane1Planner.evaluate(
        draft: lane1Draft,
        request: const VGEditorExportRequest(
          outputPath: '/data/user/0/cache/export.mp4',
        ),
      );

      final lane1Pass =
          lane1Report.routeMode == VGEditorExportRouteMode.passthroughRemux &&
          lane1Report.usePassthroughRemux == true &&
          lane1Report.useRenderExport == false &&
          lane1Report.isBlocked == false &&
          lane1Report.reason == 'passthrough_ready' &&
          lane1Report.passthroughDecisionAttempted == true &&
          lane1Report.passthroughDecisionReport != null &&
          lane1Report.passthroughDecisionReport!.isReady == true;

      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_LANE1_PASS: $lane1Pass',
      );

      // -- Lane 2: Plain multi-clip default planner -> renderExport ------------
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
      const lane2Planner = VGEditorExportAdmissionPlanner();
      final lane2Report = await lane2Planner.evaluate(draft: lane2Draft);

      final lane2Pass =
          lane2Report.routeMode == VGEditorExportRouteMode.renderExport &&
          lane2Report.useRenderExport == true &&
          lane2Report.usePassthroughRemux == false &&
          lane2Report.isBlocked == false &&
          lane2Report.reason == 'render_export_ready' &&
          lane2Report.passthroughDecisionAttempted == true &&
          lane2Report.passthroughDecisionReport != null &&
          lane2Report.passthroughDecisionReport!.isBlocked == true;

      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_LANE2_PASS: $lane2Pass',
      );

      // -- Lane 3: Unit J blocked draft with injected probe not called -> blocked
      var lane3ProbeCalled = false;
      final lane3Planner = VGEditorExportAdmissionPlanner(
        passthroughDecisionProbe:
            ({required draft, request = const VGEditorExportRequest()}) async {
              lane3ProbeCalled = true;
              return const VGPassthroughRemuxDecisionPlanner().evaluate(
                draft: draft,
                request: request,
              );
            },
      );
      final lane3Draft = VGEditorDraft(
        id: 'draft-lane-3',
        clips: [_makeClip(id: 'c1', sourcePath: fixtureFile.path)],
        transitions: [
          VGTransitionDescriptor(
            id: 't1',
            type: VGTransitionType.dissolve,
            durationSeconds: 1.0,
          ),
        ],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      final lane3Report = await lane3Planner.evaluate(draft: lane3Draft);

      final lane3Pass =
          lane3Report.routeMode == VGEditorExportRouteMode.blocked &&
          lane3Report.isBlocked == true &&
          lane3Report.usePassthroughRemux == false &&
          lane3Report.useRenderExport == false &&
          lane3Report.reason == 'export_blocked' &&
          lane3Report.passthroughDecisionAttempted == false &&
          lane3ProbeCalled == false &&
          lane3Report.passthroughDecisionReport == null &&
          lane3Report.exportReadinessReport.isBlocked == true;

      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_LANE3_PASS: $lane3Pass',
      );

      // -- Lane 4: Missing source single clip default planner -> blocked source_unavailable
      const missingSourcePath =
          '/data/user/0/com.connects.vanguard/cache/missing_unit_ac_clip_12345.mp4';
      final lane4Draft = VGEditorDraft(
        id: 'draft-lane-4',
        clips: [_makeClip(id: 'c1', sourcePath: missingSourcePath)],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      const lane4Planner = VGEditorExportAdmissionPlanner();
      final lane4Report = await lane4Planner.evaluate(draft: lane4Draft);

      final lane4Pass =
          lane4Report.routeMode == VGEditorExportRouteMode.blocked &&
          lane4Report.isBlocked == true &&
          lane4Report.usePassthroughRemux == false &&
          lane4Report.useRenderExport == false &&
          lane4Report.reason == 'export_blocked:source_unavailable' &&
          lane4Report.passthroughDecisionAttempted == true &&
          lane4Report.passthroughDecisionReport != null &&
          lane4Report.passthroughDecisionReport!.capabilityReport != null &&
          lane4Report.passthroughDecisionReport!.capabilityReport!.fileExists ==
              false;

      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_LANE4_PASS: $lane4Pass',
      );

      // -- Lane 5: Proof boundary + Non-claims on Lane 1 Report -----------------
      final proofBoundaryPass =
          lane1Report.proofBoundaryMatches == true &&
          lane1Report.proofBoundary ==
              VGEditorExportAdmissionReport.expectedProofBoundary;

      final nonClaimsPass = lane1Report.diagnosticNonClaimsHold == true;

      final lane5Pass = proofBoundaryPass && nonClaimsPass;

      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_PROOF_BOUNDARY: $proofBoundaryPass',
      );
      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_NON_CLAIMS: $nonClaimsPass',
      );
      print(
        'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_LANE5_PASS: $lane5Pass',
      );

      overallPass =
          lane1Pass && lane2Pass && lane3Pass && lane4Pass && lane5Pass;

      resultMap = <String, dynamic>{
        'pass': overallPass,
        'lane1Pass': lane1Pass,
        'lane2Pass': lane2Pass,
        'lane3Pass': lane3Pass,
        'lane4Pass': lane4Pass,
        'lane5Pass': lane5Pass,
        'proofBoundaryMatches': proofBoundaryPass,
        'diagnosticNonClaimsHold': nonClaimsPass,
        'lane1Report': lane1Report.toMap(),
        'lane2Report': lane2Report.toMap(),
        'lane3Report': lane3Report.toMap(),
        'lane4Report': lane4Report.toMap(),
      };
    } catch (e, st) {
      print('ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC: ERROR: $e\n$st');
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
      'unit': 'Phase2UnitAC',
      'target': 'android_passthrough_export_admission_physical',
      'pass': overallPass,
      'result': resultMap,
    };

    print(
      'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_JSON:${jsonEncode(payload)}',
    );
    print(
      overallPass
          ? 'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_EXPORT_ADMISSION_UNIT_AC_PHYSICAL_FAIL',
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
