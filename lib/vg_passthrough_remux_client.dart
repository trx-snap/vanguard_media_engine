// Copyright (c) Connects -- Vanguard Phase 2-Unit AE.
// Public Dart-facing Android passthrough remux execution client.
//
// Wraps native platform execution route `exportPassthroughRemux` (Unit AD)
// behind a safe, strongly-typed Dart API. This is a typed request/response
// client only: it does not touch native Kotlin, C++/JNI, ConnectsApp, iOS,
// capability probes, admission planners, or the production exportTimeline
// pipeline.
//
// Safe to import on all platforms: methods catch MissingPluginException
// and return typed unsupported reports instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

import 'src/roi/vg_roi_export_sidecar_post_processor.dart';

// -----------------------------------------------------------------------------
// Request Model
// -----------------------------------------------------------------------------

/// Typed request for [VGPassthroughRemuxClient.export].
class VGPassthroughRemuxRequest {
  /// Maximum allowed value for [diagnosticHoldBeforeRemuxMs], matching the
  /// native execution session's clamp.
  static const int maxDiagnosticHoldBeforeRemuxMs = 5000;

  /// Local filesystem path of the readable source media file.
  final String sourcePath;

  /// Local filesystem path the remuxed output should be written to.
  final String outputPath;

  /// Optional diagnostic hold (milliseconds) applied before the remux starts.
  ///
  /// Clamped to `0..5000` by both this client and the native session; used
  /// only to prove concurrency/cancellation behavior in test harnesses.
  final int? diagnosticHoldBeforeRemuxMs;

  const VGPassthroughRemuxRequest({
    required this.sourcePath,
    required this.outputPath,
    this.diagnosticHoldBeforeRemuxMs,
  });

  /// Trimmed [sourcePath] with surrounding whitespace removed.
  String get trimmedSourcePath => sourcePath.trim();

  /// Trimmed [outputPath] with surrounding whitespace removed.
  String get trimmedOutputPath => outputPath.trim();

  /// Whether this request has non-empty, valid source and output paths.
  bool get isValid =>
      trimmedSourcePath.isNotEmpty && trimmedOutputPath.isNotEmpty;

  /// Clamps [diagnosticHoldBeforeRemuxMs] into `0..5000`, or null if unset.
  int? get clampedDiagnosticHoldBeforeRemuxMs {
    final raw = diagnosticHoldBeforeRemuxMs;
    if (raw == null) return null;
    if (raw < 0) return 0;
    if (raw > maxDiagnosticHoldBeforeRemuxMs) {
      return maxDiagnosticHoldBeforeRemuxMs;
    }
    return raw;
  }

  /// Converts this request to MethodChannel invocation arguments.
  Map<String, Object> toChannelArguments() {
    final hold = clampedDiagnosticHoldBeforeRemuxMs;
    return <String, Object>{
      'sourcePath': trimmedSourcePath,
      'outputPath': trimmedOutputPath,
      'diagnosticHoldBeforeRemuxMs': ?hold,
    };
  }

  @override
  String toString() =>
      'VGPassthroughRemuxRequest(sourcePath: $sourcePath, outputPath: $outputPath, diagnosticHoldBeforeRemuxMs: $diagnosticHoldBeforeRemuxMs)';
}

// -----------------------------------------------------------------------------
// Execution Report Model
// -----------------------------------------------------------------------------

/// Structured result of an Android passthrough remux execution attempt.
///
/// Returned by [VGPassthroughRemuxClient.export].
class VGPassthroughRemuxExecutionReport {
  /// Expected native proof boundary token.
  static const String expectedProofBoundary =
      'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass';

  /// The four Unit AD execution non-claims that must all hold false.
  static const List<String> standardNonClaims = <String>[
    'mediaCodecAllocated',
    'productionExportTimelineBypass',
    'cppPassthroughRemuxSinkNode',
    'connectAppTouched',
  ];

  /// Whether the native execution session reported success.
  final bool success;

