// vg_image_optimizer.dart
// Vanguard Media Engine — Phase 10-C Image Optimization Shared Media Stack.
//
// Typed Dart bridge for the native `optimizeImage` MethodChannel route.
//
// Design rules:
//   - Stateless. No instance state, no lifecycle.
//   - Does not depend on VGEditorController or any playback runtime.
//   - Does not depend on FFmpeg or any third-party codec library.
//   - The optional [channel] parameter enables test injection without
//     depending on the iOS/native runtime.
//   - Null/omitted fields in VGImageOptimizationRequest fall back to
//     native defaults. Non-nullable booleans use conservative defaults.
//
// Architecture boundary:
//   - UMF owns the contract/profile semantics (VGImageExportProfile).
//   - Vanguard owns the native implementation (VGImageExportSession,
//     VGTransformFilterNode, VanguardImageMediaSource).
//   - Connects is the product caller; it must not own core compression logic.
//
// MethodChannel map key names match the UMF contract exactly:
//   maxWidth, maxHeight, maxLongEdge, fileSizeTargetBytes,
//   stripMetadata, normalizeOrientation, colorPolicy, destinationIntent.

import 'package:flutter/services.dart';

// ── VGImageOptimizationRequest ─────────────────────────────────────────────────

/// Immutable request configuration for a [VanguardImageOptimizer.optimizeImage]
/// call.
///
/// Resize bounds are independently composable:
///   - [maxLongEdge] caps the longer dimension proportionally.
///   - [maxWidth] caps the width dimension proportionally.
///   - [maxHeight] caps the height dimension proportionally.
///
/// When multiple bounds are supplied, the native layer applies all of them
/// simultaneously (single-pass bounding-box downscale, no upscale, no crop,
/// aspect ratio preserved).
///
/// **Format strings:** `"jpeg"` / `"jpg"` (default), `"heic"`, `"png"`.
/// WebP, AVIF, JXL, and any other unknown strings are rejected with a
/// [PlatformException] (`UNSUPPORTED_FORMAT`).
final class VGImageOptimizationRequest {
  /// Creates an image optimization request.
  ///
  /// [sourcePath] is required and must be a non-empty absolute path to a
  /// readable local file. All other fields are optional.
  const VGImageOptimizationRequest({
    required this.sourcePath,
    this.outputPath,
    this.maxWidth,
    this.maxHeight,
    this.maxLongEdge,
    this.fileSizeTargetBytes,
    this.quality,
    this.format,
    this.stripMetadata = true,
    this.normalizeOrientation = true,
    this.colorPolicy,
    this.destinationIntent,
  });

  // ── Fields ──────────────────────────────────────────────────────────────────

  /// Absolute local path to the source image (JPEG / HEIC / PNG).
  ///
  /// Must be non-null and non-empty. The file must exist and be readable.
  final String sourcePath;

  /// Absolute local path for the output image file.
  ///
  /// If null, the native layer writes to a temporary file under
  /// `NSTemporaryDirectory()`. The caller is responsible for post-export
  /// cleanup of temporary files.
  final String? outputPath;

  /// Maximum pixel width of the output image.
  ///
  /// The native layer downscales proportionally so that `width <= maxWidth`.
  /// If the source is already narrower, no resize on this axis is applied.
  /// Combined with [maxHeight] and [maxLongEdge] using the most-restrictive
  /// bounding-box algorithm. Never upscales.
  final int? maxWidth;

  /// Maximum pixel height of the output image.
  ///
  /// The native layer downscales proportionally so that `height <= maxHeight`.
  /// If the source is already shorter, no resize on this axis is applied.
  /// Combined with [maxWidth] and [maxLongEdge] using the most-restrictive
  /// bounding-box algorithm. Never upscales.
  final int? maxHeight;

  /// Maximum pixel length of the longer image dimension (after resize).
  ///
  /// The native layer downscales proportionally so that
  /// `max(width, height) <= maxLongEdge`. If the source is already within
  /// this bound, no resize on this axis is applied.
  /// Combined with [maxWidth] and [maxHeight] using the most-restrictive
  /// bounding-box algorithm. Never upscales.
  ///
  /// If null and neither [maxWidth] nor [maxHeight] is set, no resize cap is
  /// applied (source dimensions are preserved, subject only to re-encoding).
  final int? maxLongEdge;

