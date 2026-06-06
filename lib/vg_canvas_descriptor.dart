// vg_canvas_descriptor.dart
// Vanguard Media Engine — Phase 8.1
//
// Canvas + safe-zone descriptor for the UMF V2 render pipeline.
//
// Design rules (Phase 8.1):
//   - This is a pure Dart value type. No Flutter UI packages required.
//   - It describes the render canvas dimensions, content scaling policy,
//     background colour, and safe-zone insets.
//   - Data model only. It is NOT yet wired into VGEditorDraft, VGEditorController,
//     or any MethodChannel in Phase 8.1. Graph wiring is Phase 8.2.
//   - Source of truth: the native VGCanvasDescriptor.h/.m in packages/UMF/ios/Classes/.
//
// Wire keys (match native VGCanvasDescriptor serialization):
//   'width'           : int
//   'height'          : int
//   'contentMode'     : String — 'fit' | 'fill' | 'stretch'
//   'backgroundColor' : List<double> — [r, g, b, a], each in [0.0, 1.0]
//   'safeAreaTop'     : double (omitted from toMap() when 0)
//   'safeAreaBottom'  : double (omitted from toMap() when 0)
//   'safeAreaLeft'    : double (omitted from toMap() when 0)
//   'safeAreaRight'   : double (omitted from toMap() when 0)
//
// Recovery behaviour of fromMap() (mirrors native fromDictionary: exactly):
//   - Missing/invalid width or height → defaults (1080 × 1920).
//   - Missing/unknown contentMode string → VGCanvasContentMode.fit.
//   - Missing/malformed backgroundColor → [0, 0, 0, 1].
//   - Out-of-range backgroundColor components → clamped to [0.0, 1.0].
//   - Missing/negative safe-area values → 0.
//   - Returns null only when the map itself is null.

// ── VGCanvasContentMode ───────────────────────────────────────────────────────

/// How clip video frames are scaled to fill the canvas when their aspect ratio
/// differs from the canvas aspect ratio.
///
/// Wire values match the native `VGCanvasContentMode` enum strings.
enum VGCanvasContentMode {
  /// Scale clip proportionally to fit within the canvas.
  /// Black bars (letterbox / pillarbox) appear when aspect ratios differ.
  /// This is the default.
  fit('fit'),

  /// Scale clip proportionally to fill the canvas completely.
  /// The clip is centred; excess pixels are cropped by the canvas bounds.
  /// No black bars.
  fill('fill'),

  /// Scale clip non-proportionally to fill the canvas exactly.
  /// The clip is distorted if its aspect ratio differs from the canvas.
  /// **Phase 8.1**: enum value is present; rendering is deferred to Phase 8.3+.
  stretch('stretch');

  const VGCanvasContentMode(this.value);

  /// The wire-format string value sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding [VGCanvasContentMode].
  ///
  /// Returns [VGCanvasContentMode.fit] for unrecognised strings (safe default).
  static VGCanvasContentMode fromValue(String value) {
    return VGCanvasContentMode.values.firstWhere(
      (mode) => mode.value == value,
      orElse: () => VGCanvasContentMode.fit,
    );
  }
}

// ── VGCanvasDescriptor ────────────────────────────────────────────────────────

/// Canonical descriptor for the render canvas.
///
/// Describes the export dimensions, content scaling policy, background colour,
/// and safe-zone insets used when compositing timeline clips.
///
/// **Phase 8.1**: Data model only. Not yet wired into VGGraphDescriptor or any
/// MethodChannel. Graph wiring is Phase 8.2.
///
/// This is a pure value type. No Flutter UI packages are required.
///
/// ```dart
/// // Default canvas — 1080×1920, fit, black background, no safe zones.
/// final canvas = VGCanvasDescriptor();
///
/// // Custom canvas.
/// final canvas = VGCanvasDescriptor(
///   width: 1080,
///   height: 1920,
///   contentMode: VGCanvasContentMode.fill,
///   backgroundColor: [0.0, 0.0, 0.0, 1.0],
///   safeAreaTop: 44.0,
///   safeAreaBottom: 34.0,
/// );
/// ```
final class VGCanvasDescriptor {
  /// Creates a canvas descriptor.
  ///
  /// All parameters have sensible defaults matching the native implementation.
  ///
  /// [width] and [height] are export pixel dimensions. Both must be > 0.
  ///
  /// [backgroundColor] must be a list of exactly 4 doubles [R, G, B, A],
  /// each in [0.0, 1.0]. Components are clamped at construction.
  ///
  /// Safe-area inset parameters ([safeAreaTop], [safeAreaBottom],
  /// [safeAreaLeft], [safeAreaRight]) are in export pixels. Negative values
  /// are clamped to 0.
  VGCanvasDescriptor({
    this.width = 1080,
    this.height = 1920,
    this.contentMode = VGCanvasContentMode.fit,
    List<double> backgroundColor = const [0.0, 0.0, 0.0, 1.0],
    this.safeAreaTop = 0.0,
    this.safeAreaBottom = 0.0,
    this.safeAreaLeft = 0.0,
    this.safeAreaRight = 0.0,
  })  : assert(width > 0, 'width must be > 0'),
        assert(height > 0, 'height must be > 0'),
        assert(
          backgroundColor.length == 4,
          'backgroundColor must have exactly 4 elements [r, g, b, a]',
        ),
        assert(safeAreaTop >= 0.0, 'safeAreaTop must be >= 0'),
        assert(safeAreaBottom >= 0.0, 'safeAreaBottom must be >= 0'),
        assert(safeAreaLeft >= 0.0, 'safeAreaLeft must be >= 0'),
        assert(safeAreaRight >= 0.0, 'safeAreaRight must be >= 0'),
        backgroundColor = List<double>.unmodifiable(
          backgroundColor.map(_clampComponent),
        );

