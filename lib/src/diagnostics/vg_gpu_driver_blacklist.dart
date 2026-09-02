// vg_gpu_driver_blacklist.dart
// Vanguard Media Engine - P1-GPU-BLACKLIST
// Deterministic GPU driver blacklist rule evaluator.

import 'package:flutter/foundation.dart';

/// Immutable rule defining a GPU driver blacklist condition.
///
/// Fields mirror the native BlacklistEntry schema in android_backend_probe.cpp:
/// - [vendorId]: GPU vendor ID (e.g. 0x5143 for Qualcomm, 0x13B5 for ARM Mali).
/// - [deviceId]: GPU device ID. A value of 0 acts as a wildcard matching any device.
/// - [driverVersionMin]: Inclusive lower bound on driver version.
/// - [driverVersionMax]: Inclusive upper bound on driver version. 0 means unbounded.
/// - [label]: Identifier token for the blacklist entry.
/// - [reason]: Human-readable diagnosis or root cause description.
@immutable
class VGGpuDriverBlacklistRule {
  /// GPU vendor ID. Must be non-negative.
  final int vendorId;

  /// GPU device ID. 0 matches any device from this vendor. Must be non-negative.
  final int deviceId;

  /// Inclusive minimum driver version. Must be non-negative.
  final int driverVersionMin;

  /// Inclusive maximum driver version. 0 means unbounded. Must be 0 or >= [driverVersionMin].
  final int driverVersionMax;

  /// Identifier token for this blacklist rule. Must not be empty.
  final String label;

  /// Explanation or failure reason for this blacklist rule. Must not be empty.
  final String reason;

  /// Constructs a [VGGpuDriverBlacklistRule] with validation.
  VGGpuDriverBlacklistRule({
    required this.vendorId,
    this.deviceId = 0,
    this.driverVersionMin = 0,
    this.driverVersionMax = 0,
    required this.label,
    required this.reason,
  }) {
    if (vendorId < 0) {
      throw ArgumentError.value(vendorId, 'vendorId', 'Must be non-negative');
    }
    if (deviceId < 0) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Must be non-negative');
    }
    if (driverVersionMin < 0) {
      throw ArgumentError.value(
        driverVersionMin,
        'driverVersionMin',
        'Must be non-negative',
      );
    }
    if (driverVersionMax < 0) {
      throw ArgumentError.value(
        driverVersionMax,
        'driverVersionMax',
        'Must be non-negative',
      );
    }
    if (label.trim().isEmpty) {
      throw ArgumentError.value(label, 'label', 'Must not be empty');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'Must not be empty');
    }
    if (driverVersionMax != 0 && driverVersionMax < driverVersionMin) {
      throw ArgumentError.value(
        driverVersionMax,
        'driverVersionMax',
        'Must be 0 (unbounded) or >= driverVersionMin ($driverVersionMin)',
      );
    }
  }

  /// Evaluates whether the given GPU device parameters match this blacklist rule.
  bool matches({
    required int vendorId,
    required int deviceId,
    required int driverVersion,
  }) {
    if (this.vendorId != vendorId) return false;
    if (this.deviceId != 0 && this.deviceId != deviceId) return false;
    if (driverVersion < driverVersionMin) return false;
    if (driverVersionMax != 0 && driverVersion > driverVersionMax) return false;
    return true;
  }

  /// Serializes this rule to a Map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'vendorId': vendorId,
    'deviceId': deviceId,
    'driverVersionMin': driverVersionMin,
    'driverVersionMax': driverVersionMax,
    'label': label,
    'reason': reason,
  };

  /// Alias for [toMap] for JSON serialization.
  Map<String, dynamic> toJson() => toMap();

  /// Deserializes a [VGGpuDriverBlacklistRule] from a Map.
  factory VGGpuDriverBlacklistRule.fromMap(Map<String, dynamic> map) {
    return VGGpuDriverBlacklistRule(
      vendorId: (map['vendorId'] as num).toInt(),
      deviceId: (map['deviceId'] as num?)?.toInt() ?? 0,
      driverVersionMin: (map['driverVersionMin'] as num?)?.toInt() ?? 0,
      driverVersionMax: (map['driverVersionMax'] as num?)?.toInt() ?? 0,
      label: map['label'] as String? ?? '',
      reason: map['reason'] as String? ?? '',
    );
  }

  /// Deserializes a [VGGpuDriverBlacklistRule] from JSON.
  factory VGGpuDriverBlacklistRule.fromJson(Map<String, dynamic> json) =>
      VGGpuDriverBlacklistRule.fromMap(json);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGGpuDriverBlacklistRule &&
        other.vendorId == vendorId &&
        other.deviceId == deviceId &&
        other.driverVersionMin == driverVersionMin &&
        other.driverVersionMax == driverVersionMax &&
        other.label == label &&
        other.reason == reason;
  }

  @override
  int get hashCode => Object.hash(
    vendorId,
    deviceId,
    driverVersionMin,
    driverVersionMax,
    label,
    reason,
  );

  @override
  String toString() =>
      'VGGpuDriverBlacklistRule(vendorId: 0x${vendorId.toRadixString(16)}, '
      'deviceId: 0x${deviceId.toRadixString(16)}, '
      'driverVersionMin: $driverVersionMin, '
      'driverVersionMax: $driverVersionMax, '
      'label: $label, reason: $reason)';
}

