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
    this.pipWidth = 130.0,
    this.pipHeight = 220.0,
  });

  /// The active dual-camera session.
  final VGMultiCamRenderTextureSession session;

  /// Active grid option (H Split, V Split, or PiP).
  final VGDualCameraGridOption gridOption;

  /// Whether the front camera is rendered in the primary/fullscreen slot.
  final bool isFrontPrimary;

  /// Optional callback invoked when the user taps to swap camera assignments.
  final VoidCallback? onSwapCameras;

  /// Width of the floating PiP window.
  final double pipWidth;

  /// Height of the floating PiP window.
  final double pipHeight;

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
    // If only one texture exists (iOS AVFoundation CoreImage compositor), render direct texture
    if (widget.session.backTextureId == null) {
      return Texture(textureId: widget.session.textureId);
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
            return _buildHorizontalSplit(primaryTid, secondaryTid, primaryLabel, secondaryLabel);

          case VGDualCameraGridOption.splitV:
            return _buildVerticalSplit(primaryTid, secondaryTid, primaryLabel, secondaryLabel);

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

  /// Builds Horizontal Split (Top / Bottom 50/50) with aspect ratio preserved.
  Widget _buildHorizontalSplit(
    int topTid,
    int bottomTid,
    String topLabel,
    String bottomLabel,
  ) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(topTid),
              _buildStreamBadge(topLabel, Alignment.topLeft),
            ],
          ),
        ),
        Container(height: 2, color: Colors.white24),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(bottomTid),
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
    String rightLabel,
  ) {
    return Row(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(leftTid),
              _buildStreamBadge(leftLabel, Alignment.topLeft),
            ],
          ),
        ),
        Container(width: 2, color: Colors.white24),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildAspectCorrectTexture(rightTid),
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
    final pipW = widget.pipWidth;
    final pipH = widget.pipHeight;

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
              border: Border.all(color: const Color(0xFF00D4AA), width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
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

  /// Wraps a texture in ClipRect + FittedBox(fit: BoxFit.cover) to preserve
  /// native 1080x1920 sensor geometry without squishing or stretching.
  Widget _buildAspectCorrectTexture(int textureId) {
    final isBack = widget.session.backTextureId != null &&
        textureId == widget.session.backTextureId;
    final rawW = isBack
        ? (widget.session.backBufferWidth ??
            widget.session.frontBufferWidth ??
            1080)
        : (widget.session.frontBufferWidth ?? 1080);
    final rawH = isBack
        ? (widget.session.backBufferHeight ??
            widget.session.frontBufferHeight ??
            1920)
        : (widget.session.frontBufferHeight ?? 1920);

    // In portrait presentation, maintain minor axis width and major axis height
    final nativeW = (rawW < rawH ? rawW : rawH).toDouble();
    final nativeH = (rawW > rawH ? rawW : rawH).toDouble();

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        alignment: Alignment.center,
        child: SizedBox(
          width: nativeW,
          height: nativeH,
          child: Texture(textureId: textureId),
        ),
      ),
    );
  }

  Widget _buildStreamBadge(String label, Alignment alignment, {bool isMini = false}) {
    return Align(
      alignment: alignment,
      child: Container(
        margin: EdgeInsets.all(isMini ? 4 : 12),
        padding: EdgeInsets.symmetric(horizontal: isMini ? 6 : 8, vertical: isMini ? 2 : 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: label == 'FRONT' ? const Color(0xFF6C63FF) : const Color(0xFF00D4AA),
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
