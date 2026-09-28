// vg_livestream_media_source.dart
// Vanguard Media Engine — Slice I1 (livestream live media source switching)
//
// Shared Dart contract for switching the live producer of a RUNNING Vanguard
// livestream (a virtual camera LiveKit track that was started camera-first)
// between the camera and a still image, without touching the track.
//
// Wire shape (MethodChannel "vanguard_livekit_bridge", method
// `setMediaSource`):
//
//   {mode: "camera"}
//   {mode: "image", imagePath: "/absolute/local/file.png"}
//
// Native replies `{status: "committed", mode, imagePath}` only once the new
// producer is live and committed; every failure is a PlatformException whose
// code names the reason (INVALID_IMAGE_PATH, IMAGE_DECODE_FAILED,
// NO_ACTIVE_STREAM, NO_ACTIVE_CAMERA / NO_CAMERA_GRAPH, SUPERSEDED, ...) and
// leaves the current producer untouched.
//
// Playlists are Dart-owned ([VGLivestreamImagePlaylist]): the app advances
// them on its own timer as repeated single image switches. Native never sees a
// playlist, an interval or a loop flag.
//
// Validation policy: every check throws [ArgumentError] unconditionally (never
// Dart `assert`), because an image path can come from a picker or user input
// and a malformed value must never reach native in a release build either.

/// Which producer feeds the live track.
enum VGLivestreamMediaSourceMode {
  /// The Vanguard camera pipeline (beauty → green screen → overlay → egress).
  camera('camera'),

  /// A still image, decoded once and pumped at the egress frame rate with the
  /// same overlays burned in; the camera hardware is suspended meanwhile.
  image('image');

  const VGLivestreamMediaSourceMode(this.value);

  /// The wire-format string value sent over the method channel.
  final String value;

  /// Resolves a wire-format string to [VGLivestreamMediaSourceMode].
  ///
  /// Throws [ArgumentError] if [value] is unrecognized.
  static VGLivestreamMediaSourceMode fromValue(String value) {
    for (final mode in VGLivestreamMediaSourceMode.values) {
      if (mode.value == value) return mode;
    }
    throw ArgumentError.value(
      value,
      'value',
      'Unrecognized VGLivestreamMediaSourceMode',
    );
  }
}

/// One native media source switch request: the camera, or a single still
/// image. Immutable and validated at construction.
final class VGLivestreamMediaSource {
  /// The camera producer.
  const VGLivestreamMediaSource.camera()
    : mode = VGLivestreamMediaSourceMode.camera,
      imagePath = null;

  /// The still image at [imagePath] (absolute local path, see
  /// [validateImagePath]). Throws [ArgumentError] for a malformed path.
  VGLivestreamMediaSource.image(String imagePath)
    : mode = VGLivestreamMediaSourceMode.image,
      imagePath = validateImagePath(imagePath);

  final VGLivestreamMediaSourceMode mode;

  /// Absolute local path of the still image; null for [mode] camera.
  final String? imagePath;

  /// File extensions accepted for a still image (case-insensitive). Native
  /// additionally checks readability and decodability before committing.
  static const Set<String> supportedImageExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.heic',
    '.heif',
  };

  /// Returns [imagePath] when it is a non-empty, absolute, scheme-less local
  /// path with a supported extension; throws [ArgumentError] otherwise.
  static String validateImagePath(String imagePath) {
    final trimmed = imagePath.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(imagePath, 'imagePath', 'must not be empty');
    }
    if (trimmed.contains('://')) {
      throw ArgumentError.value(
        imagePath,
        'imagePath',
        'must be a local filesystem path, not a remote/URI path',
      );
    }
    if (!trimmed.startsWith('/')) {
      throw ArgumentError.value(
        imagePath,
        'imagePath',
        'must be an absolute path starting with "/"',
      );
    }
    final lower = trimmed.toLowerCase();
    if (!supportedImageExtensions.any(lower.endsWith)) {
      throw ArgumentError.value(
        imagePath,
        'imagePath',
        'must end in one of ${supportedImageExtensions.join(', ')}',
      );
    }
    return trimmed;
  }

  /// The `setMediaSource` argument map.
  Map<String, Object?> toMap() => <String, Object?>{
    'mode': mode.value,
    if (imagePath != null) 'imagePath': imagePath,
  };

  @override
  bool operator ==(Object other) =>
      other is VGLivestreamMediaSource &&
      other.mode == mode &&
      other.imagePath == imagePath;

  @override
  int get hashCode => Object.hash(mode, imagePath);

  @override
  String toString() => imagePath == null
      ? 'VGLivestreamMediaSource.camera()'
      : 'VGLivestreamMediaSource.image($imagePath)';
}

/// A Dart-owned ordered list of still images shown one after another on the
/// live track. The app (see the livestream bridge in the ConnectsApp) drives
/// the timing: every [interval] it issues one plain
/// [VGLivestreamMediaSource.image] switch for the next entry, wrapping around
/// when [loop] is true and stopping on the last image otherwise.
///
/// Validated at construction: at least one image, every path passing
/// [VGLivestreamMediaSource.validateImagePath], and an [interval] of at least
/// [minimumInterval] so consecutive native switches never overlap.
final class VGLivestreamImagePlaylist {
  VGLivestreamImagePlaylist({
    required List<String> imagePaths,
    this.interval = const Duration(seconds: 5),
    this.loop = true,
  }) : imagePaths = List<String>.unmodifiable(
         imagePaths.map(VGLivestreamMediaSource.validateImagePath),
       ) {
    if (this.imagePaths.isEmpty) {
      throw ArgumentError.value(
        imagePaths,
        'imagePaths',
        'must contain at least one image',
      );
    }
    if (interval < minimumInterval) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be at least ${minimumInterval.inMilliseconds} ms',
      );
    }
  }

  /// Shortest allowed [interval].
  static const Duration minimumInterval = Duration(milliseconds: 500);

  /// Validated absolute local image paths, in play order.
  final List<String> imagePaths;

  /// Time each image stays live before the next switch is issued.
  final Duration interval;

  /// Whether to wrap around after the last image.
  final bool loop;

  /// Number of images.
  int get length => imagePaths.length;

  /// The single-image switch for entry [index].
  VGLivestreamMediaSource sourceAt(int index) =>
      VGLivestreamMediaSource.image(imagePaths[index]);

  @override
  String toString() =>
      'VGLivestreamImagePlaylist(${imagePaths.length} image(s), '
      'interval=${interval.inMilliseconds}ms, loop=$loop)';
}
