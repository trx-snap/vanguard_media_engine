// vg_editor_draft.dart
// Vanguard Media Engine — Phase 7 Stage 7.7 / Stage 7.10 / Stage 7.13 / Stage 7.14 / Stage 7.15 / Phase 7.19B
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.7  — EDITOR DRAFT RECIPE
// STAGE 7.10 — TRANSITION-AWARE LAYOUT FACTORY
// STAGE 7.13 — NON-DESTRUCTIVE TRIM EDITING API
// STAGE 7.14 — NON-DESTRUCTIVE SPLIT EDITING API
// STAGE 7.15 — NON-DESTRUCTIVE REORDER EDITING API
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGEditorDraft is the immutable, non-destructive composition recipe that
// describes a complete timeline editing session.
//
// Design rules (Phase 7.7 / 7.10 / 7.13 / 7.14 / 7.15 / Opus M4):
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
// Phase 7.15 additions (DEC-148 revised — Option D boundary-slot relinking):
//   - VGEditorDraft.reorderClip(...) is a non-destructive reorder-editing helper
//     that moves a clip from [fromIndex] to [toIndex], applies Option D
//     boundary-slot transition relinking (transitions are anchored to their
//     original boundary slot; after reorder, fromClipId/toClipId are rewritten
//     to the new adjacent clip pair at that slot while preserving id/type/
//     duration/curve), and recomputes the sequential layout via
//     sequentialWithTransitions. Dart is the single source of truth for reorder
//     logic and transition relinking (DEC-148).
//
// Phase 8.2 additions (additive bridge):
//   - VGEditorDraft now carries an optional VGCanvasDescriptor? canvas field.
//   - canvas is null by default; legacy canvasWidth / canvasHeight remain the
//     primary compatibility fields and are unchanged.
//   - toMap() emits root 'canvasWidth' / 'canvasHeight' unconditionally (native
//     Swift plugin reads these root keys), and emits nested 'canvas' map only
//     when canvas != null.
//   - fromMap() parses nested 'canvas' if present; otherwise leaves canvas null.
//   - resolvedCanvas is a convenience getter: returns canvas if non-null,
//     otherwise constructs a VGCanvasDescriptor from canvasWidth / canvasHeight.
//   - All internal draft reconstruction calls pass canvas: canvas so the canvas
//     reference survives trim, split, freeze, reverse, and reorder operations.
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

