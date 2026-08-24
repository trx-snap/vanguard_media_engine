// Copyright (c) Connects — Vanguard Phase 4C7B.
// Public package-level adaptive streaming playback API client.
//
// Safe to import on all platforms: methods catch [MissingPluginException]
// and return typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

import 'vg_streaming_cache_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Enums & Value objects
// ─────────────────────────────────────────────────────────────────────────────

/// Supported adaptive streaming container format hints.
enum VGStreamingFormatHint {
  /// Engine inspects URI extension and MIME type to auto-detect format.
  auto,

  /// HTTP Live Streaming (RFC 8216 / RFC 8216bis), including Apple LL-HLS.
  hls,

  /// Dynamic Adaptive Streaming over HTTP (ISO/IEC 23009-1).
  dash;

  /// Returns the uppercase string representation consumed by the native platform engine.
  String toNative() => switch (this) {
    VGStreamingFormatHint.auto => 'AUTO',
    VGStreamingFormatHint.hls => 'HLS',
    VGStreamingFormatHint.dash => 'DASH',
  };

  /// Parses a string into [VGStreamingFormatHint], defaulting to [fallback].
  static VGStreamingFormatHint fromString(
    String? value, {
    VGStreamingFormatHint fallback = VGStreamingFormatHint.auto,
  }) {
    if (value == null) return fallback;
    return switch (value.trim().toLowerCase()) {
      'hls' => VGStreamingFormatHint.hls,
      'dash' => VGStreamingFormatHint.dash,
      'auto' => VGStreamingFormatHint.auto,
      _ => fallback,
    };
  }
}

/// Network policy profile applied to buffer sizing and initial bitrate selection.
enum VGStreamingNetworkProfile {
  /// Platform engine defaults (Media3 / AVPlayer standard defaults).
  auto,

  /// High-bandwidth, stable connection profile; enables aggressive readahead.
  stable,

  /// Bandwidth-constrained or data-saver profile; uses conservative bitrates and deeper buffers.
  constrained,

  /// Low-latency live profile; minimizes buffer depth to track live edge.
  lowLatency;

  /// Returns the uppercase string representation consumed by the native platform engine.
  String toNative() => switch (this) {
    VGStreamingNetworkProfile.auto => 'AUTO',
    VGStreamingNetworkProfile.stable => 'STABLE',
    VGStreamingNetworkProfile.constrained => 'CONSTRAINED',
    VGStreamingNetworkProfile.lowLatency => 'LOW_LATENCY',
  };

  /// Parses a string into [VGStreamingNetworkProfile], defaulting to [VGStreamingNetworkProfile.auto].
  static VGStreamingNetworkProfile fromString(String? value) {
    if (value == null) return VGStreamingNetworkProfile.auto;
    return switch (value.trim().toLowerCase().replaceAll('_', '')) {
      'stable' => VGStreamingNetworkProfile.stable,
      'constrained' => VGStreamingNetworkProfile.constrained,
      'lowlatency' => VGStreamingNetworkProfile.lowLatency,
      _ => VGStreamingNetworkProfile.auto,
    };
  }
}

/// Lifecycle state reported by [VGStreamingPlaybackSession].
enum VGStreamingPlaybackState {
  /// Idle state prior to stream initialization or after explicit stop.
  idle,

  /// Opening/preparing manifest, codecs, and presentation surface.
  opening,

  /// Buffering media segments prior to playback or during rebuffering.
  buffering,

  /// Actively playing decoded frames to presentation texture.
  playing,

  /// Paused; retaining last rendered frame on texture.
  paused,

  /// Seeking to a new playhead position.
  seeking,

  /// Stream reached end of media duration (VOD).
  ended,

  /// Playback failed with a fatal error.
  failed,

  /// Presentation surface was invalidated or destroyed (e.g. backgrounding).
  surfaceLost,

  /// Application moved to background.
  backgrounded,

  /// Session has been disposed and native resources released.
  disposed,

  /// Platform does not support streaming playback or plugin is missing.
  unsupported;

