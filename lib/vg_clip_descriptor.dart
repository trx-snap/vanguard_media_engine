// vg_clip_descriptor.dart
// Vanguard Media Engine — Phase 7 Stage 7.1
//
// Non-destructive clip descriptor for the UMF V2 timeline editor.
//
// Design rules (DEC-V2-026 / Phase 7):
//   - This is a pure Dart value type describing clip metadata.
//   - It does NOT mutate, transcode, or re-encode any source media file.
//   - The source file at [sourcePath] remains immutable at all times.
//   - This descriptor is consumed by VGEditorGraphFactory (Stage 7.4) and
//     ultimately by VGTimelineCompositorNode (Stage 7.5) on the native side.
//   - In Stage 7.1 there is no native rendering of these values. The descriptor
//     is used only for Dart-layer timeline math and playground validation.
//
// Serialisation:
//   toMap() produces a JSON-compatible map:
//   {
//     'id': String,
//     'sourcePath': String,
//     'mediaKind': String,       // 'video' | 'audio' | 'image' | 'unknown'
//     'startTimeSeconds': double,
//     'durationSeconds': double,
//     'trimStartSeconds': double,
//     'trimEndSeconds': double,
//     'speed': double,
//   }

/// A transport-safe, non-destructive description of a single media clip in a
/// Phase 7 timeline arrangement.
///
/// [VGClipDescriptor] is a pure value type. It holds timeline metadata only.
/// It **never** mutates the source file at [sourcePath]. The source media
/// remains immutable; all edits exist exclusively in this descriptor.
///
/// Consumed (Stage 7.4+) by `VGEditorGraphFactory` to build a
/// `VGGraphDescriptor` topology for `VGTimelineCompositorNode`.
///
/// ```dart
/// final clip = VGClipDescriptor(
///   id: 'clip-01',
///   sourcePath: '/tmp/recording.mp4',
///   mediaKind: VGMediaKind.video,
///   startTimeSeconds: 0.0,
///   durationSeconds: 10.0,
///   trimStartSeconds: 1.0,
///   trimEndSeconds: 8.5,
/// );
/// print(clip.trimDuration); // 7.5
/// ```
final class VGClipDescriptor {
  /// Creates a non-destructive clip descriptor.
  ///
  /// [id] is a stable, caller-supplied identifier for this clip within a
  /// timeline arrangement. Should be unique within one timeline.
  ///
  /// [sourcePath] is the absolute local path to the source media file.
  /// The file is **never** modified by this descriptor.
  ///
  /// [mediaKind] indicates the primary media stream type.
  ///
  /// [startTimeSeconds] is the position on the global timeline (in seconds)
  /// at which this clip begins playing. Must be >= 0.
  ///
  /// [durationSeconds] is the native/full duration of the source asset
  /// (before trimming) in seconds. Must be >= 0.
  ///
  /// [trimStartSeconds] is the start of the active trim window within the
  /// source, measured from the start of the source asset (not the timeline).
  /// Must be >= 0 and < [trimEndSeconds].
  ///
  /// [trimEndSeconds] is the end of the active trim window within the source.
  /// Must be > [trimStartSeconds] and <= [durationSeconds] when non-zero.
  ///
  /// [speed] is a speed multiplier applied to playback. 1.0 = normal speed.
  /// Must be > 0. Slow motion: 0 < speed < 1. Fast motion: speed > 1.
  const VGClipDescriptor({
    required this.id,
    required this.sourcePath,
    this.mediaKind = VGMediaKind.video,
    this.startTimeSeconds = 0.0,
    required this.durationSeconds,
    this.trimStartSeconds = 0.0,
    required this.trimEndSeconds,
    this.speed = 1.0,
  })  : assert(startTimeSeconds >= 0, 'startTimeSeconds must be >= 0'),
        assert(durationSeconds >= 0, 'durationSeconds must be >= 0'),
        assert(trimStartSeconds >= 0, 'trimStartSeconds must be >= 0'),
        assert(trimEndSeconds > trimStartSeconds,
            'trimEndSeconds must be > trimStartSeconds'),
        assert(speed > 0, 'speed must be > 0');

