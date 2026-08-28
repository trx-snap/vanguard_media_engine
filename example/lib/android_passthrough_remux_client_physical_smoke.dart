// android_passthrough_remux_client_physical_smoke.dart
// Vanguard Media Engine -- Phase 2-Unit AE
// Public Dart Android Passthrough Remux Execution Client Physical Smoke Test.

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
  runApp(const AndroidPassthroughRemuxClientPhysicalSmokeApp());
}

class AndroidPassthroughRemuxClientPhysicalSmokeApp extends StatefulWidget {
  const AndroidPassthroughRemuxClientPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxClientPhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxClientPhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxClientPhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxClientPhysicalSmokeApp> {
  String _status =
      'Initializing Android Passthrough Remux Client Physical Smoke (Unit AE)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: TIMEOUT (45s exceeded)');
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_PHYSICAL_FAIL');
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

  Future<void> _runSmoke() async {
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: START');
    final runId = 'unit_ae_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? fixtureFile;
    File? lane1OutputFile;
    File? lane1SidecarFile;
    File? lane2OutputFile;
    File? lane2SidecarFile;
    File? lane3Mp4SentinelFile;
    File? lane3SidecarSentinelFile;
    File? lane3SidecarOutputFile;
    File? lane4EmptySourceOutputFile;
    File? lane5FirstOutputFile;
    File? lane5FirstSidecarFile;
    File? lane5SecondOutputFile;
    File? lane5SecondSidecarFile;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};
    Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic> lane5Map = <String, dynamic>{};
    Map<String, dynamic> lane6Map = <String, dynamic>{};

    String? topLevelError;

    try {
      // -- Copy Asset Fixture to System Temp ---------------------------------
      print(
        'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: Copying clip_B.mov to temp...',
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
        'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: Source fixture ready at $sourcePath (${rawBytes.length} bytes)',
      );

      final client = VGPassthroughRemuxClient();

      // -- Lane 1: Primary valid client remux ---------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1: START');
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_out.mp4';
      final lane1ExpectedSidecarPath = sidecarPathForVideoPath(lane1OutputPath);
      lane1OutputFile = File(lane1OutputPath);
      lane1SidecarFile = File(lane1ExpectedSidecarPath);
      final lane1TempFile = File('$lane1OutputPath.vgptmp');
      final lane1SidecarTempFile = File('$lane1ExpectedSidecarPath.vgtmp');
      try {
        final lane1Report = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane1OutputPath,
          ),
        );
        lane1Map = lane1Report.toMap();

        final outExists = await lane1OutputFile.exists();
        final outDiskBytes = outExists ? await lane1OutputFile.length() : 0;
        final outputSizeBytes = lane1Report.outputSizeBytes ?? -1;
        final diskBytesMatch =
            outExists &&
            (outDiskBytes == outputSizeBytes) &&
            (outDiskBytes > 0);

        final sidecarExists = await lane1SidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await lane1SidecarFile.readAsString()
            : '';
        const expectedSidecarJson = '{"version":1,"rois":[]}';
        final sidecarContentValid = sidecarContent == expectedSidecarJson;
        final sidecarPathMatches =
            (lane1Report.exportRoiSidecarPath == lane1ExpectedSidecarPath) &&
            (lane1Report.roiSidecarPath == lane1ExpectedSidecarPath);
        final sidecarTempExists = await lane1SidecarTempFile.exists();
        final outTempExists = await lane1TempFile.exists();

        final successFlag = lane1Report.success;
        final pathMatch =
            (lane1Report.path == lane1OutputPath) &&
            (lane1Report.outputPath == lane1OutputPath) &&
            (lane1Report.sourcePath == sourcePath);
        final videoSamples = lane1Report.videoSamples ?? 0;
        final audioSamples = lane1Report.audioSamples ?? 0;
        final width = lane1Report.width ?? 0;
        final height = lane1Report.height ?? 0;
        final durationSeconds = lane1Report.durationSeconds ?? 0.0;
        final hasAudioTrack = lane1Report.hasAudioTrack == true;
        final proofBoundaryMatch = lane1Report.proofBoundaryMatches;
        final nonClaimsMatch = lane1Report.diagnosticNonClaimsHold;
        final outputWritten = lane1Report.outputWritten;