/// Result of evaluating GPU driver parameters against blacklist rules.
@immutable
class VGGpuDriverMatchResult {
  /// Whether any blacklist rule matched.
  final bool matched;

  /// The first matching blacklist rule, or null if clean.
  final VGGpuDriverBlacklistRule? rule;

  /// Label of the matching rule, or 'not_blacklisted' if clean.
  final String label;

  /// Reason of the matching rule, or 'not_blacklisted' if clean.
  final String reason;

  /// Total number of rules evaluated before reaching a decision.
  final int evaluationCount;

  /// Index of the matched rule in the evaluator's rule list, or -1 if clean.
  final int matchedRuleIndex;

  /// Standard constructor.
  const VGGpuDriverMatchResult({
    required this.matched,
    this.rule,
    this.label = 'not_blacklisted',
    this.reason = 'not_blacklisted',
    this.evaluationCount = 0,
    this.matchedRuleIndex = -1,
  });

  /// Constructs a clean (not blacklisted) result.
  const VGGpuDriverMatchResult.clean({this.evaluationCount = 0})
    : matched = false,
      rule = null,
      label = 'not_blacklisted',
      reason = 'not_blacklisted',
      matchedRuleIndex = -1;

  /// Constructs a matched result from a matching rule.
  VGGpuDriverMatchResult.matched({
    required VGGpuDriverBlacklistRule this.rule,
    required this.evaluationCount,
    required this.matchedRuleIndex,
  }) : matched = true,
       label = rule.label,
       reason = rule.reason;

  /// Pre-built constant for not blacklisted with zero evaluations.
  static const notBlacklisted = VGGpuDriverMatchResult.clean();

  /// Serializes this result to a Map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'matched': matched,
    'label': label,
    'reason': reason,
    'evaluationCount': evaluationCount,
    'matchedRuleIndex': matchedRuleIndex,
    if (rule != null) 'rule': rule!.toMap(),
  };

  /// Alias for [toMap] for JSON serialization.
  Map<String, dynamic> toJson() => toMap();

  /// Deserializes a [VGGpuDriverMatchResult] from a Map.
  factory VGGpuDriverMatchResult.fromMap(Map<String, dynamic> map) {
    final ruleMap = map['rule'] as Map<String, dynamic>?;
    return VGGpuDriverMatchResult(
      matched: map['matched'] as bool? ?? false,
      rule: ruleMap != null ? VGGpuDriverBlacklistRule.fromMap(ruleMap) : null,
      label: map['label'] as String? ?? 'not_blacklisted',
      reason: map['reason'] as String? ?? 'not_blacklisted',
      evaluationCount: (map['evaluationCount'] as num?)?.toInt() ?? 0,
      matchedRuleIndex: (map['matchedRuleIndex'] as num?)?.toInt() ?? -1,
    );
  }

  /// Deserializes a [VGGpuDriverMatchResult] from JSON.
  factory VGGpuDriverMatchResult.fromJson(Map<String, dynamic> json) =>
      VGGpuDriverMatchResult.fromMap(json);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGGpuDriverMatchResult &&
        other.matched == matched &&
        other.rule == rule &&
        other.label == label &&
        other.reason == reason &&
        other.evaluationCount == evaluationCount &&
        other.matchedRuleIndex == matchedRuleIndex;
  }

  @override
  int get hashCode => Object.hash(
    matched,
    rule,
    label,
    reason,
    evaluationCount,
    matchedRuleIndex,
  );

  @override
  String toString() =>
      'VGGpuDriverMatchResult(matched: $matched, '
      'label: $label, reason: $reason, '
      'evaluationCount: $evaluationCount, '
      'matchedRuleIndex: $matchedRuleIndex, rule: $rule)';
}

