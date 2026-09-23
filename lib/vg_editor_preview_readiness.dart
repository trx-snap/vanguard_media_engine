// vg_editor_preview_readiness.dart
// Vanguard Media Engine — Phase 7.8P-Android
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 7.8P-ANDROID — EDITOR PREVIEW READINESS EVALUATOR
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure-Dart public readiness evaluator for preflighting VGEditorDraft instances
// before passing them to the Android native VGEditorController playback route.
//
// Android VGEditorController public playback route supports sequential plain
// local video clips (one or more, hard-cut concatenation only) plus a
// validated subset of the audio sidecar plan: derived original clip audio
// tracks and user-added music/sfx/voiceover tracks (Phase 7.8P), and
// freeze-frame clips (Phase 7.17-Android: a video clip with freezePTS holds
// one source frame for its timeline hold and is silent). It does not yet
// execute editor compositor features such as transitions, overlays, spatial
// clip transforms, still-image crop/fit, reverse playback, dual-camera
// composition, time remap, transform tracks, or color matrix filtering.
//
// This pure Dart evaluator preflights a VGEditorDraft and returns a structured
// report (ready vs blocked) with strongly-typed issue codes, descriptive
// messages, and deterministic diagnostics.
//
// Invariants:
//   - Pure Dart: zero file I/O, zero MethodChannel calls, zero platform checks.
//   - Advisory-only: does not mutate drafts, allocate native resources, or
//     dictate ConnectsApp host policy.
//   - Strict blocking: any unsupported effect/descriptor field is classified
//     as blocked to prevent accidental product misuse or false parity assumptions.

import 'package:flutter/foundation.dart';

import 'vg_audio_sidecar_plan.dart';
import 'vg_clip_descriptor.dart';
import 'vg_editor_draft.dart';

/// Top-level readiness decision for the Android editor playback route.
enum VGEditorPreviewReadinessDecision {
  /// The draft is structurally ready for the single-clip Android editor playback route.
  ready,

  /// The draft contains features unsupported by the current Android editor playback route.
  blocked,
}

/// Strongly-typed issue codes identifying unsupported features in a [VGEditorDraft].
enum VGEditorPreviewReadinessIssueCode {
  /// The draft contains zero clips.
  emptyTimeline,

  /// Reserved for backward compatibility with earlier single-clip-only
  /// readiness reports. Android editor playback now supports sequential
  /// plain multi-video drafts (Phase 7.8G), so this code is never emitted by
  /// [VGEditorPreviewReadinessEvaluator.evaluate]; a multi-clip draft is only
  /// blocked when it also trips one of the other issue codes below.
  multiClipTimeline,

  /// A clip uses a non-video media kind (e.g. image, audio).
  unsupportedMediaKind,

  /// The draft contains transitions (transitions compositor not executed on Android playback route).
  transitionsPresent,

  /// The draft contains overlays (overlays compositor not executed on Android playback route).
  overlaysPresent,

  /// A clip specifies a spatial transform (transforms not executed on Android playback route).
  clipTransformPresent,

  /// A clip specifies still-image fit mode or crop rect (crop/fit not executed on Android playback route).
  stillImageFitOrCropPresent,

  /// Reserved for backward compatibility with earlier readiness reports.
  /// Android editor playback now supports freeze-frame clips (Phase
  /// 7.17-Android: `freezePTS` holds a single source frame for the clip's
  /// timeline hold, silently), so this code is never emitted by
  /// [VGEditorPreviewReadinessEvaluator.evaluate].
  freezeFramePresent,

  /// A clip specifies reverse playback (temporal reversal not executed on Android playback route).
  reversedClipPresent,

  /// A clip specifies dual-camera composition (dual-camera compositor not executed on Android playback route).
  dualCameraPresent,

  /// A clip specifies variable-speed time remap (time remap not executed on Android playback route).
  timeRemapPresent,

  /// A clip specifies an animated transform track (transform tracks not executed on Android playback route).
  transformTrackPresent,

  /// A clip specifies a color matrix filter (color matrix not executed on Android playback route).
  colorMatrixPresent,

