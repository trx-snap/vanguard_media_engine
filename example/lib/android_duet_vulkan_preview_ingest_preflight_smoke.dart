// android_duet_vulkan_preview_ingest_preflight_smoke.dart
// Vanguard Media Engine - DUET-VULKAN-PREVIEW-INGEST-PREFLIGHT: Android
// physical preflight readiness smoke stitching existing Vulkan mask-blend pixel
// proof, real single-camera AHB Vulkan spatial render proof, and dual decoder
// AHB Vulkan render proof.
//
// Target / proof boundary:
//   duet_vulkan_preview_ingest_preflight_existing_camera_ahb_mask_blend_and_dual_decoder_ahb_vulkan_proofs_no_combined_native_seam_no_production_preview
//
// Claims allowed:
//   This preflight proves existing real single-camera AHB Vulkan render proof plus
//   existing dual-decoder AHB Vulkan proof plus Vulkan mask-blend helper are
//   physically runnable in one Duet readiness lane.
//
// Non-claims:
//   No combined camera+decoder AHB in the same native pass, no production Duet
//   preview replacement, no CameraX path, no export, no app/product UI.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet_vulkan_pixel_proof_smoke.dart';
import 'package:vanguard_media_engine/vg_single_cam_ingest_vulkan_spatial_render_smoke.dart';
import 'package:vanguard_media_engine/vg_timeline_dual_decoder_sync_smoke.dart';

const String _proofBoundaryConstant =
    'duet_vulkan_preview_ingest_preflight_existing_camera_ahb_mask_blend_and_dual_decoder_ahb_vulkan_proofs_no_combined_native_seam_no_production_preview';

const String _claimsAllowed =
    'This preflight proves existing real single-camera AHB Vulkan render proof plus existing dual-decoder AHB Vulkan proof plus Vulkan mask-blend helper are physically runnable in one Duet readiness lane.';

const String _nonClaims =
    'No combined camera+decoder AHB in the same native pass, no production Duet preview replacement, no CameraX path, no export, no app/product UI.';

const String _passMarker = 'ANDROID_DUET_VULKAN_PREVIEW_INGEST_PREFLIGHT_PASS';
const String _failMarker = 'ANDROID_DUET_VULKAN_PREVIEW_INGEST_PREFLIGHT_FAIL';
const String _jsonPrefix = 'ANDROID_DUET_VULKAN_PREVIEW_INGEST_PREFLIGHT_JSON:';
const String _logPrefix = 'ANDROID_DUET_VULKAN_PREVIEW_INGEST_PREFLIGHT';
const String _fixtureAsset = 'assets/manual_test_clips/clip_B.mov';

void main() {
  runApp(const AndroidDuetVulkanPreviewIngestPreflightSmokeApp());
}

class AndroidDuetVulkanPreviewIngestPreflightSmokeApp extends StatefulWidget {
  const AndroidDuetVulkanPreviewIngestPreflightSmokeApp({super.key});

  @override
  State<AndroidDuetVulkanPreviewIngestPreflightSmokeApp> createState() =>
      _AndroidDuetVulkanPreviewIngestPreflightSmokeAppState();
}

