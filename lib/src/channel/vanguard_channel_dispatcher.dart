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
//   Android's exportTimeline/exportPassthroughRemux routes share a single
//   native export lock (AndroidEditorExportCoordinator): a concurrent second
//   call is rejected with EXPORT_IN_PROGRESS rather than running in parallel.
//   Export progress listeners are a LIFO stack (see below), not a
//   single-slot: a nested exportDraft(onProgress:) call temporarily takes
//   over onExportProgress delivery and its own unregister restores whichever
//   listener was registered before it (e.g. a VanguardEngine.onExportProgress
//   consumer), rather than clobbering it.
//
// Lifecycle:
//   - Singleton exists for the Dart isolate lifetime.
//   - Hot restart resets all static state naturally.
//   - Consumers must unregister their tokens in their dispose().

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

// ── Typedefs ──────────────────────────────────────────────────────────────────

/// Callback type for timeline frame PTS updates.
/// [generation] mirrors the native generation counter sent by the compositor;
/// consumers use it to discard frames that belong to superseded seek requests.
typedef VGTimelineFrameCallback = void Function(double pts, int generation);

/// Callback type for timeline end-of-stream.
typedef VGTimelineEOSCallback = void Function();

/// Callback type for timeline audio readiness updates (Phase 10F Slice 3).
///
/// Delivered for `onTimelineAudioStateChanged`. [textureId] is the texture the
/// event was emitted for (always equal to the registration key),
/// [prepareSessionId] is the native monotonic prepare-session id echoed from
/// the `createTimelineTexture` / `updateTimeline` result map, and [state] is
/// the raw native state string (`ready`, `silent`, or `failed`). Consumers
/// must drop events whose textureId/prepareSessionId do not match their
/// current state.
typedef VGTimelineAudioStateCallback =
    void Function(int textureId, int prepareSessionId, String state);

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
/// LIFO stack — see [VanguardChannelDispatcher] class docs. Unregister via
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

/// Subscription token for iOS PhotoKit iCloud video download progress
/// callbacks (`onPhotoVideoDownloadProgress`).
///
/// Keyed by PhotoKit [assetId] (localIdentifier). Unregister via
/// [VanguardChannelDispatcher.unregisterPhotoVideoDownloadProgressListener].
/// Public consumers should go through the `vg_photo_video_download_progress`
/// library rather than the dispatcher directly.
final class VGPhotoVideoDownloadProgressSubscription {
  final String assetId;
  final Object _token;
  VGPhotoVideoDownloadProgressSubscription._(this.assetId, this._token);
}

/// Subscription token for Duet green-screen degradation event callbacks
/// (`onDuetEvent`).
///
/// Multi-listener: any number of live subscriptions may exist at once, each
/// independently unregistered via
/// [VanguardChannelDispatcher.unregisterDuetEventListener]. Public consumers
/// should go through the `vg_duet` barrel (`VGDuetEvents.stream`) rather than
/// the dispatcher directly.
final class VGDuetEventSubscription {
  final Object _token;
  VGDuetEventSubscription._(this._token);
}

/// Subscription token for generic live green-screen event callbacks
/// (`onLiveGreenScreenEvent`).
///
/// Multi-listener and independent of [VGDuetEventSubscription]. Public
/// consumers should go through the `vg_live_green_screen` barrel
/// (`VGLiveGreenScreenEvents.stream`) rather than the dispatcher directly.
final class VGLiveGreenScreenEventSubscription {
  final Object _token;
  VGLiveGreenScreenEventSubscription._(this._token);
}

// ── Internal storage types ────────────────────────────────────────────────────

class _TimelineEntry {
  final Object token;
  final VGTimelineFrameCallback onFrame;
  final VGTimelineEOSCallback onEOS;
  final VGTimelineAudioStateCallback? onAudioStateChanged;
  _TimelineEntry({
    required this.token,
    required this.onFrame,
    required this.onEOS,
    this.onAudioStateChanged,
  });
}

/// A parsed `onTimelineAudioStateChanged` payload held while no timeline
/// listener is registered for its textureId (Phase 10F Slice 3).
class _PendingAudioState {
  final int prepareSessionId;
  final String state;
  const _PendingAudioState({
    required this.prepareSessionId,
    required this.state,
  });
}

class _ExportEntry {
  final Object token;
  final void Function(double progress) onProgress;
  _ExportEntry({required this.token, required this.onProgress});
}

