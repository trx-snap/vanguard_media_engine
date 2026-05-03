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

// ── P4-10: Typed constructors + validation (DEC-42, closes RR-34) ────────────

/// Allowlist of native-recognised filter type strings.
///
/// The native plugin's `setFilterChain` handler maps each type to a concrete
/// filter node class. Extend this set when a new filter node is added to both
/// the native handler and the UMF protocol conformers.
const Set<String> _validTypes = {'lut', 'beauty', 'segmentation'};

/// Typed factory constructors and validation for [VGFilterSpec].
///
/// Preferred over raw `VGFilterSpec(type: 'lut', ...)` because the factories
/// guarantee the correct type string and default parameters without relying on
/// caller-supplied string literals.
///
/// ```dart
/// await session.setFilterChain([
///   VGFilterSpecs.lut(intensity: 0.8),
///   VGFilterSpecs.beauty(intensity: 0.5, radius: 3.0),
///   VGFilterSpecs.segmentation(),
/// ]);
/// ```
extension VGFilterSpecs on VGFilterSpec {
  /// Creates a LUT colour-grading filter.
  ///
  /// [intensity] controls the blend between the identity and the loaded LUT
  /// [0.0, 1.0]. Defaults to 1.0 (full LUT).
  static VGFilterSpec lut({double intensity = 1.0}) => VGFilterSpec(
        type: 'lut',
        parameters: {'intensity': intensity},
      );

