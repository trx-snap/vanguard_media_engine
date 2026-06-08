// vg_multicam_recording_stats.dart
// Vanguard Media Engine — MC-18
//
// VGMultiCamRecordingStats is a typed, immutable result returned by
// [VGCameraSession.stopMultiCamVideoRecording()].
//
// Design constraints (mirrors VGRecordingStats):
//   R-agnostic  — zero references to any Connects feature surface.
//   R-defensive — normalises all numeric fields via safe int/double coercion
//                 so callers are insulated from minor native-side type changes.
//   R-forward   — preserves the full raw map for callers that need extra keys
//                 added in future native releases.
//   R-safe      — missing or malformed numeric values default to 0 / 0.0;
//                 missing path defaults to empty string rather than null,
//                 ensuring the result is always non-null and usable.

// ─────────────────────────────────────────────────────────────────────────────
// VGMultiCamRecordingStats
// ─────────────────────────────────────────────────────────────────────────────

/// Typed result from [VGCameraSession.stopMultiCamVideoRecording()].
///
/// Created via [VGMultiCamRecordingStats.fromMap], which normalises all native
/// map values with safe numeric coercion so callers are isolated from minor
/// native-side type variations.
///
/// ## Field semantics
/// - [filePath]                    — absolute path of the completed MP4 on-device.
///                                   Empty string if the native side omitted the key.
/// - [durationSeconds]             — duration of the recording in seconds.
/// - [width]                       — output video width in pixels.
/// - [height]                      — output video height in pixels.
/// - [framesOffered]               — total frames offered to AVAssetWriter.
/// - [framesAppended]              — frames successfully appended.
/// - [framesDroppedWriterNotReady] — frames dropped due to writer backpressure.
/// - [writerStatus]                — native AVAssetWriterStatus integer.
///                                   `2` == AVAssetWriterStatusCompleted.
/// - [fileSizeBytes]               — output file size in bytes.
/// - [raw]                         — defensive copy of the original native map,
///                                   for forward-compatibility with keys added
///                                   in future native releases.
final class VGMultiCamRecordingStats {
  /// Absolute path of the completed MP4 output file.
  ///
  /// Empty string when the native side did not include a path key.
  final String filePath;

  /// Duration of the recording in seconds.
  final double durationSeconds;

  /// Output video width in pixels.
  final int width;

  /// Output video height in pixels.
  final int height;

  /// Total frames offered to AVAssetWriter.
  final int framesOffered;

  /// Frames successfully appended to the AVAssetWriter input.
  final int framesAppended;

  /// Frames dropped because the AVAssetWriterInput was not ready for more data.
  final int framesDroppedWriterNotReady;

  /// Native AVAssetWriterStatus integer value at recording completion.
  ///
  /// `2` corresponds to `AVAssetWriterStatusCompleted`.
  final int writerStatus;

  /// Output file size in bytes.
  final int fileSizeBytes;

  /// Defensive copy of the raw native map.
  ///
  /// Preserved for forward-compatibility: future native releases may add keys
  /// not yet modelled as typed fields. Callers that need those keys can read
  /// them here without waiting for a package update.
  final Map<String, dynamic> raw;

  // ── Constructor ─────────────────────────────────────────────────────────────

  const VGMultiCamRecordingStats({
    required this.filePath,
    required this.durationSeconds,
    required this.width,
    required this.height,
    required this.framesOffered,
    required this.framesAppended,
    required this.framesDroppedWriterNotReady,
    required this.writerStatus,
    required this.fileSizeBytes,
    required this.raw,
  });

  // ── Factory ─────────────────────────────────────────────────────────────────

  /// Constructs a [VGMultiCamRecordingStats] from the raw map returned by the
  /// native `stopMultiCamVideoRecording` method-channel handler.
  ///
  /// ## Numeric coercion
  /// All numeric fields accept `int`, `double`, `num`, or a `String` that
  /// parses as a number. Malformed or missing values become `0` / `0.0`.
  factory VGMultiCamRecordingStats.fromMap(Map<String, dynamic> map) {
    return VGMultiCamRecordingStats(
      filePath:                    _firstString(map, const ['filePath', 'path']),
      durationSeconds:             _parseDouble(map, const ['durationSeconds']),
      width:                       _parseInt(map, const ['width']),
      height:                      _parseInt(map, const ['height']),
      framesOffered:               _parseInt(map, const ['framesOffered']),
      framesAppended:              _parseInt(map, const ['framesAppended']),
      framesDroppedWriterNotReady: _parseInt(map, const ['framesDroppedWriterNotReady']),
      writerStatus:                _parseInt(map, const ['writerStatus']),
      fileSizeBytes:               _parseInt(map, const ['fileSizeBytes']),
      // Defensive copy: never expose the original map reference.
      raw:                         Map<String, dynamic>.from(map),
    );
  }

  // ── Debug ───────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGMultiCamRecordingStats('
      'filePath: $filePath, '
      'durationSeconds: $durationSeconds, '
      'dims: ${width}x$height, '
      'framesOffered: $framesOffered, '
      'framesAppended: $framesAppended, '
      'framesDroppedWriterNotReady: $framesDroppedWriterNotReady, '
      'writerStatus: $writerStatus, '
      'fileSizeBytes: $fileSizeBytes)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal normalisation helpers (file-private)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the first non-empty string found under any of [keys], or `''`.
String _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final v = map[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return '';
}

/// Returns the first parseable integer found under any of [keys], or `0`.
int _parseInt(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final v = map[key];
    if (v == null) continue;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is num) return v.toInt();
    if (v is String) {
      final parsed = int.tryParse(v) ?? double.tryParse(v)?.toInt();
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

/// Returns the first parseable double found under any of [keys], or `0.0`.
double _parseDouble(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final v = map[key];
    if (v == null) continue;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    if (v is String) {
      final parsed = double.tryParse(v);
      if (parsed != null) return parsed;
    }
  }
  return 0.0;
}
