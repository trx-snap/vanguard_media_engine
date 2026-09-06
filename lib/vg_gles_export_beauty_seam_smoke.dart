// vg_gles_export_beauty_seam_smoke.dart
// vanguard_media_engine - P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS:
// diagnostic-only Android True-DAG proof that a REAL MediaCodec decode ->
// SurfaceTexture -> GL_TEXTURE_EXTERNAL_OES frame, resolved on its own
// current-verified ES3 EGL pbuffer context to a GL_TEXTURE_2D RGBA8 raster
// via an FBO blit, still routes into the caller-current native
// `GlesBeautyV2Compositor::DrawBeautyV2` seam already exercised by the
// synthetic-pbuffer P5-BEAUTY-V2-GLES-RENDER diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5GlesExportBeautySeamSmoke` MethodChannel route.
// Diagnostic-only: no production GLES Beauty export route/session/backend-
// selector/encoder change.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 GLES export beauty seam smoke
/// harness.
enum VGGlesExportBeautySeamSmokeDecision {
  /// All native GLES export beauty seam gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGGlesExportBeautySeamSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGGlesExportBeautySeamSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGGlesExportBeautySeamSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGGlesExportBeautySeamSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGGlesExportBeautySeamSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGGlesExportBeautySeamSmokeDecision.harnessException;
    }
    for (final value in VGGlesExportBeautySeamSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGGlesExportBeautySeamSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGGlesExportBeautySeamSmokeReport.runAndroidDagPhase5GlesExportBeautySeamSmoke],
