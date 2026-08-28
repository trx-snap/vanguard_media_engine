// vg_clip_descriptor.dart
// Vanguard Media Engine — Phase 7 Stage 7.1 / Phase 7.11 / Phase 7.16 / Phase 7.17 / Phase 7.19B / Phase 7.x-Q1 / Phase 7.22A / Phase 7.23 / Phase 10
//
// Non-destructive clip descriptor for the UMF V2 timeline editor.
//
// Design rules (DEC-V2-026 / Phase 7):
//   - This is a pure Dart value type describing clip metadata.
//   - It does NOT mutate, transcode, or re-encode any source media file.
//   - The source file at [sourcePath] remains immutable at all times.
//   - This descriptor is consumed by VGEditorGraphFactory (Stage 7.4) and
//     ultimately by VGTimelineCompositorNode (Stage 7.5) on the native side.
//   - In Stage 7.1 there is no native rendering of these values. The descriptor
//     is used only for Dart-layer timeline math and playground validation.
//
// Phase 7.11 addition (DEC-144):
//   - Optional [transform] field of type [VGClipTransformDescriptor].
//   - Null means identity (no transform applied by the compositor).
//   - Serialised in toMap() under key 'transform' only when non-null.
//
// Phase 7.16 addition (DEC-148):
//   - [fitMode]: VGStillImageFitMode — how a still image is scaled to fill the
//     canvas. Defaults to [VGStillImageFitMode.fit]. Applies ONLY to clips with
//     [VGMediaKind.image]; video fit/fill is Phase 8 canvas scope.
//   - [cropRect]: Optional normalized [x, y, width, height] in [0.0, 1.0].
//     Applied at decode time (baked into the static buffer cache). Null = no crop.
//   - Both fields are omitted from toMap() when default/null.
//   - Do NOT add these fields to VGClipTransformDescriptor.
//
// Phase 7.17 addition (DEC-150):
//   - [freezePTS]: Optional source-local PTS (in seconds) for video-derived
//     freeze frame extraction. When non-null the compositor extracts a single
//     frame from the video asset at [sourcePath] using AVAssetImageGenerator
//     at the specified source-local time and caches it as a static buffer.
//   - Descriptor-level validation: must be non-negative. The caller
//     (VGEditorDraft.freezeClip) is responsible for ensuring the value lies
//     within the original clip's active trim window at split time.
//   - Applies ONLY to [VGMediaKind.video] clips created by freezeClip().
//   - Omitted from toMap() when null.
//
// Phase 7.19B addition (DEC-154):
//   - [isReversed]: bool — when true the compositor plays this video clip
//     in reverse (temporal reversal via AVAssetImageGenerator). Defaults to
//     false. Applies ONLY to [VGMediaKind.video] clips with a null [freezePTS].
//     Still-image and freeze-frame clips cannot be reversed (native constraint).
//
// Phase 7.x-Q1 addition:
//   - [dualCamera]: optional VGDualCameraDescriptor — when non-null this clip
//     is a dual-camera composite. The enclosing VGClipDescriptor is the
//     primary stream. The nested descriptor provides the secondary stream and
//     layout. Null means single-stream clip (no change to existing behavior).
//   - The production timeline wire key is 'dualCamera'. Its nested map is
//     produced by VGDualCameraDescriptor.toTimelineMap() which omits
//     primaryClip (since the enclosing descriptor IS the primary).
//   - Existing DEV routes that use VGDualCameraDescriptor.toMap() (which
//     includes primaryClip) are unaffected.
//
// Phase 7.22A addition:
//   - [timeRemap]: optional VGTimeRemapDescriptor — when non-null describes
//     variable-speed playback as an ordered list of VGSpeedSegmentDescriptor
//     values plus an audio policy.
//   - **Descriptor-only in Phase 7.22A.** The native compositor ignores this
//     field until Phase 7.22B+ implements PTS mapping.
//   - Wire key: 'timeRemap'. Omitted from toMap() when null.
//   - Backward-compatible: existing maps without 'timeRemap' produce null.
//   - The existing [speed] field remains unchanged and is NOT superseded in
//     this slice. Both coexist; the compositor continues to use [speed] only.
//
// Phase 7.23 addition (DEC-167):
//   - [transformTrack]: optional VGTransformTrackDescriptor — when non-null
//     describes keyframed transform/opacity animation via an ordered list of
//     VGTransformKeyframeDescriptor values and a declared interpolation mode.
//   - **Descriptor-only in Phase 7.23.** The native compositor ignores this
//     field until Phase 7.23B runtime integration is implemented.
//   - Wire key: 'transformTrack'. Omitted from toMap() when null.
//   - Backward-compatible: existing maps without 'transformTrack' produce null.
//   - Precedence rule (DEC-167): When transformTrack is non-null, runtime
//     rendering uses it INSTEAD of the static [transform] field. The two are
//     NOT composed. Static transform remains stored as a fallback if
//     transformTrack is absent or later cleared. Runtime integration: 7.23B.
//
// Phase 10 addition:
//   - [colorMatrix]: optional 20-element List<double> — row-major 4×5 color
//     matrix applied to every decoded video frame by the native compositor.
//     Format matches Flutter's ColorFilter.matrix convention.
//     Null means no color filter. Must be exactly 20 elements when non-null.
//   - Wire key: 'colorMatrix'. Omitted from toMap() when null.
//   - Backward-compatible: existing maps without 'colorMatrix' produce null.
//
// Phase 5-Unit O addition:
//   - [sourceRoiSidecarPath]: optional String — the local path to this clip's
//     source capture-time ROI sidecar (`.roi.json`), when one exists.
//   - This is Dart-owned metadata only. It is never read by the native
//     compositor and never mutates the source media at [sourcePath]. Native
//     consumers of a serialized clip map MUST ignore this key.
//   - It exists purely so the Dart-side export-time ROI post-processing
//     (`VGRoiExportSidecarPostProcessor`) can resolve each clip's own source
//     sidecar explicitly, instead of deriving it from [sourcePath].
//   - Wire key: 'sourceRoiSidecarPath'. Omitted from toMap() when null or
//     empty. Backward-compatible: existing maps without this key, or with a
//     non-String/empty value, produce null.
//
// Serialisation:
//   toMap() produces a JSON-compatible map:
//   {
//     'id': String,
//     'sourcePath': String,
//     'mediaKind': String,        // 'video' | 'audio' | 'image' | 'unknown'
//     'startTimeSeconds': double,
//     'durationSeconds': double,
//     'trimStartSeconds': double,
//     'trimEndSeconds': double,
//     'speed': double,
//     'transform': Map?,          // Phase 7.11: optional, omitted when null
//     'fitMode': String?,         // Phase 7.16: omitted when 'fit' (default)
//     'cropRect': List<double>?,  // Phase 7.16: omitted when null
//     'freezePTS': double?,       // Phase 7.17: omitted when null
//     'isReversed': bool?,        // Phase 7.19B: omitted when false (default)
//     'dualCamera': Map?,         // Phase 7.x-Q1: omitted when null; secondary-only wire payload
//     'timeRemap': Map?,          // Phase 7.22A: omitted when null; descriptor-only in 7.22A
//     'transformTrack': Map?,     // Phase 7.23: omitted when null; descriptor-only in 7.23
//     'colorMatrix': List<double>?,// Phase 10: omitted when null; 20-element 4×5 color matrix
//   }

