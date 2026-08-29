// vg_camera_zoom_capabilities.dart
// Vanguard Media Engine — Phase 6 Zoom Capabilities API
//
// VGCameraZoomCapabilities is a pure value object returned by
// VGCameraSession.getZoomCapabilities(). It exposes native device zoom bounds
// so callers can clamp pinch-zoom gestures to real hardware limits instead of
// hardcoded fallbacks.
//
// maxZoomFactor is the RECOMMENDED quality-safe maximum for UI/gesture
// clamping. It is NOT the raw AVFoundation technical ceiling.
// Use technicalMaxZoomFactor for diagnostics only.
//
// Wide-angle-first: In this phase, device discovery remains bound to the
// built-in wide-angle camera. On a single wide-angle device:
//   minZoomFactor = 1.0
//   maxZoomFactor = recommended quality-safe max (e.g. ~6× back, 2× front)
//   technicalMaxZoomFactor = device maxAvailableVideoZoomFactor (may be 200×)
//   upscaleThresholdZoomFactor = activeFormat.videoZoomFactorUpscaleThreshold
//   virtualDeviceSwitchOverZoomFactors = []
//   isVirtualDevice = false
//   supportsUltraWide = false
//   supportsTelephoto = false
//
// Virtual multi-camera discovery (builtInTripleCamera, builtInDualCamera,
// builtInDualWideCamera) is deferred to a subsequent task. Do not claim
// 0.5× ultra-wide or telephoto parity until that task is implemented and
// real-device validated.
//
// Android: Backed by CameraX ZoomState. Android has no separate optical/
// lossless-crop threshold, so technicalMaxZoomFactor is reused as
// upscaleThresholdZoomFactor. virtualDeviceSwitchOverZoomFactors is []
// and isVirtualDevice is false in the current CameraX wide-angle-only phase.

import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────

/// The physical position of the camera sensor.
///
/// Reported by [VGCameraZoomCapabilities.cameraPosition] so callers can
/// distinguish front-camera (narrow zoom range) from back-camera (wider range)
/// without having to track which [VGCameraPosition] was active at query time.
enum VGZoomCameraPosition {
  /// Rear-facing (world-facing) sensor.
  back,

  /// Front-facing (self-facing) sensor.
  front,

  /// Position unknown or unspecified (e.g. simulator, Android fallback).
  unknown,
}

// ─────────────────────────────────────────────────────────────────────────────

/// Zoom capability data returned by [VGCameraSession.getZoomCapabilities].
///
/// ## Key field distinction
/// | Field | Meaning | Use for |
/// |---|---|---|
/// | [maxZoomFactor] | Recommended quality-safe limit | UI clamping, pinch gestures |
/// | [technicalMaxZoomFactor] | Raw AVFoundation ceiling (may be 200×) | Diagnostics only |
/// | [upscaleThresholdZoomFactor] | Lossless sensor-crop boundary | Zoom quality indicator |
///
/// ## Recommended max policy (computed natively)
/// - **Front camera:** `min(2.0, technicalMaxZoomFactor)`
/// - **Back camera:** `min(upscaleThreshold × 2.5, 10.0)`, capped at technicalMax
///
/// ## Wide-angle-first phase
/// In the current implementation, Vanguard binds exclusively to the
/// `builtInWideAngleCamera`. On such a device all [virtualDeviceSwitchOverZoomFactors]
/// are empty and [isVirtualDevice] is `false`. [supportsUltraWide] and
/// [supportsTelephoto] are therefore `false`.
///
/// ## Android
/// Backed by CameraX `ZoomState`. `technicalMaxZoomFactor` is reused as
/// `upscaleThresholdZoomFactor` since CameraX has no equivalent of
/// AVFoundation's lossless-crop threshold.
final class VGCameraZoomCapabilities {
  const VGCameraZoomCapabilities({
    required this.minZoomFactor,
    required this.maxZoomFactor,
    required this.defaultZoomFactor,
    this.technicalMaxZoomFactor = 6.0,
    this.upscaleThresholdZoomFactor = 6.0,
    this.cameraPosition = VGZoomCameraPosition.unknown,
    this.displayZoomFactorMultiplier = 1.0,
    this.virtualDeviceSwitchOverZoomFactors = const [],
    this.isVirtualDevice = false,
    this.metadata = const {},
  });