  /// Reserved for backward compatibility with earlier readiness reports.
  /// Android editor playback now supports a validated subset of the audio
  /// sidecar plan (Phase 7.8P: derived original / music / sfx / voiceover
  /// tracks), so this code is never emitted by
  /// [VGEditorPreviewReadinessEvaluator.evaluate]; an audio sidecar plan is
  /// only blocked when it also trips one of the more specific sidecar issue
  /// codes below.
  audioSidecarPresent,

  /// An audio sidecar track has a role other than `music`, `sfx`,
  /// `voiceover`, or `original` (or no role at all).
  unsupportedAudioSidecarRole,

  /// A user-added audio sidecar track id (`music`/`sfx`/`voiceover`) is
  /// reused by more than one track, including across different lanes.
  duplicateAudioSidecarTrackId,

  /// A user-added audio sidecar lane (`music`, `sfx`, and `voiceover` are
  /// each their own independent lane) exceeds the 8-track safety cap.
  audioSidecarLaneCapacityExceeded,

  /// Two user-added audio sidecar tracks in the same lane overlap in time.
  audioSidecarLaneOverlap,

  /// An audio sidecar track fails structural validation (blank id/url,
  /// non-finite or out-of-range numeric field, unsupported volume keyframe
  /// curve, or a declared "original" track that does not match a derived
  /// original clip track).
  invalidAudioSidecarTrack,
}

/// A specific readiness issue found in a [VGEditorDraft].
final class VGEditorPreviewReadinessIssue {
  /// The category code for this issue.
  final VGEditorPreviewReadinessIssueCode code;

  /// Human-readable explanation of why this feature is blocked on Android.
  final String message;

  /// The identifier of the affected clip, or null for draft-level issues.
  final String? clipId;

  /// Creates an immutable readiness issue.
  const VGEditorPreviewReadinessIssue({
    required this.code,
    required this.message,
    this.clipId,
  });

  /// Serialises this issue to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'code': code.name,
    'message': message,
    if (clipId != null) 'clipId': clipId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorPreviewReadinessIssue &&
          other.code == code &&
          other.message == message &&
          other.clipId == clipId;

  @override
  int get hashCode => Object.hash(code, message, clipId);

  @override
  String toString() =>
      'VGEditorPreviewReadinessIssue(code: ${code.name}, message: "$message"${clipId != null ? ', clipId: "$clipId"' : ''})';
}

/// The outcome of preflighting a [VGEditorDraft] for Android editor playback.
final class VGEditorPreviewReadinessReport {
  /// The overall decision: [VGEditorPreviewReadinessDecision.ready] or [VGEditorPreviewReadinessDecision.blocked].
  final VGEditorPreviewReadinessDecision decision;

  /// All issues preventing the draft from using the Android editor playback route.
  /// Empty when [decision] is [VGEditorPreviewReadinessDecision.ready].
  final List<VGEditorPreviewReadinessIssue> issues;

  /// Deterministic diagnostic metrics about the evaluated draft.
  final Map<String, Object?> diagnostics;

  /// Creates an immutable readiness report.
  VGEditorPreviewReadinessReport({
    required this.decision,
    required List<VGEditorPreviewReadinessIssue> issues,
    required Map<String, Object?> diagnostics,
  }) : issues = List.unmodifiable(issues),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether the evaluated draft can be passed to the Android native editor playback route.
  bool get canUseAndroidEditorPlaybackRoute =>
      decision == VGEditorPreviewReadinessDecision.ready;

  /// Convenience getter for `decision == VGEditorPreviewReadinessDecision.ready`.
  bool get isReady => decision == VGEditorPreviewReadinessDecision.ready;

  /// Convenience getter for `decision == VGEditorPreviewReadinessDecision.blocked`.
  bool get isBlocked => decision == VGEditorPreviewReadinessDecision.blocked;

  /// Serialises this report to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'decision': decision.name,
    'canUseAndroidEditorPlaybackRoute': canUseAndroidEditorPlaybackRoute,
    'issues': issues.map((i) => i.toMap()).toList(),
    'diagnostics': diagnostics,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorPreviewReadinessReport &&
          other.decision == decision &&
          listEquals(other.issues, issues) &&
          mapEquals(other.diagnostics, diagnostics);

