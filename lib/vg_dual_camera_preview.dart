// vg_dual_camera_preview.dart
// Vanguard Media Engine
//
// Dual-camera concurrent preview widget supporting Horizontal Split,
// Vertical Split, and high-performance 120Hz free-floating Picture-in-Picture.

import 'package:flutter/material.dart';
import 'vg_camera_session.dart';

/// Grid options for dual-camera preview presentation.
enum VGDualCameraGridOption {
  /// Horizontal split (top half / bottom half 50/50).
  splitH,

  /// Vertical split (left half / right half 50/50).
  splitV,

  /// Picture-in-Picture (primary stream fullscreen with a floating inset).
  pip,
}

/// A high-performance, aspect-ratio-correct preview widget for dual-camera sessions.
///
/// Automatically handles single-texture composited sessions (iOS) and independent
/// dual-texture concurrent streams (Android).
class VGDualCameraPreview extends StatefulWidget {
  const VGDualCameraPreview({
    super.key,
    required this.session,
    this.gridOption = VGDualCameraGridOption.pip,
    this.isFrontPrimary = false,
    this.onSwapCameras,
    this.showBadges = false,
    this.pipWidth = 0.0,
    this.pipHeight = 0.0,
    this.splitRatio = 0.5,
    this.fit,
  });

  /// The active dual-camera session.
  final VGMultiCamRenderTextureSession session;

  /// Active grid option (H Split, V Split, or PiP).
  final VGDualCameraGridOption gridOption;

  /// Whether the front camera is rendered in the primary/fullscreen slot.
  final bool isFrontPrimary;

  /// Optional callback invoked when the user taps to swap camera assignments.
  final VoidCallback? onSwapCameras;

  /// Whether to show FRONT/BACK label badges on streams.
  final bool showBadges;

  /// Width of the floating PiP window. When 0.0, automatically calculated at 9:16.
  final double pipWidth;

  /// Height of the floating PiP window. When 0.0, automatically calculated at 9:16.
  final double pipHeight;

  /// Height split ratio for Horizontal Split (top stream height fraction, 0.2–0.8).
  final double splitRatio;

  /// Custom [BoxFit] for preview presentation. Defaults to [BoxFit.contain] for
  /// [VGDualCameraGridOption.splitH] and [VGDualCameraGridOption.splitV] (preserving uncropped 9:16 framing with black
  /// letterbox padding like TikTok), and [BoxFit.cover] for PiP.
  final BoxFit? fit;

  @override
  State<VGDualCameraPreview> createState() => _VGDualCameraPreviewState();
}

class _VGDualCameraPreviewState extends State<VGDualCameraPreview> {
  // ValueNotifier ensures 120Hz high-refresh touch dragging without triggering
  // full widget tree rebuilds or reallocating camera textures.
  late final ValueNotifier<Offset?> _pipPositionNotifier;

  @override
  void initState() {
    super.initState();
    _pipPositionNotifier = ValueNotifier<Offset?>(null);
  }

