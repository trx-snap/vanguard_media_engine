// Copyright (c) Connects — Vanguard Phase 4C7AA.
// Public streaming playback status summary helper.
//
// Pure Dart immutable presentation status summary derived from
// VGStreamingPlaybackSession or VGStreamingPlaybackControllerSnapshot.
// Safe for progress bars, buffer indicators, live vs VOD distinction,
// video aspect derivation, and cache-read observability.
//
// Bounded convenience wrapper: does NOT make product feed decisions,
// ABR decisions, retry policy, caching policy, or platform mutations.

import 'vg_streaming_playback_client.dart';
import 'vg_streaming_playback_controller.dart';

export 'vg_streaming_playback_client.dart'
    show VGStreamingPlaybackSession, VGStreamingPlaybackState;
export 'vg_streaming_playback_controller.dart'
    show
        VGStreamingPlaybackControllerSnapshot,
        VGStreamingPlaybackControllerState;

/// Immutable public summary object providing UI-friendly playback and buffer telemetry.
class VGStreamingPlaybackStatusSummary {
  /// Whether an underlying native playback session is active.
  final bool hasSession;

  /// Whether the stream is live/unbounded (`durationMs < 0` or `liveOffsetMs != null`).
  final bool isLive;

  /// Whether the stream is seekable (`durationMs > 0` and not live).
  final bool isSeekable;

  /// Whether the media engine is actively playing.
  final bool isPlaying;

  /// Whether the media engine is opening, buffering, or seeking.
  final bool isBufferingOrOpening;

  /// Whether the playback session has reached a terminal state (stopped, ended, failed, disposed, or unsupported).
  final bool isTerminal;

  /// Total media duration in milliseconds (-1 for live/unbounded streams).
  final int durationMs;

  /// Current playhead position in milliseconds (clamped to >= 0).
  final int positionMs;

  /// Buffered media position in milliseconds ahead of playhead (clamped to >= 0).
  final int bufferedPositionMs;

  /// Look-ahead buffer fill percentage (clamped to 0..100).
  final int bufferedPercent;

  /// Distance from live edge in milliseconds (`null` for VOD).
  final int? liveOffsetMs;

  /// Normalized playback progress fraction clamped to `0.0..1.0` (returns `0.0` for live/unknown duration).
  final double progressFraction;

  /// Normalized buffer fraction clamped to `0.0..1.0` derived from `bufferedPercent / 100.0`.
  final double bufferedFraction;

  /// Target presentation display width in pixels after applying orientation/rotation transform.
  final int effectiveDisplayWidth;

  /// Target presentation display height in pixels after applying orientation/rotation transform.
  final int effectiveDisplayHeight;

  /// Whether the session carries non-zero rotation or explicit display dimensions.
  final bool hasRotationMetadata;

  /// Whether read-through playback cache was enabled for this session.
  final bool playbackCacheEnabled;

  /// Whether playback cache event telemetry listener is attached.
  final bool playbackCacheTelemetryAttached;

  /// Whether any cache read bytes have been observed (`playbackCacheBytesRead > 0`).
  final bool playbackCacheReadObserved;

  /// Cumulative bytes read from cache during playback (clamped to >= 0).
  final int playbackCacheBytesRead;

  /// Latest reported total cache size in bytes (clamped to >= 0).
  final int playbackCacheSizeBytes;

  /// Cumulative count of ignored cache read events (clamped to >= 0).
  final int playbackCacheIgnoredCount;

  /// Reason string for the last ignored cache event, or `null` if none occurred.
  final String? playbackCacheLastIgnoredReason;

  /// Raw diagnostic status string from platform engine.
  final String raw;

  /// Telemetry key-value map.
  final Map<String, Object?> diagnostics;

  const VGStreamingPlaybackStatusSummary({
    required this.hasSession,
    required this.isLive,
    required this.isSeekable,
    required this.isPlaying,
    required this.isBufferingOrOpening,
    required this.isTerminal,
    required this.durationMs,
    required this.positionMs,
    required this.bufferedPositionMs,
    required this.bufferedPercent,
    this.liveOffsetMs,
    required this.progressFraction,
    required this.bufferedFraction,
    required this.effectiveDisplayWidth,
    required this.effectiveDisplayHeight,
    required this.hasRotationMetadata,
    required this.playbackCacheEnabled,
    required this.playbackCacheTelemetryAttached,
    required this.playbackCacheReadObserved,
    required this.playbackCacheBytesRead,
    required this.playbackCacheSizeBytes,
    required this.playbackCacheIgnoredCount,
    this.playbackCacheLastIgnoredReason,
    required this.raw,
    required this.diagnostics,
  });

