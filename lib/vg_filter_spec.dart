// vg_filter_spec.dart
// Vanguard Media Engine — Phase 3 Step P3-5
//
// Transport-safe value type describing a single filter in a filter chain.
//
// Design rules (DEC-42 / P3-5):
//   - Dart expresses intent only. Native owns graph assembly.
//   - No native node IDs, class names, or graph/runtime concepts exposed here.
//   - `type` is a free-form string key agreed between Dart and the native plugin
//     (e.g. 'lut', 'beauty', 'segmentation'). Native resolves this to a node class.
//   - `parameters` is an open map so callers can pass filter-specific tuning
//     values (e.g. intensity, radius) without requiring a new Dart class per filter.
//
// Simplification vs DEC-42 sealed-class design:
//   DEC-42 originally specified named constructors (`VGFilterSpec.lut(...)`,
//   `VGFilterSpec.beauty(...)`, `VGFilterSpec.segmentation(...)`). P3-5 adopts
//   a flat type+parameters representation instead, which avoids proliferating
//   Dart classes before the native API stabilises. The sealed-class form can be
//   layered on top in Phase 4 once the parameter contract is finalised.
//
// Serialisation:
//   `toJson()` produces the canonical payload map expected by the native handler:
//   { 'type': String, 'enabled': bool, 'parameters': Map<String, Object?> }

/// A transport-safe description of a single GPU filter in a [VGPlaybackSession]
/// filter chain.
///
/// Pass a list of [VGFilterSpec] to [VGPlaybackSession.setFilterChain] to
/// configure the filter pipeline for a session. The native side assembles the
/// actual [VGMetalFilterNode] graph from the received specs — Dart never
/// references native node types directly.
///
/// ```dart
/// await session.setFilterChain([
///   VGFilterSpec(type: 'lut',  parameters: {'intensity': 0.8}),
///   VGFilterSpec(type: 'beauty', parameters: {'intensity': 0.5, 'radius': 3.0}),
/// ]);
/// ```
final class VGFilterSpec {
  /// Creates a filter spec.
  ///
  /// [type] is a string key identifying the filter kind, e.g. `'lut'`,
  /// `'beauty'`, `'segmentation'`. The native plugin maps this to a concrete
  /// filter node class — do not use native class names here.
  ///
  /// [enabled] controls whether the filter is applied. Defaults to `true`.
  ///
  /// [parameters] is a freeform map of filter-specific tuning values.
  /// All values must be JSON-serialisable (`String`, `num`, `bool`, `null`,
  /// `List<Object?>`, or `Map<String, Object?>`).
  const VGFilterSpec({
    required this.type,
    this.enabled = true,
    this.parameters = const <String, Object?>{},
  });

  /// The filter kind. Examples: `'lut'`, `'beauty'`, `'segmentation'`.
  ///
  /// The native plugin resolves this string to a concrete filter node. If the
  /// native side does not recognise the type, the filter is silently skipped.
  final String type;

  /// Whether this filter is active. When `false` the filter node is installed
  /// but passes frames through unchanged (enabled = NO on native side).
  ///
  /// Defaults to `true`.
  final bool enabled;

  /// Filter-specific tuning parameters.
  ///
  /// Common keys by filter type:
  /// - `'lut'`          → `'intensity'` (double, 0.0–1.0)
  /// - `'beauty'`       → `'intensity'` (double, 0.0–1.0), `'radius'` (double)
  /// - `'segmentation'` → (none in Phase 3; reserved for Phase 4)
  ///
  /// Values must be JSON-serialisable. The map is passed through to native
  /// verbatim; native ignores unknown keys.
  final Map<String, Object?> parameters;

  /// Serialises this spec to a JSON-compatible map suitable for sending over
  /// the Flutter method channel.
  ///
  /// Output shape:
  /// ```json
  /// { "type": "lut", "enabled": true, "parameters": { "intensity": 0.8 } }
  /// ```
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'enabled': enabled,
    'parameters': parameters,
  };

  @override
  String toString() =>
      'VGFilterSpec(type: $type, enabled: $enabled, parameters: $parameters)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGFilterSpec &&
          other.type == type &&
          other.enabled == enabled &&
          _mapEquals(other.parameters, parameters);

  @override
  int get hashCode => Object.hash(
    type,
    enabled,
    Object.hashAll(parameters.entries.map((e) => Object.hash(e.key, e.value))),
  );
}

/// Deep equality for the [VGFilterSpec.parameters] map.
/// Only compares one level — nested collections are compared by reference.
bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || b[key] != a[key]) return false;
  }
  return true;
}