  // ── Dimensions ─────────────────────────────────────────────────────────────

  /// Export pixel width of the canvas. Must be > 0.
  ///
  /// Default: 1080 (vertical short-form format).
  final int width;

  /// Export pixel height of the canvas. Must be > 0.
  ///
  /// Default: 1920 (vertical short-form format).
  final int height;

  // ── Content scaling ────────────────────────────────────────────────────────

  /// How clip frames are scaled when their aspect ratio differs from the canvas.
  ///
  /// Default: [VGCanvasContentMode.fit] (letterbox / pillarbox).
  final VGCanvasContentMode contentMode;

  // ── Background ─────────────────────────────────────────────────────────────

  /// Background colour rendered behind all clip frames.
  ///
  /// Format: `[R, G, B, A]`, each component clamped to `[0.0, 1.0]`.
  ///
  /// Default: `[0.0, 0.0, 0.0, 1.0]` (opaque black).
  final List<double> backgroundColor;

  // ── Safe-zone insets ───────────────────────────────────────────────────────

  /// Safe-zone top inset in export pixels. Must be >= 0.
  ///
  /// Content should not be rendered in this region.
  /// Default: 0.0 (no safe-zone constraint).
  final double safeAreaTop;

  /// Safe-zone bottom inset in export pixels. Must be >= 0. Default: 0.0.
  final double safeAreaBottom;

  /// Safe-zone left inset in export pixels. Must be >= 0. Default: 0.0.
  final double safeAreaLeft;

  /// Safe-zone right inset in export pixels. Must be >= 0. Default: 0.0.
  final double safeAreaRight;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this descriptor to a JSON-compatible map.
  ///
  /// Safe-area inset keys are omitted when their value is 0.0 (minimal wire
  /// payload, matching native toDictionary behaviour).
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "width": 1080,
  ///   "height": 1920,
  ///   "contentMode": "fit",
  ///   "backgroundColor": [0.0, 0.0, 0.0, 1.0]
  /// }
  /// ```
  Map<String, Object> toMap() {
    final m = <String, Object>{
      'width': width,
      'height': height,
      'contentMode': contentMode.value,
      'backgroundColor': backgroundColor,
    };
    // Omit safe-area inset keys when 0 (minimal wire payload).
    if (safeAreaTop > 0.0)    m['safeAreaTop']    = safeAreaTop;
    if (safeAreaBottom > 0.0) m['safeAreaBottom']  = safeAreaBottom;
    if (safeAreaLeft > 0.0)   m['safeAreaLeft']    = safeAreaLeft;
    if (safeAreaRight > 0.0)  m['safeAreaRight']   = safeAreaRight;
    return m;
  }

  /// Deserialises a [VGCanvasDescriptor] from a map produced by [toMap].
  ///
  /// **Recovery behaviour** (no hard failures for missing / out-of-range values;
  /// mirrors the native `fromDictionary:` exactly):
  /// - Missing/invalid width or height → defaults (1080 × 1920).
  /// - Missing/unknown contentMode string → [VGCanvasContentMode.fit].
  /// - Missing/malformed backgroundColor → `[0, 0, 0, 1]`.
  /// - Out-of-range backgroundColor components → clamped to `[0.0, 1.0]`.
  /// - Missing/negative safe-area values → 0.
  ///
  /// Returns `null` only when the input map is `null`.
  static VGCanvasDescriptor? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;