class _PhotoVideoDownloadEntry {
  final Object token;
  final void Function(double progress) onProgress;
  _PhotoVideoDownloadEntry({required this.token, required this.onProgress});
}

class _DuetEventEntry {
  final Object token;
  final void Function(Map<dynamic, dynamic> payload) onEvent;
  _DuetEventEntry({required this.token, required this.onEvent});
}

class _LiveGreenScreenEventEntry {
  final Object token;
  final void Function(Map<dynamic, dynamic> payload) onEvent;
  _LiveGreenScreenEventEntry({required this.token, required this.onEvent});
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
/// | Category           | Slot policy      | Identity key |
/// |--------------------|------------------|--------------|
/// | Timeline           | Per textureId    | textureId    |
/// | Timeline audio     | Per textureId*   | textureId    |
/// | Export progress    | LIFO stack       | token        |
/// | Playback complete  | Single-slot      | token        |
/// | Duration probed    | Single-slot      | token        |
/// | Thermal state      | Single-slot      | token        |
/// | iCloud download    | Per assetId      | assetId      |
/// | Duet events         | Multi-listener   | token        |
/// | Live green screen   | Multi-listener   | token        |
///
/// Export progress is a stack rather than a single slot so that a
/// short-lived registration (e.g. a nested [VanguardTimelineExporter]
/// call made while a longer-lived listener such as [VanguardEngine]'s is
/// already registered) can temporarily take over delivery and, on its own
/// unregister, restore the listener that was registered before it —
/// instead of clobbering it permanently. Unregister removes only the entry
/// matching the given token (wherever it is in the stack); dispatch always
/// calls the top (most recently registered) entry.
///
/// *Timeline audio readiness (`onTimelineAudioStateChanged`, Phase 10F
/// Slice 3) is an optional callback on the timeline entry. While no timeline
/// listener is registered for a textureId, the latest event for that
/// textureId is buffered (last-value-wins, bounded) and drained into the next
/// registration; it is purged on unregister and on [resetForTesting].
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

  // Phase 10F Slice 3: audio readiness events that arrived for a textureId
  // with no registered listener. Last-value-wins per textureId, bounded to
  // [_kMaxPendingAudioStates] textureIds (oldest entry evicted). Drained on
  // the next registerTimelineListener for that textureId and purged on
  // unregister / resetForTesting.
  //
  // Native returns the video texture before audio finishes arming, so under
  // normal ordering the controller has registered before the audio event
  // arrives. This buffer covers the gap where the Dart result continuation
  // has not yet run (e.g. a slow microtask queue) so a readiness event is not
  // lost between the result reply and the registration.
  static const int _kMaxPendingAudioStates = 8;
  final Map<int, _PendingAudioState> _pendingAudioStates = {};

  // Export progress: LIFO stack — see class docs.
  final List<_ExportEntry> _exportProgressStack = [];

  // Playback completion: single-slot.
  void Function(int textureId)? _playbackCompleteCallback;
  Object? _playbackCompleteToken;

  // Duration probed: single-slot.
  void Function(String path, double duration)? _durationProbedCallback;
  Object? _durationProbedToken;

  // Thermal state: single-slot.
  void Function(int rawValue)? _thermalStateCallback;
  Object? _thermalStateToken;

  // iOS PhotoKit iCloud video download progress: keyed by assetId. Events
  // for an assetId with no registered listener are stale (the consumer has
  // already unregistered) and are dropped; nothing is buffered.
  final Map<String, _PhotoVideoDownloadEntry> _photoVideoDownloadListeners = {};

  // Duet events: multi-listener — every registered entry receives every
  // `onDuetEvent` payload. Unkeyed (Duet has a single active session at a
  // time; consumers filter by sessionId themselves if needed).
  final Map<Object, _DuetEventEntry> _duetEventListeners = {};

  // Live green-screen events: multi-listener — every registered entry receives
  // every `onLiveGreenScreenEvent` payload. Unkeyed (one live session at a
  // time; consumers filter by sessionId themselves if needed). Independent of
  // the Duet listeners above.
  final Map<Object, _LiveGreenScreenEventEntry> _liveGreenScreenEventListeners =
      {};

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

      case 'onTimelineAudioStateChanged':
        _dispatchTimelineAudioState(call.arguments);
        break;

