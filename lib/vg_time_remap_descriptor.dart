// vg_time_remap_descriptor.dart
// Vanguard Media Engine — Phase 7.22A
//
// Descriptor-only foundation for time remap and variable-speed playback.
//
// Design rules (Phase 7.22A):
//   - These are pure Dart value types describing time remap metadata.
//   - They do NOT implement any variable-speed rendering, PTS mapping,
//     audio retiming, pitch shifting, or export retiming.
//   - The native compositor (VGTimelineCompositorNode) ignores these fields
//     in Phase 7.22A. Actual PTS remapping is a follow-up slice (Phase 7.22B+).
//   - Audio policy values are serialized metadata only. No audio behavior is
//     implemented in this slice.
//   - Phase 8 audio UX (waveforms, ducking, volume keyframes) is out of scope.
//   - Android implementation is out of scope.
//
// Serialisation:
//   VGSpeedSegmentDescriptor.toMap() produces:
//   {
//     'sourceStartTime': double,    // source-local segment start (>= 0)
//     'sourceDuration':  double,    // source-local segment duration (> 0)
//     'speedMultiplier': double,    // playback speed for this segment (> 0)
//   }
//
//   VGTimeRemapDescriptor.toMap() produces:
//   {
//     'segments':    List<Map>,     // ordered, non-overlapping speed segments
//     'audioPolicy': String,        // VGTimeRemapAudioPolicy wire value
//   }
//
// Wire format strings match native VGTimeRemapAudioPolicy enum values
// in VGTimeRemapDescriptor.h.
//
// References:
//   - DEC-V2-026 (Phase 7 non-destructive descriptor contract)
//   - UMF_V2_04_Phased_Roadmap.md §Phase 7 (VGTimeRemapDescriptor,
//     VGSpeedCurveDescriptor, VGTimeRemapAudioPolicy)

// ── VGTimeRemapAudioPolicy ──────────────────────────────────────────────────

/// Audio behaviour policy when a clip's effective speed is not 1.0.
///
/// **Phase 7.22A**: This is a serialization-only metadata field. No audio
/// behavior is implemented in this slice. The compositor silently ignores the
/// policy until Phase 7 audio pipeline work begins.
///
/// Wire values match the native `VGTimeRemapAudioPolicy` constants in
/// `VGTimeRemapDescriptor.h`.
enum VGTimeRemapAudioPolicy {
  /// Mute the clip's audio track when effective speed ≠ 1.0.
  ///
  /// This is the safest default. Preserves video fidelity without
  /// requiring pitch-shift or time-stretch capabilities.
  mute('mute'),

  /// Reject export if the clip's effective speed ≠ 1.0 and an audio track
  /// is present. Callers must explicitly mute or detach audio first.
  reject('reject'),

  /// Preserve the original audio when speed == 1.0 exactly; mute otherwise.
  ///
  /// Suitable for speed-ramp segments that include 1× sections.
  preserveOriginalWhenSpeedIs1('preserveOriginalWhenSpeedIs1'),

  /// Attempt offline deterministic time-stretch if the platform contract
  /// S-06 verified the capability in Phase 0. Falls back to [mute] if
  /// UNVERIFIED or unsupported on the current device.
  ///
  /// **Phase 7.22A**: Behavior not implemented; value stored as metadata only.
  offlineRetimeIfSupported('offlineRetimeIfSupported'),

  /// Explicit marker that this clip's audio requires the Phase 15 full
  /// audio graph for correct processing. The composite will be silent
  /// until Phase 15 is implemented.
  ///
  /// Use this value to document intent without silently dropping audio.
  deferToFullAudioGraph('deferToFullAudioGraph');

  const VGTimeRemapAudioPolicy(this.value);

  /// The wire-format string value sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding policy.
  ///
  /// Returns [VGTimeRemapAudioPolicy.mute] for unrecognised strings
  /// (safe conservative default).
  static VGTimeRemapAudioPolicy fromValue(String value) {
    for (final policy in VGTimeRemapAudioPolicy.values) {
      if (policy.value == value) return policy;
    }
    return VGTimeRemapAudioPolicy.mute;
  }
}

// ── VGSpeedSegmentDescriptor ────────────────────────────────────────────────

