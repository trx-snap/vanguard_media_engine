// vg_camera2_thermal_load_shedding_monitor_test.dart
// vanguard_media_engine — Phase 3-Unit V: Android Camera2 Thermal Load-Shedding
// Monitor & Telemetry Coordinator Foundation Unit Tests.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 3-Unit V: Config Validation & Defaults', () {
    test('default configuration parameters', () {
      final config = VGCamera2ThermalLoadSheddingMonitorConfig();
      expect(config.maxHistoryLength, equals(16));
      expect(config.suppressDuplicateThermalStates, isTrue);
      expect(config.initialSessionState.wasRecording, isFalse);
      expect(config.initialSessionState.hadSecondaryCamera, isFalse);
      expect(config.initialSessionState.currentFps, equals(30));
      expect(config.initialSessionState.currentResolutionScale, equals(1.0));
      expect(config.initialSessionState.canPreserveEncoderContract, isTrue);
    });

    test('validates maxHistoryLength > 0', () {
      expect(
        () => VGCamera2ThermalLoadSheddingMonitorConfig(maxHistoryLength: 0),
        throwsArgumentError,
      );
      expect(
        () => VGCamera2ThermalLoadSheddingMonitorConfig(maxHistoryLength: -5),
        throwsArgumentError,
      );
    });

    test('config toMap, toJson, equality, hashCode, toString', () {
      final config1 = VGCamera2ThermalLoadSheddingMonitorConfig(
        maxHistoryLength: 10,
        suppressDuplicateThermalStates: false,
      );
      final config2 = VGCamera2ThermalLoadSheddingMonitorConfig(
        maxHistoryLength: 10,
        suppressDuplicateThermalStates: false,
      );
      final config3 = VGCamera2ThermalLoadSheddingMonitorConfig(
        maxHistoryLength: 12,
      );

      expect(config1, equals(config2));
      expect(config1.hashCode, equals(config2.hashCode));
      expect(config1, isNot(equals(config3)));

      final map = config1.toMap();
      expect(map['maxHistoryLength'], equals(10));
      expect(map['suppressDuplicateThermalStates'], isFalse);
      expect(map['initialSessionState'], isA<Map<String, Object?>>());
      expect(config1.toJson(), equals(map));
      expect(
        config1.toString(),
        contains('VGCamera2ThermalLoadSheddingMonitorConfig'),
      );
    });
  });

  group('Phase 3-Unit V: Session State Model & Normalization', () {
    test('session state defaults and normalized constructor', () {
      const state = VGCamera2ThermalSessionState();
      expect(state.wasRecording, isFalse);
      expect(state.hadSecondaryCamera, isFalse);
      expect(state.currentFps, equals(30));
      expect(state.currentResolutionScale, equals(1.0));
      expect(state.canPreserveEncoderContract, isTrue);

      final normalized = VGCamera2ThermalSessionState.normalized(
        currentFps: -10,
        currentResolutionScale: -0.5,
      );
      expect(normalized.currentFps, equals(1));
      expect(normalized.currentResolutionScale, equals(1.0));
    });

    test('session state copyWith clamps invalid values', () {
      const state = VGCamera2ThermalSessionState();
      final updated = state.copyWith(
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 0,
        currentResolutionScale: 0.0,
        canPreserveEncoderContract: false,
      );

      expect(updated.wasRecording, isTrue);
      expect(updated.hadSecondaryCamera, isTrue);
      expect(updated.currentFps, equals(1));
      expect(updated.currentResolutionScale, equals(1.0));
      expect(updated.canPreserveEncoderContract, isFalse);
    });

    test(
      'toInput conversion produces accurate VGCamera2ThermalLoadSheddingInput',
      () {
        const state = VGCamera2ThermalSessionState(
          wasRecording: true,
          hadSecondaryCamera: true,
          currentFps: 60,
          currentResolutionScale: 0.75,
          canPreserveEncoderContract: false,
        );

        final input = state.toInput(VGThermalState.serious);
        expect(input.thermalState, equals(VGThermalState.serious));
        expect(input.wasRecording, isTrue);
        expect(input.hadSecondaryCamera, isTrue);
        expect(input.currentFps, equals(60));
        expect(input.currentResolutionScale, equals(0.75));
        expect(input.canPreserveEncoderContract, isFalse);
      },
    );

    test('session state equality, hashCode, toMap, toString', () {
      const state1 = VGCamera2ThermalSessionState(
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 24,
      );
      const state2 = VGCamera2ThermalSessionState(
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 24,
      );
      const state3 = VGCamera2ThermalSessionState(wasRecording: false);

      expect(state1, equals(state2));
      expect(state1.hashCode, equals(state2.hashCode));
      expect(state1, isNot(equals(state3)));

      final map = state1.toMap();
      expect(map['wasRecording'], isTrue);
      expect(map['hadSecondaryCamera'], isFalse);
      expect(map['currentFps'], equals(24));
      expect(state1.toJson(), equals(map));
      expect(state1.toString(), contains('VGCamera2ThermalSessionState'));
    });
  });

  group('Phase 3-Unit V: Monitor Initial State & updateSessionState', () {
    test(
      'initial monitor state is unstarted, undisposed, with empty history',
      () {
        final controller = StreamController<VGThermalState>.broadcast();
        final monitor = VGCamera2ThermalLoadSheddingMonitor(
          thermalStates: controller.stream,
        );

        expect(monitor.isRunning, isFalse);
        expect(monitor.isDisposed, isFalse);
        expect(monitor.historyLength, equals(0));
        expect(monitor.history, isEmpty);
        expect(monitor.latest, isNull);
        expect(monitor.lastStreamError, isNull);
        expect(monitor.sessionState.wasRecording, isFalse);

        controller.close();
      },
    );

    test('updateSessionState updates state safely', () {
      final monitor = VGCamera2ThermalLoadSheddingMonitor();

      monitor.updateSessionState(
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 60,
        currentResolutionScale: 0.5,
        canPreserveEncoderContract: false,
      );

      expect(monitor.sessionState.wasRecording, isTrue);
      expect(monitor.sessionState.hadSecondaryCamera, isTrue);
      expect(monitor.sessionState.currentFps, equals(60));
      expect(monitor.sessionState.currentResolutionScale, equals(0.5));
      expect(monitor.sessionState.canPreserveEncoderContract, isFalse);

      // Clamps invalid values
      monitor.updateSessionState(currentFps: -10, currentResolutionScale: 0.0);
      expect(monitor.sessionState.currentFps, equals(1));
      expect(monitor.sessionState.currentResolutionScale, equals(1.0));
    });
  });

  group('Phase 3-Unit V: Immediate evaluateOnce & Telemetry Invariants', () {
    test(
      'evaluateOnce records history, updates latest, and emits evaluation',
      () async {
        final controller = StreamController<VGThermalState>.broadcast();
        final monitor = VGCamera2ThermalLoadSheddingMonitor(
          thermalStates: controller.stream,
          config: VGCamera2ThermalLoadSheddingMonitorConfig(
            maxHistoryLength: 5,
          ),
        );

        final emitted = <VGCamera2ThermalLoadSheddingEvaluation>[];
        final sub = monitor.evaluations.listen(emitted.add);

        monitor.updateSessionState(
          wasRecording: true,
          hadSecondaryCamera: true,
          currentFps: 30,
          canPreserveEncoderContract: true,
        );

        final eval = monitor.evaluateOnce(VGThermalState.serious);

        expect(eval.sequence, equals(1));
        expect(eval.thermalState, equals(VGThermalState.serious));
        expect(
          eval.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera),
        );
        expect(eval.notifyDart, isTrue);
        expect(eval.requiresSafeGraphBoundary, isTrue);
        expect(eval.shouldDropSecondaryCamera, isTrue);
        expect(eval.shouldStopRecording, isFalse);
        expect(eval.advisoryOnly, isTrue);
        expect(eval.cameraSessionMutated, isFalse);
        expect(eval.captureRequestUpdated, isFalse);
        expect(eval.rendererTouched, isFalse);
        expect(eval.encoderTouched, isFalse);
        expect(eval.historyLength, equals(1));

        expect(monitor.historyLength, equals(1));
        expect(monitor.latest, equals(eval));
        expect(monitor.history.first, equals(eval));

        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(emitted.length, equals(1));
        expect(emitted.first, equals(eval));

        await sub.cancel();
        await monitor.dispose();
        await controller.close();
      },
    );

    test('evaluation convenience getters delegate to plan', () {
      final monitor = VGCamera2ThermalLoadSheddingMonitor();
      monitor.updateSessionState(wasRecording: true, hadSecondaryCamera: false);

      final evalSerious = monitor.evaluateOnce(VGThermalState.serious);
      expect(evalSerious.isReducingFrameRate, isTrue);
      expect(evalSerious.isReducingResolution, isFalse);
      expect(evalSerious.isMaintaining, isFalse);
      expect(evalSerious.isMonitoring, isFalse);
      expect(evalSerious.isDroppingSecondaryCamera, isFalse);
      expect(evalSerious.isStoppingRecording, isFalse);
      expect(evalSerious.targetFps, equals(24));
      expect(evalSerious.reasons, contains('thermal_serious_reduce_fps'));

      final evalNominal = monitor.evaluateOnce(VGThermalState.nominal);
      expect(evalNominal.isMaintaining, isTrue);
      expect(evalNominal.notifyDart, isFalse);
      expect(evalNominal.requiresSafeGraphBoundary, isFalse);
      expect(evalNominal.preservesEncoderContract, isTrue);
    });

    test(
      'diagnostics dictionary contains proofBoundary, policyProofBoundary, and nonClaims',
      () {
        final monitor = VGCamera2ThermalLoadSheddingMonitor();
        final eval = monitor.evaluateOnce(VGThermalState.serious);

        final diag = eval.diagnostics;
        expect(
          diag['proofBoundary'],
          equals(
            'thermal_load_shedding_monitor_advisory_no_camera_session_mutation',
          ),
        );
        expect(
          diag['policyProofBoundary'],
          equals(
            'thermal_load_shedding_policy_advisory_no_camera_session_mutation',
          ),
        );
        expect(diag['sequence'], equals(1));
        expect(diag['thermalState'], equals('serious'));
        expect(diag['historyLength'], equals(1));
        expect(diag['maxHistoryLength'], equals(16));

        final nonClaims = Map<String, dynamic>.from(diag['nonClaims'] as Map);
        expect(nonClaims['cameraSessionMutated'], isFalse);
        expect(nonClaims['captureRequestUpdated'], isFalse);
        expect(nonClaims['cameraOpened'], isFalse);
        expect(nonClaims['rendererTouched'], isFalse);
        expect(nonClaims['encoderTouched'], isFalse);
        expect(nonClaims['realForcedOverheat'], isFalse);
        expect(nonClaims['resolutionReconfigured'], isFalse);
      },
    );

    test(
      'evaluates resolution step when allowResolutionStep is true and fps floor is exhausted',
      () {
        final monitor = VGCamera2ThermalLoadSheddingMonitor(
          planner: const VGCamera2ThermalLoadSheddingPlanner(
            allowResolutionStep: true,
          ),
        );
        monitor.updateSessionState(
          wasRecording: true,
          hadSecondaryCamera: false,
          currentFps: 15,
          currentResolutionScale: 1.0,
        );

        final eval = monitor.evaluateOnce(VGThermalState.serious);

        expect(
          eval.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.reduceResolution),
        );
        expect(eval.isReducingResolution, isTrue);
        expect(eval.isReducingFrameRate, isFalse);
        expect(eval.targetFps, equals(15));
        expect(eval.targetResolutionScale, equals(0.5));
        expect(eval.preservesEncoderContract, isFalse);
        expect(eval.requiresSafeGraphBoundary, isTrue);
        expect(eval.advisoryOnly, isTrue);
        expect(eval.cameraSessionMutated, isFalse);
        expect(eval.captureRequestUpdated, isFalse);
        expect(eval.reasons, contains('thermal_serious_reduce_resolution'));
        expect(eval.reasons, contains('fps_floor_exhausted'));
        expect(
          eval.reasons,
          contains('resolution_step_breaks_encoder_dimensions'),
        );
      },
    );
  });

  group(
    'Phase 3-Unit V: Stream Subscription, Idempotency & Duplicate Suppression',
    () {
      test('start() is idempotent and processes stream events', () async {
        final controller = StreamController<VGThermalState>.broadcast();
        final monitor = VGCamera2ThermalLoadSheddingMonitor(
          thermalStates: controller.stream,
        );

        final emitted = <VGCamera2ThermalLoadSheddingEvaluation>[];
        final sub = monitor.evaluations.listen(emitted.add);

        expect(monitor.isRunning, isFalse);
        monitor.start();
        expect(monitor.isRunning, isTrue);
        monitor.start(); // Idempotent call
        expect(monitor.isRunning, isTrue);

        controller.add(VGThermalState.fair);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(emitted.length, equals(1));
        expect(emitted.first.thermalState, equals(VGThermalState.fair));
        expect(
          emitted.first.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.monitor),
        );

        await sub.cancel();
        await monitor.dispose();
        await controller.close();
      });

      test(
        'suppressDuplicateThermalStates=true suppresses adjacent identical thermal events',
        () async {
          final controller = StreamController<VGThermalState>.broadcast();
          final monitor = VGCamera2ThermalLoadSheddingMonitor(
            thermalStates: controller.stream,
            config: VGCamera2ThermalLoadSheddingMonitorConfig(
              suppressDuplicateThermalStates: true,
            ),
          );

          final emitted = <VGCamera2ThermalLoadSheddingEvaluation>[];
          final sub = monitor.evaluations.listen(emitted.add);

          monitor.start();

          controller.add(VGThermalState.fair);
          controller.add(VGThermalState.fair);
          controller.add(VGThermalState.fair);
          controller.add(VGThermalState.serious);
          controller.add(VGThermalState.serious);
          controller.add(VGThermalState.nominal);

          await Future<void>.delayed(const Duration(milliseconds: 30));

          expect(emitted.length, equals(3));
          expect(emitted[0].thermalState, equals(VGThermalState.fair));
          expect(emitted[1].thermalState, equals(VGThermalState.serious));
          expect(emitted[2].thermalState, equals(VGThermalState.nominal));

          await sub.cancel();
          await monitor.dispose();
          await controller.close();
        },
      );

      test(
        'suppressDuplicateThermalStates=false evaluates all events',
        () async {
          final controller = StreamController<VGThermalState>.broadcast();
          final monitor = VGCamera2ThermalLoadSheddingMonitor(
            thermalStates: controller.stream,
            config: VGCamera2ThermalLoadSheddingMonitorConfig(
              suppressDuplicateThermalStates: false,
            ),
          );

          final emitted = <VGCamera2ThermalLoadSheddingEvaluation>[];
          final sub = monitor.evaluations.listen(emitted.add);

          monitor.start();

          controller.add(VGThermalState.fair);
          controller.add(VGThermalState.fair);
          controller.add(VGThermalState.fair);

          await Future<void>.delayed(const Duration(milliseconds: 30));

          expect(emitted.length, equals(3));
          expect(
            emitted.every((e) => e.thermalState == VGThermalState.fair),
            isTrue,
          );

          await sub.cancel();
          await monitor.dispose();
          await controller.close();
        },
      );

      test(
        'stop() cancels subscription idempotently without closing evaluations stream',
        () async {
          final controller = StreamController<VGThermalState>.broadcast();
          final monitor = VGCamera2ThermalLoadSheddingMonitor(
            thermalStates: controller.stream,
          );

          final emitted = <VGCamera2ThermalLoadSheddingEvaluation>[];
          final sub = monitor.evaluations.listen(emitted.add);

          monitor.start();
          expect(monitor.isRunning, isTrue);

          monitor.stop();
          expect(monitor.isRunning, isFalse);
          monitor.stop(); // Idempotent stop
          expect(monitor.isRunning, isFalse);

          controller.add(VGThermalState.serious);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // No stream event processed while stopped
          expect(emitted, isEmpty);

          // evaluateOnce still works and emits to stream
          final eval = monitor.evaluateOnce(VGThermalState.serious);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(emitted.length, equals(1));
          expect(emitted.first, equals(eval));

          // Can resume listening via start()
          monitor.start();
          expect(monitor.isRunning, isTrue);
          controller.add(VGThermalState.critical);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(emitted.length, equals(2));
          expect(emitted.last.thermalState, equals(VGThermalState.critical));

          await sub.cancel();
          await monitor.dispose();
          await controller.close();
        },
      );

      test('captures lastStreamError when stream produces an error', () async {
        final controller = StreamController<VGThermalState>.broadcast();
        final monitor = VGCamera2ThermalLoadSheddingMonitor(
          thermalStates: controller.stream,
        );

        monitor.start();

        controller.addError(Exception('Thermal hardware sensor disconnected'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          monitor.lastStreamError,
          contains('Thermal hardware sensor disconnected'),
        );
        expect(monitor.isRunning, isTrue);

        await monitor.dispose();
        await controller.close();
      });
    },
  );

  group('Phase 3-Unit V: Dynamic Session State Transitions Mid-Stream', () {
    test(
      'reacts to dynamic session state transitions across thermal events',
      () async {
        final controller = StreamController<VGThermalState>.broadcast();
        final monitor = VGCamera2ThermalLoadSheddingMonitor(
          thermalStates: controller.stream,
        );

        final emitted = <VGCamera2ThermalLoadSheddingEvaluation>[];
        final sub = monitor.evaluations.listen(emitted.add);

        monitor.start();

        // 1. Initial state: not recording -> serious yields monitor
        controller.add(VGThermalState.serious);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(emitted.length, equals(1));
        expect(
          emitted.last.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.monitor),
        );

        // 2. Start recording with secondary camera -> critical yields dropSecondaryCamera
        monitor.updateSessionState(
          wasRecording: true,
          hadSecondaryCamera: true,
          canPreserveEncoderContract: true,
        );
        controller.add(VGThermalState.critical);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(emitted.length, equals(2));
        expect(
          emitted.last.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera),
        );
        expect(emitted.last.shouldDropSecondaryCamera, isTrue);

        // 3. Encoder contract lost -> serious yields dropSecondaryCamera (since secondary is still on)
        controller.add(VGThermalState.serious);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(emitted.length, equals(3));
        expect(
          emitted.last.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera),
        );

        // 4. Secondary dropped, cannot preserve encoder contract -> critical yields stopRecording
        monitor.updateSessionState(
          hadSecondaryCamera: false,
          canPreserveEncoderContract: false,
        );
        controller.add(VGThermalState.critical);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(emitted.length, equals(4));
        expect(
          emitted.last.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.stopRecording),
        );
        expect(emitted.last.shouldStopRecording, isTrue);
        expect(emitted.last.preservesEncoderContract, isFalse);

        await sub.cancel();
        await monitor.dispose();
        await controller.close();
      },
    );
  });

  group('Phase 3-Unit V: Bounded FIFO History & Latest Tracking', () {
    test('history is capped at maxHistoryLength with FIFO eviction', () {
      final monitor = VGCamera2ThermalLoadSheddingMonitor(
        config: VGCamera2ThermalLoadSheddingMonitorConfig(maxHistoryLength: 3),
      );

      monitor.evaluateOnce(VGThermalState.nominal);
      expect(monitor.historyLength, equals(1));
      expect(monitor.latest?.sequence, equals(1));

      monitor.evaluateOnce(VGThermalState.fair);
      expect(monitor.historyLength, equals(2));
      expect(monitor.latest?.sequence, equals(2));

      monitor.evaluateOnce(VGThermalState.serious);
      expect(monitor.historyLength, equals(3));
      expect(monitor.latest?.sequence, equals(3));

      // 4th evaluation evicts the 1st
      monitor.evaluateOnce(VGThermalState.critical);
      expect(monitor.historyLength, equals(3));
      expect(monitor.latest?.sequence, equals(4));

      final sequences = monitor.history.map((e) => e.sequence).toList();
      expect(sequences, equals([2, 3, 4]));

      // 5th evaluation evicts the 2nd
      monitor.evaluateOnce(VGThermalState.nominal);
      expect(monitor.historyLength, equals(3));
      expect(monitor.latest?.sequence, equals(5));

      final updatedSequences = monitor.history.map((e) => e.sequence).toList();
      expect(updatedSequences, equals([3, 4, 5]));
    });

    test('history list is unmodifiable', () {
      final monitor = VGCamera2ThermalLoadSheddingMonitor();
      monitor.evaluateOnce(VGThermalState.fair);

      expect(
        () => monitor.history.add(monitor.latest!),
        throwsUnsupportedError,
      );
      expect(() => monitor.history.clear(), throwsUnsupportedError);
    });
  });

  group('Phase 3-Unit V: Disposal Lifecycle & Post-Disposal Invariants', () {
    test(
      'dispose() is idempotent, closes stream, and marks isDisposed',
      () async {
        final controller = StreamController<VGThermalState>.broadcast();
        final monitor = VGCamera2ThermalLoadSheddingMonitor(
          thermalStates: controller.stream,
        );

        final streamDone = Completer<void>();
        monitor.evaluations.listen((_) {}, onDone: streamDone.complete);

        monitor.start();
        expect(monitor.isRunning, isTrue);

        await monitor.dispose();
        expect(monitor.isDisposed, isTrue);
        expect(monitor.isRunning, isFalse);

        // Second dispose is no-op
        await monitor.dispose();
        expect(monitor.isDisposed, isTrue);

        // Stream should close
        await expectLater(streamDone.future, completes);

        // start() after dispose is no-op
        monitor.start();
        expect(monitor.isRunning, isFalse);

        // updateSessionState after dispose is no-op
        final stateBefore = monitor.sessionState;
        monitor.updateSessionState(wasRecording: true);
        expect(monitor.sessionState, equals(stateBefore));

        await controller.close();
      },
    );

    test(
      'evaluateOnce after dispose returns latest or nominal fallback without emitting',
      () async {
        final monitor = VGCamera2ThermalLoadSheddingMonitor();
        final eval1 = monitor.evaluateOnce(VGThermalState.serious);

        await monitor.dispose();

        // When latest is present, evaluateOnce returns latest
        final postDisposeEval = monitor.evaluateOnce(VGThermalState.critical);
        expect(postDisposeEval, equals(eval1));

        // Fresh disposed monitor without latest returns nominal fallback
        final freshMonitor = VGCamera2ThermalLoadSheddingMonitor();
        await freshMonitor.dispose();
        final fallbackEval = freshMonitor.evaluateOnce(VGThermalState.nominal);
        expect(fallbackEval.diagnostics['disposed'], isTrue);
        expect(fallbackEval.advisoryOnly, isTrue);
        expect(fallbackEval.cameraSessionMutated, isFalse);
      },
    );
  });

  group('Phase 3-Unit V: Serialization, Equality & Hash Codes', () {
    test(
      'VGCamera2ThermalLoadSheddingEvaluation toMap, toJson, equality, and hashCode',
      () {
        final monitor = VGCamera2ThermalLoadSheddingMonitor();
        final eval1 = monitor.evaluateOnce(VGThermalState.serious);

        final map = eval1.toMap();
        expect(map['sequence'], equals(1));
        expect(map['thermalState'], equals('serious'));
        expect(map['input'], isA<Map<String, Object?>>());
        expect(map['plan'], isA<Map<String, Object?>>());
        expect(map['historyLength'], equals(1));
        expect(map['advisoryOnly'], isTrue);
        expect(map['cameraSessionMutated'], isFalse);
        expect(map['captureRequestUpdated'], isFalse);
        expect(map['rendererTouched'], isFalse);
        expect(map['encoderTouched'], isFalse);
        expect(map['diagnostics'], isA<Map<String, Object?>>());

        expect(eval1.toJson(), equals(map));
        expect(
          eval1.toString(),
          contains('VGCamera2ThermalLoadSheddingEvaluation'),
        );

        // Exact clone equality
        final evalClone = VGCamera2ThermalLoadSheddingEvaluation(
          sequence: eval1.sequence,
          thermalState: eval1.thermalState,
          input: eval1.input,
          plan: eval1.plan,
          historyLength: eval1.historyLength,
          advisoryOnly: eval1.advisoryOnly,
          cameraSessionMutated: eval1.cameraSessionMutated,
          captureRequestUpdated: eval1.captureRequestUpdated,
          rendererTouched: eval1.rendererTouched,
          encoderTouched: eval1.encoderTouched,
          diagnostics: Map<String, Object?>.from(eval1.diagnostics),
        );

        expect(eval1, equals(evalClone));
        expect(eval1.hashCode, equals(evalClone.hashCode));
      },
    );
  });
}
