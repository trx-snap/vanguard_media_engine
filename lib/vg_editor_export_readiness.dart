// vg_editor_export_readiness.dart
// Vanguard Media Engine — Phase 5-Unit J
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 5-UNIT J — EDITOR EXPORT READINESS EVALUATOR
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure-Dart public readiness evaluator for preflighting VGEditorDraft and
// VGEditorExportRequest instances before passing them to the Android native
// exportTimeline route.
//
// Android VGEditorController public export route supports sequential plain
// local video and still-image clips (one or more, hard-cut concatenation
// only) with direct-copy or PCM mixdown audio sidecar export (Unit H). Still
// image clips are local files only, fitMode must be 'fit' (default), and
// cropRect must be null. It does not yet execute editor compositor features
// such as transitions, overlays, spatial clip transforms, still-image
// crop/fill, freeze frames, reverse playback, dual-camera composition, time
// remap, transform tracks, color matrix filtering, or GPU temporal denoise.
//
// This pure Dart evaluator preflights a VGEditorDraft and VGEditorExportRequest
// and returns a structured report (ready vs blocked) with strongly-typed issue
// codes, descriptive messages, and deterministic diagnostics.
//
// Invariants:
//   - Pure Dart: zero file I/O, zero MethodChannel calls, zero platform checks.
//   - Advisory-only: does not mutate drafts/requests, allocate native resources,
//     or dictate ConnectsApp host policy.
//   - Strict blocking: any unsupported effect/descriptor field is classified
//     as blocked to prevent accidental product misuse or false parity assumptions.

import 'package:flutter/foundation.dart';

import 'vg_canvas_descriptor.dart';
import 'vg_clip_descriptor.dart';
import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';

/// Top-level readiness decision for the Android editor export route.
enum VGEditorExportReadinessDecision {
  /// The draft and request are structurally ready for the Android editor export route.
  ready,

  /// The draft or request contains features unsupported by the Android editor export route.
  blocked,
}

/// Strongly-typed issue codes identifying unsupported features or invalid arguments
/// in a [VGEditorDraft] or [VGEditorExportRequest].
enum VGEditorExportReadinessIssueCode {
  /// The draft contains zero clips.
  emptyTimeline,

  /// The draft contains transitions (transitions compositor not supported on Android export route).
  transitionsPresent,

  /// The draft contains overlays (overlays compositor not supported on Android export route).
  overlaysPresent,

  /// Canvas content mode is not 'fit' (only 'fit' is supported on Android export route).
  unsupportedCanvasContentMode,

  /// Draft canvas dimensions are invalid (must be positive even integers).
  invalidCanvasDimensions,

  /// Requested output dimensions are invalid (must be positive even integers).
  invalidRequestDimensions,

  /// Draft or requested frame rate is invalid (must be positive).
  invalidFps,

  /// Requested bitrate is invalid (must be positive).
  invalidBitrate,

  /// A clip uses a non-video media kind (e.g. image, audio).
  unsupportedMediaKind,

  /// A clip has an empty source path.
  emptySourcePath,

  /// A clip source path is not an absolute local path starting with '/'.
  nonLocalSourcePath,

  /// A clip has invalid trim range (trimEndSeconds <= trimStartSeconds).
  invalidTrimRange,

  /// A clip specifies speed != 1.0 (variable speed not supported on Android export route).
  unsupportedSpeed,

  /// A clip specifies reverse playback (temporal reversal not supported on Android export route).
  reversedClipPresent,

  /// A clip specifies a spatial transform (transforms not supported on Android export route).
  clipTransformPresent,

  /// A clip specifies still-image fit mode or crop rect (crop/fit not supported on Android export route).
  stillImageFitOrCropPresent,

  /// A clip specifies a freeze frame PTS (freeze frame extraction not supported on Android export route).
  freezeFramePresent,

  /// A clip specifies dual-camera composition (dual-camera compositor not supported on Android export route).
  dualCameraPresent,

  /// A clip specifies variable-speed time remap (time remap not supported on Android export route).
  timeRemapPresent,

  /// A clip specifies an animated transform track (transform tracks not supported on Android export route).
  transformTrackPresent,

  /// A clip specifies a color matrix filter (color matrix not supported on Android export route).
  colorMatrixPresent,

  /// The export request enables temporal denoise (temporal denoise not supported on Android export route).
  unsupportedTemporalDenoise,
}