  /// Parses a platform state string into [VGStreamingPlaybackState].
  static VGStreamingPlaybackState fromString(String? value) {
    if (value == null) return VGStreamingPlaybackState.idle;
    final normalized = value.trim().toLowerCase().replaceAll('_', '');
    return switch (normalized) {
      'idle' => VGStreamingPlaybackState.idle,
      'opening' || 'preparing' => VGStreamingPlaybackState.opening,
      'buffering' => VGStreamingPlaybackState.buffering,
      'playing' => VGStreamingPlaybackState.playing,
      'paused' || 'prepared' => VGStreamingPlaybackState.paused,
      'seeking' => VGStreamingPlaybackState.seeking,
      'ended' || 'completed' => VGStreamingPlaybackState.ended,
      'failed' => VGStreamingPlaybackState.failed,
      'surfacelost' => VGStreamingPlaybackState.surfaceLost,
      'backgrounded' => VGStreamingPlaybackState.backgrounded,
      'disposed' => VGStreamingPlaybackState.disposed,
      'unsupported' => VGStreamingPlaybackState.unsupported,
      _ => VGStreamingPlaybackState.idle,
    };
  }
}

/// Configuration options passed when opening an adaptive streaming playback session.
class VGStreamingPlaybackOptions {
  /// The HTTP/HTTPS URI of the master manifest or media playlist.
  final Uri uri;

  /// Initial presentation width in pixels for the presentation surface.
  /// Must be positive (> 0) as required by native platform coordinator.
  final int initialWidth;

  /// Initial presentation height in pixels for the presentation surface.
  /// Must be positive (> 0) as required by native platform coordinator.
  final int initialHeight;

  /// Optional HTTP request headers (e.g. authorization, custom tokens).
  final Map<String, String>? httpHeaders;

  /// Format hint to bypass auto-detection. Defaults to [VGStreamingFormatHint.auto].
  final VGStreamingFormatHint formatHint;

  /// Network profile guiding buffer depth and track selection heuristics.
  final VGStreamingNetworkProfile networkProfile;

  /// Whether playback starts immediately once initial buffering completes. Defaults to `true`.
  final bool autoPlay;

  /// Initial media position in milliseconds from stream start (VOD) or live edge offset.
  final int? initialPositionMs;

  /// Optional read-through cache configuration connecting to Vanguard cache substrate.
  final VGPlaybackCacheOptions? cacheOptions;

  const VGStreamingPlaybackOptions({
    required this.uri,
    required this.initialWidth,
    required this.initialHeight,
    this.httpHeaders,
    this.formatHint = VGStreamingFormatHint.auto,
    this.networkProfile = VGStreamingNetworkProfile.auto,
    this.autoPlay = true,
    this.initialPositionMs,
    this.cacheOptions,
  }) : assert(initialWidth > 0, 'initialWidth must be > 0'),
       assert(initialHeight > 0, 'initialHeight must be > 0'),
       assert(
         initialPositionMs == null || initialPositionMs >= 0,
         'initialPositionMs must be >= 0',
       );