  /// Output path reported by the native session (mirrors [outputPath]).
  final String? path;

  /// Local filesystem path the remuxed output was written to.
  final String? outputPath;

  /// Local filesystem path of the source media file that was remuxed.
  final String? sourcePath;

  /// Video track width in pixels.
  final int? width;

  /// Video track height in pixels.
  final int? height;

  /// Video track rotation degrees (0, 90, 180, 270).
  final int? rotationDegrees;

  /// Source media duration in seconds.
  final double? durationSeconds;

  /// Number of video samples copied during remux.
  final int? videoSamples;

  /// Number of audio samples copied during remux.
  final int? audioSamples;

  /// Size of the written output file in bytes.
  final int? outputSizeBytes;

  /// Whether the source media contained an audio track.
  final bool? hasAudioTrack;

  /// Local filesystem path of the mandatory empty ROI sidecar JSON file
  /// written alongside the remuxed output, matching the production
  /// `exportTimeline` output contract.
  final String? exportRoiSidecarPath;

  /// Alias for [exportRoiSidecarPath].
  String? get roiSidecarPath => exportRoiSidecarPath;

  /// Proof boundary token returned by the native execution session.
  final String proofBoundary;

  /// Invariant non-claims map reported by the native execution session.
  final Map<String, bool> nonClaims;

  /// Diagnostic hold (milliseconds) applied before the remux started.
  final int? diagnosticHoldBeforeRemuxMs;

  /// Native error code for fail-closed outcomes (e.g. `INVALID_ARG`,
  /// `FILE_UNREADABLE`, `UNSUPPORTED_SOURCE`, `OUTPUT_EXISTS`,
  /// `OUTPUT_UNWRITABLE`, `EXPORT_CANCELLED`, `EXPORT_FAILED`,
  /// `EXPORT_IN_PROGRESS`), or a client-local code for local/transport
  /// failures.
  final String? errorCode;

  /// Human-readable error message for fail-closed outcomes.
  final String? errorMessage;

  /// Complete raw diagnostic payload map from the native platform.
  final Map<String, Object?> diagnostics;

  const VGPassthroughRemuxExecutionReport({
    required this.success,
    this.path,
    this.outputPath,
    this.sourcePath,
    this.width,
    this.height,
    this.rotationDegrees,
    this.durationSeconds,
    this.videoSamples,
    this.audioSamples,
    this.outputSizeBytes,
    this.hasAudioTrack,
    this.exportRoiSidecarPath,
    required this.proofBoundary,
    required this.nonClaims,
    this.diagnosticHoldBeforeRemuxMs,
    this.errorCode,
    this.errorMessage,
    required this.diagnostics,
  });

