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

  /// Wire name of the render backend actually used for this export
  /// (e.g. `"vulkan"` or `"gles"`), or `null` when not reported.
  final String? renderBackend;

  /// Wire name of the render backend the selector preferred before any
  /// runtime fallback, or `null` when not reported.
  final String? preferredRenderBackend;

  /// The selector's reason for its backend decision, or `null` when not
  /// reported.
  final String? renderBackendReason;

  /// The encoder failure reason that triggered a Vulkan-to-GLES runtime
  /// fallback, or `null` when no fallback occurred / not reported.
  final String? renderBackendFallbackReason;

  /// Whether the Vulkan backend was supported on this device, or `null`
  /// when not reported.
  final bool? vulkanSupported;

  /// Whether the GLES backend was supported on this device, or `null` when
  /// not reported.
  final bool? glesSupported;

  /// Constructs a [VGDuetExportResult].
  ///
  /// [durationMs] and [fileSizeBytes] must both be positive.
  VGDuetExportResult({
    required this.outputPath,
    required this.durationMs,
    required this.fileSizeBytes,
    this.renderBackend,
    this.preferredRenderBackend,
    this.renderBackendReason,
    this.renderBackendFallbackReason,
    this.vulkanSupported,
    this.glesSupported,
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
    'renderBackend': renderBackend,
    'preferredRenderBackend': preferredRenderBackend,
    'renderBackendReason': renderBackendReason,
    'renderBackendFallbackReason': renderBackendFallbackReason,
    'vulkanSupported': vulkanSupported,
    'glesSupported': glesSupported,
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
      renderBackend: map['renderBackend'] as String?,
      preferredRenderBackend: map['preferredRenderBackend'] as String?,
      renderBackendReason: map['renderBackendReason'] as String?,
      renderBackendFallbackReason:
          map['renderBackendFallbackReason'] as String?,
      vulkanSupported: map['vulkanSupported'] as bool?,
      glesSupported: map['glesSupported'] as bool?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetExportResult &&
          outputPath == other.outputPath &&
          durationMs == other.durationMs &&
          fileSizeBytes == other.fileSizeBytes &&
          renderBackend == other.renderBackend &&
          preferredRenderBackend == other.preferredRenderBackend &&
          renderBackendReason == other.renderBackendReason &&
          renderBackendFallbackReason == other.renderBackendFallbackReason &&
          vulkanSupported == other.vulkanSupported &&
          glesSupported == other.glesSupported;

  @override
  int get hashCode => Object.hash(
    outputPath,
    durationMs,
    fileSizeBytes,
    renderBackend,
    preferredRenderBackend,
    renderBackendReason,
    renderBackendFallbackReason,
    vulkanSupported,
    glesSupported,
  );

  @override
  String toString() =>
      'VGDuetExportResult(outputPath: $outputPath, '
      'durationMs: $durationMs, fileSizeBytes: $fileSizeBytes, '
      'renderBackend: $renderBackend, '
      'preferredRenderBackend: $preferredRenderBackend, '
      'renderBackendReason: $renderBackendReason, '
      'renderBackendFallbackReason: $renderBackendFallbackReason, '
      'vulkanSupported: $vulkanSupported, glesSupported: $glesSupported)';
}
