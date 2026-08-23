// Copyright (c) Connects — Vanguard Phase 4C6E.
// Public package-level streaming cache API surface for Android backend.
//
// Safe to import on iOS: all methods catch [MissingPluginException] and return
// typed unsupported results instead of crashing.

import 'dart:async';

import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Value objects
// ─────────────────────────────────────────────────────────────────────────────

/// Optional cache configuration forwarded to the Android backend.
///
/// All fields have safe defaults so callers need not specify anything for
/// standard prewarm usage.
class VGPlaybackCacheOptions {
  /// Whether the Media3 cache substrate is enabled on Android.
  /// Defaults to `true`. Must be `true` for [VGStreamingCacheClient.prewarm].
  final bool cacheEnabled;

  /// Maximum disk budget for the shared cache, in bytes.
  /// `null` → platform default (512 MiB).
  final int? cacheMaxBytes;

  /// Cache subdirectory name under the Android application cache directory.
  /// `null` → platform default (`"vanguard_playback_cache"`).
  final String? cacheDirectoryName;

  const VGPlaybackCacheOptions({
    this.cacheEnabled = true,
    this.cacheMaxBytes,
    this.cacheDirectoryName,
  });

  Map<String, Object?> toArgs() => {
    'cacheEnabled': cacheEnabled,
    if (cacheMaxBytes != null) 'cacheMaxBytes': cacheMaxBytes,
    if (cacheDirectoryName != null) 'cacheDirectoryName': cacheDirectoryName,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Typed result objects
// ─────────────────────────────────────────────────────────────────────────────

/// Result of [VGStreamingCacheClient.getStatus].
class VGPlaybackCacheStatus {
  /// Always `"Phase4C6E"` on Android; `"unsupported"` on iOS/other.
  final String phase;

  /// Metrics phase identifier, e.g. `"Phase4C6F2"`, or `null`.
  final String? metricsPhase;

  /// Whether the call succeeded.
  final bool pass;

  /// Lifecycle state string, e.g. `"available"` or `"error"`.
  final String state;

  /// Whether the Android SimpleCache was successfully initialised.
  final bool cacheAvailable;

  /// Whether the cache is configured as enabled.
  final bool cacheEnabled;

  /// Absolute path to the Android cache directory, or `null`.
  final String? cacheDir;

  /// Configured maximum cache size in bytes, or `null`.
  final int? maxCacheBytes;

  /// Total cache space used in bytes on the Android backend, or 0 if unavailable/unsupported.
  final int cacheSpaceBytes;

  /// Number of distinct cached resources currently indexed on Android, or 0 if unavailable/unsupported.
  final int resourceCount;

  /// Raw diagnostic string from the platform.
  final String raw;

  const VGPlaybackCacheStatus({
    required this.phase,
    this.metricsPhase,
    required this.pass,
    required this.state,
    required this.cacheAvailable,
    required this.cacheEnabled,
    this.cacheDir,
    this.maxCacheBytes,
    this.cacheSpaceBytes = 0,
    this.resourceCount = 0,
    required this.raw,
  });

  factory VGPlaybackCacheStatus.fromMap(Map<Object?, Object?> m) {
    return VGPlaybackCacheStatus(
      phase: m['phase'] as String? ?? 'Phase4C6E',
      metricsPhase: m['metricsPhase'] as String?,
      pass: m['pass'] as bool? ?? false,
      state: m['state'] as String? ?? 'unknown',
      cacheAvailable: m['cacheAvailable'] as bool? ?? false,
      cacheEnabled: m['cacheEnabled'] as bool? ?? false,
      cacheDir: m['cacheDir'] as String?,
      maxCacheBytes: (m['maxCacheBytes'] as num?)?.toInt(),
      cacheSpaceBytes: (m['cacheSpaceBytes'] as num?)?.toInt() ?? 0,
      resourceCount: (m['resourceCount'] as num?)?.toInt() ?? 0,
      raw: m['raw'] as String? ?? '',
    );
  }

  /// Returned when the native plugin is not available (e.g. iOS).
  factory VGPlaybackCacheStatus.unsupported() => const VGPlaybackCacheStatus(
    phase: 'unsupported',
    pass: false,
    state: 'unsupported',
    cacheAvailable: false,
    cacheEnabled: false,
    cacheSpaceBytes: 0,
    resourceCount: 0,
    raw: 'status=UNSUPPORTED;platform=non-android',
  );

  @override
  String toString() =>
      'VGPlaybackCacheStatus(phase=$phase, pass=$pass, state=$state, '
      'cacheAvailable=$cacheAvailable, cacheEnabled=$cacheEnabled, '
      'cacheSpaceBytes=$cacheSpaceBytes, resourceCount=$resourceCount)';
}

/// Accepted prewarm start states from the Android coordinator.
enum VGPlaybackPrewarmStartState {
  /// Job was accepted and queued.
  accepted,

  /// A job with the same requestId already exists.
  duplicate,

  /// Args were invalid (blank requestId/uri, cache disabled, etc.).
  invalid,

  /// The prewarm engine has been shut down.
  shutdown,

  /// The platform is not supported.
  unsupported,
}

/// Result of [VGStreamingCacheClient.prewarm].
class VGPlaybackPrewarmStartResult {
  /// Always `"Phase4C6E"` on Android; `"unsupported"` on iOS/other.
  final String phase;

  /// Whether the job was accepted.
  final bool pass;

  /// The request ID echoed back from the platform.
  final String requestId;

  /// Start state.
  final VGPlaybackPrewarmStartState state;

  /// Raw diagnostic string from the platform.
  final String raw;

  const VGPlaybackPrewarmStartResult({
    required this.phase,
    required this.pass,
    required this.requestId,
    required this.state,
    required this.raw,
  });

  factory VGPlaybackPrewarmStartResult.fromMap(
    String requestId,
    Map<Object?, Object?> m,
  ) {
    final stateStr = m['state'] as String? ?? 'invalid';
    final state = switch (stateStr) {
      'accepted' => VGPlaybackPrewarmStartState.accepted,
      'duplicate' => VGPlaybackPrewarmStartState.duplicate,
      'shutdown' => VGPlaybackPrewarmStartState.shutdown,
      _ => VGPlaybackPrewarmStartState.invalid,
    };
    return VGPlaybackPrewarmStartResult(
      phase: m['phase'] as String? ?? 'Phase4C6E',
      pass: m['pass'] as bool? ?? false,
      requestId: m['requestId'] as String? ?? requestId,
      state: state,
      raw: m['raw'] as String? ?? '',
    );
  }

  /// Returned when the native plugin is not available.
  factory VGPlaybackPrewarmStartResult.unsupported(String requestId) =>
      VGPlaybackPrewarmStartResult(
        phase: 'unsupported',
        pass: false,
        requestId: requestId,
        state: VGPlaybackPrewarmStartState.unsupported,
        raw: 'status=UNSUPPORTED;platform=non-android',
      );

  @override
  String toString() =>
      'VGPlaybackPrewarmStartResult(phase=$phase, pass=$pass, '
      'requestId=$requestId, state=${state.name})';
}

/// Lifecycle states of an in-flight or completed prewarm job.
enum VGPlaybackPrewarmJobState {
  /// Job is queued but not yet running.
  queued,

  /// Job is actively fetching.
  running,

  /// Job completed successfully.
  succeeded,

  /// Job was cancelled.
  cancelled,

  /// Job failed (e.g. network error).
  failed,

  /// No job exists for the given requestId.
  notFound,

  /// RequestId was blank or invalid.
  invalid,

  /// The platform is not supported.
  unsupported,
}

/// Result of [VGStreamingCacheClient.getPrewarmStatus].
class VGPlaybackPrewarmStatus {
  /// Always `"Phase4C6E"` on Android; `"unsupported"` on iOS/other.
  final String phase;

  /// The request ID.
  final String requestId;

  /// Current job state.
  final VGPlaybackPrewarmJobState state;

  /// Bytes in the cache for this URI.
  final int bytesCached;

  /// Net new bytes cached in this job run.
  final int newBytesCached;

  /// Total request length as reported by Media3.
  final int requestLength;

  /// Whether the Android SimpleCache was available for this job.
  final bool cacheAvailable;

  /// Raw diagnostic string from the platform.
  final String raw;

  const VGPlaybackPrewarmStatus({
    required this.phase,
    required this.requestId,
    required this.state,
    required this.bytesCached,
    required this.newBytesCached,
    required this.requestLength,
    required this.cacheAvailable,
    required this.raw,
  });

  factory VGPlaybackPrewarmStatus.fromMap(
    String requestId,
    Map<Object?, Object?> m,
  ) {
    final stateStr = m['state'] as String? ?? 'not_found';
    final state = switch (stateStr) {
      'queued' => VGPlaybackPrewarmJobState.queued,
      'running' => VGPlaybackPrewarmJobState.running,
      'succeeded' => VGPlaybackPrewarmJobState.succeeded,
      'cancelled' => VGPlaybackPrewarmJobState.cancelled,
      'failed' => VGPlaybackPrewarmJobState.failed,
      'not_found' => VGPlaybackPrewarmJobState.notFound,
      'invalid' => VGPlaybackPrewarmJobState.invalid,
      _ => VGPlaybackPrewarmJobState.notFound,
    };
    return VGPlaybackPrewarmStatus(
      phase: m['phase'] as String? ?? 'Phase4C6E',
      requestId: m['requestId'] as String? ?? requestId,
      state: state,
      bytesCached: (m['bytesCached'] as num?)?.toInt() ?? 0,
      newBytesCached: (m['newBytesCached'] as num?)?.toInt() ?? 0,
      requestLength: (m['requestLength'] as num?)?.toInt() ?? 0,
      cacheAvailable: m['cacheAvailable'] as bool? ?? false,
      raw: m['raw'] as String? ?? '',
    );
  }

  /// Returned when the native plugin is not available.
  factory VGPlaybackPrewarmStatus.unsupported(String requestId) =>
      VGPlaybackPrewarmStatus(
        phase: 'unsupported',
        requestId: requestId,
        state: VGPlaybackPrewarmJobState.unsupported,
        bytesCached: 0,
        newBytesCached: 0,
        requestLength: 0,
        cacheAvailable: false,
        raw: 'status=UNSUPPORTED;platform=non-android',
      );

  @override
  String toString() =>
      'VGPlaybackPrewarmStatus(phase=$phase, requestId=$requestId, '
      'state=${state.name}, bytesCached=$bytesCached)';
}

/// Result of [VGStreamingCacheClient.cancelPrewarm].
class VGPlaybackPrewarmCancelResult {
  /// Always `"Phase4C6E"` on Android; `"unsupported"` on iOS/other.
  final String phase;

  /// Whether the cancel operation completed safely (true even if not found).
  final bool pass;

  /// The request ID echoed back from the platform.
  final String requestId;

  /// `"cancel_requested"`, `"not_found_or_terminal"`, `"invalid"`, or `"unsupported"`.
  final String state;

  /// Raw diagnostic string from the platform.
  final String raw;

  const VGPlaybackPrewarmCancelResult({
    required this.phase,
    required this.pass,
    required this.requestId,
    required this.state,
    required this.raw,
  });

  factory VGPlaybackPrewarmCancelResult.fromMap(
    String requestId,
    Map<Object?, Object?> m,
  ) {
    return VGPlaybackPrewarmCancelResult(
      phase: m['phase'] as String? ?? 'Phase4C6E',
      pass: m['pass'] as bool? ?? false,
      requestId: m['requestId'] as String? ?? requestId,
      state: m['state'] as String? ?? 'unknown',
      raw: m['raw'] as String? ?? '',
    );
  }

  /// Returned when the native plugin is not available.
  factory VGPlaybackPrewarmCancelResult.unsupported(String requestId) =>
      VGPlaybackPrewarmCancelResult(
        phase: 'unsupported',
        pass: false,
        requestId: requestId,
        state: 'unsupported',
        raw: 'status=UNSUPPORTED;platform=non-android',
      );

  @override
  String toString() =>
      'VGPlaybackPrewarmCancelResult(phase=$phase, pass=$pass, '
      'requestId=$requestId, state=$state)';
}

/// Result of [VGStreamingCacheClient.clear].
///
/// Phase 4C6F: returned by the `clearPlaybackCache` MethodChannel route.
class VGPlaybackCacheClearResult {
  /// Always `"Phase4C6F"` on Android; `"unsupported"` on iOS/other.
  final String phase;

  /// Whether the clear operation completed without a fatal error.
  ///
  /// `true` even when [cacheAvailable] is `false` (nothing to clear is still
  /// a successful no-op per contract).
  final bool pass;

  /// Lifecycle state: `"cleared"`, `"unavailable"`, `"error"`, or `"unsupported"`.
  final String state;

  /// Whether the Android SimpleCache was successfully initialised.
  final bool cacheAvailable;

  /// Cache space in bytes before clearing.
  final int beforeBytes;

  /// Cache space in bytes after clearing.
  final int afterBytes;

  /// Number of resource keys present before clearing.
  final int resourceCountBefore;

  /// Number of keys for which [Cache.removeResource] succeeded.
  final int removedResourceCount;

  /// Number of keys for which [Cache.removeResource] threw.
  final int failedResourceCount;

  /// Raw diagnostic string from the platform.
  final String raw;

  const VGPlaybackCacheClearResult({
    required this.phase,
    required this.pass,
    required this.state,
    required this.cacheAvailable,
    required this.beforeBytes,
    required this.afterBytes,
    required this.resourceCountBefore,
    required this.removedResourceCount,
    required this.failedResourceCount,
    required this.raw,
  });

  factory VGPlaybackCacheClearResult.fromMap(Map<Object?, Object?> m) {
    return VGPlaybackCacheClearResult(
      phase: m['phase'] as String? ?? 'Phase4C6F',
      pass: m['pass'] as bool? ?? false,
      state: m['state'] as String? ?? 'unknown',
      cacheAvailable: m['cacheAvailable'] as bool? ?? false,
      beforeBytes: (m['beforeBytes'] as num?)?.toInt() ?? 0,
      afterBytes: (m['afterBytes'] as num?)?.toInt() ?? 0,
      resourceCountBefore: (m['resourceCountBefore'] as num?)?.toInt() ?? 0,
      removedResourceCount: (m['removedResourceCount'] as num?)?.toInt() ?? 0,
      failedResourceCount: (m['failedResourceCount'] as num?)?.toInt() ?? 0,
      raw: m['raw'] as String? ?? '',
    );
  }

  /// Returned when the native plugin is not available (e.g. iOS).
  factory VGPlaybackCacheClearResult.unsupported() =>
      const VGPlaybackCacheClearResult(
        phase: 'unsupported',
        pass: false,
        state: 'unsupported',
        cacheAvailable: false,
        beforeBytes: 0,
        afterBytes: 0,
        resourceCountBefore: 0,
        removedResourceCount: 0,
        failedResourceCount: 0,
        raw: 'status=UNSUPPORTED;platform=non-android',
      );

  @override
  String toString() =>
      'VGPlaybackCacheClearResult(phase=$phase, pass=$pass, state=$state, '
      'cacheAvailable=$cacheAvailable, beforeBytes=$beforeBytes, '
      'afterBytes=$afterBytes, removed=$removedResourceCount, '
      'failed=$failedResourceCount)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public client
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 4C6E: Public Dart API for the Android streaming cache/prewarm backend.
///
/// Calls the four MethodChannel routes exposed by
/// `AndroidDagStreamingPlaybackCoordinator`:
///
/// - [getStatus] — returns current cache backend status.
/// - [prewarm]  — starts a bounded background prewarm job; returns immediately.
/// - [getPrewarmStatus] — polls the state of an in-flight job.
/// - [cancelPrewarm]   — requests cancellation of a job (idempotent if missing).
///
/// On platforms where the plugin is not installed (e.g. iOS), all methods
/// silently catch [MissingPluginException] and return typed unsupported results.
/// No Flutter widget imports are used.
class VGStreamingCacheClient {
  VGStreamingCacheClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Returns the current streaming cache backend status.
  ///
  /// Optionally customised via [options] (cache config forwarded to Android).
  Future<VGPlaybackCacheStatus> getStatus({
    VGPlaybackCacheOptions options = const VGPlaybackCacheOptions(),
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'getPlaybackCacheStatus',
        options.toArgs(),
      );
      if (raw is! Map) {
        return VGPlaybackCacheStatus.unsupported();
      }
      return VGPlaybackCacheStatus.fromMap(raw.cast<Object?, Object?>());
    } on MissingPluginException {
      return VGPlaybackCacheStatus.unsupported();
    }
  }

  /// Starts a bounded background prewarm job for [uri].
  ///
  /// Returns immediately with [VGPlaybackPrewarmStartResult]. Poll progress
  /// with [getPrewarmStatus].
  ///
  /// - [requestId]  — caller-assigned unique job ID (must not be blank).
  /// - [uri]        — HTTP/HTTPS URI of the resource to prewarm.
  /// - [httpHeaders] — optional extra request headers.
  /// - [maxBytes]   — maximum bytes to fetch (default 2 MiB).
  /// - [options]    — cache configuration; [options.cacheEnabled] must be `true`.
  Future<VGPlaybackPrewarmStartResult> prewarm({
    required String requestId,
    required Uri uri,
    Map<String, String>? httpHeaders,
    int maxBytes = 2 * 1024 * 1024,
    VGPlaybackCacheOptions options = const VGPlaybackCacheOptions(),
  }) async {
    try {
      final args = <String, Object?>{
        'requestId': requestId,
        'uri': uri.toString(),
        if (httpHeaders != null) 'httpHeaders': httpHeaders,
        'maxBytes': maxBytes,
        ...options.toArgs(),
      };
      final raw = await _channel.invokeMethod<Object?>(
        'startPlaybackCachePrewarm',
        args,
      );
      if (raw is! Map) {
        return VGPlaybackPrewarmStartResult.unsupported(requestId);
      }
      return VGPlaybackPrewarmStartResult.fromMap(
        requestId,
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGPlaybackPrewarmStartResult.unsupported(requestId);
    }
  }

  /// Returns the current status of a prewarm job identified by [requestId].
  ///
  /// Returns [VGPlaybackPrewarmJobState.notFound] when no such job exists.
  Future<VGPlaybackPrewarmStatus> getPrewarmStatus(String requestId) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'getPlaybackCachePrewarmStatus',
        {'requestId': requestId},
      );
      if (raw is! Map) {
        return VGPlaybackPrewarmStatus.unsupported(requestId);
      }
      return VGPlaybackPrewarmStatus.fromMap(
        requestId,
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGPlaybackPrewarmStatus.unsupported(requestId);
    }
  }

  /// Requests cancellation of the prewarm job identified by [requestId].
  ///
  /// Safe to call when the job does not exist or has already finished.
  Future<VGPlaybackPrewarmCancelResult> cancelPrewarm(String requestId) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'cancelPlaybackCachePrewarm',
        {'requestId': requestId},
      );
      if (raw is! Map) {
        return VGPlaybackPrewarmCancelResult.unsupported(requestId);
      }
      return VGPlaybackPrewarmCancelResult.fromMap(
        requestId,
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGPlaybackPrewarmCancelResult.unsupported(requestId);
    }
  }

  /// Phase 4C6F: Clears all resources from the Android streaming playback cache.
  ///
  /// Calls the `clearPlaybackCache` MethodChannel route on the Android backend.
  /// The operation runs on a background thread; this future resolves when the
  /// clear is complete.
  ///
  /// Returns a [VGPlaybackCacheClearResult] with counts and byte measurements.
  /// On platforms where the plugin is not installed (e.g. iOS), silently catches
  /// [MissingPluginException] and returns [VGPlaybackCacheClearResult.unsupported].
  ///
  /// [options] — optional cache configuration (directory, max bytes, enabled flag).
  /// Defaults to `cacheEnabled=true` to match the backend's public API default.
  Future<VGPlaybackCacheClearResult> clear({
    VGPlaybackCacheOptions options = const VGPlaybackCacheOptions(),
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'clearPlaybackCache',
        options.toArgs(),
      );
      if (raw is! Map) {
        return VGPlaybackCacheClearResult.unsupported();
      }
      return VGPlaybackCacheClearResult.fromMap(raw.cast<Object?, Object?>());
    } on MissingPluginException {
      return VGPlaybackCacheClearResult.unsupported();
    }
  }
}
