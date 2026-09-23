// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.

import '../../vg_overlay_descriptor.dart';
import 'vg_duet_source.dart';
import 'vg_duet_models.dart';

/// Immutable composition descriptor capturing every parameter needed to
/// reproduce a Duet recording session.
///
/// Created at the end of a capture session and forwarded to the
/// [VGDuetExportAdapter] for Universal Editor export integration.
///
/// Does **not** depend on [VGEditorDraft], [VGClipDescriptor], MultiCam,
/// or any current Universal Editor internals.
class VGDuetCompositionDescriptor {
  /// The validated local video source used for this session.
  final VGDuetSource source;

  /// The active layout configuration at the end of recording.
  final VGDuetLayoutConfig layoutConfig;

  /// The trim window applied to the source video.
  final VGDuetTrimWindow trimWindow;

  /// The initial/default recording speed multiplier (0.3, 0.5, 1.0, 2.0, 3.0).
  final double initialSpeed;

  /// Ordered, unmodifiable list of recorded segments.
  final List<VGDuetSegment> segments;

  /// Source video audio gain (0.0 – 1.0).
  final double sourceAudioGain;

  /// Microphone audio gain (0.0 – 1.0).
  final double micAudioGain;

  /// Whether the source video audio track is muted.
  final bool sourceAudioMuted;

  /// Whether the microphone audio track is muted.
  final bool micAudioMuted;

  /// Ordered, unmodifiable list of user creator overlays (text/emoji/sticker)
  /// to carry downstream of the composited Duet foreground on export.
  final List<VGOverlayDescriptor> overlays;

  /// Constructs an immutable [VGDuetCompositionDescriptor].
  ///
  /// The [segments] and [overlays] lists are defensively copied and made
  /// unmodifiable so that mutation of the caller's list after construction
  /// cannot affect this object.
  VGDuetCompositionDescriptor({
    required this.source,
    required this.layoutConfig,
    required this.trimWindow,
    required this.initialSpeed,
    required List<VGDuetSegment> segments,
    this.sourceAudioGain = 1.0,
    this.micAudioGain = 1.0,
    this.sourceAudioMuted = false,
    this.micAudioMuted = false,
    List<VGOverlayDescriptor> overlays = const [],
  }) : segments = List.unmodifiable(segments),
       overlays = List.unmodifiable(overlays) {
    _validateSpeed(initialSpeed);
    _validateGain(sourceAudioGain, 'sourceAudioGain');
    _validateGain(micAudioGain, 'micAudioGain');
    layoutConfig.validate();
  }

  static const List<double> _validSpeeds = [0.3, 0.5, 1.0, 2.0, 3.0];

  static void _validateSpeed(double speed) {
    const epsilon = 0.001;
    final ok = _validSpeeds.any((s) => (speed - s).abs() < epsilon);
    if (!ok) {
      throw ArgumentError.value(
        speed,
        'initialSpeed',
        'Must be one of ${_validSpeeds.join(', ')}.',
      );
    }
  }

  static void _validateGain(double gain, String name) {
    if (gain < 0.0 || gain > 1.0) {
      throw ArgumentError.value(
        gain,
        name,
        'Audio gain must be in the range [0.0, 1.0].',
      );
    }
  }

  /// Returns a copy with specified fields overridden.
  VGDuetCompositionDescriptor copyWith({
    VGDuetSource? source,
    VGDuetLayoutConfig? layoutConfig,
    VGDuetTrimWindow? trimWindow,
    double? initialSpeed,
    List<VGDuetSegment>? segments,
    double? sourceAudioGain,
    double? micAudioGain,
    bool? sourceAudioMuted,
    bool? micAudioMuted,
    List<VGOverlayDescriptor>? overlays,
  }) {
    return VGDuetCompositionDescriptor(
      source: source ?? this.source,
      layoutConfig: layoutConfig ?? this.layoutConfig,
      trimWindow: trimWindow ?? this.trimWindow,
      initialSpeed: initialSpeed ?? this.initialSpeed,
      segments: segments ?? this.segments,
      sourceAudioGain: sourceAudioGain ?? this.sourceAudioGain,
      micAudioGain: micAudioGain ?? this.micAudioGain,
      sourceAudioMuted: sourceAudioMuted ?? this.sourceAudioMuted,
      micAudioMuted: micAudioMuted ?? this.micAudioMuted,
      overlays: overlays ?? this.overlays,
    );
  }

