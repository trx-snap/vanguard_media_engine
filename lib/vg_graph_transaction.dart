// vg_graph_transaction.dart
// Vanguard Media Engine — Phase 6C.1B
//
// Pure Dart transaction builder and immutable payload value object.
//
// Design rules (Phase 6C / DEC-128):
//   - 100% Dart-only.  No MethodChannel, no invokeMethod, no native dispatch.
//   - Fail-fast: setParameter validates and clamps values immediately on write,
//     not deferred to commit().  This prevents silent corrupt state.
//   - Atomic commit: commit() freezes a deep-copy snapshot, then auto-clears
//     the builder so the builder is always in a well-defined state.
//   - Feature-agnostic: effect/parameter keys come from VGEffectCatalog only.
//   - Single-instance per effect type: the parameterUpdates map is keyed by
//     effectType only.  Multiple instances of the same filter type are
//     not supported in 6C.1B because the native graph has no stable instance
//     ID scheme yet.  This is documented and deferred.
//
// Usage:
//   final tx = VGGraphTransaction();
//   tx.setParameter('beauty', 'intensity', 0.8);   // clamped immediately
//   tx.applyPreset(myPreset);                       // forces requiresRebuild
//   final payload = tx.commit();                    // builder is cleared
//   // payload.toJson() → ready for future native dispatch (Phase 6C.2)

import 'vg_effect_catalog.dart';
import 'vg_parameter_descriptor.dart';
import 'vg_preset_descriptor.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VGGraphTransaction  (mutable builder)
// ─────────────────────────────────────────────────────────────────────────────

/// A mutable transaction builder that batches Dart-side parameter mutations
/// for later atomic dispatch to the native graph.
///
/// All writes are validated and clamped immediately via [VGEffectCatalog] and
/// [VGParameterDescriptor.clamp].  Unknown effects, unknown parameters, and
/// type-incompatible values throw [ArgumentError] at the point of the call,
/// never silently.
///
/// After building the desired mutations, call [commit] to obtain an immutable
/// [VGGraphTransactionPayload].  [commit] also clears the builder so it is
/// ready for the next transaction.
///
/// ## Limitations (Phase 6C.1B)
/// - One parameter map per effect type.  If the native graph were to support
///   multiple nodes of the same filter type (e.g. two `beauty` nodes), the key
///   scheme would need instance IDs.  This is deferred pending native support.
/// - No native dispatch occurs here.  The returned payload is a pure data
///   object.  Actual channel dispatch is planned for Phase 6C.2.
///
/// ```dart
/// final tx = VGGraphTransaction();
/// tx.setParameter('beauty', 'intensity', 0.6);
/// tx.setParameter('lut',    'intensity', 0.4);
/// final payload = tx.commit();
/// // payload.hasHotParameters == true
/// // payload.parameterUpdates == {'beauty': {'intensity': 0.6}, 'lut': {'intensity': 0.4}}
/// ```
final class VGGraphTransaction {
  // ── Pending state ────────────────────────────────────────────────────────────

  // Stores clamped values keyed by effectType → parameterName → clamped value.
  final Map<String, Map<String, dynamic>> _pendingUpdates = {};

  // Stored per-update policy for flag classification.  The inner map mirrors
  // _pendingUpdates but carries VGParameterApplyPolicy rather than a value.
  final Map<String, Map<String, VGParameterApplyPolicy>> _pendingPolicies = {};

  // Pending preset, if any.
  VGPresetDescriptor? _pendingPreset;

  // ── State inspection ─────────────────────────────────────────────────────────

  /// `true` if no preset has been applied and no parameters have been written.
  bool get isEmpty => _pendingUpdates.isEmpty && _pendingPreset == null;

  /// `true` if any pending parameter update has [VGParameterApplyPolicy.hot].
  bool get hasHotParameters => _anyPolicy(VGParameterApplyPolicy.hot);

  /// `true` if any pending parameter update has [VGParameterApplyPolicy.warm].
  bool get hasWarmParameters => _anyPolicy(VGParameterApplyPolicy.warm);

  /// `true` if a preset is pending OR any pending parameter update has
  /// [VGParameterApplyPolicy.prepare].
  bool get requiresRebuild =>
      _pendingPreset != null || _anyPolicy(VGParameterApplyPolicy.prepare);

  bool _anyPolicy(VGParameterApplyPolicy target) {
    for (final effectPolicies in _pendingPolicies.values) {
      for (final policy in effectPolicies.values) {
        if (policy == target) return true;
      }
    }
    return false;
  }

  // ── Mutation ─────────────────────────────────────────────────────────────────

