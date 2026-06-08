// vg_audio_sidecar_plan.dart
// Vanguard Media Engine — Phase 8.14B Multi-Track Audio Mixdown
//
// Dart descriptor types for sidecar audio tracks that are post-pass muxed
// into the exported MP4 by VGAudioExportMuxer (native).
//
// Design rules:
//   - Pure Dart value types. No rendering logic, no channel calls.
//   - Minimal validation: nil/empty guards only.
//   - Serialisation under key "audioSidecar" in VGEditorDraft.toMap().
//   - Native VGAudioSidecarPlan.fromDictionary: round-trips this exactly.
//   - Do NOT add ducking, keyframes, waveform, volume envelope, or beat sync.
//   - Do NOT add Phase 15 work.
//
// Phase 8.14B additions (additive):
//   - VGAudioSidecarTrack gains optional role, fadeInSeconds, fadeOutSeconds.
//   - Role is metadata-only in 8.14B. Native muxer does not branch on role.
//   - Fades use AVMutableAudioMixInputParameters.setVolumeRampFrom:to:timeRange:
//     in a separate audio-only Pass 1 export (AVAssetExportPresetAppleM4A).
//   - Pass 2 muxes video-only MP4 + mixed M4A using AVAssetExportPresetPassthrough.
//   - VGAudioSidecarPlan now supports multiple tracks (8.14A was single-track only).
//
// Wire contract (matches native VGAudioSidecarPlan / track dictionary keys):
//   audioSidecar: {
//     "tracks": [
//       {
//         "trackId":              String,
//         "url":                  String,   // absolute device path
//         "startTime":            double,   // seconds into timeline where audio begins
//         "duration":             double,   // seconds of audio to include
//         "volume":               double,   // 0.0–1.0 linear gain
//         "role":                 String?,  // optional: "music"|"voiceover"|"sfx"|"original"
//         "fadeInSeconds":        double?,  // optional fade-in duration (≥ 0)
//         "fadeOutSeconds":       double?,  // optional fade-out duration (≥ 0)
//         "timeRemapAudioPolicy": String?   // optional; "preserve" | "mute"
//       }
//     ]
//   }

/// A single sidecar audio track to be muxed alongside the exported video.
///
/// [trackId] must be non-empty.
/// [url] must be non-empty — an absolute file path on the device.
/// [startTime] is the timeline offset in seconds where the audio begins
///   (≥ 0.0). Native clamps audio so it does not exceed the video duration.
/// [duration] is how many seconds of audio to include (> 0.0).
/// [volume] is the linear gain, clamped to [0.0, 1.0] by the native muxer.
///   Defaults to 1.0 (unity gain).
/// [role] is an optional semantic role string. Recognised values:
///   `"music"`, `"voiceover"`, `"sfx"`, `"original"`. Defaults to null.
///   Role is metadata-only in Phase 8.14B; the muxer does not change behaviour
///   based on role. Future ducking will key on this field.
/// [fadeInSeconds] is the fade-in duration in seconds (≥ 0.0). Defaults to 0.0.
///   A ramp from silence → [volume] is applied at the track's insertion point.
/// [fadeOutSeconds] is the fade-out duration in seconds (≥ 0.0). Defaults to 0.0.
///   A ramp from [volume] → silence is applied at the end of the track's
///   effective duration in the composition.
/// [timeRemapAudioPolicy] is an optional string hint for time-remap handling.
///   Only "preserve" and "mute" are acted on. Absent or unrecognised values
///   are treated as "preserve".
final class VGAudioSidecarTrack {
  const VGAudioSidecarTrack({
    required this.trackId,
    required this.url,
    required this.startTime,
    required this.duration,
    this.volume = 1.0,
    this.role,
    this.fadeInSeconds = 0.0,
    this.fadeOutSeconds = 0.0,
    this.timeRemapAudioPolicy,
  });

  final String trackId;
  final String url;
  final double startTime;
  final double duration;
  final double volume;

  /// Optional semantic role. Values: "music", "voiceover", "sfx", "original".
  /// Metadata-only in Phase 8.14B; no behaviour change in native muxer.
  final String? role;

  /// Fade-in duration in seconds. 0.0 = no fade-in. Native applies a linear
  /// volume ramp from 0.0 → [volume] starting at the track's insertion point.
  final double fadeInSeconds;

  /// Fade-out duration in seconds. 0.0 = no fade-out. Native applies a linear
  /// volume ramp from [volume] → 0.0 ending at the track's effective end time.
  final double fadeOutSeconds;

  final String? timeRemapAudioPolicy;

  /// Serialises to a map whose keys match the native
  /// `VGAudioSidecarPlan.tracks` dictionary contract.
  Map<String, Object?> toMap() {
    final m = <String, Object?>{
      'trackId': trackId,
      'url': url,
      'startTime': startTime,
      'duration': duration,
      'volume': volume,
    };
    if (role != null) m['role'] = role;
    if (fadeInSeconds != 0.0) m['fadeInSeconds'] = fadeInSeconds;
    if (fadeOutSeconds != 0.0) m['fadeOutSeconds'] = fadeOutSeconds;
    if (timeRemapAudioPolicy != null) {
      m['timeRemapAudioPolicy'] = timeRemapAudioPolicy;
    }
    return m;
  }

