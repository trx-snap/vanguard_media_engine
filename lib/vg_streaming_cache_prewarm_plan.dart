// Copyright (c) Connects — Vanguard Phase 4C6K.
// Public streaming cache prewarm request planner.
//
// Pure Dart request planning types: bridges VGStreamingSourceDescriptor and
// VGStreamingSourceSet into explicit, bounded cache prewarm requests without
// platform coupling, network execution, or side effects.

import 'vg_streaming_cache_client.dart';
import 'vg_streaming_source_descriptor.dart';

export 'vg_streaming_cache_client.dart'
    show VGPlaybackCacheOptions, VGPlaybackPrewarmStartResult;
export 'vg_streaming_source_descriptor.dart'
    show VGStreamingSourceDescriptor, VGStreamingSourceSet;

/// Low-latency prewarm handling policy for live or low-latency streams.
enum VGStreamingCachePrewarmLowLatencyPolicy {
  /// Skips prewarming for streams requiring LL-HLS tags.
  skipLowLatency,

  /// Allows prewarming bounded manifest data only for low-latency streams.
  allowBoundedManifestOnly,
}

/// Immutable descriptor for an explicit streaming cache prewarm request.
class VGPlaybackPrewarmRequest {
  /// Unique request identifier.
  final String requestId;

  /// HTTP/HTTPS URI of the streaming resource or manifest to prewarm.
  final Uri uri;

  /// Optional HTTP headers for the prewarm request.
  final Map<String, String>? httpHeaders;

  /// Maximum bytes to prewarm into the playback cache.
  final int maxBytes;

  /// Cache substrate configuration options.
  final VGPlaybackCacheOptions options;

  VGPlaybackPrewarmRequest({
    required this.requestId,
    required this.uri,
    this.httpHeaders,
    this.maxBytes = 2 * 1024 * 1024,
    this.options = const VGPlaybackCacheOptions(),
  }) : assert(requestId.isNotEmpty, 'requestId must not be empty'),
       assert(maxBytes > 0, 'maxBytes must be > 0');

  /// Converts this request into arguments matching [VGStreamingCacheClient.prewarm].
  Map<String, Object?> toArgs() => <String, Object?>{
    'requestId': requestId,
    'uri': uri.toString(),
    if (httpHeaders != null) 'httpHeaders': httpHeaders,
    'maxBytes': maxBytes,
    ...options.toArgs(),
  };

  @override
  String toString() =>
      'VGPlaybackPrewarmRequest(requestId=$requestId, uri=$uri, '
      'maxBytes=$maxBytes, options=$options)';
}

/// Immutable plan containing evaluated prewarm requests and diagnostic feedback.
class VGStreamingCachePrewarmPlan {
  /// Ordered list of validated prewarm requests ready to be dispatched.
  final List<VGPlaybackPrewarmRequest> requests;

  /// Source keys that were skipped during plan evaluation.
  final List<String> skippedKeys;

  /// Advisory warnings generated during plan evaluation.
  final List<String> warnings;

  /// Diagnostic metadata for telemetry and auditing.
  final Map<String, Object?> diagnostics;

  const VGStreamingCachePrewarmPlan({
    required this.requests,
    this.skippedKeys = const [],
    this.warnings = const [],
    this.diagnostics = const {},
  });

  /// Whether the plan contains at least one actionable prewarm request.
  bool get hasRequests => requests.isNotEmpty;

  @override
  String toString() =>
      'VGStreamingCachePrewarmPlan(requests=${requests.length}, '
      'skippedKeys=$skippedKeys, warnings=$warnings)';
}

/// Pure Dart planning utility for converting source descriptors into cache prewarm requests.
abstract final class VGStreamingCachePrewarmPlanner {
  /// Constructs a single [VGPlaybackPrewarmRequest] from a [VGStreamingSourceDescriptor].
  ///
  /// Preserves source URI and headers. Caller-supplied [options] override
  /// [source.cacheOptions]; if neither is provided, defaults to standard [VGPlaybackCacheOptions].
  static VGPlaybackPrewarmRequest requestForSource({
    required String requestId,
    required VGStreamingSourceDescriptor source,
    int maxBytes = 2 * 1024 * 1024,
    VGPlaybackCacheOptions? options,
  }) {
    return VGPlaybackPrewarmRequest(
      requestId: requestId,
      uri: source.uri,
      httpHeaders: source.httpHeaders,
      maxBytes: maxBytes,
      options: options ?? source.cacheOptions ?? const VGPlaybackCacheOptions(),
    );
  }

