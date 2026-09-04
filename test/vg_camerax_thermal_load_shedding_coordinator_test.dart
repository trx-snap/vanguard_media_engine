// vg_camerax_thermal_load_shedding_coordinator_test.dart
// vanguard_media_engine -- P3-CAM-THERMAL-ACT-DART-CALLBACK-CAMERAX-WIRING
// unit tests. Pure Dart, no device: exercises
// VGCameraXThermalLoadSheddingCoordinator using an injected thermal state
// stream and fake diagnostics/apply callbacks.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

VGCameraXThermalFpsDiagnostics _fakeDiagnostics({
  bool isRecordingActive = false,
  bool isRecording = false,
  int? observedUpper = 30,
}) {
  return VGCameraXThermalFpsDiagnostics(
    running: true,
    bindGeneration: 1,
    bindCount: 1,
    surfaceRequestCount: 1,
    completedCaptureCount: 10,
    observedAeTargetFpsUpper: observedUpper,
    consecutiveAppliedRangeCompletedCaptures: 0,
    isRecording: isRecording,
    isRecordingActive: isRecordingActive,
  );
}

VGCameraXThermalFpsApplyResult _fakeApplyResult(int targetFps) {
  return VGCameraXThermalFpsApplyResult(
    requestedTargetFps: targetFps,
    observedCurrentLower: 30,
    observedCurrentUpper: 30,
    selectedLower: targetFps,
    selectedUpper: targetFps,
    outcome: 'APPLIED',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Serious event applies once', () {
    test(
      'serious + recording reduces FPS and calls apply exactly once',
      () async {
        final controller = StreamController<VGThermalState>.broadcast();
        var applyCallCount = 0;
        int? appliedTargetFps;

        final coordinator = VGCameraXThermalLoadSheddingCoordinator(
          thermalStates: controller.stream,
          getDiagnostics: () async => _fakeDiagnostics(
            isRecordingActive: true,
            isRecording: true,
            observedUpper: 30,
          ),
          applyTargetFps: (fps) async {
            applyCallCount++;
            appliedTargetFps = fps;
            return _fakeApplyResult(fps);
          },
        );

        final reportFuture = coordinator.reports.first;
        coordinator.start();
        controller.add(VGThermalState.serious);

        final report = await reportFuture.timeout(const Duration(seconds: 2));

        expect(report.applied, isTrue);
        expect(report.skipped, isFalse);
        expect(report.errorCode, isNull);
        expect(
          report.evaluation?.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.reduceFrameRate),
        );
        expect(applyCallCount, equals(1));
        expect(appliedTargetFps, equals(24));
        expect(report.applyResult?.outcome, equals('APPLIED'));

        await coordinator.dispose();
        await controller.close();
      },
    );
  });

  group('Duplicate/concurrent event handling', () {
    test(
      'a second event while the first is in flight is skipped apply_in_progress',
      () async {
        final controller = StreamController<VGThermalState>.broadcast();
        final diagnosticsGate = Completer<void>();
        var diagnosticsCallCount = 0;
        var applyCallCount = 0;

        final coordinator = VGCameraXThermalLoadSheddingCoordinator(
          thermalStates: controller.stream,
          getDiagnostics: () async {
            diagnosticsCallCount++;
            await diagnosticsGate.future;
            return _fakeDiagnostics(
              isRecordingActive: true,
              isRecording: true,
              observedUpper: 30,
            );
          },
          applyTargetFps: (fps) async {
            applyCallCount++;
            return _fakeApplyResult(fps);
          },
        );

        final reports = <VGCameraXThermalLoadSheddingCoordinatorReport>[];
        final subscription = coordinator.reports.listen(reports.add);
        coordinator.start();

        controller.add(VGThermalState.serious);
        await pumpEventQueue();

        controller.add(VGThermalState.critical);
        await pumpEventQueue();

        expect(diagnosticsCallCount, equals(1));
        expect(reports, hasLength(1));
        expect(reports.single.skipped, isTrue);
        expect(
          reports.single.reason,
          equals(VGCameraXThermalLoadSheddingCoordinator.reasonApplyInProgress),
        );

        diagnosticsGate.complete();
        await pumpEventQueue();

        expect(reports, hasLength(2));
        expect(reports.last.applied, isTrue);
        expect(applyCallCount, equals(1));

        await subscription.cancel();
        await coordinator.dispose();
        await controller.close();
      },
    );
  });

  group('Diagnostics/apply error handling', () {
    test('getDiagnostics failure becomes an error report', () async {
      final controller = StreamController<VGThermalState>.broadcast();

      final coordinator = VGCameraXThermalLoadSheddingCoordinator(
        thermalStates: controller.stream,
        getDiagnostics: () async =>
            throw PlatformException(code: 'NO_CAMERA', message: 'no session'),
        applyTargetFps: (fps) async => _fakeApplyResult(fps),
      );

      final reportFuture = coordinator.reports.first;
      coordinator.start();
      controller.add(VGThermalState.serious);

      final report = await reportFuture.timeout(const Duration(seconds: 2));

      expect(report.applied, isFalse);
      expect(report.skipped, isFalse);
      expect(report.errorCode, equals('NO_CAMERA'));
      expect(report.errorMessage, equals('no session'));
      expect(report.evaluation, isNull);
      expect(report.diagnosticsBefore, isNull);

      await coordinator.dispose();
      await controller.close();
    });

    test('applyTargetFps failure becomes an error report', () async {
      final controller = StreamController<VGThermalState>.broadcast();

      final coordinator = VGCameraXThermalLoadSheddingCoordinator(
        thermalStates: controller.stream,
        getDiagnostics: () async => _fakeDiagnostics(
          isRecordingActive: true,
          isRecording: true,
          observedUpper: 30,
        ),
        applyTargetFps: (fps) async =>
            throw PlatformException(code: 'APPLY_FAILED'),
      );

      final reportFuture = coordinator.reports.first;
      coordinator.start();
      controller.add(VGThermalState.serious);

      final report = await reportFuture.timeout(const Duration(seconds: 2));

      expect(report.applied, isFalse);
      expect(report.skipped, isFalse);
      expect(report.errorCode, equals('APPLY_FAILED'));
      expect(
        report.evaluation?.decision,
        equals(VGCamera2ThermalLoadSheddingDecision.reduceFrameRate),
      );
      expect(report.diagnosticsBefore, isNotNull);

      await coordinator.dispose();
      await controller.close();
    });

    test('diagnostics timeout becomes an error report with TIMEOUT', () async {
      final controller = StreamController<VGThermalState>.broadcast();
      final neverCompletes = Completer<VGCameraXThermalFpsDiagnostics>();

      final coordinator = VGCameraXThermalLoadSheddingCoordinator(
        thermalStates: controller.stream,
        getDiagnostics: () => neverCompletes.future,
        applyTargetFps: (fps) async => _fakeApplyResult(fps),
        applyTimeout: const Duration(milliseconds: 20),
      );

      final reportFuture = coordinator.reports.first;
      coordinator.start();
      controller.add(VGThermalState.serious);

      final report = await reportFuture.timeout(const Duration(seconds: 2));

      expect(report.errorCode, equals('TIMEOUT'));
      expect(report.applied, isFalse);
      expect(report.skipped, isFalse);

      await coordinator.dispose();
      await controller.close();
    });
  });

  group('Skip reasons', () {
    test(
      'reduceFrameRate with no further headroom is skipped no_reduction',
      () async {
        final controller = StreamController<VGThermalState>.broadcast();
        var applyCallCount = 0;

        final coordinator = VGCameraXThermalLoadSheddingCoordinator(
          thermalStates: controller.stream,
          getDiagnostics: () async => _fakeDiagnostics(
            isRecordingActive: true,
            isRecording: true,
            observedUpper: 1,
          ),
          applyTargetFps: (fps) async {
            applyCallCount++;
            return _fakeApplyResult(fps);
          },
        );

        final reportFuture = coordinator.reports.first;
        coordinator.start();
        controller.add(VGThermalState.serious);

        final report = await reportFuture.timeout(const Duration(seconds: 2));

        expect(report.applied, isFalse);
        expect(report.skipped, isTrue);
        expect(
          report.reason,
          equals(VGCameraXThermalLoadSheddingCoordinator.reasonNoReduction),
        );
        expect(applyCallCount, equals(0));

        await coordinator.dispose();
        await controller.close();
      },
    );

    test('nominal state is skipped no_action', () async {
      final controller = StreamController<VGThermalState>.broadcast();
      var applyCallCount = 0;

      final coordinator = VGCameraXThermalLoadSheddingCoordinator(
        thermalStates: controller.stream,
        getDiagnostics: () async => _fakeDiagnostics(),
        applyTargetFps: (fps) async {
          applyCallCount++;
          return _fakeApplyResult(fps);
        },
      );

      final reportFuture = coordinator.reports.first;
      coordinator.start();
      controller.add(VGThermalState.nominal);

      final report = await reportFuture.timeout(const Duration(seconds: 2));

      expect(report.applied, isFalse);
      expect(report.skipped, isTrue);
      expect(
        report.reason,
        equals(VGCameraXThermalLoadSheddingCoordinator.reasonNoAction),
      );
      expect(applyCallCount, equals(0));

      await coordinator.dispose();
      await controller.close();
    });

    test(
      'critical + recording without a secondary camera is skipped unsupported_decision',
      () async {
        final controller = StreamController<VGThermalState>.broadcast();
        var applyCallCount = 0;

        final coordinator = VGCameraXThermalLoadSheddingCoordinator(
          thermalStates: controller.stream,
          getDiagnostics: () async => _fakeDiagnostics(
            isRecordingActive: true,
            isRecording: true,
            observedUpper: 30,
          ),
          applyTargetFps: (fps) async {
            applyCallCount++;
            return _fakeApplyResult(fps);
          },
        );

        final reportFuture = coordinator.reports.first;
        coordinator.start();
        controller.add(VGThermalState.critical);

        final report = await reportFuture.timeout(const Duration(seconds: 2));

        expect(report.applied, isFalse);
        expect(report.skipped, isTrue);
        expect(
          report.reason,
          equals(
            VGCameraXThermalLoadSheddingCoordinator.reasonUnsupportedDecision,
          ),
        );
        expect(
          report.evaluation?.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.stopRecording),
        );
        expect(applyCallCount, equals(0));

        await coordinator.dispose();
        await controller.close();
      },
    );
  });

  group('Lifecycle', () {
    test('dispose prevents late emit and late apply', () async {
      final controller = StreamController<VGThermalState>.broadcast();
      final diagnosticsGate = Completer<VGCameraXThermalFpsDiagnostics>();
      var applyCallCount = 0;

      final coordinator = VGCameraXThermalLoadSheddingCoordinator(
        thermalStates: controller.stream,
        getDiagnostics: () => diagnosticsGate.future,
        applyTargetFps: (fps) async {
          applyCallCount++;
          return _fakeApplyResult(fps);
        },
      );

      final reports = <VGCameraXThermalLoadSheddingCoordinatorReport>[];
      coordinator.reports.listen(reports.add);
      coordinator.start();

      controller.add(VGThermalState.serious);
      await pumpEventQueue();

      await coordinator.dispose();

      diagnosticsGate.complete(
        _fakeDiagnostics(
          isRecordingActive: true,
          isRecording: true,
          observedUpper: 30,
        ),
      );
      await pumpEventQueue();

      expect(reports, isEmpty);
      expect(applyCallCount, equals(0));
      expect(coordinator.isDisposed, isTrue);
      expect(coordinator.isRunning, isFalse);

      await controller.close();
    });

    test('start/stop/dispose are idempotent', () async {
      final controller = StreamController<VGThermalState>.broadcast();
      final coordinator = VGCameraXThermalLoadSheddingCoordinator(
        thermalStates: controller.stream,
        getDiagnostics: () async => _fakeDiagnostics(),
        applyTargetFps: (fps) async => _fakeApplyResult(fps),
      );

      coordinator.start();
      coordinator.start();
      expect(coordinator.isRunning, isTrue);

      coordinator.stop();
      coordinator.stop();
      expect(coordinator.isRunning, isFalse);

      await coordinator.dispose();
      await coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);

      await controller.close();
    });
  });

  group('Report serialization', () {
    test('toMap exposes proofBoundary and nonClaims', () async {
      final controller = StreamController<VGThermalState>.broadcast();

      final coordinator = VGCameraXThermalLoadSheddingCoordinator(
        thermalStates: controller.stream,
        getDiagnostics: () async => _fakeDiagnostics(
          isRecordingActive: true,
          isRecording: true,
          observedUpper: 30,
        ),
        applyTargetFps: (fps) async => _fakeApplyResult(fps),
      );

      final reportFuture = coordinator.reports.first;
      coordinator.start();
      controller.add(VGThermalState.serious);

      final report = await reportFuture.timeout(const Duration(seconds: 2));
      final map = report.toMap();

      expect(
        map['proofBoundary'],
        equals(
          'dart_thermal_callback_path_to_camerax_fps_mid_recording_synthetic_no_forced_heat_no_rebind_no_product',
        ),
      );
      expect(
        map['nonClaims'],
        equals(VGCameraXThermalLoadSheddingCoordinatorReport.nonClaims),
      );
      expect(
        (map['nonClaims'] as Map<String, bool>).values.every((v) => v == false),
        isTrue,
      );
      expect(
        report.toString(),
        contains('VGCameraXThermalLoadSheddingCoordinatorReport'),
      );

      await coordinator.dispose();
      await controller.close();
    });
  });
}
