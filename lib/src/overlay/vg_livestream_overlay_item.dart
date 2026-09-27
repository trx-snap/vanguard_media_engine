// vg_livestream_overlay_item.dart
// Vanguard Media Engine — Slice G1-A
//
// Shared Dart contract for the livestream native text/sticker overlay.
//
// This is deliberately NOT the timeline/export overlay model
// ([VGOverlayDescriptor] / [VGOverlayKeyframe] in `vg_overlay_descriptor.dart`
// and `src/overlay/vg_overlay_keyframe.dart`): those are PTS-windowed,
// keyframe-animated, and built for the offline/export compositor. The
// livestream camera graph has no timeline — it composites the current
// wall-clock frame only — so this contract is deliberately smaller:
//
//   - No `startTimeSeconds` / `durationSeconds` (no PTS window).
//   - No keyframes, no interpolation, no animation.
//   - No rotation/scale — V1 is static placement only. `z` (paint order) IS
//     part of the authoritative wire schema (see [VGLivestreamOverlayItem.z]).
//   - Coordinates are normalized fractions of a PINNED 720×1280 portrait
//     canvas ([VGLivestreamOverlayCanvas]), not arbitrary canvas pixels.
//
// Dispatch model (see [CameraGraphComposer] in connectsapp_app): the full
// overlay list is replaced wholesale on every dispatch via a preset rebuild
// (`VGFilterSpecs.overlay(...)`) — there is no per-item hot update. An empty
// list clears every overlay.
//
// Validation policy: every check below throws [ArgumentError] unconditionally
// (never Dart `assert`, which is compiled out of release builds). Overlay
// content — free-form text, a sticker asset path — can originate from user
// input or a picker result, so a malformed value (an oversized string, a
// remote/URI path) must never reach native in a release build either.

/// The kind of content a [VGLivestreamOverlayItem] renders.
///
/// Wire values match the string this enum's [fromValue] parses and the
/// native handler expects in `parameters.items[].kind`.
enum VGLivestreamOverlayKind {
  /// Static rendered text.
  text('text'),

  /// A static bitmap sticker loaded from a local asset file.
  sticker('sticker');

  const VGLivestreamOverlayKind(this.value);

  /// The wire-format string value sent over the method channel.
  final String value;

  /// Resolves a wire-format string to [VGLivestreamOverlayKind].
  ///
  /// Throws [ArgumentError] if [value] is unrecognized — there is no silent
  /// fallback to a default kind.
  static VGLivestreamOverlayKind fromValue(String value) {
    for (final kind in VGLivestreamOverlayKind.values) {
      if (kind.value == value) return kind;
    }
    throw ArgumentError.value(
      value,
      'value',
      'Unrecognized VGLivestreamOverlayKind',
    );
  }
}

/// The pinned livestream overlay canvas: exactly 720×1280 portrait.
///
/// Every [VGLivestreamOverlayItem]'s `x`/`y`/`w`/`h` are normalized `[0, 1]`
/// fractions of this canvas — never raw pixels, and never a caller-supplied
/// size. V1 supports exactly one canvas (the livestream's fixed egress
/// resolution: see `VanguardCameraCaptureProfile.livestream720p`), so this
/// type has no configurable fields and no constructor parameters; it exists
/// only to name the pinned dimensions and produce the wire map native expects
/// under `parameters.canvas`.
final class VGLivestreamOverlayCanvas {
  const VGLivestreamOverlayCanvas._();

  /// The single instance. Canvas dimensions are pinned, not configurable —
  /// there is no other way to construct this type.
  static const VGLivestreamOverlayCanvas instance =
      VGLivestreamOverlayCanvas._();

  /// Pinned canvas width in pixels: 720 (portrait short edge).
  static const int width = 720;

  /// Pinned canvas height in pixels: 1280 (portrait long edge).
  static const int height = 1280;

  /// Serializes to the wire shape native expects under `parameters.canvas`.
  Map<String, Object?> toJson() => const <String, Object?>{
    'width': width,
    'height': height,
  };

  @override
  String toString() => 'VGLivestreamOverlayCanvas(${width}x$height)';
}