  /// Queues a parameter update.
  ///
  /// Validates [effectType] against [VGEffectCatalog.supportsEffect] and
  /// [parameterName] against [VGEffectCatalog.supportsParameter].  Throws
  /// [ArgumentError] immediately if either is unrecognised.
  ///
  /// Clamps [value] immediately using [VGParameterDescriptor.clamp].  If the
  /// runtime type of [value] is incompatible with the descriptor type, [clamp]
  /// throws [ArgumentError].
  ///
  /// Multiple writes to the same `effectType`/`parameterName` pair are
  /// last-write-wins — the final clamped value replaces the previous one.
  void setParameter(String effectType, String parameterName, dynamic value) {
    // 1. Validate effect type.
    if (!VGEffectCatalog.supportsEffect(effectType)) {
      throw ArgumentError(
        'VGGraphTransaction.setParameter: unknown effect type "$effectType". '
        'Registered effects: ${VGEffectCatalog.effects.keys.toList()}.',
      );
    }
    // 2. Validate parameter name.
    final descriptor = VGEffectCatalog.parameter(effectType, parameterName);
    if (descriptor == null) {
      throw ArgumentError(
        'VGGraphTransaction.setParameter: unknown parameter "$parameterName" '
        'for effect "$effectType". '
        'Registered parameters: '
        '${VGEffectCatalog.effect(effectType)!.parameters.keys.toList()}.',
      );
    }
    // 3. Clamp/type-check immediately.  ArgumentError propagates to caller.
    final clamped = descriptor.clamp(value);

    // 4. Store clamped value and policy (last-write-wins).
    _pendingUpdates.putIfAbsent(effectType, () => {})[parameterName] = clamped;
    _pendingPolicies.putIfAbsent(effectType, () => {})[parameterName] =
        descriptor.applyPolicy;
  }

  /// Queues multiple parameter updates for a single [effectType] in one call.
  ///
  /// Convenience batch wrapper over [setParameter]: iterates [values] in
  /// iteration order and calls [setParameter] for each entry. Delegates
  /// entirely to [setParameter]'s existing validation and clamping — an
  /// unknown [effectType], an unknown parameter name, or a type-incompatible
  /// value throws [ArgumentError] immediately, exactly as a direct
  /// [setParameter] call would. No platform dispatch occurs here.
  ///
  /// Entries applied before a failing key remain queued on the builder when
  /// [values] contains a bad entry — this mirrors [setParameter]'s own
  /// fail-fast-per-call semantics rather than adding multi-key rollback.
  ///
  /// Feature-agnostic like [setParameter]: [effectType] is any string
  /// registered in [VGEffectCatalog], not tied to a specific product filter.
  ///
  /// ```dart
  /// tx.setParameters('greenScreen', {
  ///   'scale': 1.5,
  ///   'offsetX': 0.2,
  ///   'offsetY': -0.1,
  /// });
  /// ```
  void setParameters(String effectType, Map<String, dynamic> values) {
    for (final entry in values.entries) {
      setParameter(effectType, entry.key, entry.value);
    }
  }

  /// Queues a structural preset application.
  ///
  /// Any previously queued preset is replaced (last-write-wins).
  /// Forces [requiresRebuild] to `true` regardless of any parameter policies.
  ///
  /// Parameter updates queued via [setParameter] coexist with the preset in the
  /// same transaction.  In the future native dispatch layer the preset will be
  /// applied first; parameter updates will then overwrite individual preset
  /// parameter values.
  void applyPreset(VGPresetDescriptor preset) {
    _pendingPreset = preset;
  }

  /// Removes all pending parameter updates and clears any pending preset.
  ///
  /// After [clear], [isEmpty] returns `true` and all policy flags return `false`.
  void clear() {
    _pendingUpdates.clear();
    _pendingPolicies.clear();
    _pendingPreset = null;
  }

  // ── Commit ───────────────────────────────────────────────────────────────────

  /// Freezes the current pending state into an immutable
  /// [VGGraphTransactionPayload] and then clears the builder.
  ///
  /// The returned payload is a deep-copy snapshot of the pending state at the
  /// moment of the call.  Subsequent mutations to this builder do not affect
  /// the returned payload.
  ///
  /// The builder is automatically cleared after [commit] so it is immediately
  /// ready for the next transaction without needing an explicit [clear] call.
  ///
  /// If the builder [isEmpty], the returned payload will have empty
  /// `parameterUpdates`, `null` preset, and all policy flags `false`.
  VGGraphTransactionPayload commit() {
    // Snapshot policy flags before clear.
    final hotParams = hasHotParameters;
    final warmParams = hasWarmParameters;
    final rebuild = requiresRebuild;

    // Build a typed, deeply immutable copy of parameterUpdates.
    // We cannot use Map.unmodifiable(...).cast<>() because the cast is lazy and
    // the inner UnmodifiableMapView<dynamic,dynamic> causes _TypeError when
    // accessed as Map<String,dynamic> at runtime.
    // Instead we copy each inner map into a typed Map<String,dynamic> first,
    // then wrap both levels with Map.unmodifiable.
    final typedOuter = <String, Map<String, dynamic>>{};
    for (final entry in _pendingUpdates.entries) {
      typedOuter[entry.key] = Map.unmodifiable(<String, dynamic>{
        ...entry.value,
      });
    }
    // Explicitly typed to preserve Map<String, Map<String, dynamic>> through
    // Map.unmodifiable, which would otherwise infer Map<dynamic, dynamic>.
    final Map<String, Map<String, dynamic>> frozenUpdates = Map.unmodifiable(
      typedOuter,
    );

    final frozenPreset = _pendingPreset;

    // Auto-clear builder.
    clear();

    return VGGraphTransactionPayload._(
      parameterUpdates: frozenUpdates,
      preset: frozenPreset,
      hasHotParameters: hotParams,
      hasWarmParameters: warmParams,
      requiresRebuild: rebuild,
    );
  }

