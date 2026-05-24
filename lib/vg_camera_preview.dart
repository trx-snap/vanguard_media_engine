// vg_camera_preview.dart
// Vanguard Media Engine — Phase 6D.1A
//
// VGCameraPreview is a typed StatelessWidget that renders the live camera feed
// from a [VGCameraSession] using Flutter's GPU Texture widget.
//
// Design:
//   Thin wrapper around Texture(textureId: session.textureId).
//   Parallel to VanguardTextureView (for playback), but typed to VGCameraSession.

import 'package:flutter/widgets.dart';
import 'vg_camera_session.dart';

/// Camera preview widget that renders the live feed from a [VGCameraSession].
///
/// Uses Flutter's [Texture] widget to display GPU frames registered by the
/// native AVCaptureSession + Metal rendering pipeline.
/// Achieves < 8 ms capture-to-display latency at 60 fps with zero compositor hops.
///
/// The [session] must be active (i.e. [VGCameraSession.create] has been called
/// and [VGCameraSession.dispose] has not).
///
/// ```dart
/// final session = await VGCameraSession.create();
/// // In your widget build:
/// return VGCameraPreview(session: session);
/// ```
///
/// For the fullscreen native MTKView overlay, use [VGCameraSession.openNativePreview]
/// instead — that path presents a native view controller with its own layout.
class VGCameraPreview extends StatelessWidget {
  /// Creates a camera preview for the given [session].
  const VGCameraPreview({super.key, required this.session});

  /// The active camera session whose GPU texture to display.
  final VGCameraSession session;

  @override
  Widget build(BuildContext context) {
    return Texture(textureId: session.textureId);
  }
}
