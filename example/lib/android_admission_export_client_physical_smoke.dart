// android_admission_export_client_physical_smoke.dart
// Vanguard Media Engine -- Phase 2-Unit AF
// Public Dart Admission-Driven Export Execution Client Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

String sidecarPathForVideoPath(String videoPath) {
  final lastSeparator = videoPath.lastIndexOf('/');
  final lastDot = videoPath.lastIndexOf('.');
  if (lastDot <= lastSeparator) {
    return '$videoPath.roi.json';
  }
  return '${videoPath.substring(0, lastDot)}.roi.json';
}

void main() {
  runApp(const AndroidAdmissionExportClientPhysicalSmokeApp());
}

class AndroidAdmissionExportClientPhysicalSmokeApp extends StatefulWidget {
  const AndroidAdmissionExportClientPhysicalSmokeApp({super.key});

  @override
  State<AndroidAdmissionExportClientPhysicalSmokeApp> createState() =>
      _AndroidAdmissionExportClientPhysicalSmokeAppState();
}

class _AndroidAdmissionExportClientPhysicalSmokeAppState
    extends State<AndroidAdmissionExportClientPhysicalSmokeApp> {
  String _status =
      'Initializing Android Admission Export Client Physical Smoke (Unit AF)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF: TIMEOUT (90s exceeded)');
      print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_PHYSICAL_FAIL');
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
    print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF: START');
    final runId = 'unit_af_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? fixtureFile;
    File? lane1OutputFile;
    File? lane1SidecarFile;
    File? lane2OutputFile;
    File? lane2SidecarFile;
    File? lane4RenderOutputFile;
    File? lane4ReportedSidecarFile;
    File? lane4ExpectedSidecarFile;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};
    Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic> lane5Map = <String, dynamic>{};

    String? topLevelError;

    try {
      // -- Copy Asset Fixture to System Temp ---------------------------------
      print(
        'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF: Copying clip_B.mov to temp...',
      );
      final clipByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final rawBytes = clipByteData.buffer.asUint8List(
        clipByteData.offsetInBytes,
        clipByteData.lengthInBytes,
      );

      fixtureFile = File('${tempDir.path}/${runId}_source_clip_B.mov');
      await fixtureFile.writeAsBytes(rawBytes, flush: true);
      final sourcePath = fixtureFile.path;
      print(
        'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF: Source fixture ready at $sourcePath (${rawBytes.length} bytes)',
      );

      final defaultClient = VGEditorAdmissionExportClient();

      // -- Lane 1: Default client with single valid clip + outputPath --------
      print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE1: START');
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_out.mp4';
      final lane1ExpectedSidecarPath = sidecarPathForVideoPath(lane1OutputPath);
      lane1OutputFile = File(lane1OutputPath);
      lane1SidecarFile = File(lane1ExpectedSidecarPath);
      final lane1TempFile = File('$lane1OutputPath.vgptmp');
      final lane1SidecarTempFile = File('$lane1ExpectedSidecarPath.vgtmp');
      try {
        final lane1Draft = VGEditorDraft(
          id: 'draft-lane-1',
          clips: [_makeClip(id: 'c1', sourcePath: sourcePath)],
          canvasWidth: 1080,
          canvasHeight: 1920,
          fps: 30,
        );

        final lane1Report = await defaultClient.export(
          draft: lane1Draft,
          request: VGEditorExportRequest(outputPath: lane1OutputPath),
        );
        lane1Map = lane1Report.toMap();

        final outExists = await lane1OutputFile.exists();
        final outDiskBytes = outExists ? await lane1OutputFile.length() : 0;
        final passthroughReport = lane1Report.passthroughReport;
        final passthroughOutputBytes = passthroughReport?.outputSizeBytes ?? -1;
        final diskBytesMatch =
            outExists &&
            (outDiskBytes == passthroughOutputBytes) &&
            (outDiskBytes > 0);

        final sidecarExists = await lane1SidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await lane1SidecarFile.readAsString()
            : '';
        const expectedSidecarJson = '{"version":1,"rois":[]}';
        final sidecarContentValid = sidecarContent == expectedSidecarJson;
        final sidecarPathMatch =
            passthroughReport != null &&
            (passthroughReport.exportRoiSidecarPath ==
                lane1ExpectedSidecarPath) &&
            (passthroughReport.roiSidecarPath == lane1ExpectedSidecarPath);
        final sidecarTempExists = await lane1SidecarTempFile.exists();
        final outTempExists = await lane1TempFile.exists();

        final successFlag = lane1Report.success;
        final isPassthrough = lane1Report.isPassthrough;
        final routeModeMatch =
            lane1Report.routeMode == VGEditorExportRouteMode.passthroughRemux;
        final reasonMatch =
            lane1Report.reason == 'passthrough_export_succeeded';
        final passthroughSuccess = passthroughReport?.success == true;
        final passthroughProofMatch =
            passthroughReport?.proofBoundaryMatches == true;
        final passthroughNonClaimsHold =
            passthroughReport?.diagnosticNonClaimsHold == true;
        final afProofBoundaryMatch =
            lane1Report.proofBoundary ==
            VGEditorAdmissionExportReport.expectedProofBoundary;

        lane1Pass =
            successFlag &&
            isPassthrough &&
            routeModeMatch &&
            reasonMatch &&
            outExists &&
            diskBytesMatch &&
            passthroughSuccess &&
            passthroughProofMatch &&
            passthroughNonClaimsHold &&
            afProofBoundaryMatch &&
            sidecarExists &&
            sidecarContentValid &&
            sidecarPathMatch &&
            !sidecarTempExists &&
            !outTempExists;

        lane1Map['computed_pass'] = lane1Pass;
        lane1Map['outDiskBytes'] = outDiskBytes;
        lane1Map['outExists'] = outExists;
        lane1Map['sidecarExists'] = sidecarExists;
        lane1Map['sidecarContentValid'] = sidecarContentValid;
        lane1Map['sidecarPathMatch'] = sidecarPathMatch;
        lane1Map['exportRoiSidecarPath'] =
            passthroughReport?.exportRoiSidecarPath;
        lane1Map['roiSidecarPath'] = passthroughReport?.roiSidecarPath;
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE1_SIDECAR_EXISTS: $sidecarExists',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE1_SIDECAR_CONTENT_VALID: $sidecarContentValid',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE1_REPORT_SIDECAR_PATH_MATCH: $sidecarPathMatch',
        );
        print(
          'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE1: DONE (pass=$lane1Pass, route=${lane1Report.routeMode.name}, bytes=$outDiskBytes, sidecar=$sidecarExists)',
        );
      } catch (e, st) {
        print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // -- Lane 2: Default client with missing source + outputPath -----------
      print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE2: START');
      final missingSourcePath =
          '${tempDir.path}/${runId}_missing_nonexistent.mov';
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_out.mp4';
      final lane2ExpectedSidecarPath = sidecarPathForVideoPath(lane2OutputPath);
      lane2OutputFile = File(lane2OutputPath);
      final lane2TempFile = File('$lane2OutputPath.vgptmp');
      lane2SidecarFile = File(lane2ExpectedSidecarPath);
      final lane2SidecarTempFile = File('$lane2ExpectedSidecarPath.vgtmp');
      try {
        final lane2Draft = VGEditorDraft(
          id: 'draft-lane-2',
          clips: [_makeClip(id: 'c1', sourcePath: missingSourcePath)],
          canvasWidth: 1080,
          canvasHeight: 1920,
          fps: 30,
        );

        final lane2Report = await defaultClient.export(
          draft: lane2Draft,
          request: VGEditorExportRequest(outputPath: lane2OutputPath),
        );
        lane2Map = lane2Report.toMap();

        final outExists = await lane2OutputFile.exists();
        final tempExists = await lane2TempFile.exists();
        final sidecarExists = await lane2SidecarFile.exists();
        final sidecarTempExists = await lane2SidecarTempFile.exists();
        final isBlocked = lane2Report.isBlocked;
        final routeBlocked =
            lane2Report.routeMode == VGEditorExportRouteMode.blocked;
        final reasonMatch =
            lane2Report.reason ==
            'admission_blocked:export_blocked:source_unavailable';
        final successFalse = !lane2Report.success;

        lane2Pass =
            successFalse &&
            isBlocked &&
            routeBlocked &&
            reasonMatch &&
            !outExists &&
            !tempExists &&
            !sidecarExists &&
            !sidecarTempExists;

        lane2Map['computed_pass'] = lane2Pass;
        lane2Map['outExists'] = outExists;
        lane2Map['tempExists'] = tempExists;
        lane2Map['sidecarExists'] = sidecarExists;
        lane2Map['sidecarTempExists'] = sidecarTempExists;
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE2_CLEANUP_VALID: ${!sidecarExists && !sidecarTempExists}',
        );
        print(
          'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE2: DONE (pass=$lane2Pass, route=${lane2Report.routeMode.name}, reason=${lane2Report.reason})',
        );
      } catch (e, st) {
        print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // -- Lane 3: Default client with valid clip and no outputPath ----------
      print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE3: START');
      try {
        final lane3Draft = VGEditorDraft(
          id: 'draft-lane-3',
          clips: [_makeClip(id: 'c1', sourcePath: sourcePath)],
          canvasWidth: 1080,
          canvasHeight: 1920,
          fps: 30,
        );

        final lane3Report = await defaultClient.export(
          draft: lane3Draft,
          request: const VGEditorExportRequest(outputPath: null),
        );
        lane3Map = lane3Report.toMap();

        final successFalse = !lane3Report.success;
        final isPassthrough = lane3Report.isPassthrough;
        final codeMatch =
            lane3Report.errorCode == 'PASSTHROUGH_OUTPUT_PATH_REQUIRED';
        final reasonMatch =
            lane3Report.reason == 'passthrough_output_path_required';

        lane3Pass = successFalse && isPassthrough && codeMatch && reasonMatch;

        lane3Map['computed_pass'] = lane3Pass;
        print(
          'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE3: DONE (pass=$lane3Pass, code=${lane3Report.errorCode}, reason=${lane3Report.reason})',
        );
      } catch (e, st) {
        print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }

      // -- Lane 4: Forced render dispatch to real headless render exporter ---
      print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE4: START');
      final lane4RenderOutputPath =
          '${tempDir.path}/${runId}_lane4_render_out.mp4';
      lane4RenderOutputFile = File(lane4RenderOutputPath);
      lane4ExpectedSidecarFile = File(
        sidecarPathForVideoPath(lane4RenderOutputPath),
      );
      try {
        final lane4Draft = VGEditorDraft(
          id: 'draft-lane-4',
          clips: [_makeClip(id: 'c1', sourcePath: sourcePath)],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
        );

        final forcedRenderClient = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return VGEditorExportAdmissionReport(
                  routeMode: VGEditorExportRouteMode.renderExport,
                  reason: 'forced_render_export_synthetic',
                  exportReadinessReport:
                      const VGEditorExportReadinessEvaluator().evaluate(
                        draft: draft,
                      ),
                  passthroughDecisionAttempted: false,
                );
              },
          renderExecutor: VanguardTimelineExporter.exportDraft,
        );

        final progressList = <double>[];
        final lane4Report = await forcedRenderClient.export(
          draft: lane4Draft,
          request: VGEditorExportRequest(
            outputPath: lane4RenderOutputPath,
            width: 720,
            height: 1280,
            fps: 30,
            bitrateBps: 4000000,
          ),
          onProgress: (p) => progressList.add(p),
        );
        lane4Map = lane4Report.toMap();

        final reportedSidecarPath =
            lane4Report.renderResult?.exportRoiSidecarPath;
        if (reportedSidecarPath != null && reportedSidecarPath.isNotEmpty) {
          lane4ReportedSidecarFile = File(reportedSidecarPath);
        }

        final renderOutExists = await lane4RenderOutputFile.exists();
        final renderOutBytes = renderOutExists
            ? await lane4RenderOutputFile.length()
            : 0;
        final renderResult = lane4Report.renderResult;
        final renderResultPathMatch =
            renderResult != null && renderResult.path == lane4RenderOutputPath;
        final successFlag = lane4Report.success;
        final isRender = lane4Report.isRender;
        final routeModeMatch =
            lane4Report.routeMode == VGEditorExportRouteMode.renderExport;
        final reasonMatch = lane4Report.reason == 'render_export_succeeded';
        final afProofBoundaryMatch =
            lane4Report.proofBoundary ==
            VGEditorAdmissionExportReport.expectedProofBoundary;

        lane4Pass =
            successFlag &&
            isRender &&
            routeModeMatch &&
            reasonMatch &&
            renderOutExists &&
            (renderOutBytes > 0) &&
            renderResultPathMatch &&
            afProofBoundaryMatch;

        lane4Map['computed_pass'] = lane4Pass;
        lane4Map['renderOutBytes'] = renderOutBytes;
        lane4Map['renderOutExists'] = renderOutExists;
        lane4Map['progressCount'] = progressList.length;
        print(
          'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE4: DONE (pass=$lane4Pass, route=${lane4Report.routeMode.name}, bytes=$renderOutBytes, progressSamples=${progressList.length})',
        );
      } catch (e, st) {
        print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE4: ERROR: $e\n$st');
        lane4Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane4Pass = false;
      }

      // -- Lane 5: Proof / Report Summary ------------------------------------
      print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE5: START');
      try {
        final expectedBoundary =
            VGEditorAdmissionExportReport.expectedProofBoundary;
        final lane1Boundary = lane1Map['proofBoundary'] as String? ?? '';
        final lane4Boundary = lane4Map['proofBoundary'] as String? ?? '';

        final boundaryValid =
            (lane1Boundary == expectedBoundary) &&
            (lane4Boundary == expectedBoundary);

        final standardNonClaims =
            VGEditorAdmissionExportReport.standardNonClaims;
        final standardNonClaimsValid =
            standardNonClaims.length == 3 &&
            standardNonClaims['controllerTouched'] == false &&
            standardNonClaims['connectAppTouched'] == false &&
            standardNonClaims['productionExportTimelineMutated'] == false;

        final routeBooleansValid =
            lane1Pass && lane2Pass && lane3Pass && lane4Pass;

        lane5Pass =
            boundaryValid && standardNonClaimsValid && routeBooleansValid;

        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'expectedBoundary': expectedBoundary,
          'lane1Boundary': lane1Boundary,
          'lane4Boundary': lane4Boundary,
          'boundaryValid': boundaryValid,
          'standardNonClaimsValid': standardNonClaimsValid,
          'routeBooleansValid': routeBooleansValid,
        };
        print(
          'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE5: DONE (pass=$lane5Pass, boundaryValid=$boundaryValid, standardNonClaimsValid=$standardNonClaimsValid)',
        );
      } catch (e, st) {
        print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE5: ERROR: $e\n$st');
        lane5Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane5Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // -- Guaranteed Clean up of only harness-owned files -------------------
      for (final f in [
        fixtureFile,
        lane1OutputFile,
        lane1SidecarFile,
        lane2OutputFile,
        lane2SidecarFile,
        lane4RenderOutputFile,
        lane4ReportedSidecarFile,
        lane4ExpectedSidecarFile,
        if (lane1OutputFile != null) File('${lane1OutputFile.path}.vgptmp'),
        if (lane1SidecarFile != null) File('${lane1SidecarFile.path}.vgtmp'),
        if (lane2OutputFile != null) File('${lane2OutputFile.path}.vgptmp'),
        if (lane2SidecarFile != null) File('${lane2SidecarFile.path}.vgtmp'),
        if (lane4RenderOutputFile != null)
          File('${lane4RenderOutputFile.path}.vgptmp'),
        if (lane4ReportedSidecarFile != null)
          File('${lane4ReportedSidecarFile.path}.vgtmp'),
        if (lane4ExpectedSidecarFile != null)
          File('${lane4ExpectedSidecarFile.path}.vgtmp'),
      ]) {
        if (f != null) {
          try {
            if (await f.exists()) {
              await f.delete();
            }
          } catch (_) {}
        }
      }
    }

    print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE1_PASS: $lane1Pass');
    print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE2_PASS: $lane2Pass');
    print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE3_PASS: $lane3Pass');
    print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE4_PASS: $lane4Pass');
    print('ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_LANE5_PASS: $lane5Pass');

    final allPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitAF',
      'target': 'android_admission_export_client_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_default_passthrough_export': lane1Map,
        'lane2_missing_source_blocked': lane2Map,
        'lane3_missing_output_path_rejected': lane3Map,
        'lane4_forced_render_export': lane4Map,
        'lane5_proof_report_summary': lane5Map,
      },
      'proofBoundary': VGEditorAdmissionExportReport.expectedProofBoundary,
      'error': topLevelError,
    };

    print(
      'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_JSON:${jsonEncode(payload)}',
    );
    print(
      allPass
          ? 'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_PHYSICAL_PASS'
          : 'ANDROID_ADMISSION_EXPORT_CLIENT_UNIT_AF_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(allPass ? 0 : 1);
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
