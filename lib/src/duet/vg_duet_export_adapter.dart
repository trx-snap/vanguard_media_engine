// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.
//
// Slice 1 defines a stable pure-Dart export-seam DTO only.
// Universal Editor export wiring is deferred to a later slice.
// This file does NOT claim that VGEditorDraft accepts a Duet composition
// node today, and does not depend on VGEditorDraft or VGClipDescriptor.

import '../../vg_overlay_descriptor.dart';
import 'vg_duet_composition_descriptor.dart';
import 'vg_duet_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DTO: VGDuetEditorCompositionNode
// ─────────────────────────────────────────────────────────────────────────────

/// Pure-Dart DTO representing the Duet composition seam for future Universal
/// Editor export integration.
///
/// This node is produced by [VGDuetExportAdapter] and will be consumed by the
/// Universal Editor export graph in a future wiring slice. Existing
/// [VGEditorDraft] and [VGClipDescriptor] are **not** modified in Slice 1.
class VGDuetEditorCompositionNode {
  /// Absolute local path of the source video file.
  final String sourceVideoPath;

  /// Active layout mode for this composition.
  final VGDuetLayoutMode layoutMode;

  /// Whether left/right columns are swapped from the default.
  final bool isSideSwapped;

  /// Whether top/bottom rows are swapped from the default.
  final bool isTopBottomSwapped;

  /// PiP anchor corner. Non-null only when [layoutMode] is
  /// [VGDuetLayoutMode.pip].
  final VGDuetPiPAnchor? pipAnchor;

  /// Normalized PiP rect (0.0–1.0). Non-null only when [layoutMode] is
  /// [VGDuetLayoutMode.pip].
  final VGDuetRect? pipNormalizedRect;

  /// Trim start in seconds.
  final double trimStartSeconds;

  /// Trim end in seconds.
  final double trimEndSeconds;

  /// Ordered local file paths of segment assets produced by the engine.
  final List<String> segmentAssets;

  /// Ordered recorded segments (timing, speed, PTS data).
  final List<VGDuetSegment> segments;

  /// Source video audio gain (0.0 – 1.0).
  final double sourceAudioGain;

  /// Microphone audio gain (0.0 – 1.0).
  final double micAudioGain;

  /// Whether source video audio is muted.
  final bool sourceAudioMuted;

  /// Whether microphone audio is muted.
  final bool micAudioMuted;

  /// Ordered, unmodifiable list of user creator overlays (text/emoji/sticker)
  /// to carry downstream of the composited Duet foreground on export.
  final List<VGOverlayDescriptor> overlays;

  /// Constructs a [VGDuetEditorCompositionNode].
  ///
  /// [segmentAssets], [segments], and [overlays] are defensively copied and
  /// made unmodifiable. [validate] is called immediately so invalid nodes can
  /// never be stored.
  VGDuetEditorCompositionNode({
    required this.sourceVideoPath,
    required this.layoutMode,
    required this.isSideSwapped,
    required this.isTopBottomSwapped,
    this.pipAnchor,
    this.pipNormalizedRect,
    required this.trimStartSeconds,
    required this.trimEndSeconds,
    required List<String> segmentAssets,
    required List<VGDuetSegment> segments,
    required this.sourceAudioGain,
    required this.micAudioGain,
    required this.sourceAudioMuted,
    required this.micAudioMuted,
    List<VGOverlayDescriptor> overlays = const [],
  }) : segmentAssets = List.unmodifiable(segmentAssets),
       segments = List.unmodifiable(segments),
       overlays = List.unmodifiable(overlays) {
    validate();
  }