/// A specific readiness issue found in a [VGEditorDraft] or [VGEditorExportRequest].
final class VGEditorExportReadinessIssue {
  /// The category code for this issue.
  final VGEditorExportReadinessIssueCode code;

  /// Human-readable explanation of why this feature or argument is blocked on Android.
  final String message;

  /// The identifier of the affected clip, or null for draft/request-level issues.
  final String? clipId;

  /// Creates an immutable export readiness issue.
  const VGEditorExportReadinessIssue({
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
      other is VGEditorExportReadinessIssue &&
          other.code == code &&
          other.message == message &&
          other.clipId == clipId;

  @override
  int get hashCode => Object.hash(code, message, clipId);

  @override
  String toString() =>
      'VGEditorExportReadinessIssue(code: ${code.name}, message: "$message"${clipId != null ? ', clipId: "$clipId"' : ''})';
}

/// The outcome of preflighting a [VGEditorDraft] and [VGEditorExportRequest] for Android editor export.
final class VGEditorExportReadinessReport {
  /// The overall decision: [VGEditorExportReadinessDecision.ready] or [VGEditorExportReadinessDecision.blocked].
  final VGEditorExportReadinessDecision decision;

  /// All issues preventing the draft or request from using the Android editor export route.
  /// Empty when [decision] is [VGEditorExportReadinessDecision.ready].
  final List<VGEditorExportReadinessIssue> issues;

  /// Deterministic diagnostic metrics about the evaluated draft and request.
  final Map<String, Object?> diagnostics;

  /// Creates an immutable readiness report.
  VGEditorExportReadinessReport({
    required this.decision,
    required List<VGEditorExportReadinessIssue> issues,
    required Map<String, Object?> diagnostics,
  }) : issues = List.unmodifiable(issues),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether the evaluated draft and request can be passed to the Android native editor export route.
  bool get canUseAndroidEditorExportRoute =>
      decision == VGEditorExportReadinessDecision.ready;

  /// Convenience getter for `decision == VGEditorExportReadinessDecision.ready`.
  bool get isReady => decision == VGEditorExportReadinessDecision.ready;

  /// Convenience getter for `decision == VGEditorExportReadinessDecision.blocked`.
  bool get isBlocked => decision == VGEditorExportReadinessDecision.blocked;

  /// Serialises this report to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'decision': decision.name,
    'canUseAndroidEditorExportRoute': canUseAndroidEditorExportRoute,
    'issues': issues.map((i) => i.toMap()).toList(),
    'diagnostics': diagnostics,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorExportReadinessReport &&
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
      'VGEditorExportReadinessReport(decision: ${decision.name}, canUseAndroidEditorExportRoute: $canUseAndroidEditorExportRoute, issues: ${issues.length}, diagnostics: $diagnostics)';
}

/// Pure-Dart evaluator that checks whether a [VGEditorDraft] and optional
/// [VGEditorExportRequest] are ready for the Android native editor export route.
///
/// **Android Editor Export Support Contract (Phase 5-Unit J / Unit H / Unit R):**
/// - One or more [VGClipDescriptor] entries with [VGMediaKind.video] or
///   [VGMediaKind.image] (sequential hard-cut concatenation; no transitions
///   between clips).
/// - No transitions ([VGEditorDraft.transitions] must be empty).
/// - No overlays ([VGEditorDraft.overlays] must be empty).
/// - Canvas content mode must be [VGCanvasContentMode.fit] (default).
/// - Canvas dimensions must be positive even integers.
/// - Source paths must be non-empty absolute local paths (starting with `/`).
/// - Trim ranges must have `trimEndSeconds > trimStartSeconds`.
/// - Speed must be 1.0 (`clip.speed == 1.0`).
/// - No reverse playback (`clip.isReversed == false`).
/// - No spatial clip transform (`clip.transform == null`).
/// - No still-image fit mode or crop (`clip.fitMode == VGStillImageFitMode.fit`, `clip.cropRect == null`).
/// - No freeze frame (`clip.freezePTS == null`).
/// - No dual camera (`clip.dualCamera == null`).
/// - No time remap (`clip.timeRemap == null`).
/// - No transform track (`clip.transformTrack == null`).
/// - No color matrix filter (`clip.colorMatrix == null`).
/// - Audio sidecar plans are allowed (Unit H proves direct-copy and PCM mixdown export).
/// - Export request dimensions must resolve to positive even integers.
/// - Frame rates (draft fps, request fps) must be positive.
/// - Export request bitrate must be positive if specified.
/// - Temporal denoise must not be enabled (`request.temporalDenoiseEnabled != true`).
///
/// Usage:
/// ```dart
/// const evaluator = VGEditorExportReadinessEvaluator();
/// final report = evaluator.evaluate(draft: draft, request: request);
/// if (report.canUseAndroidEditorExportRoute) {
///   await controller.export(request);
/// } else {
///   print('Editor export blocked: ${report.issues}');
/// }
/// ```
final class VGEditorExportReadinessEvaluator {
  /// Creates a const evaluator instance.
  const VGEditorExportReadinessEvaluator();

  /// Evaluates a [VGEditorDraft] and optional [VGEditorExportRequest] and returns
  /// a comprehensive export readiness report.
  VGEditorExportReadinessReport evaluate({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
  }) {
    final issues = <VGEditorExportReadinessIssue>[];

    // ── 1. Draft-level checks (in native guardrail order) ─────────────────────

    // Timeline clip count.
    if (draft.clips.isEmpty) {
      issues.add(
        const VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.emptyTimeline,
          message:
              'Draft has no clips; timeline export requires at least one video clip.',
        ),
      );
    }

    // Transitions.
    if (draft.transitions.isNotEmpty) {
      issues.add(
        VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.transitionsPresent,
          message:
              'Draft contains ${draft.transitions.length} transition(s); transitions are not supported on the Android export route.',
        ),
      );
    }

    // Overlays.
    if (draft.overlays.isNotEmpty) {
      issues.add(
        VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.overlaysPresent,
          message:
              'Draft contains ${draft.overlays.length} overlay(s); overlays are not supported on the Android export route.',
        ),
      );
    }

