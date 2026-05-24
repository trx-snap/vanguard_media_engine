// vg_photo_capture_result.dart
// Vanguard Media Engine — Phase 6D.4
//
// VGPhotoCaptureResult is a typed, immutable result returned by
// [VGCameraSession.takePhotoResult()].
//
// Design constraints:
//   R-agnostic  — zero references to any Connects feature surface.
//   R-defensive — normalises all known key variants from the native map so
//                 callers are insulated from native-side key renaming.
//   R-forward   — preserves the full raw map for callers that need extra keys
//                 added in future native releases.
//   R-safe      — missing or malformed numeric values default to 0;
//                 missing string values default to empty string rather than
//                 null, ensuring the result is always non-null and usable.
//   R-no-io     — no file I/O, stat, image decode, or EXIF read is performed
//                 inside any constructor or factory.

// ─────────────────────────────────────────────────────────────────────────────
// VGPhotoCaptureResult
// ─────────────────────────────────────────────────────────────────────────────

/// Typed result from [VGCameraSession.takePhotoResult()].
///
/// Created via [VGPhotoCaptureResult.fromPath] (when native returns a bare
/// path string — current iOS and Android behaviour) or
/// [VGPhotoCaptureResult.fromMap] (for future native enrichment returning a
/// full metadata map).
///
/// ## Field semantics
/// - [filePath]  — absolute path of the captured JPEG on-device.
///                 Empty string if the native side omitted the path.
/// - [width]     — pixel width of the captured image; `0` until native
///                 enrichment provides this value.
/// - [height]    — pixel height of the captured image; `0` until native
///                 enrichment provides this value.
/// - [sizeBytes] — file size in bytes; `0` until native enrichment provides
///                 this value. Do not perform file I/O to backfill this.
/// - [format]    — encoding format string (e.g. `'jpeg'`); empty string when
///                 the native side does not report format.
/// - [raw]       — defensive copy of the original native map (or a minimal
///                 synthetic map when created via [fromPath]), for
///                 forward-compatibility with keys added in future native
///                 releases.
final class VGPhotoCaptureResult {
  /// Absolute path of the captured output file.
  ///
  /// Empty string when the native side did not include a path key.
  final String filePath;

  /// Pixel width of the captured image.
  ///
  /// `0` when the native side does not report image dimensions. This field
  /// will be populated once the native `takePhoto` handler is enriched to
  /// return a metadata map in a future release.
  final int width;

  /// Pixel height of the captured image.
  ///
  /// `0` when the native side does not report image dimensions. This field
  /// will be populated once the native `takePhoto` handler is enriched to
  /// return a metadata map in a future release.
  final int height;

  /// File size of the captured image in bytes.
  ///
  /// `0` when the native side does not report file size. Do not perform file
  /// I/O to backfill this value — callers that need file size must stat the
  /// [filePath] themselves.
  final int sizeBytes;

  /// Encoding format of the captured image (e.g. `'jpeg'`).
  ///
  /// Empty string when the native side does not report the format.
  final String format;

  /// Defensive copy of the raw native map.
  ///
  /// Preserved for forward-compatibility: future native releases may add keys
  /// not yet modelled as typed fields. Callers that need those keys can read
  /// them here without waiting for a package update.
  ///
  /// When created via [fromPath], this map contains at minimum
  /// `{'filePath': <path>}`.
  final Map<String, dynamic> raw;

  // ── Constructor ──────────────────────────────────────────────────────────────

  const VGPhotoCaptureResult({
    required this.filePath,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.format,
    required this.raw,
  });

  // ── Named constructor (bare-path native contract) ─────────────────────────────

  /// Wraps a bare file path string returned by the native `takePhoto` handler.
  ///
  /// This is the primary construction path for the current iOS and Android
  /// native implementations, which return a plain `String` (the output file
  /// path) rather than a metadata map.
  ///
  /// ## Defaults
  /// - [width], [height], [sizeBytes] — `0` (not available from native today).
  /// - [format] — `'jpeg'` when [path] is non-empty (both platforms encode
  ///   JPEG); empty string when [path] is empty.
  /// - [raw] — `{'filePath': path}`.
  VGPhotoCaptureResult.fromPath(String path)
    : filePath = path,
      width = 0,
      height = 0,
      sizeBytes = 0,
      format = path.isNotEmpty ? 'jpeg' : '',
      raw = {'filePath': path};

  // ── Factory (future map-based native contract) ────────────────────────────────

  /// Constructs a [VGPhotoCaptureResult] from a metadata map returned by a
  /// future-enriched native `takePhoto` handler.
  ///
  /// ## Path normalisation
  /// Checks the following keys in order, using the first non-empty string:
  ///   `filePath` → `path` → `outputPath`
  ///
  /// ## Width normalisation
  ///   `width` → `imageWidth`
  ///
  /// ## Height normalisation
  ///   `height` → `imageHeight`
  ///
  /// ## Size normalisation
  ///   `sizeBytes` → `fileSize` → `size`
  ///
  /// ## Format normalisation
  ///   `format` → `imageFormat`
  ///
  /// ## Numeric coercion
  /// All integer fields accept `int`, `double`, `num`, or a `String` that
  /// parses as a number. Malformed or missing values become `0`.
  factory VGPhotoCaptureResult.fromMap(Map<String, dynamic> map) {
    // ── Path ──────────────────────────────────────────────────────────────────
    final filePath = _firstString(map, const [
      'filePath',
      'path',
      'outputPath',
    ]);

    // ── Dimensions ────────────────────────────────────────────────────────────
    final width = _parseInt(map, const ['width', 'imageWidth']);
    final height = _parseInt(map, const ['height', 'imageHeight']);

    // ── Size ─────────────────────────────────────────────────────────────────
    final sizeBytes = _parseInt(map, const ['sizeBytes', 'fileSize', 'size']);

    // ── Format ────────────────────────────────────────────────────────────────
    final format = _firstString(map, const ['format', 'imageFormat']);

    return VGPhotoCaptureResult(
      filePath: filePath,
      width: width,
      height: height,
      sizeBytes: sizeBytes,
      format: format,
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
    'width': width,
    'height': height,
    'sizeBytes': sizeBytes,
    'format': format,
  };

  // ── Value semantics ──────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VGPhotoCaptureResult) return false;
    return filePath == other.filePath &&
        width == other.width &&
        height == other.height &&
        sizeBytes == other.sizeBytes &&
        format == other.format;
  }

  @override
  int get hashCode => Object.hash(filePath, width, height, sizeBytes, format);

  // ── Debug ────────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGPhotoCaptureResult(filePath: $filePath, '
      '${width}x$height, sizeBytes: $sizeBytes, format: $format)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal normalisation helpers
// ─────────────────────────────────────────────────────────────────────────────
// Duplicated from vg_recording_stats.dart intentionally — files are kept
// independent to avoid shared utility coupling between typed result types.

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
