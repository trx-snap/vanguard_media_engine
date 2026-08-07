// vg_timeline_audio_mix_controls.dart
// Vanguard Media Engine — V-B1/V-B2: Per-track live mix-gain controls.
//
// Sends live mix-gain updates to the native VanguardAudioPreviewRuntime for the
// timeline identified by [textureId]. Updates take effect immediately in the
// audio preview pipeline without rebuilding the timeline or calling updateDraft.
//
// Contract:
//   - [gain] must be in [0.0, 1.0]. Values outside that range are clamped.
//   - [textureId] must be non-negative. A negative value throws [ArgumentError].
//   - [trackId] must be non-empty.
//   - Returns normally on success (native returns nil / null).
//   - Throws [PlatformException] on native-side error (STALE_TIMELINE,
//     NO_TIMELINE, INVALID_ARG). Callers at commit/open/cancel boundaries must
//     handle these. Live-drag callers may ignore them.
//   - Calling when no timeline runtime is active returns NO_TIMELINE; callers
//     during teardown should catch and ignore this error.
//
// Wire format (MethodChannel 'vanguard_media_engine', method
// 'timeline_setAudioMixGain'):
//   { 'textureId': Int64, 'trackId': String, 'gain': double }

import 'package:flutter/services.dart';

/// Sends live per-track mix-gain updates to the native audio preview runtime.
///
/// Safe to call from any isolate; dispatches to the audio scheduler queue
/// on the native side without blocking the Flutter UI thread.
final class VGTimelineAudioMixControls {
  const VGTimelineAudioMixControls();

  static const _channel = MethodChannel('vanguard_media_engine');

  /// Sets the live mix-gain for [trackId] to [gain] on the timeline identified
  /// by [textureId].
  ///
  /// [textureId] must be non-negative. [gain] is clamped to [0.0, 1.0].
  /// [trackId] must be non-empty. Throws [PlatformException] on
  /// STALE_TIMELINE, NO_TIMELINE, or INVALID_ARG.
  Future<void> setMixGain({
    required int textureId,
    required String trackId,
    required double gain,
  }) async {
    assert(textureId >= 0, 'VGTimelineAudioMixControls: textureId must be non-negative');
    assert(trackId.isNotEmpty, 'VGTimelineAudioMixControls: trackId must be non-empty');

    final clampedGain = gain.clamp(0.0, 1.0);

    await _channel.invokeMethod<void>('timeline_setAudioMixGain', {
      'textureId': textureId,
      'trackId': trackId,
      'gain': clampedGain,
    });
  }
}
