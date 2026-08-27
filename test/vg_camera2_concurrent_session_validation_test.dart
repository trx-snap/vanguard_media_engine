// vg_camera2_concurrent_session_validation_test.dart
// vanguard_media_engine — Phase 3-Unit F: Android Camera2 guarded concurrent
// SessionConfiguration validation Dart model & MethodChannel contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  // Helper fixture: builds a dual-camera 4-surface session configuration plan
  VGCamera2SessionConfigurationPlan makeDualCameraSessionPlanFixture({
    String primaryCameraId = '0',
    String secondaryCameraId = '1',
  }) {
    final surfacePlans = <VGCamera2SessionSurfacePlan>[
      VGCamera2SessionSurfacePlan(
        cameraId: primaryCameraId,
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: const VGCameraSize(1920, 1080),
        streamUseCaseName: 'PREVIEW',
      ),
      VGCamera2SessionSurfacePlan(
        cameraId: primaryCameraId,
        role: VGCamera2SessionSurfaceRole.videoRecord,
        formatName: 'PRIVATE',
        size: const VGCameraSize(3840, 2160),
        streamUseCaseName: 'VIDEO_RECORD',
      ),
      VGCamera2SessionSurfacePlan(
        cameraId: secondaryCameraId,
        role: VGCamera2SessionSurfaceRole.preview,
        formatName: 'PRIVATE',
        size: const VGCameraSize(1920, 1080),
        streamUseCaseName: 'PREVIEW',
      ),
      VGCamera2SessionSurfacePlan(
        cameraId: secondaryCameraId,
        role: VGCamera2SessionSurfaceRole.videoRecord,
        formatName: 'PRIVATE',
        size: const VGCameraSize(1920, 1080),
        streamUseCaseName: 'VIDEO_RECORD',
      ),
    ];

    return VGCamera2SessionConfigurationPlan(
      decision:
          VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
      reasons: const <String>[
        'camera_permission_required_for_runtime_validation',
      ],
      surfacePlans: surfacePlans,
      selectedConcurrentCameraIds: <String>[primaryCameraId, secondaryCameraId],
      requiresCameraPermission: true,
      requiresRuntimeSessionValidation: true,
      diagnostics: const <String, Object?>{
        'cameraCount': 2,
        'supportsConcurrentCamera': true,
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Decision Enum and fromRaw Verification
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ConcurrentSessionValidationDecision enum & fromRaw', () {
    test('enum has exact expected values in order', () {
      expect(
        VGCamera2ConcurrentSessionValidationDecision.values,
        orderedEquals(<VGCamera2ConcurrentSessionValidationDecision>[
          VGCamera2ConcurrentSessionValidationDecision.unsupportedApi,
          VGCamera2ConcurrentSessionValidationDecision.permissionRequired,
          VGCamera2ConcurrentSessionValidationDecision.notCandidate,
          VGCamera2ConcurrentSessionValidationDecision.supported,
          VGCamera2ConcurrentSessionValidationDecision.notSupported,
          VGCamera2ConcurrentSessionValidationDecision.validationFailed,
        ]),
      );
      expect(
        VGCamera2ConcurrentSessionValidationDecision.values.length,
        equals(6),
      );
    });

    test('fromRaw maps known valid decision strings', () {
      expect(
        VGCamera2ConcurrentSessionValidationDecision.fromRaw('unsupportedApi'),
        equals(VGCamera2ConcurrentSessionValidationDecision.unsupportedApi),
      );
      expect(
        VGCamera2ConcurrentSessionValidationDecision.fromRaw(
          'permissionRequired',
        ),
        equals(VGCamera2ConcurrentSessionValidationDecision.permissionRequired),
      );
      expect(
        VGCamera2ConcurrentSessionValidationDecision.fromRaw('notCandidate'),
        equals(VGCamera2ConcurrentSessionValidationDecision.notCandidate),
      );
      expect(
        VGCamera2ConcurrentSessionValidationDecision.fromRaw('supported'),
        equals(VGCamera2ConcurrentSessionValidationDecision.supported),
      );
      expect(
        VGCamera2ConcurrentSessionValidationDecision.fromRaw('notSupported'),
        equals(VGCamera2ConcurrentSessionValidationDecision.notSupported),
      );
      expect(
        VGCamera2ConcurrentSessionValidationDecision.fromRaw(
          'validationFailed',
        ),
        equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
      );
    });

    test(
      'fromRaw falls back to validationFailed for unknown, non-string, or null values',
      () {
        expect(
          VGCamera2ConcurrentSessionValidationDecision.fromRaw(
            'completely_unknown',
          ),
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(
          VGCamera2ConcurrentSessionValidationDecision.fromRaw(''),
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(
          VGCamera2ConcurrentSessionValidationDecision.fromRaw(null),
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(
          VGCamera2ConcurrentSessionValidationDecision.fromRaw(123),
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(
          VGCamera2ConcurrentSessionValidationDecision.fromRaw(true),
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(
          VGCamera2ConcurrentSessionValidationDecision.fromRaw(
            const <String>[],
          ),
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(
          VGCamera2ConcurrentSessionValidationDecision.fromRaw(
            const <String, Object?>{},
          ),
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Report fromMap and toMap for all decision outcomes & malformed inputs
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ConcurrentSessionValidationReport fromMap and toMap', () {
    test('supported decision report parses and serializes cleanly', () {
      final rawMap = <String, Object?>{
        'success': true,
        'apiLevel': 35,
        'hasCameraPermission': true,
        'attemptedRuntimeValidation': true,
        'supported': true,
        'decision': 'supported',
        'reasons': <String>[],
        'selectedConcurrentCameraIds': <String>['0', '1'],
        'surfacePlanCount': 4,
        'diagnostics': <String, Object?>{'validationMode': 'deferred_output'},
      };

      final report = VGCamera2ConcurrentSessionValidationReport.fromMap(rawMap);
      expect(report.success, isTrue);
      expect(report.apiLevel, equals(35));
      expect(report.hasCameraPermission, isTrue);
      expect(report.attemptedRuntimeValidation, isTrue);
      expect(report.supported, isTrue);
      expect(
        report.decision,
        equals(VGCamera2ConcurrentSessionValidationDecision.supported),
      );
      expect(report.reasons, isEmpty);
      expect(report.selectedConcurrentCameraIds, equals(['0', '1']));
      expect(report.surfacePlanCount, equals(4));
      expect(report.diagnostics, equals({'validationMode': 'deferred_output'}));

      expect(report.isPermissionRequired, isFalse);
      expect(report.isRuntimeSupported, isTrue);
      expect(report.isRuntimeRejected, isFalse);
      expect(report.isRuntimeValidationAttempted, isTrue);

      final serialized = report.toMap();
      expect(serialized['success'], isTrue);
      expect(serialized['apiLevel'], equals(35));
      expect(serialized['hasCameraPermission'], isTrue);
      expect(serialized['attemptedRuntimeValidation'], isTrue);
      expect(serialized['supported'], isTrue);
      expect(serialized['decision'], equals('supported'));
      expect(serialized['reasons'], isEmpty);
      expect(serialized['selectedConcurrentCameraIds'], equals(['0', '1']));
      expect(serialized['surfacePlanCount'], equals(4));
      expect(
        serialized['diagnostics'],
        equals({'validationMode': 'deferred_output'}),
      );

      final roundTrip = VGCamera2ConcurrentSessionValidationReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('notSupported decision report parses and serializes cleanly', () {
      final rawMap = <String, Object?>{
        'success': true,
        'apiLevel': 35,
        'hasCameraPermission': true,
        'attemptedRuntimeValidation': true,
        'supported': false,
        'decision': 'notSupported',
        'reasons': <String>[],
        'selectedConcurrentCameraIds': <String>['0', '1'],
        'surfacePlanCount': 4,
        'diagnostics': <String, Object?>{},
      };

      final report = VGCamera2ConcurrentSessionValidationReport.fromMap(rawMap);
      expect(report.success, isTrue);
      expect(report.apiLevel, equals(35));
      expect(report.hasCameraPermission, isTrue);
      expect(report.attemptedRuntimeValidation, isTrue);
      expect(report.supported, isFalse);
      expect(
        report.decision,
        equals(VGCamera2ConcurrentSessionValidationDecision.notSupported),
      );
      expect(report.reasons, isEmpty);
      expect(report.selectedConcurrentCameraIds, equals(['0', '1']));
      expect(report.surfacePlanCount, equals(4));
      expect(report.diagnostics, isEmpty);

      expect(report.isPermissionRequired, isFalse);
      expect(report.isRuntimeSupported, isFalse);
      expect(report.isRuntimeRejected, isTrue);
      expect(report.isRuntimeValidationAttempted, isTrue);

      final serialized = report.toMap();
      expect(serialized['decision'], equals('notSupported'));
      expect(serialized['supported'], isFalse);
      expect(
        VGCamera2ConcurrentSessionValidationReport.fromMap(serialized),
        equals(report),
      );
    });

    test(
      'permissionRequired decision report parses and serializes cleanly',
      () {
        final rawMap = <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': false,
          'attemptedRuntimeValidation': false,
          'supported': false,
          'decision': 'permissionRequired',
          'reasons': <String>['camera_permission_absent'],
          'selectedConcurrentCameraIds': <String>['0'],
          'surfacePlanCount': 2,
          'diagnostics': <String, Object?>{},
        };

        final report = VGCamera2ConcurrentSessionValidationReport.fromMap(
          rawMap,
        );
        expect(report.success, isTrue);
        expect(report.apiLevel, equals(34));
        expect(report.hasCameraPermission, isFalse);
        expect(report.attemptedRuntimeValidation, isFalse);
        expect(report.supported, isFalse);
        expect(
          report.decision,
          equals(
            VGCamera2ConcurrentSessionValidationDecision.permissionRequired,
          ),
        );
        expect(report.reasons, equals(['camera_permission_absent']));
        expect(report.selectedConcurrentCameraIds, equals(['0']));
        expect(report.surfacePlanCount, equals(2));
        expect(report.diagnostics, isEmpty);

        expect(report.isPermissionRequired, isTrue);
        expect(report.isRuntimeSupported, isFalse);
        expect(report.isRuntimeRejected, isFalse);
        expect(report.isRuntimeValidationAttempted, isFalse);

        final serialized = report.toMap();
        expect(serialized['decision'], equals('permissionRequired'));
        expect(serialized['reasons'], equals(['camera_permission_absent']));
        expect(
          VGCamera2ConcurrentSessionValidationReport.fromMap(serialized),
          equals(report),
        );
      },
    );

    test('unsupportedApi decision report parses and serializes cleanly', () {
      final rawMap = <String, Object?>{
        'success': true,
        'apiLevel': 29,
        'hasCameraPermission': true,
        'attemptedRuntimeValidation': false,
        'supported': false,
        'decision': 'unsupportedApi',
        'reasons': <String>['api_below_30'],
        'selectedConcurrentCameraIds': <String>['0', '1'],
        'surfacePlanCount': 4,
        'diagnostics': <String, Object?>{},
      };

      final report = VGCamera2ConcurrentSessionValidationReport.fromMap(rawMap);
      expect(report.success, isTrue);
      expect(report.apiLevel, equals(29));
      expect(report.hasCameraPermission, isTrue);
      expect(report.attemptedRuntimeValidation, isFalse);
      expect(report.supported, isFalse);
      expect(
        report.decision,
        equals(VGCamera2ConcurrentSessionValidationDecision.unsupportedApi),
      );
      expect(report.reasons, equals(['api_below_30']));
      expect(report.selectedConcurrentCameraIds, equals(['0', '1']));
      expect(report.surfacePlanCount, equals(4));

      expect(report.isPermissionRequired, isFalse);
      expect(report.isRuntimeSupported, isFalse);
      expect(report.isRuntimeRejected, isFalse);
      expect(report.isRuntimeValidationAttempted, isFalse);

      final serialized = report.toMap();
      expect(serialized['decision'], equals('unsupportedApi'));
      expect(
        VGCamera2ConcurrentSessionValidationReport.fromMap(serialized),
        equals(report),
      );
    });

    test('notCandidate decision report parses and serializes cleanly', () {
      final rawMap = <String, Object?>{
        'success': true,
        'apiLevel': 35,
        'hasCameraPermission': true,
        'attemptedRuntimeValidation': false,
        'supported': false,
        'decision': 'notCandidate',
        'reasons': <String>['session_plan_not_concurrent_candidate'],
        'selectedConcurrentCameraIds': <String>['0'],
        'surfacePlanCount': 2,
        'diagnostics': <String, Object?>{},
      };

      final report = VGCamera2ConcurrentSessionValidationReport.fromMap(rawMap);
      expect(report.success, isTrue);
      expect(report.apiLevel, equals(35));
      expect(report.hasCameraPermission, isTrue);
      expect(report.attemptedRuntimeValidation, isFalse);
      expect(report.supported, isFalse);
      expect(
        report.decision,
        equals(VGCamera2ConcurrentSessionValidationDecision.notCandidate),
      );
      expect(report.reasons, equals(['session_plan_not_concurrent_candidate']));
      expect(report.selectedConcurrentCameraIds, equals(['0']));
      expect(report.surfacePlanCount, equals(2));

      expect(report.isPermissionRequired, isFalse);
      expect(report.isRuntimeSupported, isFalse);
      expect(report.isRuntimeRejected, isFalse);
      expect(report.isRuntimeValidationAttempted, isFalse);

      final serialized = report.toMap();
      expect(serialized['decision'], equals('notCandidate'));
      expect(
        VGCamera2ConcurrentSessionValidationReport.fromMap(serialized),
        equals(report),
      );
    });

    test('validationFailed decision report parses and serializes cleanly', () {
      final rawMap = <String, Object?>{
        'success': true,
        'apiLevel': 35,
        'hasCameraPermission': true,
        'attemptedRuntimeValidation': true,
        'supported': false,
        'decision': 'validationFailed',
        'reasons': <String>['runtime_validation_threw'],
        'selectedConcurrentCameraIds': <String>['0', '1'],
        'surfacePlanCount': 4,
        'diagnostics': <String, Object?>{
          'error': 'CameraAccessException: CAMERA_DISCONNECTED',
        },
      };

      final report = VGCamera2ConcurrentSessionValidationReport.fromMap(rawMap);
      expect(report.success, isTrue);
      expect(report.apiLevel, equals(35));
      expect(report.hasCameraPermission, isTrue);
      expect(report.attemptedRuntimeValidation, isTrue);
      expect(report.supported, isFalse);
      expect(
        report.decision,
        equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
      );
      expect(report.reasons, equals(['runtime_validation_threw']));
      expect(report.selectedConcurrentCameraIds, equals(['0', '1']));
      expect(report.surfacePlanCount, equals(4));
      expect(
        report.diagnostics['error'],
        equals('CameraAccessException: CAMERA_DISCONNECTED'),
      );

      expect(report.isPermissionRequired, isFalse);
      expect(report.isRuntimeSupported, isFalse);
      expect(report.isRuntimeRejected, isFalse);
      expect(report.isRuntimeValidationAttempted, isTrue);

      final serialized = report.toMap();
      expect(serialized['decision'], equals('validationFailed'));
      expect(
        VGCamera2ConcurrentSessionValidationReport.fromMap(serialized),
        equals(report),
      );
    });

    test(
      'fromMap handles malformed non-map inputs by returning fallback failure report',
      () {
        final nullReport = VGCamera2ConcurrentSessionValidationReport.fromMap(
          null,
        );
        expect(nullReport.success, isFalse);
        expect(nullReport.apiLevel, equals(0));
        expect(nullReport.hasCameraPermission, isFalse);
        expect(nullReport.attemptedRuntimeValidation, isFalse);
        expect(nullReport.supported, isFalse);
        expect(
          nullReport.decision,
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(nullReport.reasons, equals(['native_result_not_a_map']));
        expect(nullReport.selectedConcurrentCameraIds, isEmpty);
        expect(nullReport.surfacePlanCount, equals(0));
        expect(nullReport.diagnostics, equals({'raw': null}));

        final strReport = VGCamera2ConcurrentSessionValidationReport.fromMap(
          'not_a_map',
        );
        expect(strReport.success, isFalse);
        expect(
          strReport.decision,
          equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
        );
        expect(strReport.diagnostics, equals({'raw': 'not_a_map'}));

        final numReport = VGCamera2ConcurrentSessionValidationReport.fromMap(
          999,
        );
        expect(numReport.success, isFalse);
        expect(numReport.diagnostics, equals({'raw': 999}));

        final listReport = VGCamera2ConcurrentSessionValidationReport.fromMap(
          <Object?>['a', 'b'],
        );
        expect(listReport.success, isFalse);
        expect(
          listReport.diagnostics,
          equals({
            'raw': ['a', 'b'],
          }),
        );
      },
    );

    test('fromMap handles defensive nulls, types, and generic Map shapes', () {
      final mapWithNulls = <Object?, Object?>{
        'success': null,
        'apiLevel': null,
        'hasCameraPermission': null,
        'attemptedRuntimeValidation': null,
        'supported': null,
        'decision': null,
        'reasons': null,
        'selectedConcurrentCameraIds': null,
        'surfacePlanCount': null,
        'diagnostics': null,
      };

      final report = VGCamera2ConcurrentSessionValidationReport.fromMap(
        mapWithNulls,
      );
      expect(report.success, isFalse);
      expect(report.apiLevel, equals(0));
      expect(report.hasCameraPermission, isFalse);
      expect(report.attemptedRuntimeValidation, isFalse);
      expect(report.supported, isFalse);
      expect(
        report.decision,
        equals(VGCamera2ConcurrentSessionValidationDecision.validationFailed),
      );
      expect(report.reasons, isEmpty);
      expect(report.selectedConcurrentCameraIds, isEmpty);
      expect(report.surfacePlanCount, equals(0));
      expect(report.diagnostics, isEmpty);

      // Map with doubles / non-list structures
      final mapWithDoubles = <Object?, Object?>{
        'success': true,
        'apiLevel': 34.0,
        'surfacePlanCount': 2.0,
        'reasons': <Object?>['r1', 123, null],
        'selectedConcurrentCameraIds': <Object?>['0', 456],
        'diagnostics': <Object?, Object?>{'key': 'value'},
      };

      final parsed = VGCamera2ConcurrentSessionValidationReport.fromMap(
        mapWithDoubles,
      );
      expect(parsed.apiLevel, equals(34));
      expect(parsed.surfacePlanCount, equals(2));
      expect(parsed.reasons, equals(['r1', '123']));
      expect(parsed.selectedConcurrentCameraIds, equals(['0', '456']));
      expect(parsed.diagnostics, equals({'key': 'value'}));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Getters Logic
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ConcurrentSessionValidationReport getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      const permReport = VGCamera2ConcurrentSessionValidationReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: false,
        attemptedRuntimeValidation: false,
        supported: false,
        decision:
            VGCamera2ConcurrentSessionValidationDecision.permissionRequired,
        reasons: <String>['camera_permission_absent'],
        selectedConcurrentCameraIds: <String>['0'],
        surfacePlanCount: 2,
        diagnostics: <String, Object?>{},
      );
      expect(permReport.isPermissionRequired, isTrue);

      const otherReport = VGCamera2ConcurrentSessionValidationReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedRuntimeValidation: false,
        supported: false,
        decision: VGCamera2ConcurrentSessionValidationDecision.notCandidate,
        reasons: <String>[],
        selectedConcurrentCameraIds: <String>['0'],
        surfacePlanCount: 2,
        diagnostics: <String, Object?>{},
      );
      expect(otherReport.isPermissionRequired, isFalse);
    });

    test(
      'isRuntimeSupported is true only when attemptedRuntimeValidation is true and decision is supported',
      () {
        const trueSupported = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          reasons: <String>[],
          selectedConcurrentCameraIds: <String>['0', '1'],
          surfacePlanCount: 4,
          diagnostics: <String, Object?>{},
        );
        expect(trueSupported.isRuntimeSupported, isTrue);

        const unattemptedSupported = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: false,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          reasons: <String>[],
          selectedConcurrentCameraIds: <String>['0', '1'],
          surfacePlanCount: 4,
          diagnostics: <String, Object?>{},
        );
        expect(unattemptedSupported.isRuntimeSupported, isFalse);

        const attemptedNotSupported =
            VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: false,
              decision:
                  VGCamera2ConcurrentSessionValidationDecision.notSupported,
              reasons: <String>[],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{},
            );
        expect(attemptedNotSupported.isRuntimeSupported, isFalse);
      },
    );

    test(
      'isRuntimeRejected is true only when attemptedRuntimeValidation is true and decision is notSupported',
      () {
        const trueRejected = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: true,
          supported: false,
          decision: VGCamera2ConcurrentSessionValidationDecision.notSupported,
          reasons: <String>[],
          selectedConcurrentCameraIds: <String>['0', '1'],
          surfacePlanCount: 4,
          diagnostics: <String, Object?>{},
        );
        expect(trueRejected.isRuntimeRejected, isTrue);

        const unattemptedNotSupported =
            VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: false,
              supported: false,
              decision:
                  VGCamera2ConcurrentSessionValidationDecision.notSupported,
              reasons: <String>[],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{},
            );
        expect(unattemptedNotSupported.isRuntimeRejected, isFalse);

        const attemptedSupported = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          reasons: <String>[],
          selectedConcurrentCameraIds: <String>['0', '1'],
          surfacePlanCount: 4,
          diagnostics: <String, Object?>{},
        );
        expect(attemptedSupported.isRuntimeRejected, isFalse);
      },
    );

    test(
      'isRuntimeValidationAttempted mirrors attemptedRuntimeValidation exactly',
      () {
        const attempted = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          reasons: <String>[],
          selectedConcurrentCameraIds: <String>['0', '1'],
          surfacePlanCount: 4,
          diagnostics: <String, Object?>{},
        );
        expect(attempted.isRuntimeValidationAttempted, isTrue);

        const notAttempted = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: false,
          supported: false,
          decision: VGCamera2ConcurrentSessionValidationDecision.notCandidate,
          reasons: <String>[],
          selectedConcurrentCameraIds: <String>['0'],
          surfacePlanCount: 2,
          diagnostics: <String, Object?>{},
        );
        expect(notAttempted.isRuntimeValidationAttempted, isFalse);
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Equality, hashCode, toString, and Stable Diagnostics Hash
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ConcurrentSessionValidationReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      const a = VGCamera2ConcurrentSessionValidationReport(
        success: true,
        apiLevel: 35,
        hasCameraPermission: true,
        attemptedRuntimeValidation: true,
        supported: true,
        decision: VGCamera2ConcurrentSessionValidationDecision.supported,
        reasons: <String>['ok'],
        selectedConcurrentCameraIds: <String>['0', '1'],
        surfacePlanCount: 4,
        diagnostics: <String, Object?>{'key': 'val'},
      );

      const b = VGCamera2ConcurrentSessionValidationReport(
        success: true,
        apiLevel: 35,
        hasCameraPermission: true,
        attemptedRuntimeValidation: true,
        supported: true,
        decision: VGCamera2ConcurrentSessionValidationDecision.supported,
        reasons: <String>['ok'],
        selectedConcurrentCameraIds: <String>['0', '1'],
        surfacePlanCount: 4,
        diagnostics: <String, Object?>{'key': 'val'},
      );

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('success: true'));
      expect(a.toString(), contains('apiLevel: 35'));
      expect(
        a.toString(),
        contains(
          'decision: VGCamera2ConcurrentSessionValidationDecision.supported',
        ),
      );
      expect(a.toString(), contains('surfacePlanCount: 4'));
    });

    test(
      'stable diagnostics hash produces equal hash and equality with different map key order',
      () {
        final diag1 = <String, Object?>{'alpha': 1, 'beta': 2, 'gamma': 3};
        final diag2 = <String, Object?>{'gamma': 3, 'alpha': 1, 'beta': 2};

        final report1 = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          reasons: const <String>['r1'],
          selectedConcurrentCameraIds: const <String>['0', '1'],
          surfacePlanCount: 4,
          diagnostics: diag1,
        );

        final report2 = VGCamera2ConcurrentSessionValidationReport(
          success: true,
          apiLevel: 35,
          hasCameraPermission: true,
          attemptedRuntimeValidation: true,
          supported: true,
          decision: VGCamera2ConcurrentSessionValidationDecision.supported,
          reasons: const <String>['r1'],
          selectedConcurrentCameraIds: const <String>['0', '1'],
          surfacePlanCount: 4,
          diagnostics: diag2,
        );

        expect(report1, equals(report2));
        expect(report1.hashCode, equals(report2.hashCode));
      },
    );

    test('inequality when any single field differs', () {
      const base = VGCamera2ConcurrentSessionValidationReport(
        success: true,
        apiLevel: 35,
        hasCameraPermission: true,
        attemptedRuntimeValidation: true,
        supported: true,
        decision: VGCamera2ConcurrentSessionValidationDecision.supported,
        reasons: <String>['r1'],
        selectedConcurrentCameraIds: <String>['0', '1'],
        surfacePlanCount: 4,
        diagnostics: <String, Object?>{'k': 'v'},
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: false,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: false,
              attemptedRuntimeValidation: true,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: false,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: false,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: true,
              decision:
                  VGCamera2ConcurrentSessionValidationDecision.notSupported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r2'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '2'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 2,
              diagnostics: <String, Object?>{'k': 'v'},
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ConcurrentSessionValidationReport(
              success: true,
              apiLevel: 35,
              hasCameraPermission: true,
              attemptedRuntimeValidation: true,
              supported: true,
              decision: VGCamera2ConcurrentSessionValidationDecision.supported,
              reasons: <String>['r1'],
              selectedConcurrentCameraIds: <String>['0', '1'],
              surfacePlanCount: 4,
              diagnostics: <String, Object?>{'k': 'different_val'},
            ),
          ),
        ),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. MethodChannel Contract
  // ─────────────────────────────────────────────────────────────────────────
  group('MethodChannel contract for concurrent SessionConfiguration validation', () {
    test(
      'validateAndroidCamera2ConcurrentSessionConfiguration with injected custom channel',
      () async {
        const testChannel = MethodChannel('test_vanguard_media_engine_unit_f');
        final planFixture = makeDualCameraSessionPlanFixture(
          primaryCameraId: '0',
          secondaryCameraId: '1',
        );

        String? capturedMethod;
        dynamic capturedArguments;

        binaryMessenger.setMockMethodCallHandler(testChannel, (
          MethodCall call,
        ) async {
          capturedMethod = call.method;
          capturedArguments = call.arguments;
          return <String, Object?>{
            'success': true,
            'apiLevel': 35,
            'hasCameraPermission': true,
            'attemptedRuntimeValidation': true,
            'supported': true,
            'decision': 'supported',
            'reasons': <String>[],
            'selectedConcurrentCameraIds': <String>['0', '1'],
            'surfacePlanCount': 4,
            'diagnostics': <String, Object?>{'runtimeSessionSupported': true},
          };
        });

        final report =
            await VGCamera2ConcurrentSessionValidationReport.validateAndroidCamera2ConcurrentSessionConfiguration(
              plan: planFixture,
              channel: testChannel,
            );

        expect(
          capturedMethod,
          equals('runAndroidDagPhase3UnitFConcurrentSessionValidation'),
        );
        expect(capturedArguments, isA<Map>());
        final argsMap = capturedArguments as Map;
        expect(argsMap['plan'], equals(planFixture.toMap()));

        expect(report.success, isTrue);
        expect(report.apiLevel, equals(35));
        expect(report.hasCameraPermission, isTrue);
        expect(report.attemptedRuntimeValidation, isTrue);
        expect(report.supported, isTrue);
        expect(
          report.decision,
          equals(VGCamera2ConcurrentSessionValidationDecision.supported),
        );
        expect(report.selectedConcurrentCameraIds, equals(['0', '1']));
        expect(report.surfacePlanCount, equals(4));
        expect(report.isRuntimeSupported, isTrue);

        binaryMessenger.setMockMethodCallHandler(testChannel, null);
      },
    );

    test(
      'validateAndroidCamera2ConcurrentSessionConfiguration with default channel',
      () async {
        final planFixture = makeDualCameraSessionPlanFixture(
          primaryCameraId: 'back_0',
          secondaryCameraId: 'front_1',
        );

        String? capturedMethod;
        dynamic capturedArguments;

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (
          MethodCall call,
        ) async {
          capturedMethod = call.method;
          capturedArguments = call.arguments;
          return <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': false,
            'attemptedRuntimeValidation': false,
            'supported': false,
            'decision': 'permissionRequired',
            'reasons': <String>['camera_permission_absent'],
            'selectedConcurrentCameraIds': <String>['back_0', 'front_1'],
            'surfacePlanCount': 4,
            'diagnostics': <String, Object?>{},
          };
        });

        final report =
            await VGCamera2ConcurrentSessionValidationReport.validateAndroidCamera2ConcurrentSessionConfiguration(
              plan: planFixture,
            );

        expect(
          capturedMethod,
          equals('runAndroidDagPhase3UnitFConcurrentSessionValidation'),
        );
        expect(capturedArguments, isA<Map>());
        final argsMap = capturedArguments as Map;
        expect(argsMap['plan'], equals(planFixture.toMap()));

        expect(report.success, isTrue);
        expect(report.apiLevel, equals(34));
        expect(report.hasCameraPermission, isFalse);
        expect(report.attemptedRuntimeValidation, isFalse);
        expect(report.supported, isFalse);
        expect(
          report.decision,
          equals(
            VGCamera2ConcurrentSessionValidationDecision.permissionRequired,
          ),
        );
        expect(report.reasons, equals(['camera_permission_absent']));
        expect(
          report.selectedConcurrentCameraIds,
          equals(['back_0', 'front_1']),
        );
        expect(report.surfacePlanCount, equals(4));
        expect(report.isPermissionRequired, isTrue);
      },
    );
  });
}