  /// Creates a status summary from an active or inactive [VGStreamingPlaybackSession].
  factory VGStreamingPlaybackStatusSummary.fromSession(
    VGStreamingPlaybackSession? session,
  ) {
    if (session == null) {
      return const VGStreamingPlaybackStatusSummary.empty();
    }

    final durationMs = session.durationMs < 0 ? -1 : session.durationMs;
    final positionMs = session.positionMs < 0 ? 0 : session.positionMs;
    final bufferedPositionMs = session.bufferedPositionMs < 0
        ? 0
        : session.bufferedPositionMs;
    final bufferedPercent = session.bufferedPercent.clamp(0, 100);
    final liveOffsetMs = session.liveOffsetMs;

    final isLive = durationMs < 0 || liveOffsetMs != null;
    final isSeekable = !isLive && durationMs > 0;

    final isPlaying = session.state == VGStreamingPlaybackState.playing;
    final isBufferingOrOpening =
        session.state == VGStreamingPlaybackState.opening ||
        session.state == VGStreamingPlaybackState.buffering ||
        session.state == VGStreamingPlaybackState.seeking;
    final isTerminal =
        session.state == VGStreamingPlaybackState.ended ||
        session.state == VGStreamingPlaybackState.failed ||
        session.state == VGStreamingPlaybackState.surfaceLost ||
        session.state == VGStreamingPlaybackState.backgrounded ||
        session.state == VGStreamingPlaybackState.disposed ||
        session.state == VGStreamingPlaybackState.unsupported;

    final progressFraction = (isSeekable && durationMs > 0)
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    final bufferedFraction = (bufferedPercent / 100.0).clamp(0.0, 1.0);

    final effectiveDisplayWidth = session.effectiveDisplayWidth < 0
        ? 0
        : session.effectiveDisplayWidth;
    final effectiveDisplayHeight = session.effectiveDisplayHeight < 0
        ? 0
        : session.effectiveDisplayHeight;

    final cacheBytesRead = session.playbackCacheBytesRead < 0
        ? 0
        : session.playbackCacheBytesRead;
    final cacheSizeBytes = session.playbackCacheSizeBytes < 0
        ? 0
        : session.playbackCacheSizeBytes;
    final cacheIgnoredCount = session.playbackCacheIgnoredCount < 0
        ? 0
        : session.playbackCacheIgnoredCount;

    return VGStreamingPlaybackStatusSummary(
      hasSession: true,
      isLive: isLive,
      isSeekable: isSeekable,
      isPlaying: isPlaying,
      isBufferingOrOpening: isBufferingOrOpening,
      isTerminal: isTerminal,
      durationMs: durationMs,
      positionMs: positionMs,
      bufferedPositionMs: bufferedPositionMs,
      bufferedPercent: bufferedPercent,
      liveOffsetMs: liveOffsetMs,
      progressFraction: progressFraction,
      bufferedFraction: bufferedFraction,
      effectiveDisplayWidth: effectiveDisplayWidth,
      effectiveDisplayHeight: effectiveDisplayHeight,
      hasRotationMetadata: session.hasRotationMetadata,
      playbackCacheEnabled: session.playbackCacheEnabled,
      playbackCacheTelemetryAttached: session.playbackCacheTelemetryAttached,
      playbackCacheReadObserved: cacheBytesRead > 0,
      playbackCacheBytesRead: cacheBytesRead,
      playbackCacheSizeBytes: cacheSizeBytes,
      playbackCacheIgnoredCount: cacheIgnoredCount,
      playbackCacheLastIgnoredReason: session.playbackCacheLastIgnoredReason,
      raw: session.raw,
      diagnostics: session.diagnostics,
    );
  }

