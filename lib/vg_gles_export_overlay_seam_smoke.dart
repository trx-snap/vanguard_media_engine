// vg_gles_export_overlay_seam_smoke.dart
// vanguard_media_engine - P5-GLES-EXPORT-OVERLAY-SEAM-A: diagnostic-only
// Android True-DAG proof that a REAL MediaCodec decode -> SurfaceTexture ->
// GL_TEXTURE_EXTERNAL_OES frame, drawn on its own ES2 EGL pbuffer context
// exactly like AndroidTimelineVideoEncoder.kt's decode/OES/EGL lifecycle,
// still routes into the caller-current native `GlesOverlayCompositor::
// drawOverlays` seam already exercised by the synthetic-pbuffer
// P5-OVERLAYS-TRANS diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5GlesExportOverlaySeamSmoke` MethodChannel route.
// Diagnostic-only: no production export/session/backend-selector/encoder
// change.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 GLES export overlay seam smoke
/// harness.
enum VGGlesExportOverlaySeamSmokeDecision {
  /// All native GLES export overlay seam gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGGlesExportOverlaySeamSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGGlesExportOverlaySeamSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGGlesExportOverlaySeamSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGGlesExportOverlaySeamSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGGlesExportOverlaySeamSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGGlesExportOverlaySeamSmokeDecision.harnessException;
    }
    for (final value in VGGlesExportOverlaySeamSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGGlesExportOverlaySeamSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke],
/// mirroring the native harness's result map.
@immutable
class VGGlesExportOverlaySeamSmokeReport {
  const VGGlesExportOverlaySeamSmokeReport({
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
      'native_gles_export_overlay_seam_caller_current_context_diagnostic_only_no_production_export';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_FAIL';

  /// Setup gate keys: ES2 EGL pbuffer context, OES/overlay textures.
  static const List<String> setupGateKeys = <String>['eglSetupOk'];

  /// Fail-closed argument validation gate keys.
  static const List<String> validationGateKeys = <String>[
    'invalidArgumentsRejectedOk',
  ];

  /// Real MediaCodec decode + SurfaceTexture.updateTexImage() gate keys.
  static const List<String> decodeGateKeys = <String>[
    'decodeOk',
    'updateTexImageOk',
  ];

  /// Base OES-passthrough draw + native seam call gate keys.
  static const List<String> drawGateKeys = <String>['baseDrawOk', 'seamCallOk'];

  /// glReadPixels composite (inside/outside overlay bounds) gate keys.
  static const List<String> compositeGateKeys = <String>[
    'compositeAssertionOk',
  ];

  /// GL viewport/program/blend/binding restoration gate keys.
  static const List<String> stateGateKeys = <String>['stateRestoredOk'];

  /// Resource cleanup gate keys.
  static const List<String> cleanupGateKeys = <String>['cleanupOk'];

  /// Canonical route verification gate keys.
  static const List<String> canonicalGateKeys = <String>['canonical'];

  /// All gate keys in exact native emission order.
  static const List<String> allGateKeys = <String>[
    ...setupGateKeys,
    ...validationGateKeys,
    ...decodeGateKeys,
    ...drawGateKeys,
    ...compositeGateKeys,
    ...stateGateKeys,
    ...cleanupGateKeys,
    ...canonicalGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGGlesExportOverlaySeamSmokeDecision decision;

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
  /// JSON, before/after probe pixel RGBA strings, invalid-argument probes).
  final Map<String, Object?> details;

  /// Raw native result, when available (empty when the harness returned a
  /// Map without one).
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // -- Setup -----------------------------------------------------------------

  /// Whether the temporary ES2 EGL pbuffer context and OES/overlay textures
  /// were created.
  bool get eglSetupPass => _gate('eglSetupOk');

  /// Whether the setup lane passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // -- Validation -------------------------------------------------------------

  /// Whether the native seam rejected null arrays, mismatched array lengths,
  /// and zero surface dimensions before touching any real decode/draw state.
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

  // -- Draw / seam ------------------------------------------------------------

  /// Whether the decoded OES texture was drawn to the pbuffer via the
  /// minimal external-OES passthrough shader.
  bool get baseDrawPass => _gate('baseDrawOk');

  /// Whether the native `GlesOverlayCompositor::drawOverlays` seam call
  /// succeeded on the already-current caller context.
  bool get seamCallPass => _gate('seamCallOk');

  /// Whether every draw/seam gate passed.
  bool get drawGroupPass => drawGateKeys.every(_gate);

  // -- Composite assertion ----------------------------------------------------

  /// Whether the outside-overlay probe pixel is unchanged and the
  /// inside-overlay probe pixel changed after the seam call.
  bool get compositeAssertionPass => _gate('compositeAssertionOk');

  /// Whether every composite gate passed.
  bool get compositePass => compositeGateKeys.every(_gate);

  // -- State restoration ------------------------------------------------------

  /// Whether GL viewport, current program, blend enable, and texture unit
  /// 0 bindings (2D and external OES) were restored after the seam call.
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
      decision == VGGlesExportOverlaySeamSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      allGatesPass &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGGlesExportOverlaySeamSmokeDecision.fail].
  bool get isFail => decision == VGGlesExportOverlaySeamSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGGlesExportOverlaySeamSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGGlesExportOverlaySeamSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGGlesExportOverlaySeamSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGGlesExportOverlaySeamSmokeDecision.harnessException;

  // -- Constructors for synthesized reports ----------------------------------

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGGlesExportOverlaySeamSmokeReport.unsupported(String reason) {
    return VGGlesExportOverlaySeamSmokeReport(
      pass: false,
      decision: VGGlesExportOverlaySeamSmokeDecision.unsupported,
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
  factory VGGlesExportOverlaySeamSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGGlesExportOverlaySeamSmokeReport(
      pass: false,
      decision: VGGlesExportOverlaySeamSmokeDecision.harnessException,
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
  static VGGlesExportOverlaySeamSmokeReport fromMap(Object? raw) {
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
      return VGGlesExportOverlaySeamSmokeReport.harnessFailure(
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
        ? VGGlesExportOverlaySeamSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGGlesExportOverlaySeamSmokeReport(
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

  static VGGlesExportOverlaySeamSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGGlesExportOverlaySeamSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGGlesExportOverlaySeamSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGGlesExportOverlaySeamSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGGlesExportOverlaySeamSmokeDecision.fail;
    }
    return VGGlesExportOverlaySeamSmokeDecision.harnessException;
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

  static const String _method = 'runAndroidDagPhase5GlesExportOverlaySeamSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 GLES export overlay seam
  /// diagnostic smoke harness against [videoPath].
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGGlesExportOverlaySeamSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields a
  /// [VGGlesExportOverlaySeamSmokeDecision.unsupported] report; any other
  /// error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGGlesExportOverlaySeamSmokeReport>
  runAndroidDagPhase5GlesExportOverlaySeamSmoke({
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
      return VGGlesExportOverlaySeamSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGGlesExportOverlaySeamSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGGlesExportOverlaySeamSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGGlesExportOverlaySeamSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGGlesExportOverlaySeamSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGGlesExportOverlaySeamSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGGlesExportOverlaySeamSmokeReport &&
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
      'VGGlesExportOverlaySeamSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'gates: $gates, '
      'details: $details)';
}
