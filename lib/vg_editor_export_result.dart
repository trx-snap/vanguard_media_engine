// vg_editor_export_result.dart
// Vanguard Media Engine — Phase 7 Stage 7.7
//
// Immutable result produced by a successful VGEditorController.export() call.
//
// Design rules:
//   - Pure value type. No success flag — failures throw from the controller.
//   - fromMap unpacks the native result map returned from dev_timelineExport.
//   - toMap is provided for test serialisation and logging.

/// The result of a successful [VGEditorController.export] operation.
///
/// The controller throws a [PlatformException] or [StateError] on failure,
/// so [VGEditorExportResult] always represents a successful export — there
/// is no `success` field.
final class VGEditorExportResult {
  /// Creates an export result.
  ///
  /// [path] must be the absolute local path to the exported MP4 file.
  /// [durationSeconds] must be the measured duration of the output file
  /// as reported by the native compositor.
  const VGEditorExportResult({
    required this.path,
    required this.durationSeconds,
    this.width,
    this.height,
    this.fps,
    this.exportRoiSidecarPath,
  });

  // ── Fields ─────────────────────────────────────────────────────────────────

  /// Absolute local path to the exported MP4 file.
  final String path;

  /// Duration of the exported file in seconds, as measured by the native layer.
  final double durationSeconds;

  /// Width of the exported video in pixels, or null if not reported.
  final int? width;

  /// Height of the exported video in pixels, or null if not reported.
  final int? height;

  /// Frame rate of the exported video, or null if not reported.
  final int? fps;

  /// Absolute local path to the ROI sidecar emitted alongside the exported
  /// video, or null if not reported.
  final String? exportRoiSidecarPath;

  // ── Deserialisation ────────────────────────────────────────────────────────

  /// Creates a [VGEditorExportResult] from the native result map returned by
  /// the `dev_timelineExport` MethodChannel call.
  ///
  /// Returns `null` if the map is missing required fields (`path`,
  /// `durationSeconds`) or if `success` is explicitly false.
  ///
  /// Expected native map shape:
  /// ```json
  /// {
  ///   "success": true,
  ///   "path": "/tmp/vg_timeline_export_proof.mp4",
  ///   "durationSeconds": 10.0,
  ///   "width": 640,
  ///   "height": 360,
  ///   "fps": 30
  /// }
  /// ```
  static VGEditorExportResult? fromMap(Map<Object?, Object?> map) {
    // Treat explicit false as a failure — caller should throw.
    final success = map['success'] as bool? ?? true;
    if (!success) return null;

    final path = map['path'] as String?;
    final duration = (map['durationSeconds'] as num?)?.toDouble();
    if (path == null || path.isEmpty || duration == null) return null;

    return VGEditorExportResult(
      path: path,
      durationSeconds: duration,
      width: (map['width'] as num?)?.toInt(),
      height: (map['height'] as num?)?.toInt(),
      fps: (map['fps'] as num?)?.toInt(),
      exportRoiSidecarPath: map['exportRoiSidecarPath'] as String?,
    );
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this result to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'path': path,
    'durationSeconds': durationSeconds,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (fps != null) 'fps': fps,
    if (exportRoiSidecarPath != null)
      'exportRoiSidecarPath': exportRoiSidecarPath,
  };

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorExportResult &&
          other.path == path &&
          other.durationSeconds == durationSeconds &&
          other.width == width &&
          other.height == height &&
          other.fps == fps &&
          other.exportRoiSidecarPath == exportRoiSidecarPath;

  @override
  int get hashCode => Object.hash(
    path,
    durationSeconds,
    width,
    height,
    fps,
    exportRoiSidecarPath,
  );

  @override
  String toString() =>
      'VGEditorExportResult('
      'path: ${path.split('/').last}, '
      'duration: ${durationSeconds.toStringAsFixed(2)}s, '
      '${width != null ? '$width×$height' : 'dims: unknown'}, '
      'fps: ${fps ?? 'unknown'}, '
      'exportRoiSidecarPath: ${exportRoiSidecarPath ?? 'unknown'})';
}
