// vg_preset_descriptor.dart
// Vanguard Media Engine — Phase 6C.1A
//
// A named, composable snapshot of a VGFilterSpec stack that can be saved,
// serialised, and later applied as a unit.
//
// Design rules (Phase 6C / DEC-128):
//   - Pure value object: no method channel, no runtime graph interaction.
//   - Stores a defensive immutable copy of the caller-supplied filter stack.
//   - toJson() uses the existing VGFilterSpec.toJson() transport shape so the
//     serialised form can be replayed through VGCameraSession.setFilterChain()
//     without any new wire protocol.
//   - fromJson() is provided because it is straightforward and fully tested.
//   - Feature-agnostic: id/name are free-form strings chosen by the caller.

import 'vg_filter_spec.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VGPresetDescriptor
// ─────────────────────────────────────────────────────────────────────────────

/// A named snapshot of an ordered [VGFilterSpec] stack.
///
/// Presets allow callers to define a reusable filter configuration that can be
/// serialised, stored, and later re-applied to a camera or playback session via
/// [VGCameraSession.setFilterChain].
///
/// ```dart
/// final preset = VGPresetDescriptor(
///   id: 'portrait-soft',
///   name: 'Portrait Soft',
///   filterStack: [
///     VGFilterSpecs.beauty(intensity: 0.6),
///     VGFilterSpecs.lut(intensity: 0.4),
///   ],
/// );
///
/// // Re-apply:
/// await session.setFilterChain(preset.filterStack);
///
/// // Round-trip:
/// final json  = preset.toJson();
/// final clone = VGPresetDescriptor.fromJson(json);
/// ```
final class VGPresetDescriptor {
  /// Creates a preset descriptor.
  ///
  /// [id] and [name] must be non-empty.
  ///
  /// [filterStack] is copied defensively; mutations to the original list after
  /// construction do not affect this preset.
  VGPresetDescriptor({
    required this.id,
    required this.name,
    required List<VGFilterSpec> filterStack,
  }) : filterStack = List.unmodifiable(filterStack) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
  }

  /// Unique identifier for this preset. Chosen by the caller; opaque to native.
  final String id;

  /// Human-readable display name.
  final String name;

  /// Ordered, immutable filter stack.  Apply with
  /// [VGCameraSession.setFilterChain].
  final List<VGFilterSpec> filterStack;

  // ── Serialisation ───────────────────────────────────────────────────────────

  /// Serialises this preset to a JSON-compatible map.
  ///
  /// The `filterStack` entries use the canonical [VGFilterSpec.toJson] shape:
  /// ```json
  /// {
  ///   "id": "portrait-soft",
  ///   "name": "Portrait Soft",
  ///   "filterStack": [
  ///     { "type": "beauty", "enabled": true, "parameters": { "intensity": 0.6 } },
  ///     { "type": "lut",    "enabled": true, "parameters": { "intensity": 0.4 } }
  ///   ]
  /// }
  /// ```
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'filterStack': filterStack.map((f) => f.toJson()).toList(),
  };

  // ── Deserialisation ─────────────────────────────────────────────────────────

  /// Reconstructs a [VGPresetDescriptor] from a JSON-compatible map.
  ///
  /// Expects the same shape produced by [toJson].
  ///
  /// Throws [ArgumentError] if required keys (`id`, `name`, `filterStack`) are
  /// missing or if any entry in `filterStack` is missing a `type` key.
  factory VGPresetDescriptor.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError(
        'VGPresetDescriptor.fromJson: "id" must be a non-empty String',
      );
    }
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw ArgumentError(
        'VGPresetDescriptor.fromJson: "name" must be a non-empty String',
      );
    }
    final rawStack = json['filterStack'];
    if (rawStack is! List) {
      throw ArgumentError(
        'VGPresetDescriptor.fromJson: "filterStack" must be a List',
      );
    }
    final stack = rawStack.map((entry) {
      if (entry is! Map) {
        throw ArgumentError(
          'VGPresetDescriptor.fromJson: filterStack entry must be a Map',
        );
      }
      final m = Map<String, Object?>.from(entry);
      final type = m['type'];
      if (type is! String || type.isEmpty) {
        throw ArgumentError(
          'VGPresetDescriptor.fromJson: filterStack entry missing "type"',
        );
      }
      final enabled = m['enabled'];
      final parameters = m['parameters'];
      return VGFilterSpec(
        type: type,
        enabled: enabled is bool ? enabled : true,
        parameters: parameters is Map
            ? Map<String, Object?>.from(parameters)
            : const <String, Object?>{},
      );
    }).toList();

    return VGPresetDescriptor(id: id, name: name, filterStack: stack);
  }

  // ── Equality ────────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGPresetDescriptor &&
          other.id == id &&
          other.name == name &&
          _listEquals(other.filterStack, filterStack);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(filterStack));

  @override
  String toString() =>
      'VGPresetDescriptor(id: $id, name: $name, '
      'filterStack: [${filterStack.map((f) => f.type).join(', ')}])';
}

/// Shallow list equality for [VGPresetDescriptor].
bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
