// vg_passthrough_remux_evaluator.dart
// Vanguard Media Engine — Phase 2-Unit W
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 2-UNIT W — ANDROID PASSTHROUGH REMUX SINK NODE PREFLIGHT EVALUATOR
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure-Dart public preflight evaluator that determines whether a given
// VGEditorDraft and optional VGEditorExportRequest are eligible for a future
// zero-reencode direct-copy Android PassthroughRemuxSinkNode export route.
//
// Zero-reencode passthrough remux is strictly faster and uses near-zero CPU/GPU
// because raw video and audio bitstream samples are transferred directly from
// source container to target container without decoding, raster processing,
// filtering, or re-encoding.
//
// Consequently, the eligibility criteria are much stricter than general editor
// export readiness (VGEditorExportReadinessEvaluator):
//   - Exactly one clip on the timeline.
//   - Media kind must be video.
//   - Source path must be a valid absolute local path starting with '/'.
//   - Clip timeline start must be 0.0.
//   - Clip must be completely untrimmed (trimStart == 0, trimEnd == duration).
//   - Speed must be 1.0; no reverse playback.
//   - No clip transforms, fit/crop, freeze frame, dual camera, time remap,
//     transform track, or color matrix.
//   - No transitions and no overlays.
//   - Canvas contentMode must be fit (or null).
//   - Canvas dimensions must be positive even integers; fps must be positive.
//   - No dimension resize in request (width/height must be null or match draft).
//   - No frame rate conversion in request (fps must be null or match draft).
//   - No bitrate override in request (bitrate override implies re-encoding).
//   - No temporal denoise in request.
//   - No audio sidecar plan (sidecars require audio mix/mux processing).
//   - Output path, when provided, must end with .mp4 or .m4v (case-insensitive).
//
// Invariants:
//   - Pure Dart: zero file I/O, zero MethodChannel calls, zero platform checks.
//   - Advisory-only: does not mutate drafts/requests, allocate native resources,
//     or perform filesystem operations.
//   - Deterministic: identical input yields identical report and diagnostics.

import 'package:flutter/foundation.dart';

import 'vg_canvas_descriptor.dart';
import 'vg_clip_descriptor.dart';
import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';

/// Top-level eligibility decision for direct zero-reencode passthrough remux.
enum VGPassthroughRemuxDecision {
  /// The draft and request meet all requirements for zero-reencode passthrough remux.
  eligible,

  /// The draft or request requires decoding/re-encoding, filtering, or unsupported features.
  ineligible,
}

/// Strongly-typed issue codes identifying reasons why a [VGEditorDraft] or
/// [VGEditorExportRequest] cannot use direct zero-reencode passthrough remux.
enum VGPassthroughRemuxIssueCode {
  /// The draft contains zero clips.
  emptyTimeline,

  /// The draft contains multiple clips (passthrough remux requires exactly one clip).
  multiClip,

  /// The draft contains transitions (transitions require compositing and re-encoding).
  transitionsPresent,

  /// The draft contains overlays (overlays require raster rendering and re-encoding).
  overlaysPresent,

  /// Canvas content mode is not 'fit' (non-fit scaling requires re-encoding).
  unsupportedCanvasContentMode,

  /// Draft canvas dimensions are invalid (must be positive even integers).
  invalidCanvasDimensions,

  /// Requested output dimensions do not match draft canvas dimensions or are invalid.
  incompatibleOutputDimensions,

  /// Draft or requested frame rate is invalid or does not match draft fps.
  invalidFps,

  /// Export request specifies a bitrate override (bitrate control requires re-encoding).
  unsupportedBitrateOverride,

  /// Export request enables temporal denoise (denoise requires GPU re-encoding).
  unsupportedTemporalDenoise,

  /// Clip media kind is not video (only video clips are eligible).
  unsupportedMediaKind,

  /// Clip source path is empty.
  emptySourcePath,

  /// Clip source path is not an absolute local path starting with '/'.
  nonLocalSourcePath,

  /// Clip trim range is invalid (trimEnd <= trimStart).
  invalidTrimRange,

