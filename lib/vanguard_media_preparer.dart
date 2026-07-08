import 'dart:io';
import 'dart:math' show min;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;



// ─── Enums ────────────────────────────────────────────────────────────────────

enum MediaKind { video, image, audio, unknown }

/// The decision engine's outcome for a given input file.
enum PrepareOutcome {
  /// File is safe and optimal for upload — returned unchanged.
  passThrough,

  /// File quality is acceptable but container/metadata needs correction.
  /// Performed losslessly via passthrough remux / EXIF strip.
  normalized,

  /// File must be re-encoded to meet upload constraints.
  transcoded,

  /// File fails a hard validation rule and must not be uploaded.
  rejected,
}

// ─── MediaInfo ────────────────────────────────────────────────────────────────

/// Full probe result returned by [VanguardMediaPreparer.inspectMedia].
/// All fields are populated on both iOS and Android.
class MediaInfo {
  const MediaInfo({
    required this.kind,
    required this.container,
    required this.videoCodec,
    required this.audioCodec,
    required this.width,
    required this.height,
    required this.durationSeconds,
    required this.bitrateKbps,
    required this.fps,
    required this.fileSizeBytes,
    required this.hasVideo,
    required this.hasAudio,
    required this.isHDR,
    required this.hasMoovAtFront,
    required this.hasRotationTransform,
    required this.hasEmbeddedMetadata,
    // ── ROI-5A.1 Orientation Evidence ──────────────────────────────────────
    // Additive fields. Existing width/height remain encoded/raw (naturalSize).
    this.encodedWidth  = 0,
    this.encodedHeight = 0,
    this.displayWidth  = 0,
    this.displayHeight = 0,
    this.rotationDegrees,
    this.transformA  = 1.0,
    this.transformB  = 0.0,
    this.transformC  = 0.0,
    this.transformD  = 1.0,
    this.transformTx = 0.0,
    this.transformTy = 0.0,
    this.orientationStatus = 'valid',
  });

  final MediaKind kind;

  /// Container format: 'mp4', 'mov', 'mkv', 'webm', 'avi', 'jpeg', 'png', etc.
  final String container;

  /// Video codec: 'h264', 'hevc', 'vp9', 'av1', '' if no video track.
  final String videoCodec;

  /// Audio codec: 'aac', 'ac3', 'mp3', 'opus', '' if no audio track or unknown.
  final String audioCodec;

  /// Raw encoded pixel dimensions from the video track's naturalSize.
  /// These are the on-disk dimensions before any preferredTransform rotation is
  /// applied. Do NOT swap for rotated videos — use [displayWidth]/[displayHeight]
  /// when you need the correct display orientation.
  final int width;
  final int height;

  /// Duration in seconds. -1.0 if unreadable.
  final double durationSeconds;

  /// Video track bitrate in kbps. 0 if unknown.
  final int bitrateKbps;

  /// Nominal frame rate. 0.0 for images or if unknown.
  final double fps;

  final int fileSizeBytes;
  final bool hasVideo;
  final bool hasAudio;

  /// True if source contains BT.2020 color primaries (HDR).
  final bool isHDR;

  /// True if the MP4 moov atom is positioned at the file head (faststart).
  /// Conservative: always false until a native atom-walk parser is implemented.
  /// See implementation plan §B2.
  final bool hasMoovAtFront;

  /// True if the video track has a non-identity preferred transform
  /// (rotation metadata not baked into the pixel stream).
  final bool hasRotationTransform;

  /// True if the file contains embedded metadata (GPS, device info, etc.).
  final bool hasEmbeddedMetadata;

  // ── ROI-5A.1 Orientation Evidence (additive) ─────────────────────────────

  /// Raw encoded pixel width (same as [width]). Provided for semantic clarity
  /// in code that explicitly documents which dimension space it operates in.
  final int encodedWidth;

  /// Raw encoded pixel height (same as [height]). Provided for semantic clarity
  /// in code that explicitly documents which dimension space it operates in.
  final int encodedHeight;

  /// Display pixel width after applying the video track's preferredTransform.
  /// For 0°/180° rotation this equals [encodedWidth].
  /// For 90°/270° rotation this equals [encodedHeight].
  /// 0 if there is no video track.
  final int displayWidth;

  /// Display pixel height after applying the video track's preferredTransform.
  /// For 0°/180° rotation this equals [encodedHeight].
  /// For 90°/270° rotation this equals [encodedWidth].
  /// 0 if there is no video track.
  final int displayHeight;

