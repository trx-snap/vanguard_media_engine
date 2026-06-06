// vg_overlay_descriptor.dart
// Vanguard Media Engine — Phase 8.3
//
// Timed overlay element descriptor for the UMF V2 timeline.
//
// Design rules (Phase 8.3):
//   - Pure Dart value type. No Flutter UI packages required.
//   - Describes a single timed overlay (text, emoji, or sticker) placed on
//     the timeline canvas. Geometry is in absolute canvas pixels, top-left origin.
//   - Data model only. NOT yet wired into VGEditorController or any
//     MethodChannel in Phase 8.3. Graph wiring is Phase 8.4+.
//   - Source of truth: the native VGOverlayDescriptor.h/.m in
//     packages/UMF/ios/Classes/.
//
// Wire keys (match native VGOverlayDescriptor serialization exactly):
//   'id'               : String
//   'type'             : String — 'text' | 'emoji' | 'sticker'
//   'startTimeSeconds' : double
//   'durationSeconds'  : double
//   'translationX'     : double (canvas pixels)
//   'translationY'     : double (canvas pixels)
//   'width'            : double (canvas pixels)
//   'height'           : double (canvas pixels)
//   'rotation'         : double (radians, clockwise-positive)
//   'scale'            : double (default 1.0)
//   'opacity'          : double (clamped to [0.0, 1.0])
//   'zIndex'           : int
//   'textContent'      : String? (omitted from toMap() when null)
//   'assetPath'        : String? (omitted from toMap() when null)
//
// Recovery behaviour of fromMap() (mirrors native fromDictionary: exactly):
//   - Missing/invalid id → empty string.
//   - Missing/unknown type string → VGOverlayType.text.
//   - Missing/negative startTimeSeconds or durationSeconds → 0.0.
//   - Missing translationX/Y → 0.0.
//   - Missing/negative width or height → 0.0.
//   - Missing rotation → 0.0.
//   - Missing/invalid scale (<= 0) → 1.0.
//   - Missing opacity → 1.0; out-of-range → clamped to [0.0, 1.0].
//   - Missing zIndex → 0.
//   - Missing textContent → null.
//   - Missing assetPath → null.

// ── VGOverlayType ─────────────────────────────────────────────────────────────

/// The kind of overlay element.
///
/// Wire values match the native `VGOverlayType` enum strings.
enum VGOverlayType {
  /// A text overlay (may include styled text).
  /// This is the default / fallback for unknown type strings.
  text('text'),

  /// An emoji overlay (treated as pre-rendered text).
  emoji('emoji'),

  /// A sticker overlay sourced from a local/bundled asset file.
  sticker('sticker');

  const VGOverlayType(this.value);

  /// The wire-format string value sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding [VGOverlayType].
  ///
  /// Returns [VGOverlayType.text] for unrecognised strings (safe default).
  static VGOverlayType fromValue(String value) {
    return VGOverlayType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => VGOverlayType.text,
    );
  }
}

// ── VGOverlayDescriptor ───────────────────────────────────────────────────────

/// Canonical data model for a timed overlay element on the timeline canvas.
///
/// Describes a single text, emoji, or sticker overlay. Geometry is in absolute
/// canvas pixels with a top-left origin, relative to `VGEditorDraft.resolvedCanvas`.
///
/// **Phase 8.3**: Data model only. Not yet wired into VGGraphDescriptor or any
/// MethodChannel. Graph wiring is Phase 8.4+.
///
/// This is a pure value type. No Flutter UI packages are required.
///
/// ```dart
/// // Text overlay.
/// final overlay = VGOverlayDescriptor(
///   id: 'overlay-1',
///   type: VGOverlayType.text,
///   startTimeSeconds: 1.0,
///   durationSeconds: 3.0,
///   translationX: 100.0,
///   translationY: 200.0,
///   width: 300.0,
///   height: 80.0,
///   textContent: 'Hello world',
/// );
///
/// // Sticker overlay.
/// final sticker = VGOverlayDescriptor(
///   id: 'sticker-1',
///   type: VGOverlayType.sticker,
///   startTimeSeconds: 0.5,
///   durationSeconds: 2.0,
///   translationX: 50.0,
///   translationY: 50.0,
///   width: 120.0,
///   height: 120.0,
///   assetPath: 'assets/stickers/star.png',
/// );
/// ```
final class VGOverlayDescriptor {
  /// Creates an overlay descriptor.
  ///
  /// All parameters have sensible defaults. Clamping and validation are applied
  /// at construction time.
  ///
  /// [startTimeSeconds] and [durationSeconds] are clamped to >= 0.
  /// [width] and [height] are clamped to >= 0.
  /// [scale] must be > 0; invalid values (including 0 and negative) → 1.0.
  /// [opacity] is clamped to [0.0, 1.0].
  VGOverlayDescriptor({
    this.id = '',
    this.type = VGOverlayType.text,
    double startTimeSeconds = 0.0,
    double durationSeconds = 0.0,
    this.translationX = 0.0,
    this.translationY = 0.0,
    double width = 0.0,
    double height = 0.0,
    this.rotation = 0.0,
    double scale = 1.0,
    double opacity = 1.0,
    this.zIndex = 0,
    this.textContent,
    this.assetPath,
  })  : startTimeSeconds = startTimeSeconds < 0.0 ? 0.0 : startTimeSeconds,
        durationSeconds = durationSeconds < 0.0 ? 0.0 : durationSeconds,
        width = width < 0.0 ? 0.0 : width,
        height = height < 0.0 ? 0.0 : height,
        scale = (scale <= 0.0) ? 1.0 : scale,
        opacity = opacity.clamp(0.0, 1.0);