  /// Deserialises from a map produced by [toMap].
  ///
  /// Returns null if required fields are missing or invalid.
  static VGAudioSidecarTrack? fromMap(Map<Object?, Object?> map) {
    final trackId = map['trackId'];
    if (trackId is! String || trackId.isEmpty) return null;

    final url = map['url'];
    if (url is! String || url.isEmpty) return null;

    final startTime = (map['startTime'] as num?)?.toDouble();
    if (startTime == null) return null;

    final duration = (map['duration'] as num?)?.toDouble();
    if (duration == null || duration <= 0.0) return null;

    final volume = (map['volume'] as num?)?.toDouble() ?? 1.0;

    final role = map['role'];
    final roleStr = role is String ? role : null;

    final fadeIn = (map['fadeInSeconds'] as num?)?.toDouble() ?? 0.0;
    final fadeOut = (map['fadeOutSeconds'] as num?)?.toDouble() ?? 0.0;

    final policy = map['timeRemapAudioPolicy'];
    final policyStr = policy is String ? policy : null;

    return VGAudioSidecarTrack(
      trackId: trackId,
      url: url,
      startTime: startTime,
      duration: duration,
      volume: volume,
      role: roleStr,
      fadeInSeconds: fadeIn,
      fadeOutSeconds: fadeOut,
      timeRemapAudioPolicy: policyStr,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGAudioSidecarTrack &&
          other.trackId == trackId &&
          other.url == url &&
          other.startTime == startTime &&
          other.duration == duration &&
          other.volume == volume &&
          other.role == role &&
          other.fadeInSeconds == fadeInSeconds &&
          other.fadeOutSeconds == fadeOutSeconds &&
          other.timeRemapAudioPolicy == timeRemapAudioPolicy;

  @override
  int get hashCode => Object.hash(
        trackId,
        url,
        startTime,
        duration,
        volume,
        role,
        fadeInSeconds,
        fadeOutSeconds,
        timeRemapAudioPolicy,
      );

  @override
  String toString() => 'VGAudioSidecarTrack('
      'trackId: $trackId, '
      'url: $url, '
      'startTime: ${startTime.toStringAsFixed(3)}s, '
      'duration: ${duration.toStringAsFixed(3)}s, '
      'volume: $volume'
      '${role != null ? ", role: $role" : ""}'
      '${fadeInSeconds != 0.0 ? ", fadeIn: ${fadeInSeconds}s" : ""}'
      '${fadeOutSeconds != 0.0 ? ", fadeOut: ${fadeOutSeconds}s" : ""}'
      '${timeRemapAudioPolicy != null ? ", policy: $timeRemapAudioPolicy" : ""}'
      ')';
}

/// Descriptor for a set of sidecar audio tracks to be post-pass muxed into
/// the exported MP4.
///
/// Phase 8.14B: supports multiple tracks. The native VGAudioExportMuxer
/// performs a 2-pass export:
///   Pass 1: audio-only mixdown (AVAssetExportPresetAppleM4A + AVMutableAudioMix)
///   Pass 2: video + mixed audio final mux (AVAssetExportPresetPassthrough)
///
/// [tracks] must be non-empty.
final class VGAudioSidecarPlan {
  VGAudioSidecarPlan({required List<VGAudioSidecarTrack> tracks})
      : tracks = List.unmodifiable(tracks),
        assert(tracks.isNotEmpty, 'VGAudioSidecarPlan: tracks must not be empty');

  final List<VGAudioSidecarTrack> tracks;

  /// Serialises to the map shape expected by the native
  /// `VGAudioSidecarPlan.fromDictionary:` deserialiser.
  ///
  /// Output:
  /// ```json
  /// { "tracks": [ { "trackId": ..., "url": ..., ... } ] }
  /// ```
  Map<String, Object?> toMap() => {
        'tracks': tracks.map((t) => t.toMap()).toList(),
      };

  /// Deserialises from a map produced by [toMap].
  ///
  /// Returns null if the tracks list is missing, empty, or contains no valid
  /// track entries.
  static VGAudioSidecarPlan? fromMap(Map<Object?, Object?> map) {
    final rawTracks = map['tracks'];
    if (rawTracks is! List || rawTracks.isEmpty) return null;

    final tracks = <VGAudioSidecarTrack>[];
    for (final entry in rawTracks) {
      if (entry is Map<Object?, Object?>) {
        final t = VGAudioSidecarTrack.fromMap(entry);
        if (t != null) tracks.add(t);
      }
    }
    if (tracks.isEmpty) return null;

    return VGAudioSidecarPlan(tracks: tracks);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGAudioSidecarPlan && _listEqual(other.tracks, tracks);

  @override
  int get hashCode => Object.hashAll(tracks);

  @override
  String toString() =>
      'VGAudioSidecarPlan(tracks: ${tracks.length})';
}

bool _listEqual<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