  @override
  int get hashCode => Object.hash(
    decision,
    Object.hashAll(issues),
    Object.hashAll(diagnostics.entries),
  );

  @override
  String toString() =>
      'VGEditorPreviewReadinessReport(decision: ${decision.name}, canUseAndroidEditorPlaybackRoute: $canUseAndroidEditorPlaybackRoute, issues: ${issues.length}, diagnostics: $diagnostics)';
}

/// Pure-Dart evaluator that checks whether a [VGEditorDraft] is ready for the
/// Android native editor playback route.
///
/// **Android Editor Playback Support Contract (Phase 7.8P):**
/// - One or more [VGClipDescriptor] entries, each with [VGMediaKind.video]
///   (sequential hard-cut concatenation; no transitions between clips).
/// - No transitions ([VGEditorDraft.transitions] must be empty).
/// - No overlays ([VGEditorDraft.overlays] must be empty).
/// - [VGEditorDraft.audioSidecarPlan] may be present if every track is a
///   validated subset track:
///   - Derived original tracks (`role == "original"`): `trackId` starts with
///     `"original-"` and `url` matches a [VGClipDescriptor.sourcePath] in the
///     draft. These pass through and are excluded from user-added duplicate
///     id and lane checks.
///   - User-added tracks: `role` must be `"music"`, `"sfx"`, or `"voiceover"`.
///     Each of `music`, `sfx`, and `voiceover` is its own independent lane, so
///     tracks in different lanes may freely overlap in time. Each lane allows
///     at most 8 tracks. Same-lane (same-role) tracks must not overlap in
///     time (half-open `[start, start + duration)` intervals; touching
///     endpoints are allowed). User-added track ids must be unique across all
///     lanes.
///   - Every track must pass structural validation: non-blank `trackId`/
///     `url`; finite `startTime`, `duration`, `volume`, `mixGain`,
///     `fadeInSeconds`, `fadeOutSeconds`, `sourceTrimStartSeconds`;
///     `duration > 0`; `startTime >= 0`; `sourceTrimStartSeconds >= 0`;
///     `fadeInSeconds >= 0`; `fadeOutSeconds >= 0`; and, when present, each
///     volume keyframe has a finite `time >= 0`, a finite `volume` within
///     `[0.0, 1.0]`, and an omitted or `"linear"` curve.
///   - This evaluator performs no file I/O and does not check codec support;
///     it validates only the structural/descriptor-level contract above.
/// - No spatial clip transform ([VGClipDescriptor.transform] must be null).
/// - No still-image fit mode or crop ([VGClipDescriptor.fitMode] == [VGStillImageFitMode.fit], [VGClipDescriptor.cropRect] == null).
/// - Freeze-frame clips are supported ([VGClipDescriptor.freezePTS] may be
///   non-null on a video clip; the native route holds the frame at that
///   source PTS for the clip's trim-window hold and plays it silently).
/// - No reverse playback ([VGClipDescriptor.isReversed] must be false).
/// - No dual camera ([VGClipDescriptor.dualCamera] must be null).
/// - No time remap ([VGClipDescriptor.timeRemap] must be null).
/// - No transform track ([VGClipDescriptor.transformTrack] must be null).
/// - No color matrix filter ([VGClipDescriptor.colorMatrix] must be null).
///
/// Usage:
/// ```dart
/// const evaluator = VGEditorPreviewReadinessEvaluator();
/// final report = evaluator.evaluate(draft);
/// if (report.canUseAndroidEditorPlaybackRoute) {
///   await controller.updateDraft(draft);
/// } else {
///   print('Editor preview blocked: ${report.issues}');
/// }
/// ```
final class VGEditorPreviewReadinessEvaluator {
  /// Creates a const evaluator instance.
  const VGEditorPreviewReadinessEvaluator();

