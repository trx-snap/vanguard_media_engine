// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.

// ─────────────────────────────────────────────────────────────────────────────
// Package-owned serializable geometry
// ─────────────────────────────────────────────────────────────────────────────

/// An immutable 2-D size with non-negative width and height.
class VGDuetSize {
  final double width;
  final double height;

  const VGDuetSize(this.width, this.height)
    : assert(width >= 0.0, 'width must be >= 0'),
      assert(height >= 0.0, 'height must be >= 0');

  static const VGDuetSize zero = VGDuetSize(0.0, 0.0);

  double get aspectRatio => height == 0.0 ? 0.0 : width / height;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'width': width,
    'height': height,
  };

  factory VGDuetSize.fromMap(Map<String, dynamic> map) => VGDuetSize(
    (map['width'] as num).toDouble(),
    (map['height'] as num).toDouble(),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetSize && width == other.width && height == other.height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'VGDuetSize(${width}x$height)';
}

/// An immutable 2-D point.
class VGDuetPoint {
  final double x;
  final double y;

  const VGDuetPoint(this.x, this.y);

  static const VGDuetPoint zero = VGDuetPoint(0.0, 0.0);

  Map<String, dynamic> toMap() => <String, dynamic>{'x': x, 'y': y};

  factory VGDuetPoint.fromMap(Map<String, dynamic> map) =>
      VGDuetPoint((map['x'] as num).toDouble(), (map['y'] as num).toDouble());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetPoint && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'VGDuetPoint($x, $y)';
}

/// An immutable axis-aligned rectangle defined by origin and size.
class VGDuetRect {
  final double left;
  final double top;
  final double width;
  final double height;

  const VGDuetRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory VGDuetRect.fromLTRB(
    double left,
    double top,
    double right,
    double bottom,
  ) => VGDuetRect(
    left: left,
    top: top,
    width: right - left,
    height: bottom - top,
  );

  factory VGDuetRect.fromCenter(VGDuetPoint center, VGDuetSize size) =>
      VGDuetRect(
        left: center.x - size.width / 2.0,
        top: center.y - size.height / 2.0,
        width: size.width,
        height: size.height,
      );

  double get right => left + width;
  double get bottom => top + height;
  VGDuetPoint get topLeft => VGDuetPoint(left, top);
  VGDuetPoint get center => VGDuetPoint(left + width / 2.0, top + height / 2.0);
  VGDuetSize get size => VGDuetSize(width, height);

  static const VGDuetRect zero = VGDuetRect(
    left: 0.0,
    top: 0.0,
    width: 0.0,
    height: 0.0,
  );

  Map<String, dynamic> toMap() => <String, dynamic>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  factory VGDuetRect.fromMap(Map<String, dynamic> map) => VGDuetRect(
    left: (map['left'] as num).toDouble(),
    top: (map['top'] as num).toDouble(),
    width: (map['width'] as num).toDouble(),
    height: (map['height'] as num).toDouble(),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetRect &&
          left == other.left &&
          top == other.top &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() =>
      'VGDuetRect(left: $left, top: $top, width: $width, height: $height)';
}

/// Edge insets (safe-area margins, padding).
class VGDuetInsets {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const VGDuetInsets({
    this.left = 0.0,
    this.top = 0.0,
    this.right = 0.0,
    this.bottom = 0.0,
  });

  static const VGDuetInsets zero = VGDuetInsets();