  // ── Fields ─────────────────────────────────────────────────────────────────

  /// Minimum zoom factor supported by the active device in its current
  /// capture configuration.
  ///
  /// On single wide-angle devices: always `1.0`.
  /// On dual/triple virtual devices with ultra-wide: may be the ultra-wide
  /// reciprocal factor — but only after virtual multi-camera discovery is
  /// implemented (deferred).
  ///
  /// iOS source: `AVCaptureDevice.minAvailableVideoZoomFactor` (iOS 11+).
  final double minZoomFactor;

  /// The **recommended quality-safe maximum** zoom factor for UI/gesture
  /// clamping. Pinch-zoom handlers and zoom sliders must clamp to this field.
  ///
  /// This is NOT the raw AVFoundation ceiling. It is a product-policy maximum:
  ///   - **Front camera:** `min(2.0, technicalMaxZoomFactor)`
  ///   - **Back camera:** `min(upscaleThresholdZoomFactor × 2.5, 10.0)`
  ///     capped at [technicalMaxZoomFactor].
  ///
  /// See [technicalMaxZoomFactor] for the raw ceiling (diagnostic use only).
  final double maxZoomFactor;

  /// The raw AVFoundation technical ceiling.
  ///
  /// On modern single wide-angle devices this can be **100× – 200×**.
  /// Zoom beyond [upscaleThresholdZoomFactor] uses digital interpolation
  /// that degrades image quality significantly.
  ///
  /// **Do not use this value to clamp UI or pinch gestures.** It exists for
  /// diagnostics and developer tooling only.
  ///
  /// iOS source: `AVCaptureDevice.maxAvailableVideoZoomFactor` (iOS 11+),
  /// falling back to `activeFormat.videoMaxZoomFactor`.
  final double technicalMaxZoomFactor;

  /// The zoom factor at which the camera output begins to require digital
  /// upscaling (pixel interpolation).
  ///
  /// **At or below this threshold** the sensor delivers a lossless center crop
  /// — no scaling artefacts.
  /// **Above this threshold** the output is interpolated and image quality
  /// degrades visibly.
  ///
  /// Use this field to drive a quality indicator in the camera UI, e.g. a
  /// subtle badge colour change or tooltip.
  ///
  /// iOS source: `AVCaptureDevice.Format.videoZoomFactorUpscaleThreshold`
  /// (iOS 7+). Fallback: [technicalMaxZoomFactor] when the threshold is
  /// not well-defined (value ≤ 1.0).
  final double upscaleThresholdZoomFactor;

  /// The physical position of the active camera sensor.
  ///
  /// Reflects which physical sensor was active at the time
  /// [VGCameraSession.getZoomCapabilities] was called. Should be re-queried
  /// after every `switchCamera` call so the UI can update zoom affordances
  /// appropriately.
  final VGZoomCameraPosition cameraPosition;

  /// The zoom factor that represents the native "1×" standard lens.
  ///
  /// Always `1.0` in the current wide-angle-first implementation. When virtual
  /// multi-camera discovery is implemented, this may differ from `1.0` if the
  /// virtual device considers the ultra-wide to be its minimum (not the wide).
  final double defaultZoomFactor;

  /// A multiplier to convert a native [videoZoomFactor] to the display value
  /// shown in UI (e.g. the value that iOS Camera labels "1×").
  ///
  /// iOS source: `AVCaptureDevice.displayVideoZoomFactorMultiplier` (**iOS 18+**).
  /// On iOS < 18 this is `1.0` (no additional scaling needed for wide-angle).
  ///
  /// Android: always `1.0` (CameraX exposes no equivalent multiplier).
  final double displayZoomFactorMultiplier;

