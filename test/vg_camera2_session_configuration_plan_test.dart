// vg_camera2_session_configuration_plan_test.dart
// vanguard_media_engine — Phase 3-Unit E: Android Camera2 Session Configuration
// Eligibility Planner tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Helper to build a mock mandatory concurrent stream info (Unit D fixture)
  VGCameraMandatoryConcurrentStreamInfo makeStreamInfo({
    bool isInput = false,
    int format = 34, // ImageFormat.PRIVATE
    String formatName = 'PRIVATE',
    int tenBitFormat = -1,
    String tenBitFormatName = 'none',
    bool is10BitCapable = false,
    bool isMaximumSize = false,
    bool isUltraHighResolution = false,
    int streamUseCase = 1, // PREVIEW
    String streamUseCaseName = 'PREVIEW',
    List<VGCameraSize> availableSizes = const <VGCameraSize>[
      VGCameraSize(1920, 1080),
      VGCameraSize(1280, 720),
    ],
  }) {
    return VGCameraMandatoryConcurrentStreamInfo(
      isInput: isInput,
      format: format,
      formatName: formatName,
      tenBitFormat: tenBitFormat,
      tenBitFormatName: tenBitFormatName,
      is10BitCapable: is10BitCapable,
      isMaximumSize: isMaximumSize,
      isUltraHighResolution: isUltraHighResolution,
      streamUseCase: streamUseCase,
      streamUseCaseName: streamUseCaseName,
      availableSizes: availableSizes,
    );
  }

  // Helper to build a mock mandatory concurrent stream combination (Unit D fixture)
  VGCameraMandatoryConcurrentStreamCombination makeStreamCombination({
    String description = 'Concurrent preview and record combination',
    bool isReprocessable = false,
    List<VGCameraMandatoryConcurrentStreamInfo> streams =
        const <VGCameraMandatoryConcurrentStreamInfo>[],
  }) {
    return VGCameraMandatoryConcurrentStreamCombination(
      description: description,
      isReprocessable: isReprocessable,
      streams: streams,
    );
  }

  // Helper to build a mock camera device capability
  VGCameraHardwareDeviceCapability makeCamera({
    required String id,
    required String lensFacing,
    int? sensorOrientation = 90,
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
    List<String> videoStabilizationModes = const <String>['off', 'on'],
    List<String> opticalStabilizationModes = const <String>['off'],
    VGCameraRect? sensorActiveArraySize = const VGCameraRect(0, 0, 4000, 3000),
    VGCameraSize? sensorPixelArraySize = const VGCameraSize(4000, 3000),
    List<VGCameraMandatoryConcurrentStreamCombination>
        mandatoryConcurrentStreamCombinations =
        const <VGCameraMandatoryConcurrentStreamCombination>[],
  }) {
    return VGCameraHardwareDeviceCapability(
      cameraId: id,
      lensFacing: lensFacing,
      sensorOrientation: sensorOrientation,
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
      videoStabilizationModes: videoStabilizationModes,
      opticalStabilizationModes: opticalStabilizationModes,
      sensorActiveArraySize: sensorActiveArraySize,
      sensorPixelArraySize: sensorPixelArraySize,
      mandatoryConcurrentStreamCombinations:
          mandatoryConcurrentStreamCombinations,
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

  const planner = VGCamera2SessionConfigurationPlanner();

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Export and Enum Verification
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2SessionConfiguration enums and public exports', () {
    test('VGCamera2SessionConfigurationDecision has expected values', () {
      expect(
        VGCamera2SessionConfigurationDecision.values,
        containsAll(<VGCamera2SessionConfigurationDecision>[
          VGCamera2SessionConfigurationDecision.blocked,
          VGCamera2SessionConfigurationDecision.singleCameraFallback,
          VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
        ]),
      );
      expect(VGCamera2SessionConfigurationDecision.values.length, equals(3));
    });

    test('VGCamera2SessionSurfaceRole has expected values', () {
      expect(
        VGCamera2SessionSurfaceRole.values,
        containsAll(<VGCamera2SessionSurfaceRole>[
          VGCamera2SessionSurfaceRole.preview,
          VGCamera2SessionSurfaceRole.videoRecord,
        ]),
      );
      expect(VGCamera2SessionSurfaceRole.values.length, equals(2));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGCamera2SessionSurfacePlan Contract
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2SessionSurfacePlan value semantics and serialization', () {
    test('toMap produces expected structure', () {
      const surface = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: VGCameraSize(1920, 1080),
        streamUseCaseName: 'PREVIEW',
      );

      final map = surface.toMap();
      expect(map['cameraId'], equals('0'));
      expect(map['role'], equals('preview'));
      expect(map['formatName'], equals('PRIVATE'));
      expect(map['size'], equals({'width': 1920, 'height': 1080}));
      expect(map['streamUseCaseName'], equals('PREVIEW'));
    });

    test('equality and hashCode compare all fields identically', () {
      const surfaceA = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.videoRecord,
        formatName: 'PRIVATE',
        size: VGCameraSize(3840, 2160),
        streamUseCaseName: 'VIDEO_RECORD',
      );

      const surfaceB = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.videoRecord,
        formatName: 'PRIVATE',
        size: VGCameraSize(3840, 2160),
        streamUseCaseName: 'VIDEO_RECORD',
      );

      expect(surfaceA, equals(surfaceB));
      expect(surfaceA.hashCode, equals(surfaceB.hashCode));
      expect(identical(surfaceA, surfaceA), isTrue);
    });

    test('toString returns readable string representation', () {
      const surface = VGCamera2SessionSurfacePlan(
        cameraId: '1',
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: VGCameraSize(1280, 720),
        streamUseCaseName: 'PREVIEW',
      );

      expect(surface.toString(), contains('cameraId: 1'));
      expect(
        surface.toString(),
        contains('role: VGCamera2SessionSurfaceRole.preview'),
      );
      expect(surface.toString(), contains('formatName: PRIVATE'));
      expect(surface.toString(), contains('streamUseCaseName: PREVIEW'));
    });

    test('inequality when any surface field differs', () {
      const base = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: VGCameraSize(1920, 1080),
        streamUseCaseName: 'PREVIEW',
      );

      const diffId = VGCamera2SessionSurfacePlan(
        cameraId: '1',
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: VGCameraSize(1920, 1080),
        streamUseCaseName: 'PREVIEW',
      );
      expect(base, isNot(equals(diffId)));

      const diffRole = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.videoRecord,
        formatName: 'PRIVATE',
        size: VGCameraSize(1920, 1080),
        streamUseCaseName: 'PREVIEW',
      );
      expect(base, isNot(equals(diffRole)));

      const diffFormat = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'YUV_420_888',
        size: VGCameraSize(1920, 1080),
        streamUseCaseName: 'PREVIEW',
      );
      expect(base, isNot(equals(diffFormat)));

      const diffSize = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: VGCameraSize(1280, 720),
        streamUseCaseName: 'PREVIEW',
      );
      expect(base, isNot(equals(diffSize)));

      const diffUseCase = VGCamera2SessionSurfacePlan(
        cameraId: '0',
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: VGCameraSize(1920, 1080),
        streamUseCaseName: 'STILL_CAPTURE',
      );
      expect(base, isNot(equals(diffUseCase)));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGCamera2SessionConfigurationPlan Contract
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2SessionConfigurationPlan value semantics and serialization', () {
    test('getters reflect decision correctly', () {
      const blockedPlan = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.blocked,
        reasons: <String>['no_camera_available'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>[],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{},
      );
      expect(blockedPlan.isBlocked, isTrue);
      expect(blockedPlan.usesSingleCameraFallback, isFalse);
      expect(blockedPlan.isConcurrentValidationCandidate, isFalse);

      const singlePlan = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['no_secondary_camera'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[
          VGCamera2SessionSurfacePlan(
            cameraId: '0',
            role: VGCamera2SessionSurfaceRole.preview,
            formatName: 'PRIVATE',
            size: VGCameraSize(1920, 1080),
            streamUseCaseName: 'PREVIEW',
          ),
        ],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{},
      );
      expect(singlePlan.isBlocked, isFalse);
      expect(singlePlan.usesSingleCameraFallback, isTrue);
      expect(singlePlan.isConcurrentValidationCandidate, isFalse);

      const concurrentPlan = VGCamera2SessionConfigurationPlan(
        decision:
            VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
        reasons: <String>[],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['0', '1'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: true,
        diagnostics: <String, Object?>{},
      );
      expect(concurrentPlan.isBlocked, isFalse);
      expect(concurrentPlan.usesSingleCameraFallback, isFalse);
      expect(concurrentPlan.isConcurrentValidationCandidate, isTrue);
    });

    test('toMap produces full serialized map structure', () {
      const plan = VGCamera2SessionConfigurationPlan(
        decision:
            VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
        reasons: <String>['camera_permission_required_for_runtime_validation'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[
          VGCamera2SessionSurfacePlan(
            cameraId: '0',
            role: VGCamera2SessionSurfaceRole.preview,
            formatName: 'PRIVATE',
            size: VGCameraSize(1920, 1080),
            streamUseCaseName: 'PREVIEW',
          ),
        ],
        selectedConcurrentCameraIds: <String>['0', '1'],
        requiresCameraPermission: true,
        requiresRuntimeSessionValidation: true,
        diagnostics: <String, Object?>{
          'cameraCount': 2,
          'supportsConcurrentCamera': true,
        },
      );

      final map = plan.toMap();
      expect(map['decision'], equals('concurrentValidationCandidate'));
      expect(
        map['reasons'],
        equals(['camera_permission_required_for_runtime_validation']),
      );
      expect(map['surfacePlans'], isList);
      final surfaces = map['surfacePlans'] as List;
      expect(surfaces.length, equals(1));
      expect(surfaces.first['cameraId'], equals('0'));
      expect(map['selectedConcurrentCameraIds'], equals(['0', '1']));
      expect(map['requiresCameraPermission'], isTrue);
      expect(map['requiresRuntimeSessionValidation'], isTrue);
      expect(
        map['diagnostics'],
        equals({'cameraCount': 2, 'supportsConcurrentCamera': true}),
      );
    });

    test('equality and hashCode compare all plan fields', () {
      const planA = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['camera_permission_absent'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[
          VGCamera2SessionSurfacePlan(
            cameraId: '0',
            role: VGCamera2SessionSurfaceRole.preview,
            formatName: 'PRIVATE',
            size: VGCameraSize(1920, 1080),
            streamUseCaseName: 'PREVIEW',
          ),
        ],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: true,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'cameraCount': 1},
      );

      const planB = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['camera_permission_absent'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[
          VGCamera2SessionSurfacePlan(
            cameraId: '0',
            role: VGCamera2SessionSurfaceRole.preview,
            formatName: 'PRIVATE',
            size: VGCameraSize(1920, 1080),
            streamUseCaseName: 'PREVIEW',
          ),
        ],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: true,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'cameraCount': 1},
      );

      expect(planA, equals(planB));
      expect(planA.hashCode, equals(planB.hashCode));
      expect(
        planA.toString(),
        contains(
          'decision: VGCamera2SessionConfigurationDecision.singleCameraFallback',
        ),
      );
    });

    test(
      'stable diagnostics hash produces equal hash and equality with different map key insertion order',
      () {
        final diag1 = <String, Object?>{
          'a_first': 10,
          'b_second': 'hello',
          'c_third': true,
        };

        final diag2 = <String, Object?>{
          'c_third': true,
          'a_first': 10,
          'b_second': 'hello',
        };

        final plan1 = VGCamera2SessionConfigurationPlan(
          decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
          reasons: const <String>['r1'],
          surfacePlans: const <VGCamera2SessionSurfacePlan>[],
          selectedConcurrentCameraIds: const <String>['0'],
          requiresCameraPermission: false,
          requiresRuntimeSessionValidation: false,
          diagnostics: diag1,
        );

        final plan2 = VGCamera2SessionConfigurationPlan(
          decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
          reasons: const <String>['r1'],
          surfacePlans: const <VGCamera2SessionSurfacePlan>[],
          selectedConcurrentCameraIds: const <String>['0'],
          requiresCameraPermission: false,
          requiresRuntimeSessionValidation: false,
          diagnostics: diag2,
        );

        expect(plan1, equals(plan2));
        expect(plan1.hashCode, equals(plan2.hashCode));
      },
    );

    test('inequality when any plan field differs', () {
      const base = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['r1'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'k': 'v'},
      );

      const diffDecision = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.blocked,
        reasons: <String>['r1'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'k': 'v'},
      );
      expect(base, isNot(equals(diffDecision)));

      const diffReasons = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['r2'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'k': 'v'},
      );
      expect(base, isNot(equals(diffReasons)));

      const diffSurfaces = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['r1'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[
          VGCamera2SessionSurfacePlan(
            cameraId: '0',
            role: VGCamera2SessionSurfaceRole.preview,
            formatName: 'PRIVATE',
            size: VGCameraSize(1920, 1080),
            streamUseCaseName: 'PREVIEW',
          ),
        ],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'k': 'v'},
      );
      expect(base, isNot(equals(diffSurfaces)));

      const diffCameraIds = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['r1'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['1'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'k': 'v'},
      );
      expect(base, isNot(equals(diffCameraIds)));

      const diffPermission = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['r1'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: true,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'k': 'v'},
      );
      expect(base, isNot(equals(diffPermission)));

      const diffValidation = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['r1'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: true,
        diagnostics: <String, Object?>{'k': 'v'},
      );
      expect(base, isNot(equals(diffValidation)));

      const diffDiagnostics = VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: <String>['r1'],
        surfacePlans: <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: <String>['0'],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{'k': 'diff_v'},
      );
      expect(base, isNot(equals(diffDiagnostics)));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Planner Case 1: No Camera Report
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 1: No camera report', () {
    test(
      'blocked, no permission requirement, zero surfaces, no_camera_available reason',
      () {
        final report = makeReport(
          cameraCount: 0,
          cameras: const <VGCameraHardwareDeviceCapability>[],
        );

        final plan = planner.evaluate(report: report);

        expect(
          plan.decision,
          equals(VGCamera2SessionConfigurationDecision.blocked),
        );
        expect(plan.isBlocked, isTrue);
        expect(plan.usesSingleCameraFallback, isFalse);
        expect(plan.isConcurrentValidationCandidate, isFalse);
        expect(plan.requiresCameraPermission, isFalse);
        expect(plan.requiresRuntimeSessionValidation, isFalse);
        expect(plan.surfacePlans, isEmpty);
        expect(plan.selectedConcurrentCameraIds, isEmpty);
        expect(plan.reasons, contains('no_camera_available'));
        expect(plan.diagnostics['cameraCount'], equals(0));
        expect(plan.diagnostics['surfacePlanCount'], equals(0));
        expect(plan.diagnostics['readinessDecision'], equals('noCamera'));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Planner Case 2: Severe/Critical Thermal Readiness
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 2: Severe/critical thermal readiness', () {
    test('blocked, no runtime validation for severe thermal status', () {
      final backCam = makeCamera(id: '0', lensFacing: 'back');
      final report = makeReport(
        thermalStatusName: 'severe',
        thermalStatus: 3,
        cameras: [backCam],
      );

      final plan = planner.evaluate(report: report);

      expect(
        plan.decision,
        equals(VGCamera2SessionConfigurationDecision.blocked),
      );
      expect(plan.isBlocked, isTrue);
      expect(plan.requiresRuntimeSessionValidation, isFalse);
      expect(plan.requiresCameraPermission, isFalse);
      expect(plan.surfacePlans, isEmpty);
      expect(plan.selectedConcurrentCameraIds, isEmpty);
      expect(plan.reasons, contains('thermal_blocked'));
      expect(plan.diagnostics['readinessDecision'], equals('thermalBlocked'));
    });

    test('blocked for critical thermal status', () {
      final backCam = makeCamera(id: '0', lensFacing: 'back');
      final report = makeReport(
        thermalStatusName: 'critical',
        thermalStatus: 4,
        cameras: [backCam],
      );

      final plan = planner.evaluate(report: report);

      expect(
        plan.decision,
        equals(VGCamera2SessionConfigurationDecision.blocked),
      );
      expect(plan.isBlocked, isTrue);
      expect(plan.requiresRuntimeSessionValidation, isFalse);
      expect(plan.reasons, contains('thermal_blocked'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Planner Case 3: Single Camera Fallback with hasCameraPermission=false
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 3: Single camera fallback with hasCameraPermission=false', () {
    test(
      'decision singleCameraFallback, requiresCameraPermission true, requiresRuntimeSessionValidation false, primary preview/video surfaces, single primary id, camera_permission_absent without duplication',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const [
            VGCameraSize(1920, 1080),
            VGCameraSize(1280, 720),
          ],
          videoSizes: const [
            VGCameraSize(3840, 2160),
            VGCameraSize(1920, 1080),
          ],
        );
        final report = makeReport(
          hasCameraPermission: false,
          cameras: [backCam],
          supportsConcurrentCamera: false,
        );

        final plan = planner.evaluate(report: report);

        expect(
          plan.decision,
          equals(VGCamera2SessionConfigurationDecision.singleCameraFallback),
        );
        expect(plan.usesSingleCameraFallback, isTrue);
        expect(plan.isBlocked, isFalse);
        expect(plan.isConcurrentValidationCandidate, isFalse);
        expect(plan.requiresCameraPermission, isTrue);
        expect(plan.requiresRuntimeSessionValidation, isFalse);
        expect(plan.selectedConcurrentCameraIds, equals(['0']));
        expect(plan.surfacePlans.length, equals(2));

        // Primary preview surface
        final previewSurface = plan.surfacePlans.firstWhere(
          (s) => s.role == VGCamera2SessionSurfaceRole.preview,
        );
        expect(previewSurface.cameraId, equals('0'));
        expect(previewSurface.formatName, equals('PRIVATE'));
        expect(previewSurface.size, equals(const VGCameraSize(1920, 1080)));
        expect(previewSurface.streamUseCaseName, equals('PREVIEW'));

        // Primary video surface
        final videoSurface = plan.surfacePlans.firstWhere(
          (s) => s.role == VGCamera2SessionSurfaceRole.videoRecord,
        );
        expect(videoSurface.cameraId, equals('0'));
        expect(videoSurface.formatName, equals('PRIVATE'));
        expect(videoSurface.size, equals(const VGCameraSize(3840, 2160)));
        expect(videoSurface.streamUseCaseName, equals('VIDEO_RECORD'));

        // Verify camera_permission_absent is present exactly once (no duplication)
        final permissionAbsentCount = plan.reasons
            .where((r) => r == 'camera_permission_absent')
            .length;
        expect(permissionAbsentCount, equals(1));
        expect(plan.reasons, contains('no_secondary_camera'));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Planner Case 4: Single Camera Fallback with hasCameraPermission=true
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 4: Single camera fallback with hasCameraPermission=true', () {
    test('requiresCameraPermission false, no permission reasons added', () {
      final backCam = makeCamera(
        id: '0',
        lensFacing: 'back',
        previewSizes: const [VGCameraSize(1920, 1080)],
        videoSizes: const [VGCameraSize(1920, 1080)],
      );
      final report = makeReport(
        hasCameraPermission: true,
        cameras: [backCam],
        supportsConcurrentCamera: false,
      );

      final plan = planner.evaluate(report: report);

      expect(
        plan.decision,
        equals(VGCamera2SessionConfigurationDecision.singleCameraFallback),
      );
      expect(plan.requiresCameraPermission, isFalse);
      expect(plan.requiresRuntimeSessionValidation, isFalse);
      expect(plan.reasons, isNot(contains('camera_permission_absent')));
      expect(
        plan.reasons,
        isNot(contains('camera_permission_required_for_runtime_validation')),
      );
      expect(plan.surfacePlans.length, equals(2));
      expect(plan.selectedConcurrentCameraIds, equals(['0']));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 8. Planner Case 5: Dual-Ready Synthetic Report with hasCameraPermission=false
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 5: Dual-ready synthetic report with hasCameraPermission=false', () {
    test(
      'concurrentValidationCandidate, requiresCameraPermission true, requiresRuntimeSessionValidation true, selected ids primary+secondary, four surfaces, reason camera_permission_required_for_runtime_validation',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(3840, 2160)],
        );
        final frontCam = makeCamera(
          id: '1',
          lensFacing: 'front',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(1920, 1080)],
        );
        final report = makeReport(
          hasCameraPermission: false,
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        final plan = planner.evaluate(report: report);

        expect(
          plan.decision,
          equals(
            VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
          ),
        );
        expect(plan.isConcurrentValidationCandidate, isTrue);
        expect(plan.usesSingleCameraFallback, isFalse);
        expect(plan.isBlocked, isFalse);
        expect(plan.requiresCameraPermission, isTrue);
        expect(plan.requiresRuntimeSessionValidation, isTrue);
        expect(plan.selectedConcurrentCameraIds, equals(['0', '1']));
        expect(plan.surfacePlans.length, equals(4));

        // 2 surfaces for camera '0' and 2 for camera '1'
        final cam0Surfaces = plan.surfacePlans
            .where((s) => s.cameraId == '0')
            .toList();
        final cam1Surfaces = plan.surfacePlans
            .where((s) => s.cameraId == '1')
            .toList();
        expect(cam0Surfaces.length, equals(2));
        expect(cam1Surfaces.length, equals(2));

        expect(
          cam0Surfaces.map((s) => s.role),
          containsAll([
            VGCamera2SessionSurfaceRole.preview,
            VGCamera2SessionSurfaceRole.videoRecord,
          ]),
        );
        expect(
          cam1Surfaces.map((s) => s.role),
          containsAll([
            VGCamera2SessionSurfaceRole.preview,
            VGCamera2SessionSurfaceRole.videoRecord,
          ]),
        );

        expect(plan.reasons, contains('camera_permission_absent'));
        expect(
          plan.reasons,
          contains('camera_permission_required_for_runtime_validation'),
        );
        expect(plan.diagnostics['surfacePlanCount'], equals(4));
        expect(plan.diagnostics['primaryCameraId'], equals('0'));
        expect(plan.diagnostics['secondaryCameraId'], equals('1'));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 9. Planner Case 6: Same Dual-Ready Synthetic Report with hasCameraPermission=true
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 6: Dual-ready synthetic report with hasCameraPermission=true', () {
    test(
      'concurrent candidate, requiresCameraPermission false, no permission-required reason',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(3840, 2160)],
        );
        final frontCam = makeCamera(
          id: '1',
          lensFacing: 'front',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(1920, 1080)],
        );
        final report = makeReport(
          hasCameraPermission: true,
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        final plan = planner.evaluate(report: report);

        expect(
          plan.decision,
          equals(
            VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
          ),
        );
        expect(plan.isConcurrentValidationCandidate, isTrue);
        expect(plan.requiresCameraPermission, isFalse);
        expect(plan.requiresRuntimeSessionValidation, isTrue);
        expect(plan.selectedConcurrentCameraIds, equals(['0', '1']));
        expect(plan.surfacePlans.length, equals(4));
        expect(plan.reasons, isNot(contains('camera_permission_absent')));
        expect(
          plan.reasons,
          isNot(contains('camera_permission_required_for_runtime_validation')),
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 10. Planner Case 7: Primary Preview/Video Missing
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 7: Primary preview/video missing', () {
    test(
      'blocked if no primary surface can be formed, includes primary missing reasons and requiresCameraPermission true when camera exists and permission absent',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const <VGCameraSize>[],
          videoSizes: const <VGCameraSize>[],
        );
        final report = makeReport(
          hasCameraPermission: false,
          cameras: [backCam],
          supportsConcurrentCamera: false,
        );

        final plan = planner.evaluate(report: report);

        expect(
          plan.decision,
          equals(VGCamera2SessionConfigurationDecision.blocked),
        );
        expect(plan.isBlocked, isTrue);
        expect(plan.surfacePlans, isEmpty);
        expect(plan.selectedConcurrentCameraIds, isEmpty);
        expect(plan.requiresCameraPermission, isTrue);
        expect(plan.requiresRuntimeSessionValidation, isFalse);
        expect(plan.reasons, contains('primary_preview_surface_missing'));
        expect(plan.reasons, contains('primary_video_surface_missing'));
        expect(plan.reasons, contains('camera_permission_absent'));
      },
    );

    test(
      'blocked with requiresCameraPermission false when camera exists and permission is granted',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const <VGCameraSize>[],
          videoSizes: const <VGCameraSize>[],
        );
        final report = makeReport(
          hasCameraPermission: true,
          cameras: [backCam],
          supportsConcurrentCamera: false,
        );

        final plan = planner.evaluate(report: report);

        expect(
          plan.decision,
          equals(VGCamera2SessionConfigurationDecision.blocked),
        );
        expect(plan.isBlocked, isTrue);
        expect(plan.requiresCameraPermission, isFalse);
        expect(plan.surfacePlans, isEmpty);
        expect(plan.reasons, contains('primary_preview_surface_missing'));
        expect(plan.reasons, contains('primary_video_surface_missing'));
        expect(plan.reasons, isNot(contains('camera_permission_absent')));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 11. Planner Case 8: Dual Readiness with Secondary Surface Missing
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 8: Dual readiness with secondary surface missing', () {
    test(
      'falls back to singleCameraFallback using primary surfaces and includes secondary missing reasons',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(3840, 2160)],
        );
        // Secondary camera has preview sizes but no video sizes
        final frontCam = makeCamera(
          id: '1',
          lensFacing: 'front',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const <VGCameraSize>[],
        );
        final report = makeReport(
          hasCameraPermission: true,
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        // Explicit dual readiness plan to test session planner handling of missing secondary video surface
        const explicitDualReadiness = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.dualCameraCandidate,
          reasons: <String>[],
          diagnostics: <String, Object?>{},
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
          selectedPreviewSize: VGCameraSize(1920, 1080),
          selectedVideoSize: VGCameraSize(3840, 2160),
          selectedFpsRange: VGCameraFpsRange(30, 30),
        );

        final plan = planner.evaluate(
          report: report,
          readinessPlan: explicitDualReadiness,
        );

        expect(
          plan.decision,
          equals(VGCamera2SessionConfigurationDecision.singleCameraFallback),
        );
        expect(plan.usesSingleCameraFallback, isTrue);
        expect(plan.isConcurrentValidationCandidate, isFalse);
        expect(plan.selectedConcurrentCameraIds, equals(['0']));
        // Surface plans should only contain the 2 primary surfaces
        expect(plan.surfacePlans.length, equals(2));
        expect(plan.surfacePlans.every((s) => s.cameraId == '0'), isTrue);
        expect(plan.reasons, contains('secondary_video_surface_missing'));
      },
    );

    test(
      'falls back to singleCameraFallback when secondary preview is missing',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(3840, 2160)],
        );
        final frontCam = makeCamera(
          id: '1',
          lensFacing: 'front',
          previewSizes: const <VGCameraSize>[],
          videoSizes: const [VGCameraSize(1920, 1080)],
        );
        final report = makeReport(
          hasCameraPermission: true,
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        const explicitDualReadiness = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.dualCameraCandidate,
          reasons: <String>[],
          diagnostics: <String, Object?>{},
          selectedPrimaryCameraId: '0',
          selectedSecondaryCameraId: '1',
          selectedPreviewSize: VGCameraSize(1920, 1080),
          selectedVideoSize: VGCameraSize(3840, 2160),
          selectedFpsRange: VGCameraFpsRange(30, 30),
        );

        final plan = planner.evaluate(
          report: report,
          readinessPlan: explicitDualReadiness,
        );

        expect(
          plan.decision,
          equals(VGCamera2SessionConfigurationDecision.singleCameraFallback),
        );
        expect(plan.surfacePlans.length, equals(2));
        expect(plan.reasons, contains('secondary_preview_surface_missing'));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 12. Planner Case 9: Null readinessPlan Path Computes Readiness Internally
  // ─────────────────────────────────────────────────────────────────────────
  group('Case 9: Null readinessPlan path', () {
    test(
      'computes readiness internally and matches explicit readiness behavior',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(3840, 2160)],
        );
        final frontCam = makeCamera(
          id: '1',
          lensFacing: 'front',
          previewSizes: const [VGCameraSize(1920, 1080)],
          videoSizes: const [VGCameraSize(1920, 1080)],
        );
        final report = makeReport(
          hasCameraPermission: false,
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        final planImplicit = planner.evaluate(report: report);
        final readiness = const VGCamera2ReadinessPlanner().evaluate(report);
        final planExplicit = planner.evaluate(
          report: report,
          readinessPlan: readiness,
        );

        expect(planImplicit, equals(planExplicit));
        expect(planImplicit.hashCode, equals(planExplicit.hashCode));
        expect(
          planImplicit.decision,
          equals(
            VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
          ),
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 13. Planner Case 10 & Unit D Fixture: Diagnostics Integrity
  // ─────────────────────────────────────────────────────────────────────────
  group(
    'Case 10: Diagnostics and Unit D mandatory stream combinations fixture',
    () {
      test(
        'diagnostics include cameraCount, supportsConcurrentCamera, hasCameraPermission, readinessDecision, primaryCameraId, secondaryCameraId, surfacePlanCount, mandatoryConcurrentCombinationCount, mandatoryConcurrentStreamCount',
        () {
          // Unit D mandatory stream combination fixtures: at least 1 combination and 2 streams
          final stream1 = makeStreamInfo(
            format: 34,
            formatName: 'PRIVATE',
            streamUseCase: 1,
            streamUseCaseName: 'PREVIEW',
            availableSizes: const [VGCameraSize(1920, 1080)],
          );
          final stream2 = makeStreamInfo(
            format: 34,
            formatName: 'PRIVATE',
            streamUseCase: 3,
            streamUseCaseName: 'VIDEO_RECORD',
            availableSizes: const [VGCameraSize(1920, 1080)],
          );
          final combination = makeStreamCombination(
            description: 'Mandatory concurrent combination 1',
            streams: [stream1, stream2],
          );

          final backCam = makeCamera(
            id: '0',
            lensFacing: 'back',
            previewSizes: const [VGCameraSize(1920, 1080)],
            videoSizes: const [VGCameraSize(3840, 2160)],
            mandatoryConcurrentStreamCombinations: [combination],
          );
          final frontCam = makeCamera(
            id: '1',
            lensFacing: 'front',
            previewSizes: const [VGCameraSize(1920, 1080)],
            videoSizes: const [VGCameraSize(1920, 1080)],
          );

          final report = makeReport(
            hasCameraPermission: true,
            cameras: [backCam, frontCam],
            supportsConcurrentCamera: true,
            concurrentCameraIdSets: [
              ['0', '1'],
            ],
          );

          final plan = planner.evaluate(report: report);
          final diag = plan.diagnostics;

          expect(diag['cameraCount'], equals(2));
          expect(diag['supportsConcurrentCamera'], isTrue);
          expect(diag['hasCameraPermission'], isTrue);
          expect(diag['readinessDecision'], equals('dualCameraCandidate'));
          expect(diag['primaryCameraId'], equals('0'));
          expect(diag['secondaryCameraId'], equals('1'));
          expect(diag['surfacePlanCount'], equals(4));
          expect(diag['mandatoryConcurrentCombinationCount'], equals(1));
          expect(diag['mandatoryConcurrentStreamCount'], equals(2));
        },
      );
    },
  );
}