  /// Creates a beauty (bilateral skin-smoothing) filter.
  ///
  /// [intensity] maps to sigma_color in the bilateral kernel [0.0, 1.0].
  /// Defaults to 1.0.
  ///
  /// [radius] is the kernel half-size in pixels [1, 4]. Defaults to 2.0.
  /// For V2, omit this param to use the intensity ramp; supply it only to
  /// override specific granular control (disables the ramp).
  ///
  /// [beautyVersion] selects the native implementation:
  /// - `1` (default): selects Beauty V1 — the production bilateral filter.
  ///   This is the default and must remain unchanged for all existing callers.
  /// - `2`: selects Beauty V2 — the Phase 4B 4-pass GPUPixel-style pipeline.
  ///   **Dev/test only. Not for production use until Phase 4B is signed off.**
  ///
  /// DEV tuning params (V2 only, nullable). When any of these is non-null
  /// the intensity ramp is disabled and all parameters are applied directly.
  /// When all are null (default), the intensity ramp runs as normal.
  /// These are engineering-only controls — not for product UI.
  ///
  /// - [sigma]          Spatial Gaussian std-dev [1.0, 10.0]
  /// - [rangeSigma]     Colour-similarity gate   [0.01, 0.30]  (Phase 4B.5)
  /// - [smoothStrength] Smooth blend factor      [0.0,  2.0]
  /// - [theta]          Composite edge threshold [0.01, 0.08]
  /// - [sharpenStrength] Detail add-back amount  [0.0,  0.5]
  /// - [detailDamping]  Texture attenuation      [0.0,  1.0]   (Phase 4B.6)
  /// - [toneStrength]   Tone compression         [0.0,  1.0]   (Phase 4B.6)
  /// - [midtoneLift]    Midtone luminance lift   [0.0,  0.15]  (Phase 4B.6)
  ///
  /// Phase 4C: Face-aware beauty (DEC-61/63)
  /// - [faceAwareEnabled]  When `true`, enables Vision face detection + skin
  ///   mask generation. Beauty is applied selectively to skin regions only.
  ///   When `false` (default), global beauty (Phase 4B.6 behavior).
  ///   **DEV/test only.** Does NOT affect the intensity ramp.
  static VGFilterSpec beauty({
    double intensity = 1.0,
    double radius = 2.0,
    int beautyVersion = 1, // 1 = V1 (default/production), 2 = V2 (dev/test)
    // DEV-only V2 granular overrides — null means "use intensity ramp".
    double? sigma,
    double? rangeSigma,
    double? smoothStrength,
    double? theta,
    double? sharpenStrength,
    // Phase 4B.6 (DEC-60) — perceptual composite DEV overrides.
    // Step 1: CPU-plumbed only; GPU wiring in Step 2.
    double? detailDamping,
    double? toneStrength,
    double? midtoneLift,
    // Phase 4C (DEC-61/63) — face-aware beauty DEV toggle.
    bool faceAwareEnabled = false,
    // Phase 4C.1 (DEC-66/67) — face-weighted boost DEV overrides.
    // Only active when faceAwareEnabled=true. Null = use ObjC defaults.
    // Independent of the intensity ramp — do NOT trigger hasGranular.
    double? faceSmoothBoost,
    double? faceToneBoost,
    double? faceLiftBoost,
    double? faceDampingReduce,
    // Phase 4C.2 (DEC-70/71) — color aesthetic DEV overrides.
    // Only active when faceAwareEnabled=true. Null = use ObjC defaults.
    // Independent of the intensity ramp — do NOT trigger hasGranular.
    double? faceWhitenStrength,
    double? faceRosyStrength,
    double? faceToneUnifyStrength,
    double? faceGlowStrength,
    // Phase 4C.3 (DEC-76/78) — feature protection & enhancement DEV overrides.
    // Only active when faceAwareEnabled=true. Null = use ObjC defaults.
    // Independent of the intensity ramp — do NOT trigger hasGranular.
    double? featureRestoreStrength,
    double? featureDetailRestore,
    double? featureContrastBoost,
    double? featureSatBoost,
    // Phase 4D (DEC-82/84) — perceptual feature enhancement DEV overrides.
    // Only active when faceAwareEnabled=true. Null = use ObjC defaults (0.0 = disabled).
    // Independent of the intensity ramp — do NOT trigger hasGranular.
    double? eyeEnhanceStrength,
    double? lipEnhanceStrength,
    double? browEnhanceStrength,
    // Phase 4E (DEC-90/92) — tone polish layer DEV overrides.
    // Only active when faceAwareEnabled=true. Null = use ObjC defaults (0.0 = disabled).
    // Independent of the intensity ramp — do NOT trigger hasGranular.
    double? polishGlowStrength,
    double? polishSmoothStrength,
    double? polishWarmthStrength,
    double? polishBloomStrength,
  }) {
    // Only include the version key when V2 is explicitly requested.
    // Omitting the key from V1 calls preserves the exact existing wire format
    // and guarantees native falls through to the V1 branch (Step 4 gate).
    //
    // Step 6B: For V2, radius is only included when the caller explicitly
    // overrides it (i.e. differs from the Dart default of 2.0). This prevents
    // the default value from triggering hasGranular=YES in the runtime, which
    // would disable the intensity ramp unintentionally.
    // V1 always includes radius — the V1 bilateral kernel needs it.
    //
    // DEV params: included only when non-null AND V2 is selected. Each one
    // presence causes hasGranular=YES on native side → intensity ramp off.
    final bool isV2 = beautyVersion != 1;
    final params = <String, Object?>{
      'intensity': intensity,
      if (!isV2) 'radius': radius,              // V1: always send radius
      if (isV2 && radius != 2.0) 'radius': radius, // V2: only when overridden
      if (isV2) 'beautyVersion': beautyVersion,
      // DEV granular overrides (V2 only):
      if (isV2 && sigma          != null) 'sigma':          sigma,
      if (isV2 && rangeSigma     != null) 'rangeSigma':     rangeSigma,
      if (isV2 && smoothStrength != null) 'smoothStrength': smoothStrength,
      if (isV2 && theta          != null) 'theta':          theta,
      if (isV2 && sharpenStrength!= null) 'sharpenStrength':sharpenStrength,
      // Phase 4B.6 (DEC-60) DEV overrides:
      if (isV2 && detailDamping  != null) 'detailDamping':  detailDamping,
      if (isV2 && toneStrength   != null) 'toneStrength':   toneStrength,
      if (isV2 && midtoneLift    != null) 'midtoneLift':    midtoneLift,
      // Phase 4C (DEC-61/63): only send when true — omit = default NO on native.
      if (isV2 && faceAwareEnabled) 'faceAwareEnabled': true,
      // Phase 4C.1 (DEC-66/67): face-boost overrides (V2 only, null-safe).
      // Independent of hasGranular — do not disable intensity ramp.
      if (isV2 && faceSmoothBoost   != null) 'faceSmoothBoost':   faceSmoothBoost,
      if (isV2 && faceToneBoost     != null) 'faceToneBoost':     faceToneBoost,
      if (isV2 && faceLiftBoost     != null) 'faceLiftBoost':     faceLiftBoost,
      if (isV2 && faceDampingReduce != null) 'faceDampingReduce': faceDampingReduce,
      // Phase 4C.2 (DEC-70/71): color aesthetic overrides (V2 only, null-safe).
      // Independent of hasGranular — do not disable intensity ramp.
      if (isV2 && faceWhitenStrength    != null) 'faceWhitenStrength':    faceWhitenStrength,
      if (isV2 && faceRosyStrength      != null) 'faceRosyStrength':      faceRosyStrength,
      if (isV2 && faceToneUnifyStrength != null) 'faceToneUnifyStrength': faceToneUnifyStrength,
      if (isV2 && faceGlowStrength      != null) 'faceGlowStrength':      faceGlowStrength,
      // Phase 4C.3 (DEC-76/78): feature protection & enhancement overrides (V2 only, null-safe).
      // Independent of hasGranular — do not disable intensity ramp.
      if (isV2 && featureRestoreStrength != null) 'featureRestoreStrength': featureRestoreStrength,
      if (isV2 && featureDetailRestore   != null) 'featureDetailRestore':   featureDetailRestore,
      if (isV2 && featureContrastBoost   != null) 'featureContrastBoost':   featureContrastBoost,
      if (isV2 && featureSatBoost        != null) 'featureSatBoost':        featureSatBoost,
      // Phase 4D (DEC-82/84): perceptual feature enhancement overrides (V2 only, null-safe).
      // Independent of hasGranular — do not disable intensity ramp.
      if (isV2 && eyeEnhanceStrength  != null) 'eyeEnhanceStrength':  eyeEnhanceStrength,
      if (isV2 && lipEnhanceStrength  != null) 'lipEnhanceStrength':  lipEnhanceStrength,
      if (isV2 && browEnhanceStrength != null) 'browEnhanceStrength': browEnhanceStrength,
      // Phase 4E (DEC-90/92): tone polish layer overrides (V2 only, null-safe).
      // Independent of hasGranular — do not disable intensity ramp.
      if (isV2 && polishGlowStrength   != null) 'polishGlowStrength':   polishGlowStrength,
      if (isV2 && polishSmoothStrength != null) 'polishSmoothStrength': polishSmoothStrength,
      if (isV2 && polishWarmthStrength != null) 'polishWarmthStrength': polishWarmthStrength,
      if (isV2 && polishBloomStrength  != null) 'polishBloomStrength':  polishBloomStrength,
    };
    return VGFilterSpec(type: 'beauty', parameters: params);
  }

  /// Creates a person-segmentation composite filter.
  ///
  /// No parameters in Phase 4. Reads the current [VanguardMaskStore] snapshot
  /// on the native side.
  static VGFilterSpec segmentation() =>
      const VGFilterSpec(type: 'segmentation');

  /// Asserts that this spec's [type] is recognised by the native plugin.
  ///
  /// Throws an [AssertionError] in debug mode if [type] is not in the
  /// allowlist ([_validTypes]). No-op in release mode (Dart `assert` is elided
  /// by the compiler when asserts are disabled).
  ///
  /// [VGPlaybackSession.setFilterChain] calls this automatically for every
  /// spec before dispatching to native, so callers do not need to call it
  /// manually unless they are constructing specs outside [setFilterChain].
  void assertValid() {
    assert(
      _validTypes.contains(type),
      'VGFilterSpec.assertValid: unrecognised filter type "$type". '
      'Valid types: $_validTypes. '
      'Add a native handler case and update _validTypes to introduce a new filter.',
    );
  }
}