  // ── Identity ───────────────────────────────────────────────────────────────

  /// Stable identifier for this clip within a timeline arrangement.
  ///
  /// Must be unique within one timeline. Callers may use UUIDs, sequential
  /// integers cast to strings, or descriptive keys.
  final String id;

  // ── Source ─────────────────────────────────────────────────────────────────

  /// Absolute local path to the source media asset.
  ///
  /// The file at this path is **never modified** by this descriptor or the
  /// timeline compositor. All editing is non-destructive; changes exist only
  /// in this descriptor until a final export pass renders the output.
  final String sourcePath;

  /// The primary media stream type of the source asset.
  final VGMediaKind mediaKind;

  // ── Timeline placement ────────────────────────────────────────────────────

  /// Position on the global timeline (in seconds) at which this clip starts.
  ///
  /// Multiple clips may be placed consecutively or with gaps. The timeline
  /// compositor maps global playhead PTS to the correct clip-local PTS using
  /// this value together with [trimStartSeconds] and [speed].
  final double startTimeSeconds;

  // ── Source asset geometry ─────────────────────────────────────────────────

  /// Full native duration of the source asset in seconds (before any trim).
  ///
  /// Use `VanguardEngine.probeVideoDuration` to populate this field.
  /// A value of 0.0 is permitted for unknown-duration assets (e.g. streaming
  /// sources) but will result in no-op trim clamping.
  final double durationSeconds;

  // ── Trim window ───────────────────────────────────────────────────────────

  /// Start of the active trim window within the source asset, in seconds.
  ///
  /// Measured from the beginning of the source file (not the global timeline).
  /// The compositor begins decoding from this offset. Must be >= 0.
  final double trimStartSeconds;

  /// End of the active trim window within the source asset, in seconds.
  ///
  /// Measured from the beginning of the source file (not the global timeline).
  /// The compositor stops decoding at this offset. Must be > [trimStartSeconds].
  final double trimEndSeconds;

  // ── Speed ──────────────────────────────────────────────────────────────────

  /// Playback speed multiplier. 1.0 = normal speed.
  ///
  /// - 0 < speed < 1: slow motion (e.g. 0.25 = 4× slow motion)
  /// - speed = 1: real-time
  /// - speed > 1: fast forward (e.g. 2.0 = 2× speed)
  ///
  /// Audio behaviour under non-1.0 speeds is governed by [VGTimeRemapAudioPolicy]
  /// (Phase 7 Stage 7.5+). In Stage 7.1 this field is stored but not rendered.
  final double speed;

  // ── Derived helpers ────────────────────────────────────────────────────────

  /// The active duration of this clip after trimming, in source-asset seconds.
  ///
  /// Equivalent to `trimEndSeconds - trimStartSeconds`.
  /// This is the unscaled duration; multiply by `1 / speed` to get wall-clock
  /// timeline contribution when speed != 1.0.
  double get trimDuration => trimEndSeconds - trimStartSeconds;

