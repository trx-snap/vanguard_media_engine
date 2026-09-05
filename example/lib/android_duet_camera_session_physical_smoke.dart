// android_duet_camera_session_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-DUET-SESSION-ADMISSION-ROUTE: Duet/Dual Camera
// Session Admission Route Physical Smoke Harness.
//
// Proof lanes:
//   - Calls VGCameraSession.startDuetSession(allowDiagnosticSyntheticMode: false)
//     and confirms production admission fails closed (returns null) on hardware
//     without a hardware-validated concurrent camera combination (e.g. SM-A566B).
//   - Calls VGCameraSession.startDuetSession(allowDiagnosticSyntheticMode: true)
//     and confirms diagnostic single-camera continuation is admitted: a real
//     textureId (>= 0) is returned, but isPhysicalDualCamera and
//     isProductionRealDualCamera are strictly false and isDiagnosticSyntheticMode
//     is strictly true -- the diagnostic path never claims physical dual camera.
//   - Disposes whichever sessions were acquired and confirms clean teardown.
//   - Emits structured JSON summary, start/pass/fail markers, and exits 0 on
//     pass or 1 on fail.
//
// Boundary: duet_dual_camera_session_admission_gated_routing_single_cam_diagnostic_fallback_no_real_concurrent_hardware_proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String kDuetSessionAdmissionProofBoundary =
    'duet_dual_camera_session_admission_gated_routing_single_cam_diagnostic_fallback_no_real_concurrent_hardware_proof';

const String kDuetSessionAdmissionStartMarker =
    'ANDROID_DAG_PHASE3_DUET_SESSION_ADMISSION_PHYSICAL_SMOKE_START';

const String kDuetSessionAdmissionPassMarker =
    'ANDROID_DAG_PHASE3_DUET_SESSION_ADMISSION_PHYSICAL_SMOKE_PASS';

const String kDuetSessionAdmissionFailMarker =
    'ANDROID_DAG_PHASE3_DUET_SESSION_ADMISSION_PHYSICAL_SMOKE_FAIL';

void main() {
  runApp(const AndroidDuetCameraSessionPhysicalSmokeApp());
}

class AndroidDuetCameraSessionPhysicalSmokeApp extends StatefulWidget {
  const AndroidDuetCameraSessionPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetCameraSessionPhysicalSmokeApp> createState() =>
      _AndroidDuetCameraSessionPhysicalSmokeAppState();
}

class _AndroidDuetCameraSessionPhysicalSmokeAppState
    extends State<AndroidDuetCameraSessionPhysicalSmokeApp> {
  String _status = 'Initializing Duet Camera Session Admission Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kDuetSessionAdmissionStartMarker);
    try {
      final reasons = <String>[];
      var pass = true;
      void addFailure(String reason) {
        pass = false;
        if (!reasons.contains(reason)) reasons.add(reason);
      }

      final productionPolicy = await VGCameraSession.evaluateDuetCapability(
        allowDiagnosticSyntheticMode: false,
      );
      final diagnosticPolicy = await VGCameraSession.evaluateDuetCapability(
        allowDiagnosticSyntheticMode: true,
      );

      final isRealSupported = productionPolicy.isProductionRealDualCamera;
      final isUnsupportedWithPrimary =
          productionPolicy.isProductionHiddenSingleCameraFallback &&
          productionPolicy.selectedPrimaryCameraId != null;

      VGDuetCameraSession? productionSession;
      VGDuetCameraSession? diagnosticSession;
      try {
        if (isRealSupported) {
          productionSession = await VGCameraSession.startDuetSession(
            allowDiagnosticSyntheticMode: false,
          );
          if (productionSession == null) {
            addFailure('real_supported_route_not_started');
          } else {
            if (!productionSession.isPhysicalDualCamera) {
              addFailure('real_supported_physical_dual_false');
            }
            if (!productionSession.isProductionRealDualCamera) {
              addFailure('real_supported_production_real_dual_false');
            }
            if (productionSession.isDiagnosticSyntheticMode) {
              addFailure('real_supported_diagnostic_synthetic_true');
            }
          }
        } else if (isUnsupportedWithPrimary) {
          productionSession = await VGCameraSession.startDuetSession(
            allowDiagnosticSyntheticMode: false,
          );
          if (productionSession != null) {
            addFailure('unsupported_production_session_not_null');
          }

          diagnosticSession = await VGCameraSession.startDuetSession(
            allowDiagnosticSyntheticMode: true,
          );
          if (diagnosticSession == null) {
            addFailure('unsupported_diagnostic_session_null');
          } else {
            if (diagnosticSession.textureId < 0) {
              addFailure('diagnostic_texture_id_negative');
            }
            if (diagnosticSession.isPhysicalDualCamera) {
              addFailure('diagnostic_physical_dual_true');
            }
            if (diagnosticSession.isProductionRealDualCamera) {
              addFailure('diagnostic_production_real_dual_true');
            }
            if (!diagnosticSession.isDiagnosticSyntheticMode) {
              addFailure('diagnostic_synthetic_flag_false');
            }
          }
        } else {
          addFailure(
            'hardware_policy_unsupported_or_blocked:${productionPolicy.decision.name}',
          );
        }
      } finally {
        await productionSession?.dispose();
        await diagnosticSession?.dispose();
      }

      if (productionSession != null && !productionSession.isDisposed) {
        addFailure('production_session_not_disposed');
      }
      if (diagnosticSession != null && !diagnosticSession.isDisposed) {
        addFailure('diagnostic_session_not_disposed');
      }

      if (pass) {
        reasons.add(
          isRealSupported
              ? 'duet_session_real_concurrent_hardware_validated_pass'
              : 'duet_session_unsupported_hardware_fail_closed_diagnostic_fallback_pass',
        );
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary': kDuetSessionAdmissionProofBoundary,
        'passMarker': kDuetSessionAdmissionPassMarker,
        'failMarker': kDuetSessionAdmissionFailMarker,
        'reasons': reasons,
        'productionPolicy': productionPolicy.toMap(),
        'diagnosticPolicy': diagnosticPolicy.toMap(),
        'productionSession': productionSession == null
            ? null
            : <String, Object?>{
                'textureId': productionSession.textureId,
                'isPhysicalDualCamera': productionSession.isPhysicalDualCamera,
                'isProductionRealDualCamera':
                    productionSession.isProductionRealDualCamera,
                'isDiagnosticSyntheticMode':
                    productionSession.isDiagnosticSyntheticMode,
              },
        'diagnosticSession': diagnosticSession == null
            ? null
            : <String, Object?>{
                'textureId': diagnosticSession.textureId,
                'isPhysicalDualCamera': diagnosticSession.isPhysicalDualCamera,
                'isProductionRealDualCamera':
                    diagnosticSession.isProductionRealDualCamera,
                'isDiagnosticSyntheticMode':
                    diagnosticSession.isDiagnosticSyntheticMode,
              },
      };
      print(
        'ANDROID_DAG_PHASE3_DUET_SESSION_ADMISSION_JSON:${jsonEncode(payload)}',
      );

      if (pass) {
        print(kDuetSessionAdmissionPassMarker);
      } else {
        print(kDuetSessionAdmissionFailMarker);
      }

      if (mounted) {
        setState(() {
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    } catch (e, st) {
      print('ANDROID_DAG_PHASE3_DUET_SESSION_ADMISSION_ERROR: $e\n$st');
      print(kDuetSessionAdmissionFailMarker);
      if (mounted) {
        setState(() {
          _status = 'FAIL';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(1);
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
