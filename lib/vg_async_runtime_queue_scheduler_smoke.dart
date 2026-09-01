// vg_async_runtime_queue_scheduler_smoke.dart
// vanguard_media_engine - P4-AUDIO-RUNTIME-QUEUE-SCHEDULER: Android True-DAG
// Phase 4 diagnostic async runtime queue/backpressure scheduler integration
// smoke foundation (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAsyncRuntimeQueueSchedulerSmoke` MethodChannel route. Diagnostic-only:
// validates that one native worker thread is the sole caller of the
// AudioClock/ClockedAudioTransportCoordinator control + dispatch path while
// Kotlin control commands are serialized through a bounded native command
// queue, with SPSC source/output ring roles preserved and every media-time
// tick caller-derived on a synthetic frame axis.
//
// Honest non-claims (Proof Boundary):
// diagnostic_async_runtime_queue_scheduler_integration_proof_only_worker_owned_clock_and_coordinator_command_serialized_source_ring_spsc_output_ring_spsc_caller_derived_systime_ticks_only_steady_clock_pacing_only_no_native_media_timebase_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAsyncRuntimeQueueSchedulerSmokeReport {
  const VGAsyncRuntimeQueueSchedulerSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.asyncThreadDecouplingOk,
    required this.controlCommandSerializationOk,
    required this.sourceBackpressureOk,
    required this.outputBackpressureOk,
    required this.providerZeroFillAccountingOk,
    required this.seekEpochCoordinationOk,
    required this.checksumAccountingOk,
    required this.workerJoinOnDestroyOk,
    required this.idempotentDestroyOk,
    required this.noOwnerThreadDispatchOk,
    required this.proofBoundaryOk,
    required this.workerThreadDistinct,
    required this.ownerDispatchCalls,
    required this.commandsEnqueued,
    required this.commandsProcessed,
    required this.commandErrors,
    required this.dispatchCount,
    required this.silenceCount,
    required this.backpressureCount,
    required this.writerBackpressureRejects,
    required this.providerFramesZeroFilled,
    required this.totalFramesAccepted,
    required this.totalFramesRendered,
    required this.totalFramesPushed,
    required this.totalOutputFramesRead,
    required this.kotlinAcceptedChecksumHex,
    required this.nativeAcceptedChecksumHex,
    required this.nativeOutputReadChecksumHex,
    required this.probeFramesZeroFilled,
    required this.probeSilenceCount,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runAsyncRuntimeQueueSchedulerSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'diagnostic_async_runtime_queue_scheduler_integration_proof_only_worker_owned_clock_and_coordinator_command_serialized_source_ring_spsc_output_ring_spsc_caller_derived_systime_ticks_only_steady_clock_pacing_only_no_native_media_timebase_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes';

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

  // ---- Lanes (11 lanes) ---------------------------------------------------

  /// Whether the native worker advanced the transport independently of the
  /// Kotlin owner thread (distinct thread id, zero owner dispatch calls).
  final bool asyncThreadDecouplingOk;

  /// Whether every control command was queue-serialized and executed by the
  /// worker in order with zero command errors.
  final bool controlCommandSerializationOk;

  /// Whether the node-owned source-ring writer fail-closed on a full ring.
  final bool sourceBackpressureOk;

  /// Whether the coordinator recorded output-ring backpressure without
  /// overrunning the output SPSC ring.
  final bool outputBackpressureOk;

  /// Whether the bounded EOS zero-fill probe session reported its provider
  /// zero-fill accounting exactly (kept out of the identity verdict).
  final bool providerZeroFillAccountingOk;

  /// Whether the forward-only seek epoch handshake completed cleanly
  /// (worker coordinator seek + owner output-ring ack, zero discards).
  final bool seekEpochCoordinationOk;

  /// Whether Kotlin accepted, native accepted, and native output read
  /// checksums are identical with lockstep frame accounting.
  final bool checksumAccountingOk;

  /// Whether destroy set the stop flag, woke, and JOINED the worker.
  final bool workerJoinOnDestroyOk;

  /// Whether a second destroy and post-destroy snapshot returned not_found.
  final bool idempotentDestroyOk;

  /// Whether the owner thread performed zero dispatch calls.
  final bool noOwnerThreadDispatchOk;

  /// Whether the native snapshot carried the canonical proof boundary.
  final bool proofBoundaryOk;

  // ---- Metrics ------------------------------------------------------------

  /// Whether the native worker thread id differs from the owner thread id.
  final bool workerThreadDistinct;

  /// Owner-side dispatch call count (structurally 0).
  final int ownerDispatchCalls;

  /// Total control commands enqueued by the owner thread.
  final int commandsEnqueued;

  /// Total control commands executed by the worker thread.
  final int commandsProcessed;

  /// Worker-side command execution errors (must be 0).
  final int commandErrors;

  /// Worker dispatch count over the main session.
  final int dispatchCount;

  /// Coordinator silence windows in the main session (must be 0).
  final int silenceCount;

  /// Coordinator output-ring backpressure records (must be >= 1).
  final int backpressureCount;

  /// Source-ring writer backpressure rejects (must be >= 1).
  final int writerBackpressureRejects;

  /// Provider zero-filled frames in the main session (must be 0).
  final int providerFramesZeroFilled;

  /// Total frames accepted into the source ring (main session).
  final int totalFramesAccepted;

  /// Total frames rendered by the worker (main session).
  final int totalFramesRendered;

  /// Total frames pushed into the output ring (main session).
  final int totalFramesPushed;

  /// Total frames read back by the owner thread (main session).
  final int totalOutputFramesRead;

  /// 64-bit hexadecimal checksum computed on the Kotlin accepted side.
  final String kotlinAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native accepted side.
  final String nativeAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native output read side.
  final String nativeOutputReadChecksumHex;

  /// Provider zero-filled frames in the bounded probe session (> 0).
  final int probeFramesZeroFilled;

  /// Coordinator silence windows in the bounded probe session.
  final int probeSilenceCount;

  // ---- Raw & nested maps --------------------------------------------------

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether the three checksums are non-empty and identical, and
  /// [checksumAccountingOk] is true.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHex.isNotEmpty &&
      nativeAcceptedChecksumHex.isNotEmpty &&
      nativeOutputReadChecksumHex.isNotEmpty &&
      kotlinAcceptedChecksumHex == nativeAcceptedChecksumHex &&
      nativeAcceptedChecksumHex == nativeOutputReadChecksumHex &&
      checksumAccountingOk;

  /// Whether all native diagnostic lanes passed according to the
  /// P4-AUDIO-RUNTIME-QUEUE-SCHEDULER verification contract.
  bool get allNativeLanesPass =>
      pass &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      hasCanonicalProofBoundary &&
      asyncThreadDecouplingOk &&
      controlCommandSerializationOk &&
      sourceBackpressureOk &&
      outputBackpressureOk &&
      providerZeroFillAccountingOk &&
      seekEpochCoordinationOk &&
      checksumAccountingOk &&
      workerJoinOnDestroyOk &&
      idempotentDestroyOk &&
      noOwnerThreadDispatchOk &&
      proofBoundaryOk &&
      workerThreadDistinct &&
      ownerDispatchCalls == 0 &&
      commandsEnqueued > 0 &&
      commandsEnqueued == commandsProcessed &&
      commandErrors == 0 &&
      checksumsMatch &&
      totalFramesAccepted > 0 &&
      totalFramesAccepted == totalFramesRendered &&
      totalFramesAccepted == totalFramesPushed &&
      totalFramesAccepted == totalOutputFramesRead &&
      silenceCount == 0 &&
      providerFramesZeroFilled == 0 &&
      backpressureCount >= 1 &&
      writerBackpressureRejects >= 1 &&
      probeFramesZeroFilled > 0 &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAsyncRuntimeQueueSchedulerSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return _failShapedReport(
        reason: 'native_result_not_a_map',
        details: '',
        lastError: 'native_result_not_a_map',
        proofBoundary: '',
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

    final lanesRaw = raw['lanes'];
    final parsedLanes = <String, Object?>{};
    if (lanesRaw is Map) {
      for (final entry in lanesRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedLanes[k] = entry.value;
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
      final v =
          parsedLanes[key] ?? raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
      if (v is bool) {
        return v;
      }
      if (v is String) {
        final lower = v.trim().toLowerCase();
        if (lower == 'true' || lower == 'pass' || lower == 'ok') {
          return true;
        }
        if (lower == 'false' || lower == 'fail') {
          return false;
        }
      }
      return defaultValue;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      final v =
          parsedMetrics[key] ?? raw[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? defaultValue;
      return defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v =
          raw[key] ?? parsedMetrics[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v != null) return v.toString();
      return defaultValue;
    }

    final pass = parseBool(
      'pass',
      parsedRaw['status']?.toLowerCase() == 'pass',
    );
    final failureReason = parseString(
      'failureReason',
      parsedRaw['reason'] ?? '',
    );

    return VGAsyncRuntimeQueueSchedulerSmokeReport(
      pass: pass,
      status: parseString('status', pass ? 'pass' : 'fail'),
      marker: parseString(
        'marker',
        pass ? passMarkerConstant : failMarkerConstant,
      ),
      proofBoundary: parseString('proofBoundary'),
      failureReason: failureReason,
      details: parseString('details'),
      asyncThreadDecouplingOk: parseBool('asyncThreadDecouplingOk'),
      controlCommandSerializationOk: parseBool('controlCommandSerializationOk'),
      sourceBackpressureOk: parseBool('sourceBackpressureOk'),
      outputBackpressureOk: parseBool('outputBackpressureOk'),
      providerZeroFillAccountingOk: parseBool('providerZeroFillAccountingOk'),
      seekEpochCoordinationOk: parseBool('seekEpochCoordinationOk'),
      checksumAccountingOk: parseBool('checksumAccountingOk'),
      workerJoinOnDestroyOk: parseBool('workerJoinOnDestroyOk'),
      idempotentDestroyOk: parseBool('idempotentDestroyOk'),
      noOwnerThreadDispatchOk: parseBool('noOwnerThreadDispatchOk'),
      proofBoundaryOk: parseBool('proofBoundaryOk'),
      workerThreadDistinct: parseBool('workerThreadDistinct'),
      ownerDispatchCalls: parseInt('ownerDispatchCalls', -1),
      commandsEnqueued: parseInt('commandsEnqueued', -1),
      commandsProcessed: parseInt('commandsProcessed', -1),
      commandErrors: parseInt('commandErrors', -1),
      dispatchCount: parseInt('dispatchCount'),
      silenceCount: parseInt('silenceCount', -1),
      backpressureCount: parseInt('backpressureCount', -1),
      writerBackpressureRejects: parseInt('writerBackpressureRejects', -1),
      providerFramesZeroFilled: parseInt('providerFramesZeroFilled', -1),
      totalFramesAccepted: parseInt('totalFramesAccepted'),
      totalFramesRendered: parseInt('totalFramesRendered'),
      totalFramesPushed: parseInt('totalFramesPushed'),
      totalOutputFramesRead: parseInt('totalOutputFramesRead'),
      kotlinAcceptedChecksumHex: parseString('kotlinAcceptedChecksumHex'),
      nativeAcceptedChecksumHex: parseString('nativeAcceptedChecksumHex'),
      nativeOutputReadChecksumHex: parseString('nativeOutputReadChecksumHex'),
      probeFramesZeroFilled: parseInt('probeFramesZeroFilled', -1),
      probeSilenceCount: parseInt('probeSilenceCount', -1),
      lanes: Map<String, Object?>.unmodifiable(parsedLanes),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
      raw: Map<String, String>.unmodifiable(parsedRaw),
      lastError: parseString(
        'lastError',
        failureReason.isNotEmpty ? failureReason : '',
      ),
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
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'raw': Map<String, String>.from(raw),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGAsyncRuntimeQueueSchedulerSmokeReport _failShapedReport({
    required String reason,
    required String details,
    required String lastError,
    String proofBoundary = proofBoundaryConstant,
  }) {
    return VGAsyncRuntimeQueueSchedulerSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundary,
      failureReason: reason,
      details: details,
      asyncThreadDecouplingOk: false,
      controlCommandSerializationOk: false,
      sourceBackpressureOk: false,
      outputBackpressureOk: false,
      providerZeroFillAccountingOk: false,
      seekEpochCoordinationOk: false,
      checksumAccountingOk: false,
      workerJoinOnDestroyOk: false,
      idempotentDestroyOk: false,
      noOwnerThreadDispatchOk: false,
      proofBoundaryOk: false,
      workerThreadDistinct: false,
      ownerDispatchCalls: -1,
      commandsEnqueued: -1,
      commandsProcessed: -1,
      commandErrors: -1,
      dispatchCount: 0,
      silenceCount: -1,
      backpressureCount: -1,
      writerBackpressureRejects: -1,
      providerFramesZeroFilled: -1,
      totalFramesAccepted: 0,
      totalFramesRendered: 0,
      totalFramesPushed: 0,
      totalOutputFramesRead: 0,
      kotlinAcceptedChecksumHex: '',
      nativeAcceptedChecksumHex: '',
      nativeOutputReadChecksumHex: '',
      probeFramesZeroFilled: -1,
      probeSilenceCount: -1,
      lanes: Map<String, Object?>.unmodifiable(<String, Object?>{
        'status': 'FAIL',
        'reason': reason,
      }),
      metrics: Map<String, Object?>.unmodifiable(<String, Object?>{
        'status': 'FAIL',
        'reason': reason,
      }),
      raw: Map<String, String>.unmodifiable(<String, String>{
        'status': 'FAIL',
        'reason': reason,
      }),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 async runtime queue/backpressure
  /// scheduler integration diagnostic smoke harness.
  ///
  /// Defaults mirror the Kotlin coordinator; [timeout] bounds the call and
  /// is forwarded as `deadlineMs`. [channel] may be injected for testing.
  /// Any MethodChannel error yields an unsupported/fail-shaped report.
  static Future<VGAsyncRuntimeQueueSchedulerSmokeReport>
  runAsyncRuntimeQueueSchedulerSmoke({
    int sampleRate = 48000,
    int channelCount = 2,
    int maxFramesPerMix = 256,
    int sourceRingCapacityFrames = 4096,
    int outputRingCapacityFrames = 1024,
    int mainWindows = 64,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'maxFramesPerMix': maxFramesPerMix,
      'sourceRingCapacityFrames': sourceRingCapacityFrames,
      'outputRingCapacityFrames': outputRingCapacityFrames,
      'mainWindows': mainWindows,
      'deadlineMs': timeout != null ? timeout.inMilliseconds : 30000,
    };
    try {
      final future = ch.invokeMethod<Object?>(methodName, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return _failShapedReport(
        reason: 'timeout',
        details: te.toString(),
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return _failShapedReport(
        reason: 'platform_exception:${pe.code}',
        details: pe.message ?? '',
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } on MissingPluginException catch (mpe) {
      return _failShapedReport(
        reason: 'unsupported_platform',
        details: mpe.toString(),
        lastError: 'unsupported_platform: $mpe',
      );
    } catch (e) {
      return _failShapedReport(
        reason: 'exception:$e',
        details: e.toString(),
        lastError: 'exception:$e',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAsyncRuntimeQueueSchedulerSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.asyncThreadDecouplingOk == asyncThreadDecouplingOk &&
        other.controlCommandSerializationOk == controlCommandSerializationOk &&
        other.sourceBackpressureOk == sourceBackpressureOk &&
        other.outputBackpressureOk == outputBackpressureOk &&
        other.providerZeroFillAccountingOk == providerZeroFillAccountingOk &&
        other.seekEpochCoordinationOk == seekEpochCoordinationOk &&
        other.checksumAccountingOk == checksumAccountingOk &&
        other.workerJoinOnDestroyOk == workerJoinOnDestroyOk &&
        other.idempotentDestroyOk == idempotentDestroyOk &&
        other.noOwnerThreadDispatchOk == noOwnerThreadDispatchOk &&
        other.proofBoundaryOk == proofBoundaryOk &&
        other.workerThreadDistinct == workerThreadDistinct &&
        other.ownerDispatchCalls == ownerDispatchCalls &&
        other.commandsEnqueued == commandsEnqueued &&
        other.commandsProcessed == commandsProcessed &&
        other.commandErrors == commandErrors &&
        other.dispatchCount == dispatchCount &&
        other.silenceCount == silenceCount &&
        other.backpressureCount == backpressureCount &&
        other.writerBackpressureRejects == writerBackpressureRejects &&
        other.providerFramesZeroFilled == providerFramesZeroFilled &&
        other.totalFramesAccepted == totalFramesAccepted &&
        other.totalFramesRendered == totalFramesRendered &&
        other.totalFramesPushed == totalFramesPushed &&
        other.totalOutputFramesRead == totalOutputFramesRead &&
        other.kotlinAcceptedChecksumHex == kotlinAcceptedChecksumHex &&
        other.nativeAcceptedChecksumHex == nativeAcceptedChecksumHex &&
        other.nativeOutputReadChecksumHex == nativeOutputReadChecksumHex &&
        other.probeFramesZeroFilled == probeFramesZeroFilled &&
        other.probeSilenceCount == probeSilenceCount &&
        mapEquals(other.lanes, lanes) &&
        mapEquals(other.metrics, metrics) &&
        mapEquals(other.raw, raw) &&
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
    asyncThreadDecouplingOk,
    controlCommandSerializationOk,
    sourceBackpressureOk,
    outputBackpressureOk,
    providerZeroFillAccountingOk,
    seekEpochCoordinationOk,
    checksumAccountingOk,
    workerJoinOnDestroyOk,
    idempotentDestroyOk,
    noOwnerThreadDispatchOk,
    proofBoundaryOk,
    workerThreadDistinct,
    ownerDispatchCalls,
    commandsEnqueued,
    commandsProcessed,
    commandErrors,
    dispatchCount,
    silenceCount,
    backpressureCount,
    writerBackpressureRejects,
    providerFramesZeroFilled,
    totalFramesAccepted,
    totalFramesRendered,
    totalFramesPushed,
    totalOutputFramesRead,
    kotlinAcceptedChecksumHex,
    nativeAcceptedChecksumHex,
    nativeOutputReadChecksumHex,
    probeFramesZeroFilled,
    probeSilenceCount,
    _stableMapHash(lanes),
    _stableMapHash(metrics),
    _stableMapHash(raw),
    lastError,
  ]);

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAsyncRuntimeQueueSchedulerSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'asyncThreadDecouplingOk: $asyncThreadDecouplingOk, '
      'controlCommandSerializationOk: $controlCommandSerializationOk, '
      'sourceBackpressureOk: $sourceBackpressureOk, '
      'outputBackpressureOk: $outputBackpressureOk, '
      'providerZeroFillAccountingOk: $providerZeroFillAccountingOk, '
      'seekEpochCoordinationOk: $seekEpochCoordinationOk, '
      'checksumAccountingOk: $checksumAccountingOk, '
      'workerJoinOnDestroyOk: $workerJoinOnDestroyOk, '
      'idempotentDestroyOk: $idempotentDestroyOk, '
      'noOwnerThreadDispatchOk: $noOwnerThreadDispatchOk, '
      'proofBoundaryOk: $proofBoundaryOk, '
      'workerThreadDistinct: $workerThreadDistinct, '
      'ownerDispatchCalls: $ownerDispatchCalls, '
      'commandsEnqueued: $commandsEnqueued, '
      'commandsProcessed: $commandsProcessed, '
      'commandErrors: $commandErrors, '
      'dispatchCount: $dispatchCount, '
      'silenceCount: $silenceCount, '
      'backpressureCount: $backpressureCount, '
      'writerBackpressureRejects: $writerBackpressureRejects, '
      'providerFramesZeroFilled: $providerFramesZeroFilled, '
      'totalFramesAccepted: $totalFramesAccepted, '
      'totalFramesRendered: $totalFramesRendered, '
      'totalFramesPushed: $totalFramesPushed, '
      'totalOutputFramesRead: $totalOutputFramesRead, '
      'kotlinAcceptedChecksumHex: $kotlinAcceptedChecksumHex, '
      'nativeAcceptedChecksumHex: $nativeAcceptedChecksumHex, '
      'nativeOutputReadChecksumHex: $nativeOutputReadChecksumHex, '
      'probeFramesZeroFilled: $probeFramesZeroFilled, '
      'probeSilenceCount: $probeSilenceCount, '
      'lastError: $lastError)';
}
