// Copyright 2026, Connects. All rights reserved.
// Typed Duet green-screen degradation/fallback event stream
// (`onDuetEvent`), backed by VanguardChannelDispatcher's multi-listener Duet
// event registration. Not a second MethodChannel handler — this file only
// registers/unregisters a listener on the existing dispatcher singleton.

import 'dart:async';

import '../channel/vanguard_channel_dispatcher.dart';

/// Duet green-screen degradation/fallback event kinds.
///
/// `green_screen_degraded` is emitted when native keeps green screen live after
/// degrading to a lower rung, e.g. Android MediaPipe CPU -> ML Kit;
/// `green_screen_fallback` is emitted after native switches to safe PiP.
enum VGDuetEventType { greenScreenDegraded, greenScreenFallback }

/// A single parsed `onDuetEvent` payload.
final class VGDuetEvent {
  const VGDuetEvent({
    required this.type,
    required this.sessionId,
    required this.previousBackend,
    required this.currentBackend,
    required this.reason,
    required this.userMessage,
  });

  final VGDuetEventType type;
  final String sessionId;
  final String previousBackend;
  final String currentBackend;
  final String reason;
  final String userMessage;

  /// Parses a raw dispatcher payload. Returns `null` for malformed payloads
  /// or unrecognized event names; both are silently dropped by
  /// [VGDuetEvents].
  static VGDuetEvent? tryParse(Map<dynamic, dynamic> payload) {
    final type = _typeFromWire(payload['event']);
    if (type == null) return null;

    final sessionId = payload['sessionId'];
    final previousBackend = payload['previousBackend'];
    final currentBackend = payload['currentBackend'];
    final reason = payload['reason'];
    final userMessage = payload['userMessage'];
    if (sessionId is! String ||
        previousBackend is! String ||
        currentBackend is! String ||
        reason is! String ||
        userMessage is! String) {
      return null;
    }

    return VGDuetEvent(
      type: type,
      sessionId: sessionId,
      previousBackend: previousBackend,
      currentBackend: currentBackend,
      reason: reason,
      userMessage: userMessage,
    );
  }

  static VGDuetEventType? _typeFromWire(dynamic wireValue) {
    switch (wireValue) {
      case 'green_screen_degraded':
        return VGDuetEventType.greenScreenDegraded;
      case 'green_screen_fallback':
        return VGDuetEventType.greenScreenFallback;
      default:
        return null;
    }
  }
}

/// Public typed stream of Duet green-screen degradation/fallback events.
///
/// Registers a single dispatcher listener lazily on the first [stream]
/// subscriber and unregisters it once the last subscriber cancels; any
/// number of consumers may listen concurrently (broadcast stream), and
/// cancelling one subscription never affects the others.
final class VGDuetEvents {
  VGDuetEvents._();

  static final StreamController<VGDuetEvent> _controller =
      StreamController<VGDuetEvent>.broadcast(
        onListen: _onListen,
        onCancel: _onCancel,
      );

  static VGDuetEventSubscription? _dispatcherSubscription;

  /// Broadcast stream of parsed Duet events. Malformed payloads and unknown
  /// event names are dropped before reaching this stream.
  static Stream<VGDuetEvent> get stream => _controller.stream;

  static void _onListen() {
    _dispatcherSubscription ??= VanguardChannelDispatcher.instance
        .registerDuetEventListener((payload) {
          final event = VGDuetEvent.tryParse(payload);
          if (event != null) _controller.add(event);
        });
  }

  static void _onCancel() {
    final subscription = _dispatcherSubscription;
    if (subscription != null) {
      VanguardChannelDispatcher.instance.unregisterDuetEventListener(
        subscription,
      );
      _dispatcherSubscription = null;
    }
  }
}
