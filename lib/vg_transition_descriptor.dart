// vg_transition_descriptor.dart
// Vanguard Media Engine — Phase 7 Stage 7.1
//
// Non-destructive transition descriptor for the UMF V2 timeline editor.
//
// Design rules (DEC-V2-026 / DEC-V2-060 / Phase 7):
//   - This is a pure Dart value type describing the transition between two
//     adjacent clips in a timeline arrangement.
//   - It contains no rendering logic, Metal shaders, or graph node references.
//   - All transitions in Phase 7 execute inside VGTimelineCompositorNode
//     (Stage 7.5+), NOT as separate graph nodes. DEC-V2-060.
//   - Beat-synced transitions are deferred to Phase 13. DEC-V2-060.
//   - This descriptor is consumed by VGEditorGraphFactory (Stage 7.4) and
//     VGTimelineCompositorNode (Stage 7.5) on the native side.
//
// First-slice supported types (Stage 7.1):
//   - VGTransitionType.none    — hard cut (no transition)
//   - VGTransitionType.fade    — fade to/from black
//   - VGTransitionType.dissolve — cross-dissolve between clips
//
// Extended types (Phase 7 v2.7/v2.8, DEC-V2-060):
//   VGTransitionPresetDescriptor adds swipe, slide, zoom, wipe, glitch, mask.
//   Those are deferred to a later Stage 7 sub-phase.
//
// Serialisation:
//   toMap() produces a JSON-compatible map:
//   {
//     'id': String,
//     'type': String,            // 'none' | 'fade' | 'dissolve'
//     'durationSeconds': double,
//     'fromClipId': String?,
//     'toClipId': String?,
//     'curve': String,           // 'linear' | 'easeIn' | 'easeOut' | 'easeInOut'
//   }

/// A transport-safe, non-destructive description of the transition between two
/// adjacent clips in a Phase 7 timeline arrangement.
///
/// [VGTransitionDescriptor] is a pure value type. It holds transition metadata
/// only. Per **DEC-V2-060**, all transitions execute **inside**
/// `VGTimelineCompositorNode` during clip boundary windows — there is no
/// separate transition graph node.
///
/// In Stage 7.1 (descriptor-only), this object is validated and displayed in
/// the timeline playground. Native rendering is Stage 7.5+.
///
/// ```dart
/// final dissolve = VGTransitionDescriptor(
///   id: 'tr-01',
///   type: VGTransitionType.dissolve,
///   durationSeconds: 0.5,
///   fromClipId: 'clip-01',
///   toClipId: 'clip-02',
///   curve: VGTransitionCurve.easeInOut,
/// );
/// ```
final class VGTransitionDescriptor {
  /// Creates a non-destructive transition descriptor.
  ///
  /// [id] is a stable, caller-supplied identifier for this transition.
  ///
  /// [type] specifies the visual transition effect. Defaults to
  /// [VGTransitionType.dissolve]. In Stage 7.1 only `none`, `fade`, and
  /// `dissolve` are first-class. Additional types are described in Phase 7
  /// v2.7/v2.8 via [VGTransitionPresetDescriptor] (deferred).
  ///
  /// [durationSeconds] is the overlap window during which both clips are
  /// visible (for cross-dissolve) or the fade duration. Must be >= 0.
  /// A value of 0.0 with [type] == [VGTransitionType.none] is a hard cut.
  ///
  /// [fromClipId] and [toClipId] are optional references to the preceding
  /// and succeeding [VGClipDescriptor.id] values in the timeline. Nullable
  /// for Stage 7.1 playground use where the clip list is not yet linked.
  ///
  /// [curve] controls the timing curve of the blend. Defaults to
  /// [VGTransitionCurve.linear]. Only meaningful when [type] != `none`.
  const VGTransitionDescriptor({
    required this.id,
    this.type = VGTransitionType.dissolve,
    this.durationSeconds = 0.0,
    this.fromClipId,
    this.toClipId,
    this.curve = VGTransitionCurve.linear,
  }) : assert(durationSeconds >= 0, 'durationSeconds must be >= 0');

  // ── Identity ───────────────────────────────────────────────────────────────

  /// Stable identifier for this transition within a timeline arrangement.
  final String id;

  // ── Transition geometry ────────────────────────────────────────────────────

  /// The visual transition effect.
  ///
  /// Defaults to [VGTransitionType.dissolve]. In Stage 7.1 only `none`,
  /// `fade`, and `dissolve` are supported by the playground.
  final VGTransitionType type;

  /// Duration of the transition overlap window in seconds.
  ///
  /// For `dissolve`: both clips are blended for this many seconds during the
  /// boundary. For `fade`: the outgoing clip fades to black over half this
  /// duration, and the incoming clip fades in over the other half.
  /// For `none`: this value is ignored (hard cut occurs immediately).
  ///
  /// Must be >= 0. Typically 0.3–0.8 seconds.
  final double durationSeconds;

  // ── Clip linkage ───────────────────────────────────────────────────────────

  /// The [VGClipDescriptor.id] of the outgoing (preceding) clip, or null.
  ///
  /// Null is permitted in Stage 7.1 for standalone transition previews
  /// where the full clip list is not yet assembled. The native factory
  /// (Stage 7.4) requires both IDs to be non-null when building a graph.
  final String? fromClipId;

  /// The [VGClipDescriptor.id] of the incoming (succeeding) clip, or null.
  ///
  /// Null is permitted in Stage 7.1 for standalone transition previews.
  final String? toClipId;

