// vanguard_channel_dispatcher.dart
// Vanguard Media Engine — MethodChannel Router
//
// Package-level singleton that is the SOLE production owner of:
//   MethodChannel('vanguard_media_engine').setMethodCallHandler(...)
//
// Architecture:
//   Native callbacks
//   → VanguardChannelDispatcher (one permanent handler, registered once)
//   → typed, ownership-safe subscription tokens
//   → session-specific or engine-owned consumers
//
// Invariants:
//   - Only this file calls setMethodCallHandler in production code.
//   - The handler is registered lazily on first consumer registration.
//   - The handler is NEVER cleared during ordinary consumer disposal.
//   - All numeric payloads parsed through `num` (never direct `as double?`).
//   - Unknown callbacks are silently dropped.
//   - Malformed payloads are silently dropped (no throw in production).
//
// Export concurrency note:
//   exportTimeline has no native single-export guard. Concurrent exports
//   may both execute on native. The most recent export registration receives
//   shared onExportProgress events; older export Futures complete via
//   their result() callbacks regardless.
//
// Lifecycle:
//   - Singleton exists for the Dart isolate lifetime.
//   - Hot restart resets all static state naturally.
//   - Consumers must unregister their tokens in their dispose().

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

// ── Typedefs ──────────────────────────────────────────────────────────────────

/// Callback type for timeline frame PTS updates.
typedef VGTimelineFrameCallback = void Function(double pts);

/// Callback type for timeline end-of-stream.
typedef VGTimelineEOSCallback = void Function();

// ── Subscription tokens ───────────────────────────────────────────────────────
//
// All token classes are in this library so that the dispatcher can access
// the private `_token` field for stale-token checking.

/// Subscription token for timeline callbacks (onTimelineFrame, onTimelineEOS).
///
/// Keyed by [textureId]. Unregister via
/// [VanguardChannelDispatcher.unregisterTimelineListener].
final class VGTimelineSubscription {
  final int textureId;
  final Object _token;
  VGTimelineSubscription._(this.textureId, this._token);
}

/// Subscription token for export progress callbacks.
///
/// Single-slot global. Unregister via
/// [VanguardChannelDispatcher.unregisterExportListener].
final class VGExportSubscription {
  final Object _token;
  VGExportSubscription._(this._token);
}

/// Subscription token for playback-completion callbacks.
///
/// Single-slot global, owned by the current [VanguardEngine].
/// Unregister via [VanguardChannelDispatcher.unregisterPlaybackCompleteListener].
final class VGPlaybackCompleteSubscription {
  final Object _token;
  VGPlaybackCompleteSubscription._(this._token);
}

/// Subscription token for node duration-probed callbacks.
///
/// Single-slot global, owned by the current [VanguardEngine].
/// Unregister via [VanguardChannelDispatcher.unregisterDurationProbedListener].
final class VGDurationProbedSubscription {
  final Object _token;
  VGDurationProbedSubscription._(this._token);
}

/// Subscription token for thermal state callbacks.
///
/// Single-slot global, self-registered by [VGThermalMonitor].
/// Unregister via [VanguardChannelDispatcher.unregisterThermalStateListener].
final class VGThermalSubscription {
  final Object _token;
  VGThermalSubscription._(this._token);
}

// ── Internal storage types ────────────────────────────────────────────────────

class _TimelineEntry {
  final Object token;
  final VGTimelineFrameCallback onFrame;
  final VGTimelineEOSCallback onEOS;
  _TimelineEntry({
    required this.token,
    required this.onFrame,
    required this.onEOS,
  });
}

// ── Dispatcher ────────────────────────────────────────────────────────────────

/// The package-level singleton MethodChannel callback router.
///
/// Owns the single `setMethodCallHandler` registration on the
/// `vanguard_media_engine` MethodChannel. All other production code must
/// use the typed subscription APIs below.
///
/// ## Handler registration
///
/// The handler is registered lazily on the first consumer call to any
/// `register*` method via [ensureHandlerRegistered]. It is never cleared.
///
/// ## Subscription semantics
///
/// | Category           | Slot policy    | Identity key |
/// |--------------------|----------------|--------------|
/// | Timeline           | Per textureId  | textureId    |
/// | Export progress    | Single-slot    | token        |
/// | Playback complete  | Single-slot    | token        |
/// | Duration probed    | Single-slot    | token        |
/// | Thermal state      | Single-slot    | token        |
///
/// Stale-token unregister is always a no-op.
final class VanguardChannelDispatcher {
  VanguardChannelDispatcher._();

  /// The singleton instance. Stable for the Dart isolate lifetime.
  static final VanguardChannelDispatcher instance =
      VanguardChannelDispatcher._();

