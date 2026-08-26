// Copyright (c) Connects — Vanguard Phase 7.8C.
// Public editor texture presentation view widget.
//
// Pure presentation widget that renders the timeline texture from VGEditorValue
// and preserves the reported editor render dimensions / aspect ratio.
//
// Note: This widget is presentation-only: it does NOT own playback lifecycle,
// invoke platform channels, mutate controller state, start/stop timelines,
// force product fit policy, or dispose native texture resources.

import 'package:flutter/material.dart';

import 'vg_editor_value.dart';

/// A lightweight, presentation-only Flutter widget that renders an editor
/// timeline texture from [VGEditorValue].
///
/// Automatically scales and positions the presentation surface using [FittedBox],
/// preserving the reported aspect ratio from native render dimensions
/// ([VGEditorValue.renderWidth] / [VGEditorValue.renderHeight]), falling back to
/// draft canvas dimensions ([VGEditorValue.draft.canvasWidth] / [VGEditorValue.draft.canvasHeight]),
/// [fallbackSize], or 16:9 when dimensions are unavailable or non-positive.
class VGEditorTextureView extends StatelessWidget {
  /// The current immutable editor state snapshot from [VGEditorController].
  final VGEditorValue value;

  /// How the texture should be inscribed into the box. Defaults to [BoxFit.contain].
  final BoxFit fit;

  /// How to align the texture within the bounds. Defaults to [Alignment.center].
  final Alignment alignment;

  /// The background color filling letterboxing / pillarboxing or empty texture states.
  /// Defaults to [Colors.black].
  final Color backgroundColor;

  /// Optional builder invoked when [value.textureId] is null.
  final WidgetBuilder? placeholderBuilder;

  /// Fallback aspect ratio dimensions used when native render dimensions and draft canvas
  /// dimensions are unavailable or non-positive. Defaults to 16:9 ([Size(16, 9)]).
  final Size fallbackSize;

  /// Whether to clip content overflowing the widget boundary. Defaults to `true`.
  final bool clip;

  const VGEditorTextureView({
    super.key,
    required this.value,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.backgroundColor = Colors.black,
    this.placeholderBuilder,
    this.fallbackSize = const Size(16, 9),
    this.clip = true,
  });

  @override
  Widget build(BuildContext context) {
    final textureId = value.textureId;
    if (textureId == null) {
      if (placeholderBuilder != null) {
        return placeholderBuilder!(context);
      }
      return SizedBox.expand(child: ColoredBox(color: backgroundColor));
    }

    final double sourceWidth;
    final double sourceHeight;

    final rw = value.renderWidth;
    final rh = value.renderHeight;
    final cw = value.draft.canvasWidth;
    final ch = value.draft.canvasHeight;

    if (rw != null && rh != null && rw > 0 && rh > 0) {
      sourceWidth = rw.toDouble();
      sourceHeight = rh.toDouble();
    } else if (cw > 0 && ch > 0) {
      sourceWidth = cw.toDouble();
      sourceHeight = ch.toDouble();
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