  /// Serializes the descriptor to a plain [Map] for method channel / JSON.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'source': source.toMap(),
      'layoutConfig': layoutConfig.toMap(),
      'trimWindow': trimWindow.toMap(),
      'initialSpeed': initialSpeed,
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
  /// failing the whole descriptor.
  factory VGDuetCompositionDescriptor.fromMap(Map<String, dynamic> map) {
    final segmentsList =
        (map['segments'] as List<dynamic>?)
            ?.map(
              (e) => VGDuetSegment.fromMap(Map<String, dynamic>.from(e as Map)),
            )
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
    return VGDuetCompositionDescriptor(
      source: VGDuetSource.fromMap(
        Map<String, dynamic>.from(map['source'] as Map),
      ),
      layoutConfig: VGDuetLayoutConfig.fromMap(
        Map<String, dynamic>.from(map['layoutConfig'] as Map),
      ),
      trimWindow: VGDuetTrimWindow.fromMap(
        Map<String, dynamic>.from(map['trimWindow'] as Map),
      ),
      initialSpeed: (map['initialSpeed'] as num).toDouble(),
      segments: segmentsList,
      sourceAudioGain: (map['sourceAudioGain'] as num?)?.toDouble() ?? 1.0,
      micAudioGain: (map['micAudioGain'] as num?)?.toDouble() ?? 1.0,
      sourceAudioMuted: map['sourceAudioMuted'] as bool? ?? false,
      micAudioMuted: map['micAudioMuted'] as bool? ?? false,
      overlays: overlaysList,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetCompositionDescriptor &&
          source == other.source &&
          layoutConfig == other.layoutConfig &&
          trimWindow == other.trimWindow &&
          initialSpeed == other.initialSpeed &&
          _listsEqual(segments, other.segments) &&
          sourceAudioGain == other.sourceAudioGain &&
          micAudioGain == other.micAudioGain &&
          sourceAudioMuted == other.sourceAudioMuted &&
          micAudioMuted == other.micAudioMuted &&
          _overlaysEqual(overlays, other.overlays);

  static bool _listsEqual(List<VGDuetSegment> a, List<VGDuetSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _overlaysEqual(
    List<VGOverlayDescriptor> a,
    List<VGOverlayDescriptor> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    source,
    layoutConfig,
    trimWindow,
    initialSpeed,
    Object.hashAll(segments),
    sourceAudioGain,
    micAudioGain,
    sourceAudioMuted,
    micAudioMuted,
    Object.hashAll(overlays),
  );

  @override
  String toString() =>
      'VGDuetCompositionDescriptor(source: ${source.fileName}, '
      'layout: ${layoutConfig.mode.name}, '
      'trim: ${trimWindow.startSeconds}–${trimWindow.endSeconds}s, '
      'speed: ${initialSpeed}x, '
      'segments: ${segments.length}, '
      'gains: src=${sourceAudioGain}/mic=$micAudioGain, '
      'overlays: ${overlays.length})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Capture result (defined here — after VGDuetCompositionDescriptor — so that
// compositionDescriptor can be typed correctly without a circular import)
// ─────────────────────────────────────────────────────────────────────────────

/// The output of a completed Duet recording session.
class VGDuetCaptureResult {
  /// The finalized immutable composition descriptor.
  final VGDuetCompositionDescriptor compositionDescriptor;

  /// Ordered, unmodifiable list of local segment asset file paths produced by
  /// the engine.
  final List<String> segmentAssets;

  /// Total output timeline duration in milliseconds.
  final int totalDurationMs;

  /// Number of recorded segments.
  final int segmentCount;

  /// Test-only: path to a headless harness proof MP4. Null in production.
  final String? proofOutputPath;

  VGDuetCaptureResult({
    required this.compositionDescriptor,
    required List<String> segmentAssets,
    required this.totalDurationMs,
    required this.segmentCount,
    this.proofOutputPath,
  }) : segmentAssets = List.unmodifiable(segmentAssets) {
    if (totalDurationMs <= 0) {
      throw ArgumentError.value(
        totalDurationMs,
        'totalDurationMs',
        'Must be > 0.',
      );
    }
    if (segmentCount <= 0) {
      throw ArgumentError.value(segmentCount, 'segmentCount', 'Must be > 0.');
    }
  }

  @override
  String toString() =>
      'VGDuetCaptureResult(segments: $segmentCount, '
      'duration: ${totalDurationMs}ms)';
}