  /// The wall-clock duration this clip contributes to the global timeline.
  ///
  /// Accounts for the [speed] multiplier: at 0.5× speed a 4-second trim
  /// occupies 8 seconds on the timeline.
  double get timelineDuration => trimDuration / speed;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this descriptor to a JSON-compatible map.
  ///
  /// All values are JSON primitives. The map can be sent over a Flutter
  /// MethodChannel, stored as JSON, or diffed against a running graph.
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "id": "clip-01",
  ///   "sourcePath": "/tmp/recording.mp4",
  ///   "mediaKind": "video",
  ///   "startTimeSeconds": 0.0,
  ///   "durationSeconds": 10.0,
  ///   "trimStartSeconds": 1.0,
  ///   "trimEndSeconds": 8.5,
  ///   "speed": 1.0
  /// }
  /// ```
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'sourcePath': sourcePath,
        'mediaKind': mediaKind.value,
        'startTimeSeconds': startTimeSeconds,
        'durationSeconds': durationSeconds,
        'trimStartSeconds': trimStartSeconds,
        'trimEndSeconds': trimEndSeconds,
        'speed': speed,
      };

  /// Deserialises a [VGClipDescriptor] from a map produced by [toMap].
  ///
  /// Returns `null` if any required field is missing or has the wrong type.
  static VGClipDescriptor? fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final sourcePath = map['sourcePath'];
    final mediaKindStr = map['mediaKind'] as String? ?? 'video';
    final startTime = (map['startTimeSeconds'] as num?)?.toDouble();
    final duration = (map['durationSeconds'] as num?)?.toDouble();
    final trimStart = (map['trimStartSeconds'] as num?)?.toDouble();
    final trimEnd = (map['trimEndSeconds'] as num?)?.toDouble();
    final speed = (map['speed'] as num?)?.toDouble();

    if (id == null ||
        sourcePath == null ||
        startTime == null ||
        duration == null ||
        trimStart == null ||
        trimEnd == null ||
        speed == null) {
      return null;
    }
    if (trimEnd <= trimStart || speed <= 0 || startTime < 0 || duration < 0) {
      return null;
    }
    return VGClipDescriptor(
      id: id as String,
      sourcePath: sourcePath as String,
      mediaKind: VGMediaKind.fromValue(mediaKindStr),
      startTimeSeconds: startTime,
      durationSeconds: duration,
      trimStartSeconds: trimStart,
      trimEndSeconds: trimEnd,
      speed: speed,
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this descriptor with the specified fields replaced.
  ///
  /// Validation asserts are enforced on the new instance.
  VGClipDescriptor copyWith({
    String? id,
    String? sourcePath,
    VGMediaKind? mediaKind,
    double? startTimeSeconds,
    double? durationSeconds,
    double? trimStartSeconds,
    double? trimEndSeconds,
    double? speed,
  }) {
    return VGClipDescriptor(
      id: id ?? this.id,
      sourcePath: sourcePath ?? this.sourcePath,
      mediaKind: mediaKind ?? this.mediaKind,
      startTimeSeconds: startTimeSeconds ?? this.startTimeSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      trimStartSeconds: trimStartSeconds ?? this.trimStartSeconds,
      trimEndSeconds: trimEndSeconds ?? this.trimEndSeconds,
      speed: speed ?? this.speed,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGClipDescriptor &&
          other.id == id &&
          other.sourcePath == sourcePath &&
          other.mediaKind == mediaKind &&
          other.startTimeSeconds == startTimeSeconds &&
          other.durationSeconds == durationSeconds &&
          other.trimStartSeconds == trimStartSeconds &&
          other.trimEndSeconds == trimEndSeconds &&
          other.speed == speed;

  @override
  int get hashCode => Object.hash(
        id,
        sourcePath,
        mediaKind,
        startTimeSeconds,
        durationSeconds,
        trimStartSeconds,
        trimEndSeconds,
        speed,
      );

  @override
  String toString() => 'VGClipDescriptor('
      'id: $id, '
      'sourcePath: ${sourcePath.split('/').last}, '
      'kind: ${mediaKind.value}, '
      'start: ${startTimeSeconds}s, '
      'duration: ${durationSeconds}s, '
      'trim: [${trimStartSeconds}s → ${trimEndSeconds}s], '
      'speed: $speed×)';
}

// ── VGMediaKind ────────────────────────────────────────────────────────────────

/// The primary media stream type of a clip's source asset.
///
/// Used by [VGClipDescriptor.mediaKind] to communicate the expected content
/// type to the native graph factory.
enum VGMediaKind {
  /// A video asset (may contain an audio track).
  video('video'),

  /// An audio-only asset (no video track).
  audio('audio'),

  /// A still image asset (JPEG, PNG, HEIC, WebP).
  ///
  /// Corresponds to [VGStillImageClipDescriptor] in the Phase 7 roadmap.
  image('image'),

  /// Unknown or not yet probed.
  unknown('unknown');

  const VGMediaKind(this.value);

  /// The wire-format string value as sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding [VGMediaKind].
  ///
  /// Returns [VGMediaKind.unknown] for unrecognised strings.
  static VGMediaKind fromValue(String value) {
    for (final kind in VGMediaKind.values) {
      if (kind.value == value) return kind;
    }
    return VGMediaKind.unknown;
  }
}
