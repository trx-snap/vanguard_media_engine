// vg_audio_pipeline_integration_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice F: Android True-DAG Phase 4
// native closed-loop ingest-to-transport audio graph pipeline integration diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioPipelineIntegrationSmoke` MethodChannel route.
// Diagnostic-only - validates native closed-loop ingest-to-transport audio graph
// pipeline integration proof:
// AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer(s) ->
// RingBufferAudioSampleProvider(s) -> GraphAudioScheduler -> AudioMixBusNode ->
// ClockedAudioTransportCoordinator -> output AudioSpscAudioRingBuffer -> consumer drain.
//
// Honest non-claims:
// - Pure in-memory C++ proof only; no MediaCodec, no MediaExtractor,
//   no AudioTrack, no AAudio, no OpenSL, no Oboe, no realtime playback,
//   no audible output, no OS callbacks, no threads, no locks, no file IO,
//   no wall-clock read (caller-supplied sysTimeNs only), no resample,
//   no speed change, no export reroute, no pass-2 graph reroute,
//   no streaming, no cache, no iOS, no product/editor UI.
//   DecodedAudioPcmSourceNode remains a topology anchor only (no PCM
//   ingest/retention). Writer-local EOS only. Single-threaded native call.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioPipelineIntegrationSmokeReport.runAndroidDagPhase4AudioPipelineIntegrationSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioPipelineIntegrationSmokeReport {
  const VGAudioPipelineIntegrationSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioPipelineIntegrationSmoke';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_closed_loop_audio_pipeline_integration_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_audible_output_no_os_callback_no_threads_no_locks_no_file_io_no_wall_clock_read_no_resample_no_speed_change_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_no_source_node_pcm_ingest_topology_anchor_only_writer_local_eos_only_caller_supplied_systime_only_single_threaded';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  // ---- Boolean Lane Helpers & Getters -------------------------------------

  bool _boolMetric(String key) {
    final val = metrics[key] ?? raw[key];
    if (val is bool) return val;
    if (val is String) {
      final lower = val.trim().toLowerCase();
      return lower == 'true' || lower == 'pass' || lower == 'success';
    }
    return false;
  }

  /// Whether scheduler selects only valid registered source nodes for mix routing.
  bool get routeSelectivityOk => _boolMetric('routeSelectivityOk');

  /// Whether start operation awaits reader seek ACK before pushing frames.
  bool get startAwaitAckGateOk => _boolMetric('startAwaitAckGateOk');

  /// Whether multi-source written samples match mixed and drained samples bit-exact.
  bool get closedLoopIdentityOk => _boolMetric('closedLoopIdentityOk');

  /// Whether writer-side seek boundary clears EOS and gates writes until source ring ACK.
  bool get sourceSeekAckBoundaryOk => _boolMetric('sourceSeekAckBoundaryOk');

  /// Whether coordinator seek correctly transitions cursor, acks, and matches samples.
  bool get coordinatorSeekIdentityOk =>
      _boolMetric('coordinatorSeekIdentityOk');

  /// Whether first post-seek dispatch window pushes silence due to provider seek consumption.
  bool get firstPostSeekSilenceOk => _boolMetric('firstPostSeekSilenceOk');

  /// Whether repeated write-dispatch-drain cycles incur zero steady-state heap allocations.
  bool get noSteadyStateAllocationOk =>
      _boolMetric('noSteadyStateAllocationOk');

  /// Whether no ring push shortfall or terminal errors occurred across any lane.
  bool get noRingPushShortfallOk => _boolMetric('noRingPushShortfallOk');

  /// Whether fail-closed configuration, format mismatch, and lifecycle guards hold.
  bool get lifecycleOk => _boolMetric('lifecycleOk');

  /// Whether execution was stack-scoped without persistent native leaks.
  bool get stackScoped => _boolMetric('stackScoped');

  // ---- Numeric Getters ----------------------------------------------------

  int _intMetric(String key, [int defaultValue = 0]) {
    final val = metrics[key] ?? raw[key];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? defaultValue;
    return defaultValue;
  }

  /// Total frames verified during closed-loop identity test.
  int get closedLoopFramesVerified => _intMetric('closedLoopFramesVerified');

  /// Checksum of drained output samples in closed-loop test.
  int get closedLoopChecksum => _intMetric('closedLoopChecksum');

  /// Expected checksum of reference mixed samples in closed-loop test.
  int get closedLoopExpectedChecksum =>
      _intMetric('closedLoopExpectedChecksum');

  /// Total saturated/clipped samples during closed-loop mix.
  int get closedLoopClippedSamples => _intMetric('closedLoopClippedSamples');

  /// Seek target frame position during coordinator seek test.
  int get seekTargetFrame => _intMetric('seekTargetFrame');

  /// Seek target frame position during source seek boundary test.
  int get sourceSeekTargetFrame => _intMetric('sourceSeekTargetFrame');

  /// Underrun events counted during first post-seek silence window.
  int get firstPostSeekUnderrunEvents =>
      _intMetric('firstPostSeekUnderrunEvents');

  /// Zero-filled silence frames pushed during first post-seek window.
  int get firstPostSeekFramesZeroFilled =>
      _intMetric('firstPostSeekFramesZeroFilled');

  /// Total dispatches executed during steady-state allocation test.
  int get steadyStateDispatches => _intMetric('steadyStateDispatches');

  /// Total frames pushed during steady-state allocation test.
  int get steadyStateFramesPushed => _intMetric('steadyStateFramesPushed');

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      routeSelectivityOk &&
      startAwaitAckGateOk &&
      closedLoopIdentityOk &&
      sourceSeekAckBoundaryOk &&
      coordinatorSeekIdentityOk &&
      firstPostSeekSilenceOk &&
      noSteadyStateAllocationOk &&
      noRingPushShortfallOk &&
      lifecycleOk &&
      stackScoped;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioPipelineIntegrationSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioPipelineIntegrationSmokeReport(
        pass: false,
        proofBoundary: '',
        raw: <String, String>{'reason': 'native_result_not_a_map'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        lastError: 'native_result_not_a_map',
      );
    }

    final rawMapInput = raw['raw'];
    final parsedRaw = <String, String>{};
    if (rawMapInput is Map) {
      for (final entry in rawMapInput.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && v != null) {
          parsedRaw[k] = v;
        }
      }
    } else if (rawMapInput is String && rawMapInput.isNotEmpty) {
      for (final part in rawMapInput.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          final k = part.substring(0, eq).trim();
          final v = part.substring(eq + 1).trim();
          if (k.isNotEmpty) {
            parsedRaw[k] = v;
          }
        }
      }
    }

    final pass = raw['pass'] as bool? ?? (parsedRaw['status'] == 'PASS');
    final proofBoundary =
        (raw['proofBoundary'] as String?) ?? parsedRaw['proofBoundary'] ?? '';
    final lastError =
        (raw['lastError'] as String?) ?? parsedRaw['reason'] ?? '';

    final metricsRaw = raw['metrics'];
    final parsedMetrics = <String, Object?>{};
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedMetrics[k] = entry.value;
        }
      }
    }

    return VGAudioPipelineIntegrationSmokeReport(
      pass: pass,
      proofBoundary: proofBoundary,
      raw: Map<String, String>.unmodifiable(parsedRaw),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
      lastError: lastError,
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'proofBoundary': proofBoundary,
      'raw': Map<String, String>.from(raw),
      'metrics': Map<String, Object?>.from(metrics),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android True-DAG Phase 4 native audio pipeline integration
  /// diagnostic proof smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioPipelineIntegrationSmokeReport>
  runAndroidDagPhase4AudioPipelineIntegrationSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioPipelineIntegrationSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioPipelineIntegrationSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: const <String, String>{'status': 'FAIL', 'reason': 'timeout'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'timeout',
          'error': te.toString(),
        },
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return VGAudioPipelineIntegrationSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: <String, String>{
          'status': 'FAIL',
          'reason': 'platform_exception:${pe.code}',
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'platform_exception',
          'code': pe.code,
          'message': pe.message ?? '',
        },
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } catch (e) {
      return VGAudioPipelineIntegrationSmokeReport(
        pass: false,
        proofBoundary: proofBoundaryConstant,
        raw: <String, String>{'status': 'FAIL', 'reason': 'exception:$e'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'exception',
          'error': e.toString(),
        },
        lastError: 'exception:$e',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAudioPipelineIntegrationSmokeReport &&
        other.pass == pass &&
        other.proofBoundary == proofBoundary &&
        mapEquals(other.raw, raw) &&
        mapEquals(other.metrics, metrics) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hash(
    pass,
    proofBoundary,
    _stableMapHash(raw),
    _stableMapHash(metrics),
    lastError,
  );

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAudioPipelineIntegrationSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
