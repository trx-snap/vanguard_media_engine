// vg_timeline_transition_gles_render_smoke.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (sub-slice GLES-RENDER):
// Android True-DAG V4.3 foundation GlesTimelineTransitionCompositor
// shader/raster proof smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5TimelineTransitionGlesRenderSmoke` MethodChannel route.
// Diagnostic-only — validates that the private native GLES transition helper
// fails closed on invalid parameters, rasterizes compositor-owned crossfade /
// hard-cut / slide / wipe geometry (from ComputeTransitionGeometry) into the
// expected pixel ownership, accepts GL_TEXTURE_2D fully and
// GL_TEXTURE_EXTERNAL_OES structurally, and restores GL viewport/state.
// No Vulkan, no decode, no export session, no SurfaceTexture/decoder OES
// frame proof, and no product/editor UI.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 GLES transition render smoke
/// harness.
enum VGTimelineTransitionGlesRenderSmokeDecision {
  /// All native GLES transition render gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGTimelineTransitionGlesRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGTimelineTransitionGlesRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGTimelineTransitionGlesRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGTimelineTransitionGlesRenderSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGTimelineTransitionGlesRenderSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGTimelineTransitionGlesRenderSmokeDecision.harnessException;
    }
    for (final value in VGTimelineTransitionGlesRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGTimelineTransitionGlesRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGTimelineTransitionGlesRenderSmokeReport {
  const VGTimelineTransitionGlesRenderSmokeReport({
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
      'native_gles_timeline_transition_compositor_shader_raster_only_no_vulkan_no_decode_no_export';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_FAIL';

  /// EGL/synthetic-texture setup gate key.
  static const List<String> setupGateKeys = <String>['eglSetupOk'];

  /// Lane 1: parameter validation gate keys (fail-closed, no GL draw).
  static const List<String> paramValidationGateKeys = <String>[
    'invalidTextureRejectedOk',
    'invalidDimensionsRejectedOk',
    'nonFiniteProgressRejectedOk',
    'nonFiniteWeightRejectedOk',
    'unsupportedTargetRejectedOk',
  ];

  /// Lane 2: hard cut + crossfade raster gate keys.
  static const List<String> crossfadeGateKeys = <String>[
    'hardCutNoneOk',
    'crossfadeStartOk',
    'crossfadeMidOk',
    'crossfadeEndOk',
  ];

  /// Lane 3: slide raster gate keys (p=0.5, all four directions).
  static const List<String> slideGateKeys = <String>[
    'slideLeftOk',
    'slideRightOk',
    'slideUpOk',
    'slideDownOk',
  ];

  /// Lane 4: wipe raster gate keys (p=0.5, all four directions).
  static const List<String> wipeGateKeys = <String>[
    'wipeLeftOk',
    'wipeRightOk',
    'wipeUpOk',
    'wipeDownOk',
  ];

  /// Lane 5: texture target acceptance gate keys.
  static const List<String> textureTargetGateKeys = <String>[
    'texture2dTargetAcceptedOk',
    'oesTargetStructuralOk',
    'unsupportedTargetStillRejectedOk',
  ];

  /// GL viewport / binding restoration gate keys.
  static const List<String> stateRestoreGateKeys = <String>[
    'viewportRestoredOk',
    'glStateRestoredOk',
  ];

  /// All gate keys in native emission order.
  static const List<String> allGateKeys = <String>[
    ...setupGateKeys,
    ...paramValidationGateKeys,
    ...crossfadeGateKeys,
    ...slideGateKeys,
    ...wipeGateKeys,
    ...textureTargetGateKeys,
    ...stateRestoreGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGTimelineTransitionGlesRenderSmokeDecision decision;

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
  /// version/renderer, per-draw checksums, probe RGB values, mismatch
  /// counts, OES route errors).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Whether the temporary EGL pbuffer context and synthetic textures were
  /// created.
  bool get eglSetupPass => _gate('eglSetupOk');

  // ── Lane 1: parameter validation ──────────────────────────────────────────

  /// Whether texture name 0 (from or to) was rejected before any GL call.
  bool get invalidTextureRejectedPass => _gate('invalidTextureRejectedOk');

  /// Whether zero surface width/height was rejected.
  bool get invalidDimensionsRejectedPass =>
      _gate('invalidDimensionsRejectedOk');

  /// Whether NaN/Inf progress was rejected.
  bool get nonFiniteProgressRejectedPass =>
      _gate('nonFiniteProgressRejectedOk');

  /// Whether NaN/Inf blend weights were rejected.
  bool get nonFiniteWeightRejectedPass => _gate('nonFiniteWeightRejectedOk');

  /// Whether target 0 / GL_TEXTURE_CUBE_MAP were rejected as unsupported.
  bool get unsupportedTargetRejectedPass =>
      _gate('unsupportedTargetRejectedOk');

  /// Whether every parameter validation gate passed.
  bool get paramValidationPass => paramValidationGateKeys.every(_gate);

  // ── Lane 2: hard cut + crossfade ──────────────────────────────────────────

  /// Whether kNone geometry rendered the "from" layer only (uniform red).
  bool get hardCutNonePass => _gate('hardCutNoneOk');

  /// Whether crossfade p=0.0 rendered uniform red.
  bool get crossfadeStartPass => _gate('crossfadeStartOk');

  /// Whether crossfade p=0.5 rendered the red/blue midpoint (purple).
  bool get crossfadeMidPass => _gate('crossfadeMidOk');

  /// Whether crossfade p=1.0 rendered uniform blue.
  bool get crossfadeEndPass => _gate('crossfadeEndOk');

  /// Whether every crossfade/hard-cut gate passed.
  bool get crossfadePass => crossfadeGateKeys.every(_gate);

  // ── Lane 3: slides ────────────────────────────────────────────────────────

  /// Whether slide-left p=0.5 produced the expected quadrant ownership.
  bool get slideLeftPass => _gate('slideLeftOk');

  /// Whether slide-right p=0.5 produced the expected quadrant ownership.
  bool get slideRightPass => _gate('slideRightOk');

  /// Whether slide-up p=0.5 produced the expected quadrant ownership.
  bool get slideUpPass => _gate('slideUpOk');

  /// Whether slide-down p=0.5 produced the expected quadrant ownership.
  bool get slideDownPass => _gate('slideDownOk');

  /// Whether every slide gate passed.
  bool get slidePass => slideGateKeys.every(_gate);

  // ── Lane 4: wipes ─────────────────────────────────────────────────────────

  /// Whether wipe-left p=0.5 produced the expected crop ownership.
  bool get wipeLeftPass => _gate('wipeLeftOk');

  /// Whether wipe-right p=0.5 produced the expected crop ownership.
  bool get wipeRightPass => _gate('wipeRightOk');

  /// Whether wipe-up p=0.5 produced the expected crop ownership.
  bool get wipeUpPass => _gate('wipeUpOk');

  /// Whether wipe-down p=0.5 produced the expected crop ownership.
  bool get wipeDownPass => _gate('wipeDownOk');

  /// Whether every wipe gate passed.
  bool get wipePass => wipeGateKeys.every(_gate);

  // ── Lane 5: texture targets ───────────────────────────────────────────────

  /// Whether every GL_TEXTURE_2D content draw route succeeded.
  bool get texture2dTargetAcceptedPass => _gate('texture2dTargetAcceptedOk');

  /// Whether GL_TEXTURE_EXTERNAL_OES passed target validation and sampler
  /// compile/link structurally (no SurfaceTexture/decoder frame proof).
  bool get oesTargetStructuralPass => _gate('oesTargetStructuralOk');

  /// Whether unsupported targets were still rejected.
  bool get unsupportedTargetStillRejectedPass =>
      _gate('unsupportedTargetStillRejectedOk');

  /// Whether every texture target gate passed.
  bool get textureTargetPass => textureTargetGateKeys.every(_gate);

  // ── State restoration ─────────────────────────────────────────────────────

  /// Whether the full-surface viewport was restored after sub-rect draws.
  bool get viewportRestoredPass => _gate('viewportRestoredOk');

  /// Whether program/buffer/texture bindings were unbound after draws.
  bool get glStateRestoredPass => _gate('glStateRestoredOk');

  /// Whether every state restoration gate passed.
  bool get stateRestorePass => stateRestoreGateKeys.every(_gate);

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

  /// Full verified pass: native pass flag, every gate, native aggregate,
  /// canonical PASS marker, and canonical proof boundary all agree.
  bool get isVerifiedPass =>
      pass &&
      isPass &&
      allNativeLanesPass &&
      nativeAllLanesPass &&
      hasPassMarker &&
      hasCanonicalProofBoundary;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineTransitionGlesRenderSmokeDecision.pass].
  bool get isPass =>
      decision == VGTimelineTransitionGlesRenderSmokeDecision.pass;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineTransitionGlesRenderSmokeDecision.fail].
  bool get isFail =>
      decision == VGTimelineTransitionGlesRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineTransitionGlesRenderSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGTimelineTransitionGlesRenderSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineTransitionGlesRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGTimelineTransitionGlesRenderSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGTimelineTransitionGlesRenderSmokeReport.unsupported(String reason) {
    return VGTimelineTransitionGlesRenderSmokeReport(
      pass: false,
      decision: VGTimelineTransitionGlesRenderSmokeDecision.unsupported,
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
  factory VGTimelineTransitionGlesRenderSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGTimelineTransitionGlesRenderSmokeReport(
      pass: false,
      decision: VGTimelineTransitionGlesRenderSmokeDecision.harnessException,
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

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGTimelineTransitionGlesRenderSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGTimelineTransitionGlesRenderSmokeReport.harnessFailure(
        'native_result_not_a_map',
        extraDetails: <String, Object?>{'received': raw?.toString() ?? ''},
      );
    }

    final pass = raw['pass'] as bool? ?? false;
    final status = (raw['status'] as String?) ?? (pass ? 'PASS' : 'FAIL');
    final marker = (raw['marker'] as String?) ?? '';
    final proofBoundary = (raw['proofBoundary'] as String?) ?? '';
    final failureReason = (raw['failureReason'] as String?) ?? '';
    final rawString = (raw['raw'] as String?) ?? '';

    final gates = <String, bool>{};
    for (final key in allGateKeys) {
      gates[key] = _truthy(raw[key]);
    }

    // Native emits both spellings with the same value; accept either.
    final nativeAllLanesPass = raw.containsKey('allNativeLanesPass')
        ? _truthy(raw['allNativeLanesPass'])
        : _truthy(raw['nativeAllLanesPass']);

    final detailsRaw = raw['details'];
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
        ? VGTimelineTransitionGlesRenderSmokeDecision.pass
        : _decisionFromStatus(status, raw['decision']);

    return VGTimelineTransitionGlesRenderSmokeReport(
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

  static VGTimelineTransitionGlesRenderSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGTimelineTransitionGlesRenderSmokeDecision.fromRaw(
        explicitDecision,
      );
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGTimelineTransitionGlesRenderSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGTimelineTransitionGlesRenderSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGTimelineTransitionGlesRenderSmokeDecision.fail;
    }
    return VGTimelineTransitionGlesRenderSmokeDecision.harnessException;
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
      'runAndroidDagPhase5TimelineTransitionGlesRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 GlesTimelineTransitionCompositor
  /// shader/raster diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGTimelineTransitionGlesRenderSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields an
  /// [VGTimelineTransitionGlesRenderSmokeDecision.unsupported] report; any
  /// other error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGTimelineTransitionGlesRenderSmokeReport>
  runAndroidDagPhase5TimelineTransitionGlesRenderSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGTimelineTransitionGlesRenderSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGTimelineTransitionGlesRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGTimelineTransitionGlesRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGTimelineTransitionGlesRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGTimelineTransitionGlesRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGTimelineTransitionGlesRenderSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGTimelineTransitionGlesRenderSmokeReport &&
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
      'VGTimelineTransitionGlesRenderSmokeReport('
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
