// vg_timeline_dual_decoder_sync_smoke.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC):
// Android True-DAG V4.3 foundation dual MediaCodec synchronized ingest +
// overlap crossfade proof smoke diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5TimelineDualDecoderSyncSmoke` MethodChannel route.
// Diagnostic-only — validates that two real Android hardware MediaCodec
// decoders feeding ImageReader.PRIVATE produce HardwareBuffers in a
// synchronized overlap window, that Kotlin pairs one frame from each decoder
// on one owner thread with monotonic pts, that native imports both
// AHardwareBuffers into a temporary Vulkan device, evaluates
// ComputeTransitionGeometry(kCrossfade, progress), renders one offscreen
// crossfade through VulkanTimelineTransitionCompositor with deterministic
// pixel telemetry, and that every codec / image / native resource is
// released. No production export route change, no encoder/mux, no audio, no
// product/editor UI. A device without a usable Vulkan or AHardwareBuffer
// import path reports `UNSUPPORTED` rather than crashing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 dual decoder sync smoke harness.
enum VGTimelineDualDecoderSyncSmokeDecision {
  /// All dual decoder sync + native crossfade gates passed.
  pass,

  /// One or more gates failed.
  fail,

  /// The route is not available on this platform/plugin build, or the device
  /// has no usable Vulkan / AHardwareBuffer import path.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGTimelineDualDecoderSyncSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGTimelineDualDecoderSyncSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGTimelineDualDecoderSyncSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGTimelineDualDecoderSyncSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGTimelineDualDecoderSyncSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGTimelineDualDecoderSyncSmokeDecision.harnessException;
    }
    for (final value in VGTimelineDualDecoderSyncSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGTimelineDualDecoderSyncSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGTimelineDualDecoderSyncSmokeReport.runAndroidDagPhase5TimelineDualDecoderSyncSmoke],