  /// Rotation in degrees (0, 90, 180, or 270) for cardinal, non-mirrored
  /// transforms. Null for mirrored, non-cardinal, ambiguous, or missing tracks.
  final int? rotationDegrees;

  /// The six components of the video track's preferredTransform matrix.
  /// Default to identity (a=1,b=0,c=0,d=1,tx=0,ty=0) when not available.
  final double transformA;
  final double transformB;
  final double transformC;
  final double transformD;
  final double transformTx;
  final double transformTy;

  /// Classification of the orientation metadata:
  /// - 'valid'        : Supported cardinal rotation (0/90/180/270), no mirroring.
  /// - 'validMirrored': Cardinal rotation + horizontal mirror (e.g. front camera).
  ///                    ROI is blocked until a mirror coordinate policy is defined.
  /// - 'ambiguous'    : Non-orthogonal matrix, shear, non-unit scale, or degenerate.
  ///                    ROI must not be generated for ambiguous videos.
  /// - 'noVideoTrack' : No video track exists.
  /// Defaults to 'valid' so that older native responses remain fully compatible.
  final String orientationStatus;

  /// True when the display height is greater than the display width.
  bool get isPortraitDisplay => displayHeight > displayWidth;

  /// True when the display width is greater than or equal to the display height.
  bool get isLandscapeDisplay => displayWidth >= displayHeight;

  int get shortestSide => min(width, height);

  static MediaInfo _fromRaw(Map<dynamic, dynamic> raw) {
    final kindStr = raw['kind'] as String? ?? 'unknown';
    final kind = switch (kindStr) {
      'video' => MediaKind.video,
      'image' => MediaKind.image,
      'audio' => MediaKind.audio,
      _       => MediaKind.unknown,
    };
    final rawWidth  = (raw['width']  as num?)?.toInt() ?? 0;
    final rawHeight = (raw['height'] as num?)?.toInt() ?? 0;
    return MediaInfo(
      kind:                  kind,
      container:             raw['container']             as String? ?? '',
      videoCodec:            raw['videoCodec']            as String? ?? '',
      audioCodec:            raw['audioCodec']            as String? ?? '',
      width:                 rawWidth,
      height:                rawHeight,
      durationSeconds:       (raw['durationSeconds']      as num?)?.toDouble() ?? -1.0,
      bitrateKbps:           (raw['bitrateKbps']          as num?)?.toInt() ?? 0,
      fps:                   (raw['fps']                  as num?)?.toDouble() ?? 0.0,
      fileSizeBytes:         (raw['fileSizeBytes']        as num?)?.toInt() ?? 0,
      hasVideo:              raw['hasVideo']              as bool? ?? false,
      hasAudio:              raw['hasAudio']              as bool? ?? false,
      isHDR:                 raw['isHDR']                 as bool? ?? false,
      hasMoovAtFront:        raw['hasMoovAtFront']        as bool? ?? false,
      hasRotationTransform:  raw['hasRotationTransform']  as bool? ?? false,
      hasEmbeddedMetadata:   raw['hasEmbeddedMetadata']   as bool? ?? false,
      // ROI-5A.1 Orientation Evidence — fall back to raw width/height when
      // the native side does not yet return these keys (older plugin builds).
      encodedWidth:     (raw['encodedWidth']     as num?)?.toInt() ?? rawWidth,
      encodedHeight:    (raw['encodedHeight']    as num?)?.toInt() ?? rawHeight,
      displayWidth:     (raw['displayWidth']     as num?)?.toInt() ?? rawWidth,
      displayHeight:    (raw['displayHeight']    as num?)?.toInt() ?? rawHeight,
      rotationDegrees:  (raw['rotationDegrees']  as num?)?.toInt(),
      transformA:  (raw['transformA']  as num?)?.toDouble() ?? 1.0,
      transformB:  (raw['transformB']  as num?)?.toDouble() ?? 0.0,
      transformC:  (raw['transformC']  as num?)?.toDouble() ?? 0.0,
      transformD:  (raw['transformD']  as num?)?.toDouble() ?? 1.0,
      transformTx: (raw['transformTx'] as num?)?.toDouble() ?? 0.0,
      transformTy: (raw['transformTy'] as num?)?.toDouble() ?? 0.0,
      orientationStatus: raw['orientationStatus'] as String? ?? 'valid',
    );
  }