  /// Zoom factor thresholds at which a virtual device switches between its
  /// constituent physical lenses (e.g., ultra-wide → wide, wide → telephoto).
  ///
  /// Empty (`[]`) on non-virtual (single-lens) devices and in the current
  /// wide-angle-first implementation.
  ///
  /// iOS source: `AVCaptureDevice.virtualDeviceSwitchOverVideoZoomFactors`
  /// (iOS 13+).
  final List<double> virtualDeviceSwitchOverZoomFactors;

  /// Whether the active device is an AVFoundation virtual device composed of
  /// multiple physical lenses.
  ///
  /// `false` in the current wide-angle-first implementation.
  ///
  /// iOS source: `AVCaptureDevice.isVirtualDevice` (iOS 13+).
  final bool isVirtualDevice;

  /// Reserved for future platform-specific metadata. Currently always empty.
  final Map<String, Object?> metadata;

  // ── Computed getters ───────────────────────────────────────────────────────

  /// `true` when [maxZoomFactor] is meaningfully greater than [minZoomFactor],
  /// meaning the user can perform a perceptible zoom.
  ///
  /// The epsilon used is `0.05×` — any recommended max that is within 5%
  /// of the minimum is considered non-meaningful.
  ///
  /// UI callers may hide or disable zoom affordances (pinch area, zoom badge,
  /// quick-zoom buttons) when this is `false`. Typically `false` on front
  /// cameras where [maxZoomFactor] ≤ 2.0 and the device's minimum is ≥ 1.95×.
  bool get supportsMeaningfulZoom =>
      (maxZoomFactor - minZoomFactor) > 0.05;

  /// Whether the active device has a dedicated ultra-wide physical lens
  /// accessible through the current configuration.
  ///
  /// Honest implementation: `true` only when the device is a virtual device
  /// AND switch-over factors are present (implying at least one lens below the
  /// wide-angle range). Currently always `false` because virtual multi-camera
  /// discovery is not yet implemented.
  ///
  /// Do NOT use this as a product signal until virtual multi-camera is
  /// implemented and real-device validated.
  bool get supportsUltraWide =>
      isVirtualDevice && virtualDeviceSwitchOverZoomFactors.isNotEmpty;

  /// Whether the active device has a dedicated telephoto physical lens
  /// accessible through the current configuration.
  ///
  /// Honest implementation: `true` only when the device is a virtual device
  /// AND at least two switch-over thresholds are present (wide → telephoto).
  /// Currently always `false` because virtual multi-camera discovery is not
  /// yet implemented.
  bool get supportsTelephoto =>
      isVirtualDevice && virtualDeviceSwitchOverZoomFactors.length >= 2;

  // ── Display helpers ────────────────────────────────────────────────────────

  /// Returns a formatted zoom label for [factor] scaled by
  /// [displayZoomFactorMultiplier], suitable for display in a zoom badge.
  ///
  /// Examples (with multiplier = 1.0):
  ///   factor 1.0   → "1.00×"
  ///   factor 1.5   → "1.50×"
  ///   factor 2.0   → "2.0×"
  ///   factor 3.14  → "3.1×"
  String displayLabelFor(double factor) {
    final display = factor * displayZoomFactorMultiplier;
    return display >= 2.0
        ? '${display.toStringAsFixed(1)}×'
        : '${display.toStringAsFixed(2)}×';
  }

  // ── Constants ──────────────────────────────────────────────────────────────

  /// Safe fallback used when native capability query fails, the session is
  /// disposed, or no camera is active. Clamps zoom to the 1.0–6.0 range
  /// used in the validation era.
  ///
  /// This is a temporary validation-era fallback, not a production bound.
  /// Production code will replace this with real native values on the first
  /// successful [VGCameraSession.getZoomCapabilities] call.
  static const VGCameraZoomCapabilities fallback = VGCameraZoomCapabilities(
    minZoomFactor: 1.0,
    maxZoomFactor: 6.0,
    defaultZoomFactor: 1.0,
    technicalMaxZoomFactor: 6.0,
    upscaleThresholdZoomFactor: 6.0,
    cameraPosition: VGZoomCameraPosition.unknown,
  );