  /// Synthesizes a [VGStreamingCachePrewarmPlan] from a [VGStreamingSourceSet].
  ///
  /// - Evaluates [sourceKeys] in supplied order if non-empty; otherwise evaluates all [sourceSet.sources] in order.
  /// - Unknown keys in [sourceKeys] generate an `unknown_source_key:<key>` warning.
  /// - If [options.cacheEnabled] is `false`, returns no requests, marks all considered sources as skipped, and warns `cache_disabled`.
  /// - If [source.requireLlHlsTags] is `true` and [lowLatencyPolicy] is [VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency],
  ///   skips the source with warning `low_latency_cache_constrained:<key>`.
  /// - Assigns deterministic request IDs formatted as `${requestIdPrefix}_${source.key}_${index}` based on 0-indexed considered order.
  static VGStreamingCachePrewarmPlan planForSourceSet({
    required VGStreamingSourceSet sourceSet,
    required String requestIdPrefix,
    List<String> sourceKeys = const [],
    int maxBytes = 2 * 1024 * 1024,
    VGPlaybackCacheOptions options = const VGPlaybackCacheOptions(),
    VGStreamingCachePrewarmLowLatencyPolicy lowLatencyPolicy =
        VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
  }) {
    final requests = <VGPlaybackPrewarmRequest>[];
    final skippedKeys = <String>[];
    final warnings = <String>[];

    // Rule 5: Cache disabled check
    if (!options.cacheEnabled) {
      warnings.add('cache_disabled');
      if (sourceKeys.isNotEmpty) {
        for (final key in sourceKeys) {
          final source = sourceSet.trySourceForKey(key);
          if (source != null) {
            skippedKeys.add(source.key);
          } else {
            warnings.add('unknown_source_key:$key');
          }
        }
      } else {
        for (final source in sourceSet.sources) {
          skippedKeys.add(source.key);
        }
      }
      return VGStreamingCachePrewarmPlan(
        requests: const [],
        skippedKeys: List<String>.unmodifiable(skippedKeys),
        warnings: List<String>.unmodifiable(warnings),
        diagnostics: {
          'requestCount': 0,
          'skippedCount': skippedKeys.length,
          'lowLatencyPolicy': lowLatencyPolicy.name,
          'cacheEnabled': false,
          'maxBytes': maxBytes,
        },
      );
    }

    final candidateSources = <VGStreamingSourceDescriptor>[];
    if (sourceKeys.isNotEmpty) {
      for (final key in sourceKeys) {
        final source = sourceSet.trySourceForKey(key);
        if (source != null) {
          candidateSources.add(source);
        } else {
          warnings.add('unknown_source_key:$key');
        }
      }
    } else {
      candidateSources.addAll(sourceSet.sources);
    }

    final overrideOptions = identical(options, const VGPlaybackCacheOptions())
        ? null
        : options;

    for (var i = 0; i < candidateSources.length; i++) {
      final source = candidateSources[i];
      if (source.requireLlHlsTags &&
          lowLatencyPolicy ==
              VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency) {
        skippedKeys.add(source.key);
        warnings.add('low_latency_cache_constrained:${source.key}');
        continue;
      }

      final requestId = '${requestIdPrefix}_${source.key}_$i';
      requests.add(
        requestForSource(
          requestId: requestId,
          source: source,
          maxBytes: maxBytes,
          options: overrideOptions,
        ),
      );
    }

    return VGStreamingCachePrewarmPlan(
      requests: List<VGPlaybackPrewarmRequest>.unmodifiable(requests),
      skippedKeys: List<String>.unmodifiable(skippedKeys),
      warnings: List<String>.unmodifiable(warnings),
      diagnostics: {
        'requestCount': requests.length,
        'skippedCount': skippedKeys.length,
        'lowLatencyPolicy': lowLatencyPolicy.name,
        'cacheEnabled': options.cacheEnabled,
        'maxBytes': maxBytes,
      },
    );
  }
}

/// Convenience extension bridging [VGPlaybackPrewarmRequest] into [VGStreamingCacheClient].
extension VGStreamingCacheClientPrewarmRequest on VGStreamingCacheClient {
  /// Starts a bounded background prewarm job for [request].
  Future<VGPlaybackPrewarmStartResult> prewarmRequest(
    VGPlaybackPrewarmRequest request,
  ) {
    return prewarm(
      requestId: request.requestId,
      uri: request.uri,
      httpHeaders: request.httpHeaders,
      maxBytes: request.maxBytes,
      options: request.options,
    );
  }
}