  Map<String, dynamic> toMap() => <String, dynamic>{
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  factory VGDuetInsets.fromMap(Map<String, dynamic> map) => VGDuetInsets(
    left: (map['left'] as num?)?.toDouble() ?? 0.0,
    top: (map['top'] as num?)?.toDouble() ?? 0.0,
    right: (map['right'] as num?)?.toDouble() ?? 0.0,
    bottom: (map['bottom'] as num?)?.toDouble() ?? 0.0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetInsets &&
          left == other.left &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'VGDuetInsets(l: $left, t: $top, r: $right, b: $bottom)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Foreground camera-layer transform (Slice 5A)
// ─────────────────────────────────────────────────────────────────────────────

/// Optional affine transform for the green-screen foreground camera layer.
///
/// Semantics (v1 — shrink / reposition only):
/// - [scale]: uniform scale of the camera rect in `(0, 1]`. Clamped to
///   `[0.25, 1.0]` by native geometry before rect computation. A scale of 1.0
///   produces the full-canvas identity.
/// - [offset]: normalized canvas-center translation. `(0, 0)` keeps the rect
///   centered; `(1, 0)` shifts one full half-canvas width to the right.
///   Clamped to `[-1.0, 1.0]` per axis.
/// - [anchor]: the point within the scaled rect that maps to the canvas center
///   plus the offset translation. `(0.5, 0.5)` is the rect center. Clamped to
///   `[0.0, 1.0]` per axis.
///
/// This class is only meaningful when the layout mode is
/// [VGDuetLayoutMode.greenScreen]; it is harmlessly serialized for other modes
/// when present.
class VGDuetForegroundTransform {
  /// Uniform scale of the camera layer rect. Must be finite and positive.
  /// Native geometry clamps to `[0.25, 1.0]`.
  final double scale;

  /// Normalized canvas-center translation. Clamped to `[-1.0, 1.0]` by native
  /// geometry.
  final VGDuetPoint offset;

  /// The point within the scaled rect that anchors to canvas-center + offset.
  /// Clamped to `[0.0, 1.0]` by native geometry.
  final VGDuetPoint anchor;

  /// Identity transform: full-canvas rect, no offset, centered anchor.
  static const VGDuetForegroundTransform identity = VGDuetForegroundTransform(
    scale: 1.0,
    offset: VGDuetPoint.zero,
    anchor: VGDuetPoint(0.5, 0.5),
  );

  /// Product/app convenience preset for a green-screen creator overlay: a
  /// smaller foreground camera rect repositioned toward the lower portion of
  /// the canvas. This is not the engine default — [identity] remains that —
  /// and apps are free to supply their own [VGDuetForegroundTransform] values
  /// instead (e.g. computed live from pinch/drag gestures on a creator
  /// overlay control).
  static const VGDuetForegroundTransform creatorOverlay =
      VGDuetForegroundTransform(
        scale: 0.62,
        offset: VGDuetPoint(0.0, 0.22),
        anchor: VGDuetPoint(0.5, 0.5),
      );

  /// Constructs a [VGDuetForegroundTransform].
  ///
  /// Only the [scale] positivity is checked at construction time (via assert).
  /// Offset and anchor range clamping is deferred to native geometry to avoid
  /// rejecting semantically reasonable inputs.
  const VGDuetForegroundTransform({
    required this.scale,
    required this.offset,
    required this.anchor,
  }) : assert(scale > 0.0, 'scale must be positive');

  /// Constructs a [VGDuetForegroundTransform] with runtime validation.
  ///
  /// Throws [ArgumentError] if [scale] is not finite or is not positive.
  factory VGDuetForegroundTransform.validated({
    required double scale,
    required VGDuetPoint offset,
    required VGDuetPoint anchor,
  }) {
    if (!scale.isFinite) {
      throw ArgumentError.value(scale, 'scale', 'Must be finite.');
    }
    if (scale <= 0.0) {
      throw ArgumentError.value(scale, 'scale', 'Must be positive.');
    }
    return VGDuetForegroundTransform(
      scale: scale,
      offset: offset,
      anchor: anchor,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'scale': scale,
    'offset': offset.toMap(),
    'anchor': anchor.toMap(),
  };

  /// Parses a [VGDuetForegroundTransform] from a map.
  ///
  /// Invalid or missing values degrade to [identity] (for bad scale) or to
  /// per-field defaults (offset → zero, anchor → center) rather than throwing.
  /// No path through this factory throws for malformed foregroundTransform input.
  factory VGDuetForegroundTransform.fromMap(Map<String, dynamic> map) {
    final rawScale = (map['scale'] as num?)?.toDouble() ?? 1.0;
    if (!rawScale.isFinite || rawScale <= 0.0) {
      return VGDuetForegroundTransform.identity;
    }

    // Parse offset x/y defensively: missing, non-numeric, or non-finite → 0.0.
    final offsetMap = map['offset'];
    double offsetX = 0.0;
    double offsetY = 0.0;
    if (offsetMap is Map) {
      final rx = (offsetMap['x'] as num?)?.toDouble() ?? double.nan;
      final ry = (offsetMap['y'] as num?)?.toDouble() ?? double.nan;
      if (rx.isFinite) offsetX = rx;
      if (ry.isFinite) offsetY = ry;
    }

    // Parse anchor x/y defensively: missing, non-numeric, or non-finite → 0.5.
    final anchorMap = map['anchor'];
    double anchorX = 0.5;
    double anchorY = 0.5;
    if (anchorMap is Map) {
      final rx = (anchorMap['x'] as num?)?.toDouble() ?? double.nan;
      final ry = (anchorMap['y'] as num?)?.toDouble() ?? double.nan;
      if (rx.isFinite) anchorX = rx;
      if (ry.isFinite) anchorY = ry;
    }

    return VGDuetForegroundTransform(
      scale: rawScale,
      offset: VGDuetPoint(offsetX, offsetY),
      anchor: VGDuetPoint(anchorX, anchorY),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetForegroundTransform &&
          scale == other.scale &&
          offset == other.offset &&
          anchor == other.anchor;

  @override
  int get hashCode => Object.hash(scale, offset, anchor);

  @override
  String toString() =>
      'VGDuetForegroundTransform(scale: $scale, offset: $offset, anchor: $anchor)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Layout enums
// ─────────────────────────────────────────────────────────────────────────────

/// The four core Duet authoring layout modes.
enum VGDuetLayoutMode {
  /// Picture-in-Picture: source is in a draggable, corner-snapping overlay.
  pip,

  /// Left/Right 50-50 horizontal split.
  splitLeftRight,

  /// Top/Bottom 50-50 vertical split.
  splitTopBottom,

  /// Green Screen: source video as background; live camera subject keyed over it.
  greenScreen,
}

/// The four PiP corner anchor positions.
enum VGDuetPiPAnchor { topLeft, topRight, bottomLeft, bottomRight }

// ─────────────────────────────────────────────────────────────────────────────
// Layout configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable layout configuration for a Duet session.
///
/// PiP fields ([pipAnchor], [pipNormalizedRect]) are only validated when
/// [mode] is [VGDuetLayoutMode.pip].
class VGDuetLayoutConfig {
  final VGDuetLayoutMode mode;

  /// When `true` in [VGDuetLayoutMode.splitLeftRight], camera is on the left
  /// and source is on the right (inverted from default).
  final bool isSideSwapped;

  /// When `true` in [VGDuetLayoutMode.splitTopBottom], camera is on top and
  /// source is on the bottom (inverted from default).
  final bool isTopBottomSwapped;

  /// Active PiP corner anchor. Only meaningful in [VGDuetLayoutMode.pip].
  final VGDuetPiPAnchor? pipAnchor;

  /// Normalized PiP rect in canvas-fraction coordinates (0.0–1.0).
  /// Only meaningful in [VGDuetLayoutMode.pip].
  final VGDuetRect? pipNormalizedRect;

  /// Optional camera-layer transform for green-screen mode.
  ///
  /// Only meaningful when [mode] is [VGDuetLayoutMode.greenScreen]; harmlessly
  /// serialized when present for other modes. When `null`, the full-canvas
  /// identity rect is used (backwards-compatible default).
  final VGDuetForegroundTransform? foregroundTransform;

  /// Constructs a [VGDuetLayoutConfig].
  ///
  /// Throws [ArgumentError] immediately if [mode] is [VGDuetLayoutMode.pip]
  /// and [pipNormalizedRect] contains out-of-range values, so invalid
  /// configurations can never be stored.
  VGDuetLayoutConfig({
    required this.mode,
    this.isSideSwapped = false,
    this.isTopBottomSwapped = false,
    this.pipAnchor,
    this.pipNormalizedRect,
    this.foregroundTransform,
  }) {
    _validatePiPRect(mode, pipNormalizedRect);
  }

  static void _validatePiPRect(
    VGDuetLayoutMode mode,
    VGDuetRect? pipNormalizedRect,
  ) {
    if (mode == VGDuetLayoutMode.pip && pipNormalizedRect != null) {
      final r = pipNormalizedRect;
      if (r.left < 0.0 || r.top < 0.0 || r.width <= 0.0 || r.height <= 0.0) {
        throw ArgumentError(
          'VGDuetLayoutConfig: pipNormalizedRect has invalid values '
          '(left=${r.left}, top=${r.top}, w=${r.width}, h=${r.height}).',
        );
      }
      if (r.right > 1.0 || r.bottom > 1.0) {
        throw ArgumentError(
          'VGDuetLayoutConfig: pipNormalizedRect exceeds canvas bounds '
          '(right=${r.right}, bottom=${r.bottom}).',
        );
      }
    }
  }

  /// Validates the configuration.
  ///
  /// Validation is already performed in the constructor; calling this method
  /// explicitly is a no-op for valid instances. It is retained for callers
  /// that hold a reference obtained before this change.
  void validate() => _validatePiPRect(mode, pipNormalizedRect);

  VGDuetLayoutConfig copyWith({
    VGDuetLayoutMode? mode,
    bool? isSideSwapped,
    bool? isTopBottomSwapped,
    VGDuetPiPAnchor? pipAnchor,
    VGDuetRect? pipNormalizedRect,
    VGDuetForegroundTransform? foregroundTransform,
    bool clearPipAnchor = false,
    bool clearPipRect = false,
    bool clearForegroundTransform = false,
  }) {
    return VGDuetLayoutConfig(
      mode: mode ?? this.mode,
      isSideSwapped: isSideSwapped ?? this.isSideSwapped,
      isTopBottomSwapped: isTopBottomSwapped ?? this.isTopBottomSwapped,
      pipAnchor: clearPipAnchor ? null : (pipAnchor ?? this.pipAnchor),
      pipNormalizedRect: clearPipRect
          ? null
          : (pipNormalizedRect ?? this.pipNormalizedRect),
      foregroundTransform: clearForegroundTransform
          ? null
          : (foregroundTransform ?? this.foregroundTransform),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'mode': mode.name,
    'isSideSwapped': isSideSwapped,
    'isTopBottomSwapped': isTopBottomSwapped,
    if (pipAnchor != null) 'pipAnchor': pipAnchor!.name,
    if (pipNormalizedRect != null)
      'pipNormalizedRect': pipNormalizedRect!.toMap(),
    if (foregroundTransform != null)
      'foregroundTransform': foregroundTransform!.toMap(),
  };

  factory VGDuetLayoutConfig.fromMap(Map<String, dynamic> map) {
    final modeName = map['mode'] as String? ?? 'pip';
    final mode = VGDuetLayoutMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => VGDuetLayoutMode.pip,
    );
    VGDuetPiPAnchor? pipAnchor;
    final anchorName = map['pipAnchor'] as String?;
    if (anchorName != null) {
      pipAnchor = VGDuetPiPAnchor.values.firstWhere(
        (e) => e.name == anchorName,
        orElse: () => VGDuetPiPAnchor.topRight,
      );
    }
    VGDuetRect? pipRect;
    final rectMap = map['pipNormalizedRect'];
    if (rectMap is Map) {
      pipRect = VGDuetRect.fromMap(Map<String, dynamic>.from(rectMap));
    }
    VGDuetForegroundTransform? foregroundTransform;
    final fgMap = map['foregroundTransform'];
    if (fgMap is Map) {
      foregroundTransform = VGDuetForegroundTransform.fromMap(
        Map<String, dynamic>.from(fgMap),
      );
    }
    return VGDuetLayoutConfig(
      mode: mode,
      isSideSwapped: map['isSideSwapped'] as bool? ?? false,
      isTopBottomSwapped: map['isTopBottomSwapped'] as bool? ?? false,
      pipAnchor: pipAnchor,
      pipNormalizedRect: pipRect,
      foregroundTransform: foregroundTransform,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetLayoutConfig &&
          mode == other.mode &&
          isSideSwapped == other.isSideSwapped &&
          isTopBottomSwapped == other.isTopBottomSwapped &&
          pipAnchor == other.pipAnchor &&
          pipNormalizedRect == other.pipNormalizedRect &&
          foregroundTransform == other.foregroundTransform;

  @override
  int get hashCode => Object.hash(
    mode,
    isSideSwapped,
    isTopBottomSwapped,
    pipAnchor,
    pipNormalizedRect,
    foregroundTransform,
  );

  @override
  String toString() =>
      'VGDuetLayoutConfig(mode: ${mode.name}, swap: $isSideSwapped, '
      'tbSwap: $isTopBottomSwapped, pipAnchor: ${pipAnchor?.name}, '
      'foregroundTransform: $foregroundTransform)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Trim window
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable source video trim window. Minimum duration: 1.0 s.
class VGDuetTrimWindow {
  final double startSeconds;
  final double endSeconds;

  VGDuetTrimWindow({required this.startSeconds, required this.endSeconds}) {
    if (startSeconds < 0.0) {
      throw ArgumentError.value(startSeconds, 'startSeconds', 'Must be >= 0.');
    }
    if (endSeconds <= startSeconds) {
      throw ArgumentError(
        'VGDuetTrimWindow: endSeconds ($endSeconds) must be > '
        'startSeconds ($startSeconds).',
      );
    }
    if (durationSeconds < 1.0) {
      throw ArgumentError(
        'VGDuetTrimWindow: duration must be >= 1.0 s '
        '(got ${durationSeconds.toStringAsFixed(3)} s).',
      );
    }
  }

  double get durationSeconds => endSeconds - startSeconds;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'startSeconds': startSeconds,
    'endSeconds': endSeconds,
  };

  factory VGDuetTrimWindow.fromMap(Map<String, dynamic> map) =>
      VGDuetTrimWindow(
        startSeconds: (map['startSeconds'] as num).toDouble(),
        endSeconds: (map['endSeconds'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetTrimWindow &&
          startSeconds == other.startSeconds &&
          endSeconds == other.endSeconds;

  @override
  int get hashCode => Object.hash(startSeconds, endSeconds);

  @override
  String toString() =>
      'VGDuetTrimWindow(${startSeconds}s–${endSeconds}s, '
      '${durationSeconds.toStringAsFixed(3)}s)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Segment
// ─────────────────────────────────────────────────────────────────────────────

/// One recorded segment within a multi-segment Duet take.
class VGDuetSegment {
  final int segmentIndex;
  final int durationMs;

  /// Valid values: 0.3, 0.5, 1.0, 2.0, 3.0.
  final double speedMultiplier;

  final int sourceStartMs;
  final int sourceEndMs;
  final int outputStartMs;
  final int outputEndMs;

  VGDuetSegment({
    required this.segmentIndex,
    required this.durationMs,
    required this.speedMultiplier,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.outputStartMs,
    required this.outputEndMs,
  }) {
    if (segmentIndex < 0) {
      throw ArgumentError.value(segmentIndex, 'segmentIndex', 'Must be >= 0.');
    }
    if (durationMs <= 0) {
      throw ArgumentError.value(durationMs, 'durationMs', 'Must be > 0.');
    }
    _validateSpeed(speedMultiplier);
  }

  static const List<double> _validSpeeds = [0.3, 0.5, 1.0, 2.0, 3.0];

  static void _validateSpeed(double speed) {
    const epsilon = 0.001;
    final ok = _validSpeeds.any((s) => (speed - s).abs() < epsilon);
    if (!ok) {
      throw ArgumentError.value(
        speed,
        'speedMultiplier',
        'Must be one of ${_validSpeeds.join(', ')}.',
      );
    }
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'segmentIndex': segmentIndex,
    'durationMs': durationMs,
    'speedMultiplier': speedMultiplier,
    'sourceStartMs': sourceStartMs,
    'sourceEndMs': sourceEndMs,
    'outputStartMs': outputStartMs,
    'outputEndMs': outputEndMs,
  };

  factory VGDuetSegment.fromMap(Map<String, dynamic> map) => VGDuetSegment(
    segmentIndex: (map['segmentIndex'] as num).toInt(),
    durationMs: (map['durationMs'] as num).toInt(),
    speedMultiplier: (map['speedMultiplier'] as num).toDouble(),
    sourceStartMs: (map['sourceStartMs'] as num).toInt(),
    sourceEndMs: (map['sourceEndMs'] as num).toInt(),
    outputStartMs: (map['outputStartMs'] as num).toInt(),
    outputEndMs: (map['outputEndMs'] as num).toInt(),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetSegment &&
          segmentIndex == other.segmentIndex &&
          durationMs == other.durationMs &&
          speedMultiplier == other.speedMultiplier &&
          sourceStartMs == other.sourceStartMs &&
          sourceEndMs == other.sourceEndMs &&
          outputStartMs == other.outputStartMs &&
          outputEndMs == other.outputEndMs;

  @override
  int get hashCode => Object.hash(
    segmentIndex,
    durationMs,
    speedMultiplier,
    sourceStartMs,
    sourceEndMs,
    outputStartMs,
    outputEndMs,
  );

  @override
  String toString() =>
      'VGDuetSegment(#$segmentIndex, ${durationMs}ms, ${speedMultiplier}x)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Error types
// ─────────────────────────────────────────────────────────────────────────────

/// Typed error codes for Duet engine failures.
enum VGDuetErrorCode {
  /// The [VGDuetSource] path is invalid, missing, or the codec is unsupported.
  sourceInvalid,

  /// Camera or microphone hardware is unavailable or permission denied.
  cameraUnavailable,

  /// Real-time segmentation (Green Screen) failed to initialize.
  segmentationFailed,

  /// GPU compositor or composition pass failed.
  compositionFailed,

  /// Insufficient disk space for recording or export.
  diskFull,

  /// An unrecognised or unexpected platform error.
  unknown,
}

/// Typed exception for Duet engine failures originating from platform or
/// channel calls.
///
/// Local model validation errors use [ArgumentError] directly. Platform /
/// channel failures are wrapped in [VGDuetException].
class VGDuetException implements Exception {
  final VGDuetErrorCode code;
  final String message;
  final Object? cause;

  const VGDuetException({
    required this.code,
    required this.message,
    this.cause,
  });

  @override
  String toString() =>
      'VGDuetException(code: ${code.name}, message: $message'
      '${cause != null ? ', cause: $cause' : ''})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Preview texture lifecycle  (Slice 4A)
// ─────────────────────────────────────────────────────────────────────────────

/// The lifecycle state of a Duet preview texture registration.
///
/// State machine:
///   UNATTACHED → attachDuetPreviewTexture → [attachedWaitingSurface] →
///   surface callback → [surfaceAvailable] ↔ surface cleanup → [surfaceLost]
///   → detachDuetPreviewTexture / stop / dispose → [detached]
///   allocation failure → no active attachment (compositionFailed exception)
enum VGDuetPreviewTextureState {
  /// Texture registered; waiting for the platform Surface/CALayer to arrive.
  attachedWaitingSurface,

  /// Surface is ready; a compositor can render frames into the texture.
  surfaceAvailable,

  /// Surface was lost (e.g. app backgrounded); rendering must pause.
  surfaceLost,

  /// Texture unregistered; no further rendering is possible.
  detached,
}

/// Immutable descriptor returned by [VGDuetPlatformInterface.attachPreviewTexture].
///
/// Callers use [textureId] to construct a Flutter [Texture] widget.
/// The [state] reflects the surface lifecycle at the moment of return.
/// [layoutRects] carries optional geometry keyed by role when the native
/// side computed spatial layout at attach time.
class VGDuetPreviewTexture {
  /// The Flutter texture registry ID to pass to the [Texture] widget.
  final int textureId;

  /// Canvas size negotiated with the native engine.
  final VGDuetSize size;

  /// Lifecycle state at the time this descriptor was constructed.
  final VGDuetPreviewTextureState state;

  /// Optional layout rects keyed by role (e.g. 'source', 'camera').
  /// May be null when the native side does not return layout geometry.
  final Map<String, VGDuetRect>? layoutRects;

  const VGDuetPreviewTexture({
    required this.textureId,
    required this.size,
    required this.state,
    this.layoutRects,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
    'textureId': textureId,
    'width': size.width,
    'height': size.height,
    'state': state.name,
    if (layoutRects != null)
      'layoutRects': layoutRects!.map((k, v) => MapEntry(k, v.toMap())),
  };

  /// Parses the map returned by the native [attachDuetPreviewTexture] reply.
  ///
  /// Throws [VGDuetException] with [VGDuetErrorCode.compositionFailed] when
  /// required keys are missing or have wrong types, so callers see a typed
  /// error instead of a raw cast exception.
  factory VGDuetPreviewTexture.fromMap(Map<String, dynamic> map) {
    final rawId = map['textureId'];
    if (rawId == null) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message: 'attachDuetPreviewTexture: missing textureId in native reply.',
      );
    }
    final int textureId;
    if (rawId is int) {
      textureId = rawId;
    } else if (rawId is num) {
      textureId = rawId.toInt();
    } else {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message:
            'attachDuetPreviewTexture: textureId has unexpected type '
            '${rawId.runtimeType}.',
      );
    }

    final rawW = map['width'];
    final rawH = map['height'];
    if (rawW == null || rawH == null) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message:
            'attachDuetPreviewTexture: missing width/height in native reply.',
      );
    }
    final double w;
    final double h;
    if (rawW is num && rawH is num) {
      w = rawW.toDouble();
      h = rawH.toDouble();
    } else {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message:
            'attachDuetPreviewTexture: width/height have unexpected types.',
      );
    }

    final rawState = map['state'];
    if (rawState is! String) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message:
            "attachDuetPreviewTexture: 'state' is missing or not a String.",
      );
    }
    VGDuetPreviewTextureState? parsedState;
    for (final e in VGDuetPreviewTextureState.values) {
      if (e.name == rawState) {
        parsedState = e;
        break;
      }
    }
    if (parsedState == null) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message: "attachDuetPreviewTexture: unknown state '$rawState'.",
      );
    }
    final state = parsedState;

    Map<String, VGDuetRect>? layoutRects;
    final rawRects = map['layoutRects'];
    if (rawRects is Map) {
      layoutRects = {};
      for (final entry in rawRects.entries) {
        final key = entry.key as String;
        final val = entry.value;
        if (val is Map) {
          layoutRects[key] = VGDuetRect.fromMap(Map<String, dynamic>.from(val));
        }
      }
    }

    return VGDuetPreviewTexture(
      textureId: textureId,
      size: VGDuetSize(w, h),
      state: state,
      layoutRects: layoutRects?.isEmpty == true ? null : layoutRects,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetPreviewTexture &&
          textureId == other.textureId &&
          size == other.size &&
          state == other.state &&
          _mapsEqual(layoutRects, other.layoutRects);

  static bool _mapsEqual(
    Map<String, VGDuetRect>? a,
    Map<String, VGDuetRect>? b,
  ) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(textureId, size, state);

  @override
  String toString() =>
      'VGDuetPreviewTexture(id: $textureId, size: $size, state: ${state.name})';
}