import 'vg_clip_transform_descriptor.dart';
import 'vg_dual_camera_descriptor.dart';
import 'vg_time_remap_descriptor.dart';
import 'vg_transform_keyframe_descriptor.dart';

// ── VGStillImageFitMode ──────────────────────────────────────────────────────

/// How a still-image clip is scaled to fill the compositor canvas.
///
/// Applied at decode time — baked into the static buffer cache (DEC-148).
/// This applies **only** to [VGMediaKind.image] clips in Phase 7.16.
/// Video fit/fill belongs to the Phase 8 canvas system.
///
/// Wire values match the native `VGStillImageFitMode` enum in `VGClipDescriptor.h`.
enum VGStillImageFitMode {
  /// Scale image proportionally to fit within the canvas. Black bars
  /// (letterbox / pillarbox) appear when the image and canvas aspect ratios differ.
  /// This is the default.
  fit('fit'),

  /// Scale image proportionally to fill the canvas completely. The image is
  /// centered; excess pixels are cropped by the canvas bounds. No black bars.
  fill('fill');

  const VGStillImageFitMode(this.value);

  /// The wire-format string value as sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding [VGStillImageFitMode].
  ///
  /// Returns [VGStillImageFitMode.fit] for unrecognised strings (safe default).
  static VGStillImageFitMode fromValue(String value) {
    return VGStillImageFitMode.values.firstWhere(
      (mode) => mode.value == value,
      orElse: () => VGStillImageFitMode.fit,
    );
  }
}

/// A transport-safe, non-destructive description of a single media clip in a
/// Phase 7 timeline arrangement.
///
/// [VGClipDescriptor] is a pure value type. It holds timeline metadata only.
/// It **never** mutates the source file at [sourcePath]. The source media
/// remains immutable; all edits exist exclusively in this descriptor.
///
/// Consumed (Stage 7.4+) by `VGEditorGraphFactory` to build a
/// `VGGraphDescriptor` topology for `VGTimelineCompositorNode`.
///
/// ```dart
/// final clip = VGClipDescriptor(
///   id: 'clip-01',
///   sourcePath: '/tmp/recording.mp4',
///   mediaKind: VGMediaKind.video,
///   startTimeSeconds: 0.0,
///   durationSeconds: 10.0,
///   trimStartSeconds: 1.0,
///   trimEndSeconds: 8.5,
/// );
/// print(clip.trimDuration); // 7.5
/// ```
final class VGClipDescriptor {
  /// Creates a non-destructive clip descriptor.
  ///
  /// [id] is a stable, caller-supplied identifier for this clip within a
  /// timeline arrangement. Should be unique within one timeline.
  ///
  /// [sourcePath] is the absolute local path to the source media file.
  /// The file is **never** modified by this descriptor.
  ///
  /// [mediaKind] indicates the primary media stream type.
  ///
  /// [startTimeSeconds] is the position on the global timeline (in seconds)
  /// at which this clip begins playing. Must be >= 0.
  ///
  /// [durationSeconds] is the native/full duration of the source asset
  /// (before trimming) in seconds. Must be >= 0.
  ///
  /// [trimStartSeconds] is the start of the active trim window within the
  /// source, measured from the start of the source asset (not the timeline).
  /// Must be >= 0 and < [trimEndSeconds].
  ///
  /// [trimEndSeconds] is the end of the active trim window within the source.
  /// Must be > [trimStartSeconds] and <= [durationSeconds] when non-zero.
  ///
  /// [speed] is a speed multiplier applied to playback. 1.0 = normal speed.
  /// Must be > 0. Slow motion: 0 < speed < 1. Fast motion: speed > 1.
  ///
  /// [transform] is an optional static spatial transform applied to this clip
  /// by the compositor (Phase 7.11, DEC-144). Null means identity — the clip
  /// is rendered at full size with no transform applied (zero overhead).
  const VGClipDescriptor({
    required this.id,
    required this.sourcePath,
    this.mediaKind = VGMediaKind.video,
    this.startTimeSeconds = 0.0,
    required this.durationSeconds,
    this.trimStartSeconds = 0.0,
    required this.trimEndSeconds,
    this.speed = 1.0,
    this.transform,
    this.fitMode = VGStillImageFitMode.fit,
    this.cropRect,
    this.freezePTS,
    this.isReversed = false,
    this.dualCamera,
    this.timeRemap,
    this.transformTrack,
    this.colorMatrix,
    this.sourceRoiSidecarPath,
  }) : assert(startTimeSeconds >= 0, 'startTimeSeconds must be >= 0'),
       // Phase 10: colorMatrix must be exactly 20 elements when non-null.
       assert(
         colorMatrix == null || colorMatrix.length == 20,
         'colorMatrix must have exactly 20 elements (4×5 row-major matrix)',
       ),
       assert(durationSeconds >= 0, 'durationSeconds must be >= 0'),
       assert(trimStartSeconds >= 0, 'trimStartSeconds must be >= 0'),
       assert(
         trimEndSeconds > trimStartSeconds,
         'trimEndSeconds must be > trimStartSeconds',
       ),
       assert(speed > 0, 'speed must be > 0'),
       // Phase 7.16: cropRect validation.
       // When non-null: length == 4, all finite, all in [0.0, 1.0],
       // width > 0, height > 0, x + width <= 1.0, y + height <= 1.0.
       assert(
         cropRect == null || cropRect.length == 4,
         'cropRect must have exactly 4 elements [x, y, width, height]',
       ),
       assert(
         cropRect == null ||
             (cropRect[0] >= 0.0 &&
                 cropRect[0] <= 1.0 &&
                 cropRect[1] >= 0.0 &&
                 cropRect[1] <= 1.0 &&
                 cropRect[2] > 0.0 &&
                 cropRect[2] <= 1.0 &&
                 cropRect[3] > 0.0 &&
                 cropRect[3] <= 1.0),
         'cropRect values must be finite and in (0.0, 1.0]',
       ),
       assert(
         cropRect == null || cropRect[0] + cropRect[2] <= 1.0,
         'cropRect x + width must be <= 1.0',
       ),
       assert(
         cropRect == null || cropRect[1] + cropRect[3] <= 1.0,
         'cropRect y + height must be <= 1.0',
       ),
       // Phase 7.17: freezePTS validation.
       // When non-null: must be non-negative and finite.
       // Descriptor-level check only; VGEditorDraft.freezeClip() ensures the
       // value lies within the original clip's active trim window at split time.
       assert(
         freezePTS == null || (freezePTS >= 0.0),
         'freezePTS must be non-negative (source-local PTS for frame extraction)',
       );

