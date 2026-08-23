// Copyright (c) Connects — Vanguard Phase 4C7I.
// Public streaming source descriptor and source set.
//
// Pure Dart descriptor: unifies streaming manifest preflight specification
// and playback options derivation from a single stream definition without
// platform coupling or side effects.

import 'vg_streaming_preflight_client.dart';
import 'vg_streaming_startup_plan.dart';

export 'vg_streaming_cache_client.dart' show VGPlaybackCacheOptions;
export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_preflight_client.dart'
    show VGStreamingManifestSpec, VGStreamingPreflightRequest;
export 'vg_streaming_startup_plan.dart' show VGStreamingStartupPlan;

/// Unifies stream identity, location, format hints, presentation geometry,
/// HTTP headers, preflight requirements, and playback/cache configurations
/// into a single source definition.
class VGStreamingSourceDescriptor {
  /// Unique caller-defined identifier for this streaming source (e.g. `"primary_stream"`).
  final String key;

  /// HTTP/HTTPS URI of the multivariant master manifest or media playlist.
  final Uri uri;

  /// Initial presentation surface width in pixels (must be > 0).
  final int initialWidth;

  /// Initial presentation surface height in pixels (must be > 0).
  final int initialHeight;

  /// Format hint to bypass auto-detection (defaults to [VGStreamingFormatHint.auto]).
  final VGStreamingFormatHint formatHint;

  /// Optional HTTP request headers (e.g. authorization, custom tokens).
  final Map<String, String>? httpHeaders;

  /// Whether the stream requires an adaptive multi-bitrate ladder (defaults to `true`).
  final bool requireAdaptiveLadder;

  /// Whether modern codec renditions (HEVC/AV1) must include an AVC/H.264 fallback (defaults to `true`).
  final bool requireAvcFallback;

  /// Whether low-latency tags (LL-HLS partial segments/preload hints) are strictly required (defaults to `false`).
  final bool requireLlHlsTags;

  /// Whether single-rendition media playlists are allowed as valid ladders (defaults to `false`).
  final bool allowMediaPlaylist;

  /// Optional read-through cache configuration connecting to Vanguard cache substrate.
  final VGPlaybackCacheOptions? cacheOptions;

  /// Whether playback starts immediately once initial buffering completes (defaults to `true`).
  final bool autoPlay;

  /// Initial media position in milliseconds from stream start (VOD) or live edge offset.
  final int? initialPositionMs;

  VGStreamingSourceDescriptor({
    required this.key,
    required this.uri,
    required this.initialWidth,
    required this.initialHeight,
    this.formatHint = VGStreamingFormatHint.auto,
    this.httpHeaders,
    this.requireAdaptiveLadder = true,
    this.requireAvcFallback = true,
    this.requireLlHlsTags = false,
    this.allowMediaPlaylist = false,
    this.cacheOptions,
    this.autoPlay = true,
    this.initialPositionMs,
  }) : assert(key.isNotEmpty, 'key must not be empty'),
       assert(initialWidth > 0, 'initialWidth must be > 0'),
       assert(initialHeight > 0, 'initialHeight must be > 0'),
       assert(
         initialPositionMs == null || initialPositionMs >= 0,
         'initialPositionMs must be >= 0',
       );

  /// Converts this descriptor to a [VGStreamingManifestSpec] evaluated during preflight.
  VGStreamingManifestSpec toManifestSpec() => VGStreamingManifestSpec(
    key: key,
    uri: uri,
    formatHint: formatHint,
    requireAdaptiveLadder: requireAdaptiveLadder,
    requireAvcFallback: requireAvcFallback,
    requireLlHlsTags: requireLlHlsTags,
    allowMediaPlaylist: allowMediaPlaylist,
    httpHeaders: httpHeaders,
  );