  /// Constructs a [VGPassthroughRemuxExecutionReport] defensively from a
  /// platform success or error map.
  factory VGPassthroughRemuxExecutionReport.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);
    final success = _asBool(stringMap['success']);

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

    return VGPassthroughRemuxExecutionReport(
      success: success,
      path: _asNullableString(stringMap['path']),
      outputPath: _asNullableString(stringMap['outputPath']),
      sourcePath: _asNullableString(stringMap['sourcePath']),
      width: _asInt(stringMap['width']),
      height: _asInt(stringMap['height']),
      rotationDegrees: _asInt(stringMap['rotationDegrees']),
      durationSeconds: _asDouble(stringMap['durationSeconds']),
      videoSamples: _asInt(stringMap['videoSamples']),
      audioSamples: _asInt(stringMap['audioSamples']),
      outputSizeBytes: _asInt(stringMap['outputSizeBytes']),
      hasAudioTrack: _asNullableBool(stringMap['hasAudioTrack']),
      exportRoiSidecarPath:
          _asNullableString(stringMap['exportRoiSidecarPath']) ??
          _asNullableString(stringMap['roiSidecarPath']),
      proofBoundary: _asString(stringMap['proofBoundary']),
      nonClaims: Map<String, bool>.unmodifiable(nonClaims),
      diagnosticHoldBeforeRemuxMs: _asInt(
        stringMap['diagnosticHoldBeforeRemuxMs'],
      ),
      errorCode: _asNullableString(stringMap['errorCode']),
      errorMessage: _asNullableString(stringMap['errorMessage']),
      diagnostics: Map<String, Object?>.unmodifiable(stringMap),
    );
  }

  /// Returned when the request fails closed locally (blank arguments,
  /// malformed response, `PlatformException`, or unexpected exception)
  /// without necessarily reaching the native execution session.
  factory VGPassthroughRemuxExecutionReport.failure(
    String errorCode, [
    String? errorMessage,
    Map<String, Object?>? details,
  ]) {
    final diag =
        details ?? <String, Object?>{'success': false, 'errorCode': errorCode};
    return VGPassthroughRemuxExecutionReport(
      success: false,
      proofBoundary: 'client_failure',
      nonClaims: const <String, bool>{
        'mediaCodecAllocated': false,
        'productionExportTimelineBypass': false,
        'cppPassthroughRemuxSinkNode': false,
        'connectAppTouched': false,
      },
      errorCode: errorCode,
      errorMessage: errorMessage,
      diagnostics: Map<String, Object?>.unmodifiable(diag),
    );
  }

  /// Returned when the native plugin is not available (e.g. non-Android or
  /// missing plugin).
  factory VGPassthroughRemuxExecutionReport.unsupported() =>
      const VGPassthroughRemuxExecutionReport(
        success: false,
        proofBoundary: 'unsupported',
        nonClaims: <String, bool>{
          'mediaCodecAllocated': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          'connectAppTouched': false,
        },
        errorCode: 'unsupported_platform',
        errorMessage: 'vanguard_media_engine plugin is not available',
        diagnostics: <String, Object?>{
          'success': false,
          'errorCode': 'unsupported_platform',
        },
      );

  /// Whether this report represents a fail-closed outcome.
  bool get isFailure => !success;

  /// Whether the native session reported a real output file write.
  bool get outputWritten =>
      success && (outputSizeBytes != null && outputSizeBytes! > 0);

  /// Whether the native proof boundary matches the expected Unit AD token.
  bool get proofBoundaryMatches => proofBoundary == expectedProofBoundary;

  /// Whether the four Unit AD execution non-claims strictly hold: present,
  /// all false, and no unexpected extra claims.
  bool get diagnosticNonClaimsHold {
    if (nonClaims.length != standardNonClaims.length) return false;
    for (final key in standardNonClaims) {
      if (nonClaims[key] != false) {
        return false;
      }
    }
    return true;
  }

  /// Converts to standard JSON-compatible map format.
  Map<String, Object?> toMap() => <String, Object?>{
    'success': success,
    if (path != null) 'path': path,
    if (outputPath != null) 'outputPath': outputPath,
    if (sourcePath != null) 'sourcePath': sourcePath,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (rotationDegrees != null) 'rotationDegrees': rotationDegrees,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    if (videoSamples != null) 'videoSamples': videoSamples,
    if (audioSamples != null) 'audioSamples': audioSamples,
    if (outputSizeBytes != null) 'outputSizeBytes': outputSizeBytes,
    if (hasAudioTrack != null) 'hasAudioTrack': hasAudioTrack,
    if (exportRoiSidecarPath != null)
      'exportRoiSidecarPath': exportRoiSidecarPath,
    if (roiSidecarPath != null) 'roiSidecarPath': roiSidecarPath,
    'proofBoundary': proofBoundary,
    'nonClaims': nonClaims,
    if (diagnosticHoldBeforeRemuxMs != null)
      'diagnosticHoldBeforeRemuxMs': diagnosticHoldBeforeRemuxMs,
    if (errorCode != null) 'errorCode': errorCode,
    if (errorMessage != null) 'errorMessage': errorMessage,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGPassthroughRemuxExecutionReport(success: $success, outputPath: $outputPath, sourcePath: $sourcePath, exportRoiSidecarPath: $exportRoiSidecarPath, errorCode: $errorCode, errorMessage: $errorMessage, proofBoundary: $proofBoundary)';
}

