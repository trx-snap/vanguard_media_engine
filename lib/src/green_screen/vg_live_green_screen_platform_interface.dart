// Copyright 2026, Connects. All rights reserved.
// Pure Dart except the injectable MethodChannel — no dart:io, no dart:ui.

import 'package:flutter/services.dart';

import 'vg_green_screen_models.dart' show VGGreenScreenBackgroundSource;
import 'vg_live_green_screen_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Abstract platform interface
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract generic live green-screen platform interface.
///
/// Decouples the Dart contracts from the native engine so any caller (live
/// meeting/calling, going live, camera, Universal Editor) can run a keyed
/// live camera over a static background. The engine owns the camera and
/// presents the composited output on a Flutter texture; at most one live
/// session exists at a time, and it shares the camera admission guard with
/// Duet.
abstract class VGLiveGreenScreenPlatformInterface {
  const VGLiveGreenScreenPlatformInterface();

  /// Starts a live session described by [config] and returns its descriptor
  /// (session id + output texture).
  ///
  /// Throws [VGLiveGreenScreenException] with:
  /// - [VGLiveGreenScreenErrorCode.invalidArgument] when the native side
  ///   rejects the config (bad canvas size, unsupported background type,
  ///   missing image file, malformed transform);
  /// - [VGLiveGreenScreenErrorCode.liveBusy] when a live session is already
  ///   active or another engine session (Duet) holds the camera;
  /// - [VGLiveGreenScreenErrorCode.cameraUnavailable] when the CAMERA
  ///   permission is not granted or no camera context exists;
  /// - [VGLiveGreenScreenErrorCode.compositionFailed] when the preview
  ///   texture or compositor cannot be created.
  ///
  /// Segmentation degradation, terminal fallback (unkeyed live camera over
  /// the same background), output suspension/resumption and asynchronous
  /// camera failures are reported through `VGLiveGreenScreenEvents.stream`,
  /// never by this call.
  Future<VGLiveGreenScreenSession> startLiveGreenScreenSession(
    VGLiveGreenScreenConfig config,
  );

  /// Replaces the static background of [sessionId] without restarting the
  /// camera or segmentation.
  ///
  /// Throws [ArgumentError] for a video background (deferred), and
  /// [VGLiveGreenScreenException] with
  /// [VGLiveGreenScreenErrorCode.sessionNotFound] when [sessionId] is not
  /// the active live session.
  Future<void> updateLiveGreenScreenBackground(
    String sessionId,
    VGGreenScreenBackgroundSource background,
  );

  /// Moves/scales the keyed camera layer of [sessionId]; the background
  /// keeps filling the full canvas.
  ///
  /// Throws [VGLiveGreenScreenException] with
  /// [VGLiveGreenScreenErrorCode.sessionNotFound] when [sessionId] is not
  /// the active live session.
  Future<void> updateLiveGreenScreenTransform(
    String sessionId,
    VGLiveGreenScreenForegroundTransform transform,
  );

  /// Stops [sessionId], releasing the camera, segmentation, compositor and
  /// texture. Idempotent: an unknown or already stopped id completes
  /// normally.
  Future<void> stopLiveGreenScreenSession(String sessionId);
}

// ─────────────────────────────────────────────────────────────────────────────
// Default MethodChannel implementation
// ─────────────────────────────────────────────────────────────────────────────

/// Default [VGLiveGreenScreenPlatformInterface] backed by an injectable
/// [MethodChannel].
///
/// Channel name: `vanguard_media_engine`
/// Native method names: `startLiveGreenScreenSession`,
/// `updateLiveGreenScreenBackground`, `updateLiveGreenScreenTransform`,
/// `stopLiveGreenScreenSession`.
/// Error codes from native: `INVALID_ARG`, `live_busy`, `cameraUnavailable`,
/// `composition_failed`, `session_not_found`.
class MethodChannelVGLiveGreenScreenPlatform
    extends VGLiveGreenScreenPlatformInterface {
  /// The method channel used to communicate with the native engine.
  final MethodChannel channel;

  const MethodChannelVGLiveGreenScreenPlatform({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  static const String _methodStart = 'startLiveGreenScreenSession';
  static const String _methodUpdateBackground =
      'updateLiveGreenScreenBackground';
  static const String _methodUpdateTransform = 'updateLiveGreenScreenTransform';
  static const String _methodStop = 'stopLiveGreenScreenSession';

  @override
  Future<VGLiveGreenScreenSession> startLiveGreenScreenSession(
    VGLiveGreenScreenConfig config,
  ) async {
    final result = await _invoke<Map>(_methodStart, config.toMap());
    if (result == null) {
      throw const VGLiveGreenScreenException(
        code: VGLiveGreenScreenErrorCode.compositionFailed,
        message: '$_methodStart returned null result.',
      );
    }
    try {
      return VGLiveGreenScreenSession.fromMap(
        Map<String, dynamic>.from(result),
      );
    } on ArgumentError catch (e) {
      throw VGLiveGreenScreenException(
        code: VGLiveGreenScreenErrorCode.compositionFailed,
        message: '$_methodStart returned a malformed session: ${e.message}',
        cause: e,
      );
    }
  }

  @override
  Future<void> updateLiveGreenScreenBackground(
    String sessionId,
    VGGreenScreenBackgroundSource background,
  ) async {
    // Throws ArgumentError for a video background before touching native.
    final nativeBackground = VGLiveGreenScreenConfig.backgroundToNativeMap(
      background,
    );
    await _invoke<void>(_methodUpdateBackground, <String, dynamic>{
      'sessionId': sessionId,
      'background': nativeBackground,
    });
  }

  @override
  Future<void> updateLiveGreenScreenTransform(
    String sessionId,
    VGLiveGreenScreenForegroundTransform transform,
  ) async {
    await _invoke<void>(_methodUpdateTransform, <String, dynamic>{
      'sessionId': sessionId,
      'foregroundTransform': transform.toMap(),
    });
  }

  @override
  Future<void> stopLiveGreenScreenSession(String sessionId) async {
    await _invoke<void>(_methodStop, <String, dynamic>{'sessionId': sessionId});
  }

  Future<T?> _invoke<T>(String method, Map<String, dynamic> arguments) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw VGLiveGreenScreenException(
        code: VGLiveGreenScreenErrorCode.fromPlatformCode(e.code),
        message: e.message ?? '$method failed.',
        cause: e,
        details: e.details,
      );
    } on MissingPluginException catch (e) {
      throw VGLiveGreenScreenException(
        code: VGLiveGreenScreenErrorCode.unknown,
        message: e.message ?? '$method is not implemented on this platform.',
        cause: e,
      );
    }
  }
}
