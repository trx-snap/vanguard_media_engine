// Copyright (c) Connects — Vanguard Phase 4C7O.
// Public streaming playback controller facade.
//
// Pure Dart session-safety facade over VGStreamingPlaybackClient and
// VGStreamingPlaybackDecision. Owns exactly one active streaming session at a time.
// Bounded convenience wrapper: does NOT implement feed policy, retry policy,
// source replacement, prefetch policy, WebRTC/LiveKit, ABR control, native cleanup,
// or ConnectsApp wiring.

import 'dart:async';

import 'vg_streaming_playback_client.dart';
import 'vg_streaming_playback_decision.dart';

export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackClient,
        VGStreamingPlaybackOptions,
        VGStreamingPlaybackSession,
        VGStreamingPlaybackState;
export 'vg_streaming_playback_decision.dart'
    show
        VGStreamingPlaybackDecision,
        VGStreamingPlaybackDecisionPlanner,
        VGStreamingPlaybackDecisionRequest;

/// High-level lifecycle states of [VGStreamingPlaybackController].
enum VGStreamingPlaybackControllerState {
  idle,
  opening,
  playing,
  paused,
  stopped,
  failed,
  disposed,
  unsupported,
}

/// Immutable snapshot of the current state of a [VGStreamingPlaybackController].
class VGStreamingPlaybackControllerSnapshot {
  /// Current high-level lifecycle state.
  final VGStreamingPlaybackControllerState state;

  /// Decision that opened or attempted to open this playback session.
  final VGStreamingPlaybackDecision? decision;

  /// Underlying active native session descriptor, if any.
  final VGStreamingPlaybackSession? session;

  /// Whether the last controller operation succeeded.
  final bool pass;

  /// High-level reason or outcome description of the last operation.
  final String reason;

  /// Optional error message from the last failed operation.
  final String? lastError;

  /// Diagnostic telemetry and metadata.
  final Map<String, Object?> diagnostics;

  const VGStreamingPlaybackControllerSnapshot({
    required this.state,
    this.decision,
    this.session,
    required this.pass,
    required this.reason,
    this.lastError,
    this.diagnostics = const {},
  });

  /// Flutter TextureRegistry texture ID for presentation, or `null` if no active session texture.
  int? get textureId =>
      (session != null && session!.textureId >= 0) ? session!.textureId : null;

  /// Total media duration in milliseconds (-1 for live/unbounded streams or when no session).
  int get durationMs => session?.durationMs ?? -1;

  /// Current playhead position in milliseconds (0 when no session).
  int get positionMs => session?.positionMs ?? 0;

  /// Buffered duration in milliseconds ahead of current playhead (0 when no session).
  int get bufferedPositionMs => session?.bufferedPositionMs ?? 0;

  /// Look-ahead buffer fill percentage (0 to 100, 0 when no session).
  int get bufferedPercent => session?.bufferedPercent ?? 0;

  /// Current distance from live edge in milliseconds (live streams only; `null` for VOD or when no session).
  int? get liveOffsetMs => session?.liveOffsetMs;

  /// Whether playback session telemetry is available.
  bool get hasPlaybackTelemetry => session != null;

  /// Returns a copy of this snapshot with updated fields.
  VGStreamingPlaybackControllerSnapshot copyWith({
    VGStreamingPlaybackControllerState? state,
    VGStreamingPlaybackDecision? decision,
    VGStreamingPlaybackSession? session,
    bool clearSession = false,
    bool? pass,
    String? reason,
    String? lastError,
    bool clearLastError = false,
    Map<String, Object?>? diagnostics,
  }) {
    return VGStreamingPlaybackControllerSnapshot(
      state: state ?? this.state,
      decision: decision ?? this.decision,
      session: clearSession ? null : (session ?? this.session),
      pass: pass ?? this.pass,
      reason: reason ?? this.reason,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      diagnostics: diagnostics ?? this.diagnostics,
    );
  }

  @override
  String toString() =>
      'VGStreamingPlaybackControllerSnapshot(state=$state, pass=$pass, '
      'reason=$reason, textureId=$textureId, lastError=$lastError)';
}

/// Bounded public Dart controller facade over streaming playback sessions.
///
/// Serializes asynchronous operations via a busy guard, ensures single-session
/// ownership, and coordinates lifecycle transitions between planner decisions
/// and platform playback sessions.
class VGStreamingPlaybackController {
  final VGStreamingPlaybackClient _client;
  bool _isBusy = false;
  bool _isDisposed = false;

