// vg_editor_export_request.dart
// Vanguard Media Engine — Phase 7 Stage 7.7
//
// Immutable configuration for a VGEditorController export operation.
//
// Design rules:
//   - Pure value type. No rendering logic, no channel calls.
//   - Does NOT include dev-only flags (e.g. useRealVideoClips).
//     That concept is internal to the controller proof path.
//   - All fields are optional to allow incremental configuration.
//     The native layer applies its own defaults when fields are null.

/// Immutable configuration for a [VGEditorController.export] operation.
///
/// All fields are optional; the native layer applies defaults for any null
/// fields. In Phase 7.7 the native dev export route writes to a fixed temp
/// path internally — [outputPath] is accepted but the native layer may
/// override it with the proof path.
final class VGEditorExportRequest {
  /// Creates an export request configuration.
  ///
  /// All fields are optional. Pass only the fields you wish to override from
  /// the native defaults.
  const VGEditorExportRequest({
    this.outputPath,
    this.bitrateBps,
    this.width,
    this.height,
    this.fps,
  });

  // ── Fields ─────────────────────────────────────────────────────────────────

  /// Optional output file path for the exported MP4.
  ///
  /// If null, the native layer writes to its default temp location
  /// (typically `NSTemporaryDirectory/vg_timeline_export_proof.mp4`).
  final String? outputPath;

  /// Target video bitrate in bits per second.
  ///
  /// If null, the native layer uses its default (typically 4 Mbps).
  final int? bitrateBps;

  /// Target output video width in pixels.
  ///
  /// If null, the native layer uses the canvas width from the active draft.
  final int? width;

  /// Target output video height in pixels.
  ///
  /// If null, the native layer uses the canvas height from the active draft.
  final int? height;

  /// Target output frame rate.
  ///
  /// If null, the native layer uses the fps from the active draft.
  final int? fps;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this request to a JSON-compatible map.
  ///
  /// Null fields are omitted from the output — the native layer will apply
  /// its own defaults for any missing keys.
  Map<String, Object?> toMap() {
    final map = <String, Object?>{};
    if (outputPath != null) map['outputPath'] = outputPath;
    if (bitrateBps != null) map['bitrateBps'] = bitrateBps;
    if (width != null) map['width'] = width;
    if (height != null) map['height'] = height;
    if (fps != null) map['fps'] = fps;
    return map;
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this request with the specified fields replaced.
  VGEditorExportRequest copyWith({
    Object? outputPath = _kNoValue,
    int? bitrateBps,
    int? width,
    int? height,
    int? fps,
  }) {
    return VGEditorExportRequest(
      outputPath:
          outputPath == _kNoValue ? this.outputPath : outputPath as String?,
      bitrateBps: bitrateBps ?? this.bitrateBps,
      width: width ?? this.width,
      height: height ?? this.height,
      fps: fps ?? this.fps,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorExportRequest &&
          other.outputPath == outputPath &&
          other.bitrateBps == bitrateBps &&
          other.width == width &&
          other.height == height &&
          other.fps == fps;

  @override
  int get hashCode =>
      Object.hash(outputPath, bitrateBps, width, height, fps);

  @override
  String toString() => 'VGEditorExportRequest('
      'outputPath: $outputPath, '
      'bitrateBps: $bitrateBps, '
      'width: $width, '
      'height: $height, '
      'fps: $fps)';
}

// ── Sentinel for copyWith nullable fields ─────────────────────────────────────
const _kNoValue = Object();