  @override
  String toString() =>
      'MediaInfo(kind=$kind container=$container codec=$videoCodec '
      '${width}x$height ${durationSeconds.toStringAsFixed(1)}s '
      '${bitrateKbps}kbps HDR=$isHDR rotation=$hasRotationTransform '
      'orientation=$orientationStatus display=${displayWidth}x$displayHeight meta=$hasEmbeddedMetadata)';
}

// ─── UploadConstraints ───────────────────────────────────────────────────────

/// Per-surface upload limits. Use named constructors for each upload surface.
class UploadConstraints {
  const UploadConstraints({
    required this.maxDurationSeconds,
    required this.maxShortSidePx,
    required this.maxBitrateKbps,
    required this.maxFileSizeMb,
    required this.targetBitrateKbps,
    required this.imageMaxWidthPx,
    required this.imageJpegQuality,
  });

  final int maxDurationSeconds;
  final int maxShortSidePx;
  final int maxBitrateKbps;
  final int maxFileSizeMb;
  final int targetBitrateKbps;
  final int imageMaxWidthPx;

  /// JPEG quality in 0.0–1.0 range (passed to native and normalized as needed).
  final double imageJpegQuality;

  /// Post / feed video. Mirrors file_compress.dart limits.
  const UploadConstraints.post()
      : maxDurationSeconds = 180,
        maxShortSidePx     = 720,
        maxBitrateKbps     = 1500,
        maxFileSizeMb      = 200,
        targetBitrateKbps  = 1000,
        imageMaxWidthPx    = 1080,
        imageJpegQuality   = 0.82;

  const UploadConstraints.reels()
      : maxDurationSeconds = 180,
        maxShortSidePx     = 720,
        maxBitrateKbps     = 1500,
        maxFileSizeMb      = 200,
        targetBitrateKbps  = 1000,
        imageMaxWidthPx    = 1080,
        imageJpegQuality   = 0.82;

  const UploadConstraints.chat()
      : maxDurationSeconds = 180,
        maxShortSidePx     = 720,
        maxBitrateKbps     = 1500,
        maxFileSizeMb      = 200,
        targetBitrateKbps  = 1000,
        imageMaxWidthPx    = 1080,
        imageJpegQuality   = 0.82;

  /// Gallery-picked story clip. Camera clips bypass this via alreadyExported gate.
  const UploadConstraints.story()
      : maxDurationSeconds = 30,
        maxShortSidePx     = 720,
        maxBitrateKbps     = 1500,
        maxFileSizeMb      = 200,
        targetBitrateKbps  = 1000,
        imageMaxWidthPx    = 1080,
        imageJpegQuality   = 0.82;
}

// ─── UploadPolicy ─────────────────────────────────────────────────────────────

/// Behavioural flags that control how [VanguardMediaPreparer.prepareForUpload]
/// handles edge cases. Use named constructors for common configurations.
class UploadPolicy {
  const UploadPolicy({
    required this.stripMetadata,
    required this.requireFastStart,
    required this.allowNormalize,
    required this.allowPassThrough,
  });

  /// True: strip GPS/device EXIF from images and embedded metadata from videos.
  final bool stripMetadata;

  /// True: ensure moov atom is at the file head (required for server-side streaming).
  final bool requireFastStart;

  /// True: allow lossless remux/normalize instead of full re-encode when eligible.
  final bool allowNormalize;

  /// True: allow returning the input file unchanged when it already meets all constraints.
  final bool allowPassThrough;

  /// Default policy for all upload surfaces.
  const UploadPolicy.standard()
      : stripMetadata    = true,
        requireFastStart = true,
        allowNormalize   = true,
        allowPassThrough = true;

  /// Strict policy: always normalize at minimum. Never return raw input file.
  const UploadPolicy.strict()
      : stripMetadata    = true,
        requireFastStart = true,
        allowNormalize   = true,
        allowPassThrough = false;
}

// ─── PrepareResult ────────────────────────────────────────────────────────────

class PrepareResult {
  const PrepareResult({
    required this.file,
    required this.info,
    required this.outcome,
    this.tempPath,
    this.error,
  });

  /// The file ready for upload (may be the original input if outcome is passThrough).
  final File file;

  /// Full inspection result for the source file.
  final MediaInfo info;

  final PrepareOutcome outcome;