  /// Builds a [VGStreamingPlaybackOptions] descriptor guided by the provided [plan].
  ///
  /// Delegates directly to [plan.buildPlaybackOptions] with descriptor attributes,
  /// inheriting the recommended network profile and respecting preflight gating.
  VGStreamingPlaybackOptions toPlaybackOptions(VGStreamingStartupPlan plan) {
    return plan.buildPlaybackOptions(
      uri: uri,
      initialWidth: initialWidth,
      initialHeight: initialHeight,
      httpHeaders: httpHeaders,
      formatHint: formatHint,
      autoPlay: autoPlay,
      initialPositionMs: initialPositionMs,
      cacheOptions: cacheOptions,
    );
  }

  /// Creates a copy of this descriptor with optional parameter overrides.
  VGStreamingSourceDescriptor copyWith({
    String? key,
    Uri? uri,
    int? initialWidth,
    int? initialHeight,
    VGStreamingFormatHint? formatHint,
    Map<String, String>? httpHeaders,
    bool? requireAdaptiveLadder,
    bool? requireAvcFallback,
    bool? requireLlHlsTags,
    bool? allowMediaPlaylist,
    VGPlaybackCacheOptions? cacheOptions,
    bool? autoPlay,
    int? initialPositionMs,
  }) {
    return VGStreamingSourceDescriptor(
      key: key ?? this.key,
      uri: uri ?? this.uri,
      initialWidth: initialWidth ?? this.initialWidth,
      initialHeight: initialHeight ?? this.initialHeight,
      formatHint: formatHint ?? this.formatHint,
      httpHeaders: httpHeaders ?? this.httpHeaders,
      requireAdaptiveLadder:
          requireAdaptiveLadder ?? this.requireAdaptiveLadder,
      requireAvcFallback: requireAvcFallback ?? this.requireAvcFallback,
      requireLlHlsTags: requireLlHlsTags ?? this.requireLlHlsTags,
      allowMediaPlaylist: allowMediaPlaylist ?? this.allowMediaPlaylist,
      cacheOptions: cacheOptions ?? this.cacheOptions,
      autoPlay: autoPlay ?? this.autoPlay,
      initialPositionMs: initialPositionMs ?? this.initialPositionMs,
    );
  }

  @override
  String toString() =>
      'VGStreamingSourceDescriptor(key=$key, uri=$uri, initialWidth=$initialWidth, '
      'initialHeight=$initialHeight, formatHint=$formatHint, autoPlay=$autoPlay, '
      'initialPositionMs=$initialPositionMs)';
}

/// Collection of [VGStreamingSourceDescriptor] instances representing candidate stream sources.
class VGStreamingSourceSet {
  /// Ordered list of candidate stream source descriptors.
  final List<VGStreamingSourceDescriptor> sources;

  VGStreamingSourceSet({required this.sources})
    : assert(sources.isNotEmpty, 'sources must not be empty'),
      assert(
        sources.map((s) => s.key).toSet().length == sources.length,
        'sources must have unique keys',
      );

  /// Synthesizes a [VGStreamingPreflightRequest] evaluating all sources in this set.
  VGStreamingPreflightRequest toPreflightRequest({
    VGStreamingNetworkProfile requestedNetworkProfile =
        VGStreamingNetworkProfile.auto,
    bool preferLowLatency = false,
    bool allowLowLatencyOnConstrained = false,
  }) {
    return VGStreamingPreflightRequest(
      manifests: sources.map((s) => s.toManifestSpec()).toList(),
      requestedNetworkProfile: requestedNetworkProfile,
      preferLowLatency: preferLowLatency,
      allowLowLatencyOnConstrained: allowLowLatencyOnConstrained,
    );
  }

  /// Returns the [VGStreamingSourceDescriptor] associated with [key], or `null` if not found.
  VGStreamingSourceDescriptor? trySourceForKey(String key) {
    for (final source in sources) {
      if (source.key == key) return source;
    }
    return null;
  }

  /// Returns the [VGStreamingSourceDescriptor] associated with [key].
  ///
  /// Throws an [ArgumentError] if no source with [key] exists in this set.
  VGStreamingSourceDescriptor sourceForKey(String key) {
    final source = trySourceForKey(key);
    if (source == null) {
      throw ArgumentError.value(
        key,
        'key',
        'No source found for key "$key" in source set.',
      );
    }
    return source;
  }

  @override
  String toString() => 'VGStreamingSourceSet(sources=$sources)';
}