  // ── Identity ───────────────────────────────────────────────────────────────

  /// Stable identifier for this clip within a timeline arrangement.
  ///
  /// Must be unique within one timeline. Callers may use UUIDs, sequential
  /// integers cast to strings, or descriptive keys.
  final String id;

  // ── Source ─────────────────────────────────────────────────────────────────

  /// Absolute local path to the source media asset.
  ///
  /// The file at this path is **never modified** by this descriptor or the
  /// timeline compositor. All editing is non-destructive; changes exist only
  /// in this descriptor until a final export pass renders the output.
  final String sourcePath;

  /// The primary media stream type of the source asset.
  final VGMediaKind mediaKind;

  // ── Timeline placement ────────────────────────────────────────────────────

  /// Position on the global timeline (in seconds) at which this clip starts.
  ///
  /// Multiple clips may be placed consecutively or with gaps. The timeline
  /// compositor maps global playhead PTS to the correct clip-local PTS using
  /// this value together with [trimStartSeconds] and [speed].
  final double startTimeSeconds;

  // ── Source asset geometry ─────────────────────────────────────────────────

  /// Full native duration of the source asset in seconds (before any trim).
  ///
  /// Use `VanguardEngine.probeVideoDuration` to populate this field.
  /// A value of 0.0 is permitted for unknown-duration assets (e.g. streaming
  /// sources) but will result in no-op trim clamping.
  final double durationSeconds;

  // ── Trim window ───────────────────────────────────────────────────────────

  /// Start of the active trim window within the source asset, in seconds.
  ///
  /// Measured from the beginning of the source file (not the global timeline).
  /// The compositor begins decoding from this offset. Must be >= 0.
  final double trimStartSeconds;

  /// End of the active trim window within the source asset, in seconds.
  ///
  /// Measured from the beginning of the source file (not the global timeline).
  /// The compositor stops decoding at this offset. Must be > [trimStartSeconds].
  final double trimEndSeconds;

  // ── Speed ──────────────────────────────────────────────────────────────────

  /// Playback speed multiplier. 1.0 = normal speed.
  ///
  /// - 0 < speed < 1: slow motion (e.g. 0.25 = 4× slow motion)
  /// - speed = 1: real-time
  /// - speed > 1: fast forward (e.g. 2.0 = 2× speed)
  ///
  /// Audio behaviour under non-1.0 speeds is governed by [VGTimeRemapAudioPolicy]
  /// (Phase 7 Stage 7.5+). In Stage 7.1 this field is stored but not rendered.
  final double speed;

  // ── Spatial transform (Phase 7.11) ────────────────────────────────────────

  /// Optional static spatial transform applied to this clip by the compositor.
  ///
  /// When null, the clip renders at full size with no transform applied.
  /// The native compositor skips the CoreImage filter chain entirely for
  /// null transforms (identity optimisation, zero overhead).
  ///
  /// When non-null, [VGClipTransformDescriptor.isIdentity] is also checked
  /// natively — a descriptor with all default field values is treated as
  /// identity and skipped.
  ///
  /// **Phase 7.11 / DEC-144**: Keyframed transforms and multi-layer overlay
  /// are deferred to later phases. Crop and fit/fill are Phase 7.16 (see below).
  ///
  /// **NOTE**: Do NOT add fitMode or cropRect to this class. Those fields live
  /// on [VGClipDescriptor] directly (DEC-148).
  final VGClipTransformDescriptor? transform;

  // ── Still-image fit/fill and crop (Phase 7.16) ────────────────────────────