  /// Advisory soft target for output file size in bytes.
  ///
  /// **v1 behavior:** Parsed and accepted. Not enforced. The encoder reports
  /// actual [VGImageOptimizationResult.fileSizeBytes]. Iterative quality
  /// search to meet this target is deferred to v2.
  final int? fileSizeTargetBytes;

  /// Encode quality for lossy formats (JPEG, HEIC). Range: 0.0–1.0.
  ///
  /// 1.0 = maximum quality / largest file. Ignored for PNG (lossless).
  /// Native default: 0.80. Clamped to [0.0, 1.0] by the native layer.
  final double? quality;

  /// Output image format: `"jpeg"` / `"jpg"`, `"heic"`, or `"png"`.
  ///
  /// - `"jpg"` is normalised to `"jpeg"` natively.
  /// - HEIC falls back to JPEG on non-HEVC devices; the actual resolved
  ///   format is reported in [VGImageOptimizationResult.format].
  /// - WebP, AVIF, JXL, and unknown strings are rejected with a
  ///   [PlatformException] (`UNSUPPORTED_FORMAT`).
  ///
  /// If null, the native layer defaults to `"jpeg"`.
  final String? format;

  /// When true (default), EXIF metadata (GPS, device info, timestamps) is
  /// stripped from the output via the re-encode path.
  ///
  /// **v1 behavior:** Metadata is always stripped via re-encode regardless
  /// of this value, because v1 does not implement a metadata-preservation
  /// path. Passing `false` is accepted without error, but the output will
  /// still have metadata stripped. This will be corrected in v2.
  final bool stripMetadata;

  /// When true (default), physically rotates pixels to bake EXIF orientation
  /// into the output (via UIImage → CVPixelBuffer). The output will have EXIF
  /// orientation = up (neutral). Safe for upload targets that strip EXIF.
  ///
  /// **v1 behavior:** Orientation normalisation is always applied via the
  /// UIImage decode path, regardless of this value. Passing `false` is
  /// accepted without error, but the output will still have orientation
  /// normalised. This will be corrected in v2.
  final bool normalizeOrientation;

  /// Color space normalisation policy (advisory in v1).
  ///
  /// Example values: `"sdr_rec709"`, `"preserve"`.
  /// Parsed and logged; not enforced in v1.
  final String? colorPolicy;

  /// Declares the intended destination context of the upload (advisory in v1).
  ///
  /// Example values: `"story"`, `"timeline"`, `"chat"`, `"profile"`.
  /// Parsed and logged; not enforced in v1.
  final String? destinationIntent;

  // ── Serialisation ────────────────────────────────────────────────────────────

  /// Serialises this request to a MethodChannel-compatible map.
  ///
  /// Keys match the UMF contract exactly. Null optional fields are omitted;
  /// the native layer applies its documented defaults for missing keys.
  /// Non-nullable booleans are always included.
  Map<String, Object?> toMap() {
    final map = <String, Object?>{
      'sourcePath': sourcePath,
      // Non-nullable booleans: always serialised.
      'stripMetadata': stripMetadata,
      'normalizeOrientation': normalizeOrientation,
    };
    if (outputPath != null) map['outputPath'] = outputPath;
    if (maxWidth != null) map['maxWidth'] = maxWidth;
    if (maxHeight != null) map['maxHeight'] = maxHeight;
    if (maxLongEdge != null) map['maxLongEdge'] = maxLongEdge;
    if (fileSizeTargetBytes != null) {
      map['fileSizeTargetBytes'] = fileSizeTargetBytes;
    }
    if (quality != null) map['quality'] = quality;
    if (format != null) map['format'] = format;
    if (colorPolicy != null) map['colorPolicy'] = colorPolicy;
    if (destinationIntent != null) map['destinationIntent'] = destinationIntent;
    return map;
  }