  /// Converts this configuration to the map argument format expected by native routes.
  Map<String, Object?> toArgs() => <String, Object?>{
    'uri': uri.toString(),
    'initialWidth': initialWidth,
    'initialHeight': initialHeight,
    if (httpHeaders != null) 'httpHeaders': httpHeaders,
    'formatHint': formatHint.toNative(),
    'networkProfile': networkProfile.toNative(),
    'autoPlay': autoPlay,
    if (initialPositionMs != null) 'startPositionMs': initialPositionMs,
    if (cacheOptions != null) ...cacheOptions!.toArgs(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Typed session object
// ─────────────────────────────────────────────────────────────────────────────

/// Active streaming session snapshot and presentation descriptor.
class VGStreamingPlaybackSession {
  /// Whether the operation succeeded.
  final bool pass;

  /// Phase identifier reported by platform backend (e.g. `"Phase4C1D1"`).
  final String phase;

  /// Unique session identifier generated by the platform engine or synthesized as an opaque alias.
  final String sessionId;

  /// Flutter TextureRegistry texture ID for presentation (`Texture(textureId: session.textureId)`).
  final int textureId;

  /// Resolved or hinted streaming format.
  final VGStreamingFormatHint format;

  /// Current session lifecycle state.
  final VGStreamingPlaybackState state;

  /// Total media duration in milliseconds (-1 for live/unbounded streams).
  final int durationMs;

  /// Current playhead position in milliseconds.
  final int positionMs;

  /// Buffered duration in milliseconds ahead of current playhead.
  final int bufferedPositionMs;

  /// Look-ahead buffer fill percentage (0 to 100).
  final int bufferedPercent;

  /// Current distance from live edge in milliseconds (live streams only; `null` for VOD).
  final int? liveOffsetMs;

  /// Current video stream width in pixels.
  final int videoWidth;

  /// Current video stream height in pixels.
  final int videoHeight;

  /// Clockwise rotation in degrees to be applied for correct display orientation (0, 90, 180, 270).
  ///
  /// Official platform reference baselines:
  /// - `MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION`: retrieves video rotation angle in degrees (0, 90, 180, 270).
  /// - `MediaFormat.KEY_ROTATION`: describes clockwise rotation on output surface (0, 90, 180, 270; default 0).
  /// - Media3 `Format.rotationDegrees`: clockwise rotation for correct orientation (0, 90, 180, 270).
  /// - Media3 `VideoSize.unappliedRotationDegrees`: deprecated (player handles rotation internally and returns 0).
  final int rotationDegrees;

  /// Target presentation display width in pixels after applying orientation/rotation transform.
  ///
  /// When positive (> 0), overrides [videoWidth] for presentation layout.
  final int displayWidth;

  /// Target presentation display height in pixels after applying orientation/rotation transform.
  ///
  /// When positive (> 0), overrides [videoHeight] for presentation layout.
  final int displayHeight;

  /// Total rendered frames presented to the texture surface.
  final int renderedFrames;

  /// Total decoded frames processed by decoder.
  final int decodedFrames;

  /// Raw diagnostic status string from platform engine.
  final String raw;

  /// Diagnostic telemetry key-value map.
  final Map<String, Object?> diagnostics;

  const VGStreamingPlaybackSession({
    required this.pass,
    required this.phase,
    required this.sessionId,
    required this.textureId,
    required this.format,
    required this.state,
    this.durationMs = -1,
    this.positionMs = 0,
    this.bufferedPositionMs = 0,
    this.bufferedPercent = 0,
    this.liveOffsetMs,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.rotationDegrees = 0,
    this.displayWidth = 0,
    this.displayHeight = 0,
    this.renderedFrames = 0,
    this.decodedFrames = 0,
    required this.raw,
    required this.diagnostics,
  });

  /// The effective presentation display width in pixels.
  ///
  /// Prefers positive [displayWidth] when present; otherwise derives from
  /// [videoWidth] / [videoHeight] and cardinal [rotationDegrees] (swapping for 90° and 270°).
  /// Returns 0 when source dimensions are not positive.
  int get effectiveDisplayWidth {
    if (displayWidth > 0) return displayWidth;
    if (videoWidth <= 0 || videoHeight <= 0) return 0;
    if (rotationDegrees == 90 || rotationDegrees == 270) {
      return videoHeight;
    }
    return videoWidth;
  }

  /// The effective presentation display height in pixels.
  ///
  /// Prefers positive [displayHeight] when present; otherwise derives from
  /// [videoWidth] / [videoHeight] and cardinal [rotationDegrees] (swapping for 90° and 270°).
  /// Returns 0 when source dimensions are not positive.
  int get effectiveDisplayHeight {
    if (displayHeight > 0) return displayHeight;
    if (videoWidth <= 0 || videoHeight <= 0) return 0;
    if (rotationDegrees == 90 || rotationDegrees == 270) {
      return videoWidth;
    }
    return videoHeight;
  }

  /// Whether the session carries non-zero rotation or explicit display dimensions.
  bool get hasRotationMetadata =>
      rotationDegrees != 0 || (displayWidth > 0 && displayHeight > 0);

  /// Constructs a [VGStreamingPlaybackSession] from a raw platform dictionary.
  factory VGStreamingPlaybackSession.fromMap(
    Map<Object?, Object?> map, {
    VGStreamingFormatHint fallbackFormat = VGStreamingFormatHint.auto,
  }) {
    final stringMap = _defensiveStringMap(map);

    final pass = stringMap['pass'] as bool? ?? false;
    final phase = stringMap['phase'] as String? ?? 'Phase4C1D1';
    final textureId = (stringMap['textureId'] as num?)?.toInt() ?? -1;

    final nativeSessionId = stringMap['sessionId'] as String?;
    final sessionId = (nativeSessionId != null && nativeSessionId.isNotEmpty)
        ? nativeSessionId
        : (textureId >= 0 ? textureId.toString() : '');

    final stateStr = stringMap['state'] as String?;
    final state = VGStreamingPlaybackState.fromString(stateStr);

    final formatStr =
        stringMap['format'] as String? ?? stringMap['formatHint'] as String?;
    final format = VGStreamingFormatHint.fromString(
      formatStr,
      fallback: fallbackFormat,
    );

    final durationMs = (stringMap['durationMs'] as num?)?.toInt() ?? -1;
    final positionMs = (stringMap['positionMs'] as num?)?.toInt() ?? 0;
    final bufferedPositionMs =
        (stringMap['bufferedPositionMs'] as num?)?.toInt() ?? 0;
    final bufferedPercent = _parseBufferedPercent(
      stringMap['bufferedPercent'] ?? stringMap['buffered_percent'],
    );
    final liveOffsetMs = (stringMap['liveOffsetMs'] as num?)?.toInt();
    final videoWidth =
        (stringMap['videoWidth'] as num?)?.toInt() ??
        (stringMap['width'] as num?)?.toInt() ??
        (stringMap['initialWidth'] as num?)?.toInt() ??
        0;
    final videoHeight =
        (stringMap['videoHeight'] as num?)?.toInt() ??
        (stringMap['height'] as num?)?.toInt() ??
        (stringMap['initialHeight'] as num?)?.toInt() ??
        0;
    final rotationDegrees = _parseRotation(
      stringMap['rotationDegrees'] ?? stringMap['rotation'],
    );
    final displayWidth = _parseDimension(
      stringMap['displayWidth'] ?? stringMap['display_width'],
    );
    final displayHeight = _parseDimension(
      stringMap['displayHeight'] ?? stringMap['display_height'],
    );
    final renderedFrames = (stringMap['renderedFrames'] as num?)?.toInt() ?? 0;
    final decodedFrames = (stringMap['decodedFrames'] as num?)?.toInt() ?? 0;
    final raw = stringMap['raw'] as String? ?? '';

    return VGStreamingPlaybackSession(
      pass: pass,
      phase: phase,
      sessionId: sessionId,
      textureId: textureId,
      format: format,
      state: state,
      durationMs: durationMs,
      positionMs: positionMs,
      bufferedPositionMs: bufferedPositionMs,
      bufferedPercent: bufferedPercent,
      liveOffsetMs: liveOffsetMs,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      rotationDegrees: rotationDegrees,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
      renderedFrames: renderedFrames,
      decodedFrames: decodedFrames,
      raw: raw,
      diagnostics: stringMap,
    );
  }

  /// Returned when the native plugin is not available (e.g. non-Android or missing plugin).
  factory VGStreamingPlaybackSession.unsupported() =>
      const VGStreamingPlaybackSession(
        pass: false,
        phase: 'unsupported',
        sessionId: '',
        textureId: -1,
        format: VGStreamingFormatHint.auto,
        state: VGStreamingPlaybackState.unsupported,
        durationMs: -1,
        positionMs: 0,
        bufferedPositionMs: 0,
        bufferedPercent: 0,
        liveOffsetMs: null,
        videoWidth: 0,
        videoHeight: 0,
        rotationDegrees: 0,
        displayWidth: 0,
        displayHeight: 0,
        renderedFrames: 0,
        decodedFrames: 0,
        raw: 'status=UNSUPPORTED;platform=non-android',
        diagnostics: <String, Object?>{
          'pass': false,
          'phase': 'unsupported',
          'state': 'unsupported',
          'raw': 'status=UNSUPPORTED;platform=non-android',
        },
      );

  static int _parseRotation(Object? raw) {
    if (raw == null) return 0;
    int? degrees;
    if (raw is num) {
      degrees = raw.toInt();
    } else if (raw is String) {
      degrees = int.tryParse(raw.trim());
    }
    if (degrees == null) return 0;
    final normalized = ((degrees % 360) + 360) % 360;
    if (normalized == 0 ||
        normalized == 90 ||
        normalized == 180 ||
        normalized == 270) {
      return normalized;
    }
    return 0;
  }

  static int _parseDimension(Object? raw) {
    if (raw == null) return 0;
    int? dim;
    if (raw is num) {
      dim = raw.toInt();
    } else if (raw is String) {
      dim = int.tryParse(raw.trim());
    }
    if (dim == null || dim < 0) return 0;
    return dim;
  }

  static int _parseBufferedPercent(Object? raw) {
    if (raw == null) return 0;
    int? val;
    if (raw is num) {
      val = raw.toInt();
    } else if (raw is String) {
      val = int.tryParse(raw.trim());
    }
    if (val == null) return 0;
    return val.clamp(0, 100);
  }

  static Map<String, Object?> _defensiveStringMap(Map<Object?, Object?> map) {
    final result = <String, Object?>{};
    for (final entry in map.entries) {
      final key = entry.key?.toString();
      if (key != null) {
        result[key] = entry.value;
      }
    }
    return result;
  }

  @override
  String toString() =>
      'VGStreamingPlaybackSession(pass=$pass, phase=$phase, sessionId=$sessionId, '
      'textureId=$textureId, format=$format, state=$state, positionMs=$positionMs, '
      'durationMs=$durationMs, bufferedPercent=$bufferedPercent, '
      'bufferedPositionMs=$bufferedPositionMs, videoWidth=$videoWidth, videoHeight=$videoHeight, '
      'rotationDegrees=$rotationDegrees, displayWidth=$displayWidth, displayHeight=$displayHeight, '
      'renderedFrames=$renderedFrames)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public client
// ─────────────────────────────────────────────────────────────────────────────

/// Public client for Vanguard adaptive streaming playback.
///
/// Encapsulates platform `MethodChannel` interaction, parameter serialization,
/// and error translation.
class VGStreamingPlaybackClient {
  VGStreamingPlaybackClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Opens an adaptive streaming session, prepares the platform pipeline,
  /// and returns an active session descriptor with an allocated presentation [textureId].
  Future<VGStreamingPlaybackSession> open(
    VGStreamingPlaybackOptions options,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'createAndroidDagPhase4C1D1StreamingPlayback',
        options.toArgs(),
      );
      if (raw is! Map) {
        return VGStreamingPlaybackSession.unsupported();
      }
      return VGStreamingPlaybackSession.fromMap(
        raw.cast<Object?, Object?>(),
        fallbackFormat: options.formatHint,
      );
    } on MissingPluginException {
      return VGStreamingPlaybackSession.unsupported();
    }
  }

  /// Requests playback to start/resume for the active session.
  Future<VGStreamingPlaybackSession> play(
    VGStreamingPlaybackSession session,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'playAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object?>{'textureId': session.textureId},
      );
      if (raw is! Map) {
        return VGStreamingPlaybackSession.unsupported();
      }
      return VGStreamingPlaybackSession.fromMap(
        raw.cast<Object?, Object?>(),
        fallbackFormat: session.format,
      );
    } on MissingPluginException {
      return VGStreamingPlaybackSession.unsupported();
    }
  }

