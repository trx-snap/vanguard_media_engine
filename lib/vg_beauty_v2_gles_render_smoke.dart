// vg_beauty_v2_gles_render_smoke.dart
// vanguard_media_engine — P5-BEAUTY-V2-GLES-RENDER:
// Android True-DAG V4.3 foundation GlesBeautyV2Compositor
// 3-pass bilateral beauty smoothing shader/raster + CPU reference parity
// proof smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5BeautyV2GlesRenderSmoke` MethodChannel route.
// Diagnostic-only — validates that the private native GLES beauty helper
// fails closed on invalid parameters, rasterizes complete 3-pass bilateral
// smoothing matching iOS Metal math, asserts CPU reference parity across
// presets (none, soft, strong, max), asserts midtone parabolic lift and
// output bounds, restores GL state, cleanly releases all native resources,
// and verifies descriptor parity.
// No Vulkan, no decode, no export session, and no product/editor UI.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 Beauty V2 GLES render smoke harness.
enum VGBeautyV2GlesRenderSmokeDecision {
  /// All native GLES beauty render gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGBeautyV2GlesRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGBeautyV2GlesRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGBeautyV2GlesRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGBeautyV2GlesRenderSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGBeautyV2GlesRenderSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGBeautyV2GlesRenderSmokeDecision.harnessException;
    }
    for (final value in VGBeautyV2GlesRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGBeautyV2GlesRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGBeautyV2GlesRenderSmokeReport.runAndroidDagPhase5BeautyV2GlesRenderSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGBeautyV2GlesRenderSmokeReport {
  const VGBeautyV2GlesRenderSmokeReport({
    required this.pass,
    required this.decision,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.gates,
    required this.nativeAllLanesPass,
    required this.details,
    required this.raw,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_gles_beauty_v2_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_BEAUTY_V2_GLES_RENDER_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_BEAUTY_V2_GLES_RENDER_PHYSICAL_SMOKE_FAIL';

  /// Setup gate keys: temporary EGL pbuffer context and ES3+ confirmation.
  static const List<String> setupGateKeys = <String>[
    'eglSetupOk',
    'glVersionOk',
  ];

  /// Lane 1: parameter validation gate keys (fail-closed, zero GL mutations).
  static const List<String> validationGateKeys = <String>[
    'invalidTextureRejectedOk',
    'invalidDimensionsRejectedOk',
    'invalidIntensityRejectedOk',
    'invalidParameterRejectedOk',
  ];

  /// Lane 1 alias for consistency with diagnostic conventions.
  static const List<String> paramValidationGateKeys = validationGateKeys;

  /// Lane 2: none preset flat identity and gradient minimum ramp keys.
  static const List<String> nonePresetGateKeys = <String>[
    'nonePresetFlatIdentityOk',
    'nonePresetGradientMinimumRampOk',
  ];

  /// Lane 3: soft preset CPU reference parity gate keys.
  static const List<String> softPresetGateKeys = <String>[
    'softPresetCpuParityOk',
  ];

  /// Lane 4: strong preset CPU reference parity gate keys.
  static const List<String> strongPresetGateKeys = <String>[
    'strongPresetCpuParityOk',
  ];

  /// Lane 5: max preset CPU parity, pixel bounds, and midtone lift gate keys.
  static const List<String> maxPresetGateKeys = <String>[
    'maxPresetCpuParityOk',
    'maxPresetBoundsOk',
    'maxPresetMidtoneLiftOk',
  ];

  /// Lane 6: lifecycle resource release and GL state restoration gate keys.
  static const List<String> lifecycleStateGateKeys = <String>[
    'lifecycleResourcesReleasedOk',
    'glStateRestoredOk',
  ];

  /// Lane 6 aliases for consistency with diagnostic conventions.
  static const List<String> stateGateKeys = lifecycleStateGateKeys;
  static const List<String> stateRestoreGateKeys = lifecycleStateGateKeys;

  /// Lane 7: struct parity gate keys.
  static const List<String> structParityGateKeys = <String>['structParityOk'];

  /// Lane 7 alias for consistency with diagnostic conventions.
  static const List<String> parityGateKeys = structParityGateKeys;

  /// Canonical route verification gate keys.
  static const List<String> canonicalGateKeys = <String>['canonical'];

  /// Secondary telemetry keys. These are parsed, exposed, serialized, and
  /// tested, but per Section 9 readiness contract, false telemetry does NOT
  /// gate [allNativeLanesPass] or [isPass].
  static const List<String> telemetryKeys = <String>[
    'softPresetSmoothingObservedOk',
    'strongPresetEdgePreservationOk',
  ];

  /// Primary gate keys that determine [allNativeLanesPass]. Excludes telemetry.
  static const List<String> primaryGateKeys = <String>[
    ...setupGateKeys,
    ...validationGateKeys,
    ...nonePresetGateKeys,
    ...softPresetGateKeys,
    ...strongPresetGateKeys,
    ...maxPresetGateKeys,
    ...lifecycleStateGateKeys,
    ...structParityGateKeys,
    ...canonicalGateKeys,
  ];

  /// All 19 boolean gate and telemetry keys in native emission order.
  static const List<String> allGateKeys = <String>[
    'eglSetupOk',
    'glVersionOk',
    'invalidTextureRejectedOk',
    'invalidDimensionsRejectedOk',
    'invalidIntensityRejectedOk',
    'invalidParameterRejectedOk',
    'nonePresetFlatIdentityOk',
    'nonePresetGradientMinimumRampOk',
    'softPresetCpuParityOk',
    'softPresetSmoothingObservedOk',
    'strongPresetCpuParityOk',
    'strongPresetEdgePreservationOk',
    'maxPresetCpuParityOk',
    'maxPresetBoundsOk',
    'maxPresetMidtoneLiftOk',
    'lifecycleResourcesReleasedOk',
    'glStateRestoredOk',
    'structParityOk',
    'canonical',
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGBeautyV2GlesRenderSmokeDecision decision;

  /// Raw status string (`PASS`, `FAIL`, `UNSUPPORTED`, ...).
  final String status;

  /// PASS/FAIL marker string emitted by the native harness.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// First failure reason reported by the native harness, empty on pass.
  final String failureReason;

  /// Per-gate boolean results keyed by gate name.
  final Map<String, bool> gates;

  /// Native aggregate flag (`allNativeLanesPass`, mirrored as
  /// `nativeAllLanesPass` by the native harness).
  final bool nativeAllLanesPass;

  /// Free-form diagnostic details emitted by the native harness (GL
  /// version/renderer, per-preset MAE/deltas, timing, struct layout).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Whether the temporary EGL pbuffer context was created.
  bool get eglSetupPass => _gate('eglSetupOk');

  /// Whether OpenGL ES 3.0+ was verified.
  bool get glVersionPass => _gate('glVersionOk');

  /// Whether the setup lane passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ── Lane 1: parameter validation ──────────────────────────────────────────

  /// Whether texture name 0 was rejected before any GL call.
  bool get invalidTextureRejectedPass => _gate('invalidTextureRejectedOk');

  /// Whether zero surface width or height was rejected.
  bool get invalidDimensionsRejectedPass =>
      _gate('invalidDimensionsRejectedOk');

  /// Whether negative, >1.0, or non-finite intensity was rejected.
  bool get invalidIntensityRejectedPass => _gate('invalidIntensityRejectedOk');

  /// Whether non-finite or out-of-bounds parameters were rejected.
  bool get invalidParameterRejectedPass => _gate('invalidParameterRejectedOk');

  /// Whether every parameter validation gate passed.
  bool get validationPass => validationGateKeys.every(_gate);

  /// Semantic alias for validation lane pass.
  bool get paramValidationPass => validationPass;

  // ── Lane 2: none preset minimum ramp ──────────────────────────────────────

  /// Whether flat patches produce bit-identical output under intensity 0.0.
  bool get nonePresetFlatIdentityPass => _gate('nonePresetFlatIdentityOk');

  /// Whether linear gradient ramps match minimum ramp math within tolerance.
  bool get nonePresetGradientMinimumRampPass =>
      _gate('nonePresetGradientMinimumRampOk');

  /// Whether every none preset gate passed.
  bool get nonePresetPass => nonePresetGateKeys.every(_gate);

  // ── Lane 3: soft preset CPU reference parity ──────────────────────────────

  /// Primary gate: whether GPU output matches CPU reference math within tolerance.
  bool get softPresetCpuParityPass => _gate('softPresetCpuParityOk');

  /// Secondary telemetry: whether output variance is lower than input variance.
  bool get softPresetSmoothingObserved =>
      _gate('softPresetSmoothingObservedOk');

  /// Semantic alias for soft preset smoothing telemetry.
  bool get softPresetSmoothingObservedPass => softPresetSmoothingObserved;

  /// Whether the soft preset primary gate passed.
  bool get softPresetPass => softPresetCpuParityPass;

  // ── Lane 4: strong preset CPU reference parity ────────────────────────────

  /// Primary gate: whether GPU output matches CPU reference math within tolerance.
  bool get strongPresetCpuParityPass => _gate('strongPresetCpuParityOk');

  /// Secondary telemetry: whether boundary edge sharpness is preserved.
  bool get strongPresetEdgePreservationObserved =>
      _gate('strongPresetEdgePreservationOk');

  /// Semantic alias for strong preset edge preservation telemetry.
  bool get strongPresetEdgePreservationPass =>
      strongPresetEdgePreservationObserved;

  /// Whether the strong preset primary gate passed.
  bool get strongPresetPass => strongPresetCpuParityPass;

  // ── Lane 5: max preset bounds & midtone lift ──────────────────────────────

  /// Primary gate: whether GPU output matches CPU reference math within tolerance.
  bool get maxPresetCpuParityPass => _gate('maxPresetCpuParityOk');

  /// Secondary gate: whether all output pixel channels are within [0, 255].
  bool get maxPresetBoundsPass => _gate('maxPresetBoundsOk');

  /// Secondary gate: whether midtone luminance was lifted above input.
  bool get maxPresetMidtoneLiftPass => _gate('maxPresetMidtoneLiftOk');

  /// Whether every max preset gate passed.
  bool get maxPresetPass => maxPresetGateKeys.every(_gate);

  // ── Lane 6: lifecycle & GL state restoration ──────────────────────────────

  /// Whether all temporary shaders, programs, FBOs, and textures were released.
  bool get lifecycleResourcesReleasedPass =>
      _gate('lifecycleResourcesReleasedOk');

  /// Semantic alias for lifecycle resources released pass.
  bool get lifecyclePass => lifecycleResourcesReleasedPass;

  /// Whether GL viewport, active texture, bindings, blend, dither, scissor,
  /// depth, stencil, cull, color mask, and alignments were restored.
  bool get glStateRestoredPass => _gate('glStateRestoredOk');

  /// Whether every lifecycle and state restoration gate passed.
  bool get statePass => lifecycleStateGateKeys.every(_gate);

  /// Semantic alias for state restoration lane pass.
  bool get stateRestorePass => statePass;

  // ── Lane 7: struct parity ─────────────────────────────────────────────────

  /// Whether native GlesBeautyV2Parameters layout and fields match contract.
  bool get structParityPass => _gate('structParityOk');

  /// Semantic alias for struct parity gate pass.
  bool get parityPass => structParityPass;

  // ── Canonical route ───────────────────────────────────────────────────────

  /// Whether the canonical route ran against the owned EGL pbuffer with no lane
  /// skipped or substituted.
  bool get canonicalPass => _gate('canonical');

  /// Semantic alias for canonical pass.
  bool get canonical => canonicalPass;

  // ── Aggregates ────────────────────────────────────────────────────────────

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every primary diagnostic gate passed (computed Dart-side from
  /// [gates], independent of [nativeAllLanesPass]). Telemetry keys are excluded.
  bool get allNativeLanesPass => primaryGateKeys.every(_gate);

  /// Full verified pass: requires pass true, decision pass, proofBoundary
  /// exact, marker exact, nativeAllLanesPass true, all primary gate keys true,
  /// nativeAllLanesPass agreeing with Dart primary gate calculation, and
  /// canonical true. False telemetry does not fail this pass.
  bool get isPass =>
      pass &&
      decision == VGBeautyV2GlesRenderSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      nativeAllLanesPass &&
      allNativeLanesPass &&
      (nativeAllLanesPass == allNativeLanesPass) &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGBeautyV2GlesRenderSmokeDecision.fail].
  bool get isFail => decision == VGBeautyV2GlesRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGBeautyV2GlesRenderSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGBeautyV2GlesRenderSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGBeautyV2GlesRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGBeautyV2GlesRenderSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGBeautyV2GlesRenderSmokeReport.unsupported(String reason) {
    return VGBeautyV2GlesRenderSmokeReport(
      pass: false,
      decision: VGBeautyV2GlesRenderSmokeDecision.unsupported,
      status: 'UNSUPPORTED',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      nativeAllLanesPass: false,
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
      }),
      raw: '{"pass":false,"status":"UNSUPPORTED","failureReason":"$reason"}',
    );
  }

  /// A fail-shaped report for a harness-level failure (timeout, exception,
  /// malformed native payload).
  factory VGBeautyV2GlesRenderSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGBeautyV2GlesRenderSmokeReport(
      pass: false,
      decision: VGBeautyV2GlesRenderSmokeDecision.harnessException,
      status: 'FAIL',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      nativeAllLanesPass: false,
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
        ...extraDetails,
      }),
      raw: '{"pass":false,"status":"FAIL","failureReason":"$reason"}',
    );
  }

  static bool _truthy(Object? value) =>
      value == true || (value is String && value == 'true');

  /// Parses a report from the raw native map or JSON string. Defensive
  /// against non-map, non-JSON, missing, or malformed fields.
  static VGBeautyV2GlesRenderSmokeReport fromMap(Object? raw) {
    Map<dynamic, dynamic>? map;
    if (raw is Map) {
      map = raw;
    } else if (raw is String && raw.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          map = decoded;
        }
      } catch (_) {
        // Fail closed below.
      }
    }

    if (map == null) {
      return VGBeautyV2GlesRenderSmokeReport.harnessFailure(
        'native_result_not_a_map',
        extraDetails: <String, Object?>{'received': raw?.toString() ?? ''},
      );
    }

    final pass = map['pass'] as bool? ?? false;
    final status = (map['status'] as String?) ?? (pass ? 'PASS' : 'FAIL');
    final marker = (map['marker'] as String?) ?? '';
    final proofBoundary = (map['proofBoundary'] as String?) ?? '';
    final failureReason = (map['failureReason'] as String?) ?? '';
    final rawString = raw is String ? raw : ((map['raw'] as String?) ?? '');

    final gates = <String, bool>{};
    for (final key in allGateKeys) {
      gates[key] = _truthy(map[key]);
    }

    // Native emits both spellings with the same value; accept either.
    final nativeAllLanesPass = map.containsKey('allNativeLanesPass')
        ? _truthy(map['allNativeLanesPass'])
        : _truthy(map['nativeAllLanesPass']);

    final detailsRaw = map['details'];
    final details = <String, Object?>{};
    if (detailsRaw is Map) {
      for (final entry in detailsRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          details[k] = entry.value;
        }
      }
    }

    final decision = pass
        ? VGBeautyV2GlesRenderSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGBeautyV2GlesRenderSmokeReport(
      pass: pass,
      decision: decision,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      gates: Map<String, bool>.unmodifiable(gates),
      nativeAllLanesPass: nativeAllLanesPass,
      details: Map<String, Object?>.unmodifiable(details),
      raw: rawString,
    );
  }

  static VGBeautyV2GlesRenderSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGBeautyV2GlesRenderSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGBeautyV2GlesRenderSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGBeautyV2GlesRenderSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGBeautyV2GlesRenderSmokeDecision.fail;
    }
    return VGBeautyV2GlesRenderSmokeDecision.harnessException;
  }

  /// Serializes the report back to a map mirroring all 27 native wire keys.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      for (final key in allGateKeys) key: gates[key] == true,
      'allNativeLanesPass': nativeAllLanesPass,
      'nativeAllLanesPass': nativeAllLanesPass,
      'details': Map<String, Object?>.from(details),
      'decision': decision.name,
      'raw': raw,
    };
  }

  static const String _method = 'runAndroidDagPhase5BeautyV2GlesRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 GlesBeautyV2Compositor
  /// bilateral beauty smoothing shader/raster diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGBeautyV2GlesRenderSmokeDecision.harnessException] report on timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields a
  /// [VGBeautyV2GlesRenderSmokeDecision.unsupported] report; any
  /// other error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGBeautyV2GlesRenderSmokeReport>
  runAndroidDagPhase5BeautyV2GlesRenderSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGBeautyV2GlesRenderSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGBeautyV2GlesRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGBeautyV2GlesRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGBeautyV2GlesRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGBeautyV2GlesRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGBeautyV2GlesRenderSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGBeautyV2GlesRenderSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        mapEquals(other.gates, gates) &&
        other.nativeAllLanesPass == nativeAllLanesPass &&
        mapEquals(other.details, details) &&
        other.raw == raw;
  }

  @override
  int get hashCode => Object.hash(
    pass,
    decision,
    status,
    marker,
    proofBoundary,
    failureReason,
    _stableMapHash(gates),
    nativeAllLanesPass,
    _stableMapHash(details),
    raw,
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGBeautyV2GlesRenderSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'gates: $gates, '
      'nativeAllLanesPass: $nativeAllLanesPass, '
      'details: $details)';
}
