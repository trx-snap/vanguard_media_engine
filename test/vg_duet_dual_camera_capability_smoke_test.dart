// vg_duet_dual_camera_capability_smoke_test.dart
// vanguard_media_engine - P3-CAM-DUET-CAPABILITY-ADMISSION-ROUTE: Smoke contract & runner tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

class _FakeDuetCapabilityEvaluator extends VGDuetDualCameraCapabilityEvaluator {
  _FakeDuetCapabilityEvaluator({
    required this.productionPolicy,
    required this.diagnosticPolicy,
  });

  final VGDuetDualCameraCapabilityPolicy productionPolicy;
  final VGDuetDualCameraCapabilityPolicy diagnosticPolicy;

  @override
  Future<VGDuetDualCameraCapabilityPolicy> evaluateDevicePolicy({
    bool allowDiagnosticSyntheticMode = false,
    MethodChannel? channel,
  }) async {
    return allowDiagnosticSyntheticMode ? diagnosticPolicy : productionPolicy;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // 1. Constants and Markers
  // -------------------------------------------------------------------------
  group('Duet capability admission smoke markers and proof boundary', () {
    test('proof boundary has exact required string value', () {
      expect(
        kDuetDualCameraCapabilityAdmissionProofBoundary,
        equals(
          'duet_dual_camera_capability_admission_policy_derived_no_real_concurrent_hardware_proof_no_camera_open_no_render',
        ),
      );
    });

    test('pass marker has exact required token', () {
      expect(
        kDuetDualCameraCapabilityAdmissionPassMarker,
        equals(
          'ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_PHYSICAL_SMOKE_PASS',
        ),
      );
    });

    test('fail marker has exact required token with _FAIL suffix', () {
      expect(
        kDuetDualCameraCapabilityAdmissionFailMarker,
        equals(
          'ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_PHYSICAL_SMOKE_FAIL',
        ),
      );
    });

    test('start marker has exact expected token', () {
      expect(
        kDuetDualCameraCapabilityAdmissionStartMarker,
        equals(
          'ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_PHYSICAL_SMOKE_START',
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // 2. Report Serialization & Deserialization
  // -------------------------------------------------------------------------
  group('VGDuetDualCameraCapabilitySmokeReport map conversion', () {
    const prodPolicy = VGDuetDualCameraCapabilityPolicy(
      decision: VGDuetDualCameraCapabilityDecision
          .productionHiddenSingleCameraFallback,
      reasons: <String>['no_concurrent_camera_combination'],
      diagnostics: <String, Object?>{
        'supportsConcurrentCamera': false,
        'cameraCount': 2,
      },
      isProductionVisible: false,
      isProductionRealDualCamera: false,
      isDiagnosticSyntheticMode: false,
      isPhysicalDualCamera: false,
      selectedPrimaryCameraId: '0',
    );

    const diagPolicy = VGDuetDualCameraCapabilityPolicy(
      decision:
          VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
      reasons: <String>[
        'diagnostic_synthetic_single_camera_enabled',
        'no_concurrent_camera_combination',
      ],
      diagnostics: <String, Object?>{
        'supportsConcurrentCamera': false,
        'cameraCount': 2,
      },
      isProductionVisible: false,
      isProductionRealDualCamera: false,
      isDiagnosticSyntheticMode: true,
      isPhysicalDualCamera: false,
      selectedPrimaryCameraId: '0',
    );

    test('toMap and fromMap roundtrip preserves all fields', () {
      const report = VGDuetDualCameraCapabilitySmokeReport(
        pass: true,
        proofBoundary: kDuetDualCameraCapabilityAdmissionProofBoundary,
        passMarker: kDuetDualCameraCapabilityAdmissionPassMarker,
        failMarker: kDuetDualCameraCapabilityAdmissionFailMarker,
        productionPolicy: prodPolicy,
        diagnosticPolicy: diagPolicy,
        reasons: <String>['duet_unsupported_hardware_fail_closed_pass'],
        diagnostics: <String, Object?>{
          'proofBoundary': kDuetDualCameraCapabilityAdmissionProofBoundary,
          'supportsConcurrentCamera': false,
        },
      );

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(
        map['proofBoundary'],
        equals(kDuetDualCameraCapabilityAdmissionProofBoundary),
      );
      expect(
        map['passMarker'],
        equals(kDuetDualCameraCapabilityAdmissionPassMarker),
      );
      expect(
        map['failMarker'],
        equals(kDuetDualCameraCapabilityAdmissionFailMarker),
      );
      expect(map['productionPolicy'], isA<Map<String, Object?>>());
      expect(map['diagnosticPolicy'], isA<Map<String, Object?>>());

      final roundtripped = VGDuetDualCameraCapabilitySmokeReport.fromMap(map);
      expect(roundtripped, isNotNull);
      expect(roundtripped, equals(report));
      expect(roundtripped!.pass, isTrue);
      expect(
        roundtripped.productionPolicy.isProductionHiddenSingleCameraFallback,
        isTrue,
      );
      expect(
        roundtripped.diagnosticPolicy.decision,
        equals(
          VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
        ),
      );
    });

    test('fromMap returns null on non-map or corrupt policy map', () {
      expect(VGDuetDualCameraCapabilitySmokeReport.fromMap(null), isNull);
      expect(VGDuetDualCameraCapabilitySmokeReport.fromMap('string'), isNull);
      expect(
        VGDuetDualCameraCapabilitySmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'productionPolicy': null,
          'diagnosticPolicy': null,
        }),
        isNull,
      );
    });
  });

  // -------------------------------------------------------------------------
  // 3. Unsupported Hardware PASS Shape (SM-A566B profile)
  // -------------------------------------------------------------------------
  group('Unsupported device PASS verification (SM-A566B shape)', () {
    test(
      'Unsupported device: production hidden fallback, diagnostic synthetic mode, physicalDual=false',
      () async {
        const prod = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .productionHiddenSingleCameraFallback,
          reasons: <String>['no_concurrent_camera_combination'],
          diagnostics: <String, Object?>{
            'supportsConcurrentCamera': false,
            'cameraCount': 2,
          },
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: null,
        );

        const diag = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .diagnosticSyntheticSingleCamera,
          reasons: <String>[
            'diagnostic_synthetic_single_camera_enabled',
            'no_concurrent_camera_combination',
          ],
          diagnostics: <String, Object?>{
            'supportsConcurrentCamera': false,
            'cameraCount': 2,
          },
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: true,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: null,
        );

        final evaluator = _FakeDuetCapabilityEvaluator(
          productionPolicy: prod,
          diagnosticPolicy: diag,
        );

        final report = await VGDuetDualCameraCapabilitySmokeRunner.run(
          evaluator: evaluator,
        );

        expect(report.pass, isTrue);
        expect(
          report.proofBoundary,
          equals(kDuetDualCameraCapabilityAdmissionProofBoundary),
        );
        expect(
          report.reasons,
          contains('duet_unsupported_hardware_fail_closed_pass'),
        );
        expect(report.productionPolicy.isProductionVisible, isFalse);
        expect(report.productionPolicy.isProductionRealDualCamera, isFalse);
        expect(report.productionPolicy.isPhysicalDualCamera, isFalse);
        expect(report.diagnosticPolicy.isDiagnosticSyntheticMode, isTrue);
        expect(report.diagnosticPolicy.isPhysicalDualCamera, isFalse);
        expect(report.diagnostics['supportsConcurrentCamera'], isFalse);
      },
    );

    test(
      'Unsupported device with 0 cameras: blocked for both -> PASS',
      () async {
        const prod = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.blocked,
          reasons: <String>['no_camera_available'],
          diagnostics: <String, Object?>{
            'supportsConcurrentCamera': false,
            'cameraCount': 0,
          },
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: false,
        );

        const diag = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.blocked,
          reasons: <String>['no_camera_available'],
          diagnostics: <String, Object?>{
            'supportsConcurrentCamera': false,
            'cameraCount': 0,
          },
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: false,
        );

        final evaluator = _FakeDuetCapabilityEvaluator(
          productionPolicy: prod,
          diagnosticPolicy: diag,
        );

        final report = await VGDuetDualCameraCapabilitySmokeRunner.run(
          evaluator: evaluator,
        );

        expect(report.pass, isTrue);
        expect(
          report.reasons,
          contains('duet_unsupported_hardware_fail_closed_pass'),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // 4. Real Supported Hardware PASS Shape
  // -------------------------------------------------------------------------
  group('Real supported hardware PASS verification', () {
    test(
      'Real supported hardware: production real dual camera, diagnostic not downgraded -> PASS',
      () async {
        const prod = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          reasons: <String>['concurrent_session_supported'],
          diagnostics: <String, Object?>{
            'supportsConcurrentCamera': true,
            'cameraCount': 2,
            'runtimeValidationCameraIdsMatch': true,
            'runtimeValidationDecision': 'supported',
          },
          isProductionVisible: true,
          isProductionRealDualCamera: true,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: true,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        // Diagnostic policy must not downgrade real supported hardware
        const diag = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          reasons: <String>['concurrent_session_supported'],
          diagnostics: <String, Object?>{
            'supportsConcurrentCamera': true,
            'cameraCount': 2,
            'runtimeValidationCameraIdsMatch': true,
            'runtimeValidationDecision': 'supported',
          },
          isProductionVisible: true,
          isProductionRealDualCamera: true,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: true,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        final evaluator = _FakeDuetCapabilityEvaluator(
          productionPolicy: prod,
          diagnosticPolicy: diag,
        );

        final report = await VGDuetDualCameraCapabilitySmokeRunner.run(
          evaluator: evaluator,
        );

        expect(report.pass, isTrue);
        expect(
          report.reasons,
          contains('duet_real_concurrent_hardware_validated_pass'),
        );
        expect(report.productionPolicy.isProductionVisible, isTrue);
        expect(report.productionPolicy.isProductionRealDualCamera, isTrue);
        expect(report.productionPolicy.isPhysicalDualCamera, isTrue);
        expect(report.diagnosticPolicy.isPhysicalDualCamera, isTrue);
        expect(
          report.diagnosticPolicy.decision,
          equals(VGDuetDualCameraCapabilityDecision.productionRealDualCamera),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // 5. Fail Shapes Verification
  // -------------------------------------------------------------------------
  group('Smoke FAIL shapes verification', () {
    test(
      'Unsupported device claiming productionVisible=true -> FAIL',
      () async {
        const prod = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .productionHiddenSingleCameraFallback,
          reasons: <String>['no_concurrent_camera_combination'],
          diagnostics: <String, Object?>{'supportsConcurrentCamera': false},
          isProductionVisible: true, // ILLEGAL for fallback
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
        );

        const diag = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .diagnosticSyntheticSingleCamera,
          reasons: <String>['diagnostic_synthetic_single_camera_enabled'],
          diagnostics: <String, Object?>{'supportsConcurrentCamera': false},
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: true,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
        );

        final report = await VGDuetDualCameraCapabilitySmokeRunner.run(
          evaluator: _FakeDuetCapabilityEvaluator(
            productionPolicy: prod,
            diagnosticPolicy: diag,
          ),
        );

        expect(report.pass, isFalse);
        expect(report.reasons, contains('unsupported_production_visible_true'));
      },
    );

    test(
      'Unsupported device claiming physicalDual=true in diagnostic -> FAIL',
      () async {
        const prod = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .productionHiddenSingleCameraFallback,
          reasons: <String>['no_concurrent_camera_combination'],
          diagnostics: <String, Object?>{'supportsConcurrentCamera': false},
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
        );

        const diag = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .diagnosticSyntheticSingleCamera,
          reasons: <String>['diagnostic_synthetic_single_camera_enabled'],
          diagnostics: <String, Object?>{'supportsConcurrentCamera': false},
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: true,
          isPhysicalDualCamera: true, // ILLEGAL for synthetic
          selectedPrimaryCameraId: '0',
        );

        final report = await VGDuetDualCameraCapabilitySmokeRunner.run(
          evaluator: _FakeDuetCapabilityEvaluator(
            productionPolicy: prod,
            diagnosticPolicy: diag,
          ),
        );

        expect(report.pass, isFalse);
        expect(
          report.reasons,
          contains('unsupported_diagnostic_physical_dual_true'),
        );
      },
    );

    test(
      'Real supported device downgraded in diagnostic mode -> FAIL',
      () async {
        const prod = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          reasons: <String>['concurrent_session_supported'],
          diagnostics: <String, Object?>{
            'supportsConcurrentCamera': true,
            'runtimeValidationCameraIdsMatch': true,
          },
          isProductionVisible: true,
          isProductionRealDualCamera: true,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: true,
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
        );

        // Fault: downgraded to synthetic
        const diag = VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision
              .diagnosticSyntheticSingleCamera,
          reasons: <String>['diagnostic_synthetic_single_camera_enabled'],
          diagnostics: <String, Object?>{'supportsConcurrentCamera': true},
          isProductionVisible: false,
          isProductionRealDualCamera: false,
          isDiagnosticSyntheticMode: true,
          isPhysicalDualCamera: false,
          selectedPrimaryCameraId: '0',
        );

        final report = await VGDuetDualCameraCapabilitySmokeRunner.run(
          evaluator: _FakeDuetCapabilityEvaluator(
            productionPolicy: prod,
            diagnosticPolicy: diag,
          ),
        );

        expect(report.pass, isFalse);
        expect(
          report.reasons,
          contains('real_supported_downgraded_in_diagnostic_mode'),
        );
      },
    );

    test('Missing supportsConcurrentCamera in diagnostics -> FAIL', () async {
      const prod = VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision
            .productionHiddenSingleCameraFallback,
        reasons: <String>['no_concurrent_camera_combination'],
        diagnostics: <String, Object?>{}, // Missing supportsConcurrentCamera
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
        selectedPrimaryCameraId: '0',
      );

      const diag = VGDuetDualCameraCapabilityPolicy(
        decision:
            VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
        reasons: <String>['diagnostic_synthetic_single_camera_enabled'],
        diagnostics: <String, Object?>{},
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: true,
        isPhysicalDualCamera: false,
        selectedPrimaryCameraId: '0',
      );

      final report = await VGDuetDualCameraCapabilitySmokeRunner.run(
        evaluator: _FakeDuetCapabilityEvaluator(
          productionPolicy: prod,
          diagnosticPolicy: diag,
        ),
      );

      expect(report.pass, isFalse);
      expect(
        report.reasons,
        contains('diagnostics_missing_supportsConcurrentCamera'),
      );
    });
  });
}
