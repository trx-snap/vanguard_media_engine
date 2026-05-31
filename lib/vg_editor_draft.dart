// vg_editor_draft.dart
// Vanguard Media Engine — Phase 7 Stage 7.7 / Stage 7.10 / Stage 7.13 / Stage 7.14
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.7  — EDITOR DRAFT RECIPE
// STAGE 7.10 — TRANSITION-AWARE LAYOUT FACTORY
// STAGE 7.13 — NON-DESTRUCTIVE TRIM EDITING API
// STAGE 7.14 — NON-DESTRUCTIVE SPLIT EDITING API
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGEditorDraft is the immutable, non-destructive composition recipe that
// describes a complete timeline editing session.
//
// Design rules (Phase 7.7 / 7.10 / 7.13 / 7.14 / Opus M4):
//   - Pure Dart value type. No rendering logic, no channel calls.
//   - The clips list is non-destructive: source files are never modified.
//   - All fields are validated at construction time via asserts.
//   - Clip IDs must be unique within one draft.
//   - Transition fromClipId / toClipId must reference clip IDs in the draft.
//
// Phase 7.10 additions (DEC-143):
//   - VGEditorDraft.sequentialWithTransitions(...) computes clip startTimeSeconds
//     so that each non-hard-cut transition creates an overlap window between
//     the outgoing and incoming clips. Dart is the single source of truth for
//     startTimeSeconds. Native consumes the pre-shifted values.
//   - durationSeconds now subtracts non-hard-cut transition overlaps from the
//     sum of clip timelineDurations. This matches what native computes as
//     lastClip.startTimeSeconds + lastClip.timelineDuration.
//
// Phase 7.13 additions (DEC-146):
//   - VGEditorDraft.trimClip(...) is a non-destructive trim-editing helper that
//     validates the new trim range, replaces the target clip, and recomputes
//     the sequential layout via sequentialWithTransitions. Dart is the single
//     source of truth for trim validation and start-time cascade (DEC-146).
//
// Phase 7.14 additions (DEC-147):
//   - VGEditorDraft.splitClip(...) is a non-destructive split-editing helper that
//     divides a clip at a source-local playhead position (splitSeconds) into two
//     adjacent clips. The left clip retains the original ID; the right clip gets
//     a deterministic unique ID. Outgoing transitions are rebound to the right
//     clip. The sequential layout is recomputed via sequentialWithTransitions.
//     Dart is the single source of truth for split math, ID generation, and
//     transition rebinding (DEC-147).
//
// Consumed by VGEditorController (Stage 7.7) to coordinate channel calls.
//
// Serialisation:
//   toMap() produces a JSON-compatible map:
//   {
//     'id': String,
//     'clips': List<Map>,
//     'transitions': List<Map>,
//     'canvasWidth': int,
//     'canvasHeight': int,
//     'fps': int,
//   }

import 'vg_clip_descriptor.dart';
import 'vg_transition_descriptor.dart';

/// An immutable, non-destructive composition recipe for a Phase 7 timeline
/// editing session.
///
/// [VGEditorDraft] describes the full clip sequence, inter-clip transitions,
/// and canvas geometry for a single editing draft. It is a pure Dart value
/// type — it holds metadata only, never touches source media files.
///
/// Consumed by [VGEditorController] to build and rebuild the native playback
/// and export timelines via the proven `dev_*` MethodChannel routes.
///
/// ```dart
/// final draft = VGEditorDraft(
///   id: 'draft-001',
///   clips: [clipA, clipB],
/// );
/// print(draft.durationSeconds); // sum of clip timelineDurations
/// ```
final class VGEditorDraft {
  /// Creates an immutable draft composition.
  ///
  /// [id] must be non-empty. Stable identifier for this editing session.
  ///
  /// [clips] must be non-empty. All clip IDs must be unique within this draft.
  ///
  /// [transitions] may be empty. If provided, each transition's [fromClipId]
  /// and [toClipId] must reference IDs present in [clips]. In Phase 7.7 only
  /// hard-cut transitions ([VGTransitionType.none]) are executed by native;
  /// other types are stored but will be rejected at playback/export time.
  ///
  /// [canvasWidth] and [canvasHeight] must both be > 0.
  ///
  /// [fps] must be > 0.
  VGEditorDraft({
    required this.id,
    required List<VGClipDescriptor> clips,
    List<VGTransitionDescriptor> transitions = const [],
    this.canvasWidth = 640,
    this.canvasHeight = 360,
    this.fps = 30,
  })  : clips = List.unmodifiable(clips),
        transitions = List.unmodifiable(transitions),
        assert(id.isNotEmpty, 'VGEditorDraft: id must not be empty'),
        assert(clips.isNotEmpty, 'VGEditorDraft: clips must not be empty'),
        assert(canvasWidth > 0, 'VGEditorDraft: canvasWidth must be > 0'),
        assert(canvasHeight > 0, 'VGEditorDraft: canvasHeight must be > 0'),
        assert(fps > 0, 'VGEditorDraft: fps must be > 0'),
        assert(
          _allClipIdsUnique(clips),
          'VGEditorDraft: clip IDs must be unique within a draft',
        ),
        assert(
          _transitionsReferencesValid(clips, transitions),
          'VGEditorDraft: transition fromClipId/toClipId must reference existing clip IDs',
        );

