// vg_dual_camera_capability_policy_test.dart
// vanguard_media_engine - P3-CAM-DUET-CAPABILITY-POLICY: Pure-Dart Duet dual-camera
// capability policy tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Helper to build a mock camera device capability
  VGCameraHardwareDeviceCapability makeCamera({
    required String id,
    required String lensFacing,
    String hardwareLevel = 'full',
    bool isLogicalMultiCamera = false,
    List<String> physicalCameraIds = const <String>[],
    List<String> capabilities = const <String>['BACKWARD_COMPATIBLE'],
    List<VGCameraSize> previewSizes = const <VGCameraSize>[
      VGCameraSize(1920, 1080),
      VGCameraSize(1280, 720),
    ],
    List<VGCameraSize> videoSizes = const <VGCameraSize>[
      VGCameraSize(3840, 2160),
      VGCameraSize(1920, 1080),
    ],
    List<VGCameraSize> jpegSizes = const <VGCameraSize>[
      VGCameraSize(4000, 3000),
    ],
    List<VGCameraSize> yuv420Sizes = const <VGCameraSize>[
      VGCameraSize(1920, 1080),
    ],
    List<VGCameraFpsRange> fpsRanges = const <VGCameraFpsRange>[
      VGCameraFpsRange(15, 30),
      VGCameraFpsRange(30, 30),
    ],
    bool flashAvailable = true,
  }) {
    return VGCameraHardwareDeviceCapability(
      cameraId: id,
      lensFacing: lensFacing,
      hardwareLevel: hardwareLevel,
      isLogicalMultiCamera: isLogicalMultiCamera,
      physicalCameraIds: physicalCameraIds,
      capabilities: capabilities,
      previewSizes: previewSizes,
      videoSizes: videoSizes,
      jpegSizes: jpegSizes,
      yuv420Sizes: yuv420Sizes,
      fpsRanges: fpsRanges,
      flashAvailable: flashAvailable,
    );
  }

  // Helper to build a mock capability report
  VGCameraHardwareCapabilityReport makeReport({
    bool success = true,
    int apiLevel = 34,
    bool hasCameraPermission = true,
    int? thermalStatus = 0,
    String thermalStatusName = 'none',
    int? cameraCount,
    bool supportsConcurrentCamera = false,
    List<List<String>> concurrentCameraIdSets = const <List<String>>[],
    List<VGCameraHardwareDeviceCapability> cameras =
        const <VGCameraHardwareDeviceCapability>[],
    String fallbackRecommendation = 'single_camera_only',
  }) {
    return VGCameraHardwareCapabilityReport(
      success: success,
      apiLevel: apiLevel,
      hasCameraPermission: hasCameraPermission,
      thermalStatus: thermalStatus,
      thermalStatusName: thermalStatusName,
      cameraCount: cameraCount ?? cameras.length,
      supportsConcurrentCamera: supportsConcurrentCamera,
      concurrentCameraIdSets: concurrentCameraIdSets,
      cameras: cameras,
      fallbackRecommendation: fallbackRecommendation,
    );
  }

  // Helper to build a mock runtime concurrent session validation report
  VGCamera2ConcurrentSessionValidationReport makeValidationReport({
    bool success = true,
    int apiLevel = 34,
    bool hasCameraPermission = true,
    bool attemptedRuntimeValidation = true,
    bool supported = true,
    VGCamera2ConcurrentSessionValidationDecision decision =
        VGCamera2ConcurrentSessionValidationDecision.supported,
    List<String> reasons = const <String>[],
    List<String> selectedConcurrentCameraIds = const <String>['0', '1'],
    int surfacePlanCount = 4,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) {
    return VGCamera2ConcurrentSessionValidationReport(
      success: success,
      apiLevel: apiLevel,
      hasCameraPermission: hasCameraPermission,
      attemptedRuntimeValidation: attemptedRuntimeValidation,
      supported: supported,
      decision: decision,
      reasons: reasons,
      selectedConcurrentCameraIds: selectedConcurrentCameraIds,
      surfacePlanCount: surfacePlanCount,
      diagnostics: diagnostics,
    );
  }

  const planner = VGDuetDualCameraCapabilityPlanner();

  // -------------------------------------------------------------------------
  // 1. Enum and Public Export Verification
  // -------------------------------------------------------------------------
  group('VGDuetDualCameraCapabilityPolicy enum and public exports', () {
    test('VGDuetDualCameraCapabilityDecision has expected 4 enum values', () {
      expect(
        VGDuetDualCameraCapabilityDecision.values,
        containsAll(<VGDuetDualCameraCapabilityDecision>[
          VGDuetDualCameraCapabilityDecision.blocked,
          VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          VGDuetDualCameraCapabilityDecision
              .productionHiddenSingleCameraFallback,
          VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
        ]),
      );
      expect(VGDuetDualCameraCapabilityDecision.values.length, equals(4));
    });

    test('Convenience getters reflect decision accurately', () {
      const blockedPolicy = VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision.blocked,
        reasons: <String>['no_camera_available'],
        diagnostics: <String, Object?>{},
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
      );
      expect(blockedPolicy.isBlocked, isTrue);
      expect(blockedPolicy.isProductionHiddenSingleCameraFallback, isFalse);

      const fallbackPolicy = VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision
            .productionHiddenSingleCameraFallback,
        reasons: <String>['runtime_validation_required'],
        diagnostics: <String, Object?>{},
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
      );
      expect(fallbackPolicy.isBlocked, isFalse);
      expect(fallbackPolicy.isProductionHiddenSingleCameraFallback, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // 2. Value Semantics, toMap, fromMap, and hashCode Coverage
  // -------------------------------------------------------------------------
  group(
    'VGDuetDualCameraCapabilityPolicy value semantics and serialization',
    () {
      test('toMap produces expected serializable map structure', () {
        const policy = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          reasons: <String>['valid_candidate'],
          diagnostics: <String, Object?>{'cameraCount': 2},
          isProductionVisible: true,
          isProductionRealDualCamera: true,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: true,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        final map = policy.toMap();
        expect(map['decision'], equals('productionRealDualCamera'));
        expect(map['reasons'], equals(<String>['valid_candidate']));
        expect(map['diagnostics'], equals(<String, Object?>{'cameraCount': 2}));
        expect(map['isProductionVisible'], isTrue);
        expect(map['isProductionRealDualCamera'], isTrue);
        expect(map['isDiagnosticSyntheticMode'], isFalse);
        expect(map['isPhysicalDualCamera'], isTrue);
        expect(map['selectedPrimaryCameraId'], equals('0'));
        expect(map['selectedSecondaryCameraId'], equals('1'));
      });

      test('fromMap restores identical policy object', () {
        const policy = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .diagnosticSyntheticSingleCamera,
          reasons: <String>[
            'diagnostic_synthetic_single_camera_enabled',
            'no_matching_concurrent_camera_set',
          ],
          diagnostics: <String, Object?>{
            'cameraCount': 2,
            'supportsConcurrentCamera': false,
          },
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: true,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        final reconstructed = VGDuetDualCameraCapabilityPolicy.fromMap(
          policy.toMap(),
        );
        expect(reconstructed, equals(policy));
        expect(reconstructed.hashCode, equals(policy.hashCode));
        expect(reconstructed?.isDiagnosticSyntheticMode, isTrue);
        expect(reconstructed?.isPhysicalDualCamera, isFalse);
      });

      test('fromMap handles null and invalid maps defensively', () {
        expect(VGDuetDualCameraCapabilityPolicy.fromMap(null), isNull);
        expect(VGDuetDualCameraCapabilityPolicy.fromMap('not_a_map'), isNull);
        expect(
          VGDuetDualCameraCapabilityPolicy.fromMap(<String, Object?>{
            'decision': 'invalid_decision_string',
          }),
          isNull,
        );
      });

      test('equality and hashCode contract across field modifications', () {
        const p1 = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          reasons: <String>['a', 'b'],
          diagnostics: <String, Object?>{'k1': 'v1'},
          isProductionVisible: true,
          isProductionRealDualCamera: true,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: true,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        const p2 = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          reasons: <String>['a', 'b'],
          diagnostics: <String, Object?>{'k1': 'v1'},
          isProductionVisible: true,
          isProductionRealDualCamera: true,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: true,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        const pDiffDecision = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.blocked,
          reasons: <String>['a', 'b'],
          diagnostics: <String, Object?>{'k1': 'v1'},
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        expect(p1, equals(p2));
        expect(p1.hashCode, equals(p2.hashCode));
        expect(p1, isNot(equals(pDiffDecision)));
      });

      test('toString formats readable debug representation', () {
        const policy = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.blocked,
          reasons: <String>['no_camera_available'],
          diagnostics: <String, Object?>{},
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: false,
        );

        expect(
          policy.toString(),
          contains('VGDuetDualCameraCapabilityPolicy('),
        );
        expect(policy.toString(), contains('decision:'));
        expect(policy.toString(), contains('isProductionVisible: false'));
      });
    },
  );

  // -------------------------------------------------------------------------
  // 3. Blocked No-Camera Remains Hidden and No Diagnostic
  // -------------------------------------------------------------------------
  group('Blocked no-camera scenario', () {
    test('Blocked no-camera report remains hidden and diagnostic false', () {
      final report = makeReport(
        cameraCount: 0,
        cameras: const <VGCameraHardwareDeviceCapability>[],
        fallbackRecommendation: 'no_camera',
      );

      // Evaluate with diagnostic synthetic mode disabled
      final policyDisabled = planner.evaluate(
        report: report,
        allowDiagnosticSyntheticMode: false,
      );
      expect(
        policyDisabled.decision,
        equals(VGDuetDualCameraCapabilityDecision.blocked),
      );
      expect(policyDisabled.isProductionVisible, isFalse);
      expect(policyDisabled.isProductionRealDualCamera, isFalse);
      expect(policyDisabled.isDiagnosticSyntheticMode, isFalse);
      expect(policyDisabled.isPhysicalDualCamera, isFalse);
      expect(policyDisabled.selectedPrimaryCameraId, isNull);
      expect(policyDisabled.selectedSecondaryCameraId, isNull);
      expect(policyDisabled.reasons, contains('no_camera_available'));

      // Evaluate with diagnostic synthetic mode enabled (must remain blocked)
      final policyEnabled = planner.evaluate(
        report: report,
        allowDiagnosticSyntheticMode: true,
      );
      expect(
        policyEnabled.decision,
        equals(VGDuetDualCameraCapabilityDecision.blocked),
      );
      expect(policyEnabled.isProductionVisible, isFalse);
      expect(policyEnabled.isProductionRealDualCamera, isFalse);
      expect(policyEnabled.isDiagnosticSyntheticMode, isFalse);
      expect(policyEnabled.isPhysicalDualCamera, isFalse);
      expect(policyEnabled.selectedPrimaryCameraId, isNull);
      expect(policyEnabled.selectedSecondaryCameraId, isNull);
      expect(policyEnabled.reasons, contains('no_camera_available'));
    });
  });

  // -------------------------------------------------------------------------
  // 4. Severe Thermal Report -> Blocked Even If Diagnostic Mode Allowed
  // -------------------------------------------------------------------------
  group('Severe thermal scenario', () {
    test(
      'Severe thermal status blocks session even when diagnostic mode is requested',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameraCount: 2,
          thermalStatus: 3,
          thermalStatusName: 'severe',
          cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
          fallbackRecommendation: 'thermal_blocked',
        );

        final policy = planner.evaluate(
          report: report,
          allowDiagnosticSyntheticMode: true,
        );

        expect(
          policy.decision,
          equals(VGDuetDualCameraCapabilityDecision.blocked),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isFalse);
        expect(policy.isPhysicalDualCamera, isFalse);
        expect(policy.reasons, contains('thermal_blocked'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // 5. SM-A566B-Style Unsupported Report (No Concurrent ID Combinations)
  // -------------------------------------------------------------------------
  group('SM-A566B-style unsupported report scenario', () {
    final backCam = makeCamera(id: '0', lensFacing: 'back');
    final frontCam = makeCamera(id: '1', lensFacing: 'front');
    final smA566bReport = makeReport(
      cameraCount: 2,
      supportsConcurrentCamera: false,
      concurrentCameraIdSets: const <List<String>>[],
      cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
      fallbackRecommendation: 'single_camera_only',
    );

    test(
      'allowDiagnosticSyntheticMode=false -> productionHiddenSingleCameraFallback, hidden, physicalDual=false',
      () {
        final policy = planner.evaluate(
          report: smA566bReport,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policy.decision,
          equals(
            VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
          ),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isFalse);
        expect(policy.isPhysicalDualCamera, isFalse);
        expect(policy.selectedPrimaryCameraId, equals('0'));
        expect(policy.selectedSecondaryCameraId, equals('1'));
        expect(
          policy.reasons,
          anyOf(
            contains('no_matching_concurrent_camera_set'),
            contains('no_concurrent_camera_combination'),
          ),
        );
        expect(
          policy.reasons,
          isNot(contains('diagnostic_synthetic_single_camera_enabled')),
        );
      },
    );

    test(
      'allowDiagnosticSyntheticMode=true -> diagnosticSyntheticSingleCamera, hidden, diagnostic=true, physicalDual=false',
      () {
        final policy = planner.evaluate(
          report: smA566bReport,
          allowDiagnosticSyntheticMode: true,
        );

        expect(
          policy.decision,
          equals(
            VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
          ),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isTrue);
        expect(policy.isPhysicalDualCamera, isFalse);
        expect(policy.selectedPrimaryCameraId, equals('0'));
        expect(policy.selectedSecondaryCameraId, equals('1'));
        expect(
          policy.reasons,
          contains('diagnostic_synthetic_single_camera_enabled'),
        );
        expect(
          policy.reasons,
          anyOf(
            contains('no_matching_concurrent_camera_set'),
            contains('no_concurrent_camera_combination'),
          ),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // 6. Candidate Concurrent Report With Matching Set & Runtime Supported Report
  // -------------------------------------------------------------------------
  group('Candidate concurrent report with runtime supported validation', () {
    test(
      'Runtime supported report promotes candidate to productionRealDualCamera with physicalDual=true',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameraCount: 2,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: const <List<String>>[
            <String>['0', '1'],
          ],
          cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
          fallbackRecommendation: 'concurrent_supported',
        );

        final validationReport = makeValidationReport(
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
        );

        final policy = planner.evaluate(
          report: report,
          runtimeValidationReport: validationReport,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policy.decision,
          equals(VGDuetDualCameraCapabilityDecision.productionRealDualCamera),
        );
        expect(policy.isProductionVisible, isTrue);
        expect(policy.isProductionRealDualCamera, isTrue);
        expect(policy.isDiagnosticSyntheticMode, isFalse);
        expect(policy.isPhysicalDualCamera, isTrue);
        expect(policy.selectedPrimaryCameraId, equals('0'));
        expect(policy.selectedSecondaryCameraId, equals('1'));
        expect(
          policy.diagnostics['runtimeValidationDecision'],
          equals('supported'),
        );
        expect(policy.diagnostics['runtimeValidationCameraIdsMatch'], isTrue);
      },
    );

    test(
      'Runtime supported report with order-inverted camera IDs promotes to productionRealDualCamera',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameraCount: 2,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: const <List<String>>[
            <String>['0', '1'],
          ],
          cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
          fallbackRecommendation: 'concurrent_supported',
        );

        final validationReport = makeValidationReport(
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          selectedConcurrentCameraIds: const <String>['1', '0'],
        );

        final policy = planner.evaluate(
          report: report,
          runtimeValidationReport: validationReport,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policy.decision,
          equals(VGDuetDualCameraCapabilityDecision.productionRealDualCamera),
        );
        expect(policy.isProductionVisible, isTrue);
        expect(policy.isProductionRealDualCamera, isTrue);
        expect(policy.isDiagnosticSyntheticMode, isFalse);
        expect(policy.isPhysicalDualCamera, isTrue);
        expect(policy.selectedPrimaryCameraId, equals('0'));
        expect(policy.selectedSecondaryCameraId, equals('1'));
        expect(policy.diagnostics['runtimeValidationCameraIdsMatch'], isTrue);
        expect(
          policy.reasons,
          isNot(contains('runtime_validation_camera_ids_mismatch')),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // 7. Candidate Concurrent Report With No Runtime Report
  // -------------------------------------------------------------------------
  group('Candidate concurrent report with no runtime report', () {
    test(
      'Unvalidated candidate defaults to productionHiddenSingleCameraFallback with runtime_validation_required',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameraCount: 2,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: const <List<String>>[
            <String>['0', '1'],
          ],
          cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
          fallbackRecommendation: 'concurrent_supported',
        );

        final policy = planner.evaluate(
          report: report,
          runtimeValidationReport: null,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policy.decision,
          equals(
            VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
          ),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isFalse);
        expect(policy.isPhysicalDualCamera, isFalse);
        expect(policy.selectedPrimaryCameraId, equals('0'));
        expect(policy.selectedSecondaryCameraId, equals('1'));
        expect(policy.reasons, contains('runtime_validation_required'));
        expect(
          policy.diagnostics.containsKey('runtimeValidationCameraIdsMatch'),
          isFalse,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // 8. Runtime notSupported Report
  // -------------------------------------------------------------------------
  group('Runtime notSupported report scenario', () {
    final backCam = makeCamera(id: '0', lensFacing: 'back');
    final frontCam = makeCamera(id: '1', lensFacing: 'front');
    final report = makeReport(
      cameraCount: 2,
      supportsConcurrentCamera: true,
      concurrentCameraIdSets: const <List<String>>[
        <String>['0', '1'],
      ],
      cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
      fallbackRecommendation: 'concurrent_supported',
    );

    final notSupportedValidation = makeValidationReport(
      attemptedRuntimeValidation: true,
      supported: false,
      decision: VGCamera2ConcurrentSessionValidationDecision.notSupported,
      reasons: const <String>['concurrent_session_not_supported'],
    );

    test(
      'Runtime notSupported -> productionHiddenSingleCameraFallback when diagnostic mode false',
      () {
        final policy = planner.evaluate(
          report: report,
          runtimeValidationReport: notSupportedValidation,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policy.decision,
          equals(
            VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
          ),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isFalse);
        expect(policy.isPhysicalDualCamera, isFalse);
      },
    );

    test(
      'Runtime notSupported -> diagnosticSyntheticSingleCamera when diagnostic mode true',
      () {
        final policy = planner.evaluate(
          report: report,
          runtimeValidationReport: notSupportedValidation,
          allowDiagnosticSyntheticMode: true,
        );

        expect(
          policy.decision,
          equals(
            VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
          ),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isTrue);
        expect(policy.isPhysicalDualCamera, isFalse);
        expect(
          policy.reasons,
          contains('diagnostic_synthetic_single_camera_enabled'),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // 9. Diagnostics Map Context Completeness
  // -------------------------------------------------------------------------
  group('Diagnostics context completeness', () {
    test('Diagnostics map includes all required fields', () {
      final backCam = makeCamera(id: '0', lensFacing: 'back');
      final frontCam = makeCamera(id: '1', lensFacing: 'front');
      final report = makeReport(
        cameraCount: 2,
        hasCameraPermission: true,
        supportsConcurrentCamera: true,
        concurrentCameraIdSets: const <List<String>>[
          <String>['0', '1'],
        ],
        cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
      );

      final validationReport = makeValidationReport(
        decision: VGCamera2ConcurrentSessionValidationDecision.supported,
      );

      final policy = planner.evaluate(
        report: report,
        runtimeValidationReport: validationReport,
      );

      expect(policy.diagnostics['cameraCount'], equals(2));
      expect(policy.diagnostics['supportsConcurrentCamera'], isTrue);
      expect(
        policy.diagnostics['readinessDecision'],
        equals('dualCameraCandidate'),
      );
      expect(
        policy.diagnostics['sessionConfigurationDecision'],
        equals('concurrentValidationCandidate'),
      );
      expect(
        policy.diagnostics['runtimeValidationDecision'],
        equals('supported'),
      );
      expect(policy.diagnostics['runtimeValidationCameraIdsMatch'], isTrue);
      expect(policy.diagnostics['requiresRuntimeSessionValidation'], isTrue);
      expect(policy.diagnostics['hasCameraPermission'], isTrue);
      expect(policy.diagnostics['selectedPrimaryCameraId'], equals('0'));
      expect(policy.diagnostics['selectedSecondaryCameraId'], equals('1'));
    });
  });

  // -------------------------------------------------------------------------
  // 10. Pass Pre-Computed Readiness and Session Configuration Plans
  // -------------------------------------------------------------------------
  group('Pre-computed plan injection', () {
    test(
      'evaluate honors injected readinessPlan and sessionConfigurationPlan',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameraCount: 2,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: const <List<String>>[
            <String>['0', '1'],
          ],
          cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
        );

        final readiness = const VGCamera2ReadinessPlanner().evaluate(report);
        final sessionPlan = const VGCamera2SessionConfigurationPlanner()
            .evaluate(report: report, readinessPlan: readiness);

        final validationReport = makeValidationReport(
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
        );

        final policy = planner.evaluate(
          report: report,
          readinessPlan: readiness,
          sessionConfigurationPlan: sessionPlan,
          runtimeValidationReport: validationReport,
        );

        expect(
          policy.decision,
          equals(VGDuetDualCameraCapabilityDecision.productionRealDualCamera),
        );
        expect(policy.isProductionVisible, isTrue);
        expect(policy.isPhysicalDualCamera, isTrue);
      },
    );
  });

  // -------------------------------------------------------------------------
  // 11. Mismatched Supported Validation Report Scenarios
  // -------------------------------------------------------------------------
  group('Mismatched supported validation report scenarios', () {
    final backCam = makeCamera(id: '0', lensFacing: 'back');
    final frontCam = makeCamera(id: '1', lensFacing: 'front');
    final report = makeReport(
      cameraCount: 2,
      supportsConcurrentCamera: true,
      concurrentCameraIdSets: const <List<String>>[
        <String>['0', '1'],
      ],
      cameras: <VGCameraHardwareDeviceCapability>[backCam, frontCam],
      fallbackRecommendation: 'concurrent_supported',
    );

    test(
      'Mismatched IDs with allowDiagnosticSyntheticMode=false -> productionHiddenSingleCameraFallback with mismatch reason',
      () {
        final mismatchedValidation = makeValidationReport(
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          selectedConcurrentCameraIds: const <String>['0', '2'],
        );

        final policy = planner.evaluate(
          report: report,
          runtimeValidationReport: mismatchedValidation,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policy.decision,
          equals(
            VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
          ),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isFalse);
        expect(policy.isPhysicalDualCamera, isFalse);
        expect(policy.selectedPrimaryCameraId, equals('0'));
        expect(policy.selectedSecondaryCameraId, equals('1'));
        expect(
          policy.reasons,
          contains('runtime_validation_camera_ids_mismatch'),
        );
        expect(policy.diagnostics['runtimeValidationCameraIdsMatch'], isFalse);
        expect(
          policy.diagnostics['runtimeValidationDecision'],
          equals('supported'),
        );
      },
    );

    test(
      'Mismatched IDs with allowDiagnosticSyntheticMode=true -> diagnosticSyntheticSingleCamera with mismatch reason',
      () {
        final mismatchedValidation = makeValidationReport(
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          selectedConcurrentCameraIds: const <String>['0', '2'],
        );

        final policy = planner.evaluate(
          report: report,
          runtimeValidationReport: mismatchedValidation,
          allowDiagnosticSyntheticMode: true,
        );

        expect(
          policy.decision,
          equals(
            VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
          ),
        );
        expect(policy.isProductionVisible, isFalse);
        expect(policy.isProductionRealDualCamera, isFalse);
        expect(policy.isDiagnosticSyntheticMode, isTrue);
        expect(policy.isPhysicalDualCamera, isFalse);
        expect(policy.selectedPrimaryCameraId, equals('0'));
        expect(policy.selectedSecondaryCameraId, equals('1'));
        expect(
          policy.reasons,
          contains('runtime_validation_camera_ids_mismatch'),
        );
        expect(
          policy.reasons,
          contains('diagnostic_synthetic_single_camera_enabled'),
        );
        expect(policy.diagnostics['runtimeValidationCameraIdsMatch'], isFalse);
        expect(
          policy.diagnostics['runtimeValidationDecision'],
          equals('supported'),
        );
      },
    );

    test(
      'Cardinality mismatch (extra or missing ID) -> productionHiddenSingleCameraFallback with mismatch reason',
      () {
        final extraIdValidation = makeValidationReport(
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          selectedConcurrentCameraIds: const <String>['0', '1', '2'],
        );

        final policyExtra = planner.evaluate(
          report: report,
          runtimeValidationReport: extraIdValidation,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policyExtra.decision,
          equals(
            VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
          ),
        );
        expect(policyExtra.isProductionVisible, isFalse);
        expect(policyExtra.isProductionRealDualCamera, isFalse);
        expect(
          policyExtra.reasons,
          contains('runtime_validation_camera_ids_mismatch'),
        );
        expect(
          policyExtra.diagnostics['runtimeValidationCameraIdsMatch'],
          isFalse,
        );

        final singleIdValidation = makeValidationReport(
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          selectedConcurrentCameraIds: const <String>['0'],
        );

        final policySingle = planner.evaluate(
          report: report,
          runtimeValidationReport: singleIdValidation,
          allowDiagnosticSyntheticMode: false,
        );

        expect(
          policySingle.decision,
          equals(
            VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
          ),
        );
        expect(policySingle.isProductionVisible, isFalse);
        expect(policySingle.isProductionRealDualCamera, isFalse);
        expect(
          policySingle.reasons,
          contains('runtime_validation_camera_ids_mismatch'),
        );
        expect(
          policySingle.diagnostics['runtimeValidationCameraIdsMatch'],
          isFalse,
        );
      },
    );
  });
}
