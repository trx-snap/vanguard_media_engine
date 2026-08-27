// vg_camera2_thermal_fallback_matrix_test.dart
// vanguard_media_engine — Phase 3-Unit S: Android Camera2 Static Thermal Fallback
// Matrix Physical Proof Foundation unit & contract tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Helper to build a mock camera capability
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

  // Standard dual-camera fixtures
  final backCamera = makeCamera(id: '0', lensFacing: 'back');
  final frontCamera = makeCamera(id: '1', lensFacing: 'front');
  final standardDualCameras = <VGCameraHardwareDeviceCapability>[
    backCamera,
    frontCamera,
  ];
  final standardConcurrentSets = <List<String>>[
    <String>['0', '1'],
  ];

  // Local helper replicating Android probe fallback recommendation logic
  String computeProbeFallbackRecommendation({
    required int cameraCount,
    required int? thermalStatus,
    required String thermalStatusName,
    required bool supportsConcurrentCamera,
  }) {
    final isThermalBlocked =
        (thermalStatus != null && thermalStatus >= 3) ||
        const <String>{
          'severe',
          'critical',
          'emergency',
          'shutdown',
        }.contains(thermalStatusName);
    if (cameraCount == 0) {
      return 'no_camera';
    }
    if (isThermalBlocked) {
      return 'thermal_blocked';
    }
    if (supportsConcurrentCamera) {
      return 'concurrent_supported';
    }
    return 'single_camera_only';
  }

  const planner = VGCamera2ReadinessPlanner();

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Static Thermal Matrix: Nominal & Moderate (Non-Blocked)
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlanner static thermal matrix — non-blocked states', () {
    test(
      'thermalStatus=0 / thermalStatusName=none permits dual camera candidate when concurrent supported',
      () {
        final report = makeReport(
          thermalStatus: 0,
          thermalStatusName: 'none',
          cameras: standardDualCameras,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: standardConcurrentSets,
          fallbackRecommendation: 'concurrent_supported',
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.dualCameraCandidate),
        );
        expect(plan.isDualCameraCandidate, isTrue);
        expect(plan.isSingleCameraOnly, isFalse);
        expect(plan.isBlocked, isFalse);
        expect(plan.reasons, isNot(contains('thermal_blocked')));
      },
    );

    test(
      'thermalStatus=1 / thermalStatusName=light permits dual camera candidate when concurrent supported',
      () {
        final report = makeReport(
          thermalStatus: 1,
          thermalStatusName: 'light',
          cameras: standardDualCameras,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: standardConcurrentSets,
          fallbackRecommendation: 'concurrent_supported',
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.dualCameraCandidate),
        );
        expect(plan.isDualCameraCandidate, isTrue);
        expect(plan.isSingleCameraOnly, isFalse);
        expect(plan.isBlocked, isFalse);
        expect(plan.reasons, isNot(contains('thermal_blocked')));
      },
    );

    test(
      'thermalStatus=2 / thermalStatusName=moderate is not thermal blocked in planner semantics',
      () {
        // With concurrent camera support
        final dualReport = makeReport(
          thermalStatus: 2,
          thermalStatusName: 'moderate',
          cameras: standardDualCameras,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: standardConcurrentSets,
          fallbackRecommendation: 'concurrent_supported',
        );

        final dualPlan = planner.evaluate(dualReport);
        expect(
          dualPlan.decision,
          equals(VGCamera2ReadinessDecision.dualCameraCandidate),
        );
        expect(dualPlan.isBlocked, isFalse);
        expect(dualPlan.reasons, isNot(contains('thermal_blocked')));

        // Without concurrent camera support (single camera fallback)
        final singleReport = makeReport(
          thermalStatus: 2,
          thermalStatusName: 'moderate',
          cameras: standardDualCameras,
          supportsConcurrentCamera: false,
          concurrentCameraIdSets: const <List<String>>[],
          fallbackRecommendation: 'single_camera_only',
        );

        final singlePlan = planner.evaluate(singleReport);
        expect(
          singlePlan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(singlePlan.isBlocked, isFalse);
        expect(singlePlan.reasons, isNot(contains('thermal_blocked')));
        expect(
          singlePlan.reasons,
          contains('no_matching_concurrent_camera_set'),
        );
      },
    );

    test(
      'thermalStatus=null / thermalStatusName=unavailable is not thermal blocked',
      () {
        final report = makeReport(
          thermalStatus: null,
          thermalStatusName: 'unavailable',
          cameras: standardDualCameras,
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: standardConcurrentSets,
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.dualCameraCandidate),
        );
        expect(plan.isBlocked, isFalse);
        expect(plan.reasons, isNot(contains('thermal_blocked')));
      },
    );

    test(
      'nominal thermal status with no concurrent support produces singleCameraOnly without thermal reason',
      () {
        final report = makeReport(
          thermalStatus: 0,
          thermalStatusName: 'none',
          cameras: <VGCameraHardwareDeviceCapability>[backCamera],
          supportsConcurrentCamera: false,
          fallbackRecommendation: 'single_camera_only',
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(plan.isSingleCameraOnly, isTrue);
        expect(plan.isBlocked, isFalse);
        expect(plan.reasons, isNot(contains('thermal_blocked')));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Static Thermal Matrix: Blocked States (Severe/Critical/Emergency/Shutdown)
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlanner static thermal matrix — blocked states', () {
    const severeTokens = <(String, int)>[
      ('severe', 3),
      ('critical', 4),
      ('emergency', 5),
      ('shutdown', 6),
    ];

    for (final (name, status) in severeTokens) {
      test(
        'thermalStatusName=$name with status=$status produces thermalBlocked',
        () {
          final report = makeReport(
            thermalStatus: status,
            thermalStatusName: name,
            cameras: standardDualCameras,
            supportsConcurrentCamera: true,
            concurrentCameraIdSets: standardConcurrentSets,
            fallbackRecommendation: 'thermal_blocked',
          );

          final plan = planner.evaluate(report);

          expect(
            plan.decision,
            equals(VGCamera2ReadinessDecision.thermalBlocked),
          );
          expect(plan.isBlocked, isTrue);
          expect(plan.isDualCameraCandidate, isFalse);
          expect(plan.isSingleCameraOnly, isFalse);
          expect(plan.reasons, contains('thermal_blocked'));
          expect(plan.selectedPrimaryCameraId, isNull);
          expect(plan.selectedSecondaryCameraId, isNull);
          expect(plan.selectedPreviewSize, isNull);
          expect(plan.selectedVideoSize, isNull);
          expect(plan.selectedFpsRange, isNull);
        },
      );
    }

    test(
      'numeric thermalStatus >= 3 blocks even if thermalStatusName is unknown or none',
      () {
        final statusesToTest = <(int, String)>[
          (3, 'none'),
          (3, 'unknown_3'),
          (4, 'light'),
          (4, 'unknown_4'),
          (5, 'moderate'),
          (5, 'unknown_5'),
          (6, 'none'),
          (7, 'unknown_7'),
        ];

        for (final (status, name) in statusesToTest) {
          final report = makeReport(
            thermalStatus: status,
            thermalStatusName: name,
            cameras: standardDualCameras,
            supportsConcurrentCamera: true,
            concurrentCameraIdSets: standardConcurrentSets,
          );

          final plan = planner.evaluate(report);

          expect(
            plan.decision,
            equals(VGCamera2ReadinessDecision.thermalBlocked),
            reason: 'Expected thermalBlocked for status=$status, name=$name',
          );
          expect(plan.isBlocked, isTrue);
          expect(plan.reasons, contains('thermal_blocked'));
        }
      },
    );

    test(
      'severe thermalStatusName blocks even if numeric status is null or 0',
      () {
        const severeNames = <String>[
          'severe',
          'critical',
          'emergency',
          'shutdown',
        ];

        for (final name in severeNames) {
          // null numeric status
          final nullReport = makeReport(
            thermalStatus: null,
            thermalStatusName: name,
            cameras: standardDualCameras,
            supportsConcurrentCamera: true,
            concurrentCameraIdSets: standardConcurrentSets,
          );
          final nullPlan = planner.evaluate(nullReport);
          expect(
            nullPlan.decision,
            equals(VGCamera2ReadinessDecision.thermalBlocked),
            reason: 'Expected thermalBlocked for name=$name with status=null',
          );
          expect(nullPlan.isBlocked, isTrue);
          expect(nullPlan.reasons, contains('thermal_blocked'));

          // status=0 with severe name
          final zeroReport = makeReport(
            thermalStatus: 0,
            thermalStatusName: name,
            cameras: standardDualCameras,
            supportsConcurrentCamera: true,
            concurrentCameraIdSets: standardConcurrentSets,
          );
          final zeroPlan = planner.evaluate(zeroReport);
          expect(
            zeroPlan.decision,
            equals(VGCamera2ReadinessDecision.thermalBlocked),
            reason: 'Expected thermalBlocked for name=$name with status=0',
          );
          expect(zeroPlan.isBlocked, isTrue);
          expect(zeroPlan.reasons, contains('thermal_blocked'));
        }
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Precedence: No Camera vs Thermal Blocked
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlanner precedence — no-camera vs thermal', () {
    test(
      'no-camera report returns noCamera even when thermalStatus is severe or emergency',
      () {
        final severeNoCamReport = makeReport(
          cameraCount: 0,
          cameras: const <VGCameraHardwareDeviceCapability>[],
          thermalStatus: 3,
          thermalStatusName: 'severe',
          fallbackRecommendation: 'no_camera',
        );

        final plan = planner.evaluate(severeNoCamReport);

        expect(plan.decision, equals(VGCamera2ReadinessDecision.noCamera));
        expect(plan.isBlocked, isTrue);
        expect(plan.reasons, contains('no_camera_available'));
        expect(
          plan.reasons,
          isNot(contains('thermal_blocked')),
          reason:
              'no-camera precedence must be evaluated before thermal status',
        );
      },
    );

    test(
      'cameras empty with cameraCount > 0 still produces noCamera precedence',
      () {
        final report = makeReport(
          cameraCount: 2,
          cameras: const <VGCameraHardwareDeviceCapability>[],
          thermalStatus: 5,
          thermalStatusName: 'emergency',
          fallbackRecommendation: 'no_camera',
        );

        final plan = planner.evaluate(report);

        expect(plan.decision, equals(VGCamera2ReadinessDecision.noCamera));
        expect(plan.reasons, contains('no_camera_available'));
        expect(plan.reasons, isNot(contains('thermal_blocked')));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Native / Probe Fallback Recommendation Hierarchy
  // ─────────────────────────────────────────────────────────────────────────
  group(
    'Native probe fallback recommendation hierarchy: no_camera > thermal_blocked > concurrent_supported > single_camera_only',
    () {
      test(
        'no_camera wins when cameraCount == 0 regardless of thermal or concurrency',
        () {
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 0,
              thermalStatus: 0,
              thermalStatusName: 'none',
              supportsConcurrentCamera: false,
            ),
            equals('no_camera'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 0,
              thermalStatus: 3,
              thermalStatusName: 'severe',
              supportsConcurrentCamera: true,
            ),
            equals('no_camera'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 0,
              thermalStatus: 5,
              thermalStatusName: 'emergency',
              supportsConcurrentCamera: false,
            ),
            equals('no_camera'),
          );
        },
      );

      test(
        'thermal_blocked wins when cameraCount > 0 and thermal status is blocked',
        () {
          // With concurrent camera support
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 3,
              thermalStatusName: 'severe',
              supportsConcurrentCamera: true,
            ),
            equals('thermal_blocked'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 4,
              thermalStatusName: 'critical',
              supportsConcurrentCamera: true,
            ),
            equals('thermal_blocked'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 5,
              thermalStatusName: 'emergency',
              supportsConcurrentCamera: true,
            ),
            equals('thermal_blocked'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 6,
              thermalStatusName: 'shutdown',
              supportsConcurrentCamera: true,
            ),
            equals('thermal_blocked'),
          );
          // Without concurrent camera support
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 1,
              thermalStatus: 3,
              thermalStatusName: 'severe',
              supportsConcurrentCamera: false,
            ),
            equals('thermal_blocked'),
          );
          // Numeric status >= 3 overrides nominal name
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 3,
              thermalStatusName: 'none',
              supportsConcurrentCamera: true,
            ),
            equals('thermal_blocked'),
          );
          // Severe name overrides null numeric status
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: null,
              thermalStatusName: 'critical',
              supportsConcurrentCamera: true,
            ),
            equals('thermal_blocked'),
          );
        },
      );

      test(
        'concurrent_supported wins when cameraCount > 0, not thermal blocked, and concurrency supported',
        () {
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 0,
              thermalStatusName: 'none',
              supportsConcurrentCamera: true,
            ),
            equals('concurrent_supported'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 1,
              thermalStatusName: 'light',
              supportsConcurrentCamera: true,
            ),
            equals('concurrent_supported'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 2,
              thermalStatusName: 'moderate',
              supportsConcurrentCamera: true,
            ),
            equals('concurrent_supported'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: null,
              thermalStatusName: 'unavailable',
              supportsConcurrentCamera: true,
            ),
            equals('concurrent_supported'),
          );
        },
      );

      test(
        'single_camera_only is selected when cameraCount > 0, not thermal blocked, and concurrency unsupported',
        () {
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 1,
              thermalStatus: 0,
              thermalStatusName: 'none',
              supportsConcurrentCamera: false,
            ),
            equals('single_camera_only'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 4,
              thermalStatus: 0,
              thermalStatusName: 'none',
              supportsConcurrentCamera: false,
            ),
            equals('single_camera_only'),
          );
          expect(
            computeProbeFallbackRecommendation(
              cameraCount: 2,
              thermalStatus: 2,
              thermalStatusName: 'moderate',
              supportsConcurrentCamera: false,
            ),
            equals('single_camera_only'),
          );
        },
      );
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Diagnostics Preservation for Non-Blocked and Blocked Cases
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlanner diagnostics preservation', () {
    test('preserves diagnostics for representative non-blocked report', () {
      final report = makeReport(
        apiLevel: 34,
        hasCameraPermission: true,
        thermalStatus: 0,
        thermalStatusName: 'none',
        cameras: standardDualCameras,
        supportsConcurrentCamera: true,
        concurrentCameraIdSets: standardConcurrentSets,
        fallbackRecommendation: 'concurrent_supported',
      );

      final plan = planner.evaluate(report);
      final diag = plan.diagnostics;

      expect(diag['cameraCount'], equals(2));
      expect(diag['supportsConcurrentCamera'], isTrue);
      expect(diag['hasCameraPermission'], isTrue);
      expect(diag['thermalStatusName'], equals('none'));
      expect(diag['primaryLensFacing'], equals('back'));
      expect(diag['secondaryLensFacing'], equals('front'));
      expect(diag['concurrentSetMatched'], isTrue);
    });

    test('preserves diagnostics for representative blocked report', () {
      final report = makeReport(
        apiLevel: 34,
        hasCameraPermission: false,
        thermalStatus: 4,
        thermalStatusName: 'critical',
        cameras: standardDualCameras,
        supportsConcurrentCamera: true,
        concurrentCameraIdSets: standardConcurrentSets,
        fallbackRecommendation: 'thermal_blocked',
      );

      final plan = planner.evaluate(report);
      final diag = plan.diagnostics;

      expect(diag['cameraCount'], equals(2));
      expect(diag['supportsConcurrentCamera'], isTrue);
      expect(diag['hasCameraPermission'], isFalse);
      expect(diag['thermalStatusName'], equals('critical'));
      expect(diag['primaryLensFacing'], equals('back'));
      expect(diag['secondaryLensFacing'], equals('front'));
      expect(diag['concurrentSetMatched'], isFalse);
    });

    test('preserves diagnostics for no-camera report with thermal info', () {
      final report = makeReport(
        apiLevel: 34,
        hasCameraPermission: true,
        thermalStatus: 3,
        thermalStatusName: 'severe',
        cameraCount: 0,
        cameras: const <VGCameraHardwareDeviceCapability>[],
        supportsConcurrentCamera: false,
        fallbackRecommendation: 'no_camera',
      );

      final plan = planner.evaluate(report);
      final diag = plan.diagnostics;

      expect(diag['cameraCount'], equals(0));
      expect(diag['supportsConcurrentCamera'], isFalse);
      expect(diag['hasCameraPermission'], isTrue);
      expect(diag['thermalStatusName'], equals('severe'));
      expect(diag['primaryLensFacing'], isNull);
      expect(diag['secondaryLensFacing'], isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Capability Report Serialization & Physical Target Baseline
  // ─────────────────────────────────────────────────────────────────────────
  group(
    'VGCameraHardwareCapabilityReport thermal fields serialization & preflight matching',
    () {
      test(
        'toMap and fromMap preserve thermalStatus, thermalStatusName, and fallbackRecommendation',
        () {
          final original = makeReport(
            apiLevel: 36,
            hasCameraPermission: false,
            thermalStatus: 0,
            thermalStatusName: 'none',
            cameraCount: 4,
            supportsConcurrentCamera: false,
            cameras: standardDualCameras,
            fallbackRecommendation: 'single_camera_only',
          );

          final map = original.toMap();
          expect(map['thermalStatus'], equals(0));
          expect(map['thermalStatusName'], equals('none'));
          expect(map['fallbackRecommendation'], equals('single_camera_only'));

          final restored = VGCameraHardwareCapabilityReport.fromMap(map);
          expect(restored.thermalStatus, equals(0));
          expect(restored.thermalStatusName, equals('none'));
          expect(restored.fallbackRecommendation, equals('single_camera_only'));
          expect(restored.cameraCount, equals(4));
          expect(restored.supportsConcurrentCamera, isFalse);
        },
      );

      test(
        'fromMap provides safe defaults when thermal fields are omitted',
        () {
          final minimalMap = <String, Object?>{'success': true, 'apiLevel': 34};

          final report = VGCameraHardwareCapabilityReport.fromMap(minimalMap);
          expect(report.thermalStatus, isNull);
          expect(report.thermalStatusName, equals('unavailable'));
          expect(report.fallbackRecommendation, equals('no_camera'));
        },
      );

      test('replicates SM-A566B/API 36 preflight snapshot evaluation', () {
        // Baseline observed on physical Samsung SM-A566B:
        // thermalStatus=0, thermalStatusName=none, cameraCount=4,
        // supportsConcurrentCamera=false, fallbackRecommendation=single_camera_only
        final preflightReport = makeReport(
          apiLevel: 36,
          hasCameraPermission: false,
          thermalStatus: 0,
          thermalStatusName: 'none',
          cameraCount: 4,
          supportsConcurrentCamera: false,
          concurrentCameraIdSets: const <List<String>>[],
          cameras: <VGCameraHardwareDeviceCapability>[
            makeCamera(id: '0', lensFacing: 'back'),
            makeCamera(id: '1', lensFacing: 'front'),
            makeCamera(id: '2', lensFacing: 'back'),
            makeCamera(id: '3', lensFacing: 'back'),
          ],
          fallbackRecommendation: 'single_camera_only',
        );

        final plan = planner.evaluate(preflightReport);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(plan.isSingleCameraOnly, isTrue);
        expect(plan.isBlocked, isFalse);
        expect(plan.reasons, isNot(contains('thermal_blocked')));
        expect(plan.reasons, contains('camera_permission_absent'));
        expect(plan.reasons, contains('no_matching_concurrent_camera_set'));
        expect(plan.diagnostics['thermalStatusName'], equals('none'));
        expect(plan.diagnostics['cameraCount'], equals(4));
        expect(plan.diagnostics['supportsConcurrentCamera'], isFalse);
      });
    },
  );
}