  /// Clip is trimmed (passthrough remux requires an unmodified full-duration source clip).
  trimmedClip,

  /// Clip does not start at timeline 0.0.
  nonZeroTimelineStart,

  /// Clip playback speed != 1.0 (speed change requires re-encoding).
  unsupportedSpeed,

  /// Clip reverse playback is enabled (reverse requires frame-by-frame re-encoding).
  reversedClipPresent,

  /// Clip specifies a spatial transform (transforms require re-encoding).
  clipTransformPresent,

  /// Clip specifies still-image fit mode or crop rect (crop/fit requires re-encoding).
  stillImageFitOrCropPresent,

  /// Clip specifies a freeze frame PTS (freeze frame requires static extraction and re-encoding).
  freezeFramePresent,

  /// Clip specifies dual-camera composition (dual camera requires compositing and re-encoding).
  dualCameraPresent,

  /// Clip specifies variable-speed time remap (time remap requires re-encoding).
  timeRemapPresent,

  /// Clip specifies an animated transform track (transform animation requires re-encoding).
  transformTrackPresent,

  /// Clip specifies a color matrix filter (color filtering requires re-encoding).
  colorMatrixPresent,

  /// Draft specifies an audio sidecar plan (sidecar audio requires mixdown/muxing).
  audioSidecarPlanPresent,

  /// Export request output path does not have an MP4 container extension (.mp4, .m4v).
  incompatibleContainerFormat,
}

/// A specific issue identifying why direct passthrough remux cannot be used.
final class VGPassthroughRemuxIssue {
  /// The category code for this issue.
  final VGPassthroughRemuxIssueCode code;

  /// Human-readable explanation of why this feature or configuration is ineligible.
  final String message;

  /// The identifier of the affected clip, or null for draft/request-level issues.
  final String? clipId;

  /// Creates an immutable passthrough remux issue.
  const VGPassthroughRemuxIssue({
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
      other is VGPassthroughRemuxIssue &&
          other.code == code &&
          other.message == message &&
          other.clipId == clipId;

  @override
  int get hashCode => Object.hash(code, message, clipId);

  @override
  String toString() =>
      'VGPassthroughRemuxIssue(code: ${code.name}, message: "$message"${clipId != null ? ', clipId: "$clipId"' : ''})';
}

/// The outcome of preflighting a [VGEditorDraft] and [VGEditorExportRequest] for
/// direct zero-reencode Android PassthroughRemuxSinkNode export.
final class VGPassthroughRemuxReport {
  /// The overall decision: [VGPassthroughRemuxDecision.eligible] or [VGPassthroughRemuxDecision.ineligible].
  final VGPassthroughRemuxDecision decision;

  /// All issues preventing direct passthrough remux. Empty when [decision] is [VGPassthroughRemuxDecision.eligible].
  final List<VGPassthroughRemuxIssue> issues;

  /// Deterministic diagnostic metrics and non-claims about the evaluated draft and request.
  final Map<String, Object?> diagnostics;

  /// Creates an immutable passthrough remux report.
  VGPassthroughRemuxReport({
    required this.decision,
    required List<VGPassthroughRemuxIssue> issues,
    required Map<String, Object?> diagnostics,
  }) : issues = List.unmodifiable(issues),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether the evaluated draft and request are eligible for zero-reencode Android PassthroughRemuxSinkNode.
  bool get canUseAndroidPassthroughRemux =>
      decision == VGPassthroughRemuxDecision.eligible;

  /// Convenience getter for `decision == VGPassthroughRemuxDecision.eligible`.
  bool get isEligible => decision == VGPassthroughRemuxDecision.eligible;

  /// Convenience getter for `decision == VGPassthroughRemuxDecision.ineligible`.
  bool get isIneligible => decision == VGPassthroughRemuxDecision.ineligible;

  /// Explicit proof boundary identifier.
  String get proofBoundary =>
      diagnostics['proofBoundary'] as String? ??
      'passthrough_remux_preflight_advisory_no_file_io_no_native_mux';

  /// Serialises this report to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'decision': decision.name,
    'isEligible': isEligible,
    'isIneligible': isIneligible,
    'canUseAndroidPassthroughRemux': canUseAndroidPassthroughRemux,
    'proofBoundary': proofBoundary,
    'issues': issues.map((i) => i.toMap()).toList(),
    'diagnostics': diagnostics,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGPassthroughRemuxReport &&
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
      'VGPassthroughRemuxReport(decision: ${decision.name}, canUseAndroidPassthroughRemux: $canUseAndroidPassthroughRemux, issues: ${issues.length}, diagnostics: $diagnostics)';
}

/// Pure-Dart preflight evaluator that checks whether a [VGEditorDraft] and optional
/// [VGEditorExportRequest] can bypass decoding/re-encoding and use direct
/// Android PassthroughRemuxSinkNode bitstream remuxing.
final class VGPassthroughRemuxEvaluator {
  /// Proof boundary token for this pure Dart advisory evaluator.
  static const String proofBoundaryToken =
      'passthrough_remux_preflight_advisory_no_file_io_no_native_mux';

  /// Creates a const evaluator instance.
  const VGPassthroughRemuxEvaluator();

  /// Evaluates a [VGEditorDraft] and optional [VGEditorExportRequest] and returns
  /// a comprehensive passthrough remux eligibility report.
  VGPassthroughRemuxReport evaluate({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
  }) {
    final issues = <VGPassthroughRemuxIssue>[];

    // ── 1. Draft-level timeline structure checks ────────────────────────────

    // Timeline clip count: exactly one clip required.
    if (draft.clips.isEmpty) {
      issues.add(
        const VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.emptyTimeline,
          message:
              'Draft has no clips; passthrough remux requires exactly one video clip.',
        ),
      );
    } else if (draft.clips.length > 1) {
      issues.add(
        VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.multiClip,
          message:
              'Draft has ${draft.clips.length} clips; passthrough remux requires exactly one clip.',
        ),
      );
    }

    // Transitions: none allowed.
    if (draft.transitions.isNotEmpty) {
      issues.add(
        VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.transitionsPresent,
          message:
              'Draft contains ${draft.transitions.length} transition(s); passthrough remux does not support transitions.',
        ),
      );
    }