/// A single speed segment within a time remap curve.
///
/// Describes a contiguous range within a source asset's time domain and the
/// speed multiplier applied to that range. Multiple segments combine into a
/// [VGTimeRemapDescriptor] that describes variable-speed playback for an
/// entire clip.
///
/// **Phase 7.22A**: Descriptor and serialization only. No variable-speed
/// rendering is implemented. The native compositor ignores these values
/// until Phase 7.22B+.
///
/// Wire format produced by [toMap]:
/// ```json
/// {
///   "sourceStartTime": 0.0,
///   "sourceDuration":  2.0,
///   "speedMultiplier": 1.5
/// }
/// ```
final class VGSpeedSegmentDescriptor {
  /// Creates a speed segment descriptor.
  ///
  /// [sourceStartTime] is the start of this segment within the source asset's
  /// time domain, in seconds. Must be >= 0.
  ///
  /// [sourceDuration] is the length of this segment in source-asset seconds.
  /// Must be > 0.
  ///
  /// [speedMultiplier] is the playback speed applied to this segment.
  /// Must be > 0. 1.0 = normal speed, 0.5 = half speed, 2.0 = double speed.
  const VGSpeedSegmentDescriptor({
    required this.sourceStartTime,
    required this.sourceDuration,
    required this.speedMultiplier,
  })  : assert(sourceStartTime >= 0, 'sourceStartTime must be >= 0'),
        assert(sourceDuration > 0, 'sourceDuration must be > 0'),
        assert(speedMultiplier > 0, 'speedMultiplier must be > 0');

  /// Start of this segment in source-asset time (seconds). Must be >= 0.
  final double sourceStartTime;

  /// Length of this segment in source-asset time (seconds). Must be > 0.
  final double sourceDuration;

  /// Playback speed multiplier for this segment. Must be > 0.
  ///
  /// - 0 < speedMultiplier < 1: slow motion
  /// - speedMultiplier = 1: real-time
  /// - speedMultiplier > 1: fast forward
  final double speedMultiplier;

  /// End of this segment in source-asset time (seconds).
  double get sourceEndTime => sourceStartTime + sourceDuration;

  /// Serialises this descriptor to a JSON-compatible map.
  Map<String, Object> toMap() => {
        'sourceStartTime': sourceStartTime,
        'sourceDuration': sourceDuration,
        'speedMultiplier': speedMultiplier,
      };

