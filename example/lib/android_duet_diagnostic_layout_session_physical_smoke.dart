// android_duet_diagnostic_layout_session_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-DUET-DIAGNOSTIC-LAYOUT-SESSION: Duet/Dual Camera
// Diagnostic Layout Metadata & Session Proof Physical Smoke Harness.
//
// Proof lanes:
//   - Lane 1 (Production unsupported): Calls
//     VGCameraSession.startDuetSession(allowDiagnosticSyntheticMode: false, config: freeFloatingConfig)
//     and confirms production admission fails closed (returns null) on hardware
//     without a hardware-validated concurrent camera combination (e.g. SM-A566B).
//     Reports productionFailClosed=true based on policy/session null boundary.
//   - Lane 2 (Diagnostic freeFloating PiP): Calls
//     VGCameraSession.startDuetSession(allowDiagnosticSyntheticMode: true, config: freeFloatingConfig)
//     and confirms diagnostic single-camera continuation is admitted: a real
//     textureId (>= 0) is returned, layoutConfig (freeFloating anchor, centerX, centerY,
//     widthFraction, aspectRatio) is preserved, isPhysicalDualCamera and
//     isProductionRealDualCamera are strictly false, and
//     isDiagnosticSyntheticMode is strictly true. Then disposes cleanly.
//   - Lane 3 (Diagnostic leftRight Split): Calls
//     VGCameraSession.startDuetSession(allowDiagnosticSyntheticMode: true, config: leftRightSplitConfig)
//     and confirms diagnostic single-camera continuation is admitted: a real
//     textureId (>= 0) is returned, layoutConfig (leftRight direction, splitRatio)
//     is preserved, flags are strictly false/true as above. Then disposes cleanly.
//   - Emits structured JSON summary, start/pass/fail markers, and exits 0 on
//     pass or 1 on fail.
//
// Canonical proof boundary:
//   duet_diagnostic_layout_session_metadata_carried_single_camera_unsupported_hardware_no_real_concurrent_capture_no_render.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String kDuetDiagnosticLayoutSessionProofBoundary =
    'duet_diagnostic_layout_session_metadata_carried_single_camera_unsupported_hardware_no_real_concurrent_capture_no_render';

const String kDuetDiagnosticLayoutSessionStartMarker =
    'ANDROID_DAG_PHASE3_DUET_DIAGNOSTIC_LAYOUT_SESSION_PHYSICAL_SMOKE_START';

const String kDuetDiagnosticLayoutSessionPassMarker =
    'ANDROID_DAG_PHASE3_DUET_DIAGNOSTIC_LAYOUT_SESSION_PHYSICAL_SMOKE_PASS';

const String kDuetDiagnosticLayoutSessionFailMarker =
    'ANDROID_DAG_PHASE3_DUET_DIAGNOSTIC_LAYOUT_SESSION_PHYSICAL_SMOKE_FAIL';

void main() {
  runApp(const AndroidDuetDiagnosticLayoutSessionPhysicalSmokeApp());
}

class AndroidDuetDiagnosticLayoutSessionPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDuetDiagnosticLayoutSessionPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetDiagnosticLayoutSessionPhysicalSmokeApp> createState() =>
      _AndroidDuetDiagnosticLayoutSessionPhysicalSmokeAppState();
}