// -----------------------------------------------------------------------------
// Public Client
// -----------------------------------------------------------------------------

/// Public execution client for Android zero-reencode passthrough remux.
///
/// Wraps native platform execution route `exportPassthroughRemux` (Unit AD)
/// behind a safe, strongly-typed Dart API.
///
/// This client:
/// - Fails closed locally (without calling the platform channel) on blank
///   `sourcePath`/`outputPath`.
/// - Never deletes files, never starts the production `exportTimeline`
///   pipeline, never calls capability probes or admission planners, and
///   never attempts ConnectsApp UI wiring.
/// - Is safe to import and call on all platforms; returns a typed
///   unsupported report on non-Android platforms.
class VGPassthroughRemuxClient {
  VGPassthroughRemuxClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Executes a passthrough remux for the given [request].
  Future<VGPassthroughRemuxExecutionReport> export(
    VGPassthroughRemuxRequest request,
  ) async {
    if (!request.isValid) {
      final missing = request.trimmedSourcePath.isEmpty
          ? 'source_path_empty'
          : 'output_path_empty';
      return VGPassthroughRemuxExecutionReport.failure(missing);
    }
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'exportPassthroughRemux',
        request.toChannelArguments(),
      );
      if (raw is! Map) {
        return VGPassthroughRemuxExecutionReport.failure(
          'invalid_response',
          'unexpected response type: ${raw.runtimeType}',
        );
      }
      final report = VGPassthroughRemuxExecutionReport.fromMap(
        raw.cast<Object?, Object?>(),
      );

      // Best-effort ROI sidecar upgrade. Never affects success/error state:
      // the post-processor fails closed and leaves the native empty sidecar
      // in place on any error.
      if (report.success) {
        final sourcePath = report.sourcePath;
        final outputPath = report.outputPath;
        final sidecarPath = report.exportRoiSidecarPath;
        final width = report.width;
        final height = report.height;
        if (sourcePath != null &&
            outputPath != null &&
            sidecarPath != null &&
            width != null &&
            width > 0 &&
            height != null &&
            height > 0) {
          await VGRoiExportSidecarPostProcessor.process(
            sourceVideoPath: sourcePath,
            outputVideoPath: outputPath,
            exportRoiSidecarPath: sidecarPath,
            canvasWidth: width,
            canvasHeight: height,
            passthroughPreservesSourceGeometry: true,
          );
        }
      }

      return report;
    } on MissingPluginException {
      return VGPassthroughRemuxExecutionReport.unsupported();
    } on PlatformException catch (e) {
      return VGPassthroughRemuxExecutionReport.failure(
        e.code.isNotEmpty ? e.code : 'platform_exception',
        e.message,
        <String, Object?>{
          'success': false,
          'errorCode': e.code,
          'errorMessage': e.message,
          'details': e.details,
        },
      );
    } catch (e) {
      return VGPassthroughRemuxExecutionReport.failure('exception', '$e');
    }
  }

  /// Convenience helper: builds a [VGPassthroughRemuxRequest] from raw
  /// fields and executes it.
  static Future<VGPassthroughRemuxExecutionReport> exportFile({
    required String sourcePath,
    required String outputPath,
    int? diagnosticHoldBeforeRemuxMs,
    MethodChannel? channel,
  }) {
    final client = VGPassthroughRemuxClient(channel: channel);
    return client.export(
      VGPassthroughRemuxRequest(
        sourcePath: sourcePath,
        outputPath: outputPath,
        diagnosticHoldBeforeRemuxMs: diagnosticHoldBeforeRemuxMs,
      ),
    );
  }
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
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

bool? _asNullableBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  return null;
}

String _asString(Object? value, {String defaultValue = ''}) {
  if (value is String) return value;
  return defaultValue;
}

String? _asNullableString(Object? value) {
  if (value is String) return value;
  return null;
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