        lane1Pass =
            successFlag &&
            outExists &&
            diskBytesMatch &&
            outputWritten &&
            pathMatch &&
            videoSamples > 0 &&
            audioSamples > 0 &&
            width > 0 &&
            height > 0 &&
            durationSeconds > 0 &&
            hasAudioTrack &&
            proofBoundaryMatch &&
            nonClaimsMatch &&
            sidecarExists &&
            sidecarContentValid &&
            sidecarPathMatches &&
            !sidecarTempExists &&
            !outTempExists;

        lane1Map['computed_pass'] = lane1Pass;
        lane1Map['outDiskBytes'] = outDiskBytes;
        lane1Map['outExists'] = outExists;
        lane1Map['sidecarExists'] = sidecarExists;
        lane1Map['sidecarContentValid'] = sidecarContentValid;
        lane1Map['sidecarPathMatches'] = sidecarPathMatches;
        lane1Map['exportRoiSidecarPath'] = lane1Report.exportRoiSidecarPath;
        lane1Map['roiSidecarPath'] = lane1Report.roiSidecarPath;
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE1_SIDECAR_EXISTS: $sidecarExists',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE1_SIDECAR_CONTENT_VALID: $sidecarContentValid',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE1_REPORT_SIDECAR_PATH_MATCH: $sidecarPathMatches',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1: DONE (pass=$lane1Pass, videoSamples=$videoSamples, audioSamples=$audioSamples, bytes=$outDiskBytes, sidecar=$sidecarExists)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // -- Lane 2: Missing source through client ------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2: START');
      final missingSourcePath =
          '${tempDir.path}/${runId}_missing_nonexistent.mov';
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_out.mp4';
      final lane2ExpectedSidecarPath = sidecarPathForVideoPath(lane2OutputPath);
      lane2OutputFile = File(lane2OutputPath);
      final lane2TempFile = File('$lane2OutputPath.vgptmp');
      lane2SidecarFile = File(lane2ExpectedSidecarPath);
      final lane2SidecarTempFile = File('$lane2ExpectedSidecarPath.vgtmp');
      try {
        final lane2Report = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: missingSourcePath,
            outputPath: lane2OutputPath,
          ),
        );
        lane2Map = lane2Report.toMap();

        final outExists = await lane2OutputFile.exists();
        final tempExists = await lane2TempFile.exists();
        final sidecarExists = await lane2SidecarFile.exists();
        final sidecarTempExists = await lane2SidecarTempFile.exists();
        final codeMatch = lane2Report.errorCode == 'FILE_UNREADABLE';
        lane2Pass =
            !lane2Report.success &&
            codeMatch &&
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
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2: DONE (pass=$lane2Pass, code=${lane2Report.errorCode}, outExists=$outExists, tempExists=$tempExists, sidecarExists=$sidecarExists)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // -- Lane 3: Existing output sentinel and existing sidecar sentinel -----
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3: START');
      final lane3Mp4OutputPath = '${tempDir.path}/${runId}_lane3_sentinel.mp4';
      lane3Mp4SentinelFile = File(lane3Mp4OutputPath);
      final lane3Mp4TempFile = File('$lane3Mp4OutputPath.vgptmp');
      const sentinelMp4Content =
          'SENTINEL_PRE_EXISTING_UNIT_AE_OUTPUT_BYTES_GUARD';

      final lane3SidecarOutputPath =
          '${tempDir.path}/${runId}_lane3_sidecar_sentinel.mp4';
      final lane3ExpectedSidecarSentinelPath = sidecarPathForVideoPath(
        lane3SidecarOutputPath,
      );
      lane3SidecarSentinelFile = File(lane3ExpectedSidecarSentinelPath);
      lane3SidecarOutputFile = File(lane3SidecarOutputPath);
      final lane3SidecarOutputTempFile = File('$lane3SidecarOutputPath.vgptmp');
      final lane3SidecarTempFile = File(
        '$lane3ExpectedSidecarSentinelPath.vgtmp',
      );
      const sentinelSidecarContent =
          'SENTINEL_PRE_EXISTING_UNIT_L_SIDECAR_BYTES_GUARD';

      try {
        // Part A: Pre-existing output MP4 sentinel
        await lane3Mp4SentinelFile.writeAsString(
          sentinelMp4Content,
          flush: true,
        );
        final lane3ReportA = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane3Mp4OutputPath,
          ),
        );

        final mp4SentinelStillExists = await lane3Mp4SentinelFile.exists();
        final currentMp4SentinelContent = mp4SentinelStillExists
            ? await lane3Mp4SentinelFile.readAsString()
            : '';
        final mp4SentinelPreserved =
            mp4SentinelStillExists &&
            (currentMp4SentinelContent == sentinelMp4Content);
        final mp4TempExists = await lane3Mp4TempFile.exists();
        final partAPass =
            !lane3ReportA.success &&
            lane3ReportA.errorCode == 'OUTPUT_EXISTS' &&
            mp4SentinelPreserved &&
            !mp4TempExists;

        // Part B: Pre-existing sidecar sentinel for absent output MP4
        await lane3SidecarSentinelFile.writeAsString(
          sentinelSidecarContent,
          flush: true,
        );
        final lane3ReportB = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane3SidecarOutputPath,
          ),
        );

        final sidecarSentinelStillExists = await lane3SidecarSentinelFile
            .exists();
        final currentSidecarSentinelContent = sidecarSentinelStillExists
            ? await lane3SidecarSentinelFile.readAsString()
            : '';
        final sidecarSentinelPreserved =
            sidecarSentinelStillExists &&
            (currentSidecarSentinelContent == sentinelSidecarContent);
        final sidecarOutExists = await lane3SidecarOutputFile.exists();
        final sidecarOutTempExists = await lane3SidecarOutputTempFile.exists();
        final sidecarTempExists = await lane3SidecarTempFile.exists();
        final partBPass =
            !lane3ReportB.success &&
            lane3ReportB.errorCode == 'OUTPUT_EXISTS' &&
            sidecarSentinelPreserved &&
            !sidecarOutExists &&
            !sidecarOutTempExists &&
            !sidecarTempExists;

        lane3Pass = partAPass && partBPass;

        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'partAPass': partAPass,
          'partBPass': partBPass,
          'codeA': lane3ReportA.errorCode,
          'codeB': lane3ReportB.errorCode,
          'mp4SentinelPreserved': mp4SentinelPreserved,
          'sidecarSentinelPreserved': sidecarSentinelPreserved,
          'sidecarOutExists': sidecarOutExists,
          'sidecarOutTempExists': sidecarOutTempExists,
          'sidecarTempExists': sidecarTempExists,
        };

        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE3_SIDECAR_SENTINEL_GUARD: $partBPass',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3: DONE (pass=$lane3Pass, partA=$partAPass, partB=$partBPass)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }

      // -- Lane 4: Local validation -------------------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4: START');
      final lane4EmptySourceOutputPath =
          '${tempDir.path}/${runId}_lane4_blank_source_out.mp4';
      lane4EmptySourceOutputFile = File(lane4EmptySourceOutputPath);
      final lane4EmptySourceTempFile = File(
        '$lane4EmptySourceOutputPath.vgptmp',
      );
      try {
        final blankSourceRequest = VGPassthroughRemuxRequest(
          sourcePath: '   ',
          outputPath: lane4EmptySourceOutputPath,
        );
        final blankSourceReport = await client.export(blankSourceRequest);

        final blankOutputRequest = VGPassthroughRemuxRequest(
          sourcePath: sourcePath,
          outputPath: '  \t\n  ',
        );
        final blankOutputReport = await client.export(blankOutputRequest);

        final emptySourceOutExists = await lane4EmptySourceOutputFile.exists();
        final emptySourceTempExists = await lane4EmptySourceTempFile.exists();

        final blankSourcePass =
            !blankSourceReport.success &&
            (blankSourceReport.errorCode == 'source_path_empty') &&
            !emptySourceOutExists &&
            !emptySourceTempExists;

        final blankOutputPass =
            !blankOutputReport.success &&
            (blankOutputReport.errorCode == 'output_path_empty');

        lane4Pass = blankSourcePass && blankOutputPass;

        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'blankSourcePass': blankSourcePass,
          'blankOutputPass': blankOutputPass,
          'blankSourceErrorCode': blankSourceReport.errorCode,
          'blankOutputErrorCode': blankOutputReport.errorCode,
          'emptySourceOutExists': emptySourceOutExists,
          'emptySourceTempExists': emptySourceTempExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4: DONE (pass=$lane4Pass, blankSourceCode=${blankSourceReport.errorCode}, blankOutputCode=${blankOutputReport.errorCode})',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4: ERROR: $e\n$st');
        lane4Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane4Pass = false;
      }

      // -- Lane 5: Concurrency through client ---------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5: START');
      final lane5FirstOutputPath =
          '${tempDir.path}/${runId}_lane5_first_out.mp4';
      final lane5FirstExpectedSidecarPath = sidecarPathForVideoPath(
        lane5FirstOutputPath,
      );
      final lane5SecondOutputPath =
          '${tempDir.path}/${runId}_lane5_second_out.mp4';
      final lane5SecondExpectedSidecarPath = sidecarPathForVideoPath(
        lane5SecondOutputPath,
      );

      lane5FirstOutputFile = File(lane5FirstOutputPath);
      lane5FirstSidecarFile = File(lane5FirstExpectedSidecarPath);
      final lane5FirstTempFile = File('$lane5FirstOutputPath.vgptmp');
      final lane5FirstTempSidecarFile = File(
        '$lane5FirstExpectedSidecarPath.vgtmp',
      );

      lane5SecondOutputFile = File(lane5SecondOutputPath);
      lane5SecondSidecarFile = File(lane5SecondExpectedSidecarPath);
      final lane5SecondTempFile = File('$lane5SecondOutputPath.vgptmp');
      final lane5SecondTempSidecarFile = File(
        '$lane5SecondExpectedSidecarPath.vgtmp',
      );

      try {
        final firstFuture = client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane5FirstOutputPath,
            diagnosticHoldBeforeRemuxMs: 1200,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        final secondReport = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane5SecondOutputPath,
          ),
        );

        final firstReport = await firstFuture;

        final firstSuccess = firstReport.success;
        final firstOutExists = await lane5FirstOutputFile.exists();
        final firstOutBytes = firstOutExists
            ? await lane5FirstOutputFile.length()
            : 0;
        final firstSidecarExists = await lane5FirstSidecarFile.exists();
        final firstSidecarContent = firstSidecarExists
            ? await lane5FirstSidecarFile.readAsString()
            : '';
        const expectedSidecarJson = '{"version":1,"rois":[]}';
        final firstSidecarValid = firstSidecarContent == expectedSidecarJson;
        final firstSidecarPathMatch =
            (firstReport.exportRoiSidecarPath ==
                lane5FirstExpectedSidecarPath) &&
            (firstReport.roiSidecarPath == lane5FirstExpectedSidecarPath);
        final firstTempExists = await lane5FirstTempFile.exists();
        final firstTempSidecarExists = await lane5FirstTempSidecarFile.exists();

        final secondCodeMatch = secondReport.errorCode == 'EXPORT_IN_PROGRESS';
        final secondSuccessFalse = !secondReport.success;
        final secondOutExists = await lane5SecondOutputFile.exists();
        final secondTempExists = await lane5SecondTempFile.exists();
        final secondSidecarExists = await lane5SecondSidecarFile.exists();
        final secondTempSidecarExists = await lane5SecondTempSidecarFile
            .exists();

        final firstPass =
            firstSuccess &&
            firstOutExists &&
            firstOutBytes > 0 &&
            firstSidecarExists &&
            firstSidecarValid &&
            firstSidecarPathMatch &&
            !firstTempExists &&
            !firstTempSidecarExists;

        final secondPass =
            secondCodeMatch &&
            secondSuccessFalse &&
            !secondOutExists &&
            !secondTempExists &&
            !secondSidecarExists &&
            !secondTempSidecarExists;

        lane5Pass = firstPass && secondPass;

        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'firstPass': firstPass,
          'secondPass': secondPass,
          'secondErrorCode': secondReport.errorCode,
          'firstSuccess': firstSuccess,
          'firstOutExists': firstOutExists,
          'firstOutBytes': firstOutBytes,
          'firstSidecarExists': firstSidecarExists,
          'firstSidecarValid': firstSidecarValid,
          'firstSidecarPathMatch': firstSidecarPathMatch,
          'secondOutExists': secondOutExists,
          'secondTempExists': secondTempExists,
          'secondSidecarExists': secondSidecarExists,
          'secondTempSidecarExists': secondTempSidecarExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE5_FIRST_SIDECAR_VALID: $firstSidecarValid',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_ROI_SIDECAR_UNIT_L_LANE5_SECOND_CLEANUP_VALID: ${!secondSidecarExists && !secondTempSidecarExists}',
        );
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5: DONE (pass=$lane5Pass, secondCode=${secondReport.errorCode}, firstSuccess=$firstSuccess, firstBytes=$firstOutBytes, firstSidecar=$firstSidecarExists)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5: ERROR: $e\n$st');
        lane5Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane5Pass = false;
      }

      // -- Lane 6: Proof and non-claims summary -------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6: START');
      try {
        final lane1ProofBoundary = lane1Map['proofBoundary'] as String? ?? '';
        final lane1NonClaims = lane1Map['nonClaims'] is Map
            ? (lane1Map['nonClaims'] as Map).cast<String, dynamic>()
            : <String, dynamic>{};

        final boundaryValid =
            (lane1ProofBoundary ==
            VGPassthroughRemuxExecutionReport.expectedProofBoundary);
        final nonClaimsOnlyFour = lane1NonClaims.length == 4;
        final nonClaimsValuesFalse =
            lane1NonClaims['mediaCodecAllocated'] == false &&
            lane1NonClaims['productionExportTimelineBypass'] == false &&
            lane1NonClaims['cppPassthroughRemuxSinkNode'] == false &&
            lane1NonClaims['connectAppTouched'] == false;

        final nonClaimsValid = nonClaimsOnlyFour && nonClaimsValuesFalse;

        lane6Pass = lane1Pass && boundaryValid && nonClaimsValid;

        lane6Map = <String, dynamic>{
          'pass': lane6Pass,
          'proofBoundary': lane1ProofBoundary,
          'proofBoundaryValid': boundaryValid,
          'nonClaims': lane1NonClaims,
          'nonClaimsValid': nonClaimsValid,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6: DONE (pass=$lane6Pass, boundaryValid=$boundaryValid, nonClaimsValid=$nonClaimsValid)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6: ERROR: $e\n$st');
        lane6Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane6Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // -- Clean up only harness-owned temp files -----------------------------
      for (final f in [
        fixtureFile,
        lane1OutputFile,
        lane1SidecarFile,
        lane2OutputFile,
        lane2SidecarFile,
        lane3Mp4SentinelFile,
        lane3SidecarSentinelFile,
        lane3SidecarOutputFile,
        lane4EmptySourceOutputFile,
        lane5FirstOutputFile,
        lane5FirstSidecarFile,
        lane5SecondOutputFile,
        lane5SecondSidecarFile,
        if (lane1OutputFile != null) File('${lane1OutputFile.path}.vgptmp'),
        if (lane1SidecarFile != null) File('${lane1SidecarFile.path}.vgtmp'),
        if (lane2OutputFile != null) File('${lane2OutputFile.path}.vgptmp'),
        if (lane2SidecarFile != null) File('${lane2SidecarFile.path}.vgtmp'),
        if (lane3Mp4SentinelFile != null)
          File('${lane3Mp4SentinelFile.path}.vgptmp'),
        if (lane3SidecarSentinelFile != null)
          File('${lane3SidecarSentinelFile.path}.vgtmp'),
        if (lane3SidecarOutputFile != null)
          File('${lane3SidecarOutputFile.path}.vgptmp'),
        if (lane4EmptySourceOutputFile != null)
          File('${lane4EmptySourceOutputFile.path}.vgptmp'),
        if (lane5FirstOutputFile != null)
          File('${lane5FirstOutputFile.path}.vgptmp'),
        if (lane5FirstSidecarFile != null)
          File('${lane5FirstSidecarFile.path}.vgtmp'),
        if (lane5SecondOutputFile != null)
          File('${lane5SecondOutputFile.path}.vgptmp'),
        if (lane5SecondSidecarFile != null)
          File('${lane5SecondSidecarFile.path}.vgtmp'),
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

    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1_PASS: $lane1Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2_PASS: $lane2Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3_PASS: $lane3Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4_PASS: $lane4Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5_PASS: $lane5Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6_PASS: $lane6Pass');

    final allPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        lane6Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitAE',
      'target': 'android_passthrough_remux_client_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_primary_remux': lane1Map,
        'lane2_missing_source_guard': lane2Map,
        'lane3_output_exists_guard': lane3Map,
        'lane4_local_validation_guard': lane4Map,
        'lane5_concurrency_guard': lane5Map,
        'lane6_proof_nonclaims_summary': lane6Map,
      },
      'proofBoundary': VGPassthroughRemuxExecutionReport.expectedProofBoundary,
      'error': topLevelError,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_JSON:${jsonEncode(payload)}',
    );
    print(
      allPass
          ? 'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_PHYSICAL_FAIL',
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