  /// Creates a status summary from a [VGStreamingPlaybackControllerSnapshot].
  factory VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
    VGStreamingPlaybackControllerSnapshot snapshot,
  ) {
    final session = snapshot.session;
    if (session == null) {
      final isPlaying =
          snapshot.state == VGStreamingPlaybackControllerState.playing;
      final isBufferingOrOpening =
          snapshot.state == VGStreamingPlaybackControllerState.opening;
      final isTerminal =
          snapshot.state == VGStreamingPlaybackControllerState.stopped ||
          snapshot.state == VGStreamingPlaybackControllerState.disposed ||
          snapshot.state == VGStreamingPlaybackControllerState.failed ||
          snapshot.state == VGStreamingPlaybackControllerState.unsupported;

      return VGStreamingPlaybackStatusSummary(
        hasSession: false,
        isLive: false,
        isSeekable: false,
        isPlaying: isPlaying,
        isBufferingOrOpening: isBufferingOrOpening,
        isTerminal: isTerminal,
        durationMs: -1,
        positionMs: 0,
        bufferedPositionMs: 0,
        bufferedPercent: 0,
        liveOffsetMs: null,
        progressFraction: 0.0,
        bufferedFraction: 0.0,
        effectiveDisplayWidth: 0,
        effectiveDisplayHeight: 0,
        hasRotationMetadata: false,
        playbackCacheEnabled: false,
        playbackCacheTelemetryAttached: false,
        playbackCacheReadObserved: false,
        playbackCacheBytesRead: 0,
        playbackCacheSizeBytes: 0,
        playbackCacheIgnoredCount: 0,
        playbackCacheLastIgnoredReason: null,
        raw: snapshot.reason,
        diagnostics: snapshot.diagnostics,
      );
    }

    final durationMs = session.durationMs < 0 ? -1 : session.durationMs;
    final positionMs = session.positionMs < 0 ? 0 : session.positionMs;
    final bufferedPositionMs = session.bufferedPositionMs < 0
        ? 0
        : session.bufferedPositionMs;
    final bufferedPercent = session.bufferedPercent.clamp(0, 100);
    final liveOffsetMs = session.liveOffsetMs;

    final isLive = durationMs < 0 || liveOffsetMs != null;
    final isSeekable = !isLive && durationMs > 0;

    final isPlaying =
        snapshot.state == VGStreamingPlaybackControllerState.playing ||
        session.state == VGStreamingPlaybackState.playing;
    final isBufferingOrOpening =
        snapshot.state == VGStreamingPlaybackControllerState.opening ||
        session.state == VGStreamingPlaybackState.opening ||
        session.state == VGStreamingPlaybackState.buffering ||
        session.state == VGStreamingPlaybackState.seeking;
    final isTerminal =
        snapshot.state == VGStreamingPlaybackControllerState.stopped ||
        snapshot.state == VGStreamingPlaybackControllerState.disposed ||
        snapshot.state == VGStreamingPlaybackControllerState.failed ||
        snapshot.state == VGStreamingPlaybackControllerState.unsupported ||
        session.state == VGStreamingPlaybackState.ended ||
        session.state == VGStreamingPlaybackState.failed ||
        session.state == VGStreamingPlaybackState.surfaceLost ||
        session.state == VGStreamingPlaybackState.backgrounded ||
        session.state == VGStreamingPlaybackState.disposed ||
        session.state == VGStreamingPlaybackState.unsupported;

    final progressFraction = (isSeekable && durationMs > 0)
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    final bufferedFraction = (bufferedPercent / 100.0).clamp(0.0, 1.0);

    final effectiveDisplayWidth = session.effectiveDisplayWidth < 0
        ? 0
        : session.effectiveDisplayWidth;
    final effectiveDisplayHeight = session.effectiveDisplayHeight < 0
        ? 0
        : session.effectiveDisplayHeight;

    final cacheBytesRead = session.playbackCacheBytesRead < 0
        ? 0
        : session.playbackCacheBytesRead;
    final cacheSizeBytes = session.playbackCacheSizeBytes < 0
        ? 0
        : session.playbackCacheSizeBytes;
    final cacheIgnoredCount = session.playbackCacheIgnoredCount < 0
        ? 0
        : session.playbackCacheIgnoredCount;

    return VGStreamingPlaybackStatusSummary(
      hasSession: true,
      isLive: isLive,
      isSeekable: isSeekable,
      isPlaying: isPlaying,
      isBufferingOrOpening: isBufferingOrOpening,
      isTerminal: isTerminal,
      durationMs: durationMs,
      positionMs: positionMs,
      bufferedPositionMs: bufferedPositionMs,
      bufferedPercent: bufferedPercent,
      liveOffsetMs: liveOffsetMs,
      progressFraction: progressFraction,
      bufferedFraction: bufferedFraction,
      effectiveDisplayWidth: effectiveDisplayWidth,
      effectiveDisplayHeight: effectiveDisplayHeight,
      hasRotationMetadata: session.hasRotationMetadata,
      playbackCacheEnabled: session.playbackCacheEnabled,
      playbackCacheTelemetryAttached: session.playbackCacheTelemetryAttached,
      playbackCacheReadObserved: cacheBytesRead > 0,
      playbackCacheBytesRead: cacheBytesRead,
      playbackCacheSizeBytes: cacheSizeBytes,
      playbackCacheIgnoredCount: cacheIgnoredCount,
      playbackCacheLastIgnoredReason: session.playbackCacheLastIgnoredReason,
      raw: session.raw.isNotEmpty ? session.raw : snapshot.reason,
      diagnostics: snapshot.diagnostics.isNotEmpty
          ? snapshot.diagnostics
          : session.diagnostics,
    );
  }

  /// Empty / unsupported-safe fallback summary.
  const VGStreamingPlaybackStatusSummary.empty()
    : hasSession = false,
      isLive = false,
      isSeekable = false,
      isPlaying = false,
      isBufferingOrOpening = false,
      isTerminal = false,
      durationMs = -1,
      positionMs = 0,
      bufferedPositionMs = 0,
      bufferedPercent = 0,
      liveOffsetMs = null,
      progressFraction = 0.0,
      bufferedFraction = 0.0,
      effectiveDisplayWidth = 0,
      effectiveDisplayHeight = 0,
      hasRotationMetadata = false,
      playbackCacheEnabled = false,
      playbackCacheTelemetryAttached = false,
      playbackCacheReadObserved = false,
      playbackCacheBytesRead = 0,
      playbackCacheSizeBytes = 0,
      playbackCacheIgnoredCount = 0,
      playbackCacheLastIgnoredReason = null,
      raw = 'status=EMPTY',
      diagnostics = const <String, Object?>{
        'hasSession': false,
        'state': 'empty',
      };

  /// Serializes status summary into a map.
  Map<String, Object?> toJson() => <String, Object?>{
    'hasSession': hasSession,
    'isLive': isLive,
    'isSeekable': isSeekable,
    'isPlaying': isPlaying,
    'isBufferingOrOpening': isBufferingOrOpening,
    'isTerminal': isTerminal,
    'durationMs': durationMs,
    'positionMs': positionMs,
    'bufferedPositionMs': bufferedPositionMs,
    'bufferedPercent': bufferedPercent,
    if (liveOffsetMs != null) 'liveOffsetMs': liveOffsetMs,
    'progressFraction': progressFraction,
    'bufferedFraction': bufferedFraction,
    'effectiveDisplayWidth': effectiveDisplayWidth,
    'effectiveDisplayHeight': effectiveDisplayHeight,
    'hasRotationMetadata': hasRotationMetadata,
    'playbackCacheEnabled': playbackCacheEnabled,
    'playbackCacheTelemetryAttached': playbackCacheTelemetryAttached,
    'playbackCacheReadObserved': playbackCacheReadObserved,
    'playbackCacheBytesRead': playbackCacheBytesRead,
    'playbackCacheSizeBytes': playbackCacheSizeBytes,
    'playbackCacheIgnoredCount': playbackCacheIgnoredCount,
    if (playbackCacheLastIgnoredReason != null)
      'playbackCacheLastIgnoredReason': playbackCacheLastIgnoredReason,
    'raw': raw,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackStatusSummary('
      'hasSession=$hasSession, isLive=$isLive, isSeekable=$isSeekable, '
      'isPlaying=$isPlaying, isBufferingOrOpening=$isBufferingOrOpening, '
      'isTerminal=$isTerminal, durationMs=$durationMs, positionMs=$positionMs, '
      'bufferedPercent=$bufferedPercent, progressFraction=${progressFraction.toStringAsFixed(3)}, '
      'bufferedFraction=${bufferedFraction.toStringAsFixed(3)}, '
      'cacheBytesRead=$playbackCacheBytesRead, cacheReadObserved=$playbackCacheReadObserved)';
}
