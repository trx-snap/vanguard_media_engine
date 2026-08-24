// Copyright (c) Connects — Vanguard Phase 4C5L.
// Public streaming manifest rendition diagnostics API client.
//
// Safe to import on all platforms: methods catch [MissingPluginException]
// and return typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Rendition Info Model
// ─────────────────────────────────────────────────────────────────────────────

/// Detailed descriptor for a single variant or representation in a streaming manifest.
class VGStreamingRenditionInfo {
  /// Zero-based index of this rendition in the parent manifest stream.
  final int index;

  /// Representation identifier (primarily used in DASH MPDs).
  final String id;

  /// Fully resolved URI to the variant playlist or media asset.
  final String uri;

  /// Raw URI string from the manifest tag before resolution.
  final String rawUri;

  /// AdaptationSet identifier for DASH streams.
  final String adaptationSetId;

  /// Target peak bandwidth in bits per second (bps).
  final int bandwidth;

  /// Average bitrate in bits per second (bps).
  final int averageBandwidth;

  /// Video resolution string (e.g. `'1920x1080'`).
  final String resolution;

  /// Decoded video width in pixels.
  final int width;

  /// Decoded video height in pixels.
  final int height;

  /// CODECS attribute string (e.g. `'avc1.640028,mp4a.40.2'`).
  final String codecs;

  /// Container or codec MIME type (e.g. `'video/mp4'`).
  final String mimeType;

  /// Video frame rate representation (e.g. `'30'`, `'29.97'`, or `'0.0'`).
  final String frameRate;

  /// Human-readable name or label (e.g. from HLS `NAME` attribute).
  final String name;

  /// Whether AVC/H.264 video codec was detected for this rendition.
  final bool hasAvc;

  /// Whether HEVC/H.265 video codec was detected for this rendition.
  final bool hasHevc;

  /// Whether AV1 video codec was detected for this rendition.
  final bool hasAv1;

  /// List of detected codec family identifiers (e.g. `['avc', 'aac']`).
  final List<String> detectedFamilies;

  /// Complete raw diagnostic map for this rendition.
  final Map<String, Object?> diagnostics;

  const VGStreamingRenditionInfo({
    required this.index,
    required this.id,
    required this.uri,
    required this.rawUri,
    required this.adaptationSetId,
    required this.bandwidth,
    required this.averageBandwidth,
    required this.resolution,
    required this.width,
    required this.height,
    required this.codecs,
    required this.mimeType,
    required this.frameRate,
    required this.name,
    required this.hasAvc,
    required this.hasHevc,
    required this.hasAv1,
    required this.detectedFamilies,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingRenditionInfo] defensively from a platform dictionary.
  factory VGStreamingRenditionInfo.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);

    final index = (stringMap['index'] as num?)?.toInt() ?? 0;
    final id = stringMap['id'] as String? ?? '';
    final uri = stringMap['uri'] as String? ?? '';
    final rawUri = stringMap['rawUri'] as String? ?? '';
    final adaptationSetId = stringMap['adaptationSetId'] as String? ?? '';
    final bandwidth = (stringMap['bandwidth'] as num?)?.toInt() ?? 0;
    final averageBandwidth =
        (stringMap['averageBandwidth'] as num?)?.toInt() ?? bandwidth;
    final resolution = stringMap['resolution'] as String? ?? '';
    final width = (stringMap['width'] as num?)?.toInt() ?? 0;
    final height = (stringMap['height'] as num?)?.toInt() ?? 0;
    final codecs = stringMap['codecs'] as String? ?? '';
    final mimeType = stringMap['mimeType'] as String? ?? '';

    final rawFrameRate = stringMap['frameRate'];
    final frameRate = rawFrameRate?.toString() ?? '';

    final name = stringMap['name'] as String? ?? '';
    final hasAvc = stringMap['hasAvc'] as bool? ?? false;
    final hasHevc = stringMap['hasHevc'] as bool? ?? false;
    final hasAv1 = stringMap['hasAv1'] as bool? ?? false;

    final rawFamilies = stringMap['detectedFamilies'];
    final detectedFamilies = rawFamilies is List
        ? rawFamilies
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
        : const <String>[];

