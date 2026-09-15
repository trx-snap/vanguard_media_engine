// Copyright 2026, Connects. All rights reserved.
// Typed generic live green-screen event stream (`onLiveGreenScreenEvent`),
// backed by VanguardChannelDispatcher's multi-listener registration. Not a
// second MethodChannel handler — this file only registers/unregisters a
// listener on the existing dispatcher singleton. Independent of the Duet
// event stream (`onDuetEvent` / VGDuetEvents).

import 'dart:async';

import '../channel/vanguard_channel_dispatcher.dart';

/// Live green-screen event kinds.
///
/// - [degraded]: segmentation moved to a lower rung (for example MediaPipe
///   CPU -> ML Kit); the camera is still keyed.
/// - [fallback]: the segmentation ladder is exhausted; the engine keeps
///   showing the unkeyed live camera over the same static background. No
///   PiP, no layout change.
/// - [suspended]: the output texture was lost (typically the app moved to the
///   background); the session stays alive and resumes automatically.
/// - [resumed]: the output texture became available again after [suspended].
/// - [error]: an asynchronous failure that did not end the session, such as
///   the camera failing to start; the caller decides whether to stop.
enum VGLiveGreenScreenEventType {
  degraded,
  fallback,
  suspended,
  resumed,
  error,
}

/// A single parsed `onLiveGreenScreenEvent` payload.
final class VGLiveGreenScreenEvent {
  const VGLiveGreenScreenEvent({
    required this.type,
    required this.sessionId,
    required this.previousBackend,
    required this.currentBackend,
    required this.reason,
    required this.userMessage,
  });

  final VGLiveGreenScreenEventType type;
  final String sessionId;

  /// Segmentation backend before the event (`mediapipe_cpu`, `mlkit`,
  /// `none`, ...). Empty when not applicable.
  final String previousBackend;

  /// Segmentation backend after the event; `none` once keying is off.
  final String currentBackend;

  /// Machine-readable reason (for example `mlkit_init_failed`,
  /// `output_surface_lost`, `camera_start_failed`).
  final String reason;

  /// Human-readable description suitable for a status line.
  final String userMessage;

  /// Parses a raw dispatcher payload. Returns `null` for malformed payloads
  /// or unrecognized event names; both are silently dropped by
  /// [VGLiveGreenScreenEvents].
  static VGLiveGreenScreenEvent? tryParse(Map<dynamic, dynamic> payload) {
    final type = _typeFromWire(payload['event']);
    if (type == null) return null;

    final sessionId = payload['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) return null;

    return VGLiveGreenScreenEvent(
      type: type,
      sessionId: sessionId,
      previousBackend: _optionalString(payload['previousBackend']),
      currentBackend: _optionalString(payload['currentBackend']),
      reason: _optionalString(payload['reason']),
      userMessage: _optionalString(payload['userMessage']),
    );
  }

  static String _optionalString(dynamic value) => value is String ? value : '';

  static VGLiveGreenScreenEventType? _typeFromWire(dynamic wireValue) {
    switch (wireValue) {
      case 'green_screen_degraded':
        return VGLiveGreenScreenEventType.degraded;
      case 'green_screen_fallback':
        return VGLiveGreenScreenEventType.fallback;
      case 'suspended':
        return VGLiveGreenScreenEventType.suspended;
      case 'resumed':
        return VGLiveGreenScreenEventType.resumed;
      case 'error':
        return VGLiveGreenScreenEventType.error;
      default:
        return null;
    }
  }

  @override
  String toString() =>
      'VGLiveGreenScreenEvent(${type.name}, sessionId: $sessionId, '
      '$previousBackend -> $currentBackend, reason: $reason)';
}

/// Public typed stream of live green-screen events.
///
/// Registers a single dispatcher listener lazily on the first [stream]
/// subscriber and unregisters it once the last subscriber cancels; any
/// number of consumers may listen concurrently (broadcast stream), and
/// cancelling one subscription never affects the others.
final class VGLiveGreenScreenEvents {
  VGLiveGreenScreenEvents._();

  static final StreamController<VGLiveGreenScreenEvent> _controller =
      StreamController<VGLiveGreenScreenEvent>.broadcast(
        onListen: _onListen,
        onCancel: _onCancel,
      );

  static VGLiveGreenScreenEventSubscription? _dispatcherSubscription;

  /// Broadcast stream of parsed live green-screen events. Malformed payloads
  /// and unknown event names are dropped before reaching this stream.
  static Stream<VGLiveGreenScreenEvent> get stream => _controller.stream;

  static void _onListen() {
    _dispatcherSubscription ??= VanguardChannelDispatcher.instance
        .registerLiveGreenScreenEventListener((payload) {
          final event = VGLiveGreenScreenEvent.tryParse(payload);
          if (event != null) _controller.add(event);
        });
  }

  static void _onCancel() {
    final subscription = _dispatcherSubscription;
    if (subscription != null) {
      VanguardChannelDispatcher.instance.unregisterLiveGreenScreenEventListener(
        subscription,
      );
      _dispatcherSubscription = null;
    }
  }
}
