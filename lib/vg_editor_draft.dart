// vg_editor_draft.dart
// Vanguard Media Engine — Phase 7 Stage 7.7
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.7 — EDITOR DRAFT RECIPE
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGEditorDraft is the immutable, non-destructive composition recipe that
// describes a complete timeline editing session.
//
// Design rules (Phase 7.7 / Opus M4):
//   - Pure Dart value type. No rendering logic, no channel calls.
//   - The clips list is non-destructive: source files are never modified.
//   - Transitions are restricted to VGTransitionType.none (hard cuts) in this
//     slice. The descriptor schema supports other types; rejection is doc-only.
//   - All fields are validated at construction time via asserts.
//   - Clip IDs must be unique within one draft.
//   - Transition fromClipId / toClipId must reference clip IDs in the draft.
//
// Consumed by VGEditorController (Stage 7.7) to coordinate dev_ channel calls.
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
  /// Sum of [VGClipDescriptor.timelineDuration] for all clips.
  /// Accounts for each clip's [VGClipDescriptor.speed] multiplier.
  ///
  /// Note: transition overlaps (cross-dissolve, fade) would subtract the
  /// transition overlap window from this total, but in Phase 7.7 transitions
  /// are hard-cut only so no overlap subtraction is applied.
  double get durationSeconds =>
      clips.fold(0.0, (sum, c) => sum + c.timelineDuration);

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