class _AndroidDuetVulkanPreviewIngestPreflightSmokeAppState
    extends State<AndroidDuetVulkanPreviewIngestPreflightSmokeApp> {
  String _status = 'Initializing Duet Vulkan Preview Ingest Preflight...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runPreflight();
    });
  }

  /// Copies the bundled fixture into a fresh temp file owned by this run.
  Future<File> _copyFixture(String suffix) async {
    final bytes = await rootBundle.load(_fixtureAsset);
    final runId = DateTime.now().microsecondsSinceEpoch;
    final file = File(
      '${Directory.systemTemp.path}/duet_preview_preflight_${runId}_$suffix.mov',
    );
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return file;
  }

  /// Deletes only a temp copy created by this run; never touches anything else.
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

  Future<void> _runPreflight() async {
    print('${_logPrefix}_START');
    String? topLevelError;
    String? step1Error;
    String? step2Error;
    String? step3Error;

    VGDuetVulkanPixelProofSmokeReport? duetReport;
    VGSingleCamIngestVulkanSpatialRenderSmokeReport? cameraReport;
    VGTimelineDualDecoderSyncSmokeReport? decoderReport;

    var duetPixelProofPass = false;
    var singleCameraAhbVulkanPass = false;
    var dualDecoderAhbVulkanPass = false;

    File? clip0;
    File? clip1;
    var clip0Bytes = -1;
    var clip1Bytes = -1;

    try {
      // Step 1: Run Vulkan Duet pixel proof with 30s-ish timeout.
      print('${_logPrefix}_STEP_1_VULKAN_DUET_PIXEL_PROOF_START');
      if (mounted) {
        setState(() {
          _status = 'Running Duet Vulkan Pixel Proof...';
        });
      }

      try {
        duetReport =
            await VGDuetVulkanPixelProofSmokeReport.runAndroidDuetVulkanPixelProofSmoke(
              timeout: const Duration(seconds: 25),
            ).timeout(const Duration(seconds: 30));
      } catch (e, st) {
        step1Error = 'Duet pixel proof exception: $e\n$st';
        print('${_logPrefix}_STEP_1_EXCEPTION: $step1Error');
      }

      final duetBoundaryMatches =
          duetReport != null &&
          duetReport.proofBoundary ==
              VGDuetVulkanPixelProofSmokeReport.proofBoundaryConstant;
      duetPixelProofPass =
          duetReport != null &&
          duetReport.isPass &&
          duetBoundaryMatches &&
          step1Error == null;

      print(
        '${_logPrefix}_STEP_1_VULKAN_DUET_PIXEL_PROOF_RESULT: '
        'pass=$duetPixelProofPass '
        'reportPass=${duetReport?.pass} '
        'status=${duetReport?.status} '
        'marker=${duetReport?.marker} '
        'proofBoundary=${duetReport?.proofBoundary} '
        'boundaryMatches=$duetBoundaryMatches '
        'failureReason=${duetReport?.failureReason}',
      );

      // Step 2: Run Single-Camera Ingest Vulkan Spatial Render proof with 25-30s timeout.
      print('${_logPrefix}_STEP_2_SINGLE_CAM_VULKAN_START');
      if (mounted) {
        setState(() {
          _status = 'Running Single Camera AHB Vulkan Spatial Render Proof...';
        });
      }

      try {
        cameraReport =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
              descriptor:
                  VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
              timeout: const Duration(seconds: 25),
            ).timeout(const Duration(seconds: 30));
      } catch (e, st) {
        step2Error =
            'Single camera AHB Vulkan spatial render exception: $e\n$st';
        print('${_logPrefix}_STEP_2_EXCEPTION: $step2Error');
      }

      final cameraBoundaryMatches =
          cameraReport != null &&
          cameraReport.proofBoundary ==
              VGSingleCamIngestVulkanSpatialRenderSmokeReport
                  .proofBoundaryConstant;
      singleCameraAhbVulkanPass =
          cameraReport != null &&
          cameraReport.isPass &&
          cameraBoundaryMatches &&
          step2Error == null;

      print(
        '${_logPrefix}_STEP_2_SINGLE_CAM_VULKAN_RESULT: '
        'pass=$singleCameraAhbVulkanPass '
        'reportPass=${cameraReport?.pass} '
        'status=${cameraReport?.status} '
        'marker=${cameraReport?.marker} '
        'proofBoundary=${cameraReport?.proofBoundary} '
        'boundaryMatches=$cameraBoundaryMatches '
        'failureReason=${cameraReport?.failureReason}',
      );

      // Step 3: Copy fixtures and run Dual Decoder sync smoke with 100s-ish timeout.
      print('${_logPrefix}_STEP_3_DUAL_DECODER_SYNC_START');
      if (mounted) {
        setState(() {
          _status = 'Running Dual Decoder Sync Smoke...';
        });
      }

      try {
        clip0 = await _copyFixture('clip0');
        clip1 = await _copyFixture('clip1');
        clip0Bytes = await clip0.length();
        clip1Bytes = await clip1.length();
        print(
          '${_logPrefix}_FIXTURES: asset=$_fixtureAsset '
          'clip0=${clip0.path} clip0Bytes=$clip0Bytes '
          'clip1=${clip1.path} clip1Bytes=$clip1Bytes '
          'distinctPaths=${clip0.path != clip1.path}',
        );
        if (clip0.path == clip1.path || clip0Bytes <= 0 || clip1Bytes <= 0) {
          throw StateError('fixture temp copies invalid');
        }

        decoderReport =
            await VGTimelineDualDecoderSyncSmokeReport.runAndroidDagPhase5TimelineDualDecoderSyncSmoke(
              clip0Path: clip0.path,
              clip1Path: clip1.path,
              timeout: const Duration(seconds: 90),
            ).timeout(const Duration(seconds: 100));
      } catch (e, st) {
        step3Error = 'Dual decoder sync exception: $e\n$st';
        print('${_logPrefix}_STEP_3_EXCEPTION: $step3Error');
      }

      final decoderBoundaryMatches =
          decoderReport != null &&
          decoderReport.proofBoundary ==
              VGTimelineDualDecoderSyncSmokeReport.proofBoundaryConstant;
      dualDecoderAhbVulkanPass =
          decoderReport != null &&
          decoderReport.isVerifiedPass &&
          decoderBoundaryMatches &&
          step3Error == null;

      print(
        '${_logPrefix}_STEP_3_DUAL_DECODER_SYNC_RESULT: '
        'pass=$dualDecoderAhbVulkanPass '
        'reportPass=${decoderReport?.pass} '
        'status=${decoderReport?.status} '
        'marker=${decoderReport?.marker} '
        'proofBoundary=${decoderReport?.proofBoundary} '
        'boundaryMatches=$decoderBoundaryMatches '
        'failureReason=${decoderReport?.failureReason}',
      );
    } catch (e, st) {
      topLevelError = 'Unexpected top-level error: $e\n$st';
      print('${_logPrefix}_TOP_LEVEL_ERROR: $topLevelError');
    } finally {
      await _deleteTempCopy(clip0);
      await _deleteTempCopy(clip1);

      final allPass =
          duetPixelProofPass &&
          singleCameraAhbVulkanPass &&
          dualDecoderAhbVulkanPass &&
          step1Error == null &&
          step2Error == null &&
          step3Error == null &&
          topLevelError == null;

      String? failureReason;
      if (topLevelError != null) {
        failureReason = topLevelError;
      } else if (step1Error != null) {
        failureReason = step1Error;
      } else if (!duetPixelProofPass) {
        final reason = duetReport?.failureReason;
        failureReason = (reason != null && reason.isNotEmpty)
            ? 'duet_pixel_proof: $reason'
            : 'duet_pixel_proof_failed_or_boundary_mismatch';
      } else if (step2Error != null) {
        failureReason = step2Error;
      } else if (!singleCameraAhbVulkanPass) {
        final reason = cameraReport?.failureReason;
        failureReason = (reason != null && reason.isNotEmpty)
            ? 'single_camera_ahb_vulkan: $reason'
            : 'single_camera_ahb_vulkan_failed_or_boundary_mismatch';
      } else if (step3Error != null) {
        failureReason = step3Error;
      } else if (!dualDecoderAhbVulkanPass) {
        final reason = decoderReport?.failureReason;
        failureReason = (reason != null && reason.isNotEmpty)
            ? 'dual_decoder_sync: $reason'
            : 'dual_decoder_sync_failed_or_boundary_mismatch';
      }

      final payload = <String, dynamic>{
        'pass': allPass,
        'proofBoundary': _proofBoundaryConstant,
        'claimsAllowed': _claimsAllowed,
        'nonClaims': _nonClaims,
        'duetPixelProofPass': duetPixelProofPass,
        'singleCameraAhbVulkanPass': singleCameraAhbVulkanPass,
        'dualDecoderAhbVulkanPass': dualDecoderAhbVulkanPass,
        'duetPixelProofStatus': duetReport?.status ?? 'UNKNOWN',
        'singleCameraStatus': cameraReport?.status ?? 'UNKNOWN',
        'dualDecoderStatus': decoderReport?.status ?? 'UNKNOWN',
        'duetPixelProofBoundary': duetReport?.proofBoundary ?? '',
        'singleCameraBoundary': cameraReport?.proofBoundary ?? '',
        'dualDecoderBoundary': decoderReport?.proofBoundary ?? '',
        'fixtureAsset': _fixtureAsset,
        'clip0Path': clip0?.path,
        'clip1Path': clip1?.path,
        'clip0Bytes': clip0Bytes,
        'clip1Bytes': clip1Bytes,
        'failureReason': failureReason,
        'duetReport': duetReport?.toMap(),
        'singleCameraReport': cameraReport?.toMap(),
        'dualDecoderReport': decoderReport?.toMap(),
      };

      print('$_jsonPrefix${jsonEncode(payload)}');
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
