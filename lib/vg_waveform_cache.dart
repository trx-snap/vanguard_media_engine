// vg_waveform_cache.dart
// vanguard_media_engine — Phase 8.17
//
// Dart bridge for the native iOS disk-backed waveform result cache.
//
// Scope:
//   - VGAudioWaveformCache: static API for saving and loading VGAudioWaveformResult.
//   - Reuses VGAudioWaveformResult from vg_waveform_extractor.dart.
//
// Non-goals (Phase 8.17):
//   - No automatic cache-on-extract wiring.
//   - No in-memory LRU.
//   - No eviction / TTL.
//   - No Android implementation.
//   - No real-time audio graph.

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'vg_waveform_extractor.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VGAudioWaveformCache
// ─────────────────────────────────────────────────────────────────────────────

/// Disk-backed cache for [VGAudioWaveformResult] produced by
/// [VGAudioWaveformExtractor].
///
/// iOS only. Routes through `waveformCache_*` MethodChannel methods.
///
/// Cache keying is opaque — any non-empty string is valid (e.g. a track URL,
/// a content hash, or a timeline ID). The native side hashes the key before
/// writing to disk to prevent path traversal.
///
/// Errors:
///   - [ArgumentError] for invalid Dart-side arguments.
///   - [PlatformException] for native failures. Check [PlatformException.code]:
///       'CACHE_SAVE_FAILED' — native I/O error during save
///       'INVALID_ARG'       — native argument validation failure
abstract final class VGAudioWaveformCache {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  /// Saves [result] to the on-device cache under [cacheKey].
  ///
  /// [cacheKey] must be a non-empty string.
  /// [result.samples] must be non-empty.
  /// [result.durationSeconds] must be > 0.
  /// [result.samplesPerSecond] must be > 0.
  /// [result.pointCount] must equal [result.samples.length].
  ///
  /// Throws [ArgumentError] on invalid arguments (no channel call made).
  /// Throws [PlatformException] on native I/O failure.
  static Future<void> save({
    required String cacheKey,
    required VGAudioWaveformResult result,
  }) async {
    if (cacheKey.isEmpty) {
      throw ArgumentError.value(cacheKey, 'cacheKey', 'must be non-empty');
    }
    if (result.samples.isEmpty) {
      throw ArgumentError.value(
        result.samples.length,
        'result.samples',
        'must be non-empty',
      );
    }
    if (!result.durationSeconds.isFinite || result.durationSeconds <= 0.0) {
      throw ArgumentError.value(
        result.durationSeconds,
        'result.durationSeconds',
        'must be finite and > 0',
      );
    }
    if (result.samplesPerSecond <= 0) {
      throw ArgumentError.value(
        result.samplesPerSecond,
        'result.samplesPerSecond',
        'must be > 0',
      );
    }
    if (result.pointCount != result.samples.length) {
      throw ArgumentError(
        'result.pointCount (${result.pointCount}) '
        'must equal result.samples.length (${result.samples.length})',
      );
    }

    // Convert Float32List to raw bytes for the channel.
    // FlutterStandardTypedData can carry Uint8List bytes — reinterpret.
    final Uint8List sampleBytes = result.samples.buffer.asUint8List(
      result.samples.offsetInBytes,
      result.samples.lengthInBytes,
    );

    await _channel.invokeMethod<void>(
      'waveformCache_save',
      {
        'cacheKey':        cacheKey,
        'samples':         sampleBytes,
        'durationSeconds': result.durationSeconds,
        'samplesPerSecond': result.samplesPerSecond,
        'pointCount':      result.pointCount,
      },
    );
  }

  /// Loads a previously cached [VGAudioWaveformResult] for [cacheKey].
  ///
  /// Returns null on a cache miss (the file does not exist, is corrupt,
  /// or has a mismatched schema version).
  ///
  /// [cacheKey] must be non-empty.
  ///
  /// Throws [ArgumentError] on invalid arguments.
  /// Throws [PlatformException] on unexpected native failure.
  static Future<VGAudioWaveformResult?> load({
    required String cacheKey,
  }) async {
    if (cacheKey.isEmpty) {
      throw ArgumentError.value(cacheKey, 'cacheKey', 'must be non-empty');
    }

    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'waveformCache_load',
      {'cacheKey': cacheKey},
    );

    // Null means cache miss.
    if (raw == null) return null;

    // Decode samples — native returns FlutterStandardTypedData (Uint8List bytes).
    final samplesRaw = raw['samples'];
    final Float32List samples;
    if (samplesRaw is Float32List) {
      samples = samplesRaw;
    } else if (samplesRaw is Uint8List) {
      final byteCount  = samplesRaw.length;
      final floatCount = byteCount ~/ 4;
      if (floatCount > 0) {
        // Copy to a fresh, guaranteed-aligned ByteData before reinterpreting.
        // A raw Uint8List from the MethodChannel mock may have a non-zero
        // offsetInBytes that is not 4-byte aligned, which causes a RangeError
        // on asFloat32List(offsetInBytes, count) on the VM target.
        final aligned = ByteData(floatCount * 4);
        for (var i = 0; i < floatCount * 4; i++) {
          aligned.setUint8(i, samplesRaw[i]);
        }
        samples = aligned.buffer.asFloat32List();
      } else {
        samples = Float32List(0);
      }
    } else {
      samples = Float32List(0);
    }

    return VGAudioWaveformResult(
      samples:          samples,
      durationSeconds:  (raw['durationSeconds'] as num?)?.toDouble() ?? 0.0,
      samplesPerSecond: (raw['samplesPerSecond'] as num?)?.toInt() ?? 0,
      pointCount:       (raw['pointCount'] as num?)?.toInt() ?? samples.length,
    );
  }
}
