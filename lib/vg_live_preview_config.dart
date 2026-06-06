// vg_live_preview_config.dart
// vanguard_media_engine — MC-1B: Live preview dual-camera layout config
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-1B — LIVE PREVIEW DUAL-CAMERA LAYOUT CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure Dart configuration object for live dual-camera preview layout.
//
// This type is intentionally free of:
//   - VGClipDescriptor / primaryClip / secondaryClip
//   - file paths or media URIs
//   - AVCaptureMultiCamSession or any live capture objects
//   - native runtime state
//
// It reuses the existing proven layout descriptors from vg_dual_camera_descriptor.dart:
//   - VGDualCameraLayoutMode  (pip / splitScreen)
//   - VGPiPLayoutDescriptor   (anchor, widthFraction, marginFraction, cornerRadius, opacity)
//   - VGSplitScreenLayoutDescriptor (splitRatio)
//
// This is the Dart-side layout contract that future live MultiCam preview (MC-4+)
// will pass to the native compositor to position primary and secondary camera feeds.
//
// Map shape (identical keys to VGDualCameraDescriptor layout subset):
//   {
//     'layoutMode':  'pip' | 'splitScreen',
//     'pipLayout':   { 'anchor', 'widthFraction', 'marginFraction', 'cornerRadius', 'opacity' },
//     'splitLayout': { 'splitRatio' },
//   }
//
// ── CONSTRAINTS ──────────────────────────────────────────────────────────────
//
//   DO NOT add clip or session fields to this file.
//   DO NOT add native runtime state.
//   DO NOT add live-capture logic.
//

import 'package:flutter/foundation.dart';
import 'vg_dual_camera_descriptor.dart';

// ─── VGLivePreviewConfig ─────────────────────────────────────────────────────
/// Layout configuration for live dual-camera preview.
///
/// Defines how primary and secondary live camera feeds should be composited
/// during live dual-camera preview (MC-4+).
///
/// This is deliberately free of timeline and clip semantics:
/// no [VGClipDescriptor], no file paths, no session objects.
///
/// Reuses the proven offline-compositor layout descriptors:
///   - [VGDualCameraLayoutMode]
///   - [VGPiPLayoutDescriptor]
///   - [VGSplitScreenLayoutDescriptor]
///
/// The [toMap] output uses the same keys as the layout subset of
/// [VGDualCameraDescriptor.toMap], so the native parsing path can
/// handle both offline and live layout maps without a separate parser.
///
/// ## Defaults
/// All fields have safe, non-null defaults:
///   - [layoutMode]:  [VGDualCameraLayoutMode.pip]
///   - [pipLayout]:   [VGPiPLayoutDescriptor] (bottomRight, 0.35, 0.018, 24.0, 1.0)
///   - [splitLayout]: [VGSplitScreenLayoutDescriptor] (splitRatio 0.5)
@immutable
class VGLivePreviewConfig {
  const VGLivePreviewConfig({
    this.layoutMode = VGDualCameraLayoutMode.pip,
    this.pipLayout = const VGPiPLayoutDescriptor(),
    this.splitLayout = const VGSplitScreenLayoutDescriptor(),
  });

  /// The spatial layout mode: PiP or split-screen.
  final VGDualCameraLayoutMode layoutMode;

  /// PiP geometry configuration. Active when [layoutMode] is [VGDualCameraLayoutMode.pip].
  final VGPiPLayoutDescriptor pipLayout;

  /// Split-screen geometry configuration. Active when [layoutMode] is [VGDualCameraLayoutMode.splitScreen].
  final VGSplitScreenLayoutDescriptor splitLayout;

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this config with the specified fields replaced.
  VGLivePreviewConfig copyWith({
    VGDualCameraLayoutMode? layoutMode,
    VGPiPLayoutDescriptor? pipLayout,
    VGSplitScreenLayoutDescriptor? splitLayout,
  }) {
    return VGLivePreviewConfig(
      layoutMode: layoutMode ?? this.layoutMode,
      pipLayout: pipLayout ?? this.pipLayout,
      splitLayout: splitLayout ?? this.splitLayout,
    );
  }

  // ── Serialization ──────────────────────────────────────────────────────────

  /// Serializes this config to a map.
  ///
  /// Output keys are identical to the layout subset of [VGDualCameraDescriptor.toMap]:
  ///   - `layoutMode`
  ///   - `pipLayout`
  ///   - `splitLayout`
  ///
  /// Notably absent (live preview has no clips):
  ///   - `primaryClip`
  ///   - `secondaryClip`
  Map<String, Object?> toMap() {
    return {
      'layoutMode': layoutMode.value,
      'pipLayout': pipLayout.toMap(),
      'splitLayout': splitLayout.toMap(),
    };
  }

  /// Deserializes a [VGLivePreviewConfig] from a map.
  ///
  /// Always returns a non-null result:
  ///   - [map] is `null` or empty → returns `const VGLivePreviewConfig()` (all defaults).
  ///   - Unrecognised `layoutMode` → falls back to [VGDualCameraLayoutMode.pip].
  ///   - Malformed or out-of-range `pipLayout` → falls back to `const VGPiPLayoutDescriptor()`.
  ///   - Malformed or out-of-range `splitLayout` → falls back to `const VGSplitScreenLayoutDescriptor()`.
  ///
  /// This non-nullable contract means callers never need null-handling boilerplate:
  /// a live preview always has *some* layout configuration.
  static VGLivePreviewConfig fromMap(Map<Object?, Object?>? map) {
    if (map == null || map.isEmpty) {
      return const VGLivePreviewConfig();
    }

    // layoutMode — unknown values default to pip.
    final layoutModeStr = map['layoutMode'] as String?;
    final layoutMode = layoutModeStr != null
        ? VGDualCameraLayoutModeExtension.fromValue(layoutModeStr)
        : VGDualCameraLayoutMode.pip;

    // pipLayout — validation failure falls back to default.
    final pipLayoutMap = map['pipLayout'] as Map<Object?, Object?>?;
    final pipLayout =
        VGPiPLayoutDescriptor.fromMap(pipLayoutMap) ?? const VGPiPLayoutDescriptor();

    // splitLayout — validation failure falls back to default.
    final splitLayoutMap = map['splitLayout'] as Map<Object?, Object?>?;
    final splitLayout =
        VGSplitScreenLayoutDescriptor.fromMap(splitLayoutMap) ??
            const VGSplitScreenLayoutDescriptor();

    return VGLivePreviewConfig(
      layoutMode: layoutMode,
      pipLayout: pipLayout,
      splitLayout: splitLayout,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGLivePreviewConfig &&
          runtimeType == other.runtimeType &&
          layoutMode == other.layoutMode &&
          pipLayout == other.pipLayout &&
          splitLayout == other.splitLayout;

  @override
  int get hashCode => Object.hash(layoutMode, pipLayout, splitLayout);

  @override
  String toString() =>
      'VGLivePreviewConfig('
      'layoutMode: $layoutMode, '
      'pipLayout: $pipLayout, '
      'splitLayout: $splitLayout)';
}
