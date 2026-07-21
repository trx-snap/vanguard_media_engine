// vg_waveform_cache.dart
// vanguard_media_engine — Phase 8.17 / Slice Q
//
// Dart bridge for the native iOS disk-backed waveform result cache.

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'vg_waveform_extractor.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Address & Namespaced API types
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable address keying a namespaced waveform cache entry.
final class VGAudioWaveformCacheAddress {
  final String namespace;
  final String assetKey;

  const VGAudioWaveformCacheAddress(this.namespace, this.assetKey);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAudioWaveformCacheAddress &&
        other.namespace == namespace &&
        other.assetKey == assetKey;
  }

  @override
  int get hashCode => Object.hash(namespace, assetKey);

  @override
  String toString() => 'VGAudioWaveformCacheAddress($namespace, $assetKey)';
}

/// Opaque write token returned on a namespaced cache miss.
final class VGAudioWaveformWriteLease {
  final String _token;
  final int samplesPerSecond;

  const VGAudioWaveformWriteLease._(this._token, this.samplesPerSecond);
}

/// Result of [VGAudioWaveformCache.lookupNamespaced].
sealed class VGAudioWaveformLookupResult {}

/// Cache hit: a previously saved waveform is available.
final class VGAudioWaveformLookupHit extends VGAudioWaveformLookupResult {
  final VGAudioWaveformResult cached;
  VGAudioWaveformLookupHit(this.cached);
}

/// Cache miss: extraction should proceed and the result saved via [lease].
final class VGAudioWaveformLookupMiss extends VGAudioWaveformLookupResult {
  final VGAudioWaveformWriteLease lease;
  VGAudioWaveformLookupMiss(this.lease);
}

/// Outcome of [VGAudioWaveformCache.saveNamespaced].
enum VGAudioWaveformSaveOutcome { saved, stale }

// ─────────────────────────────────────────────────────────────────────────────
// VGAudioWaveformCache
// ─────────────────────────────────────────────────────────────────────────────

abstract final class VGAudioWaveformCache {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  // ── Legacy flat-storage API (unchanged) ──────────────────────────────────

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

    final Uint8List sampleBytes = result.samples.buffer.asUint8List(
      result.samples.offsetInBytes,
      result.samples.lengthInBytes,
    );