  /// Evaluates a [VGEditorDraft] and returns a comprehensive readiness report.
  VGEditorPreviewReadinessReport evaluate(VGEditorDraft draft) {
    final issues = <VGEditorPreviewReadinessIssue>[];

    // 1. Timeline clip count validation. Sequential plain multi-video drafts
    // (Phase 7.8G) are ready as long as no clip trips an unsupported-feature
    // check below; only an empty timeline is blocked outright.
    if (draft.clips.isEmpty) {
      issues.add(
        const VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.emptyTimeline,
          message:
              'Draft has no clips; editor preview requires a valid video clip.',
        ),
      );
    }

    // 2. Transitions validation.
    if (draft.transitions.isNotEmpty) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.transitionsPresent,
          message:
              'Draft contains ${draft.transitions.length} transition(s); transitions are not executed by the Android editor playback route.',
        ),
      );
    }

    // 3. Overlays validation.
    if (draft.overlays.isNotEmpty) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.overlaysPresent,
          message:
              'Draft contains ${draft.overlays.length} overlay(s); overlays are not executed by the Android editor playback route.',
        ),
      );
    }

    // 4. Audio sidecar plan validation: a validated subset (derived original
    // + user-added music/sfx/voiceover tracks) is supported (Phase 7.8P).
    final sidecarPlan = draft.audioSidecarPlan;
    final sidecarEvaluation = sidecarPlan != null
        ? _evaluateAudioSidecarPlan(sidecarPlan, draft)
        : const _AudioSidecarEvaluation.empty();
    issues.addAll(sidecarEvaluation.issues);

    // 5. Per-clip feature inspection.
    for (final clip in draft.clips) {
      // Media kind: only video is supported.
      if (clip.mediaKind != VGMediaKind.video) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.unsupportedMediaKind,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has media kind "${clip.mediaKind.value}"; only video clips are supported on the Android editor playback route.',
          ),
        );
      }

      // Spatial transform descriptor.
      if (clip.transform != null) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.clipTransformPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a spatial transform descriptor; clip transforms are not supported on the Android editor playback route.',
          ),
        );
      }

      // Still-image fit mode or crop rect.
      if (clip.fitMode != VGStillImageFitMode.fit || clip.cropRect != null) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.stillImageFitOrCropPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" specifies still-image fit mode or crop rect; still-image fit/crop is not supported on the Android editor playback route.',
          ),
        );
      }

      // Freeze frame: supported (Phase 7.17-Android) -- no issue is emitted.

      // Reverse playback.
      if (clip.isReversed) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.reversedClipPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has reverse playback enabled; reversed clip playback is not supported on the Android editor playback route.',
          ),
        );
      }

      // Dual camera.
      if (clip.dualCamera != null) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.dualCameraPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a dual-camera descriptor; dual-camera composition is not supported on the Android editor playback route.',
          ),
        );
      }

      // Time remap.
      if (clip.timeRemap != null) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.timeRemapPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a time remap descriptor; variable-speed time remap is not supported on the Android editor playback route.',
          ),
        );
      }

      // Transform track.
      if (clip.transformTrack != null) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.transformTrackPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a transform track descriptor; keyframed transform animation is not supported on the Android editor playback route.',
          ),
        );
      }

      // Color matrix.
      if (clip.colorMatrix != null) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.colorMatrixPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a color matrix descriptor; color matrix filtering is not supported on the Android editor playback route.',
          ),
        );
      }
    }

    final decision = issues.isEmpty
        ? VGEditorPreviewReadinessDecision.ready
        : VGEditorPreviewReadinessDecision.blocked;

    final diagnostics = <String, Object?>{
      'clipCount': draft.clips.length,
      'transitionCount': draft.transitions.length,
      'overlayCount': draft.overlays.length,
      'issueCount': issues.length,
      'hasAudioSidecarPlan': draft.audioSidecarPlan != null,
      'audioSidecarTrackCount': sidecarEvaluation.trackCount,
      // Backward-compatible aggregate of the split music/sfx lane counts,
      // retained for consumers of the pre-Phase-7.8P diagnostics key.
      'audioSidecarAddedLaneCount':
          sidecarEvaluation.musicLaneCount + sidecarEvaluation.sfxLaneCount,
      'audioSidecarMusicLaneCount': sidecarEvaluation.musicLaneCount,
      'audioSidecarSfxLaneCount': sidecarEvaluation.sfxLaneCount,
      'audioSidecarVoiceoverLaneCount': sidecarEvaluation.voiceoverLaneCount,
      'audioSidecarOriginalTrackCount': sidecarEvaluation.originalTrackCount,
    };

    return VGEditorPreviewReadinessReport(
      decision: decision,
      issues: issues,
      diagnostics: diagnostics,
    );
  }

  /// Convenience static evaluation entry point.
  static VGEditorPreviewReadinessReport evaluateDraft(VGEditorDraft draft) =>
      const VGEditorPreviewReadinessEvaluator().evaluate(draft);
}

