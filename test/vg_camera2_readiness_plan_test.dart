// vg_camera2_readiness_plan_test.dart
// vanguard_media_engine — Phase 3-Unit C: Android Camera2 readiness & fallback planner tests.

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

  const planner = VGCamera2ReadinessPlanner();

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Export & Type Verification
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlan public export and enum contract', () {
    test('VGCamera2ReadinessDecision has expected enum values', () {
      expect(
        VGCamera2ReadinessDecision.values,
        containsAll(<VGCamera2ReadinessDecision>[
          VGCamera2ReadinessDecision.noCamera,
          VGCamera2ReadinessDecision.thermalBlocked,
          VGCamera2ReadinessDecision.singleCameraOnly,
          VGCamera2ReadinessDecision.dualCameraCandidate,
        ]),
      );
      expect(VGCamera2ReadinessDecision.values.length, equals(4));
    });

    test(
      'VGCamera2ReadinessPlan convenience getters reflect decision correctly',
      () {
        const dualPlan = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.dualCameraCandidate,
          reasons: <String>[],
          diagnostics: <String, Object?>{},
        );
        expect(dualPlan.isDualCameraCandidate, isTrue);
        expect(dualPlan.isSingleCameraOnly, isFalse);
        expect(dualPlan.isBlocked, isFalse);

        const singlePlan = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.singleCameraOnly,
          reasons: <String>['no_matching_concurrent_camera_set'],
          diagnostics: <String, Object?>{},
        );
        expect(singlePlan.isDualCameraCandidate, isFalse);
        expect(singlePlan.isSingleCameraOnly, isTrue);
        expect(singlePlan.isBlocked, isFalse);

        const noCamPlan = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.noCamera,
          reasons: <String>['no_camera_available'],
          diagnostics: <String, Object?>{},
        );
        expect(noCamPlan.isDualCameraCandidate, isFalse);
        expect(noCamPlan.isSingleCameraOnly, isFalse);
        expect(noCamPlan.isBlocked, isTrue);

        const thermalPlan = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.thermalBlocked,
          reasons: <String>['thermal_blocked'],
          diagnostics: <String, Object?>{},
        );
        expect(thermalPlan.isDualCameraCandidate, isFalse);
        expect(thermalPlan.isSingleCameraOnly, isFalse);
        expect(thermalPlan.isBlocked, isTrue);
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGCamera2ReadinessPlan Value Semantics, toMap, and hashCode
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlan value semantics and serialization', () {
    test('toMap produces expected map structure with all fields', () {
      const plan = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.dualCameraCandidate,
        reasons: <String>['camera_permission_absent'],
        diagnostics: <String, Object?>{
          'cameraCount': 2,
          'supportsConcurrentCamera': true,
          'hasCameraPermission': false,
        },
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(3840, 2160),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );

      final map = plan.toMap();
      expect(map['decision'], equals('dualCameraCandidate'));
      expect(map['reasons'], equals(['camera_permission_absent']));
      expect(
        map['diagnostics'],
        equals({
          'cameraCount': 2,
          'supportsConcurrentCamera': true,
          'hasCameraPermission': false,
        }),
      );
      expect(map['selectedPrimaryCameraId'], equals('0'));
      expect(map['selectedSecondaryCameraId'], equals('1'));
      expect(
        map['selectedPreviewSize'],
        equals({'width': 1920, 'height': 1080}),
      );
      expect(map['selectedVideoSize'], equals({'width': 3840, 'height': 2160}));
      expect(map['selectedFpsRange'], equals({'lower': 30, 'upper': 30}));
    });

    test(
      'toMap produces expected map structure when optional stream fields are null',
      () {
        const plan = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.noCamera,
          reasons: <String>['no_camera_available'],
          diagnostics: <String, Object?>{'cameraCount': 0},
        );

        final map = plan.toMap();
        expect(map['decision'], equals('noCamera'));
        expect(map['reasons'], equals(['no_camera_available']));
        expect(map['diagnostics'], equals({'cameraCount': 0}));
        expect(map['selectedPrimaryCameraId'], isNull);
        expect(map['selectedSecondaryCameraId'], isNull);
        expect(map['selectedPreviewSize'], isNull);
        expect(map['selectedVideoSize'], isNull);
        expect(map['selectedFpsRange'], isNull);
      },
    );

    test('equality and hashCode compare field values identically', () {
      const a = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>[
          'camera_permission_absent',
          'no_matching_concurrent_camera_set',
        ],
        diagnostics: <String, Object?>{
          'cameraCount': 2,
          'supportsConcurrentCamera': false,
        },
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );

      const b = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>[
          'camera_permission_absent',
          'no_matching_concurrent_camera_set',
        ],
        diagnostics: <String, Object?>{
          'cameraCount': 2,
          'supportsConcurrentCamera': false,
        },
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a.toString(),
        contains('decision: VGCamera2ReadinessDecision.singleCameraOnly'),
      );
      expect(a.toString(), contains('selectedPrimaryCameraId: 0'));
    });

    test(
      'equal diagnostics maps with different insertion order produce equal hashCode and equality',
      () {
        final diag1 = <String, Object?>{
          'alpha': 1,
          'beta': 'two',
          'gamma': true,
        };

        final diag2 = <String, Object?>{
          'gamma': true,
          'alpha': 1,
          'beta': 'two',
        };

        final plan1 = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.singleCameraOnly,
          reasons: const <String>['reason_1'],
          diagnostics: diag1,
          selectedPrimaryCameraId: '0',
        );

        final plan2 = VGCamera2ReadinessPlan(
          decision: VGCamera2ReadinessDecision.singleCameraOnly,
          reasons: const <String>['reason_1'],
          diagnostics: diag2,
          selectedPrimaryCameraId: '0',
        );

        expect(plan1, equals(plan2));
        expect(plan1.hashCode, equals(plan2.hashCode));
      },
    );

    test('inequality when any property differs', () {
      const base = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );

      const diffDecision = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.dualCameraCandidate,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );
      expect(base, isNot(equals(diffDecision)));

      const diffReasons = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_b'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );
      expect(base, isNot(equals(diffReasons)));

      const diffDiagnostics = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'diff_val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );
      expect(base, isNot(equals(diffDiagnostics)));

      const diffPrimary = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '2',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );
      expect(base, isNot(equals(diffPrimary)));

      const diffSecondary = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '2',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );
      expect(base, isNot(equals(diffSecondary)));

      const diffPreviewSize = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1280, 720),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );
      expect(base, isNot(equals(diffPreviewSize)));

      const diffVideoSize = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1280, 720),
        selectedFpsRange: VGCameraFpsRange(30, 30),
      );
      expect(base, isNot(equals(diffVideoSize)));

      const diffFpsRange = VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.singleCameraOnly,
        reasons: <String>['reason_a'],
        diagnostics: <String, Object?>{'key': 'val'},
        selectedPrimaryCameraId: '0',
        selectedSecondaryCameraId: '1',
        selectedPreviewSize: VGCameraSize(1920, 1080),
        selectedVideoSize: VGCameraSize(1920, 1080),
        selectedFpsRange: VGCameraFpsRange(15, 30),
      );
      expect(base, isNot(equals(diffFpsRange)));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGCamera2ReadinessPlanner Decision Logic Tests
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlanner decision logic', () {
    test('noCamera decision when cameraCount is 0', () {
      final report = makeReport(
        cameraCount: 0,
        cameras: const <VGCameraHardwareDeviceCapability>[],
      );

      final plan = planner.evaluate(report);

      expect(plan.decision, equals(VGCamera2ReadinessDecision.noCamera));
      expect(plan.isBlocked, isTrue);
      expect(plan.reasons, contains('no_camera_available'));
      expect(plan.selectedPrimaryCameraId, isNull);
      expect(plan.selectedSecondaryCameraId, isNull);
      expect(plan.selectedPreviewSize, isNull);
      expect(plan.selectedVideoSize, isNull);
      expect(plan.selectedFpsRange, isNull);
      expect(plan.diagnostics['cameraCount'], equals(0));
      expect(plan.diagnostics['concurrentSetMatched'], isFalse);
    });

    test(
      'noCamera decision when cameras list is empty even if cameraCount > 0',
      () {
        final report = makeReport(
          cameraCount: 1,
          cameras: const <VGCameraHardwareDeviceCapability>[],
        );

        final plan = planner.evaluate(report);

        expect(plan.decision, equals(VGCamera2ReadinessDecision.noCamera));
        expect(plan.isBlocked, isTrue);
        expect(plan.reasons, contains('no_camera_available'));
      },
    );

    test('thermalBlocked decision for all severe thermalStatusName tokens', () {
      final severeNames = ['severe', 'critical', 'emergency', 'shutdown'];
      final backCam = makeCamera(id: '0', lensFacing: 'back');

      for (final name in severeNames) {
        final report = makeReport(
          thermalStatusName: name,
          thermalStatus: 0,
          cameras: [backCam],
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.thermalBlocked),
          reason: 'Expected thermalBlocked for thermalStatusName=$name',
        );
        expect(plan.isBlocked, isTrue);
        expect(plan.reasons, contains('thermal_blocked'));
        expect(plan.selectedPrimaryCameraId, isNull);
        expect(plan.selectedPreviewSize, isNull);
        expect(plan.diagnostics['thermalStatusName'], equals(name));
      }
    });

    test(
      'thermalBlocked decision when thermalStatus >= 3 even with nominal thermalStatusName',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');

        for (final status in [3, 4, 5]) {
          final report = makeReport(
            thermalStatusName: 'none',
            thermalStatus: status,
            cameras: [backCam],
          );

          final plan = planner.evaluate(report);

          expect(
            plan.decision,
            equals(VGCamera2ReadinessDecision.thermalBlocked),
            reason: 'Expected thermalBlocked for thermalStatus=$status',
          );
          expect(plan.isBlocked, isTrue);
          expect(plan.reasons, contains('thermal_blocked'));
        }
      },
    );

    test('nominal/moderate thermal status does not block evaluation', () {
      final backCam = makeCamera(id: '0', lensFacing: 'back');
      final nonSevere = ['none', 'light', 'moderate', 'unavailable'];

      for (final name in nonSevere) {
        final report = makeReport(
          thermalStatusName: name,
          thermalStatus: 1,
          cameras: [backCam],
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
          reason:
              'Expected singleCameraOnly (not blocked) for thermalStatusName=$name',
        );
        expect(plan.isBlocked, isFalse);
        expect(plan.reasons, isNot(contains('thermal_blocked')));
      }
    });

    test(
      'missing camera permission adds camera_permission_absent reason but does not hard block',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final report = makeReport(
          hasCameraPermission: false,
          cameras: [backCam],
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(plan.isBlocked, isFalse);
        expect(plan.reasons, contains('camera_permission_absent'));
        expect(plan.selectedPrimaryCameraId, equals('0'));
      },
    );

    test(
      'granted camera permission does not add camera_permission_absent reason',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final report = makeReport(
          hasCameraPermission: true,
          cameras: [backCam],
        );

        final plan = planner.evaluate(report);

        expect(plan.reasons, isNot(contains('camera_permission_absent')));
      },
    );

    test('singleCameraOnly decision when only one camera exists', () {
      final backCam = makeCamera(id: '0', lensFacing: 'back');
      final report = makeReport(
        cameras: [backCam],
        supportsConcurrentCamera: false,
      );

      final plan = planner.evaluate(report);

      expect(
        plan.decision,
        equals(VGCamera2ReadinessDecision.singleCameraOnly),
      );
      expect(plan.isSingleCameraOnly, isTrue);
      expect(plan.isDualCameraCandidate, isFalse);
      expect(plan.selectedPrimaryCameraId, equals('0'));
      expect(plan.selectedSecondaryCameraId, isNull);
      expect(plan.reasons, contains('no_secondary_camera'));
      expect(plan.diagnostics['secondaryLensFacing'], isNull);
    });

    test(
      'singleCameraOnly decision when two cameras exist but concurrent set does not match',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['2', '3'],
          ],
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(plan.isSingleCameraOnly, isTrue);
        expect(plan.isDualCameraCandidate, isFalse);
        expect(plan.selectedPrimaryCameraId, equals('0'));
        expect(plan.selectedSecondaryCameraId, equals('1'));
        expect(plan.reasons, contains('no_matching_concurrent_camera_set'));
        expect(plan.diagnostics['concurrentSetMatched'], isFalse);
      },
    );

    test(
      'singleCameraOnly decision when supportsConcurrentCamera is false even with matching sets',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: false,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(plan.isSingleCameraOnly, isTrue);
        expect(plan.isDualCameraCandidate, isFalse);
        expect(plan.diagnostics['concurrentSetMatched'], isTrue);
      },
    );

    test(
      'singleCameraOnly decision when primary camera has missing preview sizes',
      () {
        final backCam = makeCamera(
          id: '0',
          lensFacing: 'back',
          previewSizes: const <VGCameraSize>[],
        );
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(plan.reasons, contains('primary_stream_config_missing'));
        expect(plan.selectedPreviewSize, isNull);
      },
    );

    test(
      'singleCameraOnly decision when secondary camera has missing video sizes',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(
          id: '1',
          lensFacing: 'front',
          videoSizes: const <VGCameraSize>[],
        );
        final report = makeReport(
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.singleCameraOnly),
        );
        expect(plan.reasons, contains('secondary_stream_config_missing'));
      },
    );

    test('dualCameraCandidate happy path when all conditions are met', () {
      final backCam = makeCamera(
        id: '0',
        lensFacing: 'back',
        previewSizes: const [VGCameraSize(1920, 1080), VGCameraSize(1280, 720)],
        videoSizes: const [VGCameraSize(3840, 2160), VGCameraSize(1920, 1080)],
        fpsRanges: const [VGCameraFpsRange(15, 30), VGCameraFpsRange(30, 30)],
      );
      final frontCam = makeCamera(
        id: '1',
        lensFacing: 'front',
        previewSizes: const [VGCameraSize(1920, 1080)],
        videoSizes: const [VGCameraSize(1920, 1080)],
        fpsRanges: const [VGCameraFpsRange(30, 30)],
      );
      final report = makeReport(
        cameras: [backCam, frontCam],
        supportsConcurrentCamera: true,
        concurrentCameraIdSets: [
          ['0', '1'],
        ],
        hasCameraPermission: true,
      );

      final plan = planner.evaluate(report);

      expect(
        plan.decision,
        equals(VGCamera2ReadinessDecision.dualCameraCandidate),
      );
      expect(plan.isDualCameraCandidate, isTrue);
      expect(plan.isSingleCameraOnly, isFalse);
      expect(plan.isBlocked, isFalse);
      expect(plan.reasons, isEmpty);
      expect(plan.selectedPrimaryCameraId, equals('0'));
      expect(plan.selectedSecondaryCameraId, equals('1'));
      expect(plan.selectedPreviewSize, equals(const VGCameraSize(1920, 1080)));
      expect(plan.selectedVideoSize, equals(const VGCameraSize(3840, 2160)));
      expect(plan.selectedFpsRange, equals(const VGCameraFpsRange(30, 30)));
      expect(plan.diagnostics['concurrentSetMatched'], isTrue);
      expect(plan.diagnostics['primaryLensFacing'], equals('back'));
      expect(plan.diagnostics['secondaryLensFacing'], equals('front'));
      expect(plan.diagnostics['primaryPreviewSizeCount'], equals(2));
      expect(plan.diagnostics['primaryVideoSizeCount'], equals(2));
      expect(plan.diagnostics['primaryFpsRangeCount'], equals(2));
    });

    test(
      'dualCameraCandidate happy path even when camera permission is absent',
      () {
        final backCam = makeCamera(id: '0', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(
          cameras: [backCam, frontCam],
          supportsConcurrentCamera: true,
          concurrentCameraIdSets: [
            ['0', '1'],
          ],
          hasCameraPermission: false,
        );

        final plan = planner.evaluate(report);

        expect(
          plan.decision,
          equals(VGCamera2ReadinessDecision.dualCameraCandidate),
        );
        expect(plan.isDualCameraCandidate, isTrue);
        expect(plan.reasons, equals(['camera_permission_absent']));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Primary and Secondary Camera Selection Policy
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlanner camera selection policy', () {
    test('primary selection prefers back camera over front camera', () {
      final frontCam = makeCamera(id: '1', lensFacing: 'front');
      final backCam = makeCamera(id: '0', lensFacing: 'back');
      // Front camera appears first in list
      final report = makeReport(cameras: [frontCam, backCam]);

      final plan = planner.evaluate(report);

      expect(plan.selectedPrimaryCameraId, equals('0'));
      expect(plan.selectedSecondaryCameraId, equals('1'));
    });

    test(
      'primary selection falls back to first camera when no back camera is present',
      () {
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final extCam = makeCamera(id: '2', lensFacing: 'external');
        final report = makeReport(cameras: [frontCam, extCam]);

        final plan = planner.evaluate(report);

        expect(plan.selectedPrimaryCameraId, equals('1'));
        expect(plan.selectedSecondaryCameraId, equals('2'));
      },
    );

    test(
      'secondary selection prefers front camera over other back/external cameras',
      () {
        final backCam1 = makeCamera(id: '0', lensFacing: 'back');
        final backCam2 = makeCamera(id: '2', lensFacing: 'back');
        final frontCam = makeCamera(id: '1', lensFacing: 'front');
        final report = makeReport(cameras: [backCam1, backCam2, frontCam]);

        final plan = planner.evaluate(report);

        expect(plan.selectedPrimaryCameraId, equals('0'));
        expect(plan.selectedSecondaryCameraId, equals('1'));
      },
    );

    test(
      'secondary selection falls back to remaining camera when no front camera is present',
      () {
        final backCam1 = makeCamera(id: '0', lensFacing: 'back');
        final backCam2 = makeCamera(id: '2', lensFacing: 'back');
        final report = makeReport(cameras: [backCam1, backCam2]);

        final plan = planner.evaluate(report);

        expect(plan.selectedPrimaryCameraId, equals('0'));
        expect(plan.selectedSecondaryCameraId, equals('2'));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. FPS Range Selection Algorithm
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ReadinessPlanner FPS range selection policy', () {
    test('selects range with highest upper FPS', () {
      final cam = makeCamera(
        id: '0',
        lensFacing: 'back',
        fpsRanges: const [
          VGCameraFpsRange(15, 30),
          VGCameraFpsRange(30, 60),
          VGCameraFpsRange(15, 15),
        ],
      );
      final report = makeReport(cameras: [cam]);

      final plan = planner.evaluate(report);

      expect(plan.selectedFpsRange, equals(const VGCameraFpsRange(30, 60)));
    });

    test('breaks upper FPS tie by selecting highest lower FPS', () {
      final cam = makeCamera(
        id: '0',
        lensFacing: 'back',
        fpsRanges: const [
          VGCameraFpsRange(15, 30),
          VGCameraFpsRange(30, 30),
          VGCameraFpsRange(10, 30),
        ],
      );
      final report = makeReport(cameras: [cam]);

      final plan = planner.evaluate(report);

      expect(plan.selectedFpsRange, equals(const VGCameraFpsRange(30, 30)));
    });

    test('handles single FPS range or empty FPS ranges gracefully', () {
      final singleRangeCam = makeCamera(
        id: '0',
        lensFacing: 'back',
        fpsRanges: const [VGCameraFpsRange(24, 24)],
      );
      final planSingle = planner.evaluate(
        makeReport(cameras: [singleRangeCam]),
      );
      expect(
        planSingle.selectedFpsRange,
        equals(const VGCameraFpsRange(24, 24)),
      );

      final emptyRangeCam = makeCamera(
        id: '0',
        lensFacing: 'back',
        fpsRanges: const <VGCameraFpsRange>[],
      );
      final planEmpty = planner.evaluate(makeReport(cameras: [emptyRangeCam]));
      expect(planEmpty.selectedFpsRange, isNull);
    });
  });
}