  /// Creates a [VGEditorDraft] with clips automatically positioned so that
  /// adjacent non-hard-cut transitions produce an overlap window.
  ///
  /// **Dart is the single source of truth for [VGClipDescriptor.startTimeSeconds]
  /// in transition-aware timelines (DEC-143).** The factory computes each
  /// clip's start time so that:
  ///
  ///   `clip[i+1].startTimeSeconds`
  ///     `= clip[i].startTimeSeconds + clip[i].timelineDuration`
  ///     `    - transitionOverlap(clip[i], clip[i+1])`
  ///
  /// where `transitionOverlap` is the [VGTransitionDescriptor.durationSeconds]
  /// of the non-hard-cut transition between clip[i] and clip[i+1], or 0.0 for
  /// hard cuts.
  ///
  /// The [VGClipDescriptor.startTimeSeconds] values in the supplied [clips] are
  /// **ignored** — this factory overwrites them with the computed positions.
  ///
  /// [transitions] must reference adjacent clip IDs in the supplied [clips]
  /// list (same constraint enforced natively — error code 12).
  ///
  /// ```dart
  /// final draft = VGEditorDraft.sequentialWithTransitions(
  ///   id: 'draft-001',
  ///   clips: [clipA, clipB, clipC],
  ///   transitions: [
  ///     VGTransitionDescriptor(
  ///       id: 'tr-1',
  ///       type: VGTransitionType.dissolve,
  ///       durationSeconds: 0.5,
  ///       fromClipId: 'clip-A',
  ///       toClipId: 'clip-B',
  ///     ),
  ///   ],
  /// );
  /// // clipA.startTimeSeconds = 0.0
  /// // clipB.startTimeSeconds = clipA.timelineDuration - 0.5
  /// // clipC.startTimeSeconds = clipB.startTimeSeconds + clipB.timelineDuration
  /// ```
  factory VGEditorDraft.sequentialWithTransitions({
    required String id,
    required List<VGClipDescriptor> clips,
    List<VGTransitionDescriptor> transitions = const [],
    int canvasWidth = 640,
    int canvasHeight = 360,
    int fps = 30,
  }) {
    assert(clips.isNotEmpty,
        'VGEditorDraft.sequentialWithTransitions: clips must not be empty');

    // Build (fromClipId → toClipId) → transition lookup.
    final transitionMap = <String, VGTransitionDescriptor>{};
    for (final t in transitions) {
      final from = t.fromClipId;
      final to = t.toClipId;
      if (from != null && to != null) {
        transitionMap['$from→$to'] = t;
      }
    }

    // Compute startTimeSeconds for each clip.
    // cursor advances by clip[i].timelineDuration minus any overlap.
    double cursor = 0.0;
    final positioned = <VGClipDescriptor>[];
    for (var i = 0; i < clips.length; i++) {
      positioned.add(clips[i].copyWith(startTimeSeconds: cursor));
      if (i < clips.length - 1) {
        final key = '${clips[i].id}→${clips[i + 1].id}';
        final t = transitionMap[key];
        final overlap = (t != null && !t.isHardCut) ? t.durationSeconds : 0.0;
        cursor += clips[i].timelineDuration - overlap;
      }
    }

    return VGEditorDraft(
      id: id,
      clips: positioned,
      transitions: transitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
    );
  }