class _AndroidDuetDiagnosticLayoutSessionPhysicalSmokeAppState
    extends State<AndroidDuetDiagnosticLayoutSessionPhysicalSmokeApp> {
  String _status =
      'Initializing Duet Camera Diagnostic Layout Session Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kDuetDiagnosticLayoutSessionStartMarker);
    try {
      final reasons = <String>[];
      var pass = true;
      void addFailure(String reason) {
        pass = false;
        if (!reasons.contains(reason)) reasons.add(reason);
      }

      const freeFloatingConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.freeFloating,
          centerX: 0.72,
          centerY: 0.28,
          widthFraction: 0.4,
          aspectRatio: 1.0,
        ),
      );

      const splitLeftRightConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        splitLayout: VGSplitScreenLayoutDescriptor(
          direction: VGSplitScreenDirection.leftRight,
          splitRatio: 0.6,
        ),
      );

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
      VGDuetCameraSession? diagnosticFreeFloatingSession;
      VGDuetCameraSession? diagnosticSplitSession;
      var productionFailClosed = false;

      Map<String, Object?>? freeFloatingSessionInfo;
      Map<String, Object?>? splitSessionInfo;

      try {
        if (isRealSupported) {
          productionSession = await VGCameraSession.startDuetSession(
            allowDiagnosticSyntheticMode: false,
            config: freeFloatingConfig,
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
            if (productionSession.layoutConfig != freeFloatingConfig) {
              addFailure('real_supported_config_mismatch');
            }
          }
          await productionSession?.dispose();
        } else if (isUnsupportedWithPrimary) {
          // Lane 1: Production unsupported lane
          productionSession = await VGCameraSession.startDuetSession(
            allowDiagnosticSyntheticMode: false,
            config: freeFloatingConfig,
          );
          productionFailClosed = productionSession == null;
          if (!productionFailClosed) {
            addFailure('unsupported_production_session_not_null');
          }

          // Lane 2: Diagnostic freeFloating PiP lane
          diagnosticFreeFloatingSession =
              await VGCameraSession.startDuetSession(
                allowDiagnosticSyntheticMode: true,
                config: freeFloatingConfig,
              );
          if (diagnosticFreeFloatingSession == null) {
            addFailure('diagnostic_free_floating_session_null');
          } else {
            if (diagnosticFreeFloatingSession.textureId < 0) {
              addFailure('diagnostic_free_floating_texture_id_negative');
            }
            if (diagnosticFreeFloatingSession.isPhysicalDualCamera) {
              addFailure('diagnostic_free_floating_physical_dual_true');
            }
            if (diagnosticFreeFloatingSession.isProductionRealDualCamera) {
              addFailure('diagnostic_free_floating_production_real_dual_true');
            }
            if (!diagnosticFreeFloatingSession.isDiagnosticSyntheticMode) {
              addFailure('diagnostic_free_floating_synthetic_mode_false');
            }
            if (diagnosticFreeFloatingSession.layoutConfig !=
                freeFloatingConfig) {
              addFailure('diagnostic_free_floating_config_mismatch');
            }
            if (diagnosticFreeFloatingSession.layoutMode !=
                VGDualCameraLayoutMode.pip) {
              addFailure('diagnostic_free_floating_layout_mode_mismatch');
            }
            if (diagnosticFreeFloatingSession.pipLayout.anchor !=
                VGPiPAnchor.freeFloating) {
              addFailure('diagnostic_free_floating_anchor_mismatch');
            }
            if (diagnosticFreeFloatingSession.pipLayout.centerX != 0.72 ||
                diagnosticFreeFloatingSession.pipLayout.centerY != 0.28 ||
                diagnosticFreeFloatingSession.pipLayout.widthFraction != 0.4 ||
                diagnosticFreeFloatingSession.pipLayout.aspectRatio != 1.0) {
              addFailure('diagnostic_free_floating_geometry_mismatch');
            }

            freeFloatingSessionInfo = <String, Object?>{
              'textureId': diagnosticFreeFloatingSession.textureId,
              'isPhysicalDualCamera':
                  diagnosticFreeFloatingSession.isPhysicalDualCamera,
              'isProductionRealDualCamera':
                  diagnosticFreeFloatingSession.isProductionRealDualCamera,
              'isDiagnosticSyntheticMode':
                  diagnosticFreeFloatingSession.isDiagnosticSyntheticMode,
              'layoutConfig': diagnosticFreeFloatingSession.layoutConfig
                  .toMap(),
            };
          }
          await diagnosticFreeFloatingSession?.dispose();
          if (diagnosticFreeFloatingSession != null &&
              !diagnosticFreeFloatingSession.isDisposed) {
            addFailure('diagnostic_free_floating_session_not_disposed');
          }

          // Lane 3: Diagnostic leftRight split lane
          diagnosticSplitSession = await VGCameraSession.startDuetSession(
            allowDiagnosticSyntheticMode: true,
            config: splitLeftRightConfig,
          );
          if (diagnosticSplitSession == null) {
            addFailure('diagnostic_split_session_null');
          } else {
            if (diagnosticSplitSession.textureId < 0) {
              addFailure('diagnostic_split_texture_id_negative');
            }
            if (diagnosticSplitSession.isPhysicalDualCamera) {
              addFailure('diagnostic_split_physical_dual_true');
            }
            if (diagnosticSplitSession.isProductionRealDualCamera) {
              addFailure('diagnostic_split_production_real_dual_true');
            }
            if (!diagnosticSplitSession.isDiagnosticSyntheticMode) {
              addFailure('diagnostic_split_synthetic_mode_false');
            }
            if (diagnosticSplitSession.layoutConfig != splitLeftRightConfig) {
              addFailure('diagnostic_split_config_mismatch');
            }
            if (diagnosticSplitSession.layoutMode !=
                VGDualCameraLayoutMode.splitScreen) {
              addFailure('diagnostic_split_layout_mode_mismatch');
            }
            if (diagnosticSplitSession.splitLayout.direction !=
                VGSplitScreenDirection.leftRight) {
              addFailure('diagnostic_split_direction_mismatch');
            }
            if (diagnosticSplitSession.splitLayout.splitRatio != 0.6) {
              addFailure('diagnostic_split_ratio_mismatch');
            }

            splitSessionInfo = <String, Object?>{
              'textureId': diagnosticSplitSession.textureId,
              'isPhysicalDualCamera':
                  diagnosticSplitSession.isPhysicalDualCamera,
              'isProductionRealDualCamera':
                  diagnosticSplitSession.isProductionRealDualCamera,
              'isDiagnosticSyntheticMode':
                  diagnosticSplitSession.isDiagnosticSyntheticMode,
              'layoutConfig': diagnosticSplitSession.layoutConfig.toMap(),
            };
          }
          await diagnosticSplitSession?.dispose();
          if (diagnosticSplitSession != null &&
              !diagnosticSplitSession.isDisposed) {
            addFailure('diagnostic_split_session_not_disposed');
          }
        } else {
          addFailure(
            'hardware_policy_unsupported_or_blocked:${productionPolicy.decision.name}',
          );
        }
      } finally {
        await productionSession?.dispose();
        await diagnosticFreeFloatingSession?.dispose();
        await diagnosticSplitSession?.dispose();
      }

      if (productionSession != null && !productionSession.isDisposed) {
        addFailure('production_session_not_disposed');
      }
      if (diagnosticFreeFloatingSession != null &&
          !diagnosticFreeFloatingSession.isDisposed) {
        addFailure('diagnostic_free_floating_session_not_disposed');
      }
      if (diagnosticSplitSession != null &&
          !diagnosticSplitSession.isDisposed) {
        addFailure('diagnostic_split_session_not_disposed');
      }

      if (pass) {
        reasons.add(
          isRealSupported
              ? 'duet_diagnostic_layout_session_real_concurrent_hardware_validated_pass'
              : 'duet_diagnostic_layout_session_unsupported_hardware_metadata_carried_single_camera_pass',
        );
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary': kDuetDiagnosticLayoutSessionProofBoundary,
        'passMarker': kDuetDiagnosticLayoutSessionPassMarker,
        'failMarker': kDuetDiagnosticLayoutSessionFailMarker,
        'reasons': reasons,
        'productionFailClosed': productionFailClosed,
        'physicalConcurrentCaptureProven': false,
        'startMultiCamNativeExecutionProven': false,
        'renderProven': false,
        'recordingExportProven': false,
        'productUiWired': false,
        'nonClaims': <String, bool>{
          'physicalConcurrentCaptureProven': false,
          'startMultiCamNativeExecutionProven': false,
          'renderProven': false,
          'recordingExportProven': false,
          'productUiWired': false,
        },
        'productionPolicy': productionPolicy.toMap(),
        'diagnosticPolicy': diagnosticPolicy.toMap(),
        'freeFloatingPipSession': freeFloatingSessionInfo,
        'leftRightSplitSession': splitSessionInfo,
      };

      print(
        'ANDROID_DAG_PHASE3_DUET_DIAGNOSTIC_LAYOUT_SESSION_JSON:${jsonEncode(payload)}',
      );

      if (pass) {
        print(kDuetDiagnosticLayoutSessionPassMarker);
      } else {
        print(kDuetDiagnosticLayoutSessionFailMarker);
      }

      if (mounted) {
        setState(() {
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    } catch (e, st) {
      print('ANDROID_DAG_PHASE3_DUET_DIAGNOSTIC_LAYOUT_SESSION_ERROR: $e\n$st');
      print(kDuetDiagnosticLayoutSessionFailMarker);
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