  /// Validates this node's fields.
  ///
  /// Throws [ArgumentError] if any field is inconsistent.
  void validate() {
    if (sourceVideoPath.trim().isEmpty) {
      throw ArgumentError('sourceVideoPath must not be empty.');
    }
    if (trimEndSeconds <= trimStartSeconds) {
      throw ArgumentError(
        'trimEndSeconds ($trimEndSeconds) must be > '
        'trimStartSeconds ($trimStartSeconds).',
      );
    }
    if (sourceAudioGain < 0.0 || sourceAudioGain > 1.0) {
      throw ArgumentError.value(
        sourceAudioGain,
        'sourceAudioGain',
        'Must be in [0.0, 1.0].',
      );
    }
    if (micAudioGain < 0.0 || micAudioGain > 1.0) {
      throw ArgumentError.value(
        micAudioGain,
        'micAudioGain',
        'Must be in [0.0, 1.0].',
      );
    }
    if (layoutMode == VGDuetLayoutMode.pip && pipNormalizedRect != null) {
      final r = pipNormalizedRect!;
      if (r.left < 0.0 || r.top < 0.0 || r.width <= 0.0 || r.height <= 0.0) {
        throw ArgumentError(
          'VGDuetEditorCompositionNode: pipNormalizedRect has invalid values '
          '(left=${r.left}, top=${r.top}, w=${r.width}, h=${r.height}).',
        );
      }
      if (r.right > 1.0 || r.bottom > 1.0) {
        throw ArgumentError(
          'VGDuetEditorCompositionNode: pipNormalizedRect exceeds canvas bounds '
          '(right=${r.right}, bottom=${r.bottom}).',
        );
      }
    }
  }