  // ── Identity ───────────────────────────────────────────────────────────────

  /// Stable identifier for this draft session. Must be non-empty.
  ///
  /// Suitable for use as a persistence key, undo-history key, or diff target.
  final String id;

  // ── Clip sequence ──────────────────────────────────────────────────────────

  /// Ordered, non-destructive clip sequence.
  ///
  /// The clips list is unmodifiable. Clip IDs are unique within this draft.
  /// Source files referenced by each [VGClipDescriptor.sourcePath] are never
  /// modified; all edits are non-destructive and exist only in the descriptors.
  final List<VGClipDescriptor> clips;

  /// Inter-clip transitions.
  ///
  /// The transitions list is unmodifiable. If non-empty, each transition's
  /// [VGTransitionDescriptor.fromClipId] and [VGTransitionDescriptor.toClipId]
  /// reference IDs present in [clips].
  ///
  /// **Phase 7.7 restriction:** Only [VGTransitionType.none] (hard cuts) are
  /// currently executed by the native timeline compositor (DEC-138). Other
  /// types stored here will be rejected at playback/export time by the native
  /// layer until Phase 7.8+.
  final List<VGTransitionDescriptor> transitions;

  // ── Canvas geometry ────────────────────────────────────────────────────────

  /// Target render width in pixels. Must be > 0.
  final int canvasWidth;

  /// Target render height in pixels. Must be > 0.
  final int canvasHeight;

  /// Target frame rate for playback and export. Must be > 0.
  final int fps;

  // ── Derived helpers ────────────────────────────────────────────────────────

  /// Total wall-clock duration of the timeline in seconds.
  ///
  /// For hard-cut-only timelines: sum of [VGClipDescriptor.timelineDuration]
  /// for all clips.
  ///
  /// For timelines with non-hard-cut transitions (typically created via
  /// [VGEditorDraft.sequentialWithTransitions]): the sum of clip
  /// [VGClipDescriptor.timelineDuration] values minus the sum of non-hard-cut
  /// [VGTransitionDescriptor.durationSeconds] overlap windows.
  ///
  /// **Phase 7.10 / DEC-143**: Dart is the single source of truth for timeline
  /// layout. When clips are positioned by [sequentialWithTransitions], this
  /// value equals `lastClip.startTimeSeconds + lastClip.timelineDuration`,
  /// which is also how native computes `_totalTimelineDuration`. Both
  /// representations are equivalent for EOS detection.
  double get durationSeconds {
    double total = clips.fold(0.0, (sum, c) => sum + c.timelineDuration);
    for (final t in transitions) {
      if (!t.isHardCut) {
        total -= t.durationSeconds;
      }
    }
    return total < 0.0 ? 0.0 : total;
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this draft to a JSON-compatible map.
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "id": "draft-001",
  ///   "clips": [...],
  ///   "transitions": [...],
  ///   "canvasWidth": 640,
  ///   "canvasHeight": 360,
  ///   "fps": 30
  /// }
  /// ```
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'clips': clips.map((c) => c.toMap()).toList(),
        'transitions': transitions.map((t) => t.toMap()).toList(),
        'canvasWidth': canvasWidth,
        'canvasHeight': canvasHeight,
        'fps': fps,
      };

  /// Deserialises a [VGEditorDraft] from a map produced by [toMap].
  ///
  /// Returns `null` if required fields are missing or invalid.
  ///
  /// Note: validation asserts run in debug mode. In release mode, invalid
  /// field combinations will produce a draft without assert failures; callers
  /// should validate before using in release builds if needed.
  static VGEditorDraft? fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    if (id == null || id is! String || id.isEmpty) return null;

    final rawClips = map['clips'];
    if (rawClips == null || rawClips is! List) return null;
    final clips = <VGClipDescriptor>[];
    for (final entry in rawClips) {
      if (entry is! Map<Object?, Object?>) return null;
      final c = VGClipDescriptor.fromMap(entry);
      if (c == null) return null;
      clips.add(c);
    }
    if (clips.isEmpty) return null;

