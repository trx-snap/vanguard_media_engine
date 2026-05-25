// vg_parameter_descriptor.dart
// Vanguard Media Engine — Phase 6C.1A
//
// Pure Dart value types describing a single controllable parameter within a
// VGEffectDescriptor / VGPresetDescriptor.  These are schema-only objects —
// they do not touch the method channel, graph runtime, or native code.
//
// Design rules (Phase 6C / DEC-128):
//   - Feature-agnostic: no story/live/chat/meeting terminology.
//   - Dart-side clamping only: the descriptor clamps values before they reach
//     VGFilterSpec, not after they arrive at native.
//   - VGGraphTransaction (6C.1B) will use these descriptors to batch parameter
//     changes; that wiring is NOT part of this file.
//
// Serialisation:
//   toJson() produces a human-readable map for debugging / logging.
//   It is NOT the VGFilterSpec transport shape — that lives in VGFilterSpec.

// ─────────────────────────────────────────────────────────────────────────────
// VGParameterType
// ─────────────────────────────────────────────────────────────────────────────

/// The value type of a [VGParameterDescriptor].
///
/// Used to validate incoming values in [VGParameterDescriptor.clamp] and to
/// drive future UI control selection.
enum VGParameterType {
  /// A `double` (floating-point) parameter.  Supports numeric [VGParameterDescriptor.minValue]
  /// and [VGParameterDescriptor.maxValue] clamping.
  doubleValue,

  /// An `int` (integer) parameter.  Supports numeric [VGParameterDescriptor.minValue]
  /// and [VGParameterDescriptor.maxValue] clamping.
  intValue,

  /// A `bool` parameter.  Clamping is a type-check only; no numeric range applies.
  boolValue,

  /// A `String` parameter.  Clamping is a type-check only; no numeric range applies.
  stringValue,
}

// ─────────────────────────────────────────────────────────────────────────────
// VGParameterApplyPolicy
// ─────────────────────────────────────────────────────────────────────────────

/// Specifies when a changed parameter value should be applied to the native
/// graph.
///
/// Used by [VGGraphTransaction] (Phase 6C.1B) to decide whether a pending
/// change requires an immediate dispatch or can be deferred.
enum VGParameterApplyPolicy {
  /// Apply immediately on the next rendered frame.  Suitable for continuous
  /// slider updates (e.g. beauty intensity).
  hot,

  /// Apply at the next natural graph tick / parameter flush.  Suitable for
  /// values that change infrequently and need a brief settle time.
  warm,

  /// Apply only when the graph is being (re-)prepared / assembled, not during
  /// live playback.  Suitable for structural parameters (e.g. LUT asset path).
  prepare,
}

// ─────────────────────────────────────────────────────────────────────────────
// VGParameterDescriptor
// ─────────────────────────────────────────────────────────────────────────────

