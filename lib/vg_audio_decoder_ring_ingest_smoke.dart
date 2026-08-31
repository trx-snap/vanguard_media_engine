// vg_audio_decoder_ring_ingest_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice G3: Android True-DAG Phase 4
// native audio decoder ring ingest diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AudioDecoderRingIngestSmoke` MethodChannel route.
// Diagnostic-only - validates Kotlin-owned MediaCodec/MediaExtractor streaming
// decode into the JNI decoder ring-ingest seam:
// output format resolution, backpressure ring-full / partial-write handling,
// full-drain seek boundary + reader-side ACK, writer-local EOS transition,
// synthetic probe session (already_eos, awaiting_seek_ack, post_ack_ok),
// and three-way checksum identity (Kotlin accepted == native accepted == native drained).
//
// Honest non-claims (Proof Boundary):
// kotlin_owned_mediacodec_mediaextractor_streaming_decode_to_jni_decoder_ring_ingest_proof_only_no_cpp_os_decoder_no_mediacodec_or_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_wall_clock_read_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_no_graph_scheduler_no_mix_bus_no_coordinator_no_closed_loop_sink_no_source_node_wiring_no_resample_no_downmix_channels_1_or_2_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_writer_local_eos_only_native_zero_steady_state_allocation_only_jvm_heap_non_claim

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAudioDecoderRingIngestSmokeReport.runAndroidDagPhase4AudioDecoderRingIngestSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAudioDecoderRingIngestSmokeReport {
  const VGAudioDecoderRingIngestSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.sampleRate,
    required this.channelCount,
    required this.pcmEncoding,
    required this.totalFramesAccepted,
    required this.totalFramesDrained,
    required this.postSeekFramesAccepted,
    required this.postSeekFramesDrained,
    required this.kotlinAcceptedChecksumHex,
    required this.nativeAcceptedChecksumHex,
    required this.nativeDrainedChecksumHex,
    required this.observedPartialWrite,
    required this.observedRingFull,
    required this.syntheticProbeChunk,
    required this.eosAlreadyEosStatus,
    required this.eosAwaitingSeekAckStatus,
    required this.eosPostAckStatus,
    required this.midStreamFormatChangeRejected,
    required this.seekAckObserved,
    required this.discardedFramesOnSeek,
    required this.newStartFrame,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AudioDecoderRingIngestSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_mediacodec_mediaextractor_streaming_decode_to_jni_decoder_ring_ingest_proof_only_no_cpp_os_decoder_no_mediacodec_or_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_wall_clock_read_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_no_graph_scheduler_no_mix_bus_no_coordinator_no_closed_loop_sink_no_source_node_wiring_no_resample_no_downmix_channels_1_or_2_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_writer_local_eos_only_native_zero_steady_state_allocation_only_jvm_heap_non_claim';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Status string (e.g. 'pass', 'fail', or fail-closed reason token).
  final String status;

  /// Diagnostic marker string.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Failure reason token, if any.
  final String failureReason;

  /// Auxiliary execution details or trace breadcrumbs.
  final String details;

  /// Resolved sample rate of the audio track.
  final int sampleRate;

  /// Resolved channel count (1 or 2).
  final int channelCount;

  /// Resolved PCM encoding (AudioFormat.ENCODING_PCM_16BIT = 2).
  final int pcmEncoding;

  /// Total frames accepted into native ring across pre-seek and post-seek.
  final int totalFramesAccepted;

  /// Total frames drained from native ring across pre-seek and post-seek.
  final int totalFramesDrained;

  /// Frames accepted into native ring during the post-seek decode phase.
  final int postSeekFramesAccepted;

  /// Frames drained from native ring during the post-seek decode phase.
  final int postSeekFramesDrained;

  /// 64-bit hexadecimal checksum computed on the Kotlin accepted side.
  final String kotlinAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native accepted side.
  final String nativeAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native drained side.
  final String nativeDrainedChecksumHex;

  /// Whether partial ring write backpressure was observed during ingest.
  final bool observedPartialWrite;

  /// Whether ring full condition was observed during ingest.
  final bool observedRingFull;

  /// Whether synthetic probe test chunk was generated and exercised.
  final bool syntheticProbeChunk;

  /// Writer status when attempting ingest on already-EOS probe session ('already_eos').
  final String eosAlreadyEosStatus;

  /// Writer status when attempting ingest while awaiting seek ACK ('awaiting_seek_ack').
  final String eosAwaitingSeekAckStatus;

  /// Writer status when attempting ingest after seek ACK consumed ('ok').
  final String eosPostAckStatus;

  /// Whether mid-stream format changes are rejected cleanly.
  final bool midStreamFormatChangeRejected;

  /// Whether reader-side seek ACK consumption was observed.
  final bool seekAckObserved;

  /// Number of frames discarded at seek boundary (must be 0 after full pre-seek drain).
  final int discardedFramesOnSeek;

  /// New start frame position reported after seek ACK.
  final int newStartFrame;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether Kotlin accepted, native accepted, and native drained checksums match and are non-empty.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHex.isNotEmpty &&
      kotlinAcceptedChecksumHex == nativeAcceptedChecksumHex &&
      nativeAcceptedChecksumHex == nativeDrainedChecksumHex;

  /// Whether total frames drained plus discarded frames equals total frames accepted.
  bool get frameAccountingOk =>
      totalFramesDrained + discardedFramesOnSeek == totalFramesAccepted;

  /// Whether both partial write and ring full backpressure conditions were observed.
  bool get backpressureObserved => observedPartialWrite && observedRingFull;

  /// Whether synthetic probe transitions (already_eos, awaiting_seek_ack, ok) verified cleanly.
  bool get syntheticProbeOk =>
      syntheticProbeChunk &&
      eosAlreadyEosStatus == 'already_eos' &&
      eosAwaitingSeekAckStatus == 'awaiting_seek_ack' &&
      eosPostAckStatus == 'ok';

  /// Whether seek ACK was observed with zero discarded frames and valid start frame.
  bool get seekAckOk =>
      seekAckObserved && discardedFramesOnSeek == 0 && newStartFrame >= 0;

  /// Whether all native diagnostic lanes passed.
  bool get allNativeLanesPass =>
      pass &&
      hasCanonicalProofBoundary &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      sampleRate > 0 &&
      (channelCount >= 1 && channelCount <= 2) &&
      pcmEncoding == 2 &&
      totalFramesAccepted > 0 &&
      totalFramesDrained > 0 &&
      postSeekFramesAccepted > 0 &&
      postSeekFramesDrained > 0 &&
      checksumsMatch &&
      frameAccountingOk &&
      backpressureObserved &&
      syntheticProbeOk &&
      seekAckOk &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAudioDecoderRingIngestSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAudioDecoderRingIngestSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        totalFramesAccepted: 0,
        totalFramesDrained: 0,
        postSeekFramesAccepted: 0,
        postSeekFramesDrained: 0,
        kotlinAcceptedChecksumHex: '',
        nativeAcceptedChecksumHex: '',
        nativeDrainedChecksumHex: '',
        observedPartialWrite: false,
        observedRingFull: false,
        syntheticProbeChunk: false,
        eosAlreadyEosStatus: '',
        eosAwaitingSeekAckStatus: '',
        eosPostAckStatus: '',
        midStreamFormatChangeRejected: false,
        seekAckObserved: false,
        discardedFramesOnSeek: 0,
        newStartFrame: -1,
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

    bool parseBool(String key, [bool defaultValue = false]) {
      final v = raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
      if (v is bool) return v;
      if (v is String) {
        final lower = v.trim().toLowerCase();
        if (lower == 'true' || lower == 'pass' || lower == 'ok') return true;
        if (lower == 'false' || lower == 'fail') return false;
      }
      return defaultValue;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      final v = raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? defaultValue;
      return defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v = raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
      if (v != null) return v.toString();
      return defaultValue;
    }

    final pass = parseBool(
      'pass',
      parsedRaw['status']?.toLowerCase() == 'pass',
    );
    final status = parseString('status', pass ? 'pass' : 'fail');
    final marker = parseString(
      'marker',
      pass ? passMarkerConstant : failMarkerConstant,
    );
    final proofBoundary = parseString('proofBoundary');
    final failureReason = parseString(
      'failureReason',
      parsedRaw['reason'] ?? '',
    );
    final details = parseString('details');

    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final pcmEncoding = parseInt('pcmEncoding');
    final totalFramesAccepted = parseInt('totalFramesAccepted');
    final totalFramesDrained = parseInt('totalFramesDrained');
    final postSeekFramesAccepted = parseInt('postSeekFramesAccepted');
    final postSeekFramesDrained = parseInt('postSeekFramesDrained');

    final kotlinAcceptedChecksumHex = parseString('kotlinAcceptedChecksumHex');
    final nativeAcceptedChecksumHex = parseString('nativeAcceptedChecksumHex');
    final nativeDrainedChecksumHex = parseString('nativeDrainedChecksumHex');

    final observedPartialWrite = parseBool('observedPartialWrite');
    final observedRingFull = parseBool('observedRingFull');
    final syntheticProbeChunk = parseBool('syntheticProbeChunk');

    final eosAlreadyEosStatus = parseString('eosAlreadyEosStatus');
    final eosAwaitingSeekAckStatus = parseString('eosAwaitingSeekAckStatus');
    final eosPostAckStatus = parseString('eosPostAckStatus');

    final midStreamFormatChangeRejected = parseBool(
      'midStreamFormatChangeRejected',
    );
    final seekAckObserved = parseBool('seekAckObserved');
    final discardedFramesOnSeek = parseInt('discardedFramesOnSeek');
    final newStartFrame = parseInt('newStartFrame', -1);

    final lastError = parseString('lastError', failureReason);

    return VGAudioDecoderRingIngestSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      sampleRate: sampleRate,
      channelCount: channelCount,
      pcmEncoding: pcmEncoding,
      totalFramesAccepted: totalFramesAccepted,
      totalFramesDrained: totalFramesDrained,
      postSeekFramesAccepted: postSeekFramesAccepted,
      postSeekFramesDrained: postSeekFramesDrained,
      kotlinAcceptedChecksumHex: kotlinAcceptedChecksumHex,
      nativeAcceptedChecksumHex: nativeAcceptedChecksumHex,
      nativeDrainedChecksumHex: nativeDrainedChecksumHex,
      observedPartialWrite: observedPartialWrite,
      observedRingFull: observedRingFull,
      syntheticProbeChunk: syntheticProbeChunk,
      eosAlreadyEosStatus: eosAlreadyEosStatus,
      eosAwaitingSeekAckStatus: eosAwaitingSeekAckStatus,
      eosPostAckStatus: eosPostAckStatus,
      midStreamFormatChangeRejected: midStreamFormatChangeRejected,
      seekAckObserved: seekAckObserved,
      discardedFramesOnSeek: discardedFramesOnSeek,
      newStartFrame: newStartFrame,
      raw: Map<String, String>.unmodifiable(parsedRaw),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
      lastError: lastError,
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      'details': details,
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'pcmEncoding': pcmEncoding,
      'totalFramesAccepted': totalFramesAccepted,
      'totalFramesDrained': totalFramesDrained,
      'postSeekFramesAccepted': postSeekFramesAccepted,
      'postSeekFramesDrained': postSeekFramesDrained,
      'kotlinAcceptedChecksumHex': kotlinAcceptedChecksumHex,
      'nativeAcceptedChecksumHex': nativeAcceptedChecksumHex,
      'nativeDrainedChecksumHex': nativeDrainedChecksumHex,
      'observedPartialWrite': observedPartialWrite,
      'observedRingFull': observedRingFull,
      'syntheticProbeChunk': syntheticProbeChunk,
      'eosAlreadyEosStatus': eosAlreadyEosStatus,
      'eosAwaitingSeekAckStatus': eosAwaitingSeekAckStatus,
      'eosPostAckStatus': eosPostAckStatus,
      'midStreamFormatChangeRejected': midStreamFormatChangeRejected,
      'seekAckObserved': seekAckObserved,
      'discardedFramesOnSeek': discardedFramesOnSeek,
      'newStartFrame': newStartFrame,
      'raw': Map<String, String>.from(raw),
      'metrics': Map<String, Object?>.from(metrics),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android True-DAG Phase 4 native audio decoder ring ingest
  /// diagnostic proof smoke harness.
  ///
  /// [sourcePath] path to media file on device.
  /// [durationSec] duration to decode (default 1.0).
  /// [seekTargetSec] seek target position (default 0.35).
  /// [timeout] optionally bounds the invocation.
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAudioDecoderRingIngestSmokeReport>
  runAndroidDagPhase4AudioDecoderRingIngestSmoke({
    required String sourcePath,
    double durationSec = 1.0,
    double seekTargetSec = 0.35,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      'sourcePath': sourcePath,
      'durationSec': durationSec,
      'seekTargetSec': seekTargetSec,
    };
    try {
      final future = ch.invokeMethod<Object?>(methodName, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAudioDecoderRingIngestSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGAudioDecoderRingIngestSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: proofBoundaryConstant,
        failureReason: 'timeout',
        details: te.toString(),
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        totalFramesAccepted: 0,
        totalFramesDrained: 0,
        postSeekFramesAccepted: 0,
        postSeekFramesDrained: 0,
        kotlinAcceptedChecksumHex: '',
        nativeAcceptedChecksumHex: '',
        nativeDrainedChecksumHex: '',
        observedPartialWrite: false,
        observedRingFull: false,
        syntheticProbeChunk: false,
        eosAlreadyEosStatus: '',
        eosAwaitingSeekAckStatus: '',
        eosPostAckStatus: '',
        midStreamFormatChangeRejected: false,
        seekAckObserved: false,
        discardedFramesOnSeek: 0,
        newStartFrame: -1,
        raw: const <String, String>{'status': 'FAIL', 'reason': 'timeout'},
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'timeout',
          'error': te.toString(),
        },
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return VGAudioDecoderRingIngestSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: proofBoundaryConstant,
        failureReason: 'platform_exception:${pe.code}',
        details: pe.message ?? '',
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        totalFramesAccepted: 0,
        totalFramesDrained: 0,
        postSeekFramesAccepted: 0,
        postSeekFramesDrained: 0,
        kotlinAcceptedChecksumHex: '',
        nativeAcceptedChecksumHex: '',
        nativeDrainedChecksumHex: '',
        observedPartialWrite: false,
        observedRingFull: false,
        syntheticProbeChunk: false,
        eosAlreadyEosStatus: '',
        eosAwaitingSeekAckStatus: '',
        eosPostAckStatus: '',
        midStreamFormatChangeRejected: false,
        seekAckObserved: false,
        discardedFramesOnSeek: 0,
        newStartFrame: -1,
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
      return VGAudioDecoderRingIngestSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: proofBoundaryConstant,
        failureReason: 'exception:$e',
        details: e.toString(),
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        totalFramesAccepted: 0,
        totalFramesDrained: 0,
        postSeekFramesAccepted: 0,
        postSeekFramesDrained: 0,
        kotlinAcceptedChecksumHex: '',
        nativeAcceptedChecksumHex: '',
        nativeDrainedChecksumHex: '',
        observedPartialWrite: false,
        observedRingFull: false,
        syntheticProbeChunk: false,
        eosAlreadyEosStatus: '',
        eosAwaitingSeekAckStatus: '',
        eosPostAckStatus: '',
        midStreamFormatChangeRejected: false,
        seekAckObserved: false,
        discardedFramesOnSeek: 0,
        newStartFrame: -1,
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
    return other is VGAudioDecoderRingIngestSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.pcmEncoding == pcmEncoding &&
        other.totalFramesAccepted == totalFramesAccepted &&
        other.totalFramesDrained == totalFramesDrained &&
        other.postSeekFramesAccepted == postSeekFramesAccepted &&
        other.postSeekFramesDrained == postSeekFramesDrained &&
        other.kotlinAcceptedChecksumHex == kotlinAcceptedChecksumHex &&
        other.nativeAcceptedChecksumHex == nativeAcceptedChecksumHex &&
        other.nativeDrainedChecksumHex == nativeDrainedChecksumHex &&
        other.observedPartialWrite == observedPartialWrite &&
        other.observedRingFull == observedRingFull &&
        other.syntheticProbeChunk == syntheticProbeChunk &&
        other.eosAlreadyEosStatus == eosAlreadyEosStatus &&
        other.eosAwaitingSeekAckStatus == eosAwaitingSeekAckStatus &&
        other.eosPostAckStatus == eosPostAckStatus &&
        other.midStreamFormatChangeRejected == midStreamFormatChangeRejected &&
        other.seekAckObserved == seekAckObserved &&
        other.discardedFramesOnSeek == discardedFramesOnSeek &&
        other.newStartFrame == newStartFrame &&
        mapEquals(other.raw, raw) &&
        mapEquals(other.metrics, metrics) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll([
    pass,
    status,
    marker,
    proofBoundary,
    failureReason,
    details,
    sampleRate,
    channelCount,
    pcmEncoding,
    totalFramesAccepted,
    totalFramesDrained,
    postSeekFramesAccepted,
    postSeekFramesDrained,
    kotlinAcceptedChecksumHex,
    nativeAcceptedChecksumHex,
    nativeDrainedChecksumHex,
    observedPartialWrite,
    observedRingFull,
    syntheticProbeChunk,
    eosAlreadyEosStatus,
    eosAwaitingSeekAckStatus,
    eosPostAckStatus,
    midStreamFormatChangeRejected,
    seekAckObserved,
    discardedFramesOnSeek,
    newStartFrame,
    _stableMapHash(raw),
    _stableMapHash(metrics),
    lastError,
  ]);

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAudioDecoderRingIngestSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'pcmEncoding: $pcmEncoding, '
      'totalFramesAccepted: $totalFramesAccepted, '
      'totalFramesDrained: $totalFramesDrained, '
      'postSeekFramesAccepted: $postSeekFramesAccepted, '
      'postSeekFramesDrained: $postSeekFramesDrained, '
      'kotlinAcceptedChecksumHex: $kotlinAcceptedChecksumHex, '
      'nativeAcceptedChecksumHex: $nativeAcceptedChecksumHex, '
      'nativeDrainedChecksumHex: $nativeDrainedChecksumHex, '
      'observedPartialWrite: $observedPartialWrite, '
      'observedRingFull: $observedRingFull, '
      'syntheticProbeChunk: $syntheticProbeChunk, '
      'eosAlreadyEosStatus: $eosAlreadyEosStatus, '
      'eosAwaitingSeekAckStatus: $eosAwaitingSeekAckStatus, '
      'eosPostAckStatus: $eosPostAckStatus, '
      'midStreamFormatChangeRejected: $midStreamFormatChangeRejected, '
      'seekAckObserved: $seekAckObserved, '
      'discardedFramesOnSeek: $discardedFramesOnSeek, '
      'newStartFrame: $newStartFrame, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