  // ── Channel ────────────────────────────────────────────────────────────────

  MethodChannel _channel = const MethodChannel('vanguard_media_engine');
  bool _handlerRegistered = false;

  // ── Storage ────────────────────────────────────────────────────────────────

  // Timeline: keyed by textureId.
  final Map<int, _TimelineEntry> _timelineListeners = {};

  // Export progress: single-slot.
  void Function(double progress)? _exportProgressCallback;
  Object? _exportProgressToken;

  // Playback completion: single-slot.
  void Function(int textureId)? _playbackCompleteCallback;
  Object? _playbackCompleteToken;

  // Duration probed: single-slot.
  void Function(String path, double duration)? _durationProbedCallback;
  Object? _durationProbedToken;

  // Thermal state: single-slot.
  void Function(int rawValue)? _thermalStateCallback;
  Object? _thermalStateToken;

  // ── Handler registration ───────────────────────────────────────────────────

  /// Ensures the global MethodChannel handler is registered.
  ///
  /// Idempotent — subsequent calls are no-ops.
  /// Called automatically by all `register*` methods.
  void ensureHandlerRegistered() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler(_handleNativeCallback);
  }

  // ── Native callback dispatch ───────────────────────────────────────────────

  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    switch (call.method) {
      case 'onTimelineFrame':
        _dispatchTimelineFrame(call.arguments);
        break;

      case 'onTimelineEOS':
        _dispatchTimelineEOS(call.arguments);
        break;

      case 'onExportProgress':
        // Payload: bare num (Double on iOS, Double on Android).
        final progress = (call.arguments as num?)?.toDouble();
        if (progress != null) {
          _exportProgressCallback?.call(progress.clamp(0.0, 1.0));
        }
        break;

      case 'onPlaybackComplete':
        // Payload: {textureId: num} (added by dispatcher slice).
        final args = call.arguments as Map?;
        final textureId = (args?['textureId'] as num?)?.toInt();
        if (textureId != null) {
          _playbackCompleteCallback?.call(textureId);
        }
        break;

      case 'onNodeDurationProbed':
        // Payload: {path: String, duration: num}.
        final args = call.arguments as Map?;
        final path = args?['path'] as String?;
        final duration = (args?['duration'] as num?)?.toDouble();
        if (path != null && duration != null) {
          _durationProbedCallback?.call(path, duration);
        }
        break;

      case 'onThermalStateChanged':
        // Payload: bare num (Int on iOS, Int on Android).
        final rawValue = (call.arguments as num?)?.toInt();
        if (rawValue != null) {
          _thermalStateCallback?.call(rawValue);
        }
        break;

      // Unknown callbacks are silently dropped — forward compatibility.
    }
  }

  void _dispatchTimelineFrame(dynamic arguments) {
    final args = arguments as Map?;
    final textureId = (args?['textureId'] as num?)?.toInt();
    final pts = (args?['pts'] as num?)?.toDouble();
    if (textureId == null || pts == null) return; // malformed — drop silently

    final entry = _timelineListeners[textureId];
    entry?.onFrame(pts);
  }

  void _dispatchTimelineEOS(dynamic arguments) {
    final args = arguments as Map?;
    final textureId = (args?['textureId'] as num?)?.toInt();
    if (textureId == null) return; // malformed — drop silently

    final entry = _timelineListeners[textureId];
    entry?.onEOS();
  }

  // ── Timeline registration ──────────────────────────────────────────────────

  /// Registers a timeline callback pair for [textureId].
  ///
  /// If a registration already exists for [textureId], it is replaced and
  /// a debug diagnostic is emitted.
  ///
  /// Returns a [VGTimelineSubscription] that must be passed to
  /// [unregisterTimelineListener] when the consumer is disposed.
  VGTimelineSubscription registerTimelineListener({
    required int textureId,
    required VGTimelineFrameCallback onFrame,
    required VGTimelineEOSCallback onEOS,
  }) {
    ensureHandlerRegistered();

    if (_timelineListeners.containsKey(textureId)) {
      assert(() {
        // ignore: avoid_print
        print(
          '[VanguardChannelDispatcher] registerTimelineListener: '
          'replacing existing registration for textureId=$textureId',
        );
        return true;
      }());
    }

    final token = Object();
    _timelineListeners[textureId] = _TimelineEntry(
      token: token,
      onFrame: onFrame,
      onEOS: onEOS,
    );
    return VGTimelineSubscription._(textureId, token);
  }

  /// Unregisters a timeline subscription.
  ///
  /// Stale or already-unregistered tokens are safe no-ops.
  void unregisterTimelineListener(VGTimelineSubscription subscription) {
    final entry = _timelineListeners[subscription.textureId];
    if (entry != null && identical(entry.token, subscription._token)) {
      _timelineListeners.remove(subscription.textureId);
    }
    // Stale token: no-op.
  }

  // ── Export progress registration ──────────────────────────────────────────

  /// Registers an export progress listener.
  ///
  /// Single-slot: replaces any existing registration.
  /// A stale token cannot unregister a newer callback.
  VGExportSubscription registerExportListener(
    void Function(double progress) onProgress,
  ) {
    ensureHandlerRegistered();
    final token = Object();
    _exportProgressCallback = onProgress;
    _exportProgressToken = token;
    return VGExportSubscription._(token);
  }

  /// Unregisters an export listener.
  ///
  /// Stale tokens are safe no-ops.
  void unregisterExportListener(VGExportSubscription subscription) {
    if (identical(_exportProgressToken, subscription._token)) {
      _exportProgressCallback = null;
      _exportProgressToken = null;
    }
  }

  // ── Playback-completion registration ──────────────────────────────────────

  /// Registers a playback-completion listener.
  ///
  /// Single-slot: new registration replaces the old callback and token.
  VGPlaybackCompleteSubscription registerPlaybackCompleteListener(
    void Function(int textureId) listener,
  ) {
    ensureHandlerRegistered();
    final token = Object();
    _playbackCompleteCallback = listener;
    _playbackCompleteToken = token;
    return VGPlaybackCompleteSubscription._(token);
  }

  /// Unregisters a playback-completion listener.
  ///
  /// Stale tokens are safe no-ops (e.g. old engine unregisters after new engine registered).
  void unregisterPlaybackCompleteListener(
    VGPlaybackCompleteSubscription subscription,
  ) {
    if (identical(_playbackCompleteToken, subscription._token)) {
      _playbackCompleteCallback = null;
      _playbackCompleteToken = null;
    }
  }

  // ── Duration-probed registration ──────────────────────────────────────────

  /// Registers a node duration-probed listener.
  ///
  /// Single-slot: new registration replaces the old callback and token.
  VGDurationProbedSubscription registerDurationProbedListener(
    void Function(String path, double duration) listener,
  ) {
    ensureHandlerRegistered();
    final token = Object();
    _durationProbedCallback = listener;
    _durationProbedToken = token;
    return VGDurationProbedSubscription._(token);
  }

  /// Unregisters a duration-probed listener.
  ///
  /// Stale tokens are safe no-ops.
  void unregisterDurationProbedListener(
    VGDurationProbedSubscription subscription,
  ) {
    if (identical(_durationProbedToken, subscription._token)) {
      _durationProbedCallback = null;
      _durationProbedToken = null;
    }
  }

  // ── Thermal state registration ────────────────────────────────────────────

  /// Registers a thermal state listener.
  ///
  /// Single-slot: new registration replaces the old callback and token.
  /// Intended for [VGThermalMonitor] self-registration only.
  VGThermalSubscription registerThermalStateListener(
    void Function(int rawValue) listener,
  ) {
    ensureHandlerRegistered();
    final token = Object();
    _thermalStateCallback = listener;
    _thermalStateToken = token;
    return VGThermalSubscription._(token);
  }

  /// Unregisters a thermal state listener.
  ///
  /// Stale tokens are safe no-ops.
  void unregisterThermalStateListener(VGThermalSubscription subscription) {
    if (identical(_thermalStateToken, subscription._token)) {
      _thermalStateCallback = null;
      _thermalStateToken = null;
    }
  }

  // ── Testing seam ──────────────────────────────────────────────────────────

  /// Resets all dispatcher state. **Test-only — never call in production.**
  ///
  /// Clears all registered listeners, tokens, and the handler-registration
  /// flag. Optionally injects a test [MethodChannel].
  @visibleForTesting
  void resetForTesting({MethodChannel? channel}) {
    _timelineListeners.clear();
    _exportProgressCallback = null;
    _exportProgressToken = null;
    _playbackCompleteCallback = null;
    _playbackCompleteToken = null;
    _durationProbedCallback = null;
    _durationProbedToken = null;
    _thermalStateCallback = null;
    _thermalStateToken = null;
    _handlerRegistered = false;
    _channel = channel ?? const MethodChannel('vanguard_media_engine');
  }

  /// Whether the handler has been registered. **Test-only.**
  @visibleForTesting
  bool get isHandlerRegistered => _handlerRegistered;

  /// Whether a timeline listener is registered for [textureId]. **Test-only.**
  @visibleForTesting
  bool hasTimelineListenerForTesting(int textureId) =>
      _timelineListeners.containsKey(textureId);

  /// Whether an export progress listener is currently registered. **Test-only.**
  @visibleForTesting
  bool get hasExportListenerForTesting => _exportProgressCallback != null;
}