  // ── Identity ───────────────────────────────────────────────────────────────

  /// Unique identifier for this overlay within a draft.
  ///
  /// Default: empty string. Callers are responsible for ensuring uniqueness.
  final String id;

  /// The kind of overlay element.
  ///
  /// Default: [VGOverlayType.text].
  final VGOverlayType type;

  // ── Timeline ───────────────────────────────────────────────────────────────

  /// Timeline-local start time in seconds. Clamped to >= 0. Default: 0.0.
  final double startTimeSeconds;

  /// Duration of the overlay on the timeline in seconds. Clamped to >= 0.
  ///
  /// Default: 0.0.
  final double durationSeconds;

  // ── Geometry ───────────────────────────────────────────────────────────────

  /// X position of the overlay's top-left corner in canvas pixels.
  ///
  /// Coordinate origin is top-left of the canvas. Default: 0.0.
  final double translationX;

  /// Y position of the overlay's top-left corner in canvas pixels.
  ///
  /// Coordinate origin is top-left of the canvas. Default: 0.0.
  final double translationY;

  /// Overlay width in canvas pixels. Clamped to >= 0. Default: 0.0.
  final double width;

  /// Overlay height in canvas pixels. Clamped to >= 0. Default: 0.0.
  final double height;

  /// Rotation in radians, clockwise-positive. Default: 0.0.
  final double rotation;

  /// Uniform scale factor applied to the overlay. Default: 1.0.
  ///
  /// Invalid values (<= 0) are replaced with 1.0.
  final double scale;

  /// Opacity of the overlay in [0.0, 1.0]. Clamped at construction.
  ///
  /// Default: 1.0 (fully opaque).
  final double opacity;

  // ── Draw order ─────────────────────────────────────────────────────────────

  /// Draw order index. Higher values render on top. Default: 0.
  final int zIndex;

  // ── Content ────────────────────────────────────────────────────────────────

  /// Text content for text/emoji overlays. Null for sticker overlays.
  final String? textContent;

  /// Local/bundled asset path for sticker overlays.
  ///
  /// Null for text/emoji overlays.
  ///
  /// **Phase 8.3**: Raw path string only. Asset resolution is Phase 8.4+.
  final String? assetPath;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this descriptor to a JSON-compatible map.
  ///
  /// [textContent] and [assetPath] are omitted when null (minimal wire payload).
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "id": "overlay-1",
  ///   "type": "text",
  ///   "startTimeSeconds": 1.0,
  ///   "durationSeconds": 3.0,
  ///   "translationX": 100.0,
  ///   "translationY": 200.0,
  ///   "width": 300.0,
  ///   "height": 80.0,
  ///   "rotation": 0.0,
  ///   "scale": 1.0,
  ///   "opacity": 1.0,
  ///   "zIndex": 0,
  ///   "textContent": "Hello world"
  /// }
  /// ```
  Map<String, Object> toMap() {
    final m = <String, Object>{
      'id': id,
      'type': type.value,
      'startTimeSeconds': startTimeSeconds,
      'durationSeconds': durationSeconds,
      'translationX': translationX,
      'translationY': translationY,
      'width': width,
      'height': height,
      'rotation': rotation,
      'scale': scale,
      'opacity': opacity,
      'zIndex': zIndex,
    };
    // Omit optional string fields when null (minimal wire payload).
    if (textContent != null) m['textContent'] = textContent!;
    if (assetPath != null) m['assetPath'] = assetPath!;
    return m;
  }

  /// Deserialises a [VGOverlayDescriptor] from a map produced by [toMap].
  ///
  /// **Recovery behaviour** (no hard failures; mirrors native `fromDictionary:`):
  /// - Missing/invalid id → empty string.
  /// - Missing/unknown type string → [VGOverlayType.text].
  /// - Missing/negative startTimeSeconds or durationSeconds → 0.0.
  /// - Missing translationX/Y → 0.0.
  /// - Missing/negative width or height → 0.0.
  /// - Missing rotation → 0.0.
  /// - Missing/invalid scale (<= 0) → 1.0.
  /// - Missing opacity → 1.0; out-of-range → clamped to [0.0, 1.0].
  /// - Missing zIndex → 0.
  /// - Missing textContent → null.
  /// - Missing assetPath → null.
  ///
  /// Returns `null` only when the input map is `null`.
  static VGOverlayDescriptor? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;

