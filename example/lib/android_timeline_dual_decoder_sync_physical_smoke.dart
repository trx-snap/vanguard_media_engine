// android_timeline_dual_decoder_sync_physical_smoke.dart
// Vanguard Media Engine — P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC):
// Android True-DAG dual MediaCodec synchronized ingest -> AHardwareBuffer ->
// Vulkan crossfade proof diagnostic smoke physical harness.
//
// Fixture: assets/manual_test_clips/clip_B.mov is copied into TWO distinct
// temp files (clip0 / clip1). Both hardware decoder pipelines read their own
// file, so the smoke still proves two real, independent MediaCodec ->
// ImageReader.PRIVATE pipelines stepping in lockstep. clip_A.mov is not used
// as required proof input. Only those two temp copies are deleted in finally.
//
// Proof lanes:
//   Lane 1: smoke report pass == true, argumentValidationPass == true and
//           setupPass == true (both fixtures inspected as video tracks, both
//           hardware decoders + ImageReader.PRIVATE pipelines configured).
//   Lane 2: smoke report syncPass == true (clip0 lead-in, one Image from each
//           decoder per overlap step, strictly increasing pts / timestamps
//           per clip, overlap progress strictly inside (0,1) and echoed back
//           by native as matching crossfade blend weights).
//   Lane 3: smoke report nativePass == true (both AHardwareBuffers imported
//           into a temporary VkDevice and resolved to RGBA8 on every overlap
//           frame; compositor-owned ComputeTransitionGeometry(kCrossfade)
//           rendered through VulkanTimelineTransitionCompositor with pixel
//           telemetry matching the blend weights).
//   Lane 4: smoke report lifecyclePass == true (clip1 lead-out after the
//           overlap; every Image / codec / reader / extractor / thread and
//           every native import / scratch / device object released).
//   Lane 5: smoke report isVerifiedPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && canonical PASS marker && canonical proof
//           boundary && toMap() round-trips.
//
// Target / proof boundary:
//   native_android_dual_mediacodec_imagereader_ahb_to_vulkan_transition_crossfade_diagnostic_only_no_export
//   Diagnostic only: no AndroidTimelineExportSession, no production export
//   route, no encoder/mux, no audio, no app/editor UI. A device without a
//   usable Vulkan / AHardwareBuffer import path reports UNSUPPORTED (FAIL
//   marker, no crash). Exit code 0 is emitted only after the PASS marker.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_timeline_dual_decoder_sync_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC';
const String _fixtureAsset = 'assets/manual_test_clips/clip_B.mov';

void main() {
  runApp(const AndroidTimelineDualDecoderSyncPhysicalSmokeApp());
}

class AndroidTimelineDualDecoderSyncPhysicalSmokeApp extends StatefulWidget {
  const AndroidTimelineDualDecoderSyncPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineDualDecoderSyncPhysicalSmokeApp> createState() =>
      _AndroidTimelineDualDecoderSyncPhysicalSmokeAppState();
}

