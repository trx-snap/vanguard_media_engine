// Copyright (c) Connects -- Vanguard Phase 2-Unit AA.
// Public Dart-facing Android passthrough remux capability probe diagnostic client.
//
// Safe to import on all platforms: methods catch MissingPluginException
// and return typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

// -----------------------------------------------------------------------------
// Track Capability Model
// -----------------------------------------------------------------------------

/// Detailed capability descriptor for an extracted media track.
class VGPassthroughRemuxTrackCapability {
  /// Zero-based track index from MediaExtractor.
  final int trackIndex;

  /// Track MIME type string (e.g. 'video/avc', 'video/hevc', 'audio/mp4a-latm').
  final String mime;

  /// Whether this track format is supported for zero-reencode passthrough remux.
  final bool supported;

  /// Diagnostic reason or classification for track support status.
  final String reason;

  /// Video track width in pixels, or null for audio tracks.
  final int? width;

  /// Video track height in pixels, or null for audio tracks.
  final int? height;

  /// Track duration in microseconds, or null if unprobed.
  final int? durationUs;

  /// Video track rotation degrees (0, 90, 180, 270), or null for audio tracks.
  final int? rotationDegrees;

  /// Audio track channel count, or null for video tracks.
  final int? channelCount;

  /// Audio track sample rate in Hz, or null for video tracks.
  final int? sampleRate;

  /// Maximum input buffer size in bytes, or null if unprobed.
  final int? maxInputSize;

  /// Raw track diagnostics map preserving all platform format keys.
  final Map<String, Object?> diagnostics;

  const VGPassthroughRemuxTrackCapability({
    required this.trackIndex,
    required this.mime,
    required this.supported,
    required this.reason,
    this.width,
    this.height,
    this.durationUs,
    this.rotationDegrees,
    this.channelCount,
    this.sampleRate,
    this.maxInputSize,
    this.diagnostics = const <String, Object?>{},
  });

  /// Constructs a [VGPassthroughRemuxTrackCapability] defensively from a platform map.
  factory VGPassthroughRemuxTrackCapability.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);
    final trackIndex = _asInt(stringMap['trackIndex']) ?? -1;
    final mime = _asString(stringMap['mime']);
    final supported = _asBool(stringMap['supported']);
    final reason = _asString(stringMap['reason']);
    final width = _asInt(stringMap['width']);
    final height = _asInt(stringMap['height']);
    final durationUs = _asInt(stringMap['durationUs']);
    final rotationDegrees = _asInt(stringMap['rotationDegrees']);
    final channelCount = _asInt(stringMap['channelCount']);
    final sampleRate = _asInt(stringMap['sampleRate']);
    final maxInputSize = _asInt(stringMap['maxInputSize']);

    return VGPassthroughRemuxTrackCapability(
      trackIndex: trackIndex,
      mime: mime,
      supported: supported,
      reason: reason,
      width: width,
      height: height,
      durationUs: durationUs,
      rotationDegrees: rotationDegrees,
      channelCount: channelCount,
      sampleRate: sampleRate,
      maxInputSize: maxInputSize,
      diagnostics: Map<String, Object?>.unmodifiable(stringMap),
    );
  }

  /// Whether this track descriptor is for a video track.
  bool get isVideo => mime.startsWith('video/');

  /// Whether this track descriptor is for an audio track.
  bool get isAudio => mime.startsWith('audio/');

  /// Converts to standard JSON-compatible map format.
  Map<String, Object?> toMap() => <String, Object?>{
    'trackIndex': trackIndex,
    'mime': mime,
    'supported': supported,
    'reason': reason,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (durationUs != null) 'durationUs': durationUs,
    if (rotationDegrees != null) 'rotationDegrees': rotationDegrees,
    if (channelCount != null) 'channelCount': channelCount,
    if (sampleRate != null) 'sampleRate': sampleRate,
    if (maxInputSize != null) 'maxInputSize': maxInputSize,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGPassthroughRemuxTrackCapability(trackIndex: $trackIndex, mime: $mime, supported: $supported, reason: $reason, width: $width, height: $height, durationUs: $durationUs, rotationDegrees: $rotationDegrees, channelCount: $channelCount, sampleRate: $sampleRate, maxInputSize: $maxInputSize)';
}

// -----------------------------------------------------------------------------
// Capability Report Model
// -----------------------------------------------------------------------------

/// Structured diagnostic report of container and track passthrough remux capability.
///
/// Returned by [VGPassthroughRemuxCapabilityClient.probe].
class VGPassthroughRemuxCapabilityReport {
  /// Expected native proof boundary token.
  static const String expectedProofBoundary =
      'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples';