/// Evaluator that maintains ordered blacklist rules and performs deterministic matching.
@immutable
class VGGpuDriverBlacklistEvaluator {
  /// Ordered list of immutable blacklist rules.
  final List<VGGpuDriverBlacklistRule> rules;

  /// Internal const constructor for const empty instances.
  const VGGpuDriverBlacklistEvaluator._({
    this.rules = const <VGGpuDriverBlacklistRule>[],
  });

  /// Constructs an empty evaluator with zero active rules as a const instance.
  const VGGpuDriverBlacklistEvaluator.empty() : this._();

  /// Constructs an evaluator defensively owning an unmodifiable ordered copy of [rules].
  ///
  /// Defaults to empty rules (zero active entries, mirroring native kDriverBlacklist).
  factory VGGpuDriverBlacklistEvaluator({
    Iterable<VGGpuDriverBlacklistRule> rules =
        const <VGGpuDriverBlacklistRule>[],
  }) {
    if (rules.isEmpty) {
      return defaultEvaluator;
    }
    return VGGpuDriverBlacklistEvaluator._(
      rules: List<VGGpuDriverBlacklistRule>.unmodifiable(rules),
    );
  }

  /// Default evaluator instance with zero active rules.
  static const defaultEvaluator = VGGpuDriverBlacklistEvaluator.empty();

  /// Evaluates GPU parameters against the ordered blacklist rules.
  ///
  /// Matches in deterministic registration order:
  /// - vendorId == rule.vendorId
  /// - (rule.deviceId == 0 || rule.deviceId == deviceId)
  /// - driverVersion >= rule.driverVersionMin
  /// - (rule.driverVersionMax == 0 || driverVersion <= rule.driverVersionMax)
  ///
  /// Returns the first matching rule with its index and evaluation count.
  /// Throws [ArgumentError] on negative input values.
  VGGpuDriverMatchResult evaluate({
    required int vendorId,
    required int deviceId,
    required int driverVersion,
  }) {
    if (vendorId < 0) {
      throw ArgumentError.value(vendorId, 'vendorId', 'Must be non-negative');
    }
    if (deviceId < 0) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Must be non-negative');
    }
    if (driverVersion < 0) {
      throw ArgumentError.value(
        driverVersion,
        'driverVersion',
        'Must be non-negative',
      );
    }

    var evalCount = 0;
    for (var i = 0; i < rules.length; i++) {
      evalCount++;
      final rule = rules[i];
      if (rule.matches(
        vendorId: vendorId,
        deviceId: deviceId,
        driverVersion: driverVersion,
      )) {
        return VGGpuDriverMatchResult.matched(
          rule: rule,
          evaluationCount: evalCount,
          matchedRuleIndex: i,
        );
      }
    }

    return VGGpuDriverMatchResult.clean(evaluationCount: evalCount);
  }

  /// Convenience static evaluation method for an arbitrary collection of rules.
  static VGGpuDriverMatchResult evaluateRules({
    required Iterable<VGGpuDriverBlacklistRule> rules,
    required int vendorId,
    required int deviceId,
    required int driverVersion,
  }) {
    final evaluator = VGGpuDriverBlacklistEvaluator(
      rules: List<VGGpuDriverBlacklistRule>.unmodifiable(rules),
    );
    return evaluator.evaluate(
      vendorId: vendorId,
      deviceId: deviceId,
      driverVersion: driverVersion,
    );
  }
}
