// vg_audio_decoder_ring_writer_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: Android True-DAG Phase 4
// native AudioDecoderRingWriter diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioDecoderRingWriterSmoke` MethodChannel route.
// Diagnostic-only - validates native vanguard::audio::AudioDecoderRingWriter
// decoder-to-source-ring ingest seam proof: constructor validation, successful writes,
// partial writes, backpressure ring-full rejects, format mismatch guards, invalid
// argument defense, writer-local EOS signaling, seek ACK gating, source ring boundary
// invariants, zero steady-state allocation, and stack-scoped lifecycle proof.
//
// Honest non-claims:
// - Pure in-memory C++ proof only; no MediaCodec, no MediaExtractor,
//   no AudioTrack, no AAudio, no OpenSL, no Oboe, no realtime playback,
//   no OS callbacks, no threads, no locks, no file IO, no export reroute,
//   no streaming, no iOS, no product/editor UI, no DecodedAudioPcmSourceNode wiring,
//   no scheduler integration, no resample, no audible output.
//   Writer-local EOS only.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioDecoderRingWriterSmokeReport.runAndroidDagPhase4AudioDecoderRingWriterSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioDecoderRingWriterSmokeReport {
  const VGAudioDecoderRingWriterSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioDecoderRingWriterSmoke';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_audio_decoder_ring_writer_to_spsc_source_ring_ingest_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_os_callback_no_threads_no_locks_no_file_io_no_export_reroute_no_streaming_no_ios_no_product_no_source_node_wiring_no_scheduler_integration_no_resample_no_audible_output_writer_local_eos_only';

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

  /// Whether writer constructor validates non-null ring and format configurations.
  bool get constructorValidationOk => _boolMetric('constructorValidationOk');

  /// Whether unblocked PCM16 frames write successfully into SPSC source ring.
  bool get writeSuccessOk => _boolMetric('writeSuccessOk');

  /// Whether partial ring writes push available capacity without error.
  bool get partialWriteOk => _boolMetric('partialWriteOk');

  /// Whether ring buffer full condition rejects push cleanly with backpressure.
  bool get ringFullOk => _boolMetric('ringFullOk');

  /// Whether format/channel/sample-rate mismatch is rejected cleanly.
  bool get formatMismatchOk => _boolMetric('formatMismatchOk');

  /// Whether null/zero/invalid write arguments are rejected cleanly.
  bool get invalidArgumentOk => _boolMetric('invalidArgumentOk');

  /// Whether writer-local EOS state transition and signaling succeed.
  bool get eosOk => _boolMetric('eosOk');

  /// Whether write operations await seek ACK gate before proceeding.
  bool get seekAwaitAckGateOk => _boolMetric('seekAwaitAckGateOk');

  /// Whether source ring ingest boundary assertions hold.
  bool get sourceRingBoundaryOk => _boolMetric('sourceRingBoundaryOk');

  /// Whether steady-state execution incurs zero heap allocations.
  bool get noSteadyStateAllocationOk =>
      _boolMetric('noSteadyStateAllocationOk');

  /// Whether writer lifecycle and teardown succeed cleanly.
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

  /// Total frames accepted during partial write invocations.
  int get partialWriteFramesAccepted =>
      _intMetric('partialWriteFramesAccepted');

  /// Total partial write events encountered.
  int get partialWriteEvents => _intMetric('partialWriteEvents');

  /// Total write rejects due to backpressure / ring full.
  int get backpressureRejects => _intMetric('backpressureRejects');

  /// Total format mismatch rejections.
  int get formatMismatches => _intMetric('formatMismatches');

  /// Total invalid argument rejections.
  int get invalidArgumentRejects => _intMetric('invalidArgumentRejects');

  /// Total write rejects while awaiting seek ACK.
  int get awaitingSeekAckRejects => _intMetric('awaitingSeekAckRejects');

  /// Total EOS transition events.
  int get eosEvents => _intMetric('eosEvents');

  /// Total seek requests received / processed.
  int get seekRequests => _intMetric('seekRequests');

  /// Total audio frames successfully written into the ring.
  int get totalFramesWritten => _intMetric('totalFramesWritten');

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      constructorValidationOk &&
      writeSuccessOk &&
      partialWriteOk &&
      ringFullOk &&
      formatMismatchOk &&
      invalidArgumentOk &&
      eosOk &&
      seekAwaitAckGateOk &&
      sourceRingBoundaryOk &&
      noSteadyStateAllocationOk &&
      lifecycleOk &&
      stackScoped;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioDecoderRingWriterSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioDecoderRingWriterSmokeReport(
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

    final pass = raw['pass'] as bool? ?? false;
    final proofBoundary = (raw['proofBoundary'] as String?) ?? '';
    final lastError = (raw['lastError'] as String?) ?? '';

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

    return VGAudioDecoderRingWriterSmokeReport(
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

  /// Invokes the Android True-DAG Phase 4 native AudioDecoderRingWriter
  /// diagnostic proof smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioDecoderRingWriterSmokeReport>
  runAndroidDagPhase4AudioDecoderRingWriterSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioDecoderRingWriterSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioDecoderRingWriterSmokeReport(
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
      return VGAudioDecoderRingWriterSmokeReport(
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
      return VGAudioDecoderRingWriterSmokeReport(
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
    return other is VGAudioDecoderRingWriterSmokeReport &&
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
      'VGAudioDecoderRingWriterSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