  // ── Equality ─────────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGImageOptimizationRequest &&
          other.sourcePath == sourcePath &&
          other.outputPath == outputPath &&
          other.maxWidth == maxWidth &&
          other.maxHeight == maxHeight &&
          other.maxLongEdge == maxLongEdge &&
          other.fileSizeTargetBytes == fileSizeTargetBytes &&
          other.quality == quality &&
          other.format == format &&
          other.stripMetadata == stripMetadata &&
          other.normalizeOrientation == normalizeOrientation &&
          other.colorPolicy == colorPolicy &&
          other.destinationIntent == destinationIntent;

  @override
  int get hashCode => Object.hash(
        sourcePath,
        outputPath,
        maxWidth,
        maxHeight,
        maxLongEdge,
        fileSizeTargetBytes,
        quality,
        format,
        stripMetadata,
        normalizeOrientation,
        colorPolicy,
        destinationIntent,
      );

  @override
  String toString() => 'VGImageOptimizationRequest('
      'sourcePath: ${sourcePath.split('/').last}, '
      'outputPath: ${outputPath?.split('/').last}, '
      'maxWidth: $maxWidth, '
      'maxHeight: $maxHeight, '
      'maxLongEdge: $maxLongEdge, '
      'fileSizeTargetBytes: $fileSizeTargetBytes, '
      'quality: $quality, '
      'format: $format, '
      'stripMetadata: $stripMetadata, '
      'normalizeOrientation: $normalizeOrientation, '
      'colorPolicy: $colorPolicy, '
      'destinationIntent: $destinationIntent)';
}

// ── VGImageOptimizationResult ─────────────────────────────────────────────────

/// Immutable result of a successful [VanguardImageOptimizer.optimizeImage] call.
///
/// The optimizer throws a [PlatformException] or [StateError] on failure, so
/// [VGImageOptimizationResult] always represents a successful optimization.
final class VGImageOptimizationResult {
  /// Creates an image optimization result.
  const VGImageOptimizationResult({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.fileSizeBytes,
    required this.format,
  });

  // ── Fields ──────────────────────────────────────────────────────────────────

  /// Absolute local path to the optimized output image.
  final String outputPath;

  /// Width of the output image in pixels.
  final int width;

  /// Height of the output image in pixels.
  final int height;

  /// File size of the output image in bytes.
  final int fileSizeBytes;

  /// Actual encoding format used after platform resolution.
  ///
  /// May differ from the requested format (e.g. `"heic"` → `"jpeg"` on
  /// non-HEVC devices). Values: `"jpeg"`, `"heic"`, `"png"`.
  final String format;

  // ── Deserialisation ───────────────────────────────────────────────────────────

  /// Creates a [VGImageOptimizationResult] from the native result map.
  ///
  /// Returns `null` if required fields are missing, malformed, or if
  /// `success` is explicitly false.
  ///
  /// Expected native map shape:
  /// ```json
  /// {
  ///   "success": true,
  ///   "outputPath": "/tmp/vg_img_opt_abc.jpg",
  ///   "width": 1080,
  ///   "height": 1920,
  ///   "fileSizeBytes": 234000,
  ///   "format": "jpeg"
  /// }
  /// ```
  static VGImageOptimizationResult? fromMap(Map<Object?, Object?> map) {
    final success = map['success'] as bool? ?? true;
    if (!success) return null;

    final outputPath = map['outputPath'] as String?;
    final width = (map['width'] as num?)?.toInt();
    final height = (map['height'] as num?)?.toInt();
    final fileSizeBytes = (map['fileSizeBytes'] as num?)?.toInt();
    final format = map['format'] as String?;

    if (outputPath == null ||
        outputPath.isEmpty ||
        width == null ||
        height == null ||
        fileSizeBytes == null ||
        format == null) {
      return null;
    }

    return VGImageOptimizationResult(
      outputPath: outputPath,
      width: width,
      height: height,
      fileSizeBytes: fileSizeBytes,
      format: format,
    );
  }

  // ── Serialisation ─────────────────────────────────────────────────────────────

