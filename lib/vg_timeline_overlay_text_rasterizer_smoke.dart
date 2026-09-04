// vg_timeline_overlay_text_rasterizer_smoke.dart
// vanguard_media_engine — P5-OVERLAYS-TEXT-RASTERIZER-DIAGNOSTIC (sub-slice of P5-OVERLAYS-TRANS):
// Android True-DAG AndroidTimelineOverlayTextRasterizer helper proof diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke` MethodChannel route.
// Diagnostic-only — validates that the private Kotlin text overlay rasterizer
// helper fails closed on invalid parameters, rasterizes centered text with semi-transparent
// background box, rasterizes centered text with transparent background, packs direct
// native-order RGBA byte buffer with correct color ordering and no position drift,
// and verifies canonical route telemetry.
// No native C++, no JNI, no decode, no export session wiring, and no product/editor UI.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the Android Phase 5 text overlay rasterizer smoke harness.
enum VGTimelineOverlayTextRasterizerSmokeDecision {
  /// All native text overlay rasterizer gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGTimelineOverlayTextRasterizerSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGTimelineOverlayTextRasterizerSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGTimelineOverlayTextRasterizerSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGTimelineOverlayTextRasterizerSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGTimelineOverlayTextRasterizerSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGTimelineOverlayTextRasterizerSmokeDecision.harnessException;
    }
    for (final value in VGTimelineOverlayTextRasterizerSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGTimelineOverlayTextRasterizerSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke],
/// mirroring the native coordinator's JSON result map.
@immutable
class VGTimelineOverlayTextRasterizerSmokeReport {
  const VGTimelineOverlayTextRasterizerSmokeReport({
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

  /// Canonical proof boundary string emitted by the native coordinator.
  static const String proofBoundaryConstant =
      'android_kotlin_text_overlay_rasterizer_rgba_buffer_diagnostic_only_no_export_no_native_no_jni_no_product';

  /// Canonical PASS marker emitted by the native coordinator.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native coordinator.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_FAIL';

  /// Gate keys in exact emission order.
  static const List<String> allGateKeys = <String>[
    'validationPass',
    'backgroundPass',
    'transparentPass',
    'packingPass',
    'canonicalPass',
  ];

  /// Alias for diagnostic suite conventions.
  static const List<String> gateKeys = allGateKeys;

  /// Primary success flag emitted by the native coordinator.
  final bool pass;

  /// The parsed decision.
  final VGTimelineOverlayTextRasterizerSmokeDecision decision;

  /// Raw status string (`PASS`, `FAIL`, `UNSUPPORTED`, ...).
  final String status;

  /// PASS/FAIL marker string emitted by the native coordinator.
  final String marker;

  /// Proof boundary string proving execution of the verified coordinator.
  final String proofBoundary;

  /// First failure reason reported by the native coordinator, empty on pass.
  final String failureReason;

  /// Per-gate boolean results keyed by gate name.
  final Map<String, bool> gates;

  /// Native aggregate flag (`allNativeLanesPass`, mirrored as
  /// `nativeAllLanesPass` by the native coordinator).
  final bool nativeAllLanesPass;

  /// Free-form diagnostic details emitted by the native coordinator.
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native coordinator.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Lane 1: parameter validation ──────────────────────────────────────────

  /// Whether blank overlay id, blank text, zero/negative dimensions, NaN width,
  /// and oversized dimensions fail closed with expected codes.
  bool get validationPass => _gate('validationPass');

  // ── Lane 2: background box raster ────────────────────────────────────────

  /// Whether rasterizing with background true yields expected dimensions, row stride,
  /// direct buffer, non-zero alpha, and white-like pixels.
  bool get backgroundPass => _gate('backgroundPass');

  // ── Lane 3: transparent background raster ────────────────────────────────

  /// Whether rasterizing with background false yields expected dimensions, direct buffer,
  /// corner alpha 0 or transparent pixels, and white-like pixels.
  bool get transparentPass => _gate('transparentPass');

  // ── Lane 4: buffer packing & RGBA sanity ─────────────────────────────────

  /// Whether direct native-order buffer, RGBA byte order sanity from white text
  /// and black background, and zero buffer position drift are verified.
  bool get packingPass => _gate('packingPass');

  // ── Lane 5: canonical telemetry ──────────────────────────────────────────

  /// Whether the canonical route verified pass marker, proof boundary, and aggregate flags.
  bool get canonicalPass => _gate('canonicalPass');

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
      decision == VGTimelineOverlayTextRasterizerSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      nativeAllLanesPass &&
      allNativeLanesPass &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayTextRasterizerSmokeDecision.fail].
  bool get isFail =>
      decision == VGTimelineOverlayTextRasterizerSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayTextRasterizerSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGTimelineOverlayTextRasterizerSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineOverlayTextRasterizerSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGTimelineOverlayTextRasterizerSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGTimelineOverlayTextRasterizerSmokeReport.unsupported(
    String reason,
  ) {
    return VGTimelineOverlayTextRasterizerSmokeReport(
      pass: false,
      decision: VGTimelineOverlayTextRasterizerSmokeDecision.unsupported,
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
  factory VGTimelineOverlayTextRasterizerSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGTimelineOverlayTextRasterizerSmokeReport(
      pass: false,
      decision: VGTimelineOverlayTextRasterizerSmokeDecision.harnessException,
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
  static VGTimelineOverlayTextRasterizerSmokeReport fromMap(Object? raw) {
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
      return VGTimelineOverlayTextRasterizerSmokeReport.harnessFailure(
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
        ? VGTimelineOverlayTextRasterizerSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGTimelineOverlayTextRasterizerSmokeReport(
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

  static VGTimelineOverlayTextRasterizerSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw(
        explicitDecision,
      );
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGTimelineOverlayTextRasterizerSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGTimelineOverlayTextRasterizerSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      return VGTimelineOverlayTextRasterizerSmokeDecision.fail;
    }
    return VGTimelineOverlayTextRasterizerSmokeDecision.harnessException;
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
      'runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 AndroidTimelineOverlayTextRasterizer
  /// diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGTimelineOverlayTextRasterizerSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields a
  /// [VGTimelineOverlayTextRasterizerSmokeDecision.unsupported] report; any
  /// other error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGTimelineOverlayTextRasterizerSmokeReport>
  runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGTimelineOverlayTextRasterizerSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGTimelineOverlayTextRasterizerSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGTimelineOverlayTextRasterizerSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGTimelineOverlayTextRasterizerSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGTimelineOverlayTextRasterizerSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGTimelineOverlayTextRasterizerSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGTimelineOverlayTextRasterizerSmokeReport &&
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
      'VGTimelineOverlayTextRasterizerSmokeReport('
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