/// Result of validating a [VGAudioSidecarPlan] against the Phase 7.8P
/// Android editor playback route's supported subset.
final class _AudioSidecarEvaluation {
  const _AudioSidecarEvaluation({
    required this.issues,
    required this.trackCount,
    required this.musicLaneCount,
    required this.sfxLaneCount,
    required this.voiceoverLaneCount,
    required this.originalTrackCount,
  });

  const _AudioSidecarEvaluation.empty()
    : issues = const <VGEditorPreviewReadinessIssue>[],
      trackCount = 0,
      musicLaneCount = 0,
      sfxLaneCount = 0,
      voiceoverLaneCount = 0,
      originalTrackCount = 0;

  final List<VGEditorPreviewReadinessIssue> issues;
  final int trackCount;
  final int musicLaneCount;
  final int sfxLaneCount;
  final int voiceoverLaneCount;
  final int originalTrackCount;
}

/// A half-open `[start, end)` time interval occupied by a lane track.
final class _AudioSidecarLaneInterval {
  const _AudioSidecarLaneInterval(this.start, this.end);
  final double start;
  final double end;
}

const _kSupportedAudioSidecarRoles = <String>{
  'music',
  'sfx',
  'voiceover',
  'original',
};

const _kAudioSidecarLaneCapacity = 8;