  /// Serialises this result to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
        'outputPath': outputPath,
        'width': width,
        'height': height,
        'fileSizeBytes': fileSizeBytes,
        'format': format,
      };

  // ── Equality ─────────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGImageOptimizationResult &&
          other.outputPath == outputPath &&
          other.width == width &&
          other.height == height &&
          other.fileSizeBytes == fileSizeBytes &&
          other.format == format;

  @override
  int get hashCode =>
      Object.hash(outputPath, width, height, fileSizeBytes, format);

  @override
  String toString() => 'VGImageOptimizationResult('
      'outputPath: ${outputPath.split('/').last}, '
      '$width x $height, '
      'fileSizeBytes: $fileSizeBytes, '
      'format: $format)';
}

// ── VanguardImageOptimizer ────────────────────────────────────────────────────

/// Shared media-stack image optimizer.
///
/// Invokes the `optimizeImage` native route on the `vanguard_media_engine`
/// MethodChannel. The native handler uses the V2 pull-mode pipeline:
///   - [VanguardImageMediaSource] for orientation-aware decoding (UIImage bake).
///   - [VGTransformFilterNode] for downscaling via CIImage/Metal.
///   - [VGImageExportSession] as the pull-mode still-image export coordinator.
///   - [VGImageEncoderSinkNode] for JPEG/HEIC/PNG encoding via ImageIO.
///
/// This is a stateless static API. No instance state, no lifecycle. Does not
/// depend on [VGEditorController], the playback runtime, or any preview texture.
///
/// **Resize:** The native layer applies a single-pass bounding-box downscale
/// honoring [VGImageOptimizationRequest.maxWidth],
/// [VGImageOptimizationRequest.maxHeight], and
/// [VGImageOptimizationRequest.maxLongEdge] simultaneously. Aspect ratio is
/// always preserved. Never upscales. Never crops.
///
/// **Metadata stripping:** EXIF metadata is implicitly stripped by the
/// re-encode path. The native handler does not copy metadata from the source.
///
/// **Orientation:** Orientation normalisation is applied via UIImage decode.
/// Output EXIF orientation is 1 (up / neutral).
///
/// **Format rejection:** Unsupported formats (webp, avif, jxl, unknown)
/// throw a [PlatformException] with code `UNSUPPORTED_FORMAT`. Never silently
/// falls back to JPEG for unknown format strings.
///
/// **Cancellation:** The native pipeline is not cancellable once started.
/// Post-export output cleanup is the caller's responsibility.
///
/// ```dart
/// final result = await VanguardImageOptimizer.optimizeImage(
///   request: VGImageOptimizationRequest(
///     sourcePath: '/path/to/source.jpg',
///     maxLongEdge: 1080,
///     quality: 0.82,
///     destinationIntent: 'story',
///   ),
/// );
/// print(result.outputPath);
/// print('${result.width}×${result.height} — ${result.fileSizeBytes} bytes');
/// ```
final class VanguardImageOptimizer {
  // Private constructor: stateless static API only.
  const VanguardImageOptimizer._();

  static const MethodChannel _defaultChannel =
      MethodChannel('vanguard_media_engine');

  /// Optimizes an image for upload.
  ///
  /// Applies bounding-box downscale (honoring all of [maxWidth], [maxHeight],
  /// [maxLongEdge]), normalises orientation, strips metadata via re-encode,
  /// and encodes to JPEG/HEIC/PNG at the specified quality.
  ///
  /// [request.sourcePath] must be a non-empty absolute path to a readable
  /// local image file.
  ///
  /// [channel] is optional and exists only for test injection. Production
  /// callers must not supply it.
  ///
  /// Returns a [VGImageOptimizationResult] on success.
  ///
  /// Throws [PlatformException] on native failure (unreadable source,
  /// unsupported format, encode error, etc.).
  /// Throws [StateError] if the native response is null or reports failure.
  static Future<VGImageOptimizationResult> optimizeImage({
    required VGImageOptimizationRequest request,
    MethodChannel channel = _defaultChannel,
  }) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'optimizeImage',
      request.toMap(),
    );

    if (result == null) {
      throw StateError(
        '[VanguardImageOptimizer] optimizeImage: native returned null result',
      );
    }

    final optimizationResult = VGImageOptimizationResult.fromMap(
      result.map((key, value) => MapEntry<Object?, Object?>(key, value)),
    );

    if (optimizationResult == null) {
      throw StateError(
        '[VanguardImageOptimizer] optimizeImage: native returned failure result',
      );
    }

    return optimizationResult;
  }
}