  /// How this still-image clip is scaled to fill the compositor canvas.
  ///
  /// **Phase 7.16 / DEC-148** — applies ONLY to [VGMediaKind.image] clips.
  /// For video clips, fit/fill is the Phase 8 canvas system's responsibility.
  ///
  /// The native compositor bakes fit/fill at decode time into the static
  /// pixel buffer cache. Changing this field requires a reader/draft rebuild.
  ///
  /// Default: [VGStillImageFitMode.fit] (letterbox/pillarbox with black bars).
  final VGStillImageFitMode fitMode;

  /// Normalized crop rectangle for this still-image clip.
  ///
  /// Format: `[x, y, width, height]`, all in `[0.0, 1.0]`.
  /// Constraints: `width > 0`, `height > 0`, `x + width ≤ 1.0`, `y + height ≤ 1.0`.
  ///
  /// **Phase 7.16 / DEC-148** — applied ONLY to [VGMediaKind.image] clips at
  /// decode time, BEFORE fit/fill scaling (crop-then-fit order).
  ///
  /// Null means no crop — the full image is used as the source region.
  ///
  /// When both [cropRect] and `fitMode == fill` are set, the cropped region
  /// is scaled to fill the canvas; if the crop aspect ratio differs from the
  /// canvas, fill may crop additional edges (see RR-152).
  final List<double>? cropRect;

  // ── Freeze frame (Phase 7.17) ──────────────────────────────────────────────

  /// Source-local PTS (in seconds) for video-derived freeze frame extraction.
  ///
  /// **Phase 7.17 / DEC-150** — when non-null, this clip is a freeze-frame
  /// clip. The native compositor extracts a single frame from the video asset
  /// at [sourcePath] using `AVAssetImageGenerator` at this source-local time
  /// on the first pull, and caches it as a static buffer thereafter.
  ///
  /// Design notes:
  /// - Applies ONLY to [VGMediaKind.video] clips created by
  ///   [VGEditorDraft.freezeClip]. Setting on image clips has no effect.
  /// - `freezePTS` references the **original source video's** coordinate space,
  ///   not the freeze clip's own trim window. The freeze clip's trim fields
  ///   ([trimStartSeconds] = 0, [trimEndSeconds] = hold duration) describe
  ///   how long the frame is held on the timeline.
  /// - Descriptor-level validation: must be non-negative. [VGEditorDraft.freezeClip]
  ///   ensures the value lies within the original clip's active trim window.
  /// - Audio is implicitly silent for freeze clips in Phase 7.17 (no timeline
  ///   audio pipeline exists). Future audio sidecar work should treat
  ///   `freezePTS != null` as a mute/suppress-audio signal.
  ///
  /// Null means this is a normal video or image clip (no freeze behavior).
  final double? freezePTS;

  // ── Reverse playback (Phase 7.19B) ────────────────────────────────────────

  /// Whether this clip plays in reverse (temporal reversal).
  ///
  /// **Phase 7.19B / DEC-154** — when true the native compositor reads video
  /// frames in reverse order using `AVAssetImageGenerator` per-frame extraction
  /// (the same path as freeze-frame extraction).
  ///
  /// Design notes:
  /// - Applies ONLY to [VGMediaKind.video] clips with a null [freezePTS].
  ///   Still-image and freeze-frame clips cannot be reversed — this is enforced
  ///   by [VGEditorDraft.reverseClip] at mutation time.
  /// - Audio is out of scope for Phase 7.19. Reverse clips render silent until
  ///   the Phase 8 audio sidecar.
  /// - When false (default) the compositor uses the standard forward `AVAssetReader`
  ///   path — zero overhead.
  ///
  /// Omitted from [toMap] when false to keep wire payloads minimal.
  final bool isReversed;

  // ── Dual-camera descriptor (Phase 7.x-Q1) ─────────────────────────────────

  /// Optional dual-camera descriptor for production timeline integration.
  ///
  /// **Phase 7.x-Q1** — when non-null, this clip is a dual-camera composite.
  /// The enclosing [VGClipDescriptor] is the **primary stream**. The nested
  /// [VGDualCameraDescriptor] provides the secondary stream and layout.
  ///
  /// Design notes:
  /// - Null means single-stream clip; no change to any existing behavior.
  /// - The production timeline wire format uses [toMap] which serializes
  ///   [dualCamera] via [VGDualCameraDescriptor.toTimelineMap], omitting
  ///   `primaryClip` (the enclosing descriptor IS the primary).
  /// - Existing DEV routes use [VGDualCameraDescriptor.toMap] directly and
  ///   are not affected by this field.
  /// - [VGTimelineCompositorNode] detects the nested 'dualCamera' key and
  ///   stores it for future Q2 secondary-reader integration. In Q1, primary
  ///   clip renders exactly as a normal single clip when dualCamera is present.
  final VGDualCameraDescriptor? dualCamera;

  // ── Time remap descriptor (Phase 7.22A) ──────────────────────────────────

  /// Optional variable-speed time remap descriptor.
  ///
  /// **Phase 7.22A** — descriptor and serialization only. When non-null,
  /// this field describes piecewise variable-speed playback for this clip
  /// via an ordered list of [VGSpeedSegmentDescriptor] values.
  ///
  /// Design notes:
  /// - Null means no time remap; the existing [speed] field governs playback.
  /// - **The native compositor ignores this field in Phase 7.22A.** Actual
  ///   PTS mapping is implemented in a follow-up slice (Phase 7.22B+).
  /// - The existing [speed] field is NOT removed or superseded in this slice.
  /// - Wire key: 'timeRemap'. Omitted from [toMap] when null.
  /// - Backward-compatible: existing clip maps without 'timeRemap' produce null.
  final VGTimeRemapDescriptor? timeRemap;

  // ── Keyframe transform track (Phase 7.23) ────────────────────────────────

