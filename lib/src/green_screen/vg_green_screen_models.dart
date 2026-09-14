// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.
//
// Generic green-screen export contracts (Android first). Caller-agnostic:
// Duet, live meeting/calling, going live, camera, and the Universal Editor can
// all build a [VGGreenScreenExportRequest]; nothing here is Duet-owned.
//
// Wire contract (MethodChannel `exportGreenScreenComposition`):
//   request  → [VGGreenScreenExportRequest.toMap]
//   success  → [VGGreenScreenExportResult.fromMap]
//   errors   → platform codes `INVALID_ARG`, `export_busy`, `composition_failed`
//              mapped by [VGGreenScreenErrorCode.fromPlatformCode].

// ─────────────────────────────────────────────────────────────────────────────
// Geometry (integer output-canvas pixels)
// ─────────────────────────────────────────────────────────────────────────────

/// Integer pixel size of the export canvas.
class VGGreenScreenSize {
  final int width;
  final int height;

  const VGGreenScreenSize(this.width, this.height)
    : assert(width > 0, 'width must be > 0'),
      assert(height > 0, 'height must be > 0');

  Map<String, dynamic> toMap() => <String, dynamic>{
    'width': width,
    'height': height,
  };

  factory VGGreenScreenSize.fromMap(Map<String, dynamic> map) =>
      VGGreenScreenSize(
        (map['width'] as num).toInt(),
        (map['height'] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenSize &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'VGGreenScreenSize(${width}x$height)';
}

/// Integer pixel rect on the output canvas (destination of one lane).
///
/// A lane's content is aspect-filled into its rect by the compositor.
class VGGreenScreenRect {
  final int x;
  final int y;
  final int width;
  final int height;

  const VGGreenScreenRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  }) : assert(width > 0, 'width must be > 0'),
       assert(height > 0, 'height must be > 0');