    // Overlays: none allowed.
    if (draft.overlays.isNotEmpty) {
      issues.add(
        VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.overlaysPresent,
          message:
              'Draft contains ${draft.overlays.length} overlay(s); passthrough remux does not support overlays.',
        ),
      );
    }

    // Canvas content mode: null or fit allowed.
    if (draft.canvas != null &&
        draft.canvas!.contentMode != VGCanvasContentMode.fit) {
      issues.add(
        VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.unsupportedCanvasContentMode,
          message:
              "Canvas contentMode '${draft.canvas!.contentMode.value}' is not supported; passthrough remux requires default 'fit' mode.",
        ),
      );
    }

    // Canvas dimensions: positive even integers.
    if (draft.canvasWidth <= 0 ||
        draft.canvasHeight <= 0 ||
        draft.canvasWidth % 2 != 0 ||
        draft.canvasHeight % 2 != 0) {
      issues.add(
        VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.invalidCanvasDimensions,
          message:
              'Draft canvas dimensions ${draft.canvasWidth}x${draft.canvasHeight} must be positive even integers.',
        ),
      );
    }

    // Frame rate: positive.
    if (draft.fps <= 0) {
      issues.add(
        VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.invalidFps,
          message: 'Draft fps ${draft.fps} must be a positive integer.',
        ),
      );
    }

    // Audio sidecar plan: must be null (sidecars require audio mixing/muxing).
    if (draft.audioSidecarPlan != null) {
      issues.add(
        const VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.audioSidecarPlanPresent,
          message:
              'Draft specifies an audioSidecarPlan; audio sidecar plans require mix/mux logic and are not eligible for direct single-source passthrough remux.',
        ),
      );
    }

    // ── 2. Per-clip checks ──────────────────────────────────────────────────
    for (final clip in draft.clips) {
      // Source path: non-empty and absolute local starting with '/'.
      if (clip.sourcePath.isEmpty) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.emptySourcePath,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has an empty sourcePath; a local file path is required.',
          ),
        );
      } else if (!clip.sourcePath.startsWith('/')) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.nonLocalSourcePath,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" sourcePath "${clip.sourcePath}" is not an absolute local path; only local paths starting with "/" are eligible for passthrough remux.',
          ),
        );
      }

      // Media kind: video only.
      if (clip.mediaKind != VGMediaKind.video) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.unsupportedMediaKind,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has media kind "${clip.mediaKind.value}"; only video clips are eligible for passthrough remux.',
          ),
        );
      }

      // Timeline start: must be 0.0.
      if (clip.startTimeSeconds != 0.0) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.nonZeroTimelineStart,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has startTimeSeconds ${clip.startTimeSeconds}; direct passthrough remux requires timeline start at 0.0.',
          ),
        );
      }

      // Trim range validity & untrimmed requirement.
      if (clip.trimEndSeconds <= clip.trimStartSeconds) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.invalidTrimRange,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has trimEndSeconds (${clip.trimEndSeconds}) <= trimStartSeconds (${clip.trimStartSeconds}); trimEndSeconds must be greater than trimStartSeconds.',
          ),
        );
      } else if (clip.trimStartSeconds != 0.0 ||
          clip.trimEndSeconds != clip.durationSeconds) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.trimmedClip,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" is trimmed (trimStart: ${clip.trimStartSeconds}, trimEnd: ${clip.trimEndSeconds}, duration: ${clip.durationSeconds}); direct passthrough remux requires an unmodified clip spanning its entire source duration.',
          ),
        );
      }

      // Speed: must be 1.0.
      if (clip.speed != 1.0) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.unsupportedSpeed,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has speed ${clip.speed}; speed != 1.0 requires re-encoding and is not eligible for passthrough remux.',
          ),
        );
      }

      // Reverse playback: not supported.
      if (clip.isReversed) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.reversedClipPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has reverse playback enabled; reversed playback is not eligible for passthrough remux.',
          ),
        );
      }

      // Spatial transform: null required.
      if (clip.transform != null) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.clipTransformPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a spatial transform descriptor; clip transforms are not eligible for passthrough remux.',
          ),
        );
      }

      // Still image fit mode & crop rect: fitMode must be fit and cropRect must be null.
      if (clip.fitMode != VGStillImageFitMode.fit || clip.cropRect != null) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.stillImageFitOrCropPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" specifies still-image fit mode or crop rect; crop/fit is not eligible for passthrough remux.',
          ),
        );
      }

      // Freeze frame: must be null.
      if (clip.freezePTS != null) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.freezeFramePresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has freezePTS set; freeze frame extraction is not eligible for passthrough remux.',
          ),
        );
      }

      // Dual camera: must be null.
      if (clip.dualCamera != null) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.dualCameraPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a dual-camera descriptor; dual-camera composition is not eligible for passthrough remux.',
          ),
        );
      }

      // Time remap: must be null.
      if (clip.timeRemap != null) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.timeRemapPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a time remap descriptor; variable-speed time remap is not eligible for passthrough remux.',
          ),
        );
      }

      // Transform track: must be null.
      if (clip.transformTrack != null) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.transformTrackPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a transform track descriptor; keyframed transform animation is not eligible for passthrough remux.',
          ),
        );
      }

      // Color matrix: must be null.
      if (clip.colorMatrix != null) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.colorMatrixPresent,
            clipId: clip.id,
            message:
                'Clip "${clip.id}" has a color matrix descriptor; color matrix filtering is not eligible for passthrough remux.',
          ),
        );
      }
    }

    // ── 3. Request-level validation ─────────────────────────────────────────

    // Requested dimensions: must be null or exactly equal draft canvas dimensions.
    if (request.width != null || request.height != null) {
      final reqWidth = request.width ?? draft.canvasWidth;
      final reqHeight = request.height ?? draft.canvasHeight;
      if (reqWidth <= 0 ||
          reqWidth % 2 != 0 ||
          reqHeight <= 0 ||
          reqHeight % 2 != 0 ||
          reqWidth != draft.canvasWidth ||
          reqHeight != draft.canvasHeight) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.incompatibleOutputDimensions,
            message:
                'Requested export dimensions ${reqWidth}x$reqHeight do not match draft canvas dimensions ${draft.canvasWidth}x${draft.canvasHeight}; zero-reencode passthrough remux cannot resize.',
          ),
        );
      }
    }

    // Requested frame rate: must be null or exactly equal draft fps.
    if (request.fps != null) {
      if (request.fps! <= 0 || request.fps! != draft.fps) {
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.invalidFps,
            message:
                'Requested export fps ${request.fps} does not match draft fps ${draft.fps} or is invalid; zero-reencode passthrough remux cannot convert frame rate.',
          ),
        );
      }
    }

    // Requested bitrate: must be null.
    if (request.bitrateBps != null) {
      issues.add(
        VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.unsupportedBitrateOverride,
          message:
              'Request specifies bitrateBps (${request.bitrateBps}); bitrate override implies re-encoding and is not eligible for passthrough remux.',
        ),
      );
    }

    // Temporal denoise: must not be true.
    if (request.temporalDenoiseEnabled == true) {
      issues.add(
        const VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.unsupportedTemporalDenoise,
          message:
              'Request specifies temporalDenoiseEnabled=true; temporal denoise requires GPU re-encoding and is not eligible for passthrough remux.',
        ),
      );
    }

    // Output path & container format validation.
    String resolvedContainerFormat;
    if (request.outputPath != null) {
      final trimmed = request.outputPath!.trim();
      final lower = trimmed.toLowerCase();
      if (lower.endsWith('.mp4')) {
        resolvedContainerFormat = 'mp4';
      } else if (lower.endsWith('.m4v')) {
        resolvedContainerFormat = 'm4v';
      } else {
        resolvedContainerFormat = 'unsupported';
        issues.add(
          VGPassthroughRemuxIssue(
            code: VGPassthroughRemuxIssueCode.incompatibleContainerFormat,
            message:
                'Requested outputPath "$trimmed" does not end with a supported MP4 container extension (.mp4, .m4v); zero-reencode passthrough remux requires an MP4 container.',
          ),
        );
      }
    } else {
      resolvedContainerFormat = 'mp4_default';
    }

    final resolvedWidth = request.width ?? draft.canvasWidth;
    final resolvedHeight = request.height ?? draft.canvasHeight;
    final resolvedFps = request.fps ?? draft.fps;

    final decision = issues.isEmpty
        ? VGPassthroughRemuxDecision.eligible
        : VGPassthroughRemuxDecision.ineligible;

    final diagnostics = <String, Object?>{
      'proofBoundary': proofBoundaryToken,
      'clipCount': draft.clips.length,
      'transitionCount': draft.transitions.length,
      'overlayCount': draft.overlays.length,
      'issueCount': issues.length,
      'resolvedWidth': resolvedWidth,
      'resolvedHeight': resolvedHeight,
      'resolvedFps': resolvedFps,
      'requestHasOutputPath': request.outputPath != null,
      'resolvedContainerFormat': resolvedContainerFormat,
      'hasAudioSidecarPlan': draft.audioSidecarPlan != null,
      'hasTemporalDenoiseRequest': request.temporalDenoiseEnabled == true,
      'nonClaims': const <String, bool>{
        'nativeMuxExecuted': false,
        'mediaExtractorOpened': false,
        'mediaMuxerStarted': false,
        'sourceFileRead': false,
        'outputFileWritten': false,
        'codecAllocated': false,
      },
    };

    return VGPassthroughRemuxReport(
      decision: decision,
      issues: issues,
      diagnostics: diagnostics,
    );
  }

  /// Convenience static evaluation entry point.
  static VGPassthroughRemuxReport evaluateDraft({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
  }) => const VGPassthroughRemuxEvaluator().evaluate(
    draft: draft,
    request: request,
  );
}
