// vg_effect_catalog.dart
// Vanguard Media Engine — Phase 6C.1A
//
// Registry of known filter types and their parameter descriptors.
//
// Design rules (Phase 6C / DEC-128):
//   - Feature-agnostic: keys match _validTypes in vg_filter_spec.dart exactly.
//   - Catalog entries cover only parameters already understood by the native
//     plugin (i.e. keys present in VGFilterSpecs factories).
//   - No product-specific (story/live/meeting/chat) parameter names.
//   - VGEffectCatalog is a static registry — it carries no mutable state.
//   - This file does not import or touch method channels.

import 'vg_parameter_descriptor.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VGEffectDescriptor
// ─────────────────────────────────────────────────────────────────────────────

/// Describes a single filter effect type and its known parameters.
///
/// Instances are produced by [VGEffectCatalog] and are immutable.
final class VGEffectDescriptor {
  /// Creates an effect descriptor.
  ///
  /// [type] must match a native-recognised filter type string (e.g. `'lut'`,
  /// `'beauty'`, `'segmentation'`).
  ///
  /// [parameters] maps parameter names to their [VGParameterDescriptor].
  /// An empty map is valid for effects that have no tunable parameters.
  const VGEffectDescriptor({required this.type, required this.parameters});

  /// The filter kind.  Matches [VGFilterSpec.type].
  final String type;

  /// All known parameters for this effect, keyed by parameter name.
  final Map<String, VGParameterDescriptor> parameters;

  // ── Lookup ──────────────────────────────────────────────────────────────────

  /// Returns the descriptor for [name], or `null` if not registered.
  VGParameterDescriptor? parameter(String name) => parameters[name];

  // ── Serialisation ───────────────────────────────────────────────────────────

  /// Returns a debug/logging map for this descriptor.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'parameters': parameters.map((k, v) => MapEntry(k, v.toJson())),
  };

  @override
  String toString() =>
      'VGEffectDescriptor(type: $type, parameters: ${parameters.keys.toList()})';
}

// ─────────────────────────────────────────────────────────────────────────────
// VGEffectCatalog
// ─────────────────────────────────────────────────────────────────────────────

/// Static registry of all native-recognised filter effects and their
/// parameter schemas.
///
/// Covers the three effect types currently in `_validTypes` in
/// `vg_filter_spec.dart`: `lut`, `beauty`, and `segmentation`.
///
/// ```dart
/// final desc = VGEffectCatalog.effect('beauty');
/// final param = VGEffectCatalog.parameter('beauty', 'intensity');
/// final safe  = param?.clamp(1.5); // → 1.0
/// ```
abstract final class VGEffectCatalog {
  // ── Internal catalog ────────────────────────────────────────────────────────

  static final Map<String, VGEffectDescriptor> _catalog = Map.unmodifiable(
    <String, VGEffectDescriptor>{
      'lut': VGEffectDescriptor(
        type: 'lut',
        parameters: Map.unmodifiable(<String, VGParameterDescriptor>{
          // intensity: blend between identity and the loaded LUT [0.0, 1.0].
          'intensity': VGParameterDescriptor(
            name: 'intensity',
            type: VGParameterType.doubleValue,
            defaultValue: 1.0,
            minValue: 0.0,
            maxValue: 1.0,
            applyPolicy: VGParameterApplyPolicy.hot,
          ),
        }),
      ),

      'beauty': VGEffectDescriptor(
        type: 'beauty',
        parameters: Map.unmodifiable(<String, VGParameterDescriptor>{
          // intensity: sigma_color in the bilateral kernel [0.0, 1.0].
          'intensity': VGParameterDescriptor(
            name: 'intensity',
            type: VGParameterType.doubleValue,
            defaultValue: 1.0,
            minValue: 0.0,
            maxValue: 1.0,
            applyPolicy: VGParameterApplyPolicy.hot,
          ),
          // radius: kernel half-size in pixels [1, 4] (V1 bilateral).
          'radius': VGParameterDescriptor(
            name: 'radius',
            type: VGParameterType.doubleValue,
            defaultValue: 2.0,
            minValue: 1.0,
            maxValue: 4.0,
            applyPolicy: VGParameterApplyPolicy.warm,
          ),
          // beautyVersion: 1 = V1 (production), 2 = V2 (dev/test).
          'beautyVersion': VGParameterDescriptor(
            name: 'beautyVersion',
            type: VGParameterType.intValue,
            defaultValue: 1,
            minValue: 1,
            maxValue: 2,
            applyPolicy: VGParameterApplyPolicy.prepare,
          ),
          // faceAwareEnabled: enables Vision face detection + skin mask (V2).
          'faceAwareEnabled': VGParameterDescriptor(
            name: 'faceAwareEnabled',
            type: VGParameterType.boolValue,
            defaultValue: false,
            applyPolicy: VGParameterApplyPolicy.warm,
          ),
        }),
      ),

      // segmentation has no tunable parameters in Phase 3/4/6.
      'segmentation': VGEffectDescriptor(
        type: 'segmentation',
        parameters: Map.unmodifiable(<String, VGParameterDescriptor>{}),
      ),
    },
  );

  // ── Public API ──────────────────────────────────────────────────────────────

  /// All registered effect descriptors, keyed by effect type string.
  ///
  /// The returned map is unmodifiable.
  static Map<String, VGEffectDescriptor> get effects => _catalog;

  /// Returns the [VGEffectDescriptor] for [type], or `null` if not registered.
  static VGEffectDescriptor? effect(String type) => _catalog[type];

  /// Returns the [VGParameterDescriptor] for [parameterName] within
  /// [effectType], or `null` if the effect or parameter is not registered.
  static VGParameterDescriptor? parameter(
    String effectType,
    String parameterName,
  ) => _catalog[effectType]?.parameters[parameterName];

  /// Returns `true` if [type] is a registered effect type.
  static bool supportsEffect(String type) => _catalog.containsKey(type);

  /// Returns `true` if [effectType] is registered and has a parameter named
  /// [parameterName].
  static bool supportsParameter(String effectType, String parameterName) =>
      _catalog[effectType]?.parameters.containsKey(parameterName) ?? false;
}