/// Validates every track in [plan] against the Android editor playback
/// route's supported audio sidecar subset and returns the aggregated issues
/// and diagnostic counts. Pure Dart: no file I/O, no codec checks.
_AudioSidecarEvaluation _evaluateAudioSidecarPlan(
  VGAudioSidecarPlan plan,
  VGEditorDraft draft,
) {
  final issues = <VGEditorPreviewReadinessIssue>[];
  final sourcePaths = draft.clips.map((clip) => clip.sourcePath).toSet();

  var musicLaneCount = 0;
  var sfxLaneCount = 0;
  var voiceoverLaneCount = 0;
  var originalTrackCount = 0;

  final userAddedTrackIds = <String>{};
  final musicLane = <_AudioSidecarLaneInterval>[];
  final sfxLane = <_AudioSidecarLaneInterval>[];
  final voiceoverLane = <_AudioSidecarLaneInterval>[];

  for (final track in plan.tracks) {
    final fieldIssue = _validateAudioSidecarTrackFields(track);
    if (fieldIssue != null) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.invalidAudioSidecarTrack,
          message:
              'Audio sidecar track "${track.trackId}" is invalid: '
              '$fieldIssue.',
        ),
      );
      continue;
    }

    final role = track.role;
    if (role == null || !_kSupportedAudioSidecarRoles.contains(role)) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.unsupportedAudioSidecarRole,
          message:
              'Audio sidecar track "${track.trackId}" has unsupported role '
              '"${role ?? 'null'}"; only "music", "sfx", "voiceover", and '
              '"original" are supported on the Android editor playback route.',
        ),
      );
      continue;
    }

    if (role == 'original') {
      originalTrackCount++;
      final isDerivedOriginal =
          track.trackId.startsWith('original-') &&
          sourcePaths.contains(track.url);
      if (!isDerivedOriginal) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.invalidAudioSidecarTrack,
            message:
                'Audio sidecar track "${track.trackId}" declares role '
                '"original" but its trackId does not start with "original-" '
                'or its url does not match any clip sourcePath in the draft.',
          ),
        );
      }
      continue;
    }

    // User-added track: music, sfx, and voiceover are each their own
    // independent lane, so only same-role tracks are checked against one
    // another for capacity/overlap; different-role tracks may freely overlap.
    final List<_AudioSidecarLaneInterval> lane;
    final String laneName = role;
    if (role == 'music') {
      lane = musicLane;
      musicLaneCount++;
    } else if (role == 'sfx') {
      lane = sfxLane;
      sfxLaneCount++;
    } else {
      lane = voiceoverLane;
      voiceoverLaneCount++;
    }

    if (!userAddedTrackIds.add(track.trackId)) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.duplicateAudioSidecarTrackId,
          message:
              'Audio sidecar track id "${track.trackId}" is used by more '
              'than one user-added (music/sfx/voiceover) track.',
        ),
      );
    }

    if (lane.length >= _kAudioSidecarLaneCapacity) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode
              .audioSidecarLaneCapacityExceeded,
          message:
              'Audio sidecar track "${track.trackId}" exceeds the '
              '$_kAudioSidecarLaneCapacity-track safety cap for the '
              '$laneName lane.',
        ),
      );
      continue;
    }

    final candidate = _AudioSidecarLaneInterval(
      track.startTime,
      track.startTime + track.duration,
    );
    final overlaps = lane.any(
      (existing) =>
          candidate.start < existing.end && existing.start < candidate.end,
    );
    if (overlaps) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.audioSidecarLaneOverlap,
          message:
              'Audio sidecar track "${track.trackId}" overlaps another '
              'track in the $laneName lane.',
        ),
      );
    }

    lane.add(candidate);
  }

  return _AudioSidecarEvaluation(
    issues: issues,
    trackCount: plan.tracks.length,
    musicLaneCount: musicLaneCount,
    sfxLaneCount: sfxLaneCount,
    voiceoverLaneCount: voiceoverLaneCount,
    originalTrackCount: originalTrackCount,
  );
}

/// Validates the structural fields of a single [VGAudioSidecarTrack].
/// Returns null when valid, or a human-readable reason when invalid.
String? _validateAudioSidecarTrackFields(VGAudioSidecarTrack track) {
  if (track.trackId.trim().isEmpty) return 'trackId must not be blank';
  if (track.url.trim().isEmpty) return 'url must not be blank';
  if (!track.startTime.isFinite) return 'startTime must be finite';
  if (!track.duration.isFinite) return 'duration must be finite';
  if (!track.volume.isFinite) return 'volume must be finite';
  if (!track.mixGain.isFinite) return 'mixGain must be finite';
  if (!track.fadeInSeconds.isFinite) return 'fadeInSeconds must be finite';
  if (!track.fadeOutSeconds.isFinite) return 'fadeOutSeconds must be finite';
  if (!track.sourceTrimStartSeconds.isFinite) {
    return 'sourceTrimStartSeconds must be finite';
  }
  if (track.duration <= 0) return 'duration must be greater than zero';
  if (track.startTime < 0) return 'startTime must be >= 0';
  if (track.sourceTrimStartSeconds < 0) {
    return 'sourceTrimStartSeconds must be >= 0';
  }
  if (track.fadeInSeconds < 0) return 'fadeInSeconds must be >= 0';
  if (track.fadeOutSeconds < 0) return 'fadeOutSeconds must be >= 0';

  final keyframes = track.volumeKeyframes;
  if (keyframes != null) {
    for (final keyframe in keyframes) {
      if (!keyframe.time.isFinite || keyframe.time < 0) {
        return 'volume keyframe time must be finite and >= 0';
      }
      if (!keyframe.volume.isFinite ||
          keyframe.volume < 0.0 ||
          keyframe.volume > 1.0) {
        return 'volume keyframe volume must be finite and within [0.0, 1.0]';
      }
      if (keyframe.curve != 'linear') {
        return 'volume keyframe curve "${keyframe.curve}" is not supported '
            '(only linear)';
      }
    }
  }

  return null;
}
