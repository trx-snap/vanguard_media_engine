// vg_timeline_overlay_gles_render_smoke.dart
// vanguard_media_engine — P5-OVERLAYS-TRANS (sub-slice GLES-RENDER):
// Android True-DAG V4.3 foundation GlesOverlayCompositor
// multi-layer overlay shader/raster proof smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5TimelineOverlayGlesRenderSmoke` MethodChannel route.
// Diagnostic-only — validates that the private native GLES overlay helper
// fails closed on invalid parameters, rasterizes compositor-owned single-layer
// transforms (scale, 90/180 deg rotation, off-canvas clip), per-layer opacity
// with Porter-Duff source-over blending, multi-layer stacking order,
// accepts GL_TEXTURE_2D fully and GL_TEXTURE_EXTERNAL_OES structurally,
// restores GL viewport/blend/binding state, and verifies descriptor parity.
// No Vulkan, no decode, no export session, no keyframe evaluation,
// and no product/editor UI.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 GLES overlay render smoke harness.
enum VGTimelineOverlayGlesRenderSmokeDecision {
  /// All native GLES overlay render gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGTimelineOverlayGlesRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGTimelineOverlayGlesRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGTimelineOverlayGlesRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGTimelineOverlayGlesRenderSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGTimelineOverlayGlesRenderSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGTimelineOverlayGlesRenderSmokeDecision.harnessException;
    }
    for (final value in VGTimelineOverlayGlesRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGTimelineOverlayGlesRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGTimelineOverlayGlesRenderSmokeReport {
  const VGTimelineOverlayGlesRenderSmokeReport({
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
      'native_gles_timeline_overlay_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_FAIL';

  /// Setup gate keys: temporary EGL pbuffer context and synthetic textures.
  static const List<String> setupGateKeys = <String>['eglSetupOk'];

  /// Lane 1: parameter validation gate keys (fail-closed, no GL draw).
  static const List<String> validationGateKeys = <String>[
    'invalidTextureRejectedOk',
    'invalidDimensionsRejectedOk',
    'nonFiniteTransformRejectedOk',
    'invalidOpacityRejectedOk',
    'unsupportedTargetRejectedOk',
  ];

  /// Lane 1 alias for consistency with diagnostic conventions.
  static const List<String> paramValidationGateKeys = validationGateKeys;

  /// Lane 2: single-layer transform raster gate keys.
  static const List<String> transformGateKeys = <String>[
    'singleLayerTransformOk',
  ];

  /// Lane 3: per-layer opacity and Porter-Duff blend gate keys.
  static const List<String> blendGateKeys = <String>['opacityBlendOk'];

  /// Lane 4: multi-layer stacking and z-order gate keys.
  static const List<String> zOrderGateKeys = <String>['multiLayerZOrderOk'];

  /// Lane 5: texture target acceptance gate keys.
  static const List<String> targetGateKeys = <String>[
    'texture2dTargetAcceptedOk',
    'oesTargetStructuralOk',
    'unsupportedTargetStillRejectedOk',
  ];

  /// Lane 5 alias for consistency with diagnostic conventions.
  static const List<String> textureTargetGateKeys = targetGateKeys;

  /// Lane 6: GL blend / viewport / binding state restoration gate keys.
  static const List<String> stateGateKeys = <String>[
    'blendStateRestoredOk',
    'viewportRestoredOk',
    'glStateRestoredOk',
  ];

  /// Lane 6 alias for consistency with diagnostic conventions.
  static const List<String> stateRestoreGateKeys = stateGateKeys;

  /// Lane 7: descriptor and transform parity gate keys.
  static const List<String> parityGateKeys = <String>['structParityOk'];

  /// Lane 7 alias for consistency with diagnostic conventions.
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
    ...targetGateKeys,
    ...stateGateKeys,
    ...parityGateKeys,
    ...canonicalGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGTimelineOverlayGlesRenderSmokeDecision decision;

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
  /// version/renderer, per-draw checksums, mismatch counts, OES route errors).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Whether the temporary EGL pbuffer context and synthetic textures were
  /// created.
  bool get eglSetupPass => _gate('eglSetupOk');

  /// Whether the setup lane passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ── Lane 1: parameter validation ──────────────────────────────────────────

  /// Whether texture name 0 was rejected before any GL call.
  bool get invalidTextureRejectedPass => _gate('invalidTextureRejectedOk');

  /// Whether zero surface width/height or null layers was rejected.
  bool get invalidDimensionsRejectedPass =>
      _gate('invalidDimensionsRejectedOk');

  /// Whether NaN/Inf translation, width, height, rotation, or scale was rejected.
  bool get nonFiniteTransformRejectedPass =>
      _gate('nonFiniteTransformRejectedOk');

  /// Whether NaN/Inf or out-of-range (<0, >1) opacity was rejected.
  bool get invalidOpacityRejectedPass => _gate('invalidOpacityRejectedOk');

  /// Whether target 0 / GL_TEXTURE_CUBE_MAP were rejected as unsupported.
  bool get unsupportedTargetRejectedPass =>
      _gate('unsupportedTargetRejectedOk');

  /// Whether every parameter validation gate passed.
  bool get validationPass => validationGateKeys.every(_gate);

  /// Semantic alias for validation lane pass.
  bool get paramValidationPass => validationPass;

  // ── Lane 2: single-layer transform ────────────────────────────────────────

  /// Whether single-layer translate/scale, 90/180 deg rotation, and off-canvas
  /// clipping passed pixel verification.
  bool get singleLayerTransformPass => _gate('singleLayerTransformOk');

  /// Whether every transform gate passed.
  bool get transformPass => transformGateKeys.every(_gate);

  // ── Lane 3: per-layer opacity & Porter-Duff blend ─────────────────────────

  /// Whether uniform opacity, texture alpha, alpha*opacity, zero, and opaque
  /// blending passed pixel verification.
  bool get opacityBlendPass => _gate('opacityBlendOk');

  /// Whether every blend gate passed.
  bool get blendPass => blendGateKeys.every(_gate);

  // ── Lane 4: multi-layer stacking / z-order ────────────────────────────────

  /// Whether forward stacking, reversed order, and empty layer list passed.
  bool get multiLayerZOrderPass => _gate('multiLayerZOrderOk');

  /// Whether every z-order / stacking gate passed.
  bool get zOrderPass => zOrderGateKeys.every(_gate);

  // ── Lane 5: texture targets ───────────────────────────────────────────────

  /// Whether GL_TEXTURE_2D was fully accepted across all draw routes.
  bool get texture2dTargetAcceptedPass => _gate('texture2dTargetAcceptedOk');

  /// Whether GL_TEXTURE_EXTERNAL_OES passed target validation and sampler
  /// compile/link structurally (no SurfaceTexture/decoder frame proof).
  bool get oesTargetStructuralPass => _gate('oesTargetStructuralOk');

  /// Whether unsupported targets were still rejected after OES execution.
  bool get unsupportedTargetStillRejectedPass =>
      _gate('unsupportedTargetStillRejectedOk');

  /// Whether every texture target gate passed.
  bool get targetPass => targetGateKeys.every(_gate);

  /// Semantic alias for texture target lane pass.
  bool get textureTargetPass => targetPass;

  // ── Lane 6: GL state restoration ──────────────────────────────────────────

  /// Whether GL blend enable, equation, and func were restored.
  bool get blendStateRestoredPass => _gate('blendStateRestoredOk');

  /// Whether GL viewport was restored.
  bool get viewportRestoredPass => _gate('viewportRestoredOk');

  /// Whether GL active texture, texture binding, program, and array buffer were restored.
  bool get glStateRestoredPass => _gate('glStateRestoredOk');

  /// Whether every state restoration gate passed.
  bool get statePass => stateGateKeys.every(_gate);

  /// Semantic alias for state restoration lane pass.
  bool get stateRestorePass => statePass;

  // ── Lane 7: struct & transform parity ─────────────────────────────────────

  /// Whether native GlesOverlayLayerDescriptor layout and pure-math
  /// transform computation match Dart evaluator expectations.
  bool get structParityPass => _gate('structParityOk');

  /// Whether every parity gate passed.
  bool get parityPass => parityGateKeys.every(_gate);

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

  /// Whether every native diagnostic gate passed (computed Dart-side from
  /// [gates], independent of [nativeAllLanesPass]).
  bool get allNativeLanesPass => allGateKeys.every(_gate);

  /// Full verified pass: requires pass true, decision pass, proofBoundary
  /// exact, marker exact, nativeAllLanesPass true, all gate keys true, and
  /// canonical true.
  bool get isPass =>
      pass &&
      decision == VGTimelineOverlayGlesRenderSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      nativeAllLanesPass &&
      allNativeLanesPass &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayGlesRenderSmokeDecision.fail].
  bool get isFail => decision == VGTimelineOverlayGlesRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayGlesRenderSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGTimelineOverlayGlesRenderSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayGlesRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGTimelineOverlayGlesRenderSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGTimelineOverlayGlesRenderSmokeReport.unsupported(String reason) {
    return VGTimelineOverlayGlesRenderSmokeReport(
      pass: false,
      decision: VGTimelineOverlayGlesRenderSmokeDecision.unsupported,
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
  factory VGTimelineOverlayGlesRenderSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGTimelineOverlayGlesRenderSmokeReport(
      pass: false,
      decision: VGTimelineOverlayGlesRenderSmokeDecision.harnessException,
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
  static VGTimelineOverlayGlesRenderSmokeReport fromMap(Object? raw) {
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
      return VGTimelineOverlayGlesRenderSmokeReport.harnessFailure(
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
        ? VGTimelineOverlayGlesRenderSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGTimelineOverlayGlesRenderSmokeReport(
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

  static VGTimelineOverlayGlesRenderSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGTimelineOverlayGlesRenderSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGTimelineOverlayGlesRenderSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGTimelineOverlayGlesRenderSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGTimelineOverlayGlesRenderSmokeDecision.fail;
    }
    return VGTimelineOverlayGlesRenderSmokeDecision.harnessException;
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
      'runAndroidDagPhase5TimelineOverlayGlesRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 GlesOverlayCompositor
  /// multi-layer shader/raster diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGTimelineOverlayGlesRenderSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields a
  /// [VGTimelineOverlayGlesRenderSmokeDecision.unsupported] report; any
  /// other error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGTimelineOverlayGlesRenderSmokeReport>
  runAndroidDagPhase5TimelineOverlayGlesRenderSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGTimelineOverlayGlesRenderSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGTimelineOverlayGlesRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGTimelineOverlayGlesRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGTimelineOverlayGlesRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGTimelineOverlayGlesRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGTimelineOverlayGlesRenderSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGTimelineOverlayGlesRenderSmokeReport &&
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
      'VGTimelineOverlayGlesRenderSmokeReport('
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