    await _channel.invokeMethod<void>('waveformCache_save', {
      'cacheKey': cacheKey,
      'samples': sampleBytes,
      'durationSeconds': result.durationSeconds,
      'samplesPerSecond': result.samplesPerSecond,
      'pointCount': result.pointCount,
    });
  }

  static Future<VGAudioWaveformResult?> load({required String cacheKey}) async {
    if (cacheKey.isEmpty) {
      throw ArgumentError.value(cacheKey, 'cacheKey', 'must be non-empty');
    }

    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'waveformCache_load',
      {'cacheKey': cacheKey},
    );

    if (raw == null) return null;

    return _decodeWaveformResult(raw);
  }

  // ── Namespaced API (Slice Q) ──────────────────────────────────────────────

  static Future<VGAudioWaveformLookupResult> lookupNamespaced({
    VGAudioWaveformCacheAddress? address,
    String? namespace,
    String? assetKey,
    required int samplesPerSecond,
  }) async {
    final ns = address?.namespace ?? namespace ?? '';
    final ak = address?.assetKey ?? assetKey ?? '';

    if (ns.isEmpty) {
      throw ArgumentError.value(ns, 'namespace', 'must be non-empty');
    }
    if (ak.isEmpty) {
      throw ArgumentError.value(ak, 'assetKey', 'must be non-empty');
    }
    if (samplesPerSecond <= 0 || samplesPerSecond > 1000) {
      throw ArgumentError.value(
        samplesPerSecond,
        'samplesPerSecond',
        'must be in range [1, 1000]',
      );
    }

    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'waveformCache_lookupNamespaced',
      {'namespace': ns, 'assetKey': ak, 'samplesPerSecond': samplesPerSecond},
    );

    if (raw == null) {
      throw PlatformException(
        code: 'CACHE_LOAD_FAILED',
        message: 'Unexpected null result map',
      );
    }

    final status = raw['status'] as String?;
    if (status == 'hit') {
      final resultMap = raw['result'] as Map<dynamic, dynamic>?;
      if (resultMap == null) {
        throw PlatformException(
          code: 'CACHE_LOAD_FAILED',
          message: 'status=hit but result is absent',
        );
      }
      final waveform = _decodeWaveformResult(resultMap.cast<String, dynamic>());
      if (waveform == null) {
        throw PlatformException(
          code: 'CACHE_LOAD_FAILED',
          message: 'failed to decode cached waveform',
        );
      }
      return VGAudioWaveformLookupHit(waveform);
    } else if (status == 'miss') {
      final token = raw['writeLease'] as String?;
      if (token == null || token.isEmpty) {
        throw PlatformException(
          code: 'CACHE_LOAD_FAILED',
          message: 'status=miss returned no writeLease',
        );
      }
      return VGAudioWaveformLookupMiss(
        VGAudioWaveformWriteLease._(token, samplesPerSecond),
      );
    } else {
      throw PlatformException(
        code: 'CACHE_LOAD_FAILED',
        message: 'Unknown or malformed lookup status: $status',
      );
    }
  }

  static Future<VGAudioWaveformSaveOutcome> saveNamespaced({
    required VGAudioWaveformWriteLease lease,
    required VGAudioWaveformResult result,
  }) async {
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
    if (result.samplesPerSecond <= 0 || result.samplesPerSecond > 1000) {
      throw ArgumentError.value(
        result.samplesPerSecond,
        'result.samplesPerSecond',
        'must be in range [1, 1000]',
      );
    }
    if (result.pointCount != result.samples.length) {
      throw ArgumentError(
        'result.pointCount (${result.pointCount}) must equal '
        'result.samples.length (${result.samples.length})',
      );
    }

    final Uint8List sampleBytes = result.samples.buffer.asUint8List(
      result.samples.offsetInBytes,
      result.samples.lengthInBytes,
    );

    final raw = await _channel
        .invokeMapMethod<String, dynamic>('waveformCache_saveNamespaced', {
          'token': lease._token,
          'samples': sampleBytes,
          'durationSeconds': result.durationSeconds,
          'samplesPerSecond': result.samplesPerSecond,
          'pointCount': result.pointCount,
        });

    if (raw == null) {
      throw PlatformException(
        code: 'CACHE_SAVE_FAILED',
        message: 'Unexpected null save result map',
      );
    }

    final status = raw['status'] as String?;
    if (status == 'saved') {
      return VGAudioWaveformSaveOutcome.saved;
    } else if (status == 'stale') {
      return VGAudioWaveformSaveOutcome.stale;
    } else {
      throw PlatformException(
        code: 'CACHE_SAVE_FAILED',
        message: 'Unknown or malformed save status: $status',
      );
    }
  }

  static Future<void> invalidateAsset({
    VGAudioWaveformCacheAddress? address,
    String? namespace,
    String? assetKey,
  }) async {
    final ns = address?.namespace ?? namespace ?? '';
    final ak = address?.assetKey ?? assetKey ?? '';

    if (ns.isEmpty) {
      throw ArgumentError.value(ns, 'namespace', 'must be non-empty');
    }
    if (ak.isEmpty) {
      throw ArgumentError.value(ak, 'assetKey', 'must be non-empty');
    }
    await _channel.invokeMethod<void>('waveformCache_invalidateAsset', {
      'namespace': ns,
      'assetKey': ak,
    });
  }

  static Future<void> invalidateNamespace({required String namespace}) async {
    if (namespace.isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'must be non-empty');
    }
    await _channel.invokeMethod<void>('waveformCache_invalidateNamespace', {
      'namespace': namespace,
    });
  }

  // ── Shared decode helper ──────────────────────────────────────────────────

  static VGAudioWaveformResult? _decodeWaveformResult(
    Map<String, dynamic> raw,
  ) {
    final samplesRaw = raw['samples'];
    final Float32List samples;
    if (samplesRaw is Float32List) {
      samples = samplesRaw;
    } else if (samplesRaw is Uint8List) {
      final byteCount = samplesRaw.length;
      final floatCount = byteCount ~/ 4;
      if (floatCount > 0) {
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
      samples: samples,
      durationSeconds: (raw['durationSeconds'] as num?)?.toDouble() ?? 0.0,
      samplesPerSecond: (raw['samplesPerSecond'] as num?)?.toInt() ?? 0,
      pointCount: (raw['pointCount'] as num?)?.toInt() ?? samples.length,
    );
  }
}