import 'vg_canvas_descriptor.dart';
import 'vg_clip_descriptor.dart';
import 'vg_overlay_descriptor.dart';
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
  ///
  /// [canvas] is an optional [VGCanvasDescriptor] that enriches the canvas
  /// geometry with contentMode, backgroundColor, and safe-zone insets.
  /// When null, the draft uses [canvasWidth] / [canvasHeight] alone (Phase 7
  /// behaviour). Phase 8.2 additive bridge — native Swift plugin is unaffected
  /// because [toMap] still emits the root canvasWidth / canvasHeight keys.
  ///
  /// [overlays] is an optional list of [VGOverlayDescriptor] elements (Phase 8.3
  /// additive bridge). Defaults to an empty list. Missing overlays in legacy
  /// drafts are safely ignored by [fromMap].
  VGEditorDraft({
    required this.id,
    required List<VGClipDescriptor> clips,
    List<VGTransitionDescriptor> transitions = const [],
    this.canvasWidth = 640,
    this.canvasHeight = 360,
    this.fps = 30,
    this.canvas,
    List<VGOverlayDescriptor> overlays = const [],
  })  : clips = List.unmodifiable(clips),
        transitions = List.unmodifiable(transitions),
        overlays = List.unmodifiable(overlays),
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
    // Phase 8.2: optional canvas passes through to the constructed draft.
    VGCanvasDescriptor? canvas,
    // Phase 8.3: optional overlays pass through to the constructed draft.
    List<VGOverlayDescriptor> overlays = const [],
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
      canvas: canvas,
      overlays: overlays,
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

  /// Optional rich canvas descriptor (Phase 8.2 additive bridge).
  ///
  /// When non-null, carries content-mode, background colour, and safe-zone
  /// information in addition to the raw pixel dimensions.
  ///
  /// **Backward-compatibility guarantee**: this field is additive. When null
  /// (the default), all Phase 7 behaviour is unchanged. The native Swift plugin
  /// always reads the root `canvasWidth` / `canvasHeight` keys from [toMap],
  /// which are emitted unconditionally regardless of this field.
  ///
  /// Use [resolvedCanvas] to obtain a non-nullable descriptor.
  final VGCanvasDescriptor? canvas;

  /// Returns [canvas] if explicitly set, otherwise constructs a minimal
  /// [VGCanvasDescriptor] from [canvasWidth] and [canvasHeight].
  ///
  /// Callers that need a non-nullable canvas (e.g. overlay validation) should
  /// use this getter rather than accessing [canvas] directly.
  VGCanvasDescriptor get resolvedCanvas =>
      canvas ?? VGCanvasDescriptor(width: canvasWidth, height: canvasHeight);

  // ── Overlays ────────────────────────────────────────────────────────────────

  /// Timed overlay elements on the timeline canvas (Phase 8.3 additive bridge).
  ///
  /// Each element is a [VGOverlayDescriptor] describing a text, emoji, or
  /// sticker overlay with absolute canvas-pixel geometry.
  ///
  /// Defaults to an empty list. Legacy drafts without an `'overlays'` key in
  /// their serialised map will produce an empty list here (backward-compatible).
  ///
  /// **Phase 8.3**: Data model only. Not yet wired into the native graph
  /// or MethodChannel. Graph wiring is Phase 8.4+.
  final List<VGOverlayDescriptor> overlays;

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
  /// The root `canvasWidth` and `canvasHeight` keys are always emitted so that
  /// the native Swift plugin (which reads these root keys directly) requires no
  /// changes in Phase 8.2.
  ///
  /// When [canvas] is non-null, a nested `'canvas'` map is additionally emitted
  /// so that Phase 8.3+ consumers can read the full canvas descriptor.
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "id": "draft-001",
  ///   "clips": [...],
  ///   "transitions": [...],
  ///   "canvasWidth": 640,
  ///   "canvasHeight": 360,
  ///   "fps": 30,
  ///   "canvas": { ... }   // omitted when canvas == null
  /// }
  /// ```
  Map<String, Object?> toMap() {
    final m = <String, Object?>{
      'id': id,
      'clips': clips.map((c) => c.toMap()).toList(),
      'transitions': transitions.map((t) => t.toMap()).toList(),
      'canvasWidth': canvasWidth,
      'canvasHeight': canvasHeight,
      'fps': fps,
      // Phase 8.3: overlays are always serialised (empty list is valid JSON).
      'overlays': overlays.map((o) => o.toMap()).toList(),
    };
    // Phase 8.2: emit nested canvas map only when explicitly set.
    // Root canvasWidth / canvasHeight keys above always satisfy the native
    // Swift plugin — no native-side changes are needed.
    if (canvas != null) {
      m['canvas'] = canvas!.toMap();
    }
    return m;
  }

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

    // Phase 8.2: parse nested 'canvas' map if present and valid.
    // Falls back to null when the key is missing (Phase 7 / legacy drafts).
    VGCanvasDescriptor? canvas;
    final rawCanvas = map['canvas'];
    if (rawCanvas is Map<Object?, Object?>) {
      canvas = VGCanvasDescriptor.fromMap(rawCanvas);
    }

    // Phase 8.3: parse 'overlays' list if present.
    // Missing, null, or malformed → empty list (backward-compatible).
    final overlays = <VGOverlayDescriptor>[];
    final rawOverlays = map['overlays'];
    if (rawOverlays is List) {
      for (final entry in rawOverlays) {
        if (entry is Map<Object?, Object?>) {
          final o = VGOverlayDescriptor.fromMap(entry);
          if (o != null) overlays.add(o);
        }
        // Non-map entries are silently skipped (recovery-oriented).
      }
    }

    return VGEditorDraft(
      id: id,
      clips: clips,
      transitions: transitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
      canvas: canvas,
      overlays: overlays,
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
      canvas: canvas,
      overlays: overlays,
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
      canvas: canvas,
      overlays: overlays,
    );
  }

  // ── Freeze frame editing (Phase 7.17 / DEC-150) ─────────────────────────────

  /// Returns a new copy of this draft with [clipId] replaced by three adjacent
  /// clips: a **left clip** (normal video up to [splitSeconds]), a **freeze
  /// clip** (a static hold of the frame at [splitSeconds] for [duration]
  /// seconds), and a **right clip** (normal video from [splitSeconds] onward).
  ///
  /// **Three-way split layout:**
  /// 1. **Left clip**: keeps original [clipId]; trim window
  ///    `[original.trimStartSeconds, splitSeconds]`.
  /// 2. **Freeze clip**: new ID `"${clipId}-freeze-1"` (suffix incremented on
  ///    collision); `freezePTS = splitSeconds`; `durationSeconds = duration`;
  ///    `trimStartSeconds = 0.0`; `trimEndSeconds = duration`; `speed = 1.0`.
  ///    The native compositor extracts the frame via `AVAssetImageGenerator`
  ///    on first pull and caches it as a static source (RR-154).
  /// 3. **Right clip**: new ID `"${clipId}-split-1"` (suffix incremented on
  ///    collision); trim window `[splitSeconds, original.trimEndSeconds]`.
  ///
  /// **Transition rebinding:**
  /// - Incoming transitions to the original clip remain bound to the left clip.
  /// - Outgoing transitions from the original clip are rebound to the right clip.
  /// - The two new boundaries (left→freeze, freeze→right) are hard cuts.
  ///
  /// **Audio**: freeze clips are implicitly audio-silent in Phase 7.17 because
  /// no timeline audio pipeline exists. Future audio code should treat
  /// `freezePTS != null` as a mute/suppress-audio signal.
  ///
  /// Throws [ArgumentError] if:
  /// - [clipId] is not found in this draft.
  /// - The target clip is not `VGMediaKind.video`.
  /// - [duration] is not > 0.
  /// - [splitSeconds] is not strictly within `(trimStartSeconds, trimEndSeconds)`.
  /// - Either resulting left/right clip active duration is below 0.1 s.
  /// - The left or right clip's `timelineDuration` is less than its transition
  ///   overlap (would collapse the transition window).
  ///
  /// ```dart
  /// final frozen = draft.freezeClip(
  ///   clipId: 'clip-A',
  ///   splitSeconds: 3.0,
  ///   duration: 2.0,
  /// );
  /// // frozen.clips[0].id             == 'clip-A'        (left)
  /// // frozen.clips[1].id             == 'clip-A-freeze-1' (freeze)
  /// // frozen.clips[1].freezePTS      == 3.0
  /// // frozen.clips[2].id             == 'clip-A-split-1'  (right)
  /// ```
  VGEditorDraft freezeClip(
    String clipId,
    double splitSeconds,
    double duration,
  ) {
    // 1. Locate the target clip.
    final targetIndex = clips.indexWhere((c) => c.id == clipId);
    if (targetIndex == -1) {
      throw ArgumentError(
        'VGEditorDraft.freezeClip: clip "$clipId" not found in draft "$id".',
      );
    }
    final targetClip = clips[targetIndex];

    // 2. Validate: must be a video clip.
    if (targetClip.mediaKind != VGMediaKind.video) {
      throw ArgumentError(
        'VGEditorDraft.freezeClip: clip "$clipId" is not a video clip '
        '(mediaKind=${targetClip.mediaKind.value}). '
        'Freeze frame only applies to VGMediaKind.video clips.',
      );
    }

    // 3. Validate: duration must be > 0.
    if (duration <= 0.0) {
      throw ArgumentError(
        'VGEditorDraft.freezeClip: duration ($duration) must be > 0 '
        'for clip "$clipId".',
      );
    }

    // 4. Validate: splitSeconds must be strictly within the active trim window.
    if (splitSeconds <= targetClip.trimStartSeconds ||
        splitSeconds >= targetClip.trimEndSeconds) {
      throw ArgumentError(
        'VGEditorDraft.freezeClip: splitSeconds ($splitSeconds) must be '
        'strictly between trimStartSeconds (${targetClip.trimStartSeconds}) '
        'and trimEndSeconds (${targetClip.trimEndSeconds}) '
        'for clip "$clipId".',
      );
    }

    // 5. Validate minimum active duration for left and right clips.
    final leftDuration = splitSeconds - targetClip.trimStartSeconds;
    final rightDuration = targetClip.trimEndSeconds - splitSeconds;
    if (leftDuration < _kMinTrimDurationSeconds ||
        rightDuration < _kMinTrimDurationSeconds) {
      throw ArgumentError(
        'VGEditorDraft.freezeClip: resulting left/right clip active durations '
        '($leftDuration s / $rightDuration s) must each be >= '
        '$_kMinTrimDurationSeconds s. Do not silently clamp.',
      );
    }

    // 6. Generate deterministic unique IDs for freeze and right clips.
    //    Freeze: "${clipId}-freeze-1", incrementing suffix on collision.
    //    Right:  "${clipId}-split-1",  incrementing suffix on collision.
    final existingIds = clips.map((c) => c.id).toSet();

    var freezeIndex = 1;
    var freezeId = '$clipId-freeze-$freezeIndex';
    while (existingIds.contains(freezeId)) {
      freezeIndex++;
      freezeId = '$clipId-freeze-$freezeIndex';
    }
    // Reserve freezeId so the right clip suffix search sees it.
    existingIds.add(freezeId);

    var splitIndex = 1;
    var rightId = '$clipId-split-$splitIndex';
    while (existingIds.contains(rightId)) {
      splitIndex++;
      rightId = '$clipId-split-$splitIndex';
    }

    // 7. Validate transition-overlap safety (mirrors splitClip logic).
    //    Left clip: incoming overlap must not exceed left timeline duration.
    //    Right clip: outgoing overlap must not exceed right timeline duration.
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
        'VGEditorDraft.freezeClip: resulting left clip timelineDuration '
        '($leftTimelineDuration s) for clip "$clipId" is less than its '
        'incoming transition overlap ($overlapIn s). '
        'Freeze would collapse transition window.',
      );
    }
    if (rightTimelineDuration < overlapOut) {
      throw ArgumentError(
        'VGEditorDraft.freezeClip: resulting right clip timelineDuration '
        '($rightTimelineDuration s) for clip "$clipId" is less than its '
        'outgoing transition overlap ($overlapOut s). '
        'Freeze would collapse transition window.',
      );
    }

    // 8. Build the three new clip descriptors.
    //
    //    Left clip: retains original clipId; trim window [trimStart, splitSeconds].
    //    Inherits original transform; freezePTS stays null (normal video).
    final leftClip = targetClip.copyWith(trimEndSeconds: splitSeconds);

    //    Freeze clip: new freezeId; source is same file; mediaKind stays video.
    //    durationSeconds = duration (the hold duration, not the source duration).
    //    trimStartSeconds = 0.0, trimEndSeconds = duration (describes hold on timeline).
    //    freezePTS = splitSeconds (source-local extraction PTS).
    //    speed = 1.0, transform = null, fitMode = default, cropRect = null.
    final freezeClipDescriptor = VGClipDescriptor(
      id: freezeId,
      sourcePath: targetClip.sourcePath,
      mediaKind: VGMediaKind.video,
      // startTimeSeconds will be recomputed by sequentialWithTransitions.
      startTimeSeconds: 0.0,
      durationSeconds: duration,
      trimStartSeconds: 0.0,
      trimEndSeconds: duration,
      speed: 1.0,
      transform: null,
      fitMode: VGStillImageFitMode.fit,
      cropRect: null,
      freezePTS: splitSeconds,
    );

    //    Right clip: new rightId; trim window [splitSeconds, trimEnd].
    //    Inherits original transform, speed, and other fields.
    final rightClip = targetClip.copyWith(
      id: rightId,
      trimStartSeconds: splitSeconds,
    );

    // 9. Assemble updated clip list: replace target with left, insert freeze,
    //    then right.
    final updatedClips = List<VGClipDescriptor>.of(clips);
    updatedClips[targetIndex] = leftClip;
    updatedClips.insert(targetIndex + 1, freezeClipDescriptor);
    updatedClips.insert(targetIndex + 2, rightClip);

    // 10. Rebind outgoing transitions from the original clip to the right clip.
    //     Incoming transitions stay on the left clip (its ID is unchanged).
    //     Boundaries left→freeze and freeze→right are hard cuts (no transitions
    //     created here).
    final updatedTransitions = transitions.map((t) {
      if (t.fromClipId == targetClip.id) {
        return t.copyWith(fromClipId: rightId);
      }
      return t;
    }).toList();

    // 11. Rebuild the sequential layout (propagates startTimeSeconds cascade).
    return VGEditorDraft.sequentialWithTransitions(
      id: id,
      clips: updatedClips,
      transitions: updatedTransitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
      canvas: canvas,
      overlays: overlays,
    );
  }

  // ── Reverse playback (Phase 7.19B / DEC-154) ─────────────────────────────────

  /// Returns a new copy of this draft with [clipId]'s
  /// [VGClipDescriptor.isReversed] flag toggled.
  ///
  /// This is a **non-destructive** operation — the source media file is never
  /// modified. The returned draft is a fully immutable new instance.
  ///
  /// **Dart is the single source of truth for reverse-playback state
  /// (DEC-154).** The updated draft is forwarded to the native timeline via
  /// `VGEditorController.reverseClip` → `updateTimeline` MethodChannel route.
  ///
  /// Throws [ArgumentError] if:
  /// - [clipId] is not found in this draft.
  /// - The target clip is not `VGMediaKind.video`.
  /// - The target clip has a non-null [VGClipDescriptor.freezePTS] (freeze-frame
  ///   clips cannot be reversed — native constraint DEC-154).
  ///
  /// ```dart
  /// final reversed = draft.reverseClip(clipId: 'clip-A');
  /// // reversed.clips[0].isReversed == true  (was false)
  /// // reversed.clips[0].id          == 'clip-A'
  /// // second call toggles back:
  /// final forward = reversed.reverseClip(clipId: 'clip-A');
  /// // forward.clips[0].isReversed == false
  /// ```
  VGEditorDraft reverseClip({required String clipId}) {
    // 1. Locate the target clip.
    final targetIndex = clips.indexWhere((c) => c.id == clipId);
    if (targetIndex == -1) {
      throw ArgumentError(
        'VGEditorDraft.reverseClip: clip "$clipId" not found in draft "$id".',
      );
    }
    final targetClip = clips[targetIndex];

    // 2. Validate: must be a video clip.
    if (targetClip.mediaKind != VGMediaKind.video) {
      throw ArgumentError(
        'VGEditorDraft.reverseClip: clip "$clipId" is not a video clip '
        '(mediaKind=${targetClip.mediaKind.value}). '
        'Reverse playback only applies to VGMediaKind.video clips.',
      );
    }

    // 3. Validate: freeze-frame clips cannot be reversed.
    if (targetClip.freezePTS != null) {
      throw ArgumentError(
        'VGEditorDraft.reverseClip: clip "$clipId" is a freeze-frame clip '
        '(freezePTS=${targetClip.freezePTS}). '
        'Freeze-frame clips cannot be reversed (DEC-154).',
      );
    }

    // 4. Toggle isReversed on the target clip.
    final updatedClip = targetClip.copyWith(isReversed: !targetClip.isReversed);
    final updatedClips = List<VGClipDescriptor>.of(clips);
    updatedClips[targetIndex] = updatedClip;

    // 5. Rebuild the sequential layout (propagates startTimeSeconds cascade).
    return VGEditorDraft.sequentialWithTransitions(
      id: id,
      clips: updatedClips,
      transitions: transitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
      canvas: canvas,
      overlays: overlays,
    );
  }

  // ── Reorder editing (Phase 7.15 / DEC-148) ──────────────────────────────────

  /// Moves the clip at [fromIndex] to [toIndex] in the timeline, applies
  /// **Option D boundary-slot transition relinking**, and returns a new
  /// [VGEditorDraft] with recomputed clip start times.
  ///
  /// **Option D transition policy**: Transitions are treated as boundary-slot
  /// effects rather than permanently bound to a specific clip pair. For a
  /// timeline with N clips there are N-1 boundary slots. A transition at old
  /// boundary slot k stays at slot k after the move: its `fromClipId` and
  /// `toClipId` are rewritten to the new adjacent clip pair occupying slot k,
  /// while `id`, `type`, `durationSeconds`, and `curve` are preserved intact.
  ///
  /// Example — two clips:
  /// ```
  /// Before: A → fade(tr-0) → B
  /// After swap (fromIndex:0, toIndex:1):
  ///         B → fade(tr-0, from:B, to:A) → A
  /// ```
  ///
  /// Example — three clips:
  /// ```
  /// Before: A → t0 → B → t1 → C
  /// After moving A to end (fromIndex:0, toIndex:2):
  ///         B → t0(from:B,to:C) → C → t1(from:C,to:A) → A
  /// ```
  ///
  /// **Null-ref transitions** (Stage 7.1 compat — `fromClipId` or `toClipId`
  /// is null) cannot be matched to a slot and are **discarded**. They were
  /// never meaningfully linked to a boundary, and retaining them would produce
  /// an indeterminate layout. If Stage 7.1 null-ref compat is required, callers
  /// must re-add them after reordering.
  ///
  /// **Duration validation**: before relinking, each candidate transition's
  /// `durationSeconds` is checked against the `timelineDuration` of both new
  /// adjacent clips. If the transition duration exceeds either adjacent clip's
  /// timeline duration an [ArgumentError] is thrown before any [MethodChannel]
  /// call is made.
  ///
  /// If [fromIndex] == [toIndex] this is a no-op and returns `this` unchanged
  /// (the same instance). Drag-and-drop UIs regularly emit identity moves;
  /// the caller should inspect the return value to decide whether to push an
  /// update to the renderer.
  ///
  /// Throws [ArgumentError] if:
  /// - [fromIndex] is out of range for the current clips list.
  /// - [toIndex] is out of range for the current clips list.
  /// - A relinked transition's `durationSeconds` exceeds either new adjacent
  ///   clip's `timelineDuration`.
  ///
  /// ```dart
  /// // Swap clip at index 0 with clip at index 2:
  /// final reordered = draft.reorderClip(fromIndex: 0, toIndex: 2);
  /// // reordered.clips[0] was previously draft.clips[2]
  /// // reordered.clips[2] was previously draft.clips[0]
  /// // All startTimeSeconds recomputed.
  /// // Slot-0 transition relinked to new clips[0]→clips[1] pair.
  /// // Slot-1 transition relinked to new clips[1]→clips[2] pair.
  /// ```
  VGEditorDraft reorderClip({
    required int fromIndex,
    required int toIndex,
  }) {
    // 1. Validate index range.
    if (fromIndex < 0 || fromIndex >= clips.length) {
      throw ArgumentError(
        'VGEditorDraft.reorderClip: fromIndex ($fromIndex) is out of range '
        '[0, ${clips.length - 1}] for draft "$id".',
      );
    }
    if (toIndex < 0 || toIndex >= clips.length) {
      throw ArgumentError(
        'VGEditorDraft.reorderClip: toIndex ($toIndex) is out of range '
        '[0, ${clips.length - 1}] for draft "$id".',
      );
    }

    // 2. Identity move — return this unchanged. Drag-and-drop UIs regularly
    //    emit a drop at the same position; this avoids forcing caller-side
    //    filtering. The controller guards against pushing a no-op to native.
    if (fromIndex == toIndex) return this;

    // 3. Build the reordered clip list.
    //    Remove the clip at fromIndex, then insert it at toIndex.
    final updatedClips = List<VGClipDescriptor>.of(clips);
    final movedClip = updatedClips.removeAt(fromIndex);
    updatedClips.insert(toIndex, movedClip);


    // 4. Option D — boundary-slot transition relinking.
    //
    //    Step 4a: map each old boundary slot → the transition occupying it.
    //    Slot k is the boundary between clips[k] and clips[k+1] in the
    //    *original* (pre-reorder) ordering.
    //    Transitions with null fromClipId/toClipId (Stage 7.1 compat) cannot
    //    be matched to a slot and are discarded (see docstring).
    final oldSlotTransitions = <int, VGTransitionDescriptor>{};
    for (var k = 0; k < clips.length - 1; k++) {
      final oldFrom = clips[k].id;
      final oldTo = clips[k + 1].id;
      for (final t in transitions) {
        if (t.fromClipId == oldFrom && t.toClipId == oldTo) {
          oldSlotTransitions[k] = t;
          break; // at most one transition per slot
        }
      }
    }

    //    Step 4b: relink each slot to the new adjacent clip pair.
    //    Validate duration before accepting the relinked transition.
    final updatedTransitions = <VGTransitionDescriptor>[];
    for (var k = 0; k < updatedClips.length - 1; k++) {
      final oldTransition = oldSlotTransitions[k];
      if (oldTransition == null) continue; // no transition at this slot

      final newLeftClip = updatedClips[k];
      final newRightClip = updatedClips[k + 1];

      // Duration safety check: relinked duration must not exceed either
      // adjacent clip's wall-clock timeline contribution.
      final leftTimeline = newLeftClip.timelineDuration;
      final rightTimeline = newRightClip.timelineDuration;
      if (oldTransition.durationSeconds > leftTimeline ||
          oldTransition.durationSeconds > rightTimeline) {
        throw ArgumentError(
          'VGEditorDraft.reorderClip: relinked transition "${oldTransition.id}" '
          'durationSeconds (${oldTransition.durationSeconds}s) exceeds the '
          'timelineDuration of the new adjacent clips at slot $k '
          '(left "${newLeftClip.id}": ${leftTimeline}s, '
          'right "${newRightClip.id}": ${rightTimeline}s) for draft "$id".',
        );
      }

      // Rewrite fromClipId/toClipId; preserve id, type, durationSeconds, curve.
      updatedTransitions.add(oldTransition.copyWith(
        fromClipId: newLeftClip.id,
        toClipId: newRightClip.id,
      ));
    }

    // 5. Rebuild the sequential layout (propagates startTimeSeconds cascade).
    return VGEditorDraft.sequentialWithTransitions(
      id: id,
      clips: updatedClips,
      transitions: updatedTransitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
      canvas: canvas,
      overlays: overlays,
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this draft with the specified fields replaced.
  ///
  /// Validation asserts are enforced on the new instance.
  ///
  /// **Phase 8.2 note on [canvas]**: passing `canvas: someDescriptor` replaces
  /// the canvas. Omitting the parameter (or passing `null`) preserves the
  /// existing canvas value. There is intentionally no "clear canvas" sentinel
  /// in Phase 8.2 — if clearing is needed in a future phase, a separate
  /// `clearCanvas()` method should be added rather than abusing `null`.
  VGEditorDraft copyWith({
    String? id,
    List<VGClipDescriptor>? clips,
    List<VGTransitionDescriptor>? transitions,
    int? canvasWidth,
    int? canvasHeight,
    int? fps,
    VGCanvasDescriptor? canvas,
    List<VGOverlayDescriptor>? overlays,
  }) {
    return VGEditorDraft(
      id: id ?? this.id,
      clips: clips ?? this.clips,
      transitions: transitions ?? this.transitions,
      canvasWidth: canvasWidth ?? this.canvasWidth,
      canvasHeight: canvasHeight ?? this.canvasHeight,
      fps: fps ?? this.fps,
      canvas: canvas ?? this.canvas,
      overlays: overlays ?? this.overlays,
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
          other.fps == fps &&
          other.canvas == canvas &&
          _listEqual(other.overlays, overlays);

  @override
  int get hashCode => Object.hash(
        id,
        Object.hashAll(clips),
        Object.hashAll(transitions),
        canvasWidth,
        canvasHeight,
        fps,
        canvas,
        Object.hashAll(overlays),
      );

  @override
  String toString() => 'VGEditorDraft('
      'id: $id, '
      'clips: ${clips.length}, '
      'transitions: ${transitions.length}, '
      'overlays: ${overlays.length}, '
      'canvas: $canvasWidth\u00d7$canvasHeight'
      '${canvas != null ? " (VGCanvasDescriptor)" : ""}, '
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
