// vg_camera2_thermal_load_shedding_policy_test.dart
// vanguard_media_engine — Phase 3-Unit U: Android Camera2 Mid-Recording
// Thermal Load-Shedding Policy & Mitigation Planner Unit Tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const planner = VGCamera2ThermalLoadSheddingPlanner();

  group('Phase 3-Unit U: Export & Enum Contract', () {
    test('VGCamera2ThermalLoadSheddingDecision enum values', () {
      expect(
        VGCamera2ThermalLoadSheddingDecision.values,
        containsAll(<VGCamera2ThermalLoadSheddingDecision>[
          VGCamera2ThermalLoadSheddingDecision.maintain,
          VGCamera2ThermalLoadSheddingDecision.monitor,
          VGCamera2ThermalLoadSheddingDecision.reduceFrameRate,
          VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera,
          VGCamera2ThermalLoadSheddingDecision.stopRecording,
        ]),
      );
      expect(VGCamera2ThermalLoadSheddingDecision.values.length, equals(5));
    });

    test('VGCamera2ThermalLoadSheddingPlan boolean getters', () {
      final planMaintain = planner.evaluate(
        thermalState: VGThermalState.nominal,
      );
      expect(planMaintain.isMaintaining, isTrue);
      expect(planMaintain.isMonitoring, isFalse);
      expect(planMaintain.isReducingFrameRate, isFalse);
      expect(planMaintain.isDroppingSecondaryCamera, isFalse);
      expect(planMaintain.isStoppingRecording, isFalse);

      final planMonitor = planner.evaluate(thermalState: VGThermalState.fair);
      expect(planMonitor.isMaintaining, isFalse);
      expect(planMonitor.isMonitoring, isTrue);
      expect(planMonitor.isReducingFrameRate, isFalse);
      expect(planMonitor.isDroppingSecondaryCamera, isFalse);
      expect(planMonitor.isStoppingRecording, isFalse);

      final planFps = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
      );
      expect(planFps.isMaintaining, isFalse);
      expect(planFps.isMonitoring, isFalse);
      expect(planFps.isReducingFrameRate, isTrue);
      expect(planFps.isDroppingSecondaryCamera, isFalse);
      expect(planFps.isStoppingRecording, isFalse);

      final planDrop = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: true,
      );
      expect(planDrop.isMaintaining, isFalse);
      expect(planDrop.isMonitoring, isFalse);
      expect(planDrop.isReducingFrameRate, isFalse);
      expect(planDrop.isDroppingSecondaryCamera, isTrue);
      expect(planDrop.isStoppingRecording, isFalse);

      final planStop = planner.evaluate(
        thermalState: VGThermalState.critical,
        wasRecording: true,
        hadSecondaryCamera: false,
      );
      expect(planStop.isMaintaining, isFalse);
      expect(planStop.isMonitoring, isFalse);
      expect(planStop.isReducingFrameRate, isFalse);
      expect(planStop.isDroppingSecondaryCamera, isFalse);
      expect(planStop.isStoppingRecording, isTrue);
    });
  });

  group('Phase 3-Unit U: Deterministic Policy Evaluations', () {
    test(
      'nominal: maintain, no notifyDart, no boundary, contract preserved',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.nominal,
          wasRecording: true,
          hadSecondaryCamera: true,
          currentFps: 30,
          currentResolutionScale: 1.0,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.maintain),
        );
        expect(plan.reasons, contains('thermal_nominal'));
        expect(plan.notifyDart, isFalse);
        expect(plan.requiresSafeGraphBoundary, isFalse);
        expect(plan.preservesEncoderContract, isTrue);
        expect(plan.shouldDropSecondaryCamera, isFalse);
        expect(plan.shouldStopRecording, isFalse);
        expect(plan.targetFps, equals(30));
        expect(plan.targetResolutionScale, equals(1.0));
      },
    );

    test('fair: monitor, notifyDart true, no boundary, contract preserved', () {
      final plan = planner.evaluate(
        thermalState: VGThermalState.fair,
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 30,
        currentResolutionScale: 1.0,
      );

      expect(
        plan.decision,
        equals(VGCamera2ThermalLoadSheddingDecision.monitor),
      );
      expect(plan.reasons, contains('thermal_fair_monitor'));
      expect(plan.notifyDart, isTrue);
      expect(plan.requiresSafeGraphBoundary, isFalse);
      expect(plan.preservesEncoderContract, isTrue);
      expect(plan.shouldDropSecondaryCamera, isFalse);
      expect(plan.shouldStopRecording, isFalse);
      expect(plan.targetFps, equals(30));
      expect(plan.targetResolutionScale, equals(1.0));
    });

    test(
      'serious while recording with secondary camera: dropSecondaryCamera at safe boundary',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.serious,
          wasRecording: true,
          hadSecondaryCamera: true,
          currentFps: 30,
          currentResolutionScale: 1.0,
          canPreserveEncoderContract: true,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera),
        );
        expect(plan.reasons, contains('thermal_serious_drop_secondary'));
        expect(plan.notifyDart, isTrue);
        expect(plan.requiresSafeGraphBoundary, isTrue);
        expect(plan.preservesEncoderContract, isTrue);
        expect(plan.shouldDropSecondaryCamera, isTrue);
        expect(plan.shouldStopRecording, isFalse);
        expect(plan.targetFps, equals(30));
        expect(plan.targetResolutionScale, equals(1.0));
      },
    );

    test(
      'serious while recording without secondary camera: reduceFrameRate with targetFps < currentFps',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.serious,
          wasRecording: true,
          hadSecondaryCamera: false,
          currentFps: 30,
          currentResolutionScale: 1.0,
          canPreserveEncoderContract: true,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.reduceFrameRate),
        );
        expect(plan.reasons, contains('thermal_serious_reduce_fps'));
        expect(plan.notifyDart, isTrue);
        expect(plan.requiresSafeGraphBoundary, isTrue);
        expect(plan.preservesEncoderContract, isTrue);
        expect(plan.shouldDropSecondaryCamera, isFalse);
        expect(plan.shouldStopRecording, isFalse);
        expect(plan.targetFps, lessThan(30));
        expect(plan.targetFps, equals(24));
        expect(plan.targetResolutionScale, lessThanOrEqualTo(1.0));
        expect(plan.targetResolutionScale, greaterThan(0.0));
      },
    );

    test(
      'serious while not recording: monitor, notifyDart true, no boundary',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.serious,
          wasRecording: false,
          hadSecondaryCamera: false,
          currentFps: 30,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.monitor),
        );
        expect(plan.reasons, contains('thermal_serious_not_recording'));
        expect(plan.reasons, contains('not_recording_block_new_start'));
        expect(plan.notifyDart, isTrue);
        expect(plan.requiresSafeGraphBoundary, isFalse);
        expect(plan.preservesEncoderContract, isTrue);
        expect(plan.shouldDropSecondaryCamera, isFalse);
        expect(plan.shouldStopRecording, isFalse);
      },
    );

    test(
      'critical while recording with secondary camera and preserved encoder contract: dropSecondaryCamera',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.critical,
          wasRecording: true,
          hadSecondaryCamera: true,
          currentFps: 30,
          canPreserveEncoderContract: true,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera),
        );
        expect(plan.reasons, contains('thermal_critical_drop_secondary'));
        expect(plan.notifyDart, isTrue);
        expect(plan.requiresSafeGraphBoundary, isTrue);
        expect(plan.preservesEncoderContract, isTrue);
        expect(plan.shouldDropSecondaryCamera, isTrue);
        expect(plan.shouldStopRecording, isFalse);
      },
    );

    test(
      'critical while recording with secondary camera but unpreserved encoder contract: stopRecording',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.critical,
          wasRecording: true,
          hadSecondaryCamera: true,
          currentFps: 30,
          canPreserveEncoderContract: false,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.stopRecording),
        );
        expect(plan.reasons, contains('thermal_critical_stop_recording'));
        expect(plan.reasons, contains('encoder_contract_not_preserved'));
        expect(plan.notifyDart, isTrue);
        expect(plan.requiresSafeGraphBoundary, isTrue);
        expect(plan.preservesEncoderContract, isFalse);
        expect(plan.shouldDropSecondaryCamera, isFalse);
        expect(plan.shouldStopRecording, isTrue);
      },
    );

    test(
      'critical while recording without secondary camera: stopRecording and preservesEncoderContract false',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.critical,
          wasRecording: true,
          hadSecondaryCamera: false,
          currentFps: 30,
          canPreserveEncoderContract: true,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.stopRecording),
        );
        expect(plan.reasons, contains('thermal_critical_stop_recording'));
        expect(plan.notifyDart, isTrue);
        expect(plan.requiresSafeGraphBoundary, isTrue);
        expect(plan.preservesEncoderContract, isFalse);
        expect(plan.shouldDropSecondaryCamera, isFalse);
        expect(plan.shouldStopRecording, isTrue);
      },
    );

    test(
      'critical while not recording: maintain/block-new-start advisory without claiming active stop',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.critical,
          wasRecording: false,
          hadSecondaryCamera: true,
          currentFps: 30,
        );

        expect(
          plan.decision,
          equals(VGCamera2ThermalLoadSheddingDecision.maintain),
        );
        expect(plan.reasons, contains('thermal_critical_not_recording'));
        expect(plan.reasons, contains('not_recording_block_new_start'));
        expect(plan.notifyDart, isTrue);
        expect(plan.requiresSafeGraphBoundary, isFalse);
        expect(plan.preservesEncoderContract, isTrue);
        expect(plan.shouldDropSecondaryCamera, isFalse);
        expect(plan.shouldStopRecording, isFalse);
      },
    );
  });

  group('Phase 3-Unit U: FPS Floor and Step-Down Bounds', () {
    test('FPS reduction stepping for various standard rates', () {
      // 60 fps -> 30 fps
      final plan60 = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 60,
      );
      expect(plan60.targetFps, equals(30));

      // 30 fps -> 24 fps
      final plan30 = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 30,
      );
      expect(plan30.targetFps, equals(24));

      // 24 fps -> 15 fps (minFpsFloor)
      final plan24 = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 24,
      );
      expect(plan24.targetFps, equals(15));

      // 15 fps -> 14 fps
      final plan15 = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 15,
      );
      expect(plan15.targetFps, equals(14));

      // 1 fps -> 1 fps floor
      final plan1 = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 1,
      );
      expect(plan1.targetFps, equals(1));
    });

    test('Custom minFpsFloor configuration', () {
      const customPlanner = VGCamera2ThermalLoadSheddingPlanner(
        minFpsFloor: 20,
      );
      final plan24 = customPlanner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 24,
      );
      expect(plan24.targetFps, equals(20));
    });
  });

  group('Phase 3-Unit U: Diagnostics & Non-Claims Contract', () {
    test(
      'All non-claims are false and proofBoundary matches expected string',
      () {
        final plan = planner.evaluate(
          thermalState: VGThermalState.serious,
          wasRecording: true,
          hadSecondaryCamera: true,
        );

        final diag = plan.diagnostics;
        expect(
          diag['proofBoundary'],
          equals(
            'thermal_load_shedding_policy_advisory_no_camera_session_mutation',
          ),
        );
        expect(diag['thermalState'], equals('serious'));
        expect(diag['wasRecording'], isTrue);
        expect(diag['hadSecondaryCamera'], isTrue);

        final nonClaims = Map<String, Object?>.from(
          diag['nonClaims'] as Map<dynamic, dynamic>,
        );
        expect(nonClaims['cameraSessionMutated'], isFalse);
        expect(nonClaims['captureRequestUpdated'], isFalse);
        expect(nonClaims['cameraOpened'], isFalse);
        expect(nonClaims['rendererTouched'], isFalse);
        expect(nonClaims['encoderTouched'], isFalse);
        expect(nonClaims['realForcedOverheat'], isFalse);
      },
    );
  });

  group('Phase 3-Unit U: Value Objects, Serialization & Equality', () {
    test('VGCamera2ThermalLoadSheddingInput toMap, equality and hashCode', () {
      const input1 = VGCamera2ThermalLoadSheddingInput(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 30,
        currentResolutionScale: 1.0,
        canPreserveEncoderContract: true,
      );
      const input2 = VGCamera2ThermalLoadSheddingInput(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 30,
        currentResolutionScale: 1.0,
        canPreserveEncoderContract: true,
      );
      const input3 = VGCamera2ThermalLoadSheddingInput(
        thermalState: VGThermalState.critical,
        wasRecording: true,
      );

      expect(input1, equals(input2));
      expect(input1.hashCode, equals(input2.hashCode));
      expect(input1, isNot(equals(input3)));
      expect(input1.toMap(), isA<Map<String, Object?>>());
      expect(input1.toMap()['thermalState'], equals('serious'));
      expect(input1.toString(), contains('VGCamera2ThermalLoadSheddingInput'));
    });

    test('evaluateInput produces identical plan to evaluate', () {
      const input = VGCamera2ThermalLoadSheddingInput(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 30,
        currentResolutionScale: 1.0,
        canPreserveEncoderContract: true,
      );

      final planA = planner.evaluateInput(input);
      final planB = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 30,
        currentResolutionScale: 1.0,
        canPreserveEncoderContract: true,
      );

      expect(planA, equals(planB));
      expect(planA.hashCode, equals(planB.hashCode));
    });

    test(
      'VGCamera2ThermalLoadSheddingPlan toMap, equality, hashCode and toString',
      () {
        final plan1 = planner.evaluate(
          thermalState: VGThermalState.serious,
          wasRecording: true,
          hadSecondaryCamera: true,
        );
        final plan2 = planner.evaluate(
          thermalState: VGThermalState.serious,
          wasRecording: true,
          hadSecondaryCamera: true,
        );
        final planDifferent = planner.evaluate(
          thermalState: VGThermalState.critical,
          wasRecording: true,
          hadSecondaryCamera: true,
        );

        expect(plan1, equals(plan2));
        expect(plan1.hashCode, equals(plan2.hashCode));
        expect(plan1, isNot(equals(planDifferent)));

        final map = plan1.toMap();
        expect(map['decision'], equals('dropSecondaryCamera'));
        expect(map['thermalState'], equals('serious'));
        expect(map['wasRecording'], isTrue);
        expect(map['hadSecondaryCamera'], isTrue);
        expect(map['notifyDart'], isTrue);
        expect(map['requiresSafeGraphBoundary'], isTrue);
        expect(map['shouldDropSecondaryCamera'], isTrue);
        expect(map['shouldStopRecording'], isFalse);
        expect(map['diagnostics'], isA<Map<String, Object?>>());

        expect(plan1.toString(), contains('VGCamera2ThermalLoadSheddingPlan'));
        expect(plan1.toString(), contains('dropSecondaryCamera'));
      },
    );

    test(
      'VGCamera2ThermalLoadSheddingPlan deep diagnostics equality with nested map and list',
      () {
        const planBase = VGCamera2ThermalLoadSheddingPlan(
          decision: VGCamera2ThermalLoadSheddingDecision.maintain,
          reasons: <String>['thermal_nominal'],
          thermalState: VGThermalState.nominal,
          wasRecording: false,
          hadSecondaryCamera: false,
          currentFps: 30,
          targetFps: 30,
          targetResolutionScale: 1.0,
          notifyDart: false,
          requiresSafeGraphBoundary: false,
          preservesEncoderContract: true,
          shouldDropSecondaryCamera: false,
          shouldStopRecording: false,
          diagnostics: <String, Object?>{
            'nestedMap': <String, Object?>{'keyA': 1, 'keyB': 'val'},
            'nestedList': <Object?>[
              1,
              <String, Object?>{'inner': true},
            ],
          },
        );

        const planIdentical = VGCamera2ThermalLoadSheddingPlan(
          decision: VGCamera2ThermalLoadSheddingDecision.maintain,
          reasons: <String>['thermal_nominal'],
          thermalState: VGThermalState.nominal,
          wasRecording: false,
          hadSecondaryCamera: false,
          currentFps: 30,
          targetFps: 30,
          targetResolutionScale: 1.0,
          notifyDart: false,
          requiresSafeGraphBoundary: false,
          preservesEncoderContract: true,
          shouldDropSecondaryCamera: false,
          shouldStopRecording: false,
          diagnostics: <String, Object?>{
            'nestedMap': <String, Object?>{'keyA': 1, 'keyB': 'val'},
            'nestedList': <Object?>[
              1,
              <String, Object?>{'inner': true},
            ],
          },
        );

        const planDifferentInnerMap = VGCamera2ThermalLoadSheddingPlan(
          decision: VGCamera2ThermalLoadSheddingDecision.maintain,
          reasons: <String>['thermal_nominal'],
          thermalState: VGThermalState.nominal,
          wasRecording: false,
          hadSecondaryCamera: false,
          currentFps: 30,
          targetFps: 30,
          targetResolutionScale: 1.0,
          notifyDart: false,
          requiresSafeGraphBoundary: false,
          preservesEncoderContract: true,
          shouldDropSecondaryCamera: false,
          shouldStopRecording: false,
          diagnostics: <String, Object?>{
            'nestedMap': <String, Object?>{'keyA': 2, 'keyB': 'val'},
            'nestedList': <Object?>[
              1,
              <String, Object?>{'inner': true},
            ],
          },
        );

        const planDifferentInnerList = VGCamera2ThermalLoadSheddingPlan(
          decision: VGCamera2ThermalLoadSheddingDecision.maintain,
          reasons: <String>['thermal_nominal'],
          thermalState: VGThermalState.nominal,
          wasRecording: false,
          hadSecondaryCamera: false,
          currentFps: 30,
          targetFps: 30,
          targetResolutionScale: 1.0,
          notifyDart: false,
          requiresSafeGraphBoundary: false,
          preservesEncoderContract: true,
          shouldDropSecondaryCamera: false,
          shouldStopRecording: false,
          diagnostics: <String, Object?>{
            'nestedMap': <String, Object?>{'keyA': 1, 'keyB': 'val'},
            'nestedList': <Object?>[
              2,
              <String, Object?>{'inner': true},
            ],
          },
        );

        expect(planBase, equals(planIdentical));
        expect(planBase.hashCode, equals(planIdentical.hashCode));
        expect(planBase, isNot(equals(planDifferentInnerMap)));
        expect(planBase, isNot(equals(planDifferentInnerList)));
      },
    );
  });
}
