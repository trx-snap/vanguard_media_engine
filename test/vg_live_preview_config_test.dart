// vg_live_preview_config_test.dart
// vanguard_media_engine — MC-1B: Tests for VGLivePreviewConfig
//
// Tests all 13 required cases per the Opus validation plan.
// No Flutter binding required — pure Dart value object tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGLivePreviewConfig (MC-1B)', () {
    // ─── 1. Default constructor ───────────────────────────────────────────────
    test('1. default constructor uses pip mode with default layouts', () {
      const config = VGLivePreviewConfig();

      expect(config.layoutMode, VGDualCameraLayoutMode.pip);

      // Default pipLayout matches VGPiPLayoutDescriptor() defaults.
      expect(config.pipLayout.anchor, VGPiPAnchor.bottomRight);
      expect(config.pipLayout.widthFraction, 0.35);
      expect(config.pipLayout.marginFraction, 0.018);
      expect(config.pipLayout.cornerRadius, 24.0);
      expect(config.pipLayout.opacity, 1.0);

      // Default splitLayout matches VGSplitScreenLayoutDescriptor() defaults.
      expect(config.splitLayout.splitRatio, 0.5);
    });

    // ─── 2. copyWith preserves untouched fields ───────────────────────────────
    test('2. copyWith preserves untouched fields', () {
      const original = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        pipLayout: VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topLeft, widthFraction: 0.4),
        splitLayout: VGSplitScreenLayoutDescriptor(splitRatio: 0.6),
      );

      // Change only layoutMode — pipLayout and splitLayout must be preserved.
      final copy = original.copyWith(layoutMode: VGDualCameraLayoutMode.pip);

      expect(copy.layoutMode, VGDualCameraLayoutMode.pip);
      expect(copy.pipLayout, original.pipLayout);
      expect(copy.splitLayout, original.splitLayout);
    });

    // ─── 3. copyWith replaces specified fields ────────────────────────────────
    test('3. copyWith replaces specified fields', () {
      const original = VGLivePreviewConfig();

      const newPip = VGPiPLayoutDescriptor(
        anchor: VGPiPAnchor.topRight,
        widthFraction: 0.5,
        cornerRadius: 12.0,
      );
      const newSplit = VGSplitScreenLayoutDescriptor(splitRatio: 0.3);

      final copy = original.copyWith(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        pipLayout: newPip,
        splitLayout: newSplit,
      );

      expect(copy.layoutMode, VGDualCameraLayoutMode.splitScreen);
      expect(copy.pipLayout, newPip);
      expect(copy.splitLayout, newSplit);
    });

    // ─── 4. toMap produces expected keys and values ───────────────────────────
    test('4. toMap produces expected keys and values', () {
      const config = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.bottomRight,
          widthFraction: 0.35,
          marginFraction: 0.018,
          cornerRadius: 24.0,
          opacity: 1.0,
        ),
        splitLayout: VGSplitScreenLayoutDescriptor(splitRatio: 0.5),
      );

      final map = config.toMap();

      expect(map['layoutMode'], 'pip');

      final pip = map['pipLayout'] as Map<String, Object?>;
      expect(pip['anchor'], 'bottomRight');
      expect(pip['widthFraction'], 0.35);
      expect(pip['marginFraction'], 0.018);
      expect(pip['cornerRadius'], 24.0);
      expect(pip['opacity'], 1.0);

      final split = map['splitLayout'] as Map<String, Object?>;
      expect(split['splitRatio'], 0.5);
    });

    // ─── 5. toMap does not contain clip or session fields ─────────────────────
    test('5. toMap does not contain clip or session fields', () {
      const config = VGLivePreviewConfig();
      final map = config.toMap();
      final str = map.toString();

      expect(map.containsKey('primaryClip'), isFalse);
      expect(map.containsKey('secondaryClip'), isFalse);
      expect(str.contains('primaryClip'), isFalse);
      expect(str.contains('secondaryClip'), isFalse);
      expect(str.contains('sourcePath'), isFalse);
      expect(str.contains('MultiCam'), isFalse);
      expect(str.contains('AVCapture'), isFalse);
      expect(str.contains('session'), isFalse);
    });

    // ─── 6. fromMap round-trip (pip mode) ─────────────────────────────────────
    test('6. fromMap round-trip pip mode', () {
      const original = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.topLeft,
          widthFraction: 0.45,
          marginFraction: 0.02,
          cornerRadius: 16.0,
          opacity: 0.85,
        ),
        splitLayout: VGSplitScreenLayoutDescriptor(splitRatio: 0.5),
      );

      final roundTrip = VGLivePreviewConfig.fromMap(original.toMap());

      expect(roundTrip, original);
    });

    // ─── 7. fromMap round-trip (splitScreen mode) ─────────────────────────────
    test('7. fromMap round-trip splitScreen mode', () {
      const original = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        pipLayout: VGPiPLayoutDescriptor(),
        splitLayout: VGSplitScreenLayoutDescriptor(splitRatio: 0.7),
      );

      final roundTrip = VGLivePreviewConfig.fromMap(original.toMap());

      expect(roundTrip.layoutMode, VGDualCameraLayoutMode.splitScreen);
      expect(roundTrip.splitLayout.splitRatio, 0.7);
      expect(roundTrip, original);
    });

    // ─── 8. fromMap null returns default config ────────────────────────────────
    test('8. fromMap null returns default config', () {
      final result = VGLivePreviewConfig.fromMap(null);
      expect(result, const VGLivePreviewConfig());
    });

    // ─── 9. fromMap empty map returns default config ───────────────────────────
    test('9. fromMap empty map returns default config', () {
      final result = VGLivePreviewConfig.fromMap({});
      expect(result, const VGLivePreviewConfig());
    });

    // ─── 10. fromMap invalid pipLayout falls back to default ───────────────────
    test('10. fromMap invalid pipLayout falls back to default pipLayout', () {
      // widthFraction 0.99 is out of the [0.05, 0.75] valid range;
      // VGPiPLayoutDescriptor.fromMap will return null → fallback to default.
      final result = VGLivePreviewConfig.fromMap({
        'layoutMode': 'pip',
        'pipLayout': {'widthFraction': 0.99},
        'splitLayout': {'splitRatio': 0.5},
      });

      expect(result.pipLayout, const VGPiPLayoutDescriptor());
      expect(result.layoutMode, VGDualCameraLayoutMode.pip);
      expect(result.splitLayout, const VGSplitScreenLayoutDescriptor());
    });

    // ─── 11. fromMap invalid splitLayout falls back to default ─────────────────
    test('11. fromMap invalid splitLayout falls back to default splitLayout', () {
      // splitRatio 0.9 is outside [0.2, 0.8] → VGSplitScreenLayoutDescriptor.fromMap returns null.
      final result = VGLivePreviewConfig.fromMap({
        'layoutMode': 'splitScreen',
        'pipLayout': null,
        'splitLayout': {'splitRatio': 0.9},
      });

      expect(result.splitLayout, const VGSplitScreenLayoutDescriptor());
      expect(result.layoutMode, VGDualCameraLayoutMode.splitScreen);
    });

    // ─── 12. equality and hashCode ────────────────────────────────────────────
    test('12. equality and hashCode', () {
      const a = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(anchor: VGPiPAnchor.bottomLeft),
      );
      const b = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(anchor: VGPiPAnchor.bottomLeft),
      );
      const c = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
      );

      // Equal configs.
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      // Different configs.
      expect(a, isNot(c));
      expect(a.hashCode, isNot(c.hashCode));
    });

    // ─── 13. map keys match VGDualCameraDescriptor layout subset ─────────────
    test('13. map keys match VGDualCameraDescriptor layout subset', () {
      const config = VGLivePreviewConfig();
      final liveKeys = config.toMap().keys.toSet();

      // The layout subset keys from VGDualCameraDescriptor.toMap()
      // (excluding primaryClip and secondaryClip).
      const expectedLayoutKeys = {'layoutMode', 'pipLayout', 'splitLayout'};

      expect(liveKeys, expectedLayoutKeys);

      // Confirm none of the offline-only keys leaked in.
      expect(liveKeys.contains('primaryClip'), isFalse);
      expect(liveKeys.contains('secondaryClip'), isFalse);
    });
  });
}
