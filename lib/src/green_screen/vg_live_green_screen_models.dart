// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.
//
// Generic live green-screen contracts (Android first; iOS deferred).
// Caller-agnostic: live meeting/calling, going live, camera, and any other
// surface that needs a keyed live camera composited over a static background
// starts one session through these types. This boundary is separate from the
// offline export contracts in vg_green_screen_models.dart (shared by import
// only) and from Duet, which keeps its own session, events, and PiP fallback.
//
// v1 scope: the engine owns the camera; the background is a static solid
// color or image filling the full canvas; the foreground transform moves and
// scales only the keyed camera layer. Video backgrounds, external frame
// ingest, recording/export, and app UI wiring are deferred.
//
// Wire contract (MethodChannel `vanguard_media_engine`):
//   startLiveGreenScreenSession     → [VGLiveGreenScreenConfig.toMap]
//                                     ← [VGLiveGreenScreenSession.fromMap]
//   updateLiveGreenScreenBackground → {sessionId, background}
//   updateLiveGreenScreenTransform  → {sessionId, foregroundTransform}
//   stopLiveGreenScreenSession      → {sessionId}
//   errors → `INVALID_ARG`, `live_busy`, `cameraUnavailable`,
//            `composition_failed`, `session_not_found`, mapped by
//            [VGLiveGreenScreenErrorCode.fromPlatformCode].

import 'vg_green_screen_models.dart'
    show
        VGGreenScreenBackgroundSource,
        VGGreenScreenImageFileBackground,
        VGGreenScreenSize,
        VGGreenScreenSolidColorBackground,
        VGGreenScreenVideoFileBackground;

// ─────────────────────────────────────────────────────────────────────────────
// Foreground transform
// ─────────────────────────────────────────────────────────────────────────────

/// Moves and scales only the keyed camera layer; the background always fills
/// the full canvas.
///
/// Semantics mirror the engine's green-screen geometry (v1 — shrink and
/// reposition only):
/// - [scale] is clamped natively to `[0.25, 1.0]`;
/// - [offsetX] / [offsetY] are a normalized canvas-center translation, clamped
///   natively to `[-1.0, 1.0]`;
/// - [anchorX] / [anchorY] is the point within the scaled rect (`[0.0, 1.0]`)
///   that maps to canvas-center + offset;
/// - the resulting rect is clamped fully inside the canvas.
class VGLiveGreenScreenForegroundTransform {
  /// Uniform scale of the camera layer rect. Must be finite and positive.
  final double scale;

  /// Normalized horizontal canvas-center translation.
  final double offsetX;

  /// Normalized vertical canvas-center translation.
  final double offsetY;

  /// Horizontal anchor within the scaled rect.
  final double anchorX;

  /// Vertical anchor within the scaled rect.
  final double anchorY;

  /// Identity transform: full-canvas rect, no offset, centered anchor.
  static const VGLiveGreenScreenForegroundTransform identity =
      VGLiveGreenScreenForegroundTransform();

  /// Constructs a transform. Only [scale] positivity is asserted; range
  /// clamping is performed by the native geometry.
  const VGLiveGreenScreenForegroundTransform({
    this.scale = 1.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.anchorX = 0.5,
    this.anchorY = 0.5,
  }) : assert(scale > 0.0, 'scale must be positive');

  /// Constructs a transform with runtime validation.
  ///
  /// Throws [ArgumentError] when [scale] is not finite or not positive, or
  /// when any offset/anchor component is not finite.
  factory VGLiveGreenScreenForegroundTransform.validated({
    required double scale,
    double offsetX = 0.0,
    double offsetY = 0.0,
    double anchorX = 0.5,
    double anchorY = 0.5,
  }) {
    if (!scale.isFinite || scale <= 0.0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and > 0');
    }
    for (final entry in <String, double>{
      'offsetX': offsetX,
      'offsetY': offsetY,
      'anchorX': anchorX,
      'anchorY': anchorY,
    }.entries) {
      if (!entry.value.isFinite) {
        throw ArgumentError.value(entry.value, entry.key, 'must be finite');
      }
    }
    return VGLiveGreenScreenForegroundTransform(
      scale: scale,
      offsetX: offsetX,
      offsetY: offsetY,
      anchorX: anchorX,
      anchorY: anchorY,
    );
  }

  /// Whether this transform leaves the camera layer covering the full canvas.
  bool get isIdentity => scale >= 1.0 && offsetX == 0.0 && offsetY == 0.0;