  /// Whether this rect lies fully inside a canvas of [size].
  bool fitsInside(VGGreenScreenSize size) =>
      x >= 0 && y >= 0 && x + width <= size.width && y + height <= size.height;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  factory VGGreenScreenRect.fromMap(Map<String, dynamic> map) =>
      VGGreenScreenRect(
        x: (map['x'] as num).toInt(),
        y: (map['y'] as num).toInt(),
        width: (map['width'] as num).toInt(),
        height: (map['height'] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenRect &&
          x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'VGGreenScreenRect(x: $x, y: $y, ${width}x$height)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Background source
// ─────────────────────────────────────────────────────────────────────────────

/// How an image background is placed on its destination rect.
///
/// [aspectFit] letterboxes/pillarboxes with black; [aspectFill] center-crops.
enum VGGreenScreenScaleMode { aspectFill, aspectFit }

/// The opaque background lane of a green-screen export.
///
/// A [VGGreenScreenVideoFileBackground] is decoded directly. A
/// [VGGreenScreenSolidColorBackground] or [VGGreenScreenImageFileBackground]
/// is rendered by the native engine into a bounded temporary clip (same fps,
/// frame count, and bit rate as the output; sized to the background rect or
/// the full canvas) that is decoded through the same hardware lane and deleted
/// on every terminal path.
sealed class VGGreenScreenBackgroundSource {
  const VGGreenScreenBackgroundSource();

  /// A local video file background.
  const factory VGGreenScreenBackgroundSource.videoFile(String path) =
      VGGreenScreenVideoFileBackground;

  /// A solid ARGB color background (alpha is ignored; the lane is opaque).
  const factory VGGreenScreenBackgroundSource.solidColor(int argbColor) =
      VGGreenScreenSolidColorBackground;

  /// A local image file background placed with [scaleMode]
  /// (default [VGGreenScreenScaleMode.aspectFill]). EXIF orientation is not
  /// applied.
  const factory VGGreenScreenBackgroundSource.imageFile(
    String path, {
    VGGreenScreenScaleMode scaleMode,
  }) = VGGreenScreenImageFileBackground;

  /// Wire type name: `videoFile`, `solidColor`, or `imageFile`.
  String get type;

  Map<String, dynamic> toMap();

  /// Throws [ArgumentError] on an unknown `type` or missing fields.
  factory VGGreenScreenBackgroundSource.fromMap(Map<String, dynamic> map) {
    final type = map['type'];
    switch (type) {
      case 'videoFile':
        return VGGreenScreenVideoFileBackground(map['path'] as String);
      case 'solidColor':
        return VGGreenScreenSolidColorBackground(
          (map['argbColor'] as num).toInt(),
        );
      case 'imageFile':
        final scaleName = map['scaleMode'] as String?;
        return VGGreenScreenImageFileBackground(
          map['path'] as String,
          scaleMode: VGGreenScreenScaleMode.values.firstWhere(
            (m) => m.name == scaleName,
            orElse: () => VGGreenScreenScaleMode.aspectFill,
          ),
        );
      default:
        throw ArgumentError.value(
          type,
          'type',
          'VGGreenScreenBackgroundSource.fromMap: unknown background type.',
        );
    }
  }
}

/// See [VGGreenScreenBackgroundSource.videoFile].
final class VGGreenScreenVideoFileBackground
    extends VGGreenScreenBackgroundSource {
  final String path;

  const VGGreenScreenVideoFileBackground(this.path);

  @override
  String get type => 'videoFile';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{'type': type, 'path': path};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenVideoFileBackground && path == other.path;

  @override
  int get hashCode => Object.hash(type, path);

  @override
  String toString() => 'VGGreenScreenBackgroundSource.videoFile($path)';
}

/// See [VGGreenScreenBackgroundSource.solidColor].
final class VGGreenScreenSolidColorBackground
    extends VGGreenScreenBackgroundSource {
  final int argbColor;

  const VGGreenScreenSolidColorBackground(this.argbColor);

  @override
  String get type => 'solidColor';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'type': type,
    'argbColor': argbColor,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenSolidColorBackground &&
          argbColor == other.argbColor;

  @override
  int get hashCode => Object.hash(type, argbColor);

  @override
  String toString() =>
      'VGGreenScreenBackgroundSource.solidColor(0x${argbColor.toRadixString(16)})';
}

/// See [VGGreenScreenBackgroundSource.imageFile].
final class VGGreenScreenImageFileBackground
    extends VGGreenScreenBackgroundSource {
  final String path;
  final VGGreenScreenScaleMode scaleMode;

  const VGGreenScreenImageFileBackground(
    this.path, {
    this.scaleMode = VGGreenScreenScaleMode.aspectFill,
  });

  @override
  String get type => 'imageFile';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'type': type,
    'path': path,
    'scaleMode': scaleMode.name,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenImageFileBackground &&
          path == other.path &&
          scaleMode == other.scaleMode;

  @override
  int get hashCode => Object.hash(type, path, scaleMode);

  @override
  String toString() =>
      'VGGreenScreenBackgroundSource.imageFile($path, scaleMode: ${scaleMode.name})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Mask source
// ─────────────────────────────────────────────────────────────────────────────

/// The per-frame foreground mask (8-bit alpha: 255 = foreground, 0 = background).
///
/// Every variant is turned into a direct CPU R8 mask frame by the native
/// handler. New mask producers (for example ML segmentation) can write local
/// R8 frame files and pass them as [VGGreenScreenR8FrameFilesMask] without
/// changing the export method.
sealed class VGGreenScreenMaskSource {
  const VGGreenScreenMaskSource();

  /// A constant alpha mask of [width]x[height] (defaults 64x64) applied to
  /// every output frame.
  const factory VGGreenScreenMaskSource.constantAlpha(
    int alpha, {
    int width,
    int height,
  }) = VGGreenScreenConstantAlphaMask;

  /// One local raw R8 file per output frame: frame `i` reads
  /// `framePaths[i]`, exactly `rowStrideBytes * height` bytes (or
  /// `width * height` when [VGGreenScreenR8FrameFilesMask.rowStrideBytes] is
  /// 0). Missing or short files fail the export closed.
  const factory VGGreenScreenMaskSource.r8FrameFiles(
    List<String> framePaths, {
    required int width,
    required int height,
    int rowStrideBytes,
  }) = VGGreenScreenR8FrameFilesMask;

  /// Wire type name: `constantAlpha` or `r8FrameFiles`.
  String get type;

  Map<String, dynamic> toMap();

  /// Throws [ArgumentError] on an unknown `type` or missing fields.
  factory VGGreenScreenMaskSource.fromMap(Map<String, dynamic> map) {
    final type = map['type'];
    switch (type) {
      case 'constantAlpha':
        return VGGreenScreenConstantAlphaMask(
          (map['alpha'] as num).toInt(),
          width: (map['width'] as num?)?.toInt() ?? 64,
          height: (map['height'] as num?)?.toInt() ?? 64,
        );
      case 'r8FrameFiles':
        return VGGreenScreenR8FrameFilesMask(
          List<String>.from(map['framePaths'] as List),
          width: (map['width'] as num).toInt(),
          height: (map['height'] as num).toInt(),
          rowStrideBytes: (map['rowStrideBytes'] as num?)?.toInt() ?? 0,
        );
      default:
        throw ArgumentError.value(
          type,
          'type',
          'VGGreenScreenMaskSource.fromMap: unknown mask type.',
        );
    }
  }
}

/// See [VGGreenScreenMaskSource.constantAlpha].
final class VGGreenScreenConstantAlphaMask extends VGGreenScreenMaskSource {
  final int alpha;
  final int width;
  final int height;

  const VGGreenScreenConstantAlphaMask(
    this.alpha, {
    this.width = 64,
    this.height = 64,
  });

  @override
  String get type => 'constantAlpha';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'type': type,
    'alpha': alpha,
    'width': width,
    'height': height,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenConstantAlphaMask &&
          alpha == other.alpha &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(type, alpha, width, height);

  @override
  String toString() =>
      'VGGreenScreenMaskSource.constantAlpha($alpha, ${width}x$height)';
}

/// See [VGGreenScreenMaskSource.r8FrameFiles].
final class VGGreenScreenR8FrameFilesMask extends VGGreenScreenMaskSource {
  final List<String> framePaths;
  final int width;
  final int height;

  /// Bytes per mask row; 0 means tightly packed (`width` bytes per row).
  final int rowStrideBytes;

  const VGGreenScreenR8FrameFilesMask(
    this.framePaths, {
    required this.width,
    required this.height,
    this.rowStrideBytes = 0,
  });

  @override
  String get type => 'r8FrameFiles';

  /// Bytes the native handler reads per frame file.
  int get bytesPerFrame =>
      (rowStrideBytes > 0 ? rowStrideBytes : width) * height;

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'type': type,
    'framePaths': List<String>.unmodifiable(framePaths),
    'width': width,
    'height': height,
    'rowStrideBytes': rowStrideBytes,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenR8FrameFilesMask &&
          width == other.width &&
          height == other.height &&
          rowStrideBytes == other.rowStrideBytes &&
          _listEquals(framePaths, other.framePaths);

  @override
  int get hashCode => Object.hash(
    type,
    width,
    height,
    rowStrideBytes,
    Object.hashAll(framePaths),
  );

  @override
  String toString() =>
      'VGGreenScreenMaskSource.r8FrameFiles(${framePaths.length} files, '
      '${width}x$height, rowStrideBytes: $rowStrideBytes)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Export request
// ─────────────────────────────────────────────────────────────────────────────

/// A complete offline green-screen export request.
///
/// Output frame `i` has presentation time `i * 1_000_000 / fps` microseconds;
/// each lane pairs the newest input frame at or before that time. Null rects
/// mean the full canvas. Rotations are cardinal (0/90/180/270) and applied
/// explicitly; container rotation is never auto-applied.
class VGGreenScreenExportRequest {
  /// Local foreground video file (the masked lane).
  final String foregroundVideoPath;

  final VGGreenScreenBackgroundSource background;
  final VGGreenScreenMaskSource mask;

  /// Absolute path of the final MP4. Must not already exist; the engine writes
  /// `outputPath.tmp` and renames it only after verified success.
  final String outputPath;

  final VGGreenScreenSize targetSize;
  final int fps;
  final int videoBitRate;
  final int outputFrameCount;
  final VGGreenScreenRect? foregroundRect;
  final VGGreenScreenRect? backgroundRect;
  final int foregroundRotationDegrees;
  final int backgroundRotationDegrees;
  final bool foregroundMirrorHorizontal;
  final bool backgroundMirrorHorizontal;

  static const List<int> _cardinalRotations = <int>[0, 90, 180, 270];

  /// Throws [ArgumentError] on blank paths, non-positive clock/size values,
  /// non-cardinal rotations, rects outside [targetSize], or a mask descriptor
  /// that cannot cover [outputFrameCount] frames.
  VGGreenScreenExportRequest({
    required this.foregroundVideoPath,
    required this.background,
    required this.mask,
    required this.outputPath,
    required this.outputFrameCount,
    this.targetSize = const VGGreenScreenSize(1080, 1920),
    this.fps = 30,
    this.videoBitRate = 8000000,
    this.foregroundRect,
    this.backgroundRect,
    this.foregroundRotationDegrees = 0,
    this.backgroundRotationDegrees = 0,
    this.foregroundMirrorHorizontal = false,
    this.backgroundMirrorHorizontal = false,
  }) {
    _requireNonBlank(foregroundVideoPath, 'foregroundVideoPath');
    _requireNonBlank(outputPath, 'outputPath');
    _requirePositive(fps, 'fps');
    _requirePositive(videoBitRate, 'videoBitRate');
    _requirePositive(outputFrameCount, 'outputFrameCount');
    _requireCardinal(foregroundRotationDegrees, 'foregroundRotationDegrees');
    _requireCardinal(backgroundRotationDegrees, 'backgroundRotationDegrees');
    _requireRectFits(foregroundRect, 'foregroundRect');
    _requireRectFits(backgroundRect, 'backgroundRect');
    switch (background) {
      case VGGreenScreenVideoFileBackground(:final path):
        _requireNonBlank(path, 'background.path');
      case VGGreenScreenImageFileBackground(:final path):
        _requireNonBlank(path, 'background.path');
      case VGGreenScreenSolidColorBackground():
        break;
    }
    switch (mask) {
      case VGGreenScreenConstantAlphaMask(
        :final alpha,
        :final width,
        :final height,
      ):
        if (alpha < 0 || alpha > 255) {
          throw ArgumentError.value(
            alpha,
            'mask.alpha',
            'must be within 0..255',
          );
        }
        _requirePositive(width, 'mask.width');
        _requirePositive(height, 'mask.height');
      case VGGreenScreenR8FrameFilesMask(
        :final framePaths,
        :final width,
        :final height,
        :final rowStrideBytes,
      ):
        _requirePositive(width, 'mask.width');
        _requirePositive(height, 'mask.height');
        if (rowStrideBytes < 0 ||
            (rowStrideBytes > 0 && rowStrideBytes < width)) {
          throw ArgumentError.value(
            rowStrideBytes,
            'mask.rowStrideBytes',
            'must be 0 or >= mask.width',
          );
        }
        if (framePaths.length < outputFrameCount) {
          throw ArgumentError.value(
            framePaths.length,
            'mask.framePaths',
            'must have at least outputFrameCount ($outputFrameCount) entries',
          );
        }
        for (var i = 0; i < framePaths.length; i++) {
          _requireNonBlank(framePaths[i], 'mask.framePaths[$i]');
        }
    }
  }

  /// Nominal duration from the fixed output clock.
  Duration get nominalDuration =>
      Duration(microseconds: outputFrameCount * 1000000 ~/ fps);

  Map<String, dynamic> toMap() => <String, dynamic>{
    'foregroundVideoPath': foregroundVideoPath,
    'background': background.toMap(),
    'mask': mask.toMap(),
    'outputPath': outputPath,
    'targetSize': targetSize.toMap(),
    'fps': fps,
    'videoBitRate': videoBitRate,
    'outputFrameCount': outputFrameCount,
    'foregroundRect': foregroundRect?.toMap(),
    'backgroundRect': backgroundRect?.toMap(),
    'foregroundRotationDegrees': foregroundRotationDegrees,
    'backgroundRotationDegrees': backgroundRotationDegrees,
    'foregroundMirrorHorizontal': foregroundMirrorHorizontal,
    'backgroundMirrorHorizontal': backgroundMirrorHorizontal,
  };

  /// Throws [ArgumentError] on missing/invalid required keys.
  factory VGGreenScreenExportRequest.fromMap(Map<String, dynamic> map) {
    final fgRect = map['foregroundRect'];
    final bgRect = map['backgroundRect'];
    return VGGreenScreenExportRequest(
      foregroundVideoPath: map['foregroundVideoPath'] as String,
      background: VGGreenScreenBackgroundSource.fromMap(
        Map<String, dynamic>.from(map['background'] as Map),
      ),
      mask: VGGreenScreenMaskSource.fromMap(
        Map<String, dynamic>.from(map['mask'] as Map),
      ),
      outputPath: map['outputPath'] as String,
      outputFrameCount: (map['outputFrameCount'] as num).toInt(),
      targetSize: map['targetSize'] == null
          ? const VGGreenScreenSize(1080, 1920)
          : VGGreenScreenSize.fromMap(
              Map<String, dynamic>.from(map['targetSize'] as Map),
            ),
      fps: (map['fps'] as num?)?.toInt() ?? 30,
      videoBitRate: (map['videoBitRate'] as num?)?.toInt() ?? 8000000,
      foregroundRect: fgRect == null
          ? null
          : VGGreenScreenRect.fromMap(Map<String, dynamic>.from(fgRect as Map)),
      backgroundRect: bgRect == null
          ? null
          : VGGreenScreenRect.fromMap(Map<String, dynamic>.from(bgRect as Map)),
      foregroundRotationDegrees:
          (map['foregroundRotationDegrees'] as num?)?.toInt() ?? 0,
      backgroundRotationDegrees:
          (map['backgroundRotationDegrees'] as num?)?.toInt() ?? 0,
      foregroundMirrorHorizontal:
          map['foregroundMirrorHorizontal'] as bool? ?? false,
      backgroundMirrorHorizontal:
          map['backgroundMirrorHorizontal'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenExportRequest &&
          foregroundVideoPath == other.foregroundVideoPath &&
          background == other.background &&
          mask == other.mask &&
          outputPath == other.outputPath &&
          targetSize == other.targetSize &&
          fps == other.fps &&
          videoBitRate == other.videoBitRate &&
          outputFrameCount == other.outputFrameCount &&
          foregroundRect == other.foregroundRect &&
          backgroundRect == other.backgroundRect &&
          foregroundRotationDegrees == other.foregroundRotationDegrees &&
          backgroundRotationDegrees == other.backgroundRotationDegrees &&
          foregroundMirrorHorizontal == other.foregroundMirrorHorizontal &&
          backgroundMirrorHorizontal == other.backgroundMirrorHorizontal;

  @override
  int get hashCode => Object.hash(
    foregroundVideoPath,
    background,
    mask,
    outputPath,
    targetSize,
    fps,
    videoBitRate,
    outputFrameCount,
    foregroundRect,
    backgroundRect,
    foregroundRotationDegrees,
    backgroundRotationDegrees,
    foregroundMirrorHorizontal,
    backgroundMirrorHorizontal,
  );

  @override
  String toString() =>
      'VGGreenScreenExportRequest(foreground: $foregroundVideoPath, '
      'background: $background, mask: $mask, outputPath: $outputPath, '
      'targetSize: $targetSize, fps: $fps, videoBitRate: $videoBitRate, '
      'outputFrameCount: $outputFrameCount)';

  static void _requireNonBlank(String value, String name) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, 'must not be blank');
    }
  }

  static void _requirePositive(int value, String name) {
    if (value <= 0) throw ArgumentError.value(value, name, 'must be > 0');
  }

  static void _requireCardinal(int value, String name) {
    if (!_cardinalRotations.contains(value)) {
      throw ArgumentError.value(value, name, 'must be 0, 90, 180, or 270');
    }
  }

  void _requireRectFits(VGGreenScreenRect? rect, String name) {
    if (rect != null && !rect.fitsInside(targetSize)) {
      throw ArgumentError.value(rect, name, 'must fit inside targetSize');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Export result
// ─────────────────────────────────────────────────────────────────────────────

/// Per-lane decode/pairing telemetry reported by the native engine.
class VGGreenScreenLaneTelemetry {
  final String? decoderName;
  final int contentWidth;
  final int contentHeight;
  final int containerRotationDegrees;
  final int decodedFrames;
  final int heldFrames;
  final int heldAfterEosFrames;
  final int droppedFrames;
  final bool eosReached;

  const VGGreenScreenLaneTelemetry({
    this.decoderName,
    this.contentWidth = 0,
    this.contentHeight = 0,
    this.containerRotationDegrees = 0,
    this.decodedFrames = 0,
    this.heldFrames = 0,
    this.heldAfterEosFrames = 0,
    this.droppedFrames = 0,
    this.eosReached = false,
  });

  /// Reads `<prefix>DecoderName`, `<prefix>DecodedFrames`, … from a flat map.
  factory VGGreenScreenLaneTelemetry.fromMap(
    Map<String, dynamic> map,
    String prefix,
  ) => VGGreenScreenLaneTelemetry(
    decoderName: map['${prefix}DecoderName'] as String?,
    contentWidth: (map['${prefix}ContentWidth'] as num?)?.toInt() ?? 0,
    contentHeight: (map['${prefix}ContentHeight'] as num?)?.toInt() ?? 0,
    containerRotationDegrees:
        (map['${prefix}ContainerRotationDegrees'] as num?)?.toInt() ?? 0,
    decodedFrames: (map['${prefix}DecodedFrames'] as num?)?.toInt() ?? 0,
    heldFrames: (map['${prefix}HeldFrames'] as num?)?.toInt() ?? 0,
    heldAfterEosFrames:
        (map['${prefix}HeldAfterEosFrames'] as num?)?.toInt() ?? 0,
    droppedFrames: (map['${prefix}DroppedFrames'] as num?)?.toInt() ?? 0,
    eosReached: map['${prefix}EosReached'] as bool? ?? false,
  );

  Map<String, dynamic> toMap(String prefix) => <String, dynamic>{
    '${prefix}DecoderName': decoderName,
    '${prefix}ContentWidth': contentWidth,
    '${prefix}ContentHeight': contentHeight,
    '${prefix}ContainerRotationDegrees': containerRotationDegrees,
    '${prefix}DecodedFrames': decodedFrames,
    '${prefix}HeldFrames': heldFrames,
    '${prefix}HeldAfterEosFrames': heldAfterEosFrames,
    '${prefix}DroppedFrames': droppedFrames,
    '${prefix}EosReached': eosReached,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenLaneTelemetry &&
          decoderName == other.decoderName &&
          contentWidth == other.contentWidth &&
          contentHeight == other.contentHeight &&
          containerRotationDegrees == other.containerRotationDegrees &&
          decodedFrames == other.decodedFrames &&
          heldFrames == other.heldFrames &&
          heldAfterEosFrames == other.heldAfterEosFrames &&
          droppedFrames == other.droppedFrames &&
          eosReached == other.eosReached;

  @override
  int get hashCode => Object.hash(
    decoderName,
    contentWidth,
    contentHeight,
    containerRotationDegrees,
    decodedFrames,
    heldFrames,
    heldAfterEosFrames,
    droppedFrames,
    eosReached,
  );

  @override
  String toString() =>
      'VGGreenScreenLaneTelemetry(decoder: $decoderName, '
      'content: ${contentWidth}x$contentHeight, '
      'rotation: $containerRotationDegrees, decoded: $decodedFrames, '
      'held: $heldFrames, heldAfterEos: $heldAfterEosFrames, '
      'dropped: $droppedFrames, eos: $eosReached)';
}

/// The result of a successful green-screen export.
///
/// All fields describe the final, atomically renamed output file on disk.
class VGGreenScreenExportResult {
  final String outputPath;
  final int durationMs;
  final int fileSizeBytes;

  /// Engine terminal state wire name (`success` on this type).
  final String terminalState;
  final String reason;
  final int fps;
  final int outputFrameCount;
  final int renderedFrames;
  final int writtenVideoSamples;
  final int maskWidth;
  final int maskHeight;

  /// Whether `outputPath.tmp` survived cleanup (always expected false).
  final bool tmpExists;

  /// `videoFile`, `solidColor`, or `imageFile`.
  final String backgroundSourceType;

  /// Frames the engine wrote into its temporary static-background clip
  /// (0 for a video background).
  final int backgroundGeneratedFrames;

  /// Whether the temporary static-background clip survived cleanup (always
  /// expected false).
  final bool backgroundGeneratedTmpExists;
  final VGGreenScreenLaneTelemetry background;
  final VGGreenScreenLaneTelemetry foreground;
  final List<String> claims;

  /// [durationMs] and [fileSizeBytes] must both be positive.
  VGGreenScreenExportResult({
    required this.outputPath,
    required this.durationMs,
    required this.fileSizeBytes,
    this.terminalState = 'success',
    this.reason = 'success',
    this.fps = 0,
    this.outputFrameCount = 0,
    this.renderedFrames = 0,
    this.writtenVideoSamples = 0,
    this.maskWidth = 0,
    this.maskHeight = 0,
    this.tmpExists = false,
    this.backgroundSourceType = 'videoFile',
    this.backgroundGeneratedFrames = 0,
    this.backgroundGeneratedTmpExists = false,
    this.background = const VGGreenScreenLaneTelemetry(),
    this.foreground = const VGGreenScreenLaneTelemetry(),
    List<String> claims = const <String>[],
  }) : claims = List<String>.unmodifiable(claims) {
    if (outputPath.trim().isEmpty) {
      throw ArgumentError.value(
        outputPath,
        'outputPath',
        'VGGreenScreenExportResult: outputPath must not be blank.',
      );
    }
    if (durationMs <= 0) {
      throw ArgumentError.value(
        durationMs,
        'durationMs',
        'VGGreenScreenExportResult: durationMs must be > 0.',
      );
    }
    if (fileSizeBytes <= 0) {
      throw ArgumentError.value(
        fileSizeBytes,
        'fileSizeBytes',
        'VGGreenScreenExportResult: fileSizeBytes must be > 0.',
      );
    }
  }

  bool get renderedEqualsWritten => renderedFrames == writtenVideoSamples;

  bool get backgroundGenerated => backgroundSourceType != 'videoFile';

  Map<String, dynamic> toMap() => <String, dynamic>{
    'outputPath': outputPath,
    'durationMs': durationMs,
    'fileSizeBytes': fileSizeBytes,
    'terminalState': terminalState,
    'reason': reason,
    'fps': fps,
    'outputFrameCount': outputFrameCount,
    'renderedFrames': renderedFrames,
    'writtenVideoSamples': writtenVideoSamples,
    'renderedEqualsWritten': renderedEqualsWritten,
    'maskWidth': maskWidth,
    'maskHeight': maskHeight,
    'tmpExists': tmpExists,
    'backgroundSourceType': backgroundSourceType,
    'backgroundGeneratedFrames': backgroundGeneratedFrames,
    'backgroundGeneratedTmpExists': backgroundGeneratedTmpExists,
    ...background.toMap('background'),
    ...foreground.toMap('foreground'),
    'claims': claims,
  };

  /// Throws [ArgumentError] when required keys are missing or have wrong types.
  factory VGGreenScreenExportResult.fromMap(Map<String, dynamic> map) {
    final path = map['outputPath'];
    if (path is! String) {
      throw ArgumentError(
        'VGGreenScreenExportResult.fromMap: missing or invalid "outputPath".',
      );
    }
    final rawDuration = map['durationMs'];
    if (rawDuration is! num) {
      throw ArgumentError(
        'VGGreenScreenExportResult.fromMap: missing "durationMs".',
      );
    }
    final rawSize = map['fileSizeBytes'];
    if (rawSize is! num) {
      throw ArgumentError(
        'VGGreenScreenExportResult.fromMap: missing "fileSizeBytes".',
      );
    }
    final rawClaims = map['claims'];
    return VGGreenScreenExportResult(
      outputPath: path,
      durationMs: rawDuration.toInt(),
      fileSizeBytes: rawSize.toInt(),
      terminalState: map['terminalState'] as String? ?? 'success',
      reason: map['reason'] as String? ?? 'success',
      fps: (map['fps'] as num?)?.toInt() ?? 0,
      outputFrameCount: (map['outputFrameCount'] as num?)?.toInt() ?? 0,
      renderedFrames: (map['renderedFrames'] as num?)?.toInt() ?? 0,
      writtenVideoSamples: (map['writtenVideoSamples'] as num?)?.toInt() ?? 0,
      maskWidth: (map['maskWidth'] as num?)?.toInt() ?? 0,
      maskHeight: (map['maskHeight'] as num?)?.toInt() ?? 0,
      tmpExists: map['tmpExists'] as bool? ?? false,
      backgroundSourceType:
          map['backgroundSourceType'] as String? ?? 'videoFile',
      backgroundGeneratedFrames:
          (map['backgroundGeneratedFrames'] as num?)?.toInt() ?? 0,
      backgroundGeneratedTmpExists:
          map['backgroundGeneratedTmpExists'] as bool? ?? false,
      background: VGGreenScreenLaneTelemetry.fromMap(map, 'background'),
      foreground: VGGreenScreenLaneTelemetry.fromMap(map, 'foreground'),
      claims: rawClaims is List
          ? rawClaims.map((e) => e.toString()).toList()
          : const <String>[],
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGGreenScreenExportResult &&
          outputPath == other.outputPath &&
          durationMs == other.durationMs &&
          fileSizeBytes == other.fileSizeBytes &&
          terminalState == other.terminalState &&
          reason == other.reason &&
          fps == other.fps &&
          outputFrameCount == other.outputFrameCount &&
          renderedFrames == other.renderedFrames &&
          writtenVideoSamples == other.writtenVideoSamples &&
          maskWidth == other.maskWidth &&
          maskHeight == other.maskHeight &&
          tmpExists == other.tmpExists &&
          backgroundSourceType == other.backgroundSourceType &&
          backgroundGeneratedFrames == other.backgroundGeneratedFrames &&
          backgroundGeneratedTmpExists == other.backgroundGeneratedTmpExists &&
          background == other.background &&
          foreground == other.foreground &&
          _listEquals(claims, other.claims);

  @override
  int get hashCode => Object.hash(
    outputPath,
    durationMs,
    fileSizeBytes,
    terminalState,
    reason,
    fps,
    outputFrameCount,
    renderedFrames,
    writtenVideoSamples,
    maskWidth,
    maskHeight,
    tmpExists,
    backgroundSourceType,
    backgroundGeneratedFrames,
    backgroundGeneratedTmpExists,
    background,
    foreground,
    Object.hashAll(claims),
  );

  @override
  String toString() =>
      'VGGreenScreenExportResult(outputPath: $outputPath, '
      'durationMs: $durationMs, fileSizeBytes: $fileSizeBytes, '
      'terminalState: $terminalState, reason: $reason, '
      'rendered: $renderedFrames, written: $writtenVideoSamples, '
      'backgroundSourceType: $backgroundSourceType)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

/// Typed failure classes for [VGGreenScreenException].
enum VGGreenScreenErrorCode {
  /// The request was rejected before any work started (`INVALID_ARG`).
  invalidArgument,

  /// Another green-screen export is active, or the handler is disposed
  /// (`export_busy`).
  exportBusy,

  /// The engine reached a failed or cancelled terminal state
  /// (`composition_failed`).
  compositionFailed,

  /// Any other platform or channel error.
  unknown;

  /// Maps a native `PlatformException.code` to a typed code.
  static VGGreenScreenErrorCode fromPlatformCode(String? code) =>
      switch (code) {
        'INVALID_ARG' => VGGreenScreenErrorCode.invalidArgument,
        'export_busy' => VGGreenScreenErrorCode.exportBusy,
        'composition_failed' => VGGreenScreenErrorCode.compositionFailed,
        _ => VGGreenScreenErrorCode.unknown,
      };
}

/// Typed exception for green-screen export failures from platform/channel
/// calls. Local model validation errors use [ArgumentError] directly.
class VGGreenScreenException implements Exception {
  final VGGreenScreenErrorCode code;
  final String message;
  final Object? cause;

  /// Native error details when reported (for `composition_failed` this is the
  /// engine's full result map, including `reason` and lane telemetry).
  final Object? details;

  const VGGreenScreenException({
    required this.code,
    required this.message,
    this.cause,
    this.details,
  });

  @override
  String toString() =>
      'VGGreenScreenException(code: ${code.name}, message: $message'
      '${cause != null ? ', cause: $cause' : ''})';
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