  /// Optional keyframed transform/opacity track for animated per-clip transforms.
  ///
  /// **Phase 7.23 / DEC-167** — descriptor and interpolation math only.
  /// When non-null, this field describes animated per-clip transform/opacity
  /// via an ordered list of [VGTransformKeyframeDescriptor] values.
  ///
  /// Design notes:
  /// - Null means no keyframe animation; [transform] (static) governs rendering.
  /// - **The native compositor ignores this field in Phase 7.23.** Runtime
  ///   integration is Phase 7.23B.
  /// - **Precedence rule (DEC-167)**: When [transformTrack] is non-null,
  ///   runtime rendering uses it INSTEAD of the static [transform] field.
  ///   The two are NOT composed together. Static [transform] remains stored
  ///   as a fallback if [transformTrack] is absent or later cleared.
  /// - Wire key: 'transformTrack'. Omitted from [toMap] when null.
  /// - Backward-compatible: existing clip maps without 'transformTrack' produce null.
  final VGTransformTrackDescriptor? transformTrack;

  // ── Color matrix filter (Phase 10) ───────────────────────────────────────

  /// Optional 4×5 row-major color matrix applied to every decoded video frame.
  ///
  /// **Phase 10** — when non-null, the native `VGTimelineCompositorNode` applies
  /// this color matrix to each decoded `CVPixelBufferRef` before compositing.
  ///
  /// Format matches Flutter's `ColorFilter.matrix` convention:
  /// ```
  ///   [r0, r1, r2, r3, r4,    // R_out = r0*R + r1*G + r2*B + r3*A + r4/255
  ///    g0, g1, g2, g3, g4,    // G_out = ...
  ///    b0, b1, b2, b3, b4,    // B_out = ...
  ///    a0, a1, a2, a3, a4]    // A_out = ...
  /// ```
  ///
  /// Design notes:
  /// - Must be exactly 20 elements. Enforced by constructor assert.
  /// - Null means no color filter — clip renders with natural colors.
  /// - Applies ONLY to [VGMediaKind.video] clips in the normal forward/streaming
  ///   AVAssetReader path. Freeze-frame and reverse clips use the image-generator
  ///   path; color matrix is not applied there in Phase 10.
  /// - Wire key: 'colorMatrix'. Omitted from [toMap] when null.
  /// - Backward-compatible: existing clip maps without 'colorMatrix' produce null.
  final List<double>? colorMatrix;

  // ── Source ROI sidecar (Phase 5-Unit O) ──────────────────────────────────

  /// Local path to this clip's source capture-time ROI sidecar (`.roi.json`),
  /// when one exists.
  ///
  /// **Phase 5-Unit O** — pure Dart-owned metadata. It is never sent to, or
  /// interpreted by, the native compositor: native consumers of a serialized
  /// clip map MUST ignore this key. It does not mutate the source media at
  /// [sourcePath] in any way.
  ///
  /// Consumed exclusively by Dart-side export-time ROI post-processing
  /// (`VGRoiExportSidecarPostProcessor`) to resolve this clip's own source
  /// sidecar explicitly, instead of deriving a path from [sourcePath].
  ///
  /// Null means no known source sidecar for this clip.
  final String? sourceRoiSidecarPath;

  // ── Crop rect convenience accessors (Phase 7.16) ─────────────────────────

  /// The normalized X origin of the crop rectangle. Null when [cropRect] is null.

  double? get cropX => cropRect?[0];

  /// The normalized Y origin of the crop rectangle. Null when [cropRect] is null.
  double? get cropY => cropRect?[1];

  /// The normalized width of the crop rectangle. Null when [cropRect] is null.
  double? get cropWidth => cropRect?[2];

  /// The normalized height of the crop rectangle. Null when [cropRect] is null.
  double? get cropHeight => cropRect?[3];

  // ── Derived helpers ────────────────────────────────────────────────────────

  /// The active duration of this clip after trimming, in source-asset seconds.
  ///
  /// Equivalent to `trimEndSeconds - trimStartSeconds`.
  /// This is the unscaled duration; multiply by `1 / speed` to get wall-clock
  /// timeline contribution when speed != 1.0.
  double get trimDuration => trimEndSeconds - trimStartSeconds;