  /// Non-null when a temporary output file was created. Track for cleanup.
  final String? tempPath;

  /// Non-null only when outcome == rejected.
  final String? error;

  bool get succeeded => outcome != PrepareOutcome.rejected;

  PrepareResult._reject(this.info, this.error)
      : file    = File(''),
        outcome = PrepareOutcome.rejected,
        tempPath = null;
}

// ─── Exceptions ───────────────────────────────────────────────────────────────

/// Thrown by [VanguardMediaPreparer.prepareForUpload] when the source video
/// exceeds [UploadConstraints.maxDurationSeconds].
/// Replaces [VideoTooLongException] from file_compress.dart.
class MediaTooLongException implements Exception {
  const MediaTooLongException(this.actualSeconds, this.maxSeconds);
  final double actualSeconds;
  final int maxSeconds;

  @override
  String toString() =>
      'MediaTooLongException: ${actualSeconds.toStringAsFixed(1)}s '
      'exceeds ${maxSeconds}s limit';
}

// ─── VanguardMediaPreparer ───────────────────────────────────────────────────

/// Universal upload preprocessing pipeline.
///
/// SECURITY NOTE: Client-side processing is a compatibility and quality
/// normalization step only. Server-side validation (format, content, size,
/// moderation) remains a mandatory separate gate. Client re-encode does not
/// constitute a content safety guarantee.
class VanguardMediaPreparer {
  static const _channel = MethodChannel('vanguard_media_engine');

  static final List<String> _tempPaths = [];

  // ── inspectMedia ──────────────────────────────────────────────────────────

  /// Inspects a local media file and returns full [MediaInfo].
  /// Returns null if the file is missing, empty, or unreadable.
  ///
  /// Uses the native `inspectMedia` method channel case on both platforms.
  /// Does not call FFmpegKit.
  static Future<MediaInfo?> inspectMedia(String path) async {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() == 0) return null;

