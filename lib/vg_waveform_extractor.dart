// vg_waveform_extractor.dart
// vanguard_media_engine — Phase 8.15C / Phase 8.18
//
// Dart bridge for native iOS offline audio waveform extraction.
//
// Scope:
//   - VGAudioWaveformResult: typed result (Float32List samples + metadata).
//   - VGAudioWaveformExtractor: static API that calls the native extractWaveform endpoint.
//
// Phase 8.18 addition:
//   - Optional [cacheKey] parameter on extract().
//   - On cache hit: returns the cached result without touching native extraction.
//   - On cache miss: runs native extraction, then saves to cache.
//   - Cache errors (load or save) are swallowed; extraction result is always returned.
//
// Non-goals:
//   - No real-time audio graph.
//   - No playback service.
//   - No Android implementation.
//   - No peak extraction (RMS only).

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'vg_waveform_cache.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Result type
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable waveform result returned from [VGAudioWaveformExtractor.extract].
///
/// [samples] contains [pointCount] Float32 RMS values normalised to [0.0, 1.0].
/// Each sample represents one RMS window of [1/samplesPerSecond] seconds.
final class VGAudioWaveformResult {
  /// RMS Float32 values, each in [0.0, 1.0]. Length == [pointCount].
  final Float32List samples;

  /// Total audio duration of the source file in seconds.
  final double durationSeconds;

  /// The requested number of RMS samples per timeline second.
  final int samplesPerSecond;

  /// Number of Float32 values in [samples].
  final int pointCount;

  const VGAudioWaveformResult({
    required this.samples,
    required this.durationSeconds,
    required this.samplesPerSecond,
    required this.pointCount,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VGAudioWaveformResult) return false;
    if (samples.length != other.samples.length) return false;
    for (var i = 0; i < samples.length; i++) {
      if (samples[i] != other.samples[i]) return false;
    }
    return durationSeconds == other.durationSeconds &&
        samplesPerSecond == other.samplesPerSecond &&
        pointCount == other.pointCount;
  }

  @override
  int get hashCode => Object.hash(
        samples.length,
        durationSeconds,
        samplesPerSecond,
        pointCount,
      );

  @override
  String toString() =>
      'VGAudioWaveformResult(pointCount: $pointCount, '
      'durationSeconds: ${durationSeconds.toStringAsFixed(2)}, '
      'samplesPerSecond: $samplesPerSecond)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Extractor
// ─────────────────────────────────────────────────────────────────────────────

/// Offline audio waveform extractor backed by native iOS AVAssetReader.
///
/// iOS only. Calls the native `extractWaveform` MethodChannel endpoint.
/// Returns RMS Float32 samples normalised to [0.0, 1.0].
///
/// Errors:
///   - [ArgumentError] for invalid Dart-side arguments (path empty,
///     samplesPerSecond out of range, maxDurationSeconds ≤ 0).
///   - [PlatformException] for native failures (no audio track, reader error,
///     duration exceeded, etc.). Check [PlatformException.code] for specifics:
///       'NO_AUDIO_TRACK'      — no audio track in file
///       'ZERO_DURATION'       — asset has zero or invalid duration
///       'DURATION_EXCEEDED'   — audio duration exceeds maxDurationSeconds
///       'READER_SETUP_FAILED' — failed to create/start AVAssetReader
///       'READER_FAILED'       — reader failed during extraction
///       'WAVEFORM_CANCELLED'  — extraction was cancelled
///       'INVALID_ARG'         — native parameter validation failure
abstract final class VGAudioWaveformExtractor {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  /// Extracts an RMS waveform from a local audio or video file.
  ///
  /// [path] must be a non-empty absolute path to a readable file.
  /// [samplesPerSecond] must be in [1, 1000]. Default 100.
  /// [maxDurationSeconds] must be > 0. Default 600.0 (10 minutes).
  /// [cacheKey] is optional. If non-null and non-empty:
  ///   - A cached result is returned immediately on cache hit.
  ///   - On a miss, native extraction is run and the result is saved.
  ///   - Cache load/save errors are swallowed and never surface to the caller.
  ///
  /// Returns a [VGAudioWaveformResult] containing Float32 RMS samples.
  /// Throws [ArgumentError] for invalid parameters.
  /// Throws [PlatformException] for native errors.
  static Future<VGAudioWaveformResult> extract({
    required String path,
    int samplesPerSecond = 100,
    double maxDurationSeconds = 600.0,
    String? cacheKey,
  }) async {
    if (path.isEmpty) {
      throw ArgumentError.value(path, 'path', 'must be non-empty');
    }
    if (samplesPerSecond <= 0 || samplesPerSecond > 1000) {
      throw ArgumentError.value(
        samplesPerSecond,
        'samplesPerSecond',
        'must be in range [1, 1000]',
      );
    }
    if (maxDurationSeconds <= 0.0) {
      throw ArgumentError.value(
        maxDurationSeconds,
        'maxDurationSeconds',
        'must be > 0',
      );
    }

    // ── Phase 8.18: Cache-first lookup ───────────────────────────────────────
    final effectiveKey =
        (cacheKey != null && cacheKey.isNotEmpty) ? cacheKey : null;

    if (effectiveKey != null) {
      try {
        final cached = await VGAudioWaveformCache.load(cacheKey: effectiveKey);
        if (cached != null) return cached;
      } catch (_) {
        // Cache load error is non-fatal — fall through to native extraction.
      }
    }

    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'extractWaveform',
      {
        'path': path,
        'samplesPerSecond': samplesPerSecond,
        'maxDurationSeconds': maxDurationSeconds,
      },
    );

    final samplesTypedData = raw?['samples'];
    final Float32List samples;
    if (samplesTypedData is Float32List) {
      samples = samplesTypedData;
    } else if (samplesTypedData is Uint8List) {
      // FlutterStandardTypedData may arrive as raw bytes — reinterpret.
      // Use explicit offset+length to avoid reading past the logical data
      // when the ByteBuffer has VM-level padding beyond the Uint8List length.
      final byteCount = samplesTypedData.length;
      final floatCount = byteCount ~/ 4;
      if (floatCount > 0) {
        samples = samplesTypedData.buffer.asFloat32List(
          samplesTypedData.offsetInBytes,
          floatCount,
        );
      } else {
        samples = Float32List(0);
      }
    } else {
      samples = Float32List(0);
    }

    final result = VGAudioWaveformResult(
      samples: samples,
      durationSeconds: (raw?['durationSeconds'] as num?)?.toDouble() ?? 0.0,
      samplesPerSecond: (raw?['samplesPerSecond'] as num?)?.toInt() ??
          samplesPerSecond,
      pointCount: (raw?['pointCount'] as num?)?.toInt() ?? samples.length,
    );

    // ── Phase 8.18: Post-extraction cache save ────────────────────────────────
    if (effectiveKey != null) {
      try {
        await VGAudioWaveformCache.save(cacheKey: effectiveKey, result: result);
      } catch (_) {
        // Cache save error is non-fatal — return the extracted result.
      }
    }

    return result;
  }
}