  // ── Factories ──────────────────────────────────────────────────────────────

  /// Deserialises a map returned by the native `getCameraZoomCapabilities`
  /// method channel call.
  factory VGCameraZoomCapabilities.fromMap(Map<String, dynamic> map) {
    final rawSwitchOvers =
        map['virtualDeviceSwitchOverZoomFactors'] as List<dynamic>?;
    final switchOvers = rawSwitchOvers
            ?.map((e) => (e as num).toDouble())
            .toList(growable: false) ??
        const <double>[];

    // Parse cameraPosition string from native.
    VGZoomCameraPosition pos;
    switch (map['cameraPosition'] as String?) {
      case 'front':
        pos = VGZoomCameraPosition.front;
        break;
      case 'back':
        pos = VGZoomCameraPosition.back;
        break;
      default:
        pos = VGZoomCameraPosition.unknown;
    }

    final technicalMax =
        (map['technicalMaxZoomFactor'] as num?)?.toDouble() ?? 6.0;
    final upscaleThreshold =
        (map['upscaleThresholdZoomFactor'] as num?)?.toDouble() ?? technicalMax;

    return VGCameraZoomCapabilities(
      minZoomFactor: (map['minZoomFactor'] as num?)?.toDouble() ?? 1.0,
      maxZoomFactor: (map['maxZoomFactor'] as num?)?.toDouble() ?? 6.0,
      defaultZoomFactor: (map['defaultZoomFactor'] as num?)?.toDouble() ?? 1.0,
      technicalMaxZoomFactor: technicalMax,
      upscaleThresholdZoomFactor: upscaleThreshold,
      cameraPosition: pos,
      displayZoomFactorMultiplier:
          (map['displayZoomFactorMultiplier'] as num?)?.toDouble() ?? 1.0,
      virtualDeviceSwitchOverZoomFactors: switchOvers,
      isVirtualDevice: map['isVirtualDevice'] as bool? ?? false,
    );
  }

  // ── Diagnostics ────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraZoomCapabilities &&
        other.minZoomFactor == minZoomFactor &&
        other.maxZoomFactor == maxZoomFactor &&
        other.technicalMaxZoomFactor == technicalMaxZoomFactor &&
        other.upscaleThresholdZoomFactor == upscaleThresholdZoomFactor &&
        other.cameraPosition == cameraPosition &&
        other.defaultZoomFactor == defaultZoomFactor &&
        other.displayZoomFactorMultiplier == displayZoomFactorMultiplier &&
        listEquals(other.virtualDeviceSwitchOverZoomFactors,
            virtualDeviceSwitchOverZoomFactors) &&
        other.isVirtualDevice == isVirtualDevice;
  }

  @override
  int get hashCode => Object.hash(
        minZoomFactor,
        maxZoomFactor,
        technicalMaxZoomFactor,
        upscaleThresholdZoomFactor,
        cameraPosition,
        defaultZoomFactor,
        displayZoomFactorMultiplier,
        Object.hashAll(virtualDeviceSwitchOverZoomFactors),
        isVirtualDevice,
      );

  @override
  String toString() =>
      'VGCameraZoomCapabilities('
      'position: ${cameraPosition.name}, '
      'min: $minZoomFactor, '
      'max: $maxZoomFactor (recommended), '
      'technicalMax: $technicalMaxZoomFactor, '
      'upscaleThreshold: $upscaleThresholdZoomFactor, '
      'default: $defaultZoomFactor, '
      'displayMultiplier: $displayZoomFactorMultiplier, '
      'switchOvers: $virtualDeviceSwitchOverZoomFactors, '
      'virtual: $isVirtualDevice, '
      'supportsMeaningfulZoom: $supportsMeaningfulZoom'
      ')';
}
