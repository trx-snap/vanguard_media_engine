// vg_audio_ring_buffer_transport_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: Android True-DAG Phase 4
// native SPSC audio ring-buffer transport primitive + diagnostic AudioSampleProvider adapter proof smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioRingBufferTransportSmoke` MethodChannel route.
// Diagnostic-only — validates native vanguard::audio::AudioSpscAudioRingBuffer
// lock-free SPSC circular FIFO transport primitive and
// vanguard::audio::RingBufferAudioSampleProvider diagnostic adapter.
//
// Honest non-claims:
// - SPSC primitive + diagnostic provider only; no realtime/audible playback,
//   no AudioTrack/AAudio/OpenSL/Oboe, no realtime clock ownership,
//   no production decoder writer, no MediaCodec/MediaExtractor,
//   no C++->Kotlin callback, no export reroute, no streaming/cache,
//   no app/editor/product UI, no iOS, does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK
//   or P4-AUDIO-MIXBUS.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioRingBufferTransportSmokeReport.runAndroidDagPhase4AudioRingBufferTransportSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioRingBufferTransportSmokeReport {
  const VGAudioRingBufferTransportSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioRingBufferTransportSmoke';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_spsc_audio_ring_buffer_transport_primitive_and_diagnostic_provider_adapter_only_no_realtime_no_audio_track_no_playback_no_clock_ownership_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product';

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

  // ── Boolean Lane Helpers & Getters ────────────────────────────────────────

  bool _boolMetric(String key) {
    final val = metrics[key] ?? raw[key];
    if (val is bool) return val;
    if (val is String) {
      final lower = val.trim().toLowerCase();
      return lower == 'true' || lower == 'pass' || lower == 'success';
    }
    return false;
  }

  /// Whether atomic head/tail indices are lock-free on this platform.
  bool get ringSpscLockFreeOk => _boolMetric('ringSpscLockFreeOk');

  /// Whether ring buffer capacity constraints and power-of-two bounds are verified.
  bool get ringCapacityBoundOk => _boolMetric('ringCapacityBoundOk');

  /// Whether ring buffer maintains constant storage capacity across push/pop (no allocation).
  bool get ringNoAllocationOk => _boolMetric('ringNoAllocationOk');

  /// Whether FIFO ordering integrity is strictly preserved through push and pop.
  bool get fifoOrderIntegrityOk => _boolMetric('fifoOrderIntegrityOk');

  /// Whether circular wraparound across power-of-two ring boundary preserves all samples.
  bool get wraparoundIntegrityOk => _boolMetric('wraparoundIntegrityOk');

  /// Whether interleaved multi-channel frame samples are read atomically without tearing.
  bool get noTornFrameOk => _boolMetric('noTornFrameOk');

  /// Whether overrun rejects newest frames without overwriting unread queued data.
  bool get overrunRejectOk => _boolMetric('overrunRejectOk');

  /// Whether underrun with partial frame availability zero-fills tail and marks silent=false.
  bool get underrunZeroFillOk => _boolMetric('underrunZeroFillOk');

  /// Whether underrun on empty ring buffer produces silent window and scheduler kSilence.
  bool get underrunSilentWindowOk => _boolMetric('underrunSilentWindowOk');

  /// Whether backward seek/rewind requests fail closed without corrupting cursor.
  bool get rewindRejectOk => _boolMetric('rewindRejectOk');

  /// Whether forward gap skip discards intervening frames up to requested position.
  bool get forwardSkipBoundedOk => _boolMetric('forwardSkipBoundedOk');

  /// Whether reader discardAll flushes and drains the ring buffer cleanly.
  bool get flushDrainSemanticsOk => _boolMetric('flushDrainSemanticsOk');

  /// Whether seek epoch request/ack handshake discards pre-seek data and delivers post-seek data.
  bool get seekEpochHandshakeOk => _boolMetric('seekEpochHandshakeOk');

  /// Whether concurrent producer thread and consumer thread transfer frames without checksum mismatch.
  bool get concurrentProducerConsumerOk =>
      _boolMetric('concurrentProducerConsumerOk');

  /// Whether RingBufferAudioSampleProvider integrates into GraphAudioScheduler -> AudioMixBusNode with matching checksums.
  bool get schedulerIntegrationChecksumOk =>
      _boolMetric('schedulerIntegrationChecksumOk');

  /// Whether ring buffer construct/use/quiesce/teardown cycle succeeds cleanly.
  bool get teardownWhileQuiescedOk => _boolMetric('teardownWhileQuiescedOk');

  /// Whether constructor validation contracts reject invalid configurations.
  bool get lifecycleOk => _boolMetric('lifecycleOk');

  /// Whether execution was stack-scoped and clean.
  bool get stackScoped => _boolMetric('stackScoped');

  // ── Numeric Getters ───────────────────────────────────────────────────────

  int _intMetric(String key, [int defaultValue = 0]) {
    final val = metrics[key] ?? raw[key];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? defaultValue;
    return defaultValue;
  }

  /// Total frames pushed into the ring buffer.
  int get framesPushed => _intMetric('framesPushed');

  /// Total frames popped from the ring buffer.
  int get framesPopped => _intMetric('framesPopped');

  /// Number of overrun events encountered.
  int get overrunEvents => _intMetric('overrunEvents');

  /// Number of frames rejected due to overruns.
  int get framesRejected => _intMetric('framesRejected');

  /// Number of underrun events encountered.
  int get underrunEvents => _intMetric('underrunEvents');

  /// Number of frames zero-filled due to underruns.
  int get framesZeroFilled => _intMetric('framesZeroFilled');

  /// Number of frames skipped forward.
  int get forwardSkipFrames => _intMetric('forwardSkipFrames');

  /// Number of rewind requests rejected.
  int get rewindRejects => _intMetric('rewindRejects');

  /// Latest seek request epoch number.
  int get seekRequest => _intMetric('seekRequest');

  /// Latest seek acknowledge epoch number.
  int get seekAck => _intMetric('seekAck');

  /// Total frames transferred in concurrent producer-consumer tests.
  int get concurrentFrames => _intMetric('concurrentFrames');

  /// Number of repetitions in concurrent tests.
  int get concurrentRepetitions => _intMetric('concurrentRepetitions');

  /// Producer cumulative sample checksum in concurrent tests.
  int get producerChecksum => _intMetric('producerChecksum');

  /// Consumer cumulative sample checksum in concurrent tests.
  int get consumerChecksum => _intMetric('consumerChecksum');

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      ringSpscLockFreeOk &&
      ringCapacityBoundOk &&
      ringNoAllocationOk &&
      fifoOrderIntegrityOk &&
      wraparoundIntegrityOk &&
      noTornFrameOk &&
      overrunRejectOk &&
      underrunZeroFillOk &&
      underrunSilentWindowOk &&
      rewindRejectOk &&
      forwardSkipBoundedOk &&
      flushDrainSemanticsOk &&
      seekEpochHandshakeOk &&
      concurrentProducerConsumerOk &&
      schedulerIntegrationChecksumOk &&
      teardownWhileQuiescedOk &&
      lifecycleOk &&
      stackScoped;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioRingBufferTransportSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioRingBufferTransportSmokeReport(
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

    return VGAudioRingBufferTransportSmokeReport(
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

  /// Invokes the Android True-DAG Phase 4 native SPSC audio ring-buffer
  /// transport primitive + diagnostic provider adapter proof smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a fallback report if timed out
  /// or if a [PlatformException] / error occurs.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioRingBufferTransportSmokeReport>
  runAndroidDagPhase4AudioRingBufferTransportSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioRingBufferTransportSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioRingBufferTransportSmokeReport(
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
      return VGAudioRingBufferTransportSmokeReport(
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
      return VGAudioRingBufferTransportSmokeReport(
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
    return other is VGAudioRingBufferTransportSmokeReport &&
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
      'VGAudioRingBufferTransportSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
