// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.
//
// VGDuetExportResult: result type for exportDuetComposition (Slice 5B-A).
// Descriptor-bound offline export: no sessionId required.

// ─────────────────────────────────────────────────────────────────────────────
// Export result
// ─────────────────────────────────────────────────────────────────────────────

/// The result of a successful offline Duet composition export.
///
/// Returned by [VGDuetPlatformInterface.exportDuetComposition] on success.
/// All fields reflect the final, atomically renamed output file on disk.
class VGDuetExportResult {
  /// Absolute path of the finalized output MP4 (renamed from temp on success).
  final String outputPath;

  /// Duration of the exported video in milliseconds (> 0).
  final int durationMs;

  /// File size of the finalized output in bytes (> 0).
  final int fileSizeBytes;

  /// Constructs a [VGDuetExportResult].
  ///
  /// [durationMs] and [fileSizeBytes] must both be positive.
  VGDuetExportResult({
    required this.outputPath,
    required this.durationMs,
    required this.fileSizeBytes,
  }) {
    if (outputPath.trim().isEmpty) {
      throw ArgumentError.value(
        outputPath,
        'outputPath',
        'VGDuetExportResult: outputPath must not be blank.',
      );
    }
    if (durationMs <= 0) {
      throw ArgumentError.value(
        durationMs,
        'durationMs',
        'VGDuetExportResult: durationMs must be > 0.',
      );
    }
    if (fileSizeBytes <= 0) {
      throw ArgumentError.value(
        fileSizeBytes,
        'fileSizeBytes',
        'VGDuetExportResult: fileSizeBytes must be > 0.',
      );
    }
  }

  /// Serializes to a plain [Map] for method-channel / JSON transport.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'outputPath': outputPath,
    'durationMs': durationMs,
    'fileSizeBytes': fileSizeBytes,
  };

  /// Deserializes from a plain [Map] returned by the native reply.
  ///
  /// Throws [ArgumentError] when required keys are missing or have wrong types.
  factory VGDuetExportResult.fromMap(Map<String, dynamic> map) {
    final path = map['outputPath'];
    if (path is! String) {
      throw ArgumentError(
        'VGDuetExportResult.fromMap: missing or invalid "outputPath".',
      );
    }
    final rawDuration = map['durationMs'];
    if (rawDuration == null) {
      throw ArgumentError('VGDuetExportResult.fromMap: missing "durationMs".');
    }
    final rawSize = map['fileSizeBytes'];
    if (rawSize == null) {
      throw ArgumentError(
        'VGDuetExportResult.fromMap: missing "fileSizeBytes".',
      );
    }
    return VGDuetExportResult(
      outputPath: path,
      durationMs: (rawDuration as num).toInt(),
      fileSizeBytes: (rawSize as num).toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetExportResult &&
          outputPath == other.outputPath &&
          durationMs == other.durationMs &&
          fileSizeBytes == other.fileSizeBytes;

  @override
  int get hashCode => Object.hash(outputPath, durationMs, fileSizeBytes);

  @override
  String toString() =>
      'VGDuetExportResult(outputPath: $outputPath, '
      'durationMs: $durationMs, fileSizeBytes: $fileSizeBytes)';
}