    // Fast-path MIME type from extension for kind detection (matches existing
    // lookupMimeType usage in file_compress.dart:221).
    // Native call follows for actual track-level info.
    try {
      final raw = await _channel.invokeMethod<Map>('inspectMedia', {'path': path});
      if (raw == null) return null;
      return MediaInfo._fromRaw(raw);
    } on PlatformException catch (e) {
      debugPrint('VanguardMediaPreparer.inspectMedia error: ${e.message}');
      return null;
    }
  }

  // ── extractDisplayOrientedFrameEvidence ───────────────────────────────────

  /// ROI-5B.1 — Diagnostic method for imported media orientation evidence.
  ///
  /// Extracts a single frame from [videoPath] using the native platform decoder
  /// and returns the decoded pixel dimensions, extraction method, and rotation
  /// handling metadata. This proves that the native pipeline produces
  /// display-oriented frames whose dimensions match [MediaInfo.displayWidth] /
  /// [MediaInfo.displayHeight] from [inspectMedia].
  ///
  /// **This method is diagnostic only.** It does not perform face detection,
  /// generate ROI sidecars, write files, or encode images. The bitmap/CGImage
  /// is immediately recycled after dimension retrieval.
  ///
  /// Returns null if:
  /// - The file does not exist or is empty.
  /// - Native frame extraction fails (corrupt file, no video track, etc.).
  ///
  /// Expected returned keys:
  /// - `extractedFrameWidth` (int): decoded frame pixel width
  /// - `extractedFrameHeight` (int): decoded frame pixel height
  /// - `method` (String): native extraction mechanism used
  /// - `rotationHandling` (String): how rotation was applied
  /// - `displayTransformApplied` (bool?): whether preferredTransform was applied
  /// - `requestedTimeSeconds` (double): timestamp requested (always 0.0)
  /// - `actualTimeSeconds` (double, iOS only): actual frame timestamp decoded
  static Future<Map<String, dynamic>?> extractDisplayOrientedFrameEvidence({
    required String videoPath,
  }) async {
    final file = File(videoPath);
    if (!file.existsSync() || file.lengthSync() == 0) return null;

    try {
      final raw = await _channel.invokeMethod<Map>(
        'extractDisplayOrientedFrameEvidence',
        {'videoPath': videoPath},
      );
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException catch (e) {
      debugPrint(
        'VanguardMediaPreparer.extractDisplayOrientedFrameEvidence error: '
        '${e.message}',
      );
      return null;
    }
  }

  // ── extractImportedFaceScanEvidence ───────────────────────────────────────

  /// ROI-5C.1 — Diagnostic method for imported face scan evidence (iOS only).
  ///
  /// Extracts one display-oriented frame from [videoPath] using
  /// [AVAssetImageGenerator] with `appliesPreferredTrackTransform = true`
  /// (same path as [extractDisplayOrientedFrameEvidence]) and then runs
  /// Apple Vision [VNDetectFaceRectanglesRequest] on that display-oriented
  /// frame with orientation `.up`.
  ///
  /// Returns face bounding boxes in three coordinate spaces per face:
  /// - Vision raw (bottom-left normalized origin, Vision convention)
  /// - Top-left normalized: `normalizedY = 1.0 - visionY - visionHeight`
  /// - Display pixel: `normalizedX * frameWidth`, `normalizedY * frameHeight`
  ///
  /// **This method is diagnostic only.** It does not generate ROI sidecars,
  /// write files, perform landmarks, or alter any export/capture path.
  ///
  /// **Android is not supported** for this slice — Android ROI-5C is blocked
  /// until Android ROI-5B frame-extraction physical smoke passes. On Android,
  /// the native side returns a [PlatformException] with code
  /// `UNSUPPORTED_PLATFORM`, which is caught here and returned as null.
  ///
  /// Returns null if:
  /// - The file does not exist or is empty.
  /// - Native frame extraction or Vision detection fails.
  ///
  /// Expected returned map keys:
  /// - `frameWidth` (int): display-oriented frame pixel width
  /// - `frameHeight` (int): display-oriented frame pixel height
  /// - `method` (String): `'VNDetectFaceRectanglesRequest'`
  /// - `frameExtractionMethod` (String): `'AVAssetImageGenerator'`
  /// - `visionOrientation` (String): `'up'`
  /// - `coordinateSpace` (String): `'displayTopLeftNormalizedAndPixels'`
  /// - `faceCount` (int): number of faces detected (0 is valid — no error)
  /// - `faces` (List): one map per face, each with:
  ///   - `index`, `visionX`, `visionY`, `visionWidth`, `visionHeight`
  ///   - `normalizedX`, `normalizedY`, `normalizedWidth`, `normalizedHeight`
  ///   - `pixelX`, `pixelY`, `pixelWidth`, `pixelHeight`
  ///   - `clamped` (bool): true if any value was clamped to [0,1] range
  /// - `requestedTimeSeconds` (double): timestamp requested (always 0.0)
  /// - `actualTimeSeconds` (double): actual frame timestamp decoded
  static Future<Map<String, dynamic>?> extractImportedFaceScanEvidence({
    required String videoPath,
  }) async {
    final file = File(videoPath);
    if (!file.existsSync() || file.lengthSync() == 0) return null;

    try {
      final raw = await _channel.invokeMethod<Map>(
        'extractImportedFaceScanEvidence',
        {'videoPath': videoPath},
      );
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } on PlatformException catch (e) {
      debugPrint(
        'VanguardMediaPreparer.extractImportedFaceScanEvidence error: '
        '${e.message}',
      );
      return null;
    }
  }

  // ── prepareForUpload ──────────────────────────────────────────────────────

  /// Universal upload preparation pipeline.
  ///
  /// Inspect → Validate → Classify → Execute.
  ///
  /// For the current implementation wave (Steps 1–7):
  /// - Image compress path: native `compressImage` on both platforms.
  /// - Video transcode path: temporary fallback to [compressFile] from
  ///   file_compress.dart until `compressVideo` and `normalizeVideo` native
  ///   handlers are implemented (plan steps 8–9, iOS only first).
  ///
  /// Throws [MediaTooLongException] if video exceeds [constraints.maxDurationSeconds].
  ///
  /// [videoFallback] is a temporary injection point for FFmpegKit-backed video
  /// compression. Pass your existing `compressFile` function here until native
  /// `compressVideo` and `normalizeVideo` handlers are implemented (plan steps 8–9).
  /// When those are done, remove this parameter.
  static Future<PrepareResult> prepareForUpload(
    File input,
    UploadConstraints constraints,
    UploadPolicy policy, {
    void Function(double progress)? onProgress,
    Future<File> Function(File, {void Function(double)? onProgress})? videoFallback,
  }) async {
    // ── Step 1: Inspect ──────────────────────────────────────────────────────
    final info = await inspectMedia(input.path);
    if (info == null) {
      return PrepareResult._reject(
        // Return a minimal fallback info for the rejected result
        const MediaInfo(
          kind: MediaKind.unknown, container: '', videoCodec: '', audioCodec: '',
          width: 0, height: 0, durationSeconds: -1, bitrateKbps: 0, fps: 0,
          fileSizeBytes: 0, hasVideo: false, hasAudio: false, isHDR: false,
          hasMoovAtFront: false, hasRotationTransform: false, hasEmbeddedMetadata: false,
          // Orientation evidence defaults — safe for rejected/unknown files.
          orientationStatus: 'noVideoTrack',
        ),
        'File is missing or unreadable',
      );
    }

    // ── Step 2: Validate ─────────────────────────────────────────────────────
    if (info.kind == MediaKind.unknown) {
      return PrepareResult._reject(info, 'Unsupported media format');
    }

    if (info.kind == MediaKind.video) {
      if (info.durationSeconds > 0 &&
          info.durationSeconds > constraints.maxDurationSeconds) {
        throw MediaTooLongException(
            info.durationSeconds, constraints.maxDurationSeconds);
      }
    }

    if (info.fileSizeBytes > constraints.maxFileSizeMb * 1024 * 1024) {
      return PrepareResult._reject(
          info, 'File exceeds ${constraints.maxFileSizeMb}MB limit');
    }

    // ── Step 3: Classify and execute ─────────────────────────────────────────
    switch (info.kind) {
      case MediaKind.video:
        return _handleVideo(input, info, constraints, policy, onProgress, videoFallback);

      case MediaKind.image:
        return _handleImage(input, info, constraints, policy);

      case MediaKind.audio:
        // No audio compression spec yet — pass through unchanged.
        return PrepareResult(
            file: input, info: info, outcome: PrepareOutcome.passThrough);

      case MediaKind.unknown:
        return PrepareResult._reject(info, 'Unsupported media format');
    }
  }

  // ── cleanupTempFiles ──────────────────────────────────────────────────────

  /// Deletes all temporary files created by [prepareForUpload].
  /// Call after upload completes (success or failure).
  /// Mirrors [cleanupCompressedFiles] from file_compress.dart.
  static Future<void> cleanupTempFiles() async {
    final toDelete = List<String>.from(_tempPaths);
    _tempPaths.clear();
    for (final path in toDelete) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        debugPrint('VanguardMediaPreparer.cleanupTempFiles: failed to delete $path — $e');
      }
    }
  }

  // ── Video handler ─────────────────────────────────────────────────────────

  static Future<PrepareResult> _handleVideo(
    File input,
    MediaInfo info,
    UploadConstraints constraints,
    UploadPolicy policy,
    void Function(double)? onProgress,
    Future<File> Function(File, {void Function(double)? onProgress})? videoFallback,
  ) async {
    final outcome = _classifyVideo(info, constraints, policy);

    switch (outcome) {
      case PrepareOutcome.passThrough:
        return PrepareResult(
            file: input, info: info, outcome: PrepareOutcome.passThrough);

      case PrepareOutcome.normalized:
        // iOS: native normalizeVideo handler (AVAssetExportPresetPassthrough).
        // Android: falls back to videoFallback (FFmpegKit) until native handler exists.
        if (Platform.isIOS) {
          return _normalizeVideoNative(input: input, info: info);
        }
        debugPrint(
            'VanguardMediaPreparer: normalize fallback (Android) '
            'for ${p.basename(input.path)}');
        if (videoFallback != null) return _runVideoFallback(input, info, onProgress, videoFallback);
        // No fallback: pass through rather than block upload.
        return PrepareResult(file: input, info: info, outcome: PrepareOutcome.passThrough);

      case PrepareOutcome.transcoded:
        // iOS native compressVideo handler not yet implemented (plan step 8).
        // Temporary fallback: if caller provides videoFallback, use it.
        // TODO(step-8): replace with native compressVideo on iOS;
        //               Android retains this fallback until hardware validation.
        debugPrint(
            'VanguardMediaPreparer: transcode fallback '
            'for ${p.basename(input.path)} '
            '(native compressVideo pending plan step 8)');
        if (videoFallback != null) return _runVideoFallback(input, info, onProgress, videoFallback);
        return PrepareResult(file: input, info: info, outcome: PrepareOutcome.transcoded);

      case PrepareOutcome.rejected:
        return PrepareResult._reject(info, 'Video failed validation');
    }
  }

  static Future<PrepareResult> _runVideoFallback(
    File input,
    MediaInfo info,
    void Function(double)? onProgress,
    Future<File> Function(File, {void Function(double)? onProgress}) fallback,
  ) async {
    final compressed = await fallback(input, onProgress: onProgress);
    final tempOut = compressed.path != input.path ? compressed.path : null;
    if (tempOut != null) _tempPaths.add(tempOut);
    return PrepareResult(
      file:     compressed,
      info:     info,
      outcome:  PrepareOutcome.transcoded,
      tempPath: tempOut,
    );
  }

  /// Calls the native `normalizeVideo` handler.
  /// iOS only. Performs lossless passthrough remux:
  /// - moov repositioned to file head (faststart)
  /// - privacy metadata stripped via AVMetadataItemFilter.forSharing()
  /// - container-level rotation preserved (no pixel bake)
  /// - video/audio samples unchanged
  static Future<PrepareResult> _normalizeVideoNative({
    required File input,
    required MediaInfo info,
  }) async {
    final dir      = p.dirname(input.path);
    final baseName = p.basenameWithoutExtension(input.path);
    final outPath  = p.join(dir, '${baseName}_vg_normalized.mp4');

    try {
      final raw = await _channel.invokeMethod<Map>('normalizeVideo', {
        'inputPath':  input.path,
        'outputPath': outPath,
      });

      if (raw == null || raw['outputPath'] == null) {
        debugPrint('VanguardMediaPreparer.normalizeVideo: native returned null — using original');
        return PrepareResult(
            file: input, info: info, outcome: PrepareOutcome.passThrough);
      }

      final outFile = File(raw['outputPath'] as String);
      _tempPaths.add(outPath);
      return PrepareResult(
        file:     outFile,
        info:     info,
        outcome:  PrepareOutcome.normalized,
        tempPath: outPath,
      );
    } on PlatformException catch (e) {
      // EXPORT_UNAVAILABLE means the asset format is incompatible with
      // AVAssetExportPresetPassthrough (e.g. MKV, WebM containers).
      // EXPORT_FAILED means the export started but failed mid-run.
      // In both cases: pass original through rather than blocking upload.
      // TODO: escalate EXPORT_UNAVAILABLE to compressVideo once that handler exists.
      debugPrint(
          'VanguardMediaPreparer.normalizeVideo PlatformException [${e.code}]: '
          '${e.message} — using original for ${p.basename(input.path)}');
      // Clean up any partial output the native side may have written before failing.
      try {
        final partial = File(outPath);
        if (partial.existsSync()) partial.deleteSync();
      } catch (_) {
        // Best-effort — ignore secondary cleanup failure
      }
      return PrepareResult(
          file: input, info: info, outcome: PrepareOutcome.passThrough);
    }
  }

  // ── Image handler ─────────────────────────────────────────────────────────


  static Future<PrepareResult> _handleImage(
    File input,
    MediaInfo info,
    UploadConstraints constraints,
    UploadPolicy policy,
  ) async {
    final outcome = _classifyImage(info, constraints, policy);

    switch (outcome) {
      case PrepareOutcome.passThrough:
        return PrepareResult(
            file: input, info: info, outcome: PrepareOutcome.passThrough);

      case PrepareOutcome.normalized:
        // Image normalize = EXIF strip only, no resize.
        // For now: use compressImage with the same width (no downscale) to strip metadata.
        // TODO: add a lightweight native EXIF-strip-only path that avoids pixel re-encode.
        return _compressImageNative(
          input: input,
          info:  info,
          maxWidthPx:  info.width > 0 ? info.width : constraints.imageMaxWidthPx,
          jpegQuality: constraints.imageJpegQuality,
        );

      case PrepareOutcome.transcoded:
        return _compressImageNative(
          input:       input,
          info:        info,
          maxWidthPx:  constraints.imageMaxWidthPx,
          jpegQuality: constraints.imageJpegQuality,
        );

      case PrepareOutcome.rejected:
        return PrepareResult._reject(info, 'Image failed validation');
    }
  }

  static Future<PrepareResult> _compressImageNative({
    required File input,
    required MediaInfo info,
    required int maxWidthPx,
    required double jpegQuality,
  }) async {
    // Build output path: same dir, _compressed suffix, always .jpg
    final dir      = p.dirname(input.path);
    final baseName = p.basenameWithoutExtension(input.path);
    final outPath  = p.join(dir, '${baseName}_vg_compressed.jpg');

    try {
      final raw = await _channel.invokeMethod<Map>('compressImage', {
        'inputPath':   input.path,
        'outputPath':  outPath,
        'maxWidthPx':  maxWidthPx,
        'jpegQuality': jpegQuality,
      });

      if (raw == null || raw['outputPath'] == null) {
        // Fallback: return original image rather than throwing
        debugPrint('VanguardMediaPreparer.compressImage: native returned null — using original');
        return PrepareResult(
            file: input, info: info, outcome: PrepareOutcome.passThrough);
      }

      final outFile = File(raw['outputPath'] as String);
      _tempPaths.add(outPath);
      return PrepareResult(
        file:     outFile,
        info:     info,
        outcome:  PrepareOutcome.transcoded,
        tempPath: outPath,
      );
    } on PlatformException catch (e) {
      debugPrint('VanguardMediaPreparer.compressImage PlatformException: ${e.message} — using original');
      return PrepareResult(
          file: input, info: info, outcome: PrepareOutcome.passThrough);
    }
  }

  // ── Classification logic (pure Dart, no native calls) ────────────────────

  /// Determines which outcome applies to a video file.
  /// See implementation plan §C for full decision model.
  static PrepareOutcome _classifyVideo(
    MediaInfo info,
    UploadConstraints constraints,
    UploadPolicy policy,
  ) {
    if (!info.hasVideo) return PrepareOutcome.rejected;

    // Transcode triggers — codec or resolution or bitrate unacceptable
    final isH264 = info.videoCodec == 'h264' || info.videoCodec == 'avc';
    if (!isH264) return PrepareOutcome.transcoded;

    if (info.shortestSide > constraints.maxShortSidePx) {
      return PrepareOutcome.transcoded;
    }

    if (info.bitrateKbps > 0 && info.bitrateKbps > constraints.maxBitrateKbps) {
      return PrepareOutcome.transcoded;
    }

    // Audio codec check: treat '' (unknown Android) as safe (aac assumed).
    // See implementation plan §B4 amendment: unknown audioCodec → do not force transcode.
    final audioOk = info.audioCodec.isEmpty ||
        info.audioCodec == 'aac' ||
        !info.hasAudio;
    if (!audioOk) return PrepareOutcome.transcoded;

    // From here: codec/res/bitrate is acceptable for upload.
    // Check if normalization is still needed even though quality is good.
    final needsNormalize = info.hasRotationTransform ||
        info.container != 'mp4' ||          // MKV, WebM, AVI → remux to MP4
        !info.hasMoovAtFront ||             // false by default (plan §B2); triggers remux
        (policy.requireFastStart && !info.hasMoovAtFront) ||
        (policy.stripMetadata && info.hasEmbeddedMetadata);

    if (needsNormalize) {
      if (policy.allowNormalize) return PrepareOutcome.normalized;
      // No normalize allowed — transcode instead (always produces correct output)
      return PrepareOutcome.transcoded;
    }

    // All constraints met, no normalization needed
    if (policy.allowPassThrough) return PrepareOutcome.passThrough;
    // Strict policy: normalize even if already optimal
    return PrepareOutcome.normalized;
  }

  /// Determines which outcome applies to an image file.
  static PrepareOutcome _classifyImage(
    MediaInfo info,
    UploadConstraints constraints,
    UploadPolicy policy,
  ) {
    final isJpeg  = info.container == 'jpeg';
    final fitsRes = info.width <= constraints.imageMaxWidthPx;

    // Pass through: already JPEG at target size with no metadata issue
    if (isJpeg &&
        fitsRes &&
        policy.allowPassThrough &&
        !(policy.stripMetadata && info.hasEmbeddedMetadata)) {
      return PrepareOutcome.passThrough;
    }

    // Normalize: JPEG at target size but metadata must be stripped
    if (isJpeg &&
        fitsRes &&
        policy.stripMetadata &&
        info.hasEmbeddedMetadata &&
        policy.allowNormalize) {
      return PrepareOutcome.normalized;
    }

    // Transcode: not JPEG, or too wide, or strict policy
    return PrepareOutcome.transcoded;
  }
}
