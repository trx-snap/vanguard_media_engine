// Copyright 2026, Connects. All rights reserved.
// Pure Dart except the injectable MethodChannel — no dart:io, no dart:ui.

import 'package:flutter/services.dart';

import 'vg_green_screen_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Abstract platform interface
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract generic green-screen platform interface.
///
/// Decouples the Dart contracts from the native engine implementation so any
/// caller (Duet, live meeting/calling, going live, camera, Universal Editor)
/// can run an offline green-screen export through one method.
abstract class VGGreenScreenPlatformInterface {
  const VGGreenScreenPlatformInterface();

  /// Runs an offline green-screen export described by [request] and returns
  /// the finalized output on success.
  ///
  /// Throws [VGGreenScreenException] with:
  /// - [VGGreenScreenErrorCode.invalidArgument] when the native side rejects
  ///   the request before any work starts (missing files, output already
  ///   exists, bad geometry, mask files missing/short, API below 29);
  /// - [VGGreenScreenErrorCode.exportBusy] when another green-screen export
  ///   is already active (only one may run at a time on Android);
  /// - [VGGreenScreenErrorCode.compositionFailed] when the engine reaches a
  ///   failed or cancelled terminal state; [VGGreenScreenException.details]
  ///   then carries the engine result map (reason, telemetry, tmp flags).
  ///
  /// The engine writes `outputPath.tmp` and renames it only after verified
  /// success; on every other terminal path the tmp and any engine-owned
  /// temporary background clip are deleted.
  Future<VGGreenScreenExportResult> exportGreenScreenComposition({
    required VGGreenScreenExportRequest request,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Default MethodChannel implementation
// ─────────────────────────────────────────────────────────────────────────────

/// Default [VGGreenScreenPlatformInterface] backed by an injectable
/// [MethodChannel].
///
/// Channel name: `vanguard_media_engine`
/// Native method name: `exportGreenScreenComposition`
///
/// Payload: [VGGreenScreenExportRequest.toMap].
/// Success reply: Map parsed by [VGGreenScreenExportResult.fromMap]
/// (`outputPath`, `durationMs`, `fileSizeBytes`, terminal/reason, counts,
/// mask size, `tmpExists`, background/foreground telemetry).
/// Error codes from native: `INVALID_ARG`, `export_busy`, `composition_failed`.
class MethodChannelVGGreenScreenPlatform
    extends VGGreenScreenPlatformInterface {
  /// The method channel used to communicate with the native engine.
  final MethodChannel channel;

  const MethodChannelVGGreenScreenPlatform({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  static const String _methodExport = 'exportGreenScreenComposition';

  @override
  Future<VGGreenScreenExportResult> exportGreenScreenComposition({
    required VGGreenScreenExportRequest request,
  }) async {
    try {
      final result = await channel.invokeMethod<Map>(
        _methodExport,
        request.toMap(),
      );
      if (result == null) {
        throw const VGGreenScreenException(
          code: VGGreenScreenErrorCode.compositionFailed,
          message: '$_methodExport returned null result.',
        );
      }
      return VGGreenScreenExportResult.fromMap(
        Map<String, dynamic>.from(result),
      );
    } on VGGreenScreenException {
      rethrow;
    } on PlatformException catch (e) {
      throw VGGreenScreenException(
        code: VGGreenScreenErrorCode.fromPlatformCode(e.code),
        message: e.message ?? '$_methodExport failed.',
        cause: e,
        details: e.details,
      );
    } on MissingPluginException catch (e) {
      throw VGGreenScreenException(
        code: VGGreenScreenErrorCode.unknown,
        message:
            e.message ?? '$_methodExport is not implemented on this platform.',
        cause: e,
      );
    }
  }
}
