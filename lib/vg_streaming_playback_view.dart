// Copyright (c) Connects — Vanguard Phase 4C7Q.
// Public streaming playback texture view widget.
//
// Pure presentation widget that renders the controller/session texture from
// VGStreamingPlaybackControllerSnapshot and preserves the video aspect ratio.
// This widget is presentation-only: it does NOT own playback lifecycle,
// invoke platform channels, start/stop sessions, preflight streams, apply filters,
// force ABR, interpret product policy, or correct native rotation metadata.

import 'package:flutter/material.dart';

import 'vg_streaming_playback_controller.dart';

/// Signature for a builder function that returns a custom widget when no texture is available.
typedef VGStreamingPlaybackPlaceholderBuilder =
    Widget Function(
      BuildContext context,
      VGStreamingPlaybackControllerSnapshot snapshot,
    );

/// Signature for a builder function that returns a custom widget when playback failed or is unsupported.
typedef VGStreamingPlaybackErrorBuilder =
    Widget Function(
      BuildContext context,
      VGStreamingPlaybackControllerSnapshot snapshot,
    );

/// A lightweight, presentation-only Flutter widget that renders a streaming
/// video texture from [VGStreamingPlaybackControllerSnapshot].
///
/// Automatically scales and centers the presentation surface using [FittedBox],
/// preserving the reported aspect ratio from the underlying session dimensions
/// (or [fallbackSize] when dimensions are unavailable or non-positive).
class VGStreamingPlaybackTextureView extends StatelessWidget {
  /// The current immutable snapshot from [VGStreamingPlaybackController].
  final VGStreamingPlaybackControllerSnapshot snapshot;

  /// How the texture should be inscribed into the box. Defaults to [BoxFit.contain].
  final BoxFit fit;

  /// How to align the texture within the bounds. Defaults to [Alignment.center].
  final Alignment alignment;

  /// The background color filling letterboxing / pillarboxing or empty texture states.
  /// Defaults to [Colors.black].
  final Color backgroundColor;

  /// Optional builder invoked when [snapshot.textureId] is null and no error condition is matched.
  final VGStreamingPlaybackPlaceholderBuilder? placeholderBuilder;

  /// Optional builder invoked when [snapshot.state] is [VGStreamingPlaybackControllerState.failed]
  /// or [VGStreamingPlaybackControllerState.unsupported].
  final VGStreamingPlaybackErrorBuilder? errorBuilder;

  /// Fallback aspect ratio dimensions used when the active session does not report positive dimensions.
  /// Defaults to 16:9 (Size(16, 9)).
  final Size fallbackSize;

  /// Whether to clip content overflowing the widget boundary. Defaults to `true`.
  final bool clip;

  const VGStreamingPlaybackTextureView({
    super.key,
    required this.snapshot,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.backgroundColor = Colors.black,
    this.placeholderBuilder,
    this.errorBuilder,
    this.fallbackSize = const Size(16, 9),
    this.clip = true,
  });

  @override
  Widget build(BuildContext context) {
    if ((snapshot.state == VGStreamingPlaybackControllerState.failed ||
            snapshot.state == VGStreamingPlaybackControllerState.unsupported) &&
        errorBuilder != null) {
      return errorBuilder!(context, snapshot);
    }

    final textureId = snapshot.textureId;
    if (textureId == null) {
      if (placeholderBuilder != null) {
        return placeholderBuilder!(context, snapshot);
      }
      return SizedBox.expand(child: ColoredBox(color: backgroundColor));
    }

    final session = snapshot.session;
    final double sourceWidth;
    final double sourceHeight;

    if (session != null && session.videoWidth > 0 && session.videoHeight > 0) {
      sourceWidth = session.videoWidth.toDouble();
      sourceHeight = session.videoHeight.toDouble();
    } else if (fallbackSize.width > 0 && fallbackSize.height > 0) {
      sourceWidth = fallbackSize.width;
      sourceHeight = fallbackSize.height;
    } else {
      sourceWidth = 16.0;
      sourceHeight = 9.0;
    }

    Widget content = SizedBox.expand(
      child: ColoredBox(
        color: backgroundColor,
        child: FittedBox(
          fit: fit,
          alignment: alignment,
          child: SizedBox(
            width: sourceWidth,
            height: sourceHeight,
            child: Texture(textureId: textureId),
          ),
        ),
      ),
    );

    if (clip) {
      content = ClipRect(child: content);
    }

    return content;
  }
}