  /// Wire shape shared with the native geometry parser:
  /// `{scale, offset: {x, y}, anchor: {x, y}}`.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'scale': scale,
    'offset': <String, dynamic>{'x': offsetX, 'y': offsetY},
    'anchor': <String, dynamic>{'x': anchorX, 'y': anchorY},
  };

  /// Parses a transform map. Malformed values degrade rather than throw: a
  /// bad scale yields [identity]; missing or non-finite offset components
  /// default to `0.0`, anchor components to `0.5`.
  factory VGLiveGreenScreenForegroundTransform.fromMap(
    Map<String, dynamic> map,
  ) {
    final rawScale = (map['scale'] as num?)?.toDouble() ?? 1.0;
    if (!rawScale.isFinite || rawScale <= 0.0) {
      return VGLiveGreenScreenForegroundTransform.identity;
    }
    final offset = map['offset'];
    final anchor = map['anchor'];
    return VGLiveGreenScreenForegroundTransform(
      scale: rawScale,
      offsetX: _component(offset, 'x', 0.0),
      offsetY: _component(offset, 'y', 0.0),
      anchorX: _component(anchor, 'x', 0.5),
      anchorY: _component(anchor, 'y', 0.5),
    );
  }

  static double _component(dynamic point, String key, double fallback) {
    if (point is! Map) return fallback;
    final value = (point[key] as num?)?.toDouble();
    if (value == null || !value.isFinite) return fallback;
    return value;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGLiveGreenScreenForegroundTransform &&
          scale == other.scale &&
          offsetX == other.offsetX &&
          offsetY == other.offsetY &&
          anchorX == other.anchorX &&
          anchorY == other.anchorY;

  @override
  int get hashCode => Object.hash(scale, offsetX, offsetY, anchorX, anchorY);

  @override
  String toString() =>
      'VGLiveGreenScreenForegroundTransform(scale: $scale, '
      'offset: ($offsetX, $offsetY), anchor: ($anchorX, $anchorY))';
}

// ─────────────────────────────────────────────────────────────────────────────
// Session config
// ─────────────────────────────────────────────────────────────────────────────

/// Everything needed to start one live green-screen session.
///
/// [background] must be a [VGGreenScreenSolidColorBackground], a
/// [VGGreenScreenImageFileBackground], or a [VGGreenScreenVideoFileBackground]
/// with a non-blank path.
class VGLiveGreenScreenConfig {
  /// Pixel size of the composited output texture.
  final VGGreenScreenSize canvasSize;

  /// Static background drawn beneath the keyed camera, filling the canvas.
  final VGGreenScreenBackgroundSource background;

  /// Placement of the keyed camera layer. Defaults to
  /// [VGLiveGreenScreenForegroundTransform.identity].
  final VGLiveGreenScreenForegroundTransform foregroundTransform;

  /// Throws [ArgumentError] when [background] is not supported by the live
  /// session (see [validateBackground]).
  VGLiveGreenScreenConfig({
    required this.canvasSize,
    required this.background,
    this.foregroundTransform = VGLiveGreenScreenForegroundTransform.identity,
  }) {
    validateBackground(background);
  }

  /// Throws [ArgumentError] unless [background] is a solid color, an image
  /// file with a non-blank path, or a video file with a non-blank path.
  static void validateBackground(VGGreenScreenBackgroundSource background) {
    switch (background) {
      case VGGreenScreenSolidColorBackground():
        return;
      case VGGreenScreenImageFileBackground(:final path):
        if (path.trim().isEmpty) {
          throw ArgumentError.value(
            path,
            'background.path',
            'must not be blank',
          );
        }
        return;
      case VGGreenScreenVideoFileBackground(:final path):
        if (path.trim().isEmpty) {
          throw ArgumentError.value(
            path,
            'background.path',
            'must not be blank',
          );
        }
        return;
    }
  }