  /// Deserialises a [VGSpeedSegmentDescriptor] from a map produced by [toMap].
  ///
  /// Returns null if any field is missing, has the wrong type, or fails
  /// validation constraints.
  static VGSpeedSegmentDescriptor? fromMap(Map<Object?, Object?> map) {
    final rawStart = map['sourceStartTime'];
    final rawDur = map['sourceDuration'];
    final rawSpeed = map['speedMultiplier'];

    if (rawStart is! num) return null;
    if (rawDur is! num) return null;
    if (rawSpeed is! num) return null;

    final start = rawStart.toDouble();
    final dur = rawDur.toDouble();
    final speed = rawSpeed.toDouble();

    if (!start.isFinite || start < 0.0) return null;
    if (!dur.isFinite || dur <= 0.0) return null;
    if (!speed.isFinite || speed <= 0.0) return null;

    return VGSpeedSegmentDescriptor(
      sourceStartTime: start,
      sourceDuration: dur,
      speedMultiplier: speed,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGSpeedSegmentDescriptor &&
          other.sourceStartTime == sourceStartTime &&
          other.sourceDuration == sourceDuration &&
          other.speedMultiplier == speedMultiplier;

  @override
  int get hashCode =>
      Object.hash(sourceStartTime, sourceDuration, speedMultiplier);

  @override
  String toString() => 'VGSpeedSegmentDescriptor('
      'start: ${sourceStartTime}s, '
      'duration: ${sourceDuration}s, '
      'speed: ${speedMultiplier}×)';
}

// ── VGTimeRemapDescriptor ───────────────────────────────────────────────────

/// Describes variable-speed playback for a single clip via an ordered list of
/// speed segments.
///
/// A time remap descriptor replaces the flat [VGClipDescriptor.speed] field
/// with a piecewise-constant speed curve. Each [VGSpeedSegmentDescriptor] in
/// [segments] covers a non-overlapping range within the source asset's time
/// domain.
///
/// **Phase 7.22A**: Descriptor and serialization only. No variable-speed
/// rendering is implemented. [VGTimelineCompositorNode] ignores this field
/// until Phase 7.22B+.
///
/// **Contiguity**: Segments are NOT required to be fully contiguous. Gaps
/// between segments are valid and indicate no-remap regions (the compositor
/// will handle gaps as identity/1× speed in a future implementation slice).
///
/// **Ordering**: Segments MUST be sorted by [VGSpeedSegmentDescriptor.sourceStartTime]
/// in ascending order and MUST NOT overlap.
///
/// Wire format produced by [toMap]:
/// ```json
/// {
///   "segments": [
///     { "sourceStartTime": 0.0, "sourceDuration": 2.0, "speedMultiplier": 1.5 }
///   ],
///   "audioPolicy": "mute"
/// }
/// ```
final class VGTimeRemapDescriptor {
  /// Creates a time remap descriptor.
  ///
  /// [segments] is the ordered list of speed segments. Must not be empty.
  /// Segments must be sorted by [VGSpeedSegmentDescriptor.sourceStartTime]
  /// in ascending order and must not overlap.
  ///
  /// [audioPolicy] is the audio handling policy when effective speed ≠ 1.0.
  /// Defaults to [VGTimeRemapAudioPolicy.mute] (the safest conservative default).
  VGTimeRemapDescriptor({
    required List<VGSpeedSegmentDescriptor> segments,
    this.audioPolicy = VGTimeRemapAudioPolicy.mute,
  })  : assert(segments.isNotEmpty, 'segments must not be empty'),
        assert(
          _validateSegments(segments),
          'segments must be sorted by sourceStartTime and must not overlap',
        ),
        segments = List.unmodifiable(segments);

  /// Ordered list of speed segments. Immutable. Must not be empty.
  ///
  /// Segments are sorted by [VGSpeedSegmentDescriptor.sourceStartTime]
  /// and must not overlap.
  final List<VGSpeedSegmentDescriptor> segments;

  /// Audio handling policy when effective speed ≠ 1.0.
  ///
  /// **Phase 7.22A**: Stored as metadata only. No audio behavior is changed.
  final VGTimeRemapAudioPolicy audioPolicy;

  /// Validates that [segments] are sorted and non-overlapping.
  ///
  /// Returns true if valid, false otherwise. Called from the assert in the
  /// constructor — this is a descriptor-layer validation, not a runtime guard.
  static bool _validateSegments(List<VGSpeedSegmentDescriptor> segments) {
    for (var i = 1; i < segments.length; i++) {
      final prev = segments[i - 1];
      final curr = segments[i];
      // Must be sorted by sourceStartTime.
      if (curr.sourceStartTime < prev.sourceStartTime) return false;
      // Must not overlap: prev.end must be <= curr.start.
      // Allow a small epsilon for floating-point rounding.
      if (prev.sourceEndTime > curr.sourceStartTime + 1e-9) return false;
    }
    return true;
  }

  /// Serialises this descriptor to a JSON-compatible map.
  Map<String, Object> toMap() => {
        'segments': segments.map((s) => s.toMap()).toList(growable: false),
        'audioPolicy': audioPolicy.value,
      };

  /// Deserialises a [VGTimeRemapDescriptor] from a map produced by [toMap].
  ///
  /// Returns null if any required field is missing, has the wrong type,
  /// fails validation, or if the segments list is empty or contains
  /// overlapping/unsorted segments.
  static VGTimeRemapDescriptor? fromMap(Map<Object?, Object?> map) {
    final rawSegments = map['segments'];
    final rawPolicy = map['audioPolicy'];

    if (rawSegments is! List) return null;
    if (rawSegments.isEmpty) return null;

    final segments = <VGSpeedSegmentDescriptor>[];
    for (final rawSeg in rawSegments) {
      if (rawSeg is! Map<Object?, Object?>) {
        // Accept both typed and dynamic map forms from MethodChannel.
        if (rawSeg is Map) {
          final seg = VGSpeedSegmentDescriptor.fromMap(
            rawSeg.cast<Object?, Object?>(),
          );
          if (seg == null) return null;
          segments.add(seg);
        } else {
          return null;
        }
        continue;
      }
      final seg = VGSpeedSegmentDescriptor.fromMap(rawSeg);
      if (seg == null) return null;
      segments.add(seg);
    }

    if (segments.isEmpty) return null;

    // Validate ordering and non-overlap after parsing.
    if (!_validateSegments(segments)) return null;

    final audioPolicy = rawPolicy is String
        ? VGTimeRemapAudioPolicy.fromValue(rawPolicy)
        : VGTimeRemapAudioPolicy.mute;

    return VGTimeRemapDescriptor(
      segments: segments,
      audioPolicy: audioPolicy,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGTimeRemapDescriptor &&
          audioPolicy == other.audioPolicy &&
          _segmentsEqual(segments, other.segments);

  static bool _segmentsEqual(
    List<VGSpeedSegmentDescriptor> a,
    List<VGSpeedSegmentDescriptor> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        audioPolicy,
        Object.hashAll(segments),
      );

  @override
  String toString() => 'VGTimeRemapDescriptor('
      'segments: ${segments.length}, '
      'audioPolicy: ${audioPolicy.value})';
}