/// mirroring the native harness's result map.
@immutable
class VGGlesExportBeautySeamSmokeReport {
  const VGGlesExportBeautySeamSmokeReport({
    required this.pass,
    required this.decision,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.gates,
    required this.details,
    required this.raw,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_gles_export_beauty_seam_caller_current_context_diagnostic_only_no_production_export';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM_PHYSICAL_SMOKE_FAIL';

  /// Setup gate keys: EGL pbuffer context + resolve/beauty target textures
  /// and FBOs.
  static const List<String> setupGateKeys = <String>['eglSetupOk'];

  /// ES3 current-context assertion gate keys: proves the EGL context now
  /// current on the harness thread is truly ES3-capable (GL_MAJOR_VERSION
  /// query, no GL error, major >= 3), rather than trusting the
  /// EGL_CONTEXT_CLIENT_VERSION request alone.
  static const List<String> es3ContextGateKeys = <String>[
    'es3ContextVerifiedOk',
  ];

  /// Fail-closed argument validation gate keys.
  static const List<String> validationGateKeys = <String>[
    'invalidArgumentsRejectedOk',
  ];

  /// Real MediaCodec decode + SurfaceTexture.updateTexImage() gate keys.
  static const List<String> decodeGateKeys = <String>[
    'decodeOk',
    'updateTexImageOk',
  ];

  /// OES -> GL_TEXTURE_2D RGBA8 resolve gate keys.
  static const List<String> resolveGateKeys = <String>[
    'oesResolveOk',
    'resolvedNonUniformOk',
  ];

  /// Native `GlesBeautyV2Compositor::DrawBeautyV2` seam call gate keys.
  static const List<String> seamGateKeys = <String>['seamCallOk'];

  /// glReadPixels composite (Beauty vs un-beautified, strong vs default
  /// intensity) gate keys.
  static const List<String> compositeGateKeys = <String>[
    'beautyDeltaOk',
    'strongIntensityDeltaOk',
  ];

  /// GL viewport/program/framebuffer/texture-binding restoration gate keys.
  static const List<String> stateGateKeys = <String>['stateRestoredOk'];

  /// Resource cleanup gate keys.
  static const List<String> cleanupGateKeys = <String>['cleanupOk'];

  /// Canonical route verification gate keys.
  static const List<String> canonicalGateKeys = <String>['canonical'];

  /// All gate keys in exact native emission order.
  static const List<String> allGateKeys = <String>[
    ...setupGateKeys,
    ...es3ContextGateKeys,
    ...validationGateKeys,
    ...decodeGateKeys,
    ...resolveGateKeys,
    ...seamGateKeys,
    ...compositeGateKeys,
    ...stateGateKeys,
    ...cleanupGateKeys,
    ...canonicalGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGGlesExportBeautySeamSmokeDecision decision;

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

  /// Free-form diagnostic details emitted by the native harness (seam raw
  /// JSON, before/after probe pixel RGBA samples, invalid-argument probes,
  /// ES3 current-context query details, delta totals).
  final Map<String, Object?> details;

  /// Raw native result, when available (empty when the harness returned a
  /// Map without one).
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // -- Setup -----------------------------------------------------------------

  /// Whether the temporary ES3 EGL pbuffer context and resolve/beauty target
  /// textures/FBOs were created.
  bool get eglSetupPass => _gate('eglSetupOk');

  /// Whether the setup lane passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // -- ES3 current-context assertion ------------------------------------------

  /// Whether the EGL context current on the harness thread was verified to
  /// be truly ES3-capable (GL_MAJOR_VERSION query, no GL error, major >= 3).
  bool get es3ContextVerifiedPass => _gate('es3ContextVerifiedOk');

  /// Whether every ES3 current-context assertion gate passed.
  bool get es3ContextGroupPass => es3ContextGateKeys.every(_gate);

  // -- Validation -------------------------------------------------------------

  /// Whether the native seam rejected invalid dimensions, input texture,
  /// target FBO, and intensity before touching any real decode/draw state.
  bool get invalidArgumentsRejectedPass => _gate('invalidArgumentsRejectedOk');

  /// Whether every validation gate passed.
  bool get validationPass => validationGateKeys.every(_gate);

  // -- Decode ---------------------------------------------------------------

  /// Whether MediaCodec released one renderable output buffer onto the
  /// SurfaceTexture.
  bool get decodePass => _gate('decodeOk');

  /// Whether `SurfaceTexture.updateTexImage()` succeeded after the frame
  /// availability signal.
  bool get updateTexImagePass => _gate('updateTexImageOk');

  /// Whether every decode gate passed.
  bool get decodeGroupPass => decodeGateKeys.every(_gate);

  // -- Resolve ----------------------------------------------------------------

  /// Whether the OES -> GL_TEXTURE_2D RGBA8 FBO resolve draw succeeded with
  /// no GL error.
  bool get oesResolvePass => _gate('oesResolveOk');

  /// Whether the resolved 2D texture proved non-uniform across the sample
  /// points before Beauty ran.
  bool get resolvedNonUniformPass => _gate('resolvedNonUniformOk');

  /// Whether every resolve gate passed.
  bool get resolveGroupPass => resolveGateKeys.every(_gate);

  // -- Seam -------------------------------------------------------------------

  /// Whether the native `GlesBeautyV2Compositor::DrawBeautyV2` seam call
  /// succeeded (both default- and strong-intensity variants) on the
  /// already-current caller context.
  bool get seamCallPass => _gate('seamCallOk');

  /// Whether every seam gate passed.
  bool get seamGroupPass => seamGateKeys.every(_gate);

  // -- Composite assertion ----------------------------------------------------

  /// Whether the Beauty output differed from the un-beautified resolved
  /// frame at every sample point.
  bool get beautyDeltaPass => _gate('beautyDeltaOk');

  /// Whether the strong-intensity variant's delta exceeded the
  /// default-intensity variant's delta.
  bool get strongIntensityDeltaPass => _gate('strongIntensityDeltaOk');

  /// Whether every composite gate passed.
  bool get compositePass => compositeGateKeys.every(_gate);

  // -- State restoration ------------------------------------------------------

  /// Whether GL viewport, current program, framebuffer binding, active
  /// texture, and texture-unit 0 bindings (2D and external OES) were
  /// restored after each seam call.
  bool get stateRestoredPass => _gate('stateRestoredOk');

  /// Whether every state restoration gate passed.
  bool get statePass => stateGateKeys.every(_gate);

  // -- Cleanup -----------------------------------------------------------------

  /// Whether every EGL/GL/MediaCodec/SurfaceTexture resource was released
  /// without an unexpected exception.
  bool get cleanupPass => _gate('cleanupOk');

  /// Whether every cleanup gate passed.
  bool get cleanupGroupPass => cleanupGateKeys.every(_gate);

  // -- Canonical route -------------------------------------------------------

  /// Whether the canonical route ran end-to-end with no lane skipped or
  /// substituted.
  bool get canonicalPass => _gate('canonical');

  /// Semantic alias for canonical pass.
  bool get canonical => canonicalPass;

  // -- Aggregates ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every native diagnostic gate passed (computed Dart-side from
  /// [gates]).
  bool get allGatesPass => allGateKeys.every(_gate);

  /// Full verified pass: requires pass true, decision pass, proofBoundary
  /// exact, marker exact, every gate key true, and canonical true.
  bool get isPass =>
      pass &&
      decision == VGGlesExportBeautySeamSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      allGatesPass &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGGlesExportBeautySeamSmokeDecision.fail].
  bool get isFail => decision == VGGlesExportBeautySeamSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGGlesExportBeautySeamSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGGlesExportBeautySeamSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGGlesExportBeautySeamSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGGlesExportBeautySeamSmokeDecision.harnessException;

  // -- Constructors for synthesized reports ----------------------------------

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGGlesExportBeautySeamSmokeReport.unsupported(String reason) {
    return VGGlesExportBeautySeamSmokeReport(
      pass: false,
      decision: VGGlesExportBeautySeamSmokeDecision.unsupported,
      status: 'UNSUPPORTED',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
      }),
      raw: '{"pass":false,"status":"UNSUPPORTED","failureReason":"$reason"}',
    );
  }