  /// Converts a generic background to the native live-session wire map:
  /// `{type: solidColor, argbColor}`, `{type: image, filePath, scaleMode}`,
  /// or `{type: video, filePath, scaleMode}`.
  static Map<String, dynamic> backgroundToNativeMap(
    VGGreenScreenBackgroundSource background,
  ) {
    validateBackground(background);
    switch (background) {
      case VGGreenScreenSolidColorBackground(:final argbColor):
        return <String, dynamic>{'type': 'solidColor', 'argbColor': argbColor};
      case VGGreenScreenImageFileBackground(:final path, :final scaleMode):
        return <String, dynamic>{
          'type': 'image',
          'filePath': path,
          'scaleMode': scaleMode.name,
        };
      case VGGreenScreenVideoFileBackground(:final path):
        return <String, dynamic>{
          'type': 'video',
          'filePath': path,
          'scaleMode': 'aspectFill',
        };
    }
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'canvasSize': canvasSize.toMap(),
    'background': backgroundToNativeMap(background),
    'foregroundTransform': foregroundTransform.toMap(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGLiveGreenScreenConfig &&
          canvasSize == other.canvasSize &&
          background == other.background &&
          foregroundTransform == other.foregroundTransform;

  @override
  int get hashCode => Object.hash(canvasSize, background, foregroundTransform);

  @override
  String toString() =>
      'VGLiveGreenScreenConfig(canvasSize: $canvasSize, '
      'background: $background, foregroundTransform: $foregroundTransform)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Session descriptor
// ─────────────────────────────────────────────────────────────────────────────

/// A started live green-screen session: its id and the Flutter texture that
/// presents the composited output.
class VGLiveGreenScreenSession {
  /// Opaque native session id passed to every subsequent call.
  final String sessionId;

  /// Flutter texture registry id for a `Texture` widget.
  final int textureId;

  /// Pixel size of the output texture.
  final VGGreenScreenSize canvasSize;

  const VGLiveGreenScreenSession({
    required this.sessionId,
    required this.textureId,
    required this.canvasSize,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
    'sessionId': sessionId,
    'textureId': textureId,
    'width': canvasSize.width,
    'height': canvasSize.height,
  };

  /// Parses the native start reply. Throws [ArgumentError] when `sessionId`,
  /// `textureId`, `width`, or `height` is missing or has the wrong type.
  factory VGLiveGreenScreenSession.fromMap(Map<String, dynamic> map) {
    final sessionId = map['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw ArgumentError(
        'VGLiveGreenScreenSession.fromMap: missing or invalid "sessionId".',
      );
    }
    final textureId = map['textureId'];
    if (textureId is! num) {
      throw ArgumentError(
        'VGLiveGreenScreenSession.fromMap: missing or invalid "textureId".',
      );
    }
    final width = map['width'];
    final height = map['height'];
    if (width is! num || height is! num || width <= 0 || height <= 0) {
      throw ArgumentError(
        'VGLiveGreenScreenSession.fromMap: missing or invalid "width"/"height".',
      );
    }
    return VGLiveGreenScreenSession(
      sessionId: sessionId,
      textureId: textureId.toInt(),
      canvasSize: VGGreenScreenSize(width.toInt(), height.toInt()),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGLiveGreenScreenSession &&
          sessionId == other.sessionId &&
          textureId == other.textureId &&
          canvasSize == other.canvasSize;

  @override
  int get hashCode => Object.hash(sessionId, textureId, canvasSize);

  @override
  String toString() =>
      'VGLiveGreenScreenSession(sessionId: $sessionId, '
      'textureId: $textureId, canvasSize: $canvasSize)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

/// Typed failure classes for [VGLiveGreenScreenException].
enum VGLiveGreenScreenErrorCode {
  /// The request was rejected before any work started (`INVALID_ARG`).
  invalidArgument,

  /// Another live green-screen session is active, or the camera is held by
  /// another engine session such as Duet (`live_busy`).
  liveBusy,

  /// The camera cannot be used: permission not granted or no camera context
  /// (`cameraUnavailable`).
  cameraUnavailable,

  /// The preview texture or compositor could not be created, or the engine
  /// has been disposed (`composition_failed`).
  compositionFailed,

  /// No active live session matches the given id (`session_not_found`).
  sessionNotFound,

  /// Any other platform or channel error.
  unknown;

  /// Maps a native `PlatformException.code` to a typed code.
  static VGLiveGreenScreenErrorCode fromPlatformCode(String? code) =>
      switch (code) {
        'INVALID_ARG' => VGLiveGreenScreenErrorCode.invalidArgument,
        'live_busy' => VGLiveGreenScreenErrorCode.liveBusy,
        'cameraUnavailable' => VGLiveGreenScreenErrorCode.cameraUnavailable,
        'composition_failed' => VGLiveGreenScreenErrorCode.compositionFailed,
        'session_not_found' => VGLiveGreenScreenErrorCode.sessionNotFound,
        _ => VGLiveGreenScreenErrorCode.unknown,
      };
}

/// Typed exception for live green-screen failures from platform/channel
/// calls. Local model validation errors use [ArgumentError] directly.
class VGLiveGreenScreenException implements Exception {
  final VGLiveGreenScreenErrorCode code;
  final String message;
  final Object? cause;

  /// Native error details when reported.
  final Object? details;

  const VGLiveGreenScreenException({
    required this.code,
    required this.message,
    this.cause,
    this.details,
  });

  @override
  String toString() =>
      'VGLiveGreenScreenException(code: ${code.name}, message: $message'
      '${cause != null ? ', cause: $cause' : ''})';
}