    return VGStreamingRenditionInfo(
      index: index,
      id: id,
      uri: uri,
      rawUri: rawUri,
      adaptationSetId: adaptationSetId,
      bandwidth: bandwidth,
      averageBandwidth: averageBandwidth,
      resolution: resolution,
      width: width,
      height: height,
      codecs: codecs,
      mimeType: mimeType,
      frameRate: frameRate,
      name: name,
      hasAvc: hasAvc,
      hasHevc: hasHevc,
      hasAv1: hasAv1,
      detectedFamilies: detectedFamilies,
      diagnostics: stringMap,
    );
  }

  /// Convenience getter indicating whether this rendition uses an advanced codec (HEVC or AV1).
  bool get hasAdvancedCodec => hasHevc || hasAv1;

  /// Converts to standard map format.
  Map<String, Object?> toMap() => {
    'index': index,
    'id': id,
    'uri': uri,
    'rawUri': rawUri,
    'adaptationSetId': adaptationSetId,
    'bandwidth': bandwidth,
    'averageBandwidth': averageBandwidth,
    'resolution': resolution,
    'width': width,
    'height': height,
    'codecs': codecs,
    'mimeType': mimeType,
    'frameRate': frameRate,
    'name': name,
    'hasAvc': hasAvc,
    'hasHevc': hasHevc,
    'hasAv1': hasAv1,
    'detectedFamilies': detectedFamilies,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingRenditionInfo(index=$index, id=$id, res=${width}x$height, bw=$bandwidth, codecs=$codecs, avc=$hasAvc, hevc=$hasHevc, av1=$hasAv1)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Stream Diagnostics Model
// ─────────────────────────────────────────────────────────────────────────────

/// Detailed diagnostic telemetry for an individual stream inspected during smoke testing.
class VGStreamingManifestStreamDiagnostics {
  /// Stream format identifier (e.g. `'HLS'` or `'DASH'`).
  final String format;

  /// Target manifest URI passed for inspection.
  final String uri;

  /// Final resolved URI following any HTTP redirects.
  final String resolvedUri;

  /// Whether HTTP GET fetch of the manifest text succeeded.
  final bool fetchSuccess;

  /// Whether structural parsing of playlist tags or MPD XML succeeded.
  final bool parseSuccess;

  /// Whether this stream was identified as a single media playlist rather than a multivariant ladder.
  final bool isMediaPlaylist;

  /// Total number of variants discovered in HLS multivariant playlist.
  final int variantCount;

  /// Total number of representations discovered in DASH MPD.
  final int representationCount;

  /// Whether multiple renditions are available for adaptive bitrate ladder switching.
  final bool hasAdaptiveLadder;

  /// Whether at least one rendition in this stream uses AVC/H.264.
  final bool hasAvc;

  /// Whether at least one rendition in this stream uses HEVC/H.265.
  final bool hasHevc;

  /// Whether at least one rendition in this stream uses AV1.
  final bool hasAv1;

  /// Whether this stream satisfies the additive server ladder policy (mandatory AVC fallback).
  final bool serverPolicyPass;

  /// Diagnostic flags for Low-Latency HLS tags (`#EXT-X-PART`, `#EXT-X-SERVER-CONTROL`, etc.).
  final Map<String, Object?> llHlsIndicators;

  /// Parsed HLS variant descriptors.
  final List<VGStreamingRenditionInfo> variants;

  /// Parsed DASH representation descriptors.
  final List<VGStreamingRenditionInfo> representations;

  /// Raw diagnostic summary string from native platform engine.
  final String raw;

  /// Complete diagnostic telemetry dictionary returned by native platform engine.
  final Map<String, Object?> diagnostics;

  const VGStreamingManifestStreamDiagnostics({
    required this.format,
    required this.uri,
    required this.resolvedUri,
    required this.fetchSuccess,
    required this.parseSuccess,
    required this.isMediaPlaylist,
    required this.variantCount,
    required this.representationCount,
    required this.hasAdaptiveLadder,
    required this.hasAvc,
    required this.hasHevc,
    required this.hasAv1,
    required this.serverPolicyPass,
    required this.llHlsIndicators,
    required this.variants,
    required this.representations,
    required this.raw,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingManifestStreamDiagnostics] defensively from a platform dictionary.
  factory VGStreamingManifestStreamDiagnostics.fromMap(
    Map<Object?, Object?> map,
  ) {
    final stringMap = _defensiveStringMap(map);

    final format = stringMap['format'] as String? ?? '';
    final uri = stringMap['uri'] as String? ?? '';
    final resolvedUri = stringMap['resolvedUri'] as String? ?? uri;
    final fetchSuccess = stringMap['fetchSuccess'] as bool? ?? false;
    final parseSuccess = stringMap['parseSuccess'] as bool? ?? false;
    final isMediaPlaylist = stringMap['isMediaPlaylist'] as bool? ?? false;
    final variantCount = (stringMap['variantCount'] as num?)?.toInt() ?? 0;
    final representationCount =
        (stringMap['representationCount'] as num?)?.toInt() ?? variantCount;
    final hasAdaptiveLadder =
        stringMap['hasAdaptiveLadder'] as bool? ?? (variantCount > 1);
    final hasAvc = stringMap['hasAvc'] as bool? ?? false;
    final hasHevc = stringMap['hasHevc'] as bool? ?? false;
    final hasAv1 = stringMap['hasAv1'] as bool? ?? false;
    final serverPolicyPass = stringMap['serverPolicyPass'] as bool? ?? false;

    final rawIndicators = stringMap['llHlsIndicators'];
    final llHlsIndicators = rawIndicators is Map
        ? _defensiveStringMap(rawIndicators.cast<Object?, Object?>())
        : const <String, Object?>{};

    final rawVariants = stringMap['variants'];
    final variants = rawVariants is List
        ? rawVariants
              .whereType<Map>()
              .map(
                (m) => VGStreamingRenditionInfo.fromMap(
                  m.cast<Object?, Object?>(),
                ),
              )
              .toList()
        : const <VGStreamingRenditionInfo>[];

    final rawReps = stringMap['representations'];
    final representations = rawReps is List
        ? rawReps
              .whereType<Map>()
              .map(
                (m) => VGStreamingRenditionInfo.fromMap(
                  m.cast<Object?, Object?>(),
                ),
              )
              .toList()
        : variants;

    final raw = stringMap['raw'] as String? ?? '';

    return VGStreamingManifestStreamDiagnostics(
      format: format,
      uri: uri,
      resolvedUri: resolvedUri,
      fetchSuccess: fetchSuccess,
      parseSuccess: parseSuccess,
      isMediaPlaylist: isMediaPlaylist,
      variantCount: variantCount,
      representationCount: representationCount,
      hasAdaptiveLadder: hasAdaptiveLadder,
      hasAvc: hasAvc,
      hasHevc: hasHevc,
      hasAv1: hasAv1,
      serverPolicyPass: serverPolicyPass,
      llHlsIndicators: llHlsIndicators,
      variants: variants,
      representations: representations,
      raw: raw,
      diagnostics: stringMap,
    );
  }

  /// Empty / fallback stream diagnostics.
  factory VGStreamingManifestStreamDiagnostics.empty([String format = '']) =>
      VGStreamingManifestStreamDiagnostics(
        format: format,
        uri: '',
        resolvedUri: '',
        fetchSuccess: false,
        parseSuccess: false,
        isMediaPlaylist: false,
        variantCount: 0,
        representationCount: 0,
        hasAdaptiveLadder: false,
        hasAvc: false,
        hasHevc: false,
        hasAv1: false,
        serverPolicyPass: false,
        llHlsIndicators: const <String, Object?>{},
        variants: const <VGStreamingRenditionInfo>[],
        representations: const <VGStreamingRenditionInfo>[],
        raw: '',
        diagnostics: const <String, Object?>{},
      );

  /// Convenience getter indicating whether any advanced codec (HEVC or AV1) is present in this stream.
  bool get hasAnyAdvancedCodecRendition =>
      hasHevc ||
      hasAv1 ||
      variants.any((v) => v.hasAdvancedCodec) ||
      representations.any((r) => r.hasAdvancedCodec);

  /// Convenience getter indicating whether AVC fallback is available in this stream.
  bool get hasAvcFallback =>
      hasAvc ||
      variants.any((v) => v.hasAvc) ||
      representations.any((r) => r.hasAvc);

  /// Convenience getter indicating whether Low-Latency HLS tags are present.
  bool get hasLlHlsIndicators =>
      llHlsIndicators['isLlHls'] == true ||
      llHlsIndicators['hasExtXPart'] == true ||
      llHlsIndicators['hasExtXServerControl'] == true ||
      llHlsIndicators['hasExtXPreloadHint'] == true ||
      llHlsIndicators['hasExtXPartInf'] == true;

  /// Converts to standard map format.
  Map<String, Object?> toMap() => {
    'format': format,
    'uri': uri,
    'resolvedUri': resolvedUri,
    'fetchSuccess': fetchSuccess,
    'parseSuccess': parseSuccess,
    'isMediaPlaylist': isMediaPlaylist,
    'variantCount': variantCount,
    'representationCount': representationCount,
    'hasAdaptiveLadder': hasAdaptiveLadder,
    'hasAvc': hasAvc,
    'hasHevc': hasHevc,
    'hasAv1': hasAv1,
    'serverPolicyPass': serverPolicyPass,
    'llHlsIndicators': llHlsIndicators,
    'variants': variants.map((v) => v.toMap()).toList(),
    'representations': representations.map((r) => r.toMap()).toList(),
    'raw': raw,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingManifestStreamDiagnostics(format=$format, uri=$uri, fetch=$fetchSuccess, parse=$parseSuccess, variants=$variantCount, avc=$hasAvc, hevc=$hasHevc, av1=$hasAv1, policy=$serverPolicyPass)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Overall Report Model
// ─────────────────────────────────────────────────────────────────────────────

/// Structured manifest rendition ladder diagnostic report returned by
/// [VGStreamingManifestRenditionClient.inspectCanonicalStreams].
///
/// Wraps native platform diagnostic route `runAndroidDagPhase4C5CManifestRenditionSmoke`
/// behind a safe, strongly-typed Dart API.
class VGStreamingManifestRenditionReport {
  /// Whether overall verification passed across all inspected streams.
  final bool pass;

  /// Platform engine phase identifier (e.g. `"Phase4C5C"` or `"unsupported"`).
  final String phase;

  /// Whether HLS multivariant stream inspection passed.
  final bool hlsPass;

  /// Whether DASH MPD stream inspection passed.
  final bool dashPass;

  /// Whether Low-Latency HLS stream inspection passed.
  final bool llHlsPass;

  /// Whether all inspected streams satisfy the additive server ladder policy.
  final bool allServerPoliciesPass;

  /// Total number of candidate streams inspected (canonical test suite: 3).
  final int totalStreamsInspected;

  /// Total number of variants and representations discovered across all streams.
  final int totalVariantsDiscovered;

  /// Total number of variants discovered in the HLS test stream.
  final int hlsVariantCount;

  /// Total number of representations discovered in the DASH test stream.
  final int dashRepresentationCount;

  /// Total number of variants discovered in the LL-HLS test stream.
  final int llHlsVariantCount;

  /// Server ladder policy requirement string (e.g. `"add_hevc_av1_renditions_but_keep_avc_fallback"`).
  final String serverLadderPolicy;

  /// Guidance note for iOS mirror implementations.
  final String iosMirrorNote;

  /// Detailed diagnostics for the HLS test stream.
  final VGStreamingManifestStreamDiagnostics hls;

  /// Detailed diagnostics for the DASH test stream.
  final VGStreamingManifestStreamDiagnostics dash;

  /// Detailed diagnostics for the LL-HLS test stream.
  final VGStreamingManifestStreamDiagnostics llHls;

  /// Raw diagnostic summary string from native platform engine.
  final String raw;

  /// Complete diagnostic telemetry dictionary returned by native platform engine.
  final Map<String, Object?> diagnostics;

  const VGStreamingManifestRenditionReport({
    required this.pass,
    required this.phase,
    required this.hlsPass,
    required this.dashPass,
    required this.llHlsPass,
    required this.allServerPoliciesPass,
    required this.totalStreamsInspected,
    required this.totalVariantsDiscovered,
    required this.hlsVariantCount,
    required this.dashRepresentationCount,
    required this.llHlsVariantCount,
    required this.serverLadderPolicy,
    required this.iosMirrorNote,
    required this.hls,
    required this.dash,
    required this.llHls,
    required this.raw,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingManifestRenditionReport] from a raw platform dictionary.
  factory VGStreamingManifestRenditionReport.fromMap(
    Map<Object?, Object?> map,
  ) {
    final stringMap = _defensiveStringMap(map);

    final pass = stringMap['pass'] as bool? ?? false;
    final phase = stringMap['phase'] as String? ?? 'Phase4C5C';
    final hlsPass = stringMap['hlsPass'] as bool? ?? false;
    final dashPass = stringMap['dashPass'] as bool? ?? false;
    final llHlsPass = stringMap['llHlsPass'] as bool? ?? false;
    final allServerPoliciesPass =
        stringMap['allServerPoliciesPass'] as bool? ?? false;

    final totalStreamsInspected =
        (stringMap['totalStreamsInspected'] as num?)?.toInt() ?? 0;
    final totalVariantsDiscovered =
        (stringMap['totalVariantsDiscovered'] as num?)?.toInt() ?? 0;
    final hlsVariantCount =
        (stringMap['hlsVariantCount'] as num?)?.toInt() ?? 0;
    final dashRepresentationCount =
        (stringMap['dashRepresentationCount'] as num?)?.toInt() ?? 0;
    final llHlsVariantCount =
        (stringMap['llHlsVariantCount'] as num?)?.toInt() ?? 0;

    final serverLadderPolicy = stringMap['serverLadderPolicy'] as String? ?? '';
    final iosMirrorNote = stringMap['iosMirrorNote'] as String? ?? '';

    final rawHls = stringMap['hls'];
    final hls = rawHls is Map
        ? VGStreamingManifestStreamDiagnostics.fromMap(
            rawHls.cast<Object?, Object?>(),
          )
        : VGStreamingManifestStreamDiagnostics.empty('HLS');

    final rawDash = stringMap['dash'];
    final dash = rawDash is Map
        ? VGStreamingManifestStreamDiagnostics.fromMap(
            rawDash.cast<Object?, Object?>(),
          )
        : VGStreamingManifestStreamDiagnostics.empty('DASH');

    final rawLlHls = stringMap['llHls'];
    final llHls = rawLlHls is Map
        ? VGStreamingManifestStreamDiagnostics.fromMap(
            rawLlHls.cast<Object?, Object?>(),
          )
        : VGStreamingManifestStreamDiagnostics.empty('HLS');

    final raw = stringMap['raw'] as String? ?? '';

    return VGStreamingManifestRenditionReport(
      pass: pass,
      phase: phase,
      hlsPass: hlsPass,
      dashPass: dashPass,
      llHlsPass: llHlsPass,
      allServerPoliciesPass: allServerPoliciesPass,
      totalStreamsInspected: totalStreamsInspected,
      totalVariantsDiscovered: totalVariantsDiscovered,
      hlsVariantCount: hlsVariantCount,
      dashRepresentationCount: dashRepresentationCount,
      llHlsVariantCount: llHlsVariantCount,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      hls: hls,
      dash: dash,
      llHls: llHls,
      raw: raw,
      diagnostics: stringMap,
    );
  }

  /// Returned when an unexpected error or malformed response occurs.
  factory VGStreamingManifestRenditionReport.failure(
    String reason, [
    Map<String, Object?>? details,
  ]) => VGStreamingManifestRenditionReport(
    pass: false,
    phase: 'Phase4C5C',
    hlsPass: false,
    dashPass: false,
    llHlsPass: false,
    allServerPoliciesPass: false,
    totalStreamsInspected: 0,
    totalVariantsDiscovered: 0,
    hlsVariantCount: 0,
    dashRepresentationCount: 0,
    llHlsVariantCount: 0,
    serverLadderPolicy: '',
    iosMirrorNote: '',
    hls: VGStreamingManifestStreamDiagnostics.empty('HLS'),
    dash: VGStreamingManifestStreamDiagnostics.empty('DASH'),
    llHls: VGStreamingManifestStreamDiagnostics.empty('HLS'),
    raw: 'status=FAIL;reason=$reason',
    diagnostics: details ?? <String, Object?>{'pass': false, 'error': reason},
  );

  /// Returned when the native plugin is not available (e.g. non-Android or missing plugin).
  factory VGStreamingManifestRenditionReport.unsupported() =>
      VGStreamingManifestRenditionReport(
        pass: false,
        phase: 'unsupported',
        hlsPass: false,
        dashPass: false,
        llHlsPass: false,
        allServerPoliciesPass: false,
        totalStreamsInspected: 0,
        totalVariantsDiscovered: 0,
        hlsVariantCount: 0,
        dashRepresentationCount: 0,
        llHlsVariantCount: 0,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        hls: VGStreamingManifestStreamDiagnostics.empty('HLS'),
        dash: VGStreamingManifestStreamDiagnostics.empty('DASH'),
        llHls: VGStreamingManifestStreamDiagnostics.empty('HLS'),
        raw: 'status=UNSUPPORTED;platform=non-android',
        diagnostics: const <String, Object?>{
          'pass': false,
          'phase': 'unsupported',
          'raw': 'status=UNSUPPORTED;platform=non-android',
        },
      );

  /// Convenience getter indicating whether any advanced codec rendition (HEVC or AV1) was discovered.
  bool get hasAnyAdvancedCodecRendition =>
      hls.hasAnyAdvancedCodecRendition ||
      dash.hasAnyAdvancedCodecRendition ||
      llHls.hasAnyAdvancedCodecRendition;

  /// Convenience getter indicating whether mandatory AVC fallback is present across all streams.
  bool get hasAvcFallback =>
      hls.hasAvcFallback && dash.hasAvcFallback && llHls.hasAvcFallback;

  /// Convenience getter indicating whether Low-Latency HLS indicators are present in the LL-HLS stream.
  bool get hasLlHlsIndicators =>
      llHls.hasLlHlsIndicators || hls.hasLlHlsIndicators;

  @override
  String toString() =>
      'VGStreamingManifestRenditionReport(pass=$pass, phase=$phase, hlsPass=$hlsPass, dashPass=$dashPass, llHlsPass=$llHlsPass, variants=$totalVariantsDiscovered, policy=$serverLadderPolicy)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Client
// ─────────────────────────────────────────────────────────────────────────────

/// Public client for inspecting streaming manifest and rendition ladder telemetry.
///
/// Wraps native platform diagnostic route `runAndroidDagPhase4C5CManifestRenditionSmoke`
/// behind a safe, strongly-typed Dart API.
///
/// Invariants:
/// - Bounded manifest-only inspection across canonical HLS, DASH, and LL-HLS streams.
/// - Pre-fetch rejection of raw media segment URLs (`.ts`, `.m4s`, `.mp4`, etc.).
/// - Zero `ExoPlayer` or `MediaCodec` allocation.
/// - Zero playback mutation, zero segment decoding, zero surface allocation, zero ABR forcing.
/// - Safe to import and call on all platforms; returns typed unsupported reports on non-Android.
///
/// Note: This canonical smoke client inspects built-in reference test streams only.
/// For validating caller-supplied production or host manifest specifications, use
/// [VGStreamingManifestPolicyClient].
class VGStreamingManifestRenditionClient {
  VGStreamingManifestRenditionClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Executes diagnostic manifest rendition inspection across canonical HLS, DASH, and LL-HLS streams.
  Future<VGStreamingManifestRenditionReport> inspectCanonicalStreams() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5CManifestRenditionSmoke',
      );
      if (raw is! Map) {
        return VGStreamingManifestRenditionReport.failure(
          'invalid_response:$raw',
        );
      }
      return VGStreamingManifestRenditionReport.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGStreamingManifestRenditionReport.unsupported();
    } catch (e) {
      return VGStreamingManifestRenditionReport.failure('exception:$e');
    }
  }

  /// Convenience alias for [inspectCanonicalStreams].
  Future<VGStreamingManifestRenditionReport> inspect() =>
      inspectCanonicalStreams();
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
