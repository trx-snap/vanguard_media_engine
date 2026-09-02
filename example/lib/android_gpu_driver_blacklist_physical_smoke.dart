// android_gpu_driver_blacklist_physical_smoke.dart
// Vanguard Media Engine - P1-GPU-BLACKLIST-RULE-EVALUATOR
// Android GPU Driver Blacklist Rule Evaluator physical smoke harness.
//
// Pure Dart verification on physical Android device.
// Zero MethodChannel calls, zero file I/O, zero native state mutation.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidGpuDriverBlacklistPhysicalSmokeApp());
}

class AndroidGpuDriverBlacklistPhysicalSmokeApp extends StatefulWidget {
  const AndroidGpuDriverBlacklistPhysicalSmokeApp({super.key});

  @override
  State<AndroidGpuDriverBlacklistPhysicalSmokeApp> createState() =>
      _AndroidGpuDriverBlacklistPhysicalSmokeAppState();
}

class _AndroidGpuDriverBlacklistPhysicalSmokeAppState
    extends State<AndroidGpuDriverBlacklistPhysicalSmokeApp> {
  String _status =
      'Initializing Android GPU Driver Blacklist physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE1_GPU_BLACKLIST_RULE_EVALUATOR_SMOKE_START');
    final results = <String, bool>{};

    // Lane 1: Empty rules clean result
    try {
      final evaluator = VGGpuDriverBlacklistEvaluator();
      final res = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 100,
      );
      final pass =
          !res.matched &&
          res.rule == null &&
          res.label == 'not_blacklisted' &&
          res.reason == 'not_blacklisted' &&
          res.evaluationCount == 0 &&
          res.matchedRuleIndex == -1;
      results['lane_1_empty_rules_clean'] = pass;
    } catch (e) {
      results['lane_1_empty_rules_clean'] = false;
    }

    // Lane 2: Vendor mismatch
    try {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        label: 'qcom_only',
        reason: 'Qualcomm only',
      );
      final evaluator = VGGpuDriverBlacklistEvaluator(rules: [rule]);
      final res = evaluator.evaluate(
        vendorId: 0x13B5,
        deviceId: 0x0100,
        driverVersion: 50,
      );
      final pass =
          !res.matched &&
          res.rule == null &&
          res.label == 'not_blacklisted' &&
          res.evaluationCount == 1 &&
          res.matchedRuleIndex == -1;
      results['lane_2_vendor_mismatch'] = pass;
    } catch (e) {
      results['lane_2_vendor_mismatch'] = false;
    }

    // Lane 3: Specific device match vs mismatch
    try {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        label: 'adreno_540',
        reason: 'Specific device fault',
      );
      final evaluator = VGGpuDriverBlacklistEvaluator(rules: [rule]);
      final matchRes = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 50,
      );
      final mismatchRes = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0630,
        driverVersion: 50,
      );
      final pass =
          matchRes.matched &&
          matchRes.label == 'adreno_540' &&
          matchRes.matchedRuleIndex == 0 &&
          !mismatchRes.matched &&
          mismatchRes.matchedRuleIndex == -1;
      results['lane_3_specific_device'] = pass;
    } catch (e) {
      results['lane_3_specific_device'] = false;
    }

    // Lane 4: Wildcard device match
    try {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0,
        label: 'qcom_wildcard',
        reason: 'All devices match',
      );
      final evaluator = VGGpuDriverBlacklistEvaluator(rules: [rule]);
      final resA = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 1,
      );
      final resB = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0630,
        driverVersion: 1,
      );
      final pass = resA.matched && resB.matched;
      results['lane_4_wildcard_device'] = pass;
    } catch (e) {
      results['lane_4_wildcard_device'] = false;
    }

    // Lane 5: Version bounds check (min, mid, max, above, unbounded)
    try {
      final boundedRule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'bounded',
        reason: 'bounded 100-200',
      );
      final unboundedRule = VGGpuDriverBlacklistRule(
        vendorId: 0x13B5,
        driverVersionMin: 100,
        driverVersionMax: 0,
        label: 'unbounded',
        reason: 'unbounded >= 100',
      );
      final evaluator = VGGpuDriverBlacklistEvaluator(
        rules: [boundedRule, unboundedRule],
      );

      final belowMin = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersion: 99,
      );
      final exactMin = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersion: 100,
      );
      final mid = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersion: 150,
      );
      final exactMax = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersion: 200,
      );
      final aboveMax = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0,
        driverVersion: 201,
      );
      final unboundedFar = evaluator.evaluate(
        vendorId: 0x13B5,
        deviceId: 0,
        driverVersion: 999999,
      );

      final pass =
          !belowMin.matched &&
          exactMin.matched &&
          mid.matched &&
          exactMax.matched &&
          !aboveMax.matched &&
          unboundedFar.matched &&
          unboundedFar.label == 'unbounded';
      results['lane_5_version_bounds'] = pass;
    } catch (e) {
      results['lane_5_version_bounds'] = false;
    }

    // Lane 6: Deterministic rule precedence & evaluation count
    try {
      final specificRule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        label: 'specific_rule',
        reason: 'specific',
      );
      final wildcardRule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0,
        label: 'wildcard_rule',
        reason: 'wildcard',
      );
      final evaluator = VGGpuDriverBlacklistEvaluator(
        rules: [specificRule, wildcardRule],
      );

      final resSpecific = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersion: 0,
      );
      final resWildcard = evaluator.evaluate(
        vendorId: 0x5143,
        deviceId: 0x0630,
        driverVersion: 0,
      );

      final pass =
          resSpecific.matched &&
          resSpecific.matchedRuleIndex == 0 &&
          resSpecific.evaluationCount == 1 &&
          resSpecific.label == 'specific_rule' &&
          resWildcard.matched &&
          resWildcard.matchedRuleIndex == 1 &&
          resWildcard.evaluationCount == 2 &&
          resWildcard.label == 'wildcard_rule';
      results['lane_6_rule_precedence'] = pass;
    } catch (e) {
      results['lane_6_rule_precedence'] = false;
    }

    // Lane 7: Rejection of negative inputs and invalid rule configurations
    try {
      final evaluator = VGGpuDriverBlacklistEvaluator();
      var threwEvalNeg = false;
      try {
        evaluator.evaluate(vendorId: -1, deviceId: 0, driverVersion: 0);
      } on ArgumentError {
        threwEvalNeg = true;
      }

      var threwRuleInvalid = false;
      try {
        VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          driverVersionMin: 200,
          driverVersionMax: 100,
          label: 'invalid',
          reason: 'invalid',
        );
      } on ArgumentError {
        threwRuleInvalid = true;
      }

      var threwEmptyLabel = false;
      try {
        VGGpuDriverBlacklistRule(
          vendorId: 0x5143,
          label: '',
          reason: 'valid reason',
        );
      } on ArgumentError {
        threwEmptyLabel = true;
      }

      final pass = threwEvalNeg && threwRuleInvalid && threwEmptyLabel;
      results['lane_7_rejection_validation'] = pass;
    } catch (e) {
      results['lane_7_rejection_validation'] = false;
    }

    // Lane 8: JSON and Map roundtrip serialization fidelity
    try {
      final rule = VGGpuDriverBlacklistRule(
        vendorId: 0x5143,
        deviceId: 0x0540,
        driverVersionMin: 100,
        driverVersionMax: 200,
        label: 'rule_serialized',
        reason: 'reason_serialized',
      );
      final matchResult = VGGpuDriverMatchResult.matched(
        rule: rule,
        evaluationCount: 3,
        matchedRuleIndex: 2,
      );

      final ruleJson = jsonEncode(rule.toJson());
      final ruleDecoded = VGGpuDriverBlacklistRule.fromJson(
        jsonDecode(ruleJson) as Map<String, dynamic>,
      );

      final matchJson = jsonEncode(matchResult.toJson());
      final matchDecoded = VGGpuDriverMatchResult.fromJson(
        jsonDecode(matchJson) as Map<String, dynamic>,
      );

      final pass =
          ruleDecoded == rule &&
          matchDecoded == matchResult &&
          matchDecoded.rule == rule &&
          matchDecoded.matchedRuleIndex == 2;
      results['lane_8_serialization_roundtrip'] = pass;
    } catch (e) {
      results['lane_8_serialization_roundtrip'] = false;
    }

    final passedCount = results.values.where((v) => v).length;
    final totalCount = results.length;
    final allPass = totalCount == 8 && passedCount == 8;

    print(
      'ANDROID_DAG_PHASE1_GPU_BLACKLIST_RULE_EVALUATOR_JSON:${jsonEncode(<String, Object?>{'totalLanes': totalCount, 'passedLanes': passedCount, 'allPass': allPass, 'results': results})}',
    );

    print(
      'ANDROID_DAG_PHASE1_GPU_BLACKLIST_RULE_EVALUATOR_SUMMARY: $passedCount/$totalCount lanes passed',
    );

    print(
      allPass
          ? 'ANDROID_DAG_PHASE1_GPU_BLACKLIST_RULE_EVALUATOR_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1_GPU_BLACKLIST_RULE_EVALUATOR_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS ($passedCount/$totalCount GPU blacklist evaluator lanes verified)'
            : 'FAIL ($passedCount/$totalCount GPU blacklist evaluator lanes passed)';
      });
    }

    await Future<void>.delayed(const Duration(seconds: 2));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text(
            'GPU Blacklist Rule Evaluator Smoke (P1-GPU-BLACKLIST)',
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