    final rawTransitions = map['transitions'];
    final transitions = <VGTransitionDescriptor>[];
    if (rawTransitions is List) {
      for (final entry in rawTransitions) {
        if (entry is Map<Object?, Object?>) {
          final t = VGTransitionDescriptor.fromMap(entry);
          if (t != null) transitions.add(t);
        }
      }
    }

    final canvasWidth = (map['canvasWidth'] as num?)?.toInt() ?? 640;
    final canvasHeight = (map['canvasHeight'] as num?)?.toInt() ?? 360;
    final fps = (map['fps'] as num?)?.toInt() ?? 30;

    if (canvasWidth <= 0 || canvasHeight <= 0 || fps <= 0) return null;

    return VGEditorDraft(
      id: id,
      clips: clips,
      transitions: transitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
    );
  }

  // ── Trim editing (Phase 7.13 / DEC-146) ─────────────────────────────────

  /// Returns a new copy of this draft with [clipId]'s trim window adjusted,
  /// and with all clip [VGClipDescriptor.startTimeSeconds] recomputed via
  /// [VGEditorDraft.sequentialWithTransitions].
  ///
  /// This is a **non-destructive** operation — the source media file is never
  /// modified. The returned draft is a fully immutable new instance.
  ///
  /// **Dart is the single source of truth for trim range validation and
  /// sequential layout recomputation (DEC-146).** The validated, recomputed
  /// draft is then forwarded to the native timeline via
  /// `VGEditorController.updateDraft` → `updateTimeline` MethodChannel route.
  ///
  /// [trimStartSeconds] and [trimEndSeconds] are measured in source-asset
  /// seconds (same coordinate space as [VGClipDescriptor.trimStartSeconds]
  /// and [VGClipDescriptor.trimEndSeconds]).
  ///
  /// Throws [ArgumentError] if:
  /// - [clipId] is not found in this draft.
  /// - [trimStartSeconds] < 0.
  /// - [trimEndSeconds] exceeds the clip's [VGClipDescriptor.durationSeconds].
  /// - The resulting trim duration is less than 0.1 s (minimum visible clip).
  /// - The resulting timeline duration of the clip is less than the total
  ///   non-hard-cut transition overlap attached to that clip, which would
  ///   collapse the transition overlap windows.
  ///
  /// ```dart
  /// final trimmed = draft.trimClip(
  ///   clipId: 'clip-A',
  ///   trimStartSeconds: 1.5,
  ///   trimEndSeconds: 4.5,
  /// );
  /// // trimmed.clips[0].trimStartSeconds == 1.5
  /// // trimmed.clips[0].trimEndSeconds   == 4.5
  /// // all subsequent clips' startTimeSeconds are recomputed
  /// ```
  VGEditorDraft trimClip({
    required String clipId,
    required double trimStartSeconds,
    required double trimEndSeconds,
  }) {
    // 1. Locate the target clip.
    final targetIndex = clips.indexWhere((c) => c.id == clipId);
    if (targetIndex == -1) {
      throw ArgumentError(
        'VGEditorDraft.trimClip: clip "$clipId" not found in draft "$id".',
      );
    }
    final targetClip = clips[targetIndex];

    // 2. Validate the new trim range.
    _validateTrimRange(
      clip: targetClip,
      clipIndex: targetIndex,
      newTrimStart: trimStartSeconds,
      newTrimEnd: trimEndSeconds,
      clips: clips,
      transitions: transitions,
    );

    // 3. Build the updated clip list (only the target clip changes).
    final updatedClip = targetClip.copyWith(
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
    );
    final updatedClips = List<VGClipDescriptor>.of(clips);
    updatedClips[targetIndex] = updatedClip;

    // 4. Recompute sequential layout (propagates startTimeSeconds cascade).
    return VGEditorDraft.sequentialWithTransitions(
      id: id,
      clips: updatedClips,
      transitions: transitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
    );
  }

  // ── Split editing (Phase 7.14 / DEC-147) ──────────────────────────────────

  /// Returns a new copy of this draft with [clipId] split into two adjacent
  /// clips at [splitSeconds] (measured in absolute source-local seconds).
  ///
  /// The split divides the clip's active trim window:
  /// - **Left Clip**: retains the original [clipId], keeps [VGClipDescriptor.trimStartSeconds],
  ///   and sets its [VGClipDescriptor.trimEndSeconds] = [splitSeconds].
  /// - **Right Clip**: assigned a deterministic unique id (`${clipId}-split-1`,
  ///   incrementing the suffix if there is a collision), sets
  ///   [VGClipDescriptor.trimStartSeconds] = [splitSeconds], and retains the
  ///   original [VGClipDescriptor.trimEndSeconds].
  ///
  /// Both clips inherit the original [VGClipDescriptor.sourcePath],
  /// [VGClipDescriptor.mediaKind], [VGClipDescriptor.durationSeconds],
  /// [VGClipDescriptor.speed], and [VGClipDescriptor.transform].
  ///
  /// **Transition rebinding (DEC-147):**
  /// - Outgoing transitions (`fromClipId == clipId`) are rebound to depart
  ///   from the new right clip ID.
  /// - Incoming transitions (`toClipId == clipId`) remain bound to the left
  ///   clip ID.
  /// - The split boundary between left and right is a hard cut — no transition
  ///   is inserted at the boundary.
  ///
  /// The sequential layout (all `startTimeSeconds`) is recomputed via
  /// [VGEditorDraft.sequentialWithTransitions] after the split.
  ///
  /// **Dart is the single source of truth for split math, ID generation, and
  /// transition rebinding (DEC-147).** The rebuilt draft is forwarded to the
  /// native timeline via `VGEditorController.updateDraft` → `updateTimeline`.
  ///
  /// Throws [ArgumentError] if:
  /// - [clipId] is not found in this draft.
  /// - [splitSeconds] is not strictly within the clip's active trim window
  ///   (`trimStartSeconds < splitSeconds < trimEndSeconds`).
  /// - Either resulting clip's active duration is below 0.1 s (minimum).
  /// - The left clip's resulting `timelineDuration` is less than its incoming
  ///   non-hard-cut transition overlap (would collapse transition window).
  /// - The right clip's resulting `timelineDuration` is less than its outgoing
  ///   non-hard-cut transition overlap (would collapse transition window).
  ///
  /// ```dart
  /// final split = draft.splitClip(
  ///   clipId: 'clip-A',
  ///   splitSeconds: 3.0,
  /// );
  /// // split.clips[0].id              == 'clip-A'
  /// // split.clips[0].trimEndSeconds  == 3.0
  /// // split.clips[1].id              == 'clip-A-split-1'
  /// // split.clips[1].trimStartSeconds == 3.0
  /// ```
  VGEditorDraft splitClip({
    required String clipId,
    required double splitSeconds,
  }) {
    // 1. Locate the target clip.
    final targetIndex = clips.indexWhere((c) => c.id == clipId);
    if (targetIndex == -1) {
      throw ArgumentError(
        'VGEditorDraft.splitClip: clip "$clipId" not found in draft "$id".',
      );
    }
    final targetClip = clips[targetIndex];

    // 2. Validate: splitSeconds must be strictly within the active trim window.
    if (splitSeconds <= targetClip.trimStartSeconds ||
        splitSeconds >= targetClip.trimEndSeconds) {
      throw ArgumentError(
        'VGEditorDraft.splitClip: splitSeconds ($splitSeconds) must be '
        'strictly between trimStartSeconds (${targetClip.trimStartSeconds}) '
        'and trimEndSeconds (${targetClip.trimEndSeconds}) '
        'for clip "$clipId".',
      );
    }

    // 3. Validate minimum active duration for both resulting clips.
    final leftDuration = splitSeconds - targetClip.trimStartSeconds;
    final rightDuration = targetClip.trimEndSeconds - splitSeconds;
    if (leftDuration < _kMinTrimDurationSeconds ||
        rightDuration < _kMinTrimDurationSeconds) {
      throw ArgumentError(
        'VGEditorDraft.splitClip: resulting clip active durations '
        '($leftDuration s / $rightDuration s) must each be >= '
        '$_kMinTrimDurationSeconds s. Do not silently clamp.',
      );
    }

    // 4. Generate a deterministic unique ID for the right-hand split clip.
    //    Starts at "${clipId}-split-1" and increments until unique.
    final existingIds = clips.map((c) => c.id).toSet();
    var splitIndex = 1;
    var rightId = '$clipId-split-$splitIndex';
    while (existingIds.contains(rightId)) {
      splitIndex++;
      rightId = '$clipId-split-$splitIndex';
    }

    // 5. Validate transition-overlap safety.
    //    Left clip timeline duration must satisfy incoming transition overlap.
    //    Right clip timeline duration must satisfy outgoing transition overlap.
    final prevClipId = targetIndex > 0 ? clips[targetIndex - 1].id : null;
    final nextClipId =
        targetIndex < clips.length - 1 ? clips[targetIndex + 1].id : null;

    double overlapIn = 0.0;
    double overlapOut = 0.0;
    for (final t in transitions) {
      if (t.isHardCut) continue;
      if (t.toClipId == targetClip.id && t.fromClipId == prevClipId) {
        overlapIn += t.durationSeconds;
      }
      if (t.fromClipId == targetClip.id && t.toClipId == nextClipId) {
        overlapOut += t.durationSeconds;
      }
    }

    final leftTimelineDuration = leftDuration / targetClip.speed;
    final rightTimelineDuration = rightDuration / targetClip.speed;
    if (leftTimelineDuration < overlapIn) {
      throw ArgumentError(
        'VGEditorDraft.splitClip: resulting left clip timelineDuration '
        '($leftTimelineDuration s) for clip "$clipId" is less than its '
        'incoming transition overlap ($overlapIn s). '
        'Split would collapse transition window.',
      );
    }
    if (rightTimelineDuration < overlapOut) {
      throw ArgumentError(
        'VGEditorDraft.splitClip: resulting right clip timelineDuration '
        '($rightTimelineDuration s) for clip "$clipId" is less than its '
        'outgoing transition overlap ($overlapOut s). '
        'Split would collapse transition window.',
      );
    }

    // 6. Build left and right clip descriptors.
    //    Left clip: retain original id, update trimEnd only.
    //    Right clip: new id, update trimStart only. All other fields inherited.
    final leftClip = targetClip.copyWith(trimEndSeconds: splitSeconds);
    final rightClip = targetClip.copyWith(
      id: rightId,
      trimStartSeconds: splitSeconds,
    );

    // 7. Assemble updated clip list: replace target, insert right clip after.
    final updatedClips = List<VGClipDescriptor>.of(clips);
    updatedClips[targetIndex] = leftClip;
    updatedClips.insert(targetIndex + 1, rightClip);

    // 8. Rebind outgoing transitions from the original clip to the right clip.
    //    Incoming transitions remain bound to the left clip (its ID is unchanged).
    final updatedTransitions = transitions.map((t) {
      if (t.fromClipId == targetClip.id) {
        return t.copyWith(fromClipId: rightId);
      }
      return t;
    }).toList();

    // 9. Rebuild the sequential layout (propagates startTimeSeconds cascade).
    return VGEditorDraft.sequentialWithTransitions(
      id: id,
      clips: updatedClips,
      transitions: updatedTransitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this draft with the specified fields replaced.
  ///
  /// Validation asserts are enforced on the new instance.
  VGEditorDraft copyWith({
    String? id,
    List<VGClipDescriptor>? clips,
    List<VGTransitionDescriptor>? transitions,
    int? canvasWidth,
    int? canvasHeight,
    int? fps,
  }) {
    return VGEditorDraft(
      id: id ?? this.id,
      clips: clips ?? this.clips,
      transitions: transitions ?? this.transitions,
      canvasWidth: canvasWidth ?? this.canvasWidth,
      canvasHeight: canvasHeight ?? this.canvasHeight,
      fps: fps ?? this.fps,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorDraft &&
          other.id == id &&
          _listEqual(other.clips, clips) &&
          _listEqual(other.transitions, transitions) &&
          other.canvasWidth == canvasWidth &&
          other.canvasHeight == canvasHeight &&
          other.fps == fps;

  @override
  int get hashCode => Object.hash(
        id,
        Object.hashAll(clips),
        Object.hashAll(transitions),
        canvasWidth,
        canvasHeight,
        fps,
      );

  @override
  String toString() => 'VGEditorDraft('
      'id: $id, '
      'clips: ${clips.length}, '
      'transitions: ${transitions.length}, '
      'canvas: $canvasWidth\u00d7$canvasHeight, '
      'fps: $fps, '
      'duration: ${durationSeconds.toStringAsFixed(2)}s)';
}

// ── Private helpers ───────────────────────────────────────────────────────────

// Minimum trim duration, in source-asset seconds (Phase 7.13).
const double _kMinTrimDurationSeconds = 0.1;

/// Validates the proposed trim range for [clip] at [clipIndex] against the
/// known bounds, minimum-duration requirement, and transition-overlap safety.
///
/// Throws [ArgumentError] with a descriptive message on any violation.
void _validateTrimRange({
  required VGClipDescriptor clip,
  required int clipIndex,
  required double newTrimStart,
  required double newTrimEnd,
  required List<VGClipDescriptor> clips,
  required List<VGTransitionDescriptor> transitions,
}) {
  // Guard 1: trimStartSeconds must be >= 0.
  if (newTrimStart < 0.0) {
    throw ArgumentError(
      'VGEditorDraft.trimClip: trimStartSeconds ($newTrimStart) must be >= 0.'
    );
  }

  // Guard 2: trimEndSeconds must not exceed the clip's source duration.
  // durationSeconds == 0.0 means unknown (streaming); skip upper-bound check.
  if (clip.durationSeconds > 0.0 && newTrimEnd > clip.durationSeconds) {
    throw ArgumentError(
      'VGEditorDraft.trimClip: trimEndSeconds ($newTrimEnd) exceeds '
      'clip "${clip.id}" source durationSeconds (${clip.durationSeconds}).',
    );
  }

  // Guard 3: trimEndSeconds must be > trimStartSeconds (enforced by
  // VGClipDescriptor assert) with at least the minimum visible duration.
  final trimDuration = newTrimEnd - newTrimStart;
  if (trimDuration < _kMinTrimDurationSeconds) {
    throw ArgumentError(
      'VGEditorDraft.trimClip: resulting trim duration ($trimDuration s) '
      'for clip "${clip.id}" is below the minimum '
      '$_kMinTrimDurationSeconds s. Do not silently clamp.',
    );
  }

  // Guard 4: transition overlap safety.
  // The clip's resulting wall-clock timelineDuration must be >= the sum of all
  // non-hard-cut transition durations attached to it (in and out combined).
  // Otherwise the overlap windows would collapse or overlap each other.
  final timelineDuration = trimDuration / clip.speed;
  double overlapIn = 0.0;
  double overlapOut = 0.0;

  // Build predecessor and successor clip IDs.
  final prevClipId = clipIndex > 0 ? clips[clipIndex - 1].id : null;
  final nextClipId = clipIndex < clips.length - 1 ? clips[clipIndex + 1].id : null;

  for (final t in transitions) {
    if (t.isHardCut) continue;
    // Transition INTO this clip: fromClipId == previous clip, toClipId == this clip.
    if (t.toClipId == clip.id && t.fromClipId == prevClipId) {
      overlapIn += t.durationSeconds;
    }
    // Transition OUT OF this clip: fromClipId == this clip, toClipId == next clip.
    if (t.fromClipId == clip.id && t.toClipId == nextClipId) {
      overlapOut += t.durationSeconds;
    }
  }

  final totalOverlap = overlapIn + overlapOut;
  if (timelineDuration < totalOverlap) {
    throw ArgumentError(
      'VGEditorDraft.trimClip: resulting timelineDuration ($timelineDuration s) '
      'for clip "${clip.id}" is less than its total transition overlap '
      '($totalOverlap s). Trim would collapse transition windows.',
    );
  }
}

/// Returns true if all clip IDs in [clips] are unique.
bool _allClipIdsUnique(List<VGClipDescriptor> clips) {
  final seen = <String>{};
  for (final c in clips) {
    if (!seen.add(c.id)) return false;
  }
  return true;
}

/// Returns true if all transition clip references resolve to clip IDs in [clips].
///
/// Null fromClipId / toClipId are permitted (Stage 7.1 compatibility).
bool _transitionsReferencesValid(
  List<VGClipDescriptor> clips,
  List<VGTransitionDescriptor> transitions,
) {
  if (transitions.isEmpty) return true;
  final ids = clips.map((c) => c.id).toSet();
  for (final t in transitions) {
    final from = t.fromClipId;
    final to = t.toClipId;
    if (from != null && !ids.contains(from)) return false;
    if (to != null && !ids.contains(to)) return false;
  }
  return true;
}

/// Structural equality for unmodifiable lists.
bool _listEqual<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