      case 'onExportProgress':
        // Payload: bare num (Double on iOS, Double on Android).
        final progress = (call.arguments as num?)?.toDouble();
        if (progress != null && _exportProgressStack.isNotEmpty) {
          _exportProgressStack.last.onProgress(progress.clamp(0.0, 1.0));
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

      case 'onPhotoVideoDownloadProgress':
        _dispatchPhotoVideoDownloadProgress(call.arguments);
        break;

      case 'onDuetEvent':
        _dispatchDuetEvent(call.arguments);
        break;

      case 'onLiveGreenScreenEvent':
        _dispatchLiveGreenScreenEvent(call.arguments);
        break;

      // Unknown callbacks are silently dropped — forward compatibility.
    }
  }

  void _dispatchPhotoVideoDownloadProgress(dynamic arguments) {
    // Payload: {assetId: String, progress: num} (iOS PhotoKit download).
    final args = arguments as Map?;
    final assetId = args?['assetId'];
    final progress = (args?['progress'] as num?)?.toDouble();
    if (assetId is! String || assetId.isEmpty || progress == null) {
      return; // malformed — drop silently
    }
    // No listener for this assetId means the consumer already unregistered
    // (stale event from a cancelled / superseded download): drop it.
    final entry = _photoVideoDownloadListeners[assetId];
    entry?.onProgress(progress.clamp(0.0, 1.0));
  }

  void _dispatchDuetEvent(dynamic arguments) {
    // Payload: {event, sessionId, previousBackend, currentBackend, reason,
    // userMessage} (all String). Field-level and event-name validation is
    // the responsibility of the `vg_duet` typed layer (VGDuetEvent.fromMap);
    // here we only guard the outer shape and drop when nobody is listening.
    final args = arguments as Map?;
    if (args == null || _duetEventListeners.isEmpty) {
      return; // malformed — drop silently
    }
    for (final entry in _duetEventListeners.values.toList(growable: false)) {
      entry.onEvent(args);
    }
  }

  void _dispatchLiveGreenScreenEvent(dynamic arguments) {
    // Payload: {event, sessionId, previousBackend, currentBackend, reason,
    // userMessage}. Field-level and event-name validation is the
    // responsibility of the `vg_live_green_screen` typed layer
    // (VGLiveGreenScreenEvent.tryParse); here we only guard the outer shape
    // and drop when nobody is listening.
    final args = arguments as Map?;
    if (args == null || _liveGreenScreenEventListeners.isEmpty) {
      return; // malformed — drop silently
    }
    for (final entry in _liveGreenScreenEventListeners.values.toList(
      growable: false,
    )) {
      entry.onEvent(args);
    }
  }

  void _dispatchTimelineFrame(dynamic arguments) {
    final args = arguments as Map?;
    final textureId = (args?['textureId'] as num?)?.toInt();
    final pts = (args?['pts'] as num?)?.toDouble();
    // generation is optional — defaults to 0 for payloads that do not include it.
    final generation = (args?['generation'] as num?)?.toInt() ?? 0;
    if (textureId == null || pts == null) return; // malformed — drop silently

    final entry = _timelineListeners[textureId];
    entry?.onFrame(pts, generation);
  }

  void _dispatchTimelineEOS(dynamic arguments) {
    final args = arguments as Map?;
    final textureId = (args?['textureId'] as num?)?.toInt();
    if (textureId == null) return; // malformed — drop silently

    final entry = _timelineListeners[textureId];
    entry?.onEOS();
  }

  void _dispatchTimelineAudioState(dynamic arguments) {
    // Payload: {textureId: num, prepareSessionId: num, state: String}.
    final args = arguments as Map?;
    final textureId = (args?['textureId'] as num?)?.toInt();
    final prepareSessionId = (args?['prepareSessionId'] as num?)?.toInt();
    final state = args?['state'] as String?;
    if (textureId == null || prepareSessionId == null || state == null) {
      return; // malformed — drop silently
    }

    final entry = _timelineListeners[textureId];
    if (entry != null) {
      // A listener owns this textureId: deliver directly (or drop if the
      // listener did not opt in to audio state). Never buffer while a
      // listener is registered — buffering would leak the event into a
      // later, unrelated registration for a reused textureId.
      entry.onAudioStateChanged?.call(textureId, prepareSessionId, state);
      return;
    }

    // No listener yet: hold the latest value for this textureId.
    _pendingAudioStates.remove(textureId);
    if (_pendingAudioStates.length >= _kMaxPendingAudioStates) {
      _pendingAudioStates.remove(_pendingAudioStates.keys.first);
    }
    _pendingAudioStates[textureId] = _PendingAudioState(
      prepareSessionId: prepareSessionId,
      state: state,
    );
  }

  // ── Timeline registration ──────────────────────────────────────────────────

  /// Registers a timeline callback pair for [textureId].
  ///
  /// If a registration already exists for [textureId], it is replaced and
  /// a debug diagnostic is emitted.
  ///
  /// [onAudioStateChanged] (optional, Phase 10F Slice 3) receives
  /// `onTimelineAudioStateChanged` events for [textureId]. Any audio state
  /// event that arrived for [textureId] before this registration is drained
  /// synchronously into [onAudioStateChanged] (last value only) during this
  /// call, and then discarded regardless of whether a callback was supplied.
  ///
  /// Returns a [VGTimelineSubscription] that must be passed to
  /// [unregisterTimelineListener] when the consumer is disposed.
  VGTimelineSubscription registerTimelineListener({
    required int textureId,
    required VGTimelineFrameCallback onFrame,
    required VGTimelineEOSCallback onEOS,
    VGTimelineAudioStateCallback? onAudioStateChanged,
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
      onAudioStateChanged: onAudioStateChanged,
    );
    final subscription = VGTimelineSubscription._(textureId, token);

    // Drain a buffered audio state for this textureId (if any). Removed
    // before delivery so a re-entrant register/unregister inside the callback
    // cannot observe or re-deliver it.
    final pending = _pendingAudioStates.remove(textureId);
    if (pending != null && onAudioStateChanged != null) {
      onAudioStateChanged(textureId, pending.prepareSessionId, pending.state);
    }
    return subscription;
  }

  /// Unregisters a timeline subscription.
  ///
  /// Stale or already-unregistered tokens are safe no-ops. Any buffered
  /// audio state for the subscription's textureId is purged so it cannot
  /// leak into a later registration for a reused textureId.
  void unregisterTimelineListener(VGTimelineSubscription subscription) {
    final entry = _timelineListeners[subscription.textureId];
    if (entry != null && identical(entry.token, subscription._token)) {
      _timelineListeners.remove(subscription.textureId);
    }
    // Stale token: listener map untouched. The pending buffer is only ever
    // populated while no listener exists for the textureId, so purging it
    // here is safe in both the live and stale-token cases.
    _pendingAudioStates.remove(subscription.textureId);
  }

  // ── Export progress registration ──────────────────────────────────────────

  /// Registers an export progress listener.
  ///
  /// LIFO stack: pushes a new entry on top. Dispatch always calls the top
  /// entry, so this registration takes over `onExportProgress` delivery
  /// until it (or a still-newer registration) is unregistered — see class
  /// docs for the nested-exportDraft rationale.
  VGExportSubscription registerExportListener(
    void Function(double progress) onProgress,
  ) {
    ensureHandlerRegistered();
    final token = Object();
    _exportProgressStack.add(
      _ExportEntry(token: token, onProgress: onProgress),
    );
    return VGExportSubscription._(token);
  }

  /// Unregisters an export listener.
  ///
  /// Removes only the entry matching [subscription]'s token, wherever it is
  /// in the stack, restoring whichever entry is now on top (if any). Stale
  /// tokens are safe no-ops.
  void unregisterExportListener(VGExportSubscription subscription) {
    _exportProgressStack.removeWhere(
      (entry) => identical(entry.token, subscription._token),
    );
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

  // ── PhotoKit iCloud download progress registration ────────────────────────

  /// Registers an iOS PhotoKit iCloud download progress listener for
  /// [assetId] (`onPhotoVideoDownloadProgress`).
  ///
  /// Keyed by assetId: a new registration for the same assetId replaces the
  /// previous one (the previous token becomes stale). Progress values are
  /// clamped to `[0.0, 1.0]` before delivery. Events for assetIds with no
  /// registered listener are dropped, never buffered.
  VGPhotoVideoDownloadProgressSubscription
  registerPhotoVideoDownloadProgressListener({
    required String assetId,
    required void Function(double progress) onProgress,
  }) {
    ensureHandlerRegistered();
    final token = Object();
    _photoVideoDownloadListeners[assetId] = _PhotoVideoDownloadEntry(
      token: token,
      onProgress: onProgress,
    );
    return VGPhotoVideoDownloadProgressSubscription._(assetId, token);
  }

  /// Unregisters a PhotoKit download progress listener.
  ///
  /// Removes the entry for the subscription's assetId only when it still
  /// belongs to [subscription]; stale tokens (superseded by a newer
  /// registration for the same assetId, or already unregistered) are safe
  /// no-ops.
  void unregisterPhotoVideoDownloadProgressListener(
    VGPhotoVideoDownloadProgressSubscription subscription,
  ) {
    final entry = _photoVideoDownloadListeners[subscription.assetId];
    if (entry != null && identical(entry.token, subscription._token)) {
      _photoVideoDownloadListeners.remove(subscription.assetId);
    }
  }

  // ── Duet event registration ────────────────────────────────────────────────

  /// Registers a Duet green-screen degradation event listener
  /// (`onDuetEvent`).
  ///
  /// Multi-listener: unlike the other single-slot categories, any number of
  /// listeners may be registered concurrently and every one receives every
  /// event. Unregistering one subscription never affects the others.
  VGDuetEventSubscription registerDuetEventListener(
    void Function(Map<dynamic, dynamic> payload) onEvent,
  ) {
    ensureHandlerRegistered();
    final token = Object();
    _duetEventListeners[token] = _DuetEventEntry(
      token: token,
      onEvent: onEvent,
    );
    return VGDuetEventSubscription._(token);
  }

  /// Unregisters a Duet event listener.
  ///
  /// Stale tokens are safe no-ops.
  void unregisterDuetEventListener(VGDuetEventSubscription subscription) {
    _duetEventListeners.remove(subscription._token);
  }

  // ── Live green-screen event registration ───────────────────────────────────

  /// Registers a generic live green-screen event listener
  /// (`onLiveGreenScreenEvent`).
  ///
  /// Multi-listener: any number of listeners may be registered concurrently
  /// and every one receives every event. Unregistering one subscription never
  /// affects the others, and never affects Duet listeners.
  VGLiveGreenScreenEventSubscription registerLiveGreenScreenEventListener(
    void Function(Map<dynamic, dynamic> payload) onEvent,
  ) {
    ensureHandlerRegistered();
    final token = Object();
    _liveGreenScreenEventListeners[token] = _LiveGreenScreenEventEntry(
      token: token,
      onEvent: onEvent,
    );
    return VGLiveGreenScreenEventSubscription._(token);
  }

  /// Unregisters a live green-screen event listener.
  ///
  /// Stale tokens are safe no-ops.
  void unregisterLiveGreenScreenEventListener(
    VGLiveGreenScreenEventSubscription subscription,
  ) {
    _liveGreenScreenEventListeners.remove(subscription._token);
  }

  // ── Testing seam ──────────────────────────────────────────────────────────

  /// Resets all dispatcher state. **Test-only — never call in production.**
  ///
  /// Clears all registered listeners, tokens, and the handler-registration
  /// flag. Optionally injects a test [MethodChannel].
  @visibleForTesting
  void resetForTesting({MethodChannel? channel}) {
    _timelineListeners.clear();
    _pendingAudioStates.clear();
    _exportProgressStack.clear();
    _playbackCompleteCallback = null;
    _playbackCompleteToken = null;
    _durationProbedCallback = null;
    _durationProbedToken = null;
    _thermalStateCallback = null;
    _thermalStateToken = null;
    _photoVideoDownloadListeners.clear();
    _duetEventListeners.clear();
    _liveGreenScreenEventListeners.clear();
    _handlerRegistered = false;
    _channel = channel ?? const MethodChannel('vanguard_media_engine');
  }

  /// Whether a PhotoKit download progress listener is registered for
  /// [assetId]. **Test-only.**
  @visibleForTesting
  bool hasPhotoVideoDownloadProgressListenerForTesting(String assetId) =>
      _photoVideoDownloadListeners.containsKey(assetId);

  /// Whether the handler has been registered. **Test-only.**
  @visibleForTesting
  bool get isHandlerRegistered => _handlerRegistered;

  /// Whether a timeline listener is registered for [textureId]. **Test-only.**
  @visibleForTesting
  bool hasTimelineListenerForTesting(int textureId) =>
      _timelineListeners.containsKey(textureId);

  /// Whether an export progress listener is currently registered. **Test-only.**
  @visibleForTesting
  bool get hasExportListenerForTesting => _exportProgressStack.isNotEmpty;

  /// Whether an audio state event is buffered for [textureId]. **Test-only.**
  @visibleForTesting
  bool hasPendingAudioStateForTesting(int textureId) =>
      _pendingAudioStates.containsKey(textureId);

  /// Number of currently registered Duet event listeners. **Test-only.**
  @visibleForTesting
  int get duetEventListenerCountForTesting => _duetEventListeners.length;
}