  VGStreamingPlaybackControllerSnapshot _snapshot =
      const VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        decision: null,
        session: null,
        pass: true,
        reason: 'idle',
        lastError: null,
        diagnostics: {},
      );

  VGStreamingPlaybackController({VGStreamingPlaybackClient? playbackClient})
    : _client = playbackClient ?? VGStreamingPlaybackClient();

  /// Current immutable snapshot of this controller.
  VGStreamingPlaybackControllerSnapshot get snapshot => _snapshot;

  /// Whether this controller has been disposed.
  bool get isDisposed => _isDisposed;

  /// Opens a streaming session using the provided [decision].
  ///
  /// If [startPlayback] is true (default), initiates playback immediately once opened.
  Future<VGStreamingPlaybackControllerSnapshot> open(
    VGStreamingPlaybackDecision decision, {
    bool startPlayback = true,
  }) async {
    if (_isDisposed) {
      return _snapshot.copyWith(
        state: VGStreamingPlaybackControllerState.disposed,
        pass: false,
        reason: 'controller_disposed',
      );
    }
    if (_isBusy) {
      return _snapshot.copyWith(pass: false, reason: 'controller_busy');
    }
    _isBusy = true;
    try {
      if (!decision.canOpenPlayback || decision.playbackOptions == null) {
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.failed,
          decision: decision,
          session: null,
          pass: false,
          reason: 'decision_blocked',
          diagnostics: decision.diagnostics,
        );
        return _snapshot;
      }

      if (_snapshot.session != null &&
          _snapshot.state != VGStreamingPlaybackControllerState.stopped) {
        return _snapshot.copyWith(
          pass: false,
          reason: 'session_already_active',
        );
      }

      // If an old session is stopped, clean it up before opening a new one.
      final oldSession = _snapshot.session;
      if (oldSession != null && oldSession.textureId >= 0) {
        try {
          await _client.dispose(oldSession);
        } catch (_) {}
      }

      _snapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.opening,
        decision: decision,
        session: null,
        pass: true,
        reason: 'opening',
        diagnostics: decision.diagnostics,
      );

      final openedSession = await _client.open(decision.playbackOptions!);
      if (!openedSession.pass ||
          openedSession.textureId < 0 ||
          openedSession.state == VGStreamingPlaybackState.unsupported) {
        final state =
            openedSession.state == VGStreamingPlaybackState.unsupported
            ? VGStreamingPlaybackControllerState.unsupported
            : VGStreamingPlaybackControllerState.failed;
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: state,
          decision: decision,
          session: openedSession,
          pass: false,
          reason: 'open_failed',
          diagnostics: openedSession.diagnostics,
        );
        return _snapshot;
      }

      if (startPlayback) {
        try {
          final playedSession = await _client.play(openedSession);
          final mappedState = _mapNativeState(playedSession.state);
          final pass =
              playedSession.pass &&
              mappedState != VGStreamingPlaybackControllerState.failed &&
              mappedState != VGStreamingPlaybackControllerState.unsupported;
          _snapshot = VGStreamingPlaybackControllerSnapshot(
            state: mappedState,
            decision: decision,
            session: playedSession,
            pass: pass,
            reason: pass ? 'playing' : 'play_failed',
            diagnostics: playedSession.diagnostics,
          );
          return _snapshot;
        } catch (e) {
          try {
            await _client.dispose(openedSession);
          } catch (_) {}
          _snapshot = VGStreamingPlaybackControllerSnapshot(
            state: VGStreamingPlaybackControllerState.failed,
            decision: decision,
            session: null,
            pass: false,
            reason: 'play_failed',
            lastError: e.toString(),
            diagnostics: openedSession.diagnostics,
          );
          return _snapshot;
        }
      } else {
        final mappedState =
            (openedSession.state == VGStreamingPlaybackState.paused)
            ? VGStreamingPlaybackControllerState.paused
            : VGStreamingPlaybackControllerState.opening;
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: mappedState,
          decision: decision,
          session: openedSession,
          pass: true,
          reason: 'opened',
          diagnostics: openedSession.diagnostics,
        );
        return _snapshot;
      }
    } finally {
      _isBusy = false;
    }
  }

  /// Requests playback to resume on the active session.
  Future<VGStreamingPlaybackControllerSnapshot> play() async {
    if (_isDisposed) {
      return _snapshot.copyWith(
        state: VGStreamingPlaybackControllerState.disposed,
        pass: false,
        reason: 'controller_disposed',
      );
    }
    if (_isBusy) {
      return _snapshot.copyWith(pass: false, reason: 'controller_busy');
    }
    _isBusy = true;
    try {
      final session = _snapshot.session;
      if (session == null) {
        return _snapshot.copyWith(pass: false, reason: 'no_active_session');
      }

      try {
        final playedSession = await _client.play(session);
        final mappedState = _mapNativeState(playedSession.state);
        final pass =
            playedSession.pass &&
            mappedState != VGStreamingPlaybackControllerState.failed &&
            mappedState != VGStreamingPlaybackControllerState.unsupported;
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: mappedState,
          decision: _snapshot.decision,
          session: playedSession,
          pass: pass,
          reason: pass ? 'playing' : 'play_failed',
          diagnostics: playedSession.diagnostics,
        );
        return _snapshot;
      } catch (e) {
        _snapshot = _snapshot.copyWith(
          pass: false,
          reason: 'play_failed',
          lastError: e.toString(),
        );
        return _snapshot;
      }
    } finally {
      _isBusy = false;
    }
  }

  /// Requests playback to pause on the active session.
  Future<VGStreamingPlaybackControllerSnapshot> pause() async {
    if (_isDisposed) {
      return _snapshot.copyWith(
        state: VGStreamingPlaybackControllerState.disposed,
        pass: false,
        reason: 'controller_disposed',
      );
    }
    if (_isBusy) {
      return _snapshot.copyWith(pass: false, reason: 'controller_busy');
    }
    _isBusy = true;
    try {
      final session = _snapshot.session;
      if (session == null) {
        return _snapshot.copyWith(pass: false, reason: 'no_active_session');
      }

      try {
        final pausedSession = await _client.pause(session);
        final mappedState = _mapNativeState(pausedSession.state);
        final pass =
            pausedSession.pass &&
            mappedState != VGStreamingPlaybackControllerState.failed &&
            mappedState != VGStreamingPlaybackControllerState.unsupported;
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: mappedState,
          decision: _snapshot.decision,
          session: pausedSession,
          pass: pass,
          reason: pass ? 'paused' : 'pause_failed',
          diagnostics: pausedSession.diagnostics,
        );
        return _snapshot;
      } catch (e) {
        _snapshot = _snapshot.copyWith(
          pass: false,
          reason: 'pause_failed',
          lastError: e.toString(),
        );
        return _snapshot;
      }
    } finally {
      _isBusy = false;
    }
  }

  /// Requests seeking to [positionMs] on the active session.
  Future<VGStreamingPlaybackControllerSnapshot> seek(int positionMs) async {
    if (_isDisposed) {
      return _snapshot.copyWith(
        state: VGStreamingPlaybackControllerState.disposed,
        pass: false,
        reason: 'controller_disposed',
      );
    }
    if (_isBusy) {
      return _snapshot.copyWith(pass: false, reason: 'controller_busy');
    }
    _isBusy = true;
    try {
      if (positionMs < 0) {
        return _snapshot.copyWith(pass: false, reason: 'position_invalid');
      }

      final session = _snapshot.session;
      if (session == null) {
        return _snapshot.copyWith(pass: false, reason: 'no_active_session');
      }

      try {
        final seekedSession = await _client.seek(session, positionMs);
        final mappedState = _mapNativeState(seekedSession.state);
        final pass =
            seekedSession.pass &&
            mappedState != VGStreamingPlaybackControllerState.failed &&
            mappedState != VGStreamingPlaybackControllerState.unsupported;
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: mappedState,
          decision: _snapshot.decision,
          session: seekedSession,
          pass: pass,
          reason: pass ? 'seeking' : 'seek_failed',
          diagnostics: seekedSession.diagnostics,
        );
        return _snapshot;
      } catch (e) {
        _snapshot = _snapshot.copyWith(
          pass: false,
          reason: 'seek_failed',
          lastError: e.toString(),
        );
        return _snapshot;
      }
    } finally {
      _isBusy = false;
    }
  }

  /// Queries current status and telemetry from the active session.
  Future<VGStreamingPlaybackControllerSnapshot> refresh() async {
    if (_isDisposed) {
      return _snapshot.copyWith(
        state: VGStreamingPlaybackControllerState.disposed,
        pass: false,
        reason: 'controller_disposed',
      );
    }
    if (_isBusy) {
      return _snapshot.copyWith(pass: false, reason: 'controller_busy');
    }
    _isBusy = true;
    try {
      final session = _snapshot.session;
      if (session == null) {
        return _snapshot.copyWith(pass: false, reason: 'no_active_session');
      }

      try {
        final statusSession = await _client.getStatus(session);
        final mappedState = _mapNativeState(statusSession.state);
        final pass =
            statusSession.pass &&
            mappedState != VGStreamingPlaybackControllerState.failed &&
            mappedState != VGStreamingPlaybackControllerState.unsupported;
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: mappedState,
          decision: _snapshot.decision,
          session: statusSession,
          pass: pass,
          reason: pass ? 'refreshed' : 'refresh_failed',
          diagnostics: statusSession.diagnostics,
        );
        return _snapshot;
      } catch (e) {
        _snapshot = _snapshot.copyWith(
          pass: false,
          reason: 'refresh_failed',
          lastError: e.toString(),
        );
        return _snapshot;
      }
    } finally {
      _isBusy = false;
    }
  }

  /// Requests playback to stop. Retains the stopped session snapshot until disposed or reopened.
  Future<VGStreamingPlaybackControllerSnapshot> stop() async {
    if (_isDisposed) {
      return _snapshot.copyWith(
        state: VGStreamingPlaybackControllerState.disposed,
        pass: false,
        reason: 'controller_disposed',
      );
    }
    if (_isBusy) {
      return _snapshot.copyWith(pass: false, reason: 'controller_busy');
    }
    _isBusy = true;
    try {
      final session = _snapshot.session;
      if (session == null) {
        _snapshot = _snapshot.copyWith(
          state: VGStreamingPlaybackControllerState.stopped,
          pass: true,
          reason: 'already_stopped',
        );
        return _snapshot;
      }

      try {
        final stoppedSession = await _client.stop(session);
        final mappedState = _mapNativeState(stoppedSession.state);
        final state =
            (mappedState == VGStreamingPlaybackControllerState.failed ||
                mappedState == VGStreamingPlaybackControllerState.unsupported)
            ? mappedState
            : VGStreamingPlaybackControllerState.stopped;
        final pass =
            stoppedSession.pass &&
            state == VGStreamingPlaybackControllerState.stopped;
        _snapshot = VGStreamingPlaybackControllerSnapshot(
          state: state,
          decision: _snapshot.decision,
          session: stoppedSession,
          pass: pass,
          reason: pass ? 'stopped' : 'stop_failed',
          diagnostics: stoppedSession.diagnostics,
        );
        return _snapshot;
      } catch (e) {
        _snapshot = _snapshot.copyWith(
          pass: false,
          reason: 'stop_failed',
          lastError: e.toString(),
        );
        return _snapshot;
      }
    } finally {
      _isBusy = false;
    }
  }

  /// Releases platform decoder, presentation surface, and native playback resources.
  ///
  /// Idempotent. Clears the retained active session.
  Future<VGStreamingPlaybackControllerSnapshot> dispose() async {
    if (_isDisposed) {
      return _snapshot;
    }
    if (_isBusy) {
      return _snapshot.copyWith(pass: false, reason: 'controller_busy');
    }
    _isBusy = true;
    _isDisposed = true;
    try {
      final session = _snapshot.session;
      if (session != null && session.textureId >= 0) {
        try {
          await _client.dispose(session);
        } catch (e) {
          _snapshot = VGStreamingPlaybackControllerSnapshot(
            state: VGStreamingPlaybackControllerState.disposed,
            decision: _snapshot.decision,
            session: null,
            pass: false,
            reason: 'dispose_failed',
            lastError: e.toString(),
            diagnostics: const {},
          );
          return _snapshot;
        }
      }

      _snapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.disposed,
        decision: _snapshot.decision,
        session: null,
        pass: true,
        reason: 'disposed',
        diagnostics: const {},
      );
      return _snapshot;
    } finally {
      _isBusy = false;
    }
  }

  static VGStreamingPlaybackControllerState _mapNativeState(
    VGStreamingPlaybackState nativeState,
  ) {
    return switch (nativeState) {
      VGStreamingPlaybackState.playing =>
        VGStreamingPlaybackControllerState.playing,
      VGStreamingPlaybackState.paused =>
        VGStreamingPlaybackControllerState.paused,
      VGStreamingPlaybackState.opening ||
      VGStreamingPlaybackState.buffering ||
      VGStreamingPlaybackState.seeking =>
        VGStreamingPlaybackControllerState.opening,
      VGStreamingPlaybackState.ended || VGStreamingPlaybackState.idle =>
        VGStreamingPlaybackControllerState.stopped,
      VGStreamingPlaybackState.failed ||
      VGStreamingPlaybackState.surfaceLost ||
      VGStreamingPlaybackState.backgrounded =>
        VGStreamingPlaybackControllerState.failed,
      VGStreamingPlaybackState.disposed =>
        VGStreamingPlaybackControllerState.disposed,
      VGStreamingPlaybackState.unsupported =>
        VGStreamingPlaybackControllerState.unsupported,
    };
  }
}