    // Parse width (default: 1080).
    int width = 1080;
    final rawWidth = map['width'];
    if (rawWidth is num && rawWidth.toInt() > 0) {
      width = rawWidth.toInt();
    }

    // Parse height (default: 1920).
    int height = 1920;
    final rawHeight = map['height'];
    if (rawHeight is num && rawHeight.toInt() > 0) {
      height = rawHeight.toInt();
    }

    // Parse contentMode (default: fit).
    var contentMode = VGCanvasContentMode.fit;
    final rawMode = map['contentMode'];
    if (rawMode is String) {
      contentMode = VGCanvasContentMode.fromValue(rawMode);
    }

    // Parse backgroundColor (default: [0,0,0,1]; clamp components).
    List<double> backgroundColor = const [0.0, 0.0, 0.0, 1.0];
    final rawBg = map['backgroundColor'];
    if (rawBg is List && rawBg.length == 4) {
      final parsed = <double>[];
      var valid = true;
      for (final v in rawBg) {
        if (v is num) {
          parsed.add(_clampComponent(v.toDouble()));
        } else {
          valid = false;
          break;
        }
      }
      if (valid && parsed.length == 4) {
        backgroundColor = List<double>.unmodifiable(parsed);
      }
    }

    // Parse safe-area insets (default: 0; clamp negative values to 0).
    double safeAreaTop    = 0.0;
    double safeAreaBottom = 0.0;
    double safeAreaLeft   = 0.0;
    double safeAreaRight  = 0.0;

    final rawTop = map['safeAreaTop'];
    if (rawTop is num) safeAreaTop = rawTop.toDouble().clamp(0.0, double.infinity).toDouble();

    final rawBottom = map['safeAreaBottom'];
    if (rawBottom is num) safeAreaBottom = rawBottom.toDouble().clamp(0.0, double.infinity).toDouble();

    final rawLeft = map['safeAreaLeft'];
    if (rawLeft is num) safeAreaLeft = rawLeft.toDouble().clamp(0.0, double.infinity).toDouble();

    final rawRight = map['safeAreaRight'];
    if (rawRight is num) safeAreaRight = rawRight.toDouble().clamp(0.0, double.infinity).toDouble();

    return VGCanvasDescriptor(
      width: width,
      height: height,
      contentMode: contentMode,
      backgroundColor: backgroundColor,
      safeAreaTop: safeAreaTop,
      safeAreaBottom: safeAreaBottom,
      safeAreaLeft: safeAreaLeft,
      safeAreaRight: safeAreaRight,
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this descriptor with the specified fields replaced.
  VGCanvasDescriptor copyWith({
    int? width,
    int? height,
    VGCanvasContentMode? contentMode,
    List<double>? backgroundColor,
    double? safeAreaTop,
    double? safeAreaBottom,
    double? safeAreaLeft,
    double? safeAreaRight,
  }) {
    return VGCanvasDescriptor(
      width: width ?? this.width,
      height: height ?? this.height,
      contentMode: contentMode ?? this.contentMode,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      safeAreaTop: safeAreaTop ?? this.safeAreaTop,
      safeAreaBottom: safeAreaBottom ?? this.safeAreaBottom,
      safeAreaLeft: safeAreaLeft ?? this.safeAreaLeft,
      safeAreaRight: safeAreaRight ?? this.safeAreaRight,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VGCanvasDescriptor) return false;
    if (width != other.width) return false;
    if (height != other.height) return false;
    if (contentMode != other.contentMode) return false;
    if (backgroundColor.length != other.backgroundColor.length) return false;
    for (var i = 0; i < backgroundColor.length; i++) {
      if (backgroundColor[i] != other.backgroundColor[i]) return false;
    }
    if (safeAreaTop != other.safeAreaTop) return false;
    if (safeAreaBottom != other.safeAreaBottom) return false;
    if (safeAreaLeft != other.safeAreaLeft) return false;
    if (safeAreaRight != other.safeAreaRight) return false;
    return true;
  }

  @override
  int get hashCode => Object.hash(
        width,
        height,
        contentMode,
        Object.hashAll(backgroundColor),
        safeAreaTop,
        safeAreaBottom,
        safeAreaLeft,
        safeAreaRight,
      );

  @override
  String toString() {
    return 'VGCanvasDescriptor('
        'width=$width, height=$height, '
        'contentMode=${contentMode.value}, '
        'backgroundColor=$backgroundColor, '
        'safeArea=[top=$safeAreaTop, bottom=$safeAreaBottom, '
        'left=$safeAreaLeft, right=$safeAreaRight])';
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Clamps a double to [0.0, 1.0].
double _clampComponent(double v) => v.clamp(0.0, 1.0).toDouble();
