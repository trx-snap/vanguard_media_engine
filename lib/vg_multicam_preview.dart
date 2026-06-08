// vg_multicam_preview.dart
// Vanguard Media Engine — MC-22
//
// VGMultiCamPreview is a typed StatelessWidget that renders the composited
// dual-camera live feed from a [VGMultiCamRenderTextureSession] using Flutter's
// GPU Texture widget.
//
// Design:
//   Thin wrapper around Texture(textureId: session.textureId).
//   Parallel to VGCameraPreview (single-camera), but typed to the MultiCam
//   session returned by VGCameraSession.startMultiCamPreview.

import 'package:flutter/widgets.dart';
import 'vg_camera_session.dart';

/// MultiCam preview widget that renders the composited dual-camera feed from
/// a [VGMultiCamRenderTextureSession].
///
/// Uses Flutter's [Texture] widget to display GPU frames produced by the
/// native [VanguardMultiCamRenderer] CoreImage compositor pipeline.
///
/// The [session] must be active (i.e. [VGCameraSession.startMultiCamPreview]
/// has been called and [VGCameraSession.stopMultiCamPreview] has not).
///
/// ```dart
/// final session = await VGCameraSession.startMultiCamPreview(
///   frontDeviceId: frontId,
///   backDeviceId: backId,
/// );
/// if (session != null) {
///   // In your widget build:
///   return AspectRatio(
///     aspectRatio: session.outputWidth > 0 && session.outputHeight > 0
///         ? session.outputWidth / session.outputHeight
///         : 9.0 / 16.0,
///     child: VGMultiCamPreview(session: session),
///   );
/// }
/// ```
///
/// ## Orientation
/// The composited buffer is already portrait-correct and mirrored per camera
/// side (front mirrored, back not mirrored). No additional orientation
/// transform is needed.
class VGMultiCamPreview extends StatelessWidget {
  /// Creates a MultiCam preview for the given [session].
  const VGMultiCamPreview({super.key, required this.session});

  /// The active MultiCam render session whose GPU texture to display.
  final VGMultiCamRenderTextureSession session;

  @override
  Widget build(BuildContext context) {
    return Texture(textureId: session.textureId);
  }
}
