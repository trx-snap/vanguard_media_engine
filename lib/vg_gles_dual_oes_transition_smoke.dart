// vg_gles_dual_oes_transition_smoke.dart
// vanguard_media_engine - P5-GLES-EXPORT-DUAL-OES-TRANSITION-READINESS:
// diagnostic-only Android True-DAG proof that TWO real MediaCodec decoders
// feed two independent SurfaceTexture / GL_TEXTURE_EXTERNAL_OES textures on
// one caller-owned ES3 EGL context, then render one compositor-owned GLES
// transition frame through the private
// `GlesTimelineTransitionCompositor::drawTransition` helper.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5GlesDualOesTransitionSmoke` MethodChannel route.
// Diagnostic-only: no production export route/session/backend-selector/
// encoder change.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 GLES dual-OES transition smoke
/// harness.
enum VGGlesDualOesTransitionSmokeDecision {
  /// All native/harness gates passed.
  pass,

  /// One or more gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGGlesDualOesTransitionSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGGlesDualOesTransitionSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGGlesDualOesTransitionSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGGlesDualOesTransitionSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGGlesDualOesTransitionSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGGlesDualOesTransitionSmokeDecision.harnessException;
    }
    for (final value in VGGlesDualOesTransitionSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGGlesDualOesTransitionSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke],