/// Describes a single controllable parameter within a [VGEffectDescriptor].
///
/// [VGParameterDescriptor] is a pure value object — it carries metadata
/// (type, range, policy) but does not hold a live value.  Callers pass the
/// descriptor's [clamp] output to [VGFilterSpec] parameters.
///
/// ```dart
/// final desc = VGParameterDescriptor(
///   name: 'intensity',
///   type: VGParameterType.doubleValue,
///   defaultValue: 1.0,
///   minValue: 0.0,
///   maxValue: 1.0,
///   applyPolicy: VGParameterApplyPolicy.hot,
/// );
///
/// final safe = desc.clamp(1.5); // → 1.0
/// ```
final class VGParameterDescriptor {
  /// Creates a parameter descriptor.
  ///
  /// [name] must be non-empty and must match the key used in
  /// [VGFilterSpec.parameters].
  ///
  /// If both [minValue] and [maxValue] are provided, [minValue] must be ≤
  /// [maxValue]; otherwise an [ArgumentError] is thrown.
  VGParameterDescriptor({
    required this.name,
    required this.type,
    required this.defaultValue,
    this.minValue,
    this.maxValue,
    this.applyPolicy = VGParameterApplyPolicy.hot,
  }) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    if (minValue != null && maxValue != null && minValue! > maxValue!) {
      throw ArgumentError(
        'VGParameterDescriptor "$name": '
        'minValue ($minValue) must be ≤ maxValue ($maxValue)',
      );
    }
  }

  /// The parameter name.  Must match the key used in [VGFilterSpec.parameters].
  final String name;

  /// The expected value type.
  final VGParameterType type;

  /// The value used when no caller-supplied value is present.
  final dynamic defaultValue;

  /// Optional inclusive lower bound (applies to [VGParameterType.doubleValue]
  /// and [VGParameterType.intValue] only).
  final num? minValue;

  /// Optional inclusive upper bound (applies to [VGParameterType.doubleValue]
  /// and [VGParameterType.intValue] only).
  final num? maxValue;

  /// When a changed value should be dispatched to the native graph.
  final VGParameterApplyPolicy applyPolicy;

  // ── Clamping ────────────────────────────────────────────────────────────────

  /// Returns [value] clamped to this descriptor's range and type.
  ///
  /// For [VGParameterType.doubleValue]:
  ///   - [value] must be a [num]; it is converted to `double` then clamped.
  ///
  /// For [VGParameterType.intValue]:
  ///   - [value] must be a [num]; it is converted to `int` (truncated) then
  ///     clamped.
  ///
  /// For [VGParameterType.boolValue]:
  ///   - [value] must be a [bool]; no numeric clamping occurs.
  ///
  /// For [VGParameterType.stringValue]:
  ///   - [value] must be a [String]; no numeric clamping occurs.
  ///
  /// Throws [ArgumentError] if [value] is of an incompatible runtime type.
  dynamic clamp(dynamic value) {
    switch (type) {
      case VGParameterType.doubleValue:
        if (value is! num) {
          throw ArgumentError.value(
            value,
            'value',
            'VGParameterDescriptor "$name" expects a num for doubleValue; '
                'got ${value.runtimeType}',
          );
        }
        double d = value.toDouble();
        if (minValue != null && d < minValue!) d = minValue!.toDouble();
        if (maxValue != null && d > maxValue!) d = maxValue!.toDouble();
        return d;

      case VGParameterType.intValue:
        if (value is! num) {
          throw ArgumentError.value(
            value,
            'value',
            'VGParameterDescriptor "$name" expects a num for intValue; '
                'got ${value.runtimeType}',
          );
        }
        int i = value.toInt();
        if (minValue != null && i < minValue!) i = minValue!.toInt();
        if (maxValue != null && i > maxValue!) i = maxValue!.toInt();
        return i;

      case VGParameterType.boolValue:
        if (value is! bool) {
          throw ArgumentError.value(
            value,
            'value',
            'VGParameterDescriptor "$name" expects a bool for boolValue; '
                'got ${value.runtimeType}',
          );
        }
        return value;

      case VGParameterType.stringValue:
        if (value is! String) {
          throw ArgumentError.value(
            value,
            'value',
            'VGParameterDescriptor "$name" expects a String for stringValue; '
                'got ${value.runtimeType}',
          );
        }
        return value;
    }
  }

  // ── Serialisation ───────────────────────────────────────────────────────────

  /// Returns a debug/logging map for this descriptor.
  ///
  /// This is NOT the [VGFilterSpec] transport shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'type': type.name,
    'defaultValue': defaultValue,
    if (minValue != null) 'minValue': minValue,
    if (maxValue != null) 'maxValue': maxValue,
    'applyPolicy': applyPolicy.name,
  };

  @override
  String toString() =>
      'VGParameterDescriptor(name: $name, type: ${type.name}, '
      'default: $defaultValue, min: $minValue, max: $maxValue, '
      'policy: ${applyPolicy.name})';
}
