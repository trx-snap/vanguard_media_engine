// vg_beauty_v2_vulkan_render_smoke.dart
// vanguard_media_engine — P5-BEAUTY-V2-VULKAN-RENDER:
// Android True-DAG V4.3 foundation VulkanBeautyV2Compositor
// 3-pass bilateral beauty smoothing shader/raster + CPU reference parity
// proof smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5BeautyV2VulkanRenderSmoke` MethodChannel route.
// Diagnostic-only — validates that the private native Vulkan beauty helper
// fails closed on invalid parameters, rasterizes complete 3-pass bilateral
// smoothing matching iOS Metal math, asserts CPU reference parity across
// presets (none, soft, strong, max), asserts midtone parabolic lift and
// output bounds, releases all helper and diagnostic Vulkan resources,
// and verifies descriptor parity.
// No decode, no export session, and no product/editor UI.
// A device without a usable Vulkan driver reports status `UNSUPPORTED`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 Beauty V2 Vulkan render smoke harness.
enum VGBeautyV2VulkanRenderSmokeDecision {
  /// All native Vulkan beauty render gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build, or the device
  /// has no usable Vulkan driver.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGBeautyV2VulkanRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGBeautyV2VulkanRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGBeautyV2VulkanRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGBeautyV2VulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGBeautyV2VulkanRenderSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGBeautyV2VulkanRenderSmokeDecision.harnessException;
    }
    for (final value in VGBeautyV2VulkanRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGBeautyV2VulkanRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGBeautyV2VulkanRenderSmokeReport {
  const VGBeautyV2VulkanRenderSmokeReport({
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
      'native_vulkan_beauty_v2_compositor_shader_raster_only_no_decode_no_export_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_BEAUTY_V2_VULKAN_RENDER_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_BEAUTY_V2_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL';

  /// Setup gate keys: temporary Vulkan scratch context, sampled images, and attachments.
  static const List<String> setupGateKeys = <String>['vulkanSetupOk'];

  /// Lane 1: parameter validation gate keys (fail-closed, zero Vulkan draw mutations).
  static const List<String> validationGateKeys = <String>[
    'invalidImageRejectedOk',
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

  /// Lane 6: lifecycle resource release and diagnostic teardown gate keys.
  static const List<String> lifecycleGateKeys = <String>[
    'helperResourcesReleasedOk',
    'diagnosticTeardownOk',
  ];

  /// Lane 6 aliases for consistency with diagnostic conventions.
  static const List<String> lifecycleStateGateKeys = lifecycleGateKeys;
  static const List<String> resourceLifecycleGateKeys = lifecycleGateKeys;
  static const List<String> lifecycleTeardownGateKeys = lifecycleGateKeys;
  static const List<String> stateGateKeys = lifecycleGateKeys;

  /// Lane 7: struct parity gate keys.
  static const List<String> structParityGateKeys = <String>['structParityOk'];

  /// Lane 7 alias for consistency with diagnostic conventions.
  static const List<String> parityGateKeys = structParityGateKeys;

  /// Canonical route verification gate keys.
  static const List<String> canonicalGateKeys = <String>['canonical'];

  /// Secondary telemetry keys. These are parsed, exposed, serialized, and
  /// tested, but per contract, false telemetry does NOT gate
  /// [allNativeLanesPass] or [isPass].
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
    ...lifecycleGateKeys,
    ...structParityGateKeys,
    ...canonicalGateKeys,
  ];

  /// All 18 boolean gate and telemetry keys in native emission order.
  static const List<String> allGateKeys = <String>[
    'vulkanSetupOk',
    'invalidImageRejectedOk',
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
    'helperResourcesReleasedOk',
    'diagnosticTeardownOk',
    'structParityOk',
    'canonical',
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGBeautyV2VulkanRenderSmokeDecision decision;

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

  /// Free-form diagnostic details emitted by the native harness (Vulkan
  /// device/driver info, per-preset MAE/deltas, timing, struct layout).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Whether the temporary Vulkan scratch context and images were created.
  bool get vulkanSetupPass => _gate('vulkanSetupOk');

  /// Whether the setup lane passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ── Lane 1: parameter validation ──────────────────────────────────────────

  /// Whether null/invalid Vulkan image handles were rejected before draw.
  bool get invalidImageRejectedPass => _gate('invalidImageRejectedOk');

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

  // ── Lane 6: lifecycle & teardown ──────────────────────────────────────────

  /// Whether all temporary helper Vulkan pipelines, framebuffers, and textures were released.
  bool get helperResourcesReleasedPass => _gate('helperResourcesReleasedOk');

  /// Whether all diagnostic-owned Vulkan devices, images, buffers, and pools were torn down.
  bool get diagnosticTeardownPass => _gate('diagnosticTeardownOk');

  /// Whether every lifecycle and teardown gate passed.
  bool get lifecyclePass => lifecycleGateKeys.every(_gate);

  /// Semantic alias for lifecycle pass matching test/physical smoke conventions.
  bool get lifecycleTeardownPass => lifecyclePass;

  /// Semantic alias for state pass matching suite conventions.
  bool get statePass => lifecyclePass;

  /// Semantic alias for resource lifecycle pass.
  bool get resourceLifecyclePass => lifecyclePass;

  /// Semantic alias for diagnostic teardown pass.
  bool get teardownPass => diagnosticTeardownPass;

  // ── Lane 7: struct parity ─────────────────────────────────────────────────

  /// Whether native VulkanBeautyV2Parameters layout and fields match contract.
  bool get structParityPass => _gate('structParityOk');

  /// Semantic alias for struct parity gate pass.
  bool get parityPass => structParityPass;

  // ── Canonical route ───────────────────────────────────────────────────────

  /// Whether the canonical route ran against the owned Vulkan scratch context with no lane
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
  /// canonical true. False telemetry does not fail this pass. Unsupported must not pass.
  bool get isPass =>
      pass &&
      decision == VGBeautyV2VulkanRenderSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      nativeAllLanesPass &&
      allNativeLanesPass &&
      (nativeAllLanesPass == allNativeLanesPass) &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGBeautyV2VulkanRenderSmokeDecision.fail].
  bool get isFail => decision == VGBeautyV2VulkanRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGBeautyV2VulkanRenderSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGBeautyV2VulkanRenderSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGBeautyV2VulkanRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGBeautyV2VulkanRenderSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform or
  /// when the device lacks a usable Vulkan driver.
  factory VGBeautyV2VulkanRenderSmokeReport.unsupported(String reason) {
    return VGBeautyV2VulkanRenderSmokeReport(
      pass: false,
      decision: VGBeautyV2VulkanRenderSmokeDecision.unsupported,
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
  factory VGBeautyV2VulkanRenderSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGBeautyV2VulkanRenderSmokeReport(
      pass: false,
      decision: VGBeautyV2VulkanRenderSmokeDecision.harnessException,
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
  static VGBeautyV2VulkanRenderSmokeReport fromMap(Object? raw) {
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
      return VGBeautyV2VulkanRenderSmokeReport.harnessFailure(
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
        ? VGBeautyV2VulkanRenderSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGBeautyV2VulkanRenderSmokeReport(
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

  static VGBeautyV2VulkanRenderSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGBeautyV2VulkanRenderSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGBeautyV2VulkanRenderSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGBeautyV2VulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGBeautyV2VulkanRenderSmokeDecision.fail;
    }
    return VGBeautyV2VulkanRenderSmokeDecision.harnessException;
  }

  /// Serializes the report back to a map mirroring all native wire keys.
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

  static const String _method = 'runAndroidDagPhase5BeautyV2VulkanRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 VulkanBeautyV2Compositor
  /// bilateral beauty smoothing shader/raster diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGBeautyV2VulkanRenderSmokeDecision.harnessException] report on timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields a
  /// [VGBeautyV2VulkanRenderSmokeDecision.unsupported] report; any
  /// other error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGBeautyV2VulkanRenderSmokeReport>
  runAndroidDagPhase5BeautyV2VulkanRenderSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGBeautyV2VulkanRenderSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGBeautyV2VulkanRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGBeautyV2VulkanRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGBeautyV2VulkanRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGBeautyV2VulkanRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGBeautyV2VulkanRenderSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGBeautyV2VulkanRenderSmokeReport &&
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
      'VGBeautyV2VulkanRenderSmokeReport('
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