class _AndroidTimelineDualDecoderSyncPhysicalSmokeAppState
    extends State<AndroidTimelineDualDecoderSyncPhysicalSmokeApp> {
  String _status = 'Initializing Dual Decoder Sync Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  /// Copies the bundled fixture into a fresh temp file owned by this run.
  Future<File> _copyFixture(String suffix) async {
    final bytes = await rootBundle.load(_fixtureAsset);
    final runId = DateTime.now().microsecondsSinceEpoch;
    final file = File(
      '${Directory.systemTemp.path}/p5_dual_decoder_sync_${runId}_$suffix.mov',
    );
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return file;
  }

  /// Deletes only a temp copy created by this run; never touches anything
  /// else. Failures are logged and never mask the smoke verdict.
  Future<void> _deleteTempCopy(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
        print('${_logPrefix}_CLEANUP: deleted ${file.path}');
      }
    } catch (e) {
      print('${_logPrefix}_CLEANUP_WARN: could not delete ${file.path}: $e');
    }
  }

  Future<void> _runSmoke() async {
    print('${_logPrefix}_SMOKE_START');
    String? topLevelError;
    VGTimelineDualDecoderSyncSmokeReport? report;
    File? clip0;
    File? clip1;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;

    try {
      clip0 = await _copyFixture('clip0');
      clip1 = await _copyFixture('clip1');
      final clip0Bytes = await clip0.length();
      final clip1Bytes = await clip1.length();
      print(
        '${_logPrefix}_FIXTURES: asset=$_fixtureAsset '
        'clip0=${clip0.path} clip0Bytes=$clip0Bytes '
        'clip1=${clip1.path} clip1Bytes=$clip1Bytes '
        'distinctPaths=${clip0.path != clip1.path}',
      );
      if (clip0.path == clip1.path || clip0Bytes <= 0 || clip1Bytes <= 0) {
        throw StateError('fixture temp copies invalid');
      }

      report =
          await VGTimelineDualDecoderSyncSmokeReport.runAndroidDagPhase5TimelineDualDecoderSyncSmoke(
            clip0Path: clip0.path,
            clip1Path: clip1.path,
            timeout: const Duration(seconds: 90),
          ).timeout(const Duration(seconds: 100));

      lane1Pass =
          report.pass == true &&
          report.argumentValidationPass &&
          report.setupPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} '
        'argumentValidationOk=${report.argumentValidationPass} '
        'fixtureFormatOk=${report.fixtureFormatPass} '
        'dualDecoderSetupOk=${report.dualDecoderSetupPass} '
        'failureReason=${report.failureReason} '
        'clip0Mime=${report.details['clip0Mime']} '
        'clip0Size=${report.details['clip0Width']}x${report.details['clip0Height']} '
        'clip1Mime=${report.details['clip1Mime']} '
        'clip1Size=${report.details['clip1Width']}x${report.details['clip1Height']} '
        'clip0Decoder=${report.details['clip0DecoderName']} '
        'clip1Decoder=${report.details['clip1DecoderName']} '
        'maxFrames=${report.details['maxFrames']} '
        'overlapFrames=${report.details['overlapFrames']}',
      );

      lane2Pass = report.syncPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass syncPass=${report.syncPass} '
        'leadInClip0Ok=${report.leadInClip0Pass} '
        'overlapPairAcquireOk=${report.overlapPairAcquirePass} '
        'overlapPtsMonotonicOk=${report.overlapPtsMonotonicPass} '
        'transitionProgressOk=${report.transitionProgressPass} '
        'leadInClip0PtsUs=${report.details['leadInClip0PtsUs']} '
        'overlapClip0PtsUs=${report.details['overlapClip0PtsUs']} '
        'overlapClip1PtsUs=${report.details['overlapClip1PtsUs']} '
        'overlapClip0ImageTimestampNs=${report.details['overlapClip0ImageTimestampNs']} '
        'overlapClip1ImageTimestampNs=${report.details['overlapClip1ImageTimestampNs']} '
        'overlapPairsAcquired=${report.details['overlapPairsAcquired']} '
        'overlapFenceWaited=${report.details['overlapFenceWaited']} '
        'overlapProgress=${report.details['overlapProgress']} '
        'overlapError=${report.details['overlapError']}',
      );

      lane3Pass = report.nativePass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass nativePass=${report.nativePass} '
        'nativeImportOk=${report.nativeImportPass} '
        'nativeCrossfadeRenderOk=${report.nativeCrossfadeRenderPass} '
        'nativeResults=${jsonEncode(report.details['nativeResults'])}',
      );

      lane4Pass = report.lifecyclePass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass lifecyclePass=${report.lifecyclePass} '
        'leadOutClip1Ok=${report.leadOutClip1Pass} '
        'resourceReleaseOk=${report.resourceReleasePass} '
        'leadOutClip1PtsUs=${report.details['leadOutClip1PtsUs']} '
        'clip0FramesProduced=${report.details['clip0FramesProduced']} '
        'clip1FramesProduced=${report.details['clip1FramesProduced']} '
        'openImagesAfterClose=${report.details['openImagesAfterClose']} '
        'closeErrors=${jsonEncode(report.details['closeErrors'])} '
        'clip0CloseSteps=${jsonEncode(report.details['clip0CloseSteps'])} '
        'clip1CloseSteps=${jsonEncode(report.details['clip1CloseSteps'])} '
        'elapsedMs=${report.details['elapsedMs']} sdkInt=${report.details['sdkInt']}',
      );

      final map = report.toMap();
      final roundTrip = VGTimelineDualDecoderSyncSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane5Pass =
          report.isVerifiedPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass isVerifiedPass=${report.isVerifiedPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: dual decoder sync smoke exceeded timeout: $te';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } finally {
      // Delete only the two temp copies this run created.
      await _deleteTempCopy(clip0);
      await _deleteTempCopy(clip1);

      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          topLevelError == null &&
          (report?.isVerifiedPass ?? false);

      final payload = <String, dynamic>{
        'unit': 'AndroidTimelineDualDecoderSyncSmokeHarness',
        'slice': 'P5-COMPOSITOR-TRANS-DUAL-DECODER-SYNC',
        'target': VGTimelineDualDecoderSyncSmokeReport.proofBoundaryConstant,
        'fixtureAsset': _fixtureAsset,
        'clip0Path': clip0?.path,
        'clip1Path': clip1?.path,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_argumentsAndSetup': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'status': report?.status,
            'argumentValidationPass': report?.argumentValidationPass,
            'setupPass': report?.setupPass,
          },
          'lane2_synchronizedStepping': {
            'pass': lane2Pass,
            'syncPass': report?.syncPass,
          },
          'lane3_nativeImportAndCrossfade': {
            'pass': lane3Pass,
            'nativePass': report?.nativePass,
          },
          'lane4_lifecycle': {
            'pass': lane4Pass,
            'lifecyclePass': report?.lifecyclePass,
          },
          'lane5_telemetry': {
            'pass': lane5Pass,
            'isVerifiedPass': report?.isVerifiedPass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'nativeAllLanesPass': report?.nativeAllLanesPass,
            'marker': report?.marker,
            'proofBoundary': report?.proofBoundary,
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