  // ── Debug ────────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGGraphTransaction(isEmpty: $isEmpty, '
      'hot: $hasHotParameters, warm: $hasWarmParameters, '
      'rebuild: $requiresRebuild, '
      'pending: ${_pendingUpdates.keys.toList()}, '
      'preset: ${_pendingPreset?.id})';
}

// ─────────────────────────────────────────────────────────────────────────────
// VGGraphTransactionPayload  (immutable value object)
// ─────────────────────────────────────────────────────────────────────────────

/// An immutable snapshot of a committed [VGGraphTransaction].
///
/// Produced exclusively by [VGGraphTransaction.commit].  The payload carries:
///   - A deeply unmodifiable map of validated, clamped parameter updates.
///   - An optional preset.
///   - Policy classification flags computed at commit time.
///
/// [toJson] produces a JSON-compatible map suitable for future native dispatch
/// (Phase 6C.2).  The shape is stable and must not change without a protocol
/// version bump.
///
/// ## JSON shape
/// ```json
/// {
///   "preset": { "id": "p", "name": "P", "filterStack": [...] },
///   "parameterUpdates": { "beauty": { "intensity": 0.8 } },
///   "requiresRebuild": true,
///   "hasWarmParameters": false,
///   "hasHotParameters": true
/// }
/// ```
/// When no preset is present, `"preset"` is `null`.
/// When no parameter updates exist, `"parameterUpdates"` is `{}`.
final class VGGraphTransactionPayload {
  // Private constructor — only [VGGraphTransaction.commit] may create instances.
  const VGGraphTransactionPayload._({
    required this.parameterUpdates,
    required this.preset,
    required this.hasHotParameters,
    required this.hasWarmParameters,
    required this.requiresRebuild,
  });

  // ── Fields ───────────────────────────────────────────────────────────────────

  /// Validated, clamped parameter updates keyed by effect type then parameter
  /// name.  The map and all inner maps are deeply unmodifiable.
  ///
  /// Example: `{'beauty': {'intensity': 0.8}, 'lut': {'intensity': 0.4}}`
  final Map<String, Map<String, dynamic>> parameterUpdates;

  /// The preset applied in this transaction, or `null` if no preset was queued.
  final VGPresetDescriptor? preset;

  /// `true` if any updated parameter had [VGParameterApplyPolicy.hot] at the
  /// time of commit.
  final bool hasHotParameters;

  /// `true` if any updated parameter had [VGParameterApplyPolicy.warm] at the
  /// time of commit.
  final bool hasWarmParameters;

  /// `true` if a preset was applied or any updated parameter had
  /// [VGParameterApplyPolicy.prepare] at the time of commit.
  final bool requiresRebuild;

  // ── Derived state ────────────────────────────────────────────────────────────

  /// `true` if this payload carries no parameter updates and no preset.
  bool get isEmpty => parameterUpdates.isEmpty && preset == null;

  // ── Serialisation ────────────────────────────────────────────────────────────

  /// Returns a JSON-compatible map for future native method-channel dispatch.
  ///
  /// The outer map always contains all five keys.  `preset` is `null` when no
  /// preset was applied.  `parameterUpdates` is `{}` when no parameters were
  /// updated.
  ///
  /// This is NOT the [VGFilterSpec] wire shape.  Future Phase 6C.2 native
  /// handlers will consume this payload and translate it to graph mutations.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'preset': preset?.toJson(),
    'parameterUpdates': parameterUpdates,
    'requiresRebuild': requiresRebuild,
    'hasWarmParameters': hasWarmParameters,
    'hasHotParameters': hasHotParameters,
  };

  // ── Debug ────────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGGraphTransactionPayload('
      'isEmpty: $isEmpty, '
      'hot: $hasHotParameters, warm: $hasWarmParameters, '
      'rebuild: $requiresRebuild, '
      'effects: ${parameterUpdates.keys.toList()}, '
      'preset: ${preset?.id})';
}