  // ── Timing curve ───────────────────────────────────────────────────────────

  /// The easing curve applied to the blend alpha over [durationSeconds].
  ///
  /// Ignored when [type] == [VGTransitionType.none].
  final VGTransitionCurve curve;

  // ── Derived helpers ────────────────────────────────────────────────────────

  /// Whether this descriptor represents a hard cut (no visual transition).
  bool get isHardCut =>
      type == VGTransitionType.none || durationSeconds == 0.0;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this descriptor to a JSON-compatible map.
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "id": "tr-01",
  ///   "type": "dissolve",
  ///   "durationSeconds": 0.5,
  ///   "fromClipId": "clip-01",
  ///   "toClipId": "clip-02",
  ///   "curve": "easeInOut"
  /// }
  /// ```
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'type': type.value,
        'durationSeconds': durationSeconds,
        'fromClipId': fromClipId,
        'toClipId': toClipId,
        'curve': curve.value,
      };

  /// Deserialises a [VGTransitionDescriptor] from a map produced by [toMap].
  ///
  /// Returns `null` if required fields are missing or invalid.
  static VGTransitionDescriptor? fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final typeStr = map['type'] as String? ?? 'none';
    final duration = (map['durationSeconds'] as num?)?.toDouble();
    final curveStr = map['curve'] as String? ?? 'linear';

    if (id == null || duration == null || duration < 0) return null;

    return VGTransitionDescriptor(
      id: id as String,
      type: VGTransitionType.fromValue(typeStr),
      durationSeconds: duration,
      fromClipId: map['fromClipId'] as String?,
      toClipId: map['toClipId'] as String?,
      curve: VGTransitionCurve.fromValue(curveStr),
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this descriptor with the specified fields replaced.
  VGTransitionDescriptor copyWith({
    String? id,
    VGTransitionType? type,
    double? durationSeconds,
    // Use a sentinel to allow explicit null assignment for fromClipId/toClipId.
    Object? fromClipId = _kNoValue,
    Object? toClipId = _kNoValue,
    VGTransitionCurve? curve,
  }) {
    return VGTransitionDescriptor(
      id: id ?? this.id,
      type: type ?? this.type,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      fromClipId: fromClipId == _kNoValue
          ? this.fromClipId
          : fromClipId as String?,
      toClipId: toClipId == _kNoValue ? this.toClipId : toClipId as String?,
      curve: curve ?? this.curve,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGTransitionDescriptor &&
          other.id == id &&
          other.type == type &&
          other.durationSeconds == durationSeconds &&
          other.fromClipId == fromClipId &&
          other.toClipId == toClipId &&
          other.curve == curve;

  @override
  int get hashCode => Object.hash(
        id,
        type,
        durationSeconds,
        fromClipId,
        toClipId,
        curve,
      );

  @override
  String toString() => 'VGTransitionDescriptor('
      'id: $id, '
      'type: ${type.value}, '
      'duration: ${durationSeconds}s, '
      'from: $fromClipId → to: $toClipId, '
      'curve: ${curve.value})';
}

// ── Sentinel for copyWith nullable fields ────────────────────────────────────

const _kNoValue = Object();

// ── VGTransitionType ──────────────────────────────────────────────────────────

/// The visual transition type between two adjacent timeline clips.
///
/// Phase 7 Stage 7.1 first-slice types: [none], [fade], [dissolve].
/// Extended presets (swipe, slide, zoom, wipe, glitch, mask) are added via
/// [VGTransitionPresetDescriptor] in Phase 7 v2.7/v2.8 (deferred, DEC-V2-060).
enum VGTransitionType {
  /// Hard cut — no visual transition. Clips change instantaneously.
  none('none'),

  /// Fade to/from black. The outgoing clip fades to black; the incoming clip
  /// fades in from black.
  fade('fade'),

  /// Cross-dissolve — outgoing and incoming clips blend simultaneously over
  /// the transition window. The most common cinematic transition.
  dissolve('dissolve');

  const VGTransitionType(this.value);

  /// Wire-format string as sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding [VGTransitionType].
  ///
  /// Returns [VGTransitionType.none] for unrecognised strings.
  static VGTransitionType fromValue(String value) {
    for (final t in VGTransitionType.values) {
      if (t.value == value) return t;
    }
    return VGTransitionType.none;
  }
}

// ── VGTransitionCurve ─────────────────────────────────────────────────────────

/// The easing curve applied to the blend alpha of a [VGTransitionDescriptor].
///
/// Corresponds to [VGTransitionTimingCurve] on the native side (Phase 7
/// v2.7/v2.8, DEC-V2-060). In Stage 7.1 this is a descriptor-only field;
/// native curve evaluation is Stage 7.5+.
enum VGTransitionCurve {
  /// Constant blend rate — uniform alpha progression.
  linear('linear'),

  /// Starts slow, accelerates toward the end.
  easeIn('easeIn'),

  /// Starts fast, decelerates toward the end.
  easeOut('easeOut'),

  /// Slow start, fast middle, slow end.
  easeInOut('easeInOut');

  const VGTransitionCurve(this.value);

  /// Wire-format string as sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding [VGTransitionCurve].
  ///
  /// Returns [VGTransitionCurve.linear] for unrecognised strings.
  static VGTransitionCurve fromValue(String value) {
    for (final c in VGTransitionCurve.values) {
      if (c.value == value) return c;
    }
    return VGTransitionCurve.linear;
  }
}