/// mirroring the Kotlin/native harness's result map.
@immutable
class VGTimelineDualDecoderSyncSmokeReport {
  const VGTimelineDualDecoderSyncSmokeReport({
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

  /// Canonical proof boundary string emitted by the harness.
  static const String proofBoundaryConstant =
      'native_android_dual_mediacodec_imagereader_ahb_to_vulkan_transition_crossfade_diagnostic_only_no_export';

  /// Canonical PASS marker emitted by the harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_FAIL';

  /// Default lead-in / lead-out frame count enforced by the Kotlin driver.
  static const int leadFrames = 2;

  /// Default overlap frame count used when [runAndroidDagPhase5TimelineDualDecoderSyncSmoke]
  /// is called without `overlapFrames`.
  static const int defaultOverlapFrames = 3;

  /// Default per-pipeline decode cap used when called without `maxFrames`.
  static const int defaultMaxFrames = 60;

  /// Lane 0: argument validation gate key.
  static const List<String> argumentGateKeys = <String>['argumentValidationOk'];

  /// Lane 1: fixture inspection + dual hardware decoder setup gate keys.
  static const List<String> setupGateKeys = <String>[
    'fixtureFormatOk',
    'dualDecoderSetupOk',
  ];

  /// Lane 2: synchronized stepping gate keys (lead-in, overlap pairing,
  /// monotonic pts/timestamps, overlap progress echo).
  static const List<String> syncGateKeys = <String>[
    'leadInClip0Ok',
    'overlapPairAcquireOk',
    'overlapPtsMonotonicOk',
    'transitionProgressOk',
  ];

  /// Lane 3: native AHardwareBuffer import + Vulkan crossfade gate keys.
  static const List<String> nativeGateKeys = <String>[
    'nativeImportOk',
    'nativeCrossfadeRenderOk',
  ];

  /// Lane 4: lead-out + resource lifecycle gate keys.
  static const List<String> lifecycleGateKeys = <String>[
    'leadOutClip1Ok',
    'resourceReleaseOk',
  ];

  /// All gate keys in harness emission order.
  static const List<String> allGateKeys = <String>[
    ...argumentGateKeys,
    ...setupGateKeys,
    ...syncGateKeys,
    ...nativeGateKeys,
    ...lifecycleGateKeys,
  ];

  /// Primary success flag emitted by the harness.
  final bool pass;

  /// The parsed decision.
  final VGTimelineDualDecoderSyncSmokeDecision decision;

  /// Raw status string (`PASS`, `FAIL`, `UNSUPPORTED`, ...).
  final String status;

  /// PASS/FAIL marker string emitted by the harness.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// First failure reason reported by the harness, empty on pass.
  final String failureReason;

  /// Per-gate boolean results keyed by gate name.
  final Map<String, bool> gates;

  /// Native aggregate flag (`allNativeLanesPass`, mirrored as
  /// `nativeAllLanesPass` by the harness): every overlap frame's native
  /// crossfade call passed all of its own lanes.
  final bool nativeAllLanesPass;

  /// Free-form diagnostic details emitted by the harness (decoder names,
  /// fixture dimensions, per-lane pts lists, per-overlap-frame native
  /// results with device name / buffer format / center RGB / checksums /
  /// helper object counts, close step table).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the harness.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Lane 0: arguments ─────────────────────────────────────────────────────

  /// Whether both clip paths and the optional frame counts were admissible.
  bool get argumentValidationPass => _gate('argumentValidationOk');

  // ── Lane 1: setup ─────────────────────────────────────────────────────────

  /// Whether both fixtures inspected as real video tracks with positive
  /// dimensions.
  bool get fixtureFormatPass => _gate('fixtureFormatOk');

  /// Whether both hardware decoders + ImageReader.PRIVATE pipelines
  /// configured and started (no software fallback).
  bool get dualDecoderSetupPass => _gate('dualDecoderSetupOk');

  /// Whether every setup gate passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ── Lane 2: synchronized stepping ─────────────────────────────────────────

  /// Whether clip0 alone produced its lead-in frames with increasing pts.
  bool get leadInClip0Pass => _gate('leadInClip0Ok');

  /// Whether every overlap step acquired one Image from each decoder.
  bool get overlapPairAcquirePass => _gate('overlapPairAcquireOk');

  /// Whether overlap pts and Image timestamps increased strictly per clip
  /// and clip0 continued past its lead-in.
  bool get overlapPtsMonotonicPass => _gate('overlapPtsMonotonicOk');

  /// Whether overlap progress values were strictly inside (0,1), increasing,
  /// and echoed back by native as matching crossfade blend weights.
  bool get transitionProgressPass => _gate('transitionProgressOk');

  /// Whether every synchronized stepping gate passed.
  bool get syncPass => syncGateKeys.every(_gate);

  // ── Lane 3: native ────────────────────────────────────────────────────────

  /// Whether both AHardwareBuffers imported into Vulkan (and resolved to
  /// RGBA8) on every overlap frame.
  bool get nativeImportPass => _gate('nativeImportOk');

  /// Whether the compositor-owned crossfade rendered with pixel telemetry
  /// matching the blend weights on every overlap frame.
  bool get nativeCrossfadeRenderPass => _gate('nativeCrossfadeRenderOk');

  /// Whether every native gate passed.
  bool get nativePass => nativeGateKeys.every(_gate);

  // ── Lane 4: lifecycle ─────────────────────────────────────────────────────

  /// Whether clip1 alone produced its lead-out frames after the overlap.
  bool get leadOutClip1Pass => _gate('leadOutClip1Ok');

  /// Whether every Image / codec / reader / thread / extractor / native
  /// object was released.
  bool get resourceReleasePass => _gate('resourceReleaseOk');

  /// Whether every lifecycle gate passed.
  bool get lifecyclePass => lifecycleGateKeys.every(_gate);

  // ── Aggregates ────────────────────────────────────────────────────────────

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every diagnostic gate passed (computed Dart-side from [gates],
  /// independent of [nativeAllLanesPass]).
  bool get allNativeLanesPass => allGateKeys.every(_gate);

  /// Full verified pass: harness pass flag, every gate, native aggregate,
  /// canonical PASS marker, and canonical proof boundary all agree.
  bool get isVerifiedPass =>
      pass &&
      isPass &&
      allNativeLanesPass &&
      nativeAllLanesPass &&
      hasPassMarker &&
      hasCanonicalProofBoundary;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineDualDecoderSyncSmokeDecision.pass].
  bool get isPass => decision == VGTimelineDualDecoderSyncSmokeDecision.pass;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineDualDecoderSyncSmokeDecision.fail].
  bool get isFail => decision == VGTimelineDualDecoderSyncSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineDualDecoderSyncSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGTimelineDualDecoderSyncSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGTimelineDualDecoderSyncSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGTimelineDualDecoderSyncSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGTimelineDualDecoderSyncSmokeReport.unsupported(String reason) {
    return VGTimelineDualDecoderSyncSmokeReport(
      pass: false,
      decision: VGTimelineDualDecoderSyncSmokeDecision.unsupported,
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
  /// malformed native payload, locally rejected arguments).
  factory VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGTimelineDualDecoderSyncSmokeReport(
      pass: false,
      decision: VGTimelineDualDecoderSyncSmokeDecision.harnessException,
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

  /// Parses a report from the raw harness map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGTimelineDualDecoderSyncSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
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

    // Harness emits both spellings with the same value; accept either.
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
        ? VGTimelineDualDecoderSyncSmokeDecision.pass
        : _decisionFromStatus(status, raw['decision']);

    return VGTimelineDualDecoderSyncSmokeReport(
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

  static VGTimelineDualDecoderSyncSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGTimelineDualDecoderSyncSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGTimelineDualDecoderSyncSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGTimelineDualDecoderSyncSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory payload; treat
      // it as a plain failure rather than trusting the status string.
      return VGTimelineDualDecoderSyncSmokeDecision.fail;
    }
    return VGTimelineDualDecoderSyncSmokeDecision.harnessException;
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
      'runAndroidDagPhase5TimelineDualDecoderSyncSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// MethodChannel argument key for the first (from / lead-in) clip path.
  static const String clip0PathArg = 'clip0Path';

  /// MethodChannel argument key for the second (to / lead-out) clip path.
  static const String clip1PathArg = 'clip1Path';

  /// MethodChannel argument key for the optional per-pipeline decode cap.
  static const String maxFramesArg = 'maxFrames';

  /// MethodChannel argument key for the optional overlap frame count.
  static const String overlapFramesArg = 'overlapFrames';

  /// Invokes the Android True-DAG Phase 5 dual MediaCodec synchronized
  /// ingest + Vulkan crossfade diagnostic smoke harness.
  ///
  /// [clip0Path] / [clip1Path] are absolute, readable local video paths
  /// (the caller owns them; the example smoke copies bundled fixtures to a
  /// temp dir). Blank paths and non-positive [maxFrames] / [overlapFrames]
  /// are rejected locally with a harness-exception report and never reach
  /// the channel.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGTimelineDualDecoderSyncSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields an
  /// [VGTimelineDualDecoderSyncSmokeDecision.unsupported] report; any other
  /// error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGTimelineDualDecoderSyncSmokeReport>
  runAndroidDagPhase5TimelineDualDecoderSyncSmoke({
    required String clip0Path,
    required String clip1Path,
    int? maxFrames,
    int? overlapFrames,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    if (clip0Path.trim().isEmpty) {
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'invalid_argument:clip0Path_empty',
      );
    }
    if (clip1Path.trim().isEmpty) {
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'invalid_argument:clip1Path_empty',
      );
    }
    if (maxFrames != null && maxFrames <= 0) {
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'invalid_argument:maxFrames_not_positive',
        extraDetails: <String, Object?>{'maxFrames': maxFrames},
      );
    }
    if (overlapFrames != null && overlapFrames <= 0) {
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'invalid_argument:overlapFrames_not_positive',
        extraDetails: <String, Object?>{'overlapFrames': overlapFrames},
      );
    }
    final args = <String, Object?>{
      clip0PathArg: clip0Path,
      clip1PathArg: clip1Path,
      maxFramesArg: ?maxFrames,
      overlapFramesArg: ?overlapFrames,
    };
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGTimelineDualDecoderSyncSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGTimelineDualDecoderSyncSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGTimelineDualDecoderSyncSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGTimelineDualDecoderSyncSmokeReport &&
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
      'VGTimelineDualDecoderSyncSmokeReport('
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
