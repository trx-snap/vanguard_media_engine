// vg_timeline_live_controls.dart
// Vanguard Media Engine — Audio Track Interaction Programme S-P1
//
// Timeline-scoped live filter-chain API.
//
// Design rules:
//   - Stateless: no lifecycle, texture, or filter-chain state stored here.
//   - Platform-neutral: API shape is Android-compatible.
//   - Dart-only validation: assertValid() + toJson() before channel dispatch.
//   - Negative textureId is rejected before dispatch, even in release mode.
//   - The native side owns filter-type authority; UNKNOWN_FILTER propagates as-is.
//
// Route: timeline_setFilterChain

import 'package:flutter/services.dart';

import 'vg_filter_spec.dart';

/// Timeline-scoped live filter-chain control for a [VGEditorController]-backed
/// normal preview.
///
/// Applies a new filter chain to the currently active timeline identified by
/// [textureId] **without** rebuilding the timeline, resetting the playhead, or
/// pausing playback. This is a fire-and-confirm API: success is returned once
/// the request has been validated and enqueued through the thread-safe native
/// runtime; it does not wait for the next rendered frame.
///
/// ## Usage
///
/// ```dart
/// final controls = VGTimelineLiveControls();
/// await controls.setFilterChain(
///   textureId: activeTextureId,
///   filters: [VGFilterSpecs.lut(intensity: 0.8)],
/// );
/// // Clear filters:
/// await controls.setFilterChain(textureId: activeTextureId, filters: []);
/// ```
///
/// ## Error codes (PlatformException)
///
/// - `INVALID_ARG`    — negative [textureId] or malformed filters payload.
/// - `NO_TIMELINE`    — no current timeline target on the native side.
/// - `STALE_TIMELINE` — [textureId] does not match the active timeline target.
/// - `UNKNOWN_FILTER` — a filter type is not recognised by the native runtime.
///
/// ## Lifecycle
///
/// This class stores no state. Create instances freely; they are cheap.
final class VGTimelineLiveControls {
  // ── Channel ────────────────────────────────────────────────────────────────

  /// The MethodChannel used to communicate with the native plugin.
  ///
  /// Defaults to `'vanguard_media_engine'` — the same channel used by all
  /// other Vanguard APIs. An alternate channel may be injected for testing.
  final MethodChannel _channel;

  // ── Constructor ────────────────────────────────────────────────────────────

  /// Creates a [VGTimelineLiveControls] instance.
  ///
  /// [channel] defaults to the shared `'vanguard_media_engine'` channel.
  /// Inject an alternate channel only in tests.
  VGTimelineLiveControls({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('vanguard_media_engine');

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Applies a new filter chain to the active timeline identified by
  /// [textureId].
  ///
  /// Each filter in [filters] is validated with [VGFilterSpec.assertValid] and
  /// serialised with [VGFilterSpec.toJson] before dispatch. An empty [filters]
  /// list clears the timeline's filter chain.
  ///
  /// [textureId] must be non-negative. A negative value throws a
  /// [PlatformException] with code `INVALID_ARG` before any channel call is
  /// made — this guard is active in both debug and release builds.
  ///
  /// Native [PlatformException]s propagate to the caller unchanged.
  ///
  /// Throws [PlatformException] with code:
  /// - `INVALID_ARG`    — [textureId] is negative.
  /// - `NO_TIMELINE`    — no active timeline on the native side.
  /// - `STALE_TIMELINE` — [textureId] does not match the active timeline.
  /// - `UNKNOWN_FILTER` — a filter type is not recognised by the native runtime.
  Future<void> setFilterChain({
    required int textureId,
    required List<VGFilterSpec> filters,
  }) async {
    // Release-mode guard: reject negative textureId before touching the channel.
    if (textureId < 0) {
      throw PlatformException(
        code: 'INVALID_ARG',
        message:
            'VGTimelineLiveControls.setFilterChain: textureId must be '
            'non-negative, got $textureId.',
      );
    }

    // Debug-mode validation: assertValid() is a no-op in release builds.
    for (final filter in filters) {
      filter.assertValid();
    }

    await _channel.invokeMethod<void>('timeline_setFilterChain', {
      'textureId': textureId,
      'filters': List<Map<String, Object?>>.unmodifiable(
        filters.map((f) => f.toJson()).toList(),
      ),
    });
  }
}