  /// Whether the evaluated media source is eligible for zero-reencode passthrough remux.
  final bool canPassthroughRemux;

  /// High-level diagnostic reason (e.g. 'supported', 'no_video_track', etc.).
  final String reason;

  /// Target source media file path probed by the engine.
  final String sourcePath;

  /// Whether the file exists on the local filesystem.
  final bool fileExists;

  /// Whether the file is readable by the process.
  final bool fileReadable;

  /// Whether MediaExtractor successfully opened the data source.
  final bool extractorOpened;

  /// Total number of tracks discovered by MediaExtractor.
  final int trackCount;

  /// Primary video track capability descriptor, or null if no video track present.
  final VGPassthroughRemuxTrackCapability? video;

  /// Primary audio track capability descriptor, or null if no audio track present.
  final VGPassthroughRemuxTrackCapability? audio;

  /// Proof boundary token returned by the native probe engine.
  final String proofBoundary;

  /// Invariant non-claims map proving pure metadata inspection without side effects.
  final Map<String, bool> nonClaims;

  /// Complete raw diagnostic telemetry dictionary from native platform probe.
  final Map<String, Object?> diagnostics;

  const VGPassthroughRemuxCapabilityReport({
    required this.canPassthroughRemux,
    required this.reason,
    required this.sourcePath,
    required this.fileExists,
    required this.fileReadable,
    required this.extractorOpened,
    required this.trackCount,
    this.video,
    this.audio,
    required this.proofBoundary,
    required this.nonClaims,
    required this.diagnostics,
  });

  /// Constructs a [VGPassthroughRemuxCapabilityReport] defensively from a platform map.
  factory VGPassthroughRemuxCapabilityReport.fromMap(
    Map<Object?, Object?> map,
  ) {
    final stringMap = _defensiveStringMap(map);
    final canPassthroughRemux = _asBool(stringMap['canPassthroughRemux']);
    final reason = _asString(stringMap['reason']);
    final sourcePath = _asString(stringMap['sourcePath']);
    final fileExists = _asBool(stringMap['fileExists']);
    final fileReadable = _asBool(stringMap['fileReadable']);
    final extractorOpened = _asBool(stringMap['extractorOpened']);
    final trackCount = _asInt(stringMap['trackCount']) ?? 0;

    final rawVideo = stringMap['video'];
    final video = rawVideo is Map
        ? VGPassthroughRemuxTrackCapability.fromMap(
            rawVideo.cast<Object?, Object?>(),
          )
        : null;

    final rawAudio = stringMap['audio'];
    final audio = rawAudio is Map
        ? VGPassthroughRemuxTrackCapability.fromMap(
            rawAudio.cast<Object?, Object?>(),
          )
        : null;

    final proofBoundary = _asString(stringMap['proofBoundary']);

    final rawNonClaims = stringMap['nonClaims'];
    final nonClaims = <String, bool>{};
    if (rawNonClaims is Map) {
      for (final entry in rawNonClaims.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          nonClaims[k] = _asBool(entry.value);
        }
      }
    }

