// vg_timeline_compositor_smoke.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (sub-slice NODE-TOPOLOGY-MATH):
// Android True-DAG V4.3 foundation VGTimelineCompositorNode native topology +
// timeline clip overlap / transition progress math smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5TimelineCompositorSmoke` MethodChannel route.
// Diagnostic-only — validates native VGTimelineCompositorNode graph port
// topology, hard-cut clip selection, speed/trim local PTS mapping, crossfade
// weights, slide viewports, wipe crops, outside-timeline handling, invalid
// transition fail-safety, zero-duration safety, and uint64 saturation.
// No render, no decode, no export session, and no product/editor UI.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 VGTimelineCompositorNode smoke
/// harness.
enum VGTimelineCompositorSmokeDecision {
  /// All native VGTimelineCompositorNode topology and math gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGTimelineCompositorSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGTimelineCompositorSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') return VGTimelineCompositorSmokeDecision.pass;
    if (normalized == 'fail') return VGTimelineCompositorSmokeDecision.fail;
    if (normalized == 'unsupported') {
      return VGTimelineCompositorSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGTimelineCompositorSmokeDecision.harnessException;
    }
    for (final value in VGTimelineCompositorSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGTimelineCompositorSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGTimelineCompositorSmokeReport {
  const VGTimelineCompositorSmokeReport({
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
      'native_vg_timeline_compositor_node_topology_and_transition_math_only_no_render_no_decode';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_FAIL';

  /// Topology gate keys emitted by the native harness.
  static const List<String> topologyGateKeys = <String>[
    'kindOk',
    'typeOk',
    'inputPortCountOk',
    'outputPortCountOk',
    'portIdsOk',
  ];

  /// Math gate keys emitted by the native harness.
  static const List<String> mathGateKeys = <String>[
    'hardCutOk',
    'crossfadeStartOk',
    'crossfadeMidOk',
    'crossfadeEndOk',
    'slideLeftMidOk',
    'wipeLeftMidOk',
    'speedMappingOk',
    'outsideTimelineOk',
    'invalidTransitionIgnoredOk',
    'zeroDurationSafeOk',
    'overflowSafeOk',
  ];

  /// All gate keys, topology first then math.
  static const List<String> allGateKeys = <String>[
    ...topologyGateKeys,
    ...mathGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGTimelineCompositorSmokeDecision decision;

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

  /// `allNativeLanesPass` flag as computed natively.
  final bool nativeAllLanesPass;

  /// Free-form diagnostic details emitted by the native harness.
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Topology gates ────────────────────────────────────────────────────────

  /// Whether the node kind is `kProcessing`.
  bool get kindPass => _gate('kindOk');

  /// Whether the node type is `kVGTimelineCompositor`.
  bool get typePass => _gate('typeOk');

  /// Whether exactly two video input ports exist.
  bool get inputPortCountPass => _gate('inputPortCountOk');

  /// Whether exactly one video output port exists.
  bool get outputPortCountPass => _gate('outputPortCountOk');

  /// Whether port IDs/data types match the frozen contract.
  bool get portIdsPass => _gate('portIdsOk');

  /// Whether all topology gates passed.
  bool get topologyPass => topologyGateKeys.every(_gate);

  // ── Math gates ────────────────────────────────────────────────────────────

  /// Whether hard-cut clip selection and node overrides passed.
  bool get hardCutPass => _gate('hardCutOk');

  /// Whether crossfade progress at window start (p=0) passed.
  bool get crossfadeStartPass => _gate('crossfadeStartOk');

  /// Whether crossfade progress at window midpoint (p=0.5) passed.
  bool get crossfadeMidPass => _gate('crossfadeMidOk');

  /// Whether crossfade end-exclusive behavior passed.
  bool get crossfadeEndPass => _gate('crossfadeEndOk');

  /// Whether slide-left viewport geometry at p=0.5 passed.
  bool get slideLeftMidPass => _gate('slideLeftMidOk');

  /// Whether wipe-left crop geometry at p=0.5 passed.
  bool get wipeLeftMidPass => _gate('wipeLeftMidOk');

  /// Whether speed/trim local PTS mapping passed.
  bool get speedMappingPass => _gate('speedMappingOk');

  /// Whether outside-timeline evaluation returned no active clip.
  bool get outsideTimelinePass => _gate('outsideTimelineOk');

  /// Whether invalid transition endpoints were ignored fail-safe.
  bool get invalidTransitionIgnoredPass => _gate('invalidTransitionIgnoredOk');

  /// Whether zero-duration transitions/clips were handled safely.
  bool get zeroDurationSafePass => _gate('zeroDurationSafeOk');

  /// Whether uint64 overflow-adjacent inputs saturated safely.
  bool get overflowSafePass => _gate('overflowSafeOk');

  /// Whether all math gates passed.
  bool get mathPass => mathGateKeys.every(_gate);

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

  /// Convenience getter for whether [decision] is [VGTimelineCompositorSmokeDecision.pass].
  bool get isPass => decision == VGTimelineCompositorSmokeDecision.pass;

  /// Convenience getter for whether [decision] is [VGTimelineCompositorSmokeDecision.fail].
  bool get isFail => decision == VGTimelineCompositorSmokeDecision.fail;

  /// Convenience getter for whether [decision] is [VGTimelineCompositorSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGTimelineCompositorSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is [VGTimelineCompositorSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGTimelineCompositorSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGTimelineCompositorSmokeReport.unsupported(String reason) {
    return VGTimelineCompositorSmokeReport(
      pass: false,
      decision: VGTimelineCompositorSmokeDecision.unsupported,
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
  factory VGTimelineCompositorSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGTimelineCompositorSmokeReport(
      pass: false,
      decision: VGTimelineCompositorSmokeDecision.harnessException,
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

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGTimelineCompositorSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGTimelineCompositorSmokeReport.harnessFailure(
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
      final value = raw[key];
      gates[key] = value == true || (value is String && value == 'true');
    }

    final nativeAllRaw = raw['allNativeLanesPass'];
    final nativeAllLanesPass =
        nativeAllRaw == true ||
        (nativeAllRaw is String && nativeAllRaw == 'true');

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
        ? VGTimelineCompositorSmokeDecision.pass
        : _decisionFromStatus(status, raw['decision']);

    return VGTimelineCompositorSmokeReport(
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

  static VGTimelineCompositorSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGTimelineCompositorSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGTimelineCompositorSmokeDecision.unsupported;
    }
    if (normalized == 'fail') return VGTimelineCompositorSmokeDecision.fail;
    if (normalized == 'pass') return VGTimelineCompositorSmokeDecision.fail;
    return VGTimelineCompositorSmokeDecision.harnessException;
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
      'details': Map<String, Object?>.from(details),
      'raw': raw,
    };
  }

  static const String _method = 'runAndroidDagPhase5TimelineCompositorSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 5 VGTimelineCompositorNode native
  /// topology and transition-math diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGTimelineCompositorSmokeDecision.harnessException] report on timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields an
  /// [VGTimelineCompositorSmokeDecision.unsupported] report; any other
  /// error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGTimelineCompositorSmokeReport>
  runAndroidDagPhase5TimelineCompositorSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGTimelineCompositorSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGTimelineCompositorSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGTimelineCompositorSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGTimelineCompositorSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGTimelineCompositorSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGTimelineCompositorSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGTimelineCompositorSmokeReport &&
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
      'VGTimelineCompositorSmokeReport('
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
