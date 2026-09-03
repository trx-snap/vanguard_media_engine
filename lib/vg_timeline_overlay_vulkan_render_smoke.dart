// vg_timeline_overlay_vulkan_render_smoke.dart
// vanguard_media_engine — P5-OVERLAYS-TRANS (sub-slice VULKAN-RENDER):
// Android True-DAG V4.3 foundation VulkanOverlayCompositor
// multi-layer overlay shader/raster proof smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke` MethodChannel route.
// Diagnostic-only — validates that the private native Vulkan overlay helper
// fails closed on invalid parameters, rasterizes compositor-owned single-layer
// transforms (scale, 90/180 deg rotation, off-canvas clip), arbitrary 45 deg
// rotation with transparent border clamping, per-layer opacity with
// Porter-Duff source-over blending, destination alpha accumulation,
// multi-layer stacking order, existing attachment content composition,
// releases every temporary Vulkan object, and verifies descriptor parity.
// No decode, no export session, no keyframe evaluation, no AHardwareBuffer
// import, no production VulkanBackend mutation, and no product/editor UI.
// A device without a usable Vulkan driver reports status `UNSUPPORTED`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 Vulkan overlay render smoke harness.
enum VGTimelineOverlayVulkanRenderSmokeDecision {
  /// All native Vulkan overlay render gates passed.
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
  static VGTimelineOverlayVulkanRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGTimelineOverlayVulkanRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGTimelineOverlayVulkanRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGTimelineOverlayVulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGTimelineOverlayVulkanRenderSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGTimelineOverlayVulkanRenderSmokeDecision.harnessException;
    }
    for (final value in VGTimelineOverlayVulkanRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGTimelineOverlayVulkanRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGTimelineOverlayVulkanRenderSmokeReport {
  const VGTimelineOverlayVulkanRenderSmokeReport({
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
      'native_vulkan_timeline_overlay_compositor_shader_raster_only_no_decode_no_export_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL';

  /// Setup gate keys: temporary Vulkan device, sampled images, and attachments.
  static const List<String> setupGateKeys = <String>['vulkanSetupOk'];

  /// Lane 1: parameter validation gate keys (fail-closed, no Vulkan draw).
  static const List<String> validationGateKeys = <String>[
    'invalidImageRejectedOk',
    'invalidDimensionsRejectedOk',
    'nonFiniteTransformRejectedOk',
    'invalidOpacityRejectedOk',
    'mixedListRejectedBeforeDrawOk',
  ];

  /// Lane 1 alias for consistency with diagnostic conventions.
  static const List<String> paramValidationGateKeys = validationGateKeys;

  /// Lane 2: single-layer transform and arbitrary rotation gate keys.
  static const List<String> transformGateKeys = <String>[
    'singleLayerTransformOk',
    'arbitraryRotationOk',
  ];

  /// Lane 3: per-layer opacity, Porter-Duff blend, and alpha accumulation keys.
  static const List<String> blendGateKeys = <String>[
    'opacityBlendOk',
    'alphaAccumulationOk',
  ];

  /// Lane 4: multi-layer stacking and existing content composite gate keys.
  static const List<String> zOrderGateKeys = <String>[
    'multiLayerZOrderOk',
    'existingContentsCompositeOk',
  ];

  /// Lane 4 alias matching multi-layer stacking conventions.
  static const List<String> stackingGateKeys = zOrderGateKeys;

  /// Lane 4 alias matching composite target conventions.
  static const List<String> compositeGateKeys = zOrderGateKeys;

  /// Lane 5: resource lifecycle and diagnostic teardown gate keys.
  static const List<String> resourceLifecycleGateKeys = <String>[
    'helperResourcesReleasedOk',
    'diagnosticTeardownOk',
  ];

  /// Lane 5 alias matching cleanup conventions.
  static const List<String> cleanupGateKeys = resourceLifecycleGateKeys;

  /// Lane 6: descriptor and transform parity gate keys.
  static const List<String> parityGateKeys = <String>['structParityOk'];

  /// Lane 6 alias for consistency with diagnostic conventions.
  static const List<String> structParityGateKeys = parityGateKeys;

  /// Canonical route verification gate keys.
  static const List<String> canonicalGateKeys = <String>['canonical'];

  /// All gate keys in exact native emission order.
  static const List<String> allGateKeys = <String>[
    ...setupGateKeys,
    ...validationGateKeys,
    ...transformGateKeys,
    ...blendGateKeys,
    ...zOrderGateKeys,
    ...resourceLifecycleGateKeys,
    ...parityGateKeys,
    ...canonicalGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGTimelineOverlayVulkanRenderSmokeDecision decision;

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

  /// Free-form diagnostic details emitted by the native harness (device
  /// name/API version, per-draw checksums, probe RGB values, mismatch counts,
  /// helper temporary-object counts).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Whether the temporary Vulkan device, synthetic sampled images, offscreen
  /// color attachment, and readback buffer were created.
  bool get vulkanSetupPass => _gate('vulkanSetupOk');

  /// Whether the setup lane passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ── Lane 1: parameter validation ──────────────────────────────────────────

  /// Whether null/invalid image view or sampler handles were rejected.
  bool get invalidImageRejectedPass => _gate('invalidImageRejectedOk');

  /// Whether zero surface width/height or null layers was rejected.
  bool get invalidDimensionsRejectedPass =>
      _gate('invalidDimensionsRejectedOk');

  /// Whether NaN/Inf translation, width, height, rotation, or scale was rejected.
  bool get nonFiniteTransformRejectedPass =>
      _gate('nonFiniteTransformRejectedOk');

  /// Whether NaN/Inf or out-of-range (<0, >1) opacity was rejected.
  bool get invalidOpacityRejectedPass => _gate('invalidOpacityRejectedOk');

  /// Whether a bad layer anywhere in a multi-layer list caused rejection
  /// before any Vulkan call.
  bool get mixedListRejectedBeforeDrawPass =>
      _gate('mixedListRejectedBeforeDrawOk');

  /// Whether every parameter validation gate passed.
  bool get validationPass => validationGateKeys.every(_gate);

  /// Semantic alias for validation lane pass.
  bool get paramValidationPass => validationPass;

  // ── Lane 2: single-layer transform & rotation ─────────────────────────────

  /// Whether single-layer translate/scale, 90/180 deg rotation, and off-canvas
  /// clipping passed pixel verification.
  bool get singleLayerTransformPass => _gate('singleLayerTransformOk');

  /// Whether arbitrary rotation (45 deg) with clamp-to-border transparent
  /// black passed pixel and probe verification.
  bool get arbitraryRotationPass => _gate('arbitraryRotationOk');

  /// Whether every transform gate passed.
  bool get transformPass => transformGateKeys.every(_gate);

  // ── Lane 3: per-layer opacity, Porter-Duff blend & alpha accumulation ─────

  /// Whether uniform opacity, texture alpha, alpha*opacity, zero, and opaque
  /// blending passed pixel verification.
  bool get opacityBlendPass => _gate('opacityBlendOk');

  /// Whether destination alpha accumulation over transparent black passed
  /// pixel verification.
  bool get alphaAccumulationPass => _gate('alphaAccumulationOk');

  /// Whether every blend gate passed.
  bool get blendPass => blendGateKeys.every(_gate);

  // ── Lane 4: multi-layer stacking / z-order & existing content composite ───

  /// Whether forward stacking, reversed order, and empty layer list passed.
  bool get multiLayerZOrderPass => _gate('multiLayerZOrderOk');

  /// Whether composite over existing attachment contents with loadOp LOAD
  /// passed pixel verification.
  bool get existingContentsCompositePass =>
      _gate('existingContentsCompositeOk');

  /// Whether every z-order / stacking gate passed.
  bool get zOrderPass => zOrderGateKeys.every(_gate);

  /// Semantic alias for stacking lane pass.
  bool get stackingPass => zOrderPass;

  /// Semantic alias for composite lane pass.
  bool get compositePass => zOrderPass;

  // ── Lane 5: resource lifecycle & teardown ──────────────────────────────────

  /// Whether the helper released exactly as many temporary Vulkan objects as
  /// it created (and created none on validation failure paths).
  bool get helperResourcesReleasedPass => _gate('helperResourcesReleasedOk');

  /// Whether the diagnostic drained its device before destruction and every
  /// owned Vulkan handle was nulled.
  bool get diagnosticTeardownPass => _gate('diagnosticTeardownOk');

  /// Whether every resource lifecycle gate passed.
  bool get resourceLifecyclePass => resourceLifecycleGateKeys.every(_gate);

  /// Semantic alias for cleanup lane pass.
  bool get cleanupPass => resourceLifecyclePass;

  // ── Lane 6: struct & transform parity ─────────────────────────────────────

  /// Whether native VulkanOverlayLayerDescriptor layout and pure-math
  /// placement computation match Dart evaluator expectations.
  bool get structParityPass => _gate('structParityOk');

  /// Whether every parity gate passed.
  bool get parityPass => parityGateKeys.every(_gate);

  // ── Canonical route ───────────────────────────────────────────────────────

  /// Whether the canonical route ran against the owned Vulkan target with no
  /// lane skipped or substituted.
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

  /// Whether every native diagnostic gate passed (computed Dart-side from
  /// [gates], independent of [nativeAllLanesPass]).
  bool get allNativeLanesPass => allGateKeys.every(_gate);

  /// Full verified pass: requires pass true, decision pass, proofBoundary
  /// exact, marker exact, nativeAllLanesPass true, all gate keys true, and
  /// canonical true.
  bool get isPass =>
      pass &&
      decision == VGTimelineOverlayVulkanRenderSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      nativeAllLanesPass &&
      allNativeLanesPass &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayVulkanRenderSmokeDecision.fail].
  bool get isFail =>
      decision == VGTimelineOverlayVulkanRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayVulkanRenderSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGTimelineOverlayVulkanRenderSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayVulkanRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGTimelineOverlayVulkanRenderSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform or
  /// a device without a usable Vulkan driver.
  factory VGTimelineOverlayVulkanRenderSmokeReport.unsupported(String reason) {
    return VGTimelineOverlayVulkanRenderSmokeReport(
      pass: false,
      decision: VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
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
  factory VGTimelineOverlayVulkanRenderSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGTimelineOverlayVulkanRenderSmokeReport(
      pass: false,
      decision: VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
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
  static VGTimelineOverlayVulkanRenderSmokeReport fromMap(Object? raw) {
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
      return VGTimelineOverlayVulkanRenderSmokeReport.harnessFailure(
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
        ? VGTimelineOverlayVulkanRenderSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGTimelineOverlayVulkanRenderSmokeReport(
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

  static VGTimelineOverlayVulkanRenderSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw(
        explicitDecision,
      );
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGTimelineOverlayVulkanRenderSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGTimelineOverlayVulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGTimelineOverlayVulkanRenderSmokeDecision.fail;
    }
    return VGTimelineOverlayVulkanRenderSmokeDecision.harnessException;
  }

  /// Serializes the report back to a map (round-trips through [fromMap]).
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'decision': decision.name,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      for (final key in allGateKeys) key: gates[key] == true,
      'allNativeLanesPass': nativeAllLanesPass,
      'nativeAllLanesPass': nativeAllLanesPass,
      'details': Map<String, Object?>.from(details),
      'raw': raw,
    };
  }

  static const String _method =
      'runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 VulkanOverlayCompositor
  /// multi-layer shader/raster diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGTimelineOverlayVulkanRenderSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`UNIMPLEMENTED` yields a
  /// [VGTimelineOverlayVulkanRenderSmokeDecision.unsupported] report; any
  /// other error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGTimelineOverlayVulkanRenderSmokeReport>
  runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGTimelineOverlayVulkanRenderSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGTimelineOverlayVulkanRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGTimelineOverlayVulkanRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGTimelineOverlayVulkanRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGTimelineOverlayVulkanRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGTimelineOverlayVulkanRenderSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGTimelineOverlayVulkanRenderSmokeReport &&
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
      'VGTimelineOverlayVulkanRenderSmokeReport('
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