    return VGPassthroughRemuxCapabilityReport(
      canPassthroughRemux: canPassthroughRemux,
      reason: reason,
      sourcePath: sourcePath,
      fileExists: fileExists,
      fileReadable: fileReadable,
      extractorOpened: extractorOpened,
      trackCount: trackCount,
      video: video,
      audio: audio,
      proofBoundary: proofBoundary,
      nonClaims: Map<String, bool>.unmodifiable(nonClaims),
      diagnostics: Map<String, Object?>.unmodifiable(stringMap),
    );
  }

  /// Returned when an unexpected error, blank argument, or malformed response occurs.
  factory VGPassthroughRemuxCapabilityReport.failure(
    String reason, [
    Map<String, Object?>? details,
  ]) {
    final diag =
        details ??
        <String, Object?>{'canPassthroughRemux': false, 'error': reason};
    return VGPassthroughRemuxCapabilityReport(
      canPassthroughRemux: false,
      reason: reason,
      sourcePath: _asString(diag['sourcePath']),
      fileExists: false,
      fileReadable: false,
      extractorOpened: false,
      trackCount: 0,
      video: null,
      audio: null,
      proofBoundary: 'client_failure',
      nonClaims: const <String, bool>{
        'mediaMuxerStarted': false,
        'mediaCodecAllocated': false,
        'samplesRead': false,
        'outputFileWritten': false,
        'productionExportTimelineBypass': false,
        'cppPassthroughRemuxSinkNode': false,
        'connectAppTouched': false,
      },
      diagnostics: Map<String, Object?>.unmodifiable(diag),
    );
  }

  /// Returned when the native plugin is not available (e.g. non-Android or missing plugin).
  factory VGPassthroughRemuxCapabilityReport.unsupported() =>
      const VGPassthroughRemuxCapabilityReport(
        canPassthroughRemux: false,
        reason: 'unsupported_platform',
        sourcePath: '',
        fileExists: false,
        fileReadable: false,
        extractorOpened: false,
        trackCount: 0,
        video: null,
        audio: null,
        proofBoundary: 'unsupported',
        nonClaims: <String, bool>{
          'mediaMuxerStarted': false,
          'mediaCodecAllocated': false,
          'samplesRead': false,
          'outputFileWritten': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          'connectAppTouched': false,
        },
        diagnostics: <String, Object?>{
          'canPassthroughRemux': false,
          'reason': 'unsupported_platform',
        },
      );

  /// Whether a supported video track is present.
  bool get hasSupportedVideo => video != null && video!.supported;

  /// Whether a supported audio track is present, or the clip contains no audio track.
  bool get hasSupportedAudioOrNoAudio => audio == null || audio!.supported;

  /// Whether the native proof boundary matches the expected Unit Z diagnostic token.
  bool get proofBoundaryMatches => proofBoundary == expectedProofBoundary;

  /// Whether all non-claims strictly hold (all false).
  bool get diagnosticNonClaimsHold {
    if (nonClaims.isEmpty) return false;
    const requiredKeys = <String>[
      'mediaMuxerStarted',
      'mediaCodecAllocated',
      'samplesRead',
      'outputFileWritten',
      'productionExportTimelineBypass',
      'cppPassthroughRemuxSinkNode',
      'connectAppTouched',
    ];
    for (final key in requiredKeys) {
      if (nonClaims[key] != false) {
        return false;
      }
    }
    return nonClaims.values.every((v) => v == false);
  }

  /// Converts to standard JSON-compatible map format.
  Map<String, Object?> toMap() => <String, Object?>{
    'canPassthroughRemux': canPassthroughRemux,
    'reason': reason,
    'sourcePath': sourcePath,
    'fileExists': fileExists,
    'fileReadable': fileReadable,
    'extractorOpened': extractorOpened,
    'trackCount': trackCount,
    'video': video?.toMap(),
    'audio': audio?.toMap(),
    'proofBoundary': proofBoundary,
    'nonClaims': nonClaims,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGPassthroughRemuxCapabilityReport(canPassthroughRemux: $canPassthroughRemux, reason: $reason, sourcePath: $sourcePath, fileExists: $fileExists, fileReadable: $fileReadable, extractorOpened: $extractorOpened, trackCount: $trackCount, video: $video, audio: $audio, proofBoundary: $proofBoundary)';
}

// -----------------------------------------------------------------------------
// Public Client
// -----------------------------------------------------------------------------

/// Public diagnostic client for probing Android passthrough remux capability of local media files.
///
/// Wraps native platform diagnostic route `runAndroidPassthroughRemuxCapabilityProbeSmoke`
/// behind a safe, strongly-typed Dart API.
///
/// Invariants:
/// - Pure metadata inspection via platform MediaExtractor.
/// - Zero sample reads (readSampleData is never invoked).
/// - Zero MediaMuxer or MediaCodec allocation.
/// - Zero production exportTimeline bypass.
/// - Safe to import and call on all platforms; returns typed unsupported reports on non-Android.
class VGPassthroughRemuxCapabilityClient {
  VGPassthroughRemuxCapabilityClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Probes the specified [sourcePath] for zero-reencode passthrough remux compatibility.
  Future<VGPassthroughRemuxCapabilityReport> probe(String sourcePath) async {
    if (sourcePath.trim().isEmpty) {
      return VGPassthroughRemuxCapabilityReport.failure('source_path_empty');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'runAndroidPassthroughRemuxCapabilityProbeSmoke',
        <String, Object>{'sourcePath': sourcePath},
      );
      if (raw is! Map) {
        return VGPassthroughRemuxCapabilityReport.failure(
          'invalid_response:${raw.runtimeType}',
        );
      }
      return VGPassthroughRemuxCapabilityReport.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGPassthroughRemuxCapabilityReport.unsupported();
    } catch (e) {
      return VGPassthroughRemuxCapabilityReport.failure('exception:$e');
    }
  }
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _asBool(Object? value, {bool defaultValue = false}) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  return defaultValue;
}

String _asString(Object? value, {String defaultValue = ''}) {
  if (value is String) return value;
  return defaultValue;
}

Map<String, Object?> _defensiveStringMap(Map<Object?, Object?> map) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key?.toString();
    if (key != null) {
      result[key] = entry.value;
    }
  }
  return result;
}