  /// The wall-clock duration this clip contributes to the global timeline.
  ///
  /// When [timeRemap] is present, the timeline duration is the sum of each
  /// segment's contribution: `sourceDuration / speedMultiplier`. This
  /// supersedes the scalar [speed] field for timeline duration purposes.
  ///
  /// When [timeRemap] is absent, preserves legacy behaviour:
  /// `trimDuration / speed`.
  ///
  /// Phase 7.22B (DEC-165): updated to account for [timeRemap].
  double get timelineDuration {
    final remap = timeRemap;
    if (remap != null) {
      return remap.segments.fold(
        0.0,
        (sum, seg) => sum + seg.sourceDuration / seg.speedMultiplier,
      );
    }
    return trimDuration / speed;
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialises this descriptor to a JSON-compatible map.
  ///
  /// All values are JSON primitives. The map can be sent over a Flutter
  /// MethodChannel, stored as JSON, or diffed against a running graph.
  ///
  /// Output shape:
  /// ```json
  /// {
  ///   "id": "clip-01",
  ///   "sourcePath": "/tmp/recording.mp4",
  ///   "mediaKind": "video",
  ///   "startTimeSeconds": 0.0,
  ///   "durationSeconds": 10.0,
  ///   "trimStartSeconds": 1.0,
  ///   "trimEndSeconds": 8.5,
  ///   "speed": 1.0
  /// }
  /// ```
  Map<String, Object?> toMap() {
    final m = <String, Object?>{
      'id': id,
      'sourcePath': sourcePath,
      'mediaKind': mediaKind.value,
      'startTimeSeconds': startTimeSeconds,
      'durationSeconds': durationSeconds,
      'trimStartSeconds': trimStartSeconds,
      'trimEndSeconds': trimEndSeconds,
      'speed': speed,
    };
    // Phase 7.11: include transform only when non-null (omit when identity
    // to keep wire payload minimal; native null-checks before parsing).
    if (transform != null) {
      m['transform'] = transform!.toMap();
    }
    // Phase 7.16: omit fitMode when default ('fit'); omit cropRect when null.
    if (fitMode != VGStillImageFitMode.fit) {
      m['fitMode'] = fitMode.value;
    }
    if (cropRect != null) {
      m['cropRect'] = cropRect!;
    }
    // Phase 7.17: omit freezePTS when null.
    if (freezePTS != null) {
      m['freezePTS'] = freezePTS!;
    }
    // Phase 7.19B: omit isReversed when false (default); include only when true.
    if (isReversed) {
      m['isReversed'] = true;
    }
    // Phase 7.x-Q1: include dualCamera as secondary-only timeline payload.
    // Uses toTimelineMap() which omits primaryClip (the enclosing descriptor
    // IS the primary — duplicating it would create field drift risk).
    if (dualCamera != null) {
      m['dualCamera'] = dualCamera!.toTimelineMap();
    }
    // Phase 7.22A: include timeRemap when non-null (descriptor-only; compositor
    // ignores this field until Phase 7.22B+ PTS mapping is implemented).
    if (timeRemap != null) {
      m['timeRemap'] = timeRemap!.toMap();
    }
    // Phase 7.23: include transformTrack when non-null (descriptor-only;
    // compositor ignores this field until Phase 7.23B runtime integration).
    if (transformTrack != null) {
      m['transformTrack'] = transformTrack!.toMap();
    }
    // Phase 10: include colorMatrix when non-null. The native compositor applies
    // this 4×5 color matrix to each decoded video frame during timeline export.
    if (colorMatrix != null) {
      m['colorMatrix'] = colorMatrix!;
    }
    // Phase 5-Unit O: Dart-owned metadata only. Native consumers must ignore
    // this key. Omitted when null or empty.
    if (sourceRoiSidecarPath != null && sourceRoiSidecarPath!.isNotEmpty) {
      m['sourceRoiSidecarPath'] = sourceRoiSidecarPath!;
    }
    return m;
  }

  /// Deserialises a [VGClipDescriptor] from a map produced by [toMap].
  ///
  /// Returns `null` if any required field is missing or has the wrong type.
  /// Returns `null` if the optional `transform` field is present but invalid.
  static VGClipDescriptor? fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final sourcePath = map['sourcePath'];
    final mediaKindStr = map['mediaKind'] as String? ?? 'video';
    final startTime = (map['startTimeSeconds'] as num?)?.toDouble();
    final duration = (map['durationSeconds'] as num?)?.toDouble();
    final trimStart = (map['trimStartSeconds'] as num?)?.toDouble();
    final trimEnd = (map['trimEndSeconds'] as num?)?.toDouble();
    final speed = (map['speed'] as num?)?.toDouble();

    if (id == null ||
        sourcePath == null ||
        startTime == null ||
        duration == null ||
        trimStart == null ||
        trimEnd == null ||
        speed == null) {
      return null;
    }
    if (trimEnd <= trimStart || speed <= 0 || startTime < 0 || duration < 0) {
      return null;
    }

    // Phase 7.11: parse optional transform. A present but invalid transform
    // (e.g. opacity out of range) causes fromMap to return null.
    VGClipTransformDescriptor? transform;
    final rawTransform = map['transform'];
    if (rawTransform != null) {
      if (rawTransform is! Map<Object?, Object?>) return null;
      transform = VGClipTransformDescriptor.fromMap(rawTransform);
      if (transform == null) return null; // invalid transform payload
    }

    // Phase 7.16: parse fitMode (default fit). Unknown strings resolve to fit.
    final fitModeStr = map['fitMode'] as String?;
    final fitMode = fitModeStr != null
        ? VGStillImageFitMode.fromValue(fitModeStr)
        : VGStillImageFitMode.fit;

    // Phase 7.16: parse cropRect. When present, must be a list of 4 doubles
    // with valid normalized bounds. A malformed cropRect causes fromMap to
    // return null (mirrors the Dart assert constraints).
    List<double>? cropRect;
    final rawCropRect = map['cropRect'];
    if (rawCropRect != null) {
      if (rawCropRect is! List) return null;
      if (rawCropRect.length != 4) return null;
      final doubles = <double>[];
      for (final v in rawCropRect) {
        if (v is! num) return null;
        doubles.add(v.toDouble());
      }
      final x = doubles[0], y = doubles[1], w = doubles[2], h = doubles[3];
      // Validate: all in [0, 1], w > 0, h > 0, x+w <= 1, y+h <= 1.
      if (x < 0.0 || x > 1.0) return null;
      if (y < 0.0 || y > 1.0) return null;
      if (w <= 0.0 || w > 1.0) return null;
      if (h <= 0.0 || h > 1.0) return null;
      if (x + w > 1.0) return null;
      if (y + h > 1.0) return null;
      cropRect = doubles;
    }

    // Phase 7.17: parse optional freezePTS. When present must be a finite
    // non-negative number. A missing key means null (normal clip).
    double? freezePTS;
    final rawFreezePTS = map['freezePTS'];
    if (rawFreezePTS != null) {
      if (rawFreezePTS is! num) return null;
      final v = rawFreezePTS.toDouble();
      if (!v.isFinite || v < 0.0) return null;
      freezePTS = v;
    }

    // Phase 7.19B: parse optional isReversed. Missing key → false (default).
    final isReversed = (map['isReversed'] as bool?) ?? false;

    // Phase 7.x-Q1: parse optional dualCamera timeline payload.
    // The timeline wire format produced by toTimelineMap() does NOT include
    // a 'primaryClip' key. fromMap() reconstructs a VGDualCameraDescriptor
    // from the secondary-only payload by using the enclosing descriptor as
    // the primary. A malformed dualCamera sub-map causes fromMap to return null.
    VGDualCameraDescriptor? dualCamera;
    final rawDualCamera = map['dualCamera'];
    if (rawDualCamera != null) {
      if (rawDualCamera is! Map<Object?, Object?>) return null;
      // Build a synthetic primary from the fields parsed so far.
      // We need a provisional primary to satisfy VGDualCameraDescriptor's
      // constructor. The actual primary is the enclosing descriptor itself.
      final provisionalPrimary = VGClipDescriptor(
        id: id as String,
        sourcePath: sourcePath as String,
        mediaKind: VGMediaKind.fromValue(mediaKindStr),
        startTimeSeconds: startTime,
        durationSeconds: duration,
        trimStartSeconds: trimStart,
        trimEndSeconds: trimEnd,
        speed: speed,
        transform: transform,
        fitMode: fitMode,
        cropRect: cropRect,
        freezePTS: freezePTS,
        isReversed: isReversed,
      );
      dualCamera = VGDualCameraDescriptor.fromTimelineMap(
        rawDualCamera,
        primaryClip: provisionalPrimary,
      );
      if (dualCamera == null) return null; // malformed dual-camera payload
    }

    // Phase 7.22A: parse optional timeRemap.
    // Missing key means null (no time remap — uses [speed] only).
    // A present but malformed map causes fromMap to return null.
    VGTimeRemapDescriptor? timeRemap;
    final rawTimeRemap = map['timeRemap'];
    if (rawTimeRemap != null) {
      if (rawTimeRemap is! Map<Object?, Object?>) {
        if (rawTimeRemap is Map) {
          timeRemap = VGTimeRemapDescriptor.fromMap(
            rawTimeRemap.cast<Object?, Object?>(),
          );
        } else {
          return null;
        }
      } else {
        timeRemap = VGTimeRemapDescriptor.fromMap(rawTimeRemap);
      }
      if (timeRemap == null) return null; // malformed time remap payload
    }

    // Phase 7.23: parse optional transformTrack.
    // Missing key means null (no keyframe track — uses static [transform]).
    // A present but malformed map causes fromMap to return null.
    VGTransformTrackDescriptor? transformTrack;
    final rawTransformTrack = map['transformTrack'];
    if (rawTransformTrack != null) {
      if (rawTransformTrack is! Map<Object?, Object?>) {
        if (rawTransformTrack is Map) {
          transformTrack = VGTransformTrackDescriptor.fromMap(
            rawTransformTrack.cast<Object?, Object?>(),
          );
        } else {
          return null;
        }
      } else {
        transformTrack = VGTransformTrackDescriptor.fromMap(rawTransformTrack);
      }
      if (transformTrack == null) {
        return null; // malformed transform track payload
      }
    }

    // Phase 10: parse optional colorMatrix.
    // Missing key means null (no color filter — natural colors).
    // When present: must be a list of exactly 20 finite numbers.
    // A malformed or wrong-length colorMatrix causes fromMap to return null.
    List<double>? colorMatrix;
    final rawColorMatrix = map['colorMatrix'];
    if (rawColorMatrix != null) {
      if (rawColorMatrix is! List) return null;
      if (rawColorMatrix.length != 20) return null;
      final doubles = <double>[];
      for (final v in rawColorMatrix) {
        if (v is! num) return null;
        doubles.add(v.toDouble());
      }
      colorMatrix = doubles;
    }

    // Phase 5-Unit O: parse optional sourceRoiSidecarPath.
    // Only a non-empty String is accepted; any other type or an empty string
    // produces null (preserves old maps without this key as null).
    final rawSourceRoiSidecarPath = map['sourceRoiSidecarPath'];
    final sourceRoiSidecarPath =
        (rawSourceRoiSidecarPath is String &&
            rawSourceRoiSidecarPath.isNotEmpty)
        ? rawSourceRoiSidecarPath
        : null;

    return VGClipDescriptor(
      id: id as String,
      sourcePath: sourcePath as String,
      mediaKind: VGMediaKind.fromValue(mediaKindStr),
      startTimeSeconds: startTime,
      durationSeconds: duration,
      trimStartSeconds: trimStart,
      trimEndSeconds: trimEnd,
      speed: speed,
      transform: transform,
      fitMode: fitMode,
      cropRect: cropRect,
      freezePTS: freezePTS,
      isReversed: isReversed,
      dualCamera: dualCamera,
      timeRemap: timeRemap,
      transformTrack: transformTrack,
      colorMatrix: colorMatrix,
      sourceRoiSidecarPath: sourceRoiSidecarPath,
    );
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this descriptor with the specified fields replaced.
  ///
  /// Validation asserts are enforced on the new instance.
  VGClipDescriptor copyWith({
    String? id,
    String? sourcePath,
    VGMediaKind? mediaKind,
    double? startTimeSeconds,
    double? durationSeconds,
    double? trimStartSeconds,
    double? trimEndSeconds,
    double? speed,
    // Use sentinel to allow explicit null assignment (clear transform).
    Object? transform = _kClipNoValue,
    VGStillImageFitMode? fitMode,
    // Use sentinel to allow explicit null assignment (clear cropRect).
    Object? cropRect = _kClipNoValue,
    // Use sentinel to allow explicit null assignment (clear freezePTS).
    Object? freezePTS = _kClipNoValue,
    bool? isReversed,
    // Use sentinel to allow explicit null assignment (clear dualCamera).
    Object? dualCamera = _kClipNoValue,
    // Use sentinel to allow explicit null assignment (clear timeRemap).
    Object? timeRemap = _kClipNoValue,
    // Use sentinel to allow explicit null assignment (clear transformTrack).
    Object? transformTrack = _kClipNoValue,
    // Use sentinel to allow explicit null assignment (clear colorMatrix).
    Object? colorMatrix = _kClipNoValue,
    // Use sentinel to allow explicit null assignment (clear sourceRoiSidecarPath).
    Object? sourceRoiSidecarPath = _kClipNoValue,
  }) {
    return VGClipDescriptor(
      id: id ?? this.id,
      sourcePath: sourcePath ?? this.sourcePath,
      mediaKind: mediaKind ?? this.mediaKind,
      startTimeSeconds: startTimeSeconds ?? this.startTimeSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      trimStartSeconds: trimStartSeconds ?? this.trimStartSeconds,
      trimEndSeconds: trimEndSeconds ?? this.trimEndSeconds,
      speed: speed ?? this.speed,
      transform: transform == _kClipNoValue
          ? this.transform
          : transform as VGClipTransformDescriptor?,
      fitMode: fitMode ?? this.fitMode,
      cropRect: cropRect == _kClipNoValue
          ? this.cropRect
          : cropRect as List<double>?,
      freezePTS: freezePTS == _kClipNoValue
          ? this.freezePTS
          : freezePTS as double?,
      isReversed: isReversed ?? this.isReversed,
      dualCamera: dualCamera == _kClipNoValue
          ? this.dualCamera
          : dualCamera as VGDualCameraDescriptor?,
      timeRemap: timeRemap == _kClipNoValue
          ? this.timeRemap
          : timeRemap as VGTimeRemapDescriptor?,
      transformTrack: transformTrack == _kClipNoValue
          ? this.transformTrack
          : transformTrack as VGTransformTrackDescriptor?,
      colorMatrix: colorMatrix == _kClipNoValue
          ? this.colorMatrix
          : colorMatrix as List<double>?,
      sourceRoiSidecarPath: sourceRoiSidecarPath == _kClipNoValue
          ? this.sourceRoiSidecarPath
          : sourceRoiSidecarPath as String?,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGClipDescriptor &&
          other.id == id &&
          other.sourcePath == sourcePath &&
          other.mediaKind == mediaKind &&
          other.startTimeSeconds == startTimeSeconds &&
          other.durationSeconds == durationSeconds &&
          other.trimStartSeconds == trimStartSeconds &&
          other.trimEndSeconds == trimEndSeconds &&
          other.speed == speed &&
          other.transform == transform &&
          other.fitMode == fitMode &&
          _cropRectEqual(other.cropRect, cropRect) &&
          other.freezePTS == freezePTS &&
          other.isReversed == isReversed &&
          other.dualCamera == dualCamera &&
          other.timeRemap == timeRemap &&
          other.transformTrack == transformTrack &&
          _colorMatrixEqual(other.colorMatrix, colorMatrix) &&
          other.sourceRoiSidecarPath == sourceRoiSidecarPath;

  /// Deep-equality helper for the [cropRect] list field.
  static bool _cropRectEqual(List<double>? a, List<double>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Deep-equality helper for the [colorMatrix] list field.
  static bool _colorMatrixEqual(List<double>? a, List<double>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    sourcePath,
    mediaKind,
    startTimeSeconds,
    durationSeconds,
    trimStartSeconds,
    trimEndSeconds,
    speed,
    transform,
    fitMode,
    // Hash cropRect elements individually for stable hash.
    Object.hashAll(cropRect ?? const []),
    freezePTS,
    isReversed,
    dualCamera,
    timeRemap,
    transformTrack,
    // Hash colorMatrix elements individually for stable hash.
    Object.hashAll(colorMatrix ?? const []),
    sourceRoiSidecarPath,
  );

  @override
  String toString() =>
      'VGClipDescriptor('
      'id: $id, '
      'sourcePath: ${sourcePath.split('/').last}, '
      'kind: ${mediaKind.value}, '
      'start: ${startTimeSeconds}s, '
      'duration: ${durationSeconds}s, '
      'trim: [${trimStartSeconds}s → ${trimEndSeconds}s], '
      'speed: $speed×, '
      'transform: $transform, '
      'fitMode: ${fitMode.value}, '
      'cropRect: $cropRect, '
      'freezePTS: $freezePTS, '
      'isReversed: $isReversed, '
      'dualCamera: ${dualCamera != null ? "<present layoutMode=${dualCamera!.layoutMode.value}>" : null}, '
      'timeRemap: ${timeRemap != null ? "<present segments=${timeRemap!.segments.length}>" : null}, '
      'transformTrack: ${transformTrack != null ? "<present keyframes=${transformTrack!.keyframes.length} interp=${transformTrack!.interpolation.value}>" : null}, '
      'colorMatrix: ${colorMatrix != null ? "<present ${colorMatrix!.length} elements>" : null}, '
      'sourceRoiSidecarPath: $sourceRoiSidecarPath)';
}

// ── Sentinel for copyWith nullable fields ─────────────────────────────────────────

const _kClipNoValue = Object();

// ── VGMediaKind ──────────────────────────────────────────────────────────────────

/// The primary media stream type of a clip's source asset.
///
/// Used by [VGClipDescriptor.mediaKind] to communicate the expected content
/// type to the native graph factory.
enum VGMediaKind {
  /// A video asset (may contain an audio track).
  video('video'),

  /// An audio-only asset (no video track).
  audio('audio'),

  /// A still image asset (JPEG, PNG, HEIC, WebP).
  ///
  /// Corresponds to [VGStillImageClipDescriptor] in the Phase 7 roadmap.
  image('image'),

  /// Unknown or not yet probed.
  unknown('unknown');

  const VGMediaKind(this.value);

  /// The wire-format string value as sent over MethodChannel and in toMap().
  final String value;

  /// Resolves a wire-format string to the corresponding [VGMediaKind].
  ///
  /// Returns [VGMediaKind.unknown] for unrecognised strings.
  static VGMediaKind fromValue(String value) {
    for (final kind in VGMediaKind.values) {
      if (kind.value == value) return kind;
    }
    return VGMediaKind.unknown;
  }
}
