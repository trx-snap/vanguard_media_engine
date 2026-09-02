// vg_gpu_driver_blacklist_test.dart
// vanguard_media_engine - Phase 1: GPU driver blacklist rule evaluator tests.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGGpuDriverBlacklistRule construction and validation', () {
    test('valid rule constructs with all fields', () {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'qcom_adreno_540_fault',
        reason: 'Crash on vulkan swapchain recreation',
      );

      expect(rule.vendorId, equals(0x5143));
      expect(rule.deviceId, equals(0x0540));
      expect(rule.driverVersionMin, equals(100));
      expect(rule.driverVersionMax, equals(200));
      expect(rule.label, equals('qcom_adreno_540_fault'));
      expect(rule.reason, equals('Crash on vulkan swapchain recreation'));
    });

    test('valid rule constructs with default deviceId and version bounds', () {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x13B5,
        label: 'mali_all_devices',
        reason: 'General Mali instability',
      );

      expect(rule.vendorId, equals(0x13B5));
      expect(rule.deviceId, equals(0));
      expect(rule.driverVersionMin, equals(0));
      expect(rule.driverVersionMax, equals(0));
      expect(rule.label, equals('mali_all_devices'));
      expect(rule.reason, equals('General Mali instability'));
    });

    test('valid rule with max == min succeeds', () {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        driverVersionMin: 150,
        driverVersionMax: 150,
        label: 'single_driver_version',
        reason: 'Specific driver release bug',
      );

      expect(rule.driverVersionMin, equals(150));
      expect(rule.driverVersionMax, equals(150));
    });

    test('valid rule with max == 0 (unbounded) succeeds', () {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        driverVersionMin: 150,
        driverVersionMax: 0,
        label: 'unbounded_driver_version',
        reason: 'All versions from 150 upward',
      );

      expect(rule.driverVersionMin, equals(150));
      expect(rule.driverVersionMax, equals(0));
    });

    test('rejects negative vendorId', () {
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: -1,
          label: 'test',
          reason: 'test',
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative deviceId', () {
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          deviceId: -1,
          label: 'test',
          reason: 'test',
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative driverVersionMin', () {
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          driverVersionMin: -1,
          label: 'test',
          reason: 'test',
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative driverVersionMax', () {
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          driverVersionMax: -1,
          label: 'test',
          reason: 'test',
        ),
        throwsArgumentError,
      );
    });

    test('rejects empty or whitespace label', () {
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          label: '',
          reason: 'test',
        ),
        throwsArgumentError,
      );
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          label: '   ',
          reason: 'test',
        ),
        throwsArgumentError,
      );
    });

    test('rejects empty or whitespace reason', () {
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          label: 'test',
          reason: '',
        ),
        throwsArgumentError,
      );
      expect(
        () => VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          label: 'test',
          reason: '   ',
        ),
        throwsArgumentError,
      );
    });

    test(
      'rejects driverVersionMax < driverVersionMin when max is non-zero',
      () {
        expect(
          () => VGGpuDriverBlacklistRule(
            vendorId: 0x5143,
            driverVersionMin: 200,
            driverVersionMax: 100,
            label: 'test',
            reason: 'test',
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('VGGpuDriverBlacklistRule matching semantics', () {
    final rule = VGGpuDriverBlacklistRule(
      vendorId: 0x5143,
      deviceId: 0x0540,
      driverVersionMin: 100,
      driverVersionMax: 200,
      label: 'qcom_adreno_540',
      reason: 'Adreno 540 driver range 100-200 bug',
    );

    test('matches exact vendor, device, and in-range version', () {
      expect(
        rule.matches(vendorId: 0x5143, deviceId: 0x0540, driverVersion: 150),
        isTrue,
      );
    });

    test('rejects mismatched vendor', () {
      expect(
        rule.matches(vendorId: 0x13B5, deviceId: 0x0540, driverVersion: 150),
        isFalse,
      );
    });

    test('rejects mismatched deviceId', () {
      expect(
        rule.matches(vendorId: 0x5143, deviceId: 0x0630, driverVersion: 150),
        isFalse,
      );
    });

    test('version boundary: below min rejects, exact min matches', () {
      expect(
        rule.matches(vendorId: 0x5143, deviceId: 0x0540, driverVersion: 99),
        isFalse,
      );
      expect(
        rule.matches(vendorId: 0x5143, deviceId: 0x0540, driverVersion: 100),
        isTrue,
      );
    });

    test('version boundary: exact max matches, above max rejects', () {
      expect(
        rule.matches(vendorId: 0x5143, deviceId: 0x0540, driverVersion: 200),
        isTrue,
      );
      expect(
        rule.matches(vendorId: 0x5143, deviceId: 0x0540, driverVersion: 201),
        isFalse,
      );
    });

    test('wildcard deviceId matches any deviceId', () {
      final wildcardRule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersionMin: 50,
        driverVersionMax: 100,
        label: 'qcom_all_devices',
        reason: 'All Qualcomm devices with bad driver',
      );

      expect(
        wildcardRule.matches(
          vendorId: 0x5143,
          deviceId: 0x0540,
          driverVersion: 75,
        ),
        isTrue,
      );
      expect(
        wildcardRule.matches(
          vendorId: 0x5143,
          deviceId: 0x0630,
          driverVersion: 75,
        ),
        isTrue,
      );
      expect(
        wildcardRule.matches(vendorId: 0x5143, deviceId: 0, driverVersion: 75),
        isTrue,
      );
    });

    test('unbounded max matches any version >= min', () {
      final unboundedRule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersionMin: 100,
        driverVersionMax: 0,
        label: 'qcom_unbounded',
        reason: 'All Qualcomm driver versions >= 100',
      );

      expect(
        unboundedRule.matches(
          vendorId: 0x5143,
          deviceId: 0x0540,
          driverVersion: 99,
        ),
        isFalse,
      );
      expect(
        unboundedRule.matches(
          vendorId: 0x5143,
          deviceId: 0x0540,
          driverVersion: 100,
        ),
        isTrue,
      );
      expect(
        unboundedRule.matches(
          vendorId: 0x5143,
          deviceId: 0x0540,
          driverVersion: 999999,
        ),
        isTrue,
      );
    });
  });

  group('VGGpuDriverBlacklistEvaluator behavior', () {
    test('empty rules return clean result with zero evaluationCount', () {
      final evaluator = VGGpuDriverBlacklistEvaluator();
      expect(evaluator.rules, isEmpty);

      final result = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 150,
      );

      expect(result.matched, isFalse);
      expect(result.rule, isNull);
      expect(result.label, equals('not_blacklisted'));
      expect(result.reason, equals('not_blacklisted'));
      expect(result.evaluationCount, equals(0));
      expect(result.matchedRuleIndex, equals(-1));
    });

    test(
      'defaultEvaluator static instance has empty rules and clean result',
      () {
        final result = VGGpuDriverBlacklistEvaluator.defaultEvaluator.evaluate(
          vendorId: 0x13B5,
          deviceId: 0x1234,
          driverVersion: 1,
        );
        expect(result, equals(VGGpuDriverMatchResult.notBlacklisted));
      },
    );

    test('static evaluateRules handles empty and populated rules', () {
      final emptyResult = VGGpuDriverBlacklistEvaluator.evaluateRules(
        rules: const [],
        vendorId: 0x5143,
        deviceId: 0,
        driverVersion: 10,
      );
      expect(emptyResult.matched, isFalse);

      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        label: 'qcom_test',
        reason: 'test reason',
      );
      final matchResult = VGGpuDriverBlacklistEvaluator.evaluateRules(
        rules: [rule],
        vendorId: 0x5143,
        deviceId: 1,
        driverVersion: 10,
      );
      expect(matchResult.matched, isTrue);
      expect(matchResult.label, equals('qcom_test'));
    });

    test('deterministic first-match precedence and evaluationCount', () {
      final rule0 = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'rule_specific_adreno_540',
        reason: 'Specific device rule',
      );
      final rule1 = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersionMin: 50,
        driverVersionMax: 300,
        label: 'rule_wildcard_qcom',
        reason: 'General wildcard rule',
      );
      final rule2 = VGGpuDriverBlacklistRule(
        vendorId: 0x13B5,
        deviceId: 0,
        label: 'rule_mali',
        reason: 'Mali rule',
      );

      final evaluator = VGGpuDriverBlacklistEvaluator(
        rules: [rule0, rule1, rule2],
      );

      // Matches rule 0 on first evaluation
      final res0 = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 150,
      );
      expect(res0.matched, isTrue);
      expect(res0.matchedRuleIndex, equals(0));
      expect(res0.evaluationCount, equals(1));
      expect(res0.label, equals('rule_specific_adreno_540'));
      expect(res0.rule, equals(rule0));

      // Matches rule 1 after evaluating rule 0 and skipping
      final res1 = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0630,
        driverVersion: 150,
      );
      expect(res1.matched, isTrue);
      expect(res1.matchedRuleIndex, equals(1));
      expect(res1.evaluationCount, equals(2));
      expect(res1.label, equals('rule_wildcard_qcom'));
      expect(res1.rule, equals(rule1));

      // Matches rule 2 after evaluating rule 0 and rule 1
      final res2 = evaluator.evaluate(
        vendorId: 0x13B5,
        deviceId: 0x9999,
        driverVersion: 1,
      );
      expect(res2.matched, isTrue);
      expect(res2.matchedRuleIndex, equals(2));
      expect(res2.evaluationCount, equals(3));
      expect(res2.label, equals('rule_mali'));
      expect(res2.rule, equals(rule2));

      // Evaluates all 3 rules and finds no match
      final resNone = evaluator.evaluate(
        vendorId: 0x8086,
        deviceId: 0x0001,
        driverVersion: 50,
      );
      expect(resNone.matched, isFalse);
      expect(resNone.matchedRuleIndex, equals(-1));
      expect(resNone.evaluationCount, equals(3));
      expect(resNone.label, equals('not_blacklisted'));
      expect(resNone.rule, isNull);
    });

    test('reversing rule order switches matched rule index', () {
      final specificRule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        label: 'specific',
        reason: 'specific reason',
      );
      final wildcardRule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0,
        label: 'wildcard',
        reason: 'wildcard reason',
      );

      final evalA = VGGpuDriverBlacklistEvaluator(
        rules: [specificRule, wildcardRule],
      );
      final resA = evalA.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 0,
      );
      expect(resA.label, equals('specific'));
      expect(resA.matchedRuleIndex, equals(0));

      final evalB = VGGpuDriverBlacklistEvaluator(
        rules: [wildcardRule, specificRule],
      );
      final resB = evalB.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 0,
      );
      expect(resB.label, equals('wildcard'));
      expect(resB.matchedRuleIndex, equals(0));
    });

    test('evaluator rejects negative inputs', () {
      final evaluator = VGGpuDriverBlacklistEvaluator();

      expect(
        () => evaluator.evaluate(vendorId: -1, deviceId: 0, driverVersion: 0),
        throwsArgumentError,
      );
      expect(
        () => evaluator.evaluate(
          vendorId: 0x5143,
          deviceId: -1,
          driverVersion: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => evaluator.evaluate(
          vendorId: 0x5143,
          deviceId: 0,
          driverVersion: -1,
        ),
        throwsArgumentError,
      );
    });

    test(
      'mutating input list after construction does not alter evaluation or exposed rules',
      () {
        final rule1 = VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          deviceId: 0x0540,
          driverVersionMin: 100,
          driverVersionMax: 200,
          label: 'initial_rule',
          reason: 'initial reason',
        );
        final mutableList = <VGGpuDriverBlacklistRule>[rule1];
        final evaluator = VGGpuDriverBlacklistEvaluator(rules: mutableList);

        expect(evaluator.rules, equals([rule1]));
        expect(evaluator.rules.length, equals(1));

        // Evaluate before mutation
        final resBefore = evaluator.evaluate(
          vendorId: 0x5143,
          deviceId: 0x0540,
          driverVersion: 150,
        );
        expect(resBefore.matched, isTrue);
        expect(resBefore.label, equals('initial_rule'));

        // Mutate the original list by adding, modifying, and clearing
        final rule2 = VGGpuDriverBlacklistRule(
          vendorId: 0x13B5,
          label: 'added_later',
          reason: 'added reason',
        );
        mutableList.add(rule2);
        mutableList.clear();

        // Evaluator state and rules must remain unaffected
        expect(evaluator.rules.length, equals(1));
        expect(evaluator.rules.first, equals(rule1));

        final resAfter = evaluator.evaluate(
          vendorId: 0x5143,
          deviceId: 0x0540,
          driverVersion: 150,
        );
        expect(resAfter.matched, isTrue);
        expect(resAfter.label, equals('initial_rule'));

        final resMali = evaluator.evaluate(
          vendorId: 0x13B5,
          deviceId: 0,
          driverVersion: 1,
        );
        expect(resMali.matched, isFalse);

        // Exposed rules list is unmodifiable
        expect(
          () => evaluator.rules.add(rule2),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test('const empty constructor creates an empty unmodifiable evaluator', () {
      const emptyEvaluator = VGGpuDriverBlacklistEvaluator.empty();
      expect(emptyEvaluator.rules, isEmpty);
      expect(
        emptyEvaluator.evaluate(
          vendorId: 0x5143,
          deviceId: 0,
          driverVersion: 10,
        ),
        equals(VGGpuDriverMatchResult.notBlacklisted),
      );
    });
  });

  group('Serialization and deserialization roundtrip', () {
    test('VGGpuDriverBlacklistRule toMap/fromMap and JSON roundtrip', () {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'test_rule_label',
        reason: 'test_rule_reason',
      );

      final map = rule.toMap();
      expect(map['vendorId'], equals(0x5143));
      expect(map['deviceId'], equals(0x0540));
      expect(map['driverVersionMin'], equals(100));
      expect(map['driverVersionMax'], equals(200));
      expect(map['label'], equals('test_rule_label'));
      expect(map['reason'], equals('test_rule_reason'));

      final fromMapRule = VGGpuDriverBlacklistRule.fromMap(map);
      expect(fromMapRule, equals(rule));
      expect(fromMapRule.hashCode, equals(rule.hashCode));

      final jsonStr = jsonEncode(rule.toJson());
      final decodedMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final fromJsonRule = VGGpuDriverBlacklistRule.fromJson(decodedMap);
      expect(fromJsonRule, equals(rule));
    });

    test('VGGpuDriverMatchResult clean toMap/fromMap and JSON roundtrip', () {
      const cleanResult = VGGpuDriverMatchResult.clean(evaluationCount: 4);
      final map = cleanResult.toMap();

      expect(map['matched'], isFalse);
      expect(map['label'], equals('not_blacklisted'));
      expect(map['reason'], equals('not_blacklisted'));
      expect(map['evaluationCount'], equals(4));
      expect(map['matchedRuleIndex'], equals(-1));
      expect(map.containsKey('rule'), isFalse);

      final fromMapResult = VGGpuDriverMatchResult.fromMap(map);
      expect(fromMapResult, equals(cleanResult));
      expect(fromMapResult.hashCode, equals(cleanResult.hashCode));

      final jsonStr = jsonEncode(cleanResult.toJson());
      final decodedMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final fromJsonResult = VGGpuDriverMatchResult.fromJson(decodedMap);
      expect(fromJsonResult, equals(cleanResult));
    });

    test('VGGpuDriverMatchResult matched toMap/fromMap and JSON roundtrip', () {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'matched_rule',
        reason: 'matched_reason',
      );
      final matchedResult = VGGpuDriverMatchResult.matched(
        rule: rule,
        evaluationCount: 2,
        matchedRuleIndex: 1,
      );

      final map = matchedResult.toMap();
      expect(map['matched'], isTrue);
      expect(map['label'], equals('matched_rule'));
      expect(map['reason'], equals('matched_reason'));
      expect(map['evaluationCount'], equals(2));
      expect(map['matchedRuleIndex'], equals(1));
      expect(map['rule'], equals(rule.toMap()));

      final fromMapResult = VGGpuDriverMatchResult.fromMap(map);
      expect(fromMapResult, equals(matchedResult));
      expect(fromMapResult.hashCode, equals(matchedResult.hashCode));
      expect(fromMapResult.rule, equals(rule));

      final jsonStr = jsonEncode(matchedResult.toJson());
      final decodedMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final fromJsonResult = VGGpuDriverMatchResult.fromJson(decodedMap);
      expect(fromJsonResult, equals(matchedResult));
      expect(fromJsonResult.rule, equals(rule));
    });
  });

  group('Value equality and toString', () {
    test('rule equality and toString output', () {
      final r1 = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'label',
        reason: 'reason',
      );
      final r2 = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'label',
        reason: 'reason',
      );
      final r3 = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 201,
        label: 'label',
        reason: 'reason',
      );

      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, isNot(equals(r3)));
      expect(r1.toString(), contains('vendorId: 0x5143'));
      expect(r1.toString(), contains('deviceId: 0x540'));
      expect(r1.toString(), contains('label: label'));
    });

    test('match result equality and toString output', () {
      const res1 = VGGpuDriverMatchResult.clean(evaluationCount: 1);
      const res2 = VGGpuDriverMatchResult.clean(evaluationCount: 1);
      const res3 = VGGpuDriverMatchResult.clean(evaluationCount: 2);

      expect(res1, equals(res2));
      expect(res1.hashCode, equals(res2.hashCode));
      expect(res1, isNot(equals(res3)));
      expect(res1.toString(), contains('matched: false'));
      expect(res1.toString(), contains('evaluationCount: 1'));
    });
  });
}