    // Parse id (default: empty string).
    final rawId = map['id'];
    final String overlayId = (rawId is String) ? rawId : '';

    // Parse type (default: text).
    final rawType = map['type'];
    final VGOverlayType type = (rawType is String)
        ? VGOverlayType.fromValue(rawType)
        : VGOverlayType.text;

    // Parse timing (default: 0; negative → 0 via constructor clamping).
    final rawStart = map['startTimeSeconds'];
    final double startTimeSeconds =
        (rawStart is num) ? rawStart.toDouble() : 0.0;

    final rawDuration = map['durationSeconds'];
    final double durationSeconds =
        (rawDuration is num) ? rawDuration.toDouble() : 0.0;

    // Parse geometry.
    final rawTX = map['translationX'];
    final double translationX = (rawTX is num) ? rawTX.toDouble() : 0.0;

    final rawTY = map['translationY'];
    final double translationY = (rawTY is num) ? rawTY.toDouble() : 0.0;

    final rawWidth = map['width'];
    final double width = (rawWidth is num) ? rawWidth.toDouble() : 0.0;

    final rawHeight = map['height'];
    final double height = (rawHeight is num) ? rawHeight.toDouble() : 0.0;

    final rawRotation = map['rotation'];
    final double rotation = (rawRotation is num) ? rawRotation.toDouble() : 0.0;

    // Parse scale (default: 1.0; invalid <= 0 → handled by constructor).
    final rawScale = map['scale'];
    final double scale = (rawScale is num) ? rawScale.toDouble() : 1.0;

    // Parse opacity (default: 1.0; out-of-range → clamped by constructor).
    final rawOpacity = map['opacity'];
    final double opacity = (rawOpacity is num) ? rawOpacity.toDouble() : 1.0;

    // Parse zIndex (default: 0).
    final rawZIndex = map['zIndex'];
    final int zIndex = (rawZIndex is num) ? rawZIndex.toInt() : 0;

    // Parse optional string fields.
    final rawTextContent = map['textContent'];
    final String? textContent = (rawTextContent is String) ? rawTextContent : null;

    final rawAssetPath = map['assetPath'];
    final String? assetPath = (rawAssetPath is String) ? rawAssetPath : null;

    return VGOverlayDescriptor(
      id: overlayId,
      type: type,
      startTimeSeconds: startTimeSeconds,
      durationSeconds: durationSeconds,
      translationX: translationX,
      translationY: translationY,
      width: width,
      height: height,
      rotation: rotation,
      scale: scale,
      opacity: opacity,
      zIndex: zIndex,
      textContent: textContent,
      assetPath: assetPath,
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this descriptor with the specified fields replaced.
  VGOverlayDescriptor copyWith({
    String? id,
    VGOverlayType? type,
    double? startTimeSeconds,
    double? durationSeconds,
    double? translationX,
    double? translationY,
    double? width,
    double? height,
    double? rotation,
    double? scale,
    double? opacity,
    int? zIndex,
    String? textContent,
    String? assetPath,
  }) {
    return VGOverlayDescriptor(
      id: id ?? this.id,
      type: type ?? this.type,
      startTimeSeconds: startTimeSeconds ?? this.startTimeSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      translationX: translationX ?? this.translationX,
      translationY: translationY ?? this.translationY,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      opacity: opacity ?? this.opacity,
      zIndex: zIndex ?? this.zIndex,
      textContent: textContent ?? this.textContent,
      assetPath: assetPath ?? this.assetPath,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VGOverlayDescriptor) return false;
    return id == other.id &&
        type == other.type &&
        startTimeSeconds == other.startTimeSeconds &&
        durationSeconds == other.durationSeconds &&
        translationX == other.translationX &&
        translationY == other.translationY &&
        width == other.width &&
        height == other.height &&
        rotation == other.rotation &&
        scale == other.scale &&
        opacity == other.opacity &&
        zIndex == other.zIndex &&
        textContent == other.textContent &&
        assetPath == other.assetPath;
  }

  @override
  int get hashCode => Object.hash(
        id,
        type,
        startTimeSeconds,
        durationSeconds,
        translationX,
        translationY,
        width,
        height,
        rotation,
        scale,
        opacity,
        zIndex,
        textContent,
        assetPath,
      );

  @override
  String toString() {
    return 'VGOverlayDescriptor('
        'id: $id, '
        'type: ${type.value}, '
        'start: ${startTimeSeconds.toStringAsFixed(2)}s, '
        'duration: ${durationSeconds.toStringAsFixed(2)}s, '
        'pos: (${translationX.toStringAsFixed(0)}, ${translationY.toStringAsFixed(0)}), '
        'size: ${width.toStringAsFixed(0)}×${height.toStringAsFixed(0)}, '
        'rot: ${rotation.toStringAsFixed(3)}, '
        'scale: ${scale.toStringAsFixed(2)}, '
        'opacity: ${opacity.toStringAsFixed(2)}, '
        'zIndex: $zIndex)';
  }
}