  /// Serializes to a plain [Map] for method channel or JSON transport.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'sourceVideoPath': sourceVideoPath,
      'layoutMode': layoutMode.name,
      'isSideSwapped': isSideSwapped,
      'isTopBottomSwapped': isTopBottomSwapped,
      if (pipAnchor != null) 'pipAnchor': pipAnchor!.name,
      if (pipNormalizedRect != null)
        'pipNormalizedRect': pipNormalizedRect!.toMap(),
      'trimStartSeconds': trimStartSeconds,
      'trimEndSeconds': trimEndSeconds,
      'segmentAssets': List<String>.from(segmentAssets),
      'segments': segments.map((s) => s.toMap()).toList(),
      'sourceAudioGain': sourceAudioGain,
      'micAudioGain': micAudioGain,
      'sourceAudioMuted': sourceAudioMuted,
      'micAudioMuted': micAudioMuted,
      'overlays': overlays.map((o) => o.toMap()).toList(),
    };
  }

  /// Deserializes from a plain [Map].
  ///
  /// `overlays` is parsed defensively (never throws): a missing or
  /// non-[List] value degrades to an empty list; each list entry that is a
  /// [Map] is parsed through [VGOverlayDescriptor.fromMap] and a `null`
  /// parse result (or a non-[Map] entry) is silently skipped rather than
  /// failing the whole node.
  factory VGDuetEditorCompositionNode.fromMap(Map<String, dynamic> map) {
    final modeName = map['layoutMode'] as String? ?? 'pip';
    final layoutMode = VGDuetLayoutMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => VGDuetLayoutMode.pip,
    );
    VGDuetPiPAnchor? pipAnchor;
    final anchorName = map['pipAnchor'] as String?;
    if (anchorName != null) {
      pipAnchor = VGDuetPiPAnchor.values.firstWhere(
        (e) => e.name == anchorName,
        orElse: () => VGDuetPiPAnchor.topRight,
      );
    }
    VGDuetRect? pipRect;
    final rectMap = map['pipNormalizedRect'];
    if (rectMap is Map) {
      pipRect = VGDuetRect.fromMap(Map<String, dynamic>.from(rectMap));
    }
    final segmentsList =
        (map['segments'] as List<dynamic>?)
            ?.map(
              (e) => VGDuetSegment.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList() ??
        [];
    final assetsList =
        (map['segmentAssets'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        [];
    final overlaysList = <VGOverlayDescriptor>[];
    final rawOverlays = map['overlays'];
    if (rawOverlays is List) {
      for (final entry in rawOverlays) {
        if (entry is Map) {
          final parsed = VGOverlayDescriptor.fromMap(
            Map<Object?, Object?>.from(entry),
          );
          if (parsed != null) overlaysList.add(parsed);
        }
      }
    }
    return VGDuetEditorCompositionNode(
      sourceVideoPath: map['sourceVideoPath'] as String? ?? '',
      layoutMode: layoutMode,
      isSideSwapped: map['isSideSwapped'] as bool? ?? false,
      isTopBottomSwapped: map['isTopBottomSwapped'] as bool? ?? false,
      pipAnchor: pipAnchor,
      pipNormalizedRect: pipRect,
      trimStartSeconds: (map['trimStartSeconds'] as num).toDouble(),
      trimEndSeconds: (map['trimEndSeconds'] as num).toDouble(),
      segmentAssets: assetsList,
      segments: segmentsList,
      sourceAudioGain: (map['sourceAudioGain'] as num?)?.toDouble() ?? 1.0,
      micAudioGain: (map['micAudioGain'] as num?)?.toDouble() ?? 1.0,
      sourceAudioMuted: map['sourceAudioMuted'] as bool? ?? false,
      micAudioMuted: map['micAudioMuted'] as bool? ?? false,
      overlays: overlaysList,
    );
  }

  @override
  String toString() =>
      'VGDuetEditorCompositionNode(layout: ${layoutMode.name}, '
      'segments: ${segments.length})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Adapter: VGDuetExportAdapter
// ─────────────────────────────────────────────────────────────────────────────

/// Stateless converter that transforms a [VGDuetCompositionDescriptor] and
/// optional segment asset paths into a [VGDuetEditorCompositionNode] DTO /
/// serialized export-seam payload.
///
/// Acts as the adapter seam for future Universal Editor export integration.
/// Does **not** require or claim that [VGEditorDraft] accepts a Duet
/// composition node today. Existing editor/export files are untouched.
abstract final class VGDuetExportAdapter {
  VGDuetExportAdapter._();

  /// Converts [descriptor] and optional [segmentAssets] into a
  /// [VGDuetEditorCompositionNode] DTO.
  ///
  /// [segmentAssets] should be the ordered list of segment file paths produced
  /// by the engine. Pass `null` or `[]` before capture completes (e.g. during
  /// descriptor-only round-trip tests).
  static VGDuetEditorCompositionNode buildCompositionNode({
    required VGDuetCompositionDescriptor descriptor,
    List<String>? segmentAssets,
  }) {
    return VGDuetEditorCompositionNode(
      sourceVideoPath: descriptor.source.filePath,
      layoutMode: descriptor.layoutConfig.mode,
      isSideSwapped: descriptor.layoutConfig.isSideSwapped,
      isTopBottomSwapped: descriptor.layoutConfig.isTopBottomSwapped,
      pipAnchor: descriptor.layoutConfig.pipAnchor,
      pipNormalizedRect: descriptor.layoutConfig.pipNormalizedRect,
      trimStartSeconds: descriptor.trimWindow.startSeconds,
      trimEndSeconds: descriptor.trimWindow.endSeconds,
      segmentAssets: List.unmodifiable(segmentAssets ?? const []),
      segments: List.unmodifiable(descriptor.segments),
      sourceAudioGain: descriptor.sourceAudioGain,
      micAudioGain: descriptor.micAudioGain,
      sourceAudioMuted: descriptor.sourceAudioMuted,
      micAudioMuted: descriptor.micAudioMuted,
      overlays: List.unmodifiable(descriptor.overlays),
    );
  }

  /// Converts [descriptor] and optional [segmentAssets] directly into the
  /// serialized export payload [Map].
  ///
  /// Equivalent to calling [buildCompositionNode] then [toMap], but
  /// provided for convenience at call sites that only need the map form.
  static Map<String, dynamic> toExportPayload({
    required VGDuetCompositionDescriptor descriptor,
    List<String>? segmentAssets,
  }) {
    return buildCompositionNode(
      descriptor: descriptor,
      segmentAssets: segmentAssets,
    ).toMap();
  }
}
