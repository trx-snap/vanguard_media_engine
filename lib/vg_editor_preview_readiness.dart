// vg_editor_preview_readiness.dart
// Vanguard Media Engine — Phase 7.8D-Android
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 7.8D-ANDROID — EDITOR PREVIEW READINESS EVALUATOR
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure-Dart public readiness evaluator for preflighting VGEditorDraft instances
// before passing them to the Android native VGEditorController playback route.
//
// Android VGEditorController public playback route currently supports a single
// plain local video clip and rejects multi-clip natively (UNSUPPORTED_TIMELINE).
// It does not yet execute editor compositor features such as transitions,
// overlays, spatial clip transforms, still-image crop/fit, freeze frames,
// reverse playback, dual-camera composition, time remap, transform tracks,
// color matrix filtering, or audio sidecar mixing.
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

  /// The draft contains more than one clip (native Android currently rejects with UNSUPPORTED_TIMELINE).
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

  /// A clip specifies a freeze frame PTS (freeze frame extraction not executed on Android playback route).
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

  /// The draft specifies an audio sidecar plan (audio sidecar mixing not supported on Android playback route).
  audioSidecarPresent,
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
/// **Android Editor Playback Support Contract (Phase 7.8D):**
/// - Exactly one [VGClipDescriptor] with [VGMediaKind.video].
/// - No transitions ([VGEditorDraft.transitions] must be empty).
/// - No overlays ([VGEditorDraft.overlays] must be empty).
/// - No audio sidecar plan ([VGEditorDraft.audioSidecarPlan] must be null).
/// - No spatial clip transform ([VGClipDescriptor.transform] must be null).
/// - No still-image fit mode or crop ([VGClipDescriptor.fitMode] == [VGStillImageFitMode.fit], [VGClipDescriptor.cropRect] == null).
/// - No freeze frame ([VGClipDescriptor.freezePTS] must be null).
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

    // 1. Timeline clip count validation.
    if (draft.clips.isEmpty) {
      issues.add(
        const VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.emptyTimeline,
          message:
              'Draft has no clips; editor preview requires a valid video clip.',
        ),
      );
    } else if (draft.clips.length > 1) {
      issues.add(
        VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.multiClipTimeline,
          message:
              'Draft contains ${draft.clips.length} clips; Android editor playback route currently supports single-clip playback only (multi-clip is UNSUPPORTED_TIMELINE).',
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

    // 4. Audio sidecar plan validation.
    if (draft.audioSidecarPlan != null) {
      issues.add(
        const VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.audioSidecarPresent,
          message:
              'Draft has an audio sidecar plan; audio sidecar mixing is not supported on the Android editor playback route.',
        ),
      );
    }

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

      // Freeze frame.
      if (clip.freezePTS != null) {
        issues.add(
          VGEditorPreviewReadinessIssue(
            code: VGEditorPreviewReadinessIssueCode.freezeFramePresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has freezePTS set; freeze frame playback is not supported on the Android editor playback route.',
          ),
        );
      }

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
