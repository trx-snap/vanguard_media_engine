// vg_recording_stats.dart
// Vanguard Media Engine — Phase 6D.3
//
// VGRecordingStats is a typed, immutable result returned by
// [VGCameraSession.stopRecording()].
//
// Design constraints:
//   R-agnostic  — zero references to any Connects feature surface.
//   R-defensive — normalises all known key variants from the native map so
//                 callers are insulated from native-side key renaming.
//   R-forward   — preserves the full raw map for callers that need extra keys
//                 added in future native releases.
//   R-safe      — missing or malformed numeric values default to 0 / 0.0;
//                 missing path defaults to empty string rather than null,
//                 ensuring the result is always non-null and usable.

// ─────────────────────────────────────────────────────────────────────────────
// VGRecordingStats
// ─────────────────────────────────────────────────────────────────────────────

/// Typed result from [VGCameraSession.stopRecording()].
///
/// Created via [VGRecordingStats.fromMap], which normalises all known native
/// key variants so callers are isolated from native-side key renaming.
///
/// ## Field semantics
/// - [filePath]      — absolute path of the completed MP4 on-device.
///                     Empty string if the native side omitted the path key.
/// - [droppedFrames] — frames the hardware encoder could not encode in time.
/// - [totalFrames]   — total frames presented to the encoder.
/// - [dropRate]      — `droppedFrames / totalFrames`; `0.0` when
///                     `totalFrames` is zero (avoids division-by-zero).
/// - [raw]           — defensive copy of the original native map, for
///                     forward-compatibility with keys added in future
///                     native releases.
final class VGRecordingStats {
  /// Absolute path of the completed output file.
  ///
  /// Empty string when the native side did not include a path key.
  final String filePath;

  /// Number of frames dropped by the hardware encoder.
  final int droppedFrames;

  /// Total number of frames presented to the hardware encoder.
  final int totalFrames;

  /// Ratio of [droppedFrames] to [totalFrames].
  ///
  /// `0.0` when [totalFrames] is zero (defensive; avoids division-by-zero).
  final double dropRate;

  /// Defensive copy of the raw native map.
  ///
  /// Preserved for forward-compatibility: future native releases may add keys
  /// not yet modelled as typed fields. Callers that need those keys can read
  /// them here without waiting for a package update.
  final Map<String, dynamic> raw;

  // ── Constructor ──────────────────────────────────────────────────────────────

  const VGRecordingStats({
    required this.filePath,
    required this.droppedFrames,
    required this.totalFrames,
    required this.dropRate,
    required this.raw,
  });

  // ── Factory ──────────────────────────────────────────────────────────────────

  /// Constructs a [VGRecordingStats] from the raw map returned by the native
  /// `stopRecording` method-channel handler.
  ///
  /// ## Path normalisation
  /// Checks the following keys in order, using the first non-empty string:
  ///   `filePath` → `path` → `outputPath`
  ///
  /// ## Frame count normalisation
  /// Dropped frames:  `droppedFrames` → `framesDropped` → `dropped`
  /// Total frames:    `totalFrames`   → `framesTotal`   → `presentedFrames` → `framesPresented`
  ///
  /// ## Drop-rate normalisation
  /// Drop rate:       `dropRate`      → `frameDropRate`
  ///
  /// ## Numeric coercion
  /// All numeric fields accept `int`, `double`, `num`, or a `String` that
  /// parses as a number. Malformed or missing values become `0` / `0.0`.
  factory VGRecordingStats.fromMap(Map<String, dynamic> map) {
    // ── Path ──────────────────────────────────────────────────────────────────
    final filePath = _firstString(map, const ['filePath', 'path', 'outputPath']);

    // ── Dropped frames ────────────────────────────────────────────────────────
    final droppedFrames = _parseInt(
      map,
      const ['droppedFrames', 'framesDropped', 'dropped'],
    );

    // ── Total frames ─────────────────────────────────────────────────────────
    final totalFrames = _parseInt(
      map,
      const ['totalFrames', 'framesTotal', 'presentedFrames', 'framesPresented'],
    );

    // ── Drop rate ─────────────────────────────────────────────────────────────
    final dropRate = _parseDouble(map, const ['dropRate', 'frameDropRate']);

    return VGRecordingStats(
      filePath: filePath,
      droppedFrames: droppedFrames,
      totalFrames: totalFrames,
      dropRate: dropRate,
      // Defensive copy: never expose the original map reference.
      raw: Map<String, dynamic>.from(map),
    );
  }

  // ── Serialisation ────────────────────────────────────────────────────────────

  /// Serialises the typed fields to a canonical JSON-compatible map.
  ///
  /// Keys are the canonical (primary) variants regardless of which key the
  /// native side used. The [raw] field is omitted to avoid duplication.
  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'droppedFrames': droppedFrames,
        'totalFrames': totalFrames,
        'dropRate': dropRate,
      };

  // ── Debug ────────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGRecordingStats(filePath: $filePath, dropped: $droppedFrames/'
      '$totalFrames, rate: ${dropRate.toStringAsFixed(4)})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal normalisation helpers
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