    // Canvas content mode: only 'fit' is supported.
    if (draft.canvas != null &&
        draft.canvas!.contentMode != VGCanvasContentMode.fit) {
      issues.add(
        VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.unsupportedCanvasContentMode,
          message:
              "Canvas contentMode '${draft.canvas!.contentMode.value}' is not supported; only 'fit' is supported on the Android export route.",
        ),
      );
    }

    // Draft canvas dimensions: must be positive even integers.
    if (draft.canvasWidth <= 0 ||
        draft.canvasHeight <= 0 ||
        draft.canvasWidth % 2 != 0 ||
        draft.canvasHeight % 2 != 0) {
      issues.add(
        VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.invalidCanvasDimensions,
          message:
              'Draft canvas dimensions ${draft.canvasWidth}x${draft.canvasHeight} must be positive even integers.',
        ),
      );
    }

    // Draft frame rate: must be positive.
    if (draft.fps <= 0) {
      issues.add(
        VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.invalidFps,
          message: 'Draft fps ${draft.fps} must be a positive integer.',
        ),
      );
    }

    // ── 2. Per-clip checks (in clip order) ────────────────────────────────────
    for (final clip in draft.clips) {
      // Source path: must be non-empty and start with '/'.
      if (clip.sourcePath.isEmpty) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.emptySourcePath,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has an empty sourcePath; a local file path is required.',
          ),
        );
      } else if (!clip.sourcePath.startsWith('/')) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.nonLocalSourcePath,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" sourcePath "${clip.sourcePath}" is not an absolute local path; only local paths starting with "/" are supported on the Android export route.',
          ),
        );
      }

      // Media kind: video and local still-image clips are supported.
      if (clip.mediaKind != VGMediaKind.video &&
          clip.mediaKind != VGMediaKind.image) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.unsupportedMediaKind,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has media kind "${clip.mediaKind.value}"; only video and image clips are supported on the Android export route.',
          ),
        );
      }

      // Trim range: trimEndSeconds must be strictly greater than trimStartSeconds.
      if (clip.trimEndSeconds <= clip.trimStartSeconds) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.invalidTrimRange,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has trimEndSeconds (${clip.trimEndSeconds}) <= trimStartSeconds (${clip.trimStartSeconds}); trimEndSeconds must be greater than trimStartSeconds.',
          ),
        );
      }

      // Speed: only 1.0 is supported.
      if (clip.speed != 1.0) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.unsupportedSpeed,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has speed ${clip.speed}; speed != 1.0 is not supported on the Android export route.',
          ),
        );
      }

      // Reverse playback: not supported.
      if (clip.isReversed) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.reversedClipPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has reverse playback enabled; reversed clips are not supported on the Android export route.',
          ),
        );
      }

      // Spatial clip transform: not supported.
      if (clip.transform != null) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.clipTransformPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a spatial transform descriptor; clip transforms are not supported on the Android export route.',
          ),
        );
      }

      // Still-image fit mode or crop rect: not supported.
      if (clip.fitMode != VGStillImageFitMode.fit || clip.cropRect != null) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.stillImageFitOrCropPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" specifies still-image fit mode or crop rect; still-image fit/crop is not supported on the Android export route.',
          ),
        );
      }

      // Freeze frame: not supported.
      if (clip.freezePTS != null) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.freezeFramePresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has freezePTS set; freeze frame export is not supported on the Android export route.',
          ),
        );
      }

      // Dual camera: not supported.
      if (clip.dualCamera != null) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.dualCameraPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a dual-camera descriptor; dual-camera composition is not supported on the Android export route.',
          ),
        );
      }

      // Time remap: not supported.
      if (clip.timeRemap != null) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.timeRemapPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a time remap descriptor; variable-speed time remap is not supported on the Android export route.',
          ),
        );
      }

      // Transform track: not supported.
      if (clip.transformTrack != null) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.transformTrackPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a transform track descriptor; keyframed transform animation is not supported on the Android export route.',
          ),
        );
      }

      // Color matrix: not supported.
      if (clip.colorMatrix != null) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.colorMatrixPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a color matrix descriptor; color matrix filtering is not supported on the Android export route.',
          ),
        );
      }
    }

    // ── 3. Request-level validation ───────────────────────────────────────────

    // Requested dimensions: if specified, must resolve to positive even integers.
    if (request.width != null || request.height != null) {
      final reqWidth = request.width ?? draft.canvasWidth;
      final reqHeight = request.height ?? draft.canvasHeight;
      if (reqWidth <= 0 ||
          reqWidth % 2 != 0 ||
          reqHeight <= 0 ||
          reqHeight % 2 != 0) {
        issues.add(
          VGEditorExportReadinessIssue(
            code: VGEditorExportReadinessIssueCode.invalidRequestDimensions,
            message:
                'Requested export dimensions ${reqWidth}x$reqHeight must be positive even integers.',
          ),
        );
      }
    }

    // Requested frame rate: if specified, must be positive.
    if (request.fps != null && request.fps! <= 0) {
      issues.add(
        VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.invalidFps,
          message:
              'Requested export fps ${request.fps} must be a positive integer.',
        ),
      );
    }

    // Requested bitrate: if specified, must be positive.
    if (request.bitrateBps != null && request.bitrateBps! <= 0) {
      issues.add(
        VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.invalidBitrate,
          message:
              'Requested export bitrate ${request.bitrateBps} must be a positive integer.',
        ),
      );
    }

    // Temporal denoise: not supported on Android export route.
    if (request.temporalDenoiseEnabled == true) {
      issues.add(
        const VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.unsupportedTemporalDenoise,
          message:
              'Request specifies temporalDenoiseEnabled=true; temporal denoise is not supported on the Android export route.',
        ),
      );
    }

    final resolvedWidth = request.width ?? draft.canvasWidth;
    final resolvedHeight = request.height ?? draft.canvasHeight;
    final resolvedFps = request.fps ?? draft.fps;

    final decision = issues.isEmpty
        ? VGEditorExportReadinessDecision.ready
        : VGEditorExportReadinessDecision.blocked;

    final diagnostics = <String, Object?>{
      'clipCount': draft.clips.length,
      'transitionCount': draft.transitions.length,
      'overlayCount': draft.overlays.length,
      'issueCount': issues.length,
      'resolvedWidth': resolvedWidth,
      'resolvedHeight': resolvedHeight,
      'resolvedFps': resolvedFps,
      'requestedBitrateBps': request.bitrateBps,
      'hasAudioSidecarPlan': draft.audioSidecarPlan != null,
      'hasTemporalDenoiseRequest': request.temporalDenoiseEnabled == true,
    };

    return VGEditorExportReadinessReport(
      decision: decision,
      issues: issues,
      diagnostics: diagnostics,
    );
  }

  /// Convenience static evaluation entry point.
  static VGEditorExportReadinessReport evaluateDraft({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
  }) => const VGEditorExportReadinessEvaluator().evaluate(
    draft: draft,
    request: request,
  );
}