/// A single static text or sticker overlay positioned on the livestream
/// egress frame, normalized against the pinned [VGLivestreamOverlayCanvas]
/// (720×1280 portrait, top-left origin).
///
/// Immutable. All fields are validated eagerly in the constructor — an
/// invalid item can never exist. See [VGLivestreamOverlayItem.new] for the
/// exact validation rules.
final class VGLivestreamOverlayItem {
  /// Creates a validated overlay item.
  ///
  /// [x] / [y]: top-left position, normalized fraction of the pinned canvas.
  /// Each must be in `[0.0, 1.0]`.
  ///
  /// [w] / [h]: size, normalized fraction of the pinned canvas. Each must be
  /// in `(0.0, 1.0]` — zero or negative size is rejected.
  ///
  /// [opacity]: blend opacity, must be in `[0.0, 1.0]`. Defaults to `1.0`.
  ///
  /// [z]: paint order among overlay items in the same list — higher paints
  /// on top. Must be a non-negative integer in `[0, 1024]`. Defaults to `0`.
  ///
  /// [text] / [assetPath] are mutually exclusive, gated by [kind]:
  /// - [VGLivestreamOverlayKind.text]: [text] is required — non-empty and at
  ///   most 120 characters — and [assetPath] must be `null`.
  /// - [VGLivestreamOverlayKind.sticker]: [assetPath] is required — a
  ///   non-blank, absolute (`/`-prefixed) local filesystem path with no URI
  ///   scheme (`scheme://…` is rejected, so `http://`, `https://`,
  ///   `content://`, `file://` etc. are all rejected as "remote/URI paths")
  ///   ending in `.png`, `.jpg`, or `.jpeg` (case-insensitive) — and [text]
  ///   must be `null`.
  ///
  /// Throws [ArgumentError] for any violation above, including an empty [id].
  /// This validation is unconditional (not `assert`-based): it also runs in
  /// release builds, because overlay content can originate from user input.
  VGLivestreamOverlayItem({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.opacity = 1.0,
    this.z = 0,
    this.text,
    this.assetPath,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must be non-empty');
    }
    _requireInClosedRange('x', x, 0.0, 1.0);
    _requireInClosedRange('y', y, 0.0, 1.0);
    _requireInHalfOpenAboveZero('w', w, 1.0);
    _requireInHalfOpenAboveZero('h', h, 1.0);
    _requireInClosedRange('opacity', opacity, 0.0, 1.0);
    _requireIntInClosedRange('z', z, 0, 1024);

    switch (kind) {
      case VGLivestreamOverlayKind.text:
        final t = text;
        if (t == null || t.isEmpty) {
          throw ArgumentError.value(
            text,
            'text',
            'must be non-empty for a text overlay',
          );
        }
        if (t.length > 120) {
          throw ArgumentError.value(
            text,
            'text',
            'must be at most 120 characters for a text overlay '
                '(got ${t.length})',
          );
        }
        if (assetPath != null) {
          throw ArgumentError.value(
            assetPath,
            'assetPath',
            'must be null for a text overlay',
          );
        }
      case VGLivestreamOverlayKind.sticker:
        if (text != null) {
          throw ArgumentError.value(
            text,
            'text',
            'must be null for a sticker overlay',
          );
        }
        _requireStickerAssetPath(assetPath);
    }
  }

  /// Parses a wire-format map (as produced by [toJson]) into a validated
  /// [VGLivestreamOverlayItem].
  ///
  /// Throws [ArgumentError] if a required field is missing or has the wrong
  /// runtime type, if `kind` is unrecognized ([VGLivestreamOverlayKind.
  /// fromValue]), or if the resulting item fails the constructor's
  /// validation (see [VGLivestreamOverlayItem.new]).
  factory VGLivestreamOverlayItem.fromMap(Map<Object?, Object?> map) {
    final rawId = map['id'];
    if (rawId is! String) {
      throw ArgumentError.value(rawId, 'id', 'must be a String');
    }
    final rawKind = map['kind'];
    if (rawKind is! String) {
      throw ArgumentError.value(rawKind, 'kind', 'must be a String');
    }
    final kind = VGLivestreamOverlayKind.fromValue(rawKind);

    final rawText = map['text'];
    if (rawText != null && rawText is! String) {
      throw ArgumentError.value(rawText, 'text', 'must be a String or null');
    }
    final rawAssetPath = map['assetPath'];
    if (rawAssetPath != null && rawAssetPath is! String) {
      throw ArgumentError.value(
        rawAssetPath,
        'assetPath',
        'must be a String or null',
      );
    }
    final rawOpacity = map['opacity'];
    if (rawOpacity != null && rawOpacity is! num) {
      throw ArgumentError.value(rawOpacity, 'opacity', 'must be a number');
    }
    final rawZ = map['z'];
    if (rawZ != null && rawZ is! num) {
      throw ArgumentError.value(rawZ, 'z', 'must be a number');
    }

    return VGLivestreamOverlayItem(
      id: rawId,
      kind: kind,
      x: _requireNumField(map, 'x'),
      y: _requireNumField(map, 'y'),
      w: _requireNumField(map, 'w'),
      h: _requireNumField(map, 'h'),
      opacity: rawOpacity == null ? 1.0 : (rawOpacity as num).toDouble(),
      z: rawZ == null ? 0 : (rawZ as num).toInt(),
      text: rawText as String?,
      assetPath: rawAssetPath as String?,
    );
  }