  /// Requests playback to pause for the active session, maintaining the last rendered frame.
  Future<VGStreamingPlaybackSession> pause(
    VGStreamingPlaybackSession session,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'pauseAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object?>{'textureId': session.textureId},
      );
      if (raw is! Map) {
        return VGStreamingPlaybackSession.unsupported();
      }
      return VGStreamingPlaybackSession.fromMap(
        raw.cast<Object?, Object?>(),
        fallbackFormat: session.format,
      );
    } on MissingPluginException {
      return VGStreamingPlaybackSession.unsupported();
    }
  }

  /// Requests seeking to a target position in milliseconds.
  Future<VGStreamingPlaybackSession> seek(
    VGStreamingPlaybackSession session,
    int positionMs,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'seekAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object?>{
          'textureId': session.textureId,
          'positionMs': positionMs,
        },
      );
      if (raw is! Map) {
        return VGStreamingPlaybackSession.unsupported();
      }
      return VGStreamingPlaybackSession.fromMap(
        raw.cast<Object?, Object?>(),
        fallbackFormat: session.format,
      );
    } on MissingPluginException {
      return VGStreamingPlaybackSession.unsupported();
    }
  }

  /// Requests stopping playback and resetting player state to idle.
  Future<VGStreamingPlaybackSession> stop(
    VGStreamingPlaybackSession session,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'stopAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object?>{'textureId': session.textureId},
      );
      if (raw is! Map) {
        return VGStreamingPlaybackSession.unsupported();
      }
      return VGStreamingPlaybackSession.fromMap(
        raw.cast<Object?, Object?>(),
        fallbackFormat: session.format,
      );
    } on MissingPluginException {
      return VGStreamingPlaybackSession.unsupported();
    }
  }

  /// Retrieves the latest playback state, playhead position, buffer levels, and telemetry.
  Future<VGStreamingPlaybackSession> getStatus(
    VGStreamingPlaybackSession session,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'diagnoseAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object?>{'textureId': session.textureId},
      );
      if (raw is! Map) {
        return VGStreamingPlaybackSession.unsupported();
      }
      return VGStreamingPlaybackSession.fromMap(
        raw.cast<Object?, Object?>(),
        fallbackFormat: session.format,
      );
    } on MissingPluginException {
      return VGStreamingPlaybackSession.unsupported();
    }
  }

  /// Idempotently releases platform decoder, surface, and native playback resources.
  Future<void> dispose(VGStreamingPlaybackSession session) async {
    try {
      await _channel.invokeMethod<Object?>(
        'disposeAndroidDagPhase4C1D1StreamingPlayback',
        <String, Object?>{'textureId': session.textureId},
      );
    } on MissingPluginException {
      // Silently complete on unsupported/missing plugin platforms.
    }
  }
}