  @override
  void dispose() {
    _pipPositionNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveFit = widget.fit ??
        ((widget.gridOption == VGDualCameraGridOption.splitH ||
                widget.gridOption == VGDualCameraGridOption.splitV)
            ? BoxFit.contain
            : BoxFit.cover);

    // If only one texture exists (iOS Metal or Android Vulkan/GLES compositor),
    // render aspect-correct texture so it never stretches on non-16:9 displays.
    if (widget.session.backTextureId == null) {
      return _buildAspectCorrectTexture(widget.session.textureId, fit: effectiveFit);
    }

    final frontTid = widget.session.textureId;
    final backTid = widget.session.backTextureId!;

    final primaryTid = widget.isFrontPrimary ? frontTid : backTid;
    final secondaryTid = widget.isFrontPrimary ? backTid : frontTid;

    final primaryLabel = widget.isFrontPrimary ? 'FRONT' : 'BACK';
    final secondaryLabel = widget.isFrontPrimary ? 'BACK' : 'FRONT';

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;

        switch (widget.gridOption) {
          case VGDualCameraGridOption.splitH:
            return _buildHorizontalSplit(
              primaryTid,
              secondaryTid,
              primaryLabel,
              secondaryLabel,
              fit: effectiveFit,
            );

          case VGDualCameraGridOption.splitV:
            return _buildVerticalSplit(
              primaryTid,
              secondaryTid,
              primaryLabel,
              secondaryLabel,
              fit: effectiveFit,
            );

          case VGDualCameraGridOption.pip:
            return _buildFloatingPip(
              primaryTid,
              secondaryTid,
              primaryLabel,
              secondaryLabel,
              screenWidth,
              screenHeight,
            );
        }
      },
    );
  }

  /// Builds Horizontal Split (Top / Bottom) with dynamic split ratio.
  Widget _buildHorizontalSplit(
    int topTid,
    int bottomTid,
    String topLabel,
    String bottomLabel, {
    BoxFit fit = BoxFit.contain,
  }) {
    final topFlex = (widget.splitRatio.clamp(0.2, 0.8) * 1000).round();
    final bottomFlex = 1000 - topFlex;

    return Column(
      children: [
        Expanded(
          flex: topFlex,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(topTid, fit: fit),
              _buildStreamBadge(topLabel, Alignment.topLeft),
            ],
          ),
        ),
        Container(height: 2, color: Colors.white24),
        Expanded(
          flex: bottomFlex,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(bottomTid, fit: fit),
              _buildStreamBadge(bottomLabel, Alignment.topLeft),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds Vertical Split (Left / Right 50/50) with aspect ratio preserved.
  Widget _buildVerticalSplit(
    int leftTid,
    int rightTid,
    String leftLabel,
    String rightLabel, {
    BoxFit fit = BoxFit.contain,
  }) {
    return Row(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(leftTid, fit: fit),
              _buildStreamBadge(leftLabel, Alignment.topLeft),
            ],
          ),
        ),
        Container(width: 2, color: Colors.white24),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(rightTid, fit: fit),
              _buildStreamBadge(rightLabel, Alignment.topLeft),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds Fullscreen Primary + 120Hz Free-Floating PiP.
  Widget _buildFloatingPip(
    int primaryTid,
    int secondaryTid,
    String primaryLabel,
    String secondaryLabel,
    double screenWidth,
    double screenHeight,
  ) {
    final pipW = (widget.pipWidth > 0 ? widget.pipWidth : screenWidth * 0.35)
        .clamp(screenWidth * 0.15, screenWidth * 0.65);
    final pipH = widget.pipHeight > 0 ? widget.pipHeight : pipW * (16.0 / 9.0);

    // Default position: top right corner with padding
    if (_pipPositionNotifier.value == null) {
      _pipPositionNotifier.value = Offset(
        screenWidth - pipW - 16,
        MediaQuery.of(context).padding.top + 50,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Fullscreen Primary Preview
        _buildAspectCorrectTexture(primaryTid),
        _buildStreamBadge(primaryLabel, Alignment.topLeft),

        // 2. High-Performance 120Hz Draggable PiP
        ValueListenableBuilder<Offset?>(
          valueListenable: _pipPositionNotifier,
          builder: (context, pos, child) {
            final currentPos = pos ?? const Offset(20, 80);
            return Positioned(
              left: currentPos.dx,
              top: currentPos.dy,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) {
                  final newX = (_pipPositionNotifier.value?.dx ?? currentPos.dx) + details.delta.dx;
                  final newY = (_pipPositionNotifier.value?.dy ?? currentPos.dy) + details.delta.dy;

                  // Constrain inside screen bounds
                  final clampedX = newX.clamp(8.0, screenWidth - pipW - 8.0);
                  final clampedY = newY.clamp(
                    MediaQuery.of(context).padding.top + 8.0,
                    screenHeight - pipH - 8.0,
                  );

                  _pipPositionNotifier.value = Offset(clampedX, clampedY);
                },
                child: child,
              ),
            );
          },
          child: Container(
            width: pipW,
            height: pipH,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white, width: 2.0),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13.5),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildAspectCorrectTexture(secondaryTid),
                  _buildStreamBadge(secondaryLabel, Alignment.bottomCenter, isMini: true),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Wraps a texture in ClipRect + Container(black) + FittedBox(fit: fit) to preserve
  /// native 1080x1920 sensor geometry without squishing or stretching.
  Widget _buildAspectCorrectTexture(int textureId, {BoxFit fit = BoxFit.cover}) {
    final isBack = widget.session.backTextureId != null &&
        textureId == widget.session.backTextureId;
    final fallbackW = widget.session.outputWidth > 0 ? widget.session.outputWidth : 1080;
    final fallbackH = widget.session.outputHeight > 0 ? widget.session.outputHeight : 1920;
    final rawW = isBack
        ? (widget.session.backBufferWidth ??
            widget.session.frontBufferWidth ??
            fallbackW)
        : (widget.session.frontBufferWidth ?? fallbackW);
    final rawH = isBack
        ? (widget.session.backBufferHeight ??
            widget.session.frontBufferHeight ??
            fallbackH)
        : (widget.session.frontBufferHeight ?? fallbackH);

    // In portrait presentation, maintain minor axis width and major axis height
    final nativeW = (rawW < rawH ? rawW : rawH).toDouble();
    final nativeH = (rawW > rawH ? rawW : rawH).toDouble();

    return ClipRect(
      child: Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: FittedBox(
          fit: fit,
          alignment: Alignment.center,
          child: SizedBox(
            width: nativeW,
            height: nativeH,
            child: Texture(textureId: textureId),
          ),
        ),
      ),
    );
  }

  Widget _buildStreamBadge(String label, Alignment alignment, {bool isMini = false}) {
    if (!widget.showBadges) return const SizedBox.shrink();
    return Align(
      alignment: alignment,
      child: Container(
        margin: EdgeInsets.all(isMini ? 4 : 12),
        padding: EdgeInsets.symmetric(horizontal: isMini ? 6 : 8, vertical: isMini ? 2 : 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Colors.white24,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: isMini ? 9 : 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