  /// Stable identifier for this item within the overlay list. Non-empty.
  final String id;

  /// Whether this item renders [text] or a bitmap loaded from [assetPath].
  final VGLivestreamOverlayKind kind;

  /// Top-left x position, normalized fraction of the pinned canvas width,
  /// in `[0.0, 1.0]`.
  final double x;

  /// Top-left y position, normalized fraction of the pinned canvas height,
  /// in `[0.0, 1.0]`.
  final double y;

  /// Width, normalized fraction of the pinned canvas width, in `(0.0, 1.0]`.
  final double w;

  /// Height, normalized fraction of the pinned canvas height, in `(0.0, 1.0]`.
  final double h;

  /// Blend opacity in `[0.0, 1.0]`. Defaults to `1.0` (fully opaque).
  final double opacity;

  /// Paint order among overlay items in the same list — higher paints on
  /// top of lower. Non-negative, in `[0, 1024]`. Defaults to `0`.
  final int z;

  /// The rendered text. Required (non-empty, ≤120 chars) for
  /// [VGLivestreamOverlayKind.text]; always `null` for
  /// [VGLivestreamOverlayKind.sticker].
  final String? text;

  /// Absolute local filesystem path to a `.png`/`.jpg`/`.jpeg` sticker asset.
  /// Required for [VGLivestreamOverlayKind.sticker]; always `null` for
  /// [VGLivestreamOverlayKind.text].
  final String? assetPath;

  /// Serializes this item to the wire shape native expects inside
  /// `parameters.items[]`. Only the field that applies to [kind] (`text` or
  /// `assetPath`) is present — the other is omitted entirely, never sent as
  /// `null`.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.value,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'opacity': opacity,
    'z': z,
    if (text != null) 'text': text,
    if (assetPath != null) 'assetPath': assetPath,
  };

  @override
  String toString() =>
      'VGLivestreamOverlayItem(id: $id, kind: ${kind.value}, '
      'x: $x, y: $y, w: $w, h: $h, opacity: $opacity, z: $z, '
      'text: $text, assetPath: $assetPath)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGLivestreamOverlayItem &&
          other.id == id &&
          other.kind == kind &&
          other.x == x &&
          other.y == y &&
          other.w == w &&
          other.h == h &&
          other.opacity == opacity &&
          other.z == z &&
          other.text == text &&
          other.assetPath == assetPath;

  @override
  int get hashCode =>
      Object.hash(id, kind, x, y, w, h, opacity, z, text, assetPath);
}

// ── Validation helpers ───────────────────────────────────────────────────────

void _requireInClosedRange(String name, double value, double min, double max) {
  if (value.isNaN || value < min || value > max) {
    throw ArgumentError.value(value, name, 'must be in [$min, $max]');
  }
}

void _requireInHalfOpenAboveZero(String name, double value, double max) {
  if (value.isNaN || value <= 0.0 || value > max) {
    throw ArgumentError.value(value, name, 'must be in (0.0, $max]');
  }
}

void _requireIntInClosedRange(String name, int value, int min, int max) {
  if (value < min || value > max) {
    throw ArgumentError.value(value, name, 'must be in [$min, $max]');
  }
}

/// Absolute-local-path + extension policy shared by every sticker item.
///
/// Rejects: `null`/blank, any URI scheme (`scheme://…` — covers `http://`,
/// `https://`, `content://`, `file://`, etc., i.e. "remote/URI paths"), a
/// non-absolute path (must start with `/`), and any extension other than
/// `.png`/`.jpg`/`.jpeg` (case-insensitive).
void _requireStickerAssetPath(String? path) {
  if (path == null || path.trim().isEmpty) {
    throw ArgumentError.value(
      path,
      'assetPath',
      'must be a non-empty absolute local path for a sticker overlay',
    );
  }
  if (path.contains('://')) {
    throw ArgumentError.value(
      path,
      'assetPath',
      'must be an absolute local filesystem path, not a remote/URI path',
    );
  }
  if (!path.startsWith('/')) {
    throw ArgumentError.value(
      path,
      'assetPath',
      'must be an absolute local filesystem path starting with "/"',
    );
  }
  final lower = path.toLowerCase();
  if (!(lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg'))) {
    throw ArgumentError.value(
      path,
      'assetPath',
      'must end in .png, .jpg, or .jpeg (case-insensitive)',
    );
  }
}

double _requireNumField(Map<Object?, Object?> map, String key) {
  final raw = map[key];
  if (raw is! num) {
    throw ArgumentError.value(raw, key, 'must be a number');
  }
  return raw.toDouble();
}
