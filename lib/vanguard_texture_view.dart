import 'package:flutter/material.dart';
import 'vanguard_media_engine.dart';

/// A Flutter widget that renders a Vanguard GPU texture.
///
/// Usage:
/// ```dart
/// final engine = VanguardEngine();
/// final info = await engine.createVideoTexture('/path/to/video.mp4', startTime: 0.0);
///
/// // In your widget tree:
/// VanguardTextureView(
///   engine: engine,
///   textureId: info.textureId,
///   renderWidth:  info.width,
///   renderHeight: info.height,
///   autoPlay: true,
/// )
/// ```
class VanguardTextureView extends StatefulWidget {
  final VanguardEngine engine;
  final int textureId;
  final BoxFit fit;
  final bool autoPlay;
  final VoidCallback? onPlaybackComplete;

  /// Actual display dimensions of the video, returned by [VanguardEngine.createVideoTexture].
  /// These are post-preferredTransform dimensions:
  ///   - portrait .mov → width < height  (e.g. 1080 × 1920)
  ///   - landscape .mp4 → width > height (e.g. 1920 × 1080)
  /// Defaults to 1080 × 1920 (portrait) for backward compatibility.
  final int renderWidth;
  final int renderHeight;

  const VanguardTextureView({
    super.key,
    required this.engine,
    required this.textureId,
    this.fit = BoxFit.cover,
    this.autoPlay = false,
    this.onPlaybackComplete,
    this.renderWidth  = 1080,
    this.renderHeight = 1920,
  });

  @override
  State<VanguardTextureView> createState() => _VanguardTextureViewState();
}

class _VanguardTextureViewState extends State<VanguardTextureView> {
  @override
  void initState() {
    super.initState();

    // Wire playback-complete callback so the story viewer can auto-advance
    widget.engine.onPlaybackComplete = (id) {
      if (id == widget.textureId) {
        widget.onPlaybackComplete?.call();
      }
    };

    if (widget.autoPlay) {
      widget.engine.play(widget.textureId);
    }
  }

  @override
  void dispose() {
    widget.engine.disposeTexture(widget.textureId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isPortrait = widget.renderHeight > widget.renderWidth;
    return SizedBox.expand(
      child: FittedBox(
        fit: isPortrait ? BoxFit.cover : BoxFit.contain,
        child: SizedBox(
          // Use actual render dimensions from native so FittedBox scales with the
          // correct aspect ratio. Landscape video (e.g. 1920×1080) was previously
          // forced into a 1080×1920 portrait SizedBox, squishing it horizontally.
          width:  widget.renderWidth.toDouble(),
          height: widget.renderHeight.toDouble(),
          child: Texture(textureId: widget.textureId),
        ),
      ),
    );
  }
}