  /// A fail-shaped report for a harness-level failure (timeout, exception,
  /// malformed native payload).
  factory VGGlesExportBeautySeamSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGGlesExportBeautySeamSmokeReport(
      pass: false,
      decision: VGGlesExportBeautySeamSmokeDecision.harnessException,
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
    );
  }

  static bool _truthy(Object? value) =>
      value == true || (value is String && value == 'true');

  /// Parses a report from the raw native map or JSON string. Defensive
  /// against non-map, non-JSON, missing, or malformed fields.
  static VGGlesExportBeautySeamSmokeReport fromMap(Object? raw) {
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
      return VGGlesExportBeautySeamSmokeReport.harnessFailure(
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
        ? VGGlesExportBeautySeamSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGGlesExportBeautySeamSmokeReport(
      pass: pass,
      decision: decision,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      gates: Map<String, bool>.unmodifiable(gates),
      details: Map<String, Object?>.unmodifiable(details),
      raw: rawString,
    );
  }

  static VGGlesExportBeautySeamSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGGlesExportBeautySeamSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGGlesExportBeautySeamSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGGlesExportBeautySeamSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGGlesExportBeautySeamSmokeDecision.fail;
    }
    return VGGlesExportBeautySeamSmokeDecision.harnessException;
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
    };
  }

  static const String _method = 'runAndroidDagPhase5GlesExportBeautySeamSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 GLES export beauty seam
  /// diagnostic smoke harness against [videoPath].
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGGlesExportBeautySeamSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields a
  /// [VGGlesExportBeautySeamSmokeDecision.unsupported] report; any other
  /// error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGGlesExportBeautySeamSmokeReport>
  runAndroidDagPhase5GlesExportBeautySeamSmoke({
    required String videoPath,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method, <String, Object?>{
        'videoPath': videoPath,
      });
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGGlesExportBeautySeamSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGGlesExportBeautySeamSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGGlesExportBeautySeamSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGGlesExportBeautySeamSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGGlesExportBeautySeamSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGGlesExportBeautySeamSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGGlesExportBeautySeamSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        mapEquals(other.gates, gates) &&
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
    _stableMapHash(details),
    raw,
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGGlesExportBeautySeamSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'gates: $gates, '
      'details: $details)';
}