/// mirroring the native harness's result map.
@immutable
class VGGlesDualOesTransitionSmokeReport {
  const VGGlesDualOesTransitionSmokeReport({
    required this.pass,
    required this.decision,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.gates,
    required this.details,
    required this.raw,
    required this.glMajorVersion,
    required this.fromPtsUs,
    required this.toPtsUs,
    required this.nativeRaw,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'diagnostic_dual_mediacodec_surfacetexture_oes_to_gles_transition_compositor_no_export';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_FAIL';

  /// Fail-closed argument validation (clip paths readable) gate keys.
  static const List<String> argumentValidationGateKeys = <String>[
    'argumentValidationOk',
  ];

  /// EGL pbuffer ES3-first context setup gate keys.
  static const List<String> setupGateKeys = <String>['eglSetupOk'];

  /// ES3 current-context assertion gate keys (GL_MAJOR_VERSION query, no GL
  /// error, major >= 3).
  static const List<String> es3ContextGateKeys = <String>[
    'es3ContextVerifiedOk',
  ];

  /// Dual real MediaCodec decode + frame-available + updateTexImage() gate
  /// keys.
  static const List<String> decodeGateKeys = <String>[
    'dualDecoderSetupOk',
    'bothFramesAvailableOk',
    'bothUpdateTexImageOk',
  ];

  /// Native `GlesTimelineTransitionCompositor::drawTransition` seam call +
  /// pixel-proof gate keys.
  static const List<String> transitionGateKeys = <String>[
    'nativeTransitionDrawOk',
    'pixelProofOk',
  ];

  /// GL viewport/program/buffer/texture-binding restoration gate keys.
  static const List<String> stateGateKeys = <String>['stateRestoredOk'];

  /// Resource cleanup gate keys.
  static const List<String> cleanupGateKeys = <String>['cleanupOk'];

  /// All gate keys in exact native/harness emission order.
  static const List<String> allGateKeys = <String>[
    ...argumentValidationGateKeys,
    ...setupGateKeys,
    ...es3ContextGateKeys,
    ...decodeGateKeys,
    ...transitionGateKeys,
    ...stateGateKeys,
    ...cleanupGateKeys,
  ];

  /// Primary success flag emitted by the harness.
  final bool pass;

  /// The parsed decision.
  final VGGlesDualOesTransitionSmokeDecision decision;

  /// Raw status string (`PASS`, `FAIL`, `UNSUPPORTED`, ...).
  final String status;

  /// PASS/FAIL marker string emitted by the harness.
  final String marker;

  /// Proof boundary string proving execution of the verified diagnostic.
  final String proofBoundary;

  /// First failure reason reported by the harness, empty on pass.
  final String failureReason;

  /// Per-gate boolean results keyed by gate name.
  final Map<String, bool> gates;

  /// Free-form diagnostic details emitted by the harness (glMajorVersion
  /// telemetry echo, decoded frame PTS, native pixel-probe samples).
  final Map<String, Object?> details;

  /// Raw harness result, when available (empty when the harness returned a
  /// Map without one).
  final String raw;

  /// The GL major version (2 or 3) negotiated by the harness's EGL context.
  final int glMajorVersion;

  /// Decoded "from" clip frame's presentation time (microseconds), or -1
  /// when never decoded.
  final int fromPtsUs;

  /// Decoded "to" clip frame's presentation time (microseconds), or -1 when
  /// never decoded.
  final int toPtsUs;

  /// Compact raw JSON string returned by the native
  /// `drawAndroidDagPhase5GlesDualOesTransition` seam call.
  final String nativeRaw;

  bool _gate(String key) => gates[key] == true;

  // -- Argument validation -----------------------------------------------

  /// Whether the requested clip paths passed fail-closed validation.
  bool get argumentValidationPass => _gate('argumentValidationOk');

  /// Whether every argument validation gate passed.
  bool get argumentValidationGroupPass =>
      argumentValidationGateKeys.every(_gate);

  // -- Setup ----------------------------------------------------------------

  /// Whether the ES3-first EGL pbuffer context was created.
  bool get eglSetupPass => _gate('eglSetupOk');

  /// Whether every setup gate passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // -- ES3 current-context assertion ---------------------------------------

  /// Whether the EGL context current on the harness thread was verified to
  /// be truly ES3-capable.
  bool get es3ContextVerifiedPass => _gate('es3ContextVerifiedOk');

  /// Whether every ES3 current-context assertion gate passed.
  bool get es3ContextGroupPass => es3ContextGateKeys.every(_gate);

  // -- Decode -----------------------------------------------------------------

  /// Whether both hardware decoders were configured and started.
  bool get dualDecoderSetupPass => _gate('dualDecoderSetupOk');

  /// Whether both decoders' frame-available callbacks arrived within the
  /// bounded wait.
  bool get bothFramesAvailablePass => _gate('bothFramesAvailableOk');

  /// Whether `SurfaceTexture.updateTexImage()` succeeded for both textures.
  bool get bothUpdateTexImagePass => _gate('bothUpdateTexImageOk');

  /// Whether every decode gate passed.
  bool get decodeGroupPass => decodeGateKeys.every(_gate);

  // -- Native transition draw ------------------------------------------------

  /// Whether the native `GlesTimelineTransitionCompositor::drawTransition`
  /// seam call succeeded.
  bool get nativeTransitionDrawPass => _gate('nativeTransitionDrawOk');

  /// Whether the post-draw pixel sample proved real, non-sentinel, non-black
  /// composited content.
  bool get pixelProofPass => _gate('pixelProofOk');

  /// Whether every native transition draw gate passed.
  bool get transitionGroupPass => transitionGateKeys.every(_gate);

  // -- State restoration ------------------------------------------------------

  /// Whether GL viewport/program/buffer/texture-unit bindings were restored
  /// per the compositor's contract after the draw.
  bool get stateRestoredPass => _gate('stateRestoredOk');

  /// Whether every state restoration gate passed.
  bool get statePass => stateGateKeys.every(_gate);

  // -- Cleanup -----------------------------------------------------------------

  /// Whether every EGL/GL/MediaCodec/SurfaceTexture resource was released
  /// without an unexpected exception.
  bool get cleanupPass => _gate('cleanupOk');

  /// Whether every cleanup gate passed.
  bool get cleanupGroupPass => cleanupGateKeys.every(_gate);

  // -- Aggregates ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every gate key passed (computed Dart-side from [gates]).
  bool get allGatesPass => allGateKeys.every(_gate);

  /// Full verified pass: requires pass true, decision pass, proofBoundary
  /// exact, marker exact, and every gate key true.
  bool get isPass =>
      pass &&
      decision == VGGlesDualOesTransitionSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      allGatesPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGGlesDualOesTransitionSmokeDecision.fail].
  bool get isFail => decision == VGGlesDualOesTransitionSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGGlesDualOesTransitionSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGGlesDualOesTransitionSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGGlesDualOesTransitionSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGGlesDualOesTransitionSmokeDecision.harnessException;

  // -- Constructors for synthesized reports ----------------------------------

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGGlesDualOesTransitionSmokeReport.unsupported(String reason) {
    return VGGlesDualOesTransitionSmokeReport(
      pass: false,
      decision: VGGlesDualOesTransitionSmokeDecision.unsupported,
      status: 'UNSUPPORTED',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
      }),
      raw: '{"pass":false,"status":"UNSUPPORTED","failureReason":"$reason"}',
      glMajorVersion: 0,
      fromPtsUs: -1,
      toPtsUs: -1,
      nativeRaw: '',
    );
  }

  /// A fail-shaped report for a harness-level failure (timeout, exception,
  /// malformed native payload).
  factory VGGlesDualOesTransitionSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGGlesDualOesTransitionSmokeReport(
      pass: false,
      decision: VGGlesDualOesTransitionSmokeDecision.harnessException,
      status: 'FAIL',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
        ...extraDetails,
      }),
      raw: '{"pass":false,"status":"FAIL","failureReason":"$reason"}',
      glMajorVersion: 0,
      fromPtsUs: -1,
      toPtsUs: -1,
      nativeRaw: '',
    );
  }

  static bool _truthy(Object? value) =>
      value == true || (value is String && value == 'true');

  static int _intOr(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  /// Parses a report from the raw native map or JSON string. Defensive
  /// against non-map, non-JSON, missing, or malformed fields.
  static VGGlesDualOesTransitionSmokeReport fromMap(Object? raw) {
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
      return VGGlesDualOesTransitionSmokeReport.harnessFailure(
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
        ? VGGlesDualOesTransitionSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGGlesDualOesTransitionSmokeReport(
      pass: pass,
      decision: decision,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      gates: Map<String, bool>.unmodifiable(gates),
      details: Map<String, Object?>.unmodifiable(details),
      raw: rawString,
      glMajorVersion: _intOr(map['glMajorVersion'], 0),
      fromPtsUs: _intOr(map['fromPtsUs'], -1),
      toPtsUs: _intOr(map['toPtsUs'], -1),
      nativeRaw: (map['nativeRaw'] as String?) ?? '',
    );
  }

  static VGGlesDualOesTransitionSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGGlesDualOesTransitionSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGGlesDualOesTransitionSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGGlesDualOesTransitionSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGGlesDualOesTransitionSmokeDecision.fail;
    }
    return VGGlesDualOesTransitionSmokeDecision.harnessException;
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
      'details': Map<String, Object?>.from(details),
      'raw': raw,
      'glMajorVersion': glMajorVersion,
      'fromPtsUs': fromPtsUs,
      'toPtsUs': toPtsUs,
      'nativeRaw': nativeRaw,
    };
  }

  static const String _method = 'runAndroidDagPhase5GlesDualOesTransitionSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 GLES dual-OES transition
  /// diagnostic smoke harness against [fromClipPath] and [toClipPath].
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGGlesDualOesTransitionSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields a
  /// [VGGlesDualOesTransitionSmokeDecision.unsupported] report; any other
  /// error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGGlesDualOesTransitionSmokeReport>
  runAndroidDagPhase5GlesDualOesTransitionSmoke({
    required String fromClipPath,
    required String toClipPath,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method, <String, Object?>{
        'fromClipPath': fromClipPath,
        'toClipPath': toClipPath,
      });
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGGlesDualOesTransitionSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGGlesDualOesTransitionSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGGlesDualOesTransitionSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGGlesDualOesTransitionSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGGlesDualOesTransitionSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGGlesDualOesTransitionSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGGlesDualOesTransitionSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        mapEquals(other.gates, gates) &&
        mapEquals(other.details, details) &&
        other.raw == raw &&
        other.glMajorVersion == glMajorVersion &&
        other.fromPtsUs == fromPtsUs &&
        other.toPtsUs == toPtsUs &&
        other.nativeRaw == nativeRaw;
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
    _stableMapHash(details),
    raw,
    glMajorVersion,
    fromPtsUs,
    toPtsUs,
    nativeRaw,
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGGlesDualOesTransitionSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'gates: $gates, '
      'glMajorVersion: $glMajorVersion, '
      'fromPtsUs: $fromPtsUs, '
      'toPtsUs: $toPtsUs, '
      'details: $details)';
}
