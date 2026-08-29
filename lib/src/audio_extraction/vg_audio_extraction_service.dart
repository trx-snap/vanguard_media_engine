// vg_audio_extraction_service.dart
// vanguard_media_engine — Phase 10-C Slice T Gate 6A
//
// Managed, cancellable audio extraction service.
//
// Architecture (modularity boundary):
//   VGAudioExtractionService  — platform gating + typed results (Dart layer)
//   VanguardAudioExtractionHandler  — registry + lifecycle (Swift handler)
//   VGAudioOnlyExporter  — AVAssetReader/Writer execution + quiescence (ObjC)
//   VanguardMediaEnginePlugin  — thin routing only (Swift plugin)
//
// iOS and Android. Returns [VGAudioExtractionBeginResult.unsupportedPlatform]
// on any other unsupported platform.
//
// Channel contract:
//   beginAudioExtraction   → Map | FlutterError
//   cancelAudioExtraction  → Map | FlutterError
//
// Terminal error codes (normalized, never raw platform strings):
//   invalidArgument, operationAlreadyExists, noAudioTrack, cancelled,
//   readFailure, writeFailure, internalFailure
//
// Cancel disposition codes:
//   cancellationCompleted, alreadyTerminal, notFound
//
// File-preservation invariant:
//   Native may remove its own partial output while quiescing after cancel.
//   Dart must still perform an authoritative idempotent cancelReservation after
//   receiving any cancellation acknowledgement.

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ─── Result and operation types ───────────────────────────────────────────────

/// Normalized terminal error codes for [VGAudioExtractionOperation.result].
enum VGAudioExtractionError {
  invalidArgument,
  operationAlreadyExists,
  noAudioTrack,
  cancelled,
  readFailure,
  writeFailure,
  internalFailure,
}

/// Normalized cancel-call disposition codes.
enum VGAudioExtractionCancelDisposition {
  /// Cancellation quiescence is complete. The native reader and writer are
  /// both terminal; no future write to the output file will occur.
  ///
  /// **Terminal-race note**: this does NOT guarantee [VGAudioExtractionOperation.result]
  /// resolves with [VGAudioExtractionError.cancelled]. If the native pipeline
  /// reached a terminal state (success or failure) before cancellation was
  /// processed, [result] retains that actual outcome. Callers must always
  /// await [result] to determine the authoritative terminal state.
  cancellationCompleted,

  /// The operation had already reached a terminal state before cancel was called.
  alreadyTerminal,

  /// No operation with this ID exists in the native registry.
  notFound,
}

// ─── Cancel exception ─────────────────────────────────────────────────────────

/// Exception thrown by [VGAudioExtractionOperation.cancel] when the native
/// cancel channel call fails with an unexpected [PlatformException] or the
/// native response carries an unrecognized disposition string.
///
/// [error] is always [VGAudioExtractionError.internalFailure].
/// [message] carries a human-readable detail string when available.
///
/// This is a thrown exception, not a result type. It indicates the cancel
/// *request* itself failed, not the extraction operation. The caller must
/// decide whether to retry, abandon, or surface this error. The
/// [VGAudioExtractionOperation.result] future is NOT completed by this
/// exception — it remains pending until native terminal completion fires.
final class VGAudioExtractionCancelException implements Exception {
  /// Always [VGAudioExtractionError.internalFailure].
  final VGAudioExtractionError error;

  /// Optional human-readable detail from the underlying platform error.
  final String? message;

  const VGAudioExtractionCancelException({
    this.error = VGAudioExtractionError.internalFailure,
    this.message,
  });

  @override
  String toString() =>
      'VGAudioExtractionCancelException($error${message != null ? ': $message' : ''})';
}

// ─── Terminal result ──────────────────────────────────────────────────────────

/// Terminal result of an audio extraction operation.
///
/// All payload fields are accessible directly — no cast to a private subtype
/// is required. Construct via the named factories; match via [isSuccess]/
/// [isFailure] or Dart 3 sealed-class pattern matching.
sealed class VGAudioExtractionResult {
  const VGAudioExtractionResult._();

  /// Extraction completed successfully.
  ///
  /// [outputPath] is the absolute path of the produced audio file.
  /// Always non-null on success.
  const factory VGAudioExtractionResult.success(String outputPath) =
      VGAudioExtractionSuccess;

  /// Extraction failed with a normalized error code.
  ///
  /// [error] is always set. [message] is an optional human-readable description.
  const factory VGAudioExtractionResult.failure(
    VGAudioExtractionError error, {
    String? message,
  }) = VGAudioExtractionFailure;

  /// True if this is a success result.
  bool get isSuccess => this is VGAudioExtractionSuccess;

  /// True if this is a failure result.
  bool get isFailure => this is VGAudioExtractionFailure;
}

/// Successful terminal result. [outputPath] is publicly accessible.
final class VGAudioExtractionSuccess extends VGAudioExtractionResult {
  /// Absolute path of the produced audio file.
  final String outputPath;

  const VGAudioExtractionSuccess(this.outputPath) : super._();
}

/// Failure terminal result. [error] and [message] are publicly accessible.
final class VGAudioExtractionFailure extends VGAudioExtractionResult {
  /// Normalized error code describing why extraction failed.
  final VGAudioExtractionError error;

  /// Optional human-readable detail message from the native layer.
  final String? message;

  const VGAudioExtractionFailure(this.error, {this.message}) : super._();
}

// ─── Operation ────────────────────────────────────────────────────────────────

/// An in-progress or completed audio extraction operation.
///
/// [result] completes exactly once with the terminal [VGAudioExtractionResult].
/// [cancel] issues a cancellation request to the native layer and returns a
/// disposition describing the outcome of that request.
///
/// **Cancellation Quiescence Note**:
/// [VGAudioExtractionCancelDisposition.cancellationCompleted] indicates that the native
/// quiescence is already complete (both native reader and writer are fully terminal).
/// It does not guarantee a cancelled result; the authoritative result on [result] may
/// still be success, failure, or cancelled because terminal completion can race
/// with cancellation.
final class VGAudioExtractionOperation {
  VGAudioExtractionOperation._({
    required String operationId,
    required MethodChannel channel,
    required Completer<VGAudioExtractionResult> completer,
  }) : _operationId = operationId,
       _channel = channel,
       _completer = completer;

  final String _operationId;
  final MethodChannel _channel;
  final Completer<VGAudioExtractionResult> _completer;

  /// Future that completes exactly once with the terminal result.
  Future<VGAudioExtractionResult> get result => _completer.future;

  /// Requests cancellation of this operation.
  ///
  /// Returns a [VGAudioExtractionCancelDisposition]:
  ///   - [cancellationCompleted]: native quiescence is complete — reader and
  ///     writer are both terminal. Does NOT guarantee [result] resolves with
  ///     [VGAudioExtractionError.cancelled]; a racing terminal completion
  ///     (success or failure) may have already set the actual outcome. Always
  ///     await [result] for the authoritative terminal state.
  ///   - [alreadyTerminal]: operation reached a terminal state before cancel.
  ///   - [notFound]: operation ID was not found in the native registry.
  ///
  /// Throws [VGAudioExtractionCancelException] on:
  ///   - An unexpected [PlatformException] from the native cancel call.
  ///   - An unrecognized or malformed disposition string in the native response.
  ///
  /// When [VGAudioExtractionCancelException] is thrown, [result] is NOT
  /// completed — it remains pending until native terminal completion fires.
  Future<VGAudioExtractionCancelDisposition> cancel() async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'cancelAudioExtraction',
        {'operationId': _operationId},
      );
    } on PlatformException catch (e) {
      // Do NOT complete result — the operation may still be running.
      // Throw a normalized exception so the caller knows the cancel request
      // itself failed, without polluting the operation result future.
      throw VGAudioExtractionCancelException(
        message:
            'cancelAudioExtraction PlatformException: ${e.code} — ${e.message}',
      );
    }

    final Object? rawDisposition = raw?['disposition'];
    if (rawDisposition is! String) {
      throw VGAudioExtractionCancelException(
        message:
            'cancelAudioExtraction returned non-string disposition: $rawDisposition',
      );
    }
    final parsed = _parseDisposition(rawDisposition);
    if (parsed == null) {
      // Unrecognized or malformed native disposition — throw rather than
      // silently mapping to notFound.
      throw VGAudioExtractionCancelException(
        message:
            'cancelAudioExtraction returned unrecognized disposition: "$rawDisposition"',
      );
    }
    return parsed;
  }

  /// Completes the result future exactly once. No-op if already completed.
  void _complete(VGAudioExtractionResult value) {
    if (!_completer.isCompleted) {
      _completer.complete(value);
    }
  }
}

// ─── Begin result ─────────────────────────────────────────────────────────────

/// Result returned synchronously by [VGAudioExtractionService.begin].
///
/// Payload is accessible directly without casting to private subtypes.
sealed class VGAudioExtractionBeginResult {
  const VGAudioExtractionBeginResult._();

  /// Extraction was accepted and an operation object was created.
  ///
  /// [operation] is publicly accessible; no cast required.
  const factory VGAudioExtractionBeginResult.started(
    VGAudioExtractionOperation operation,
  ) = VGAudioExtractionBeginStarted;

  /// This platform does not support managed audio extraction.
  ///
  /// Returned immediately without creating an operation or invoking any
  /// channel method. No cast required to check for this case.
  static const VGAudioExtractionBeginResult unsupportedPlatform =
      VGAudioExtractionBeginUnsupported._instance;
}

/// Started result. [operation] is publicly accessible.
final class VGAudioExtractionBeginStarted extends VGAudioExtractionBeginResult {
  /// The operation object wrapping this extraction.
  final VGAudioExtractionOperation operation;

  const VGAudioExtractionBeginStarted(this.operation) : super._();
}

/// Unsupported-platform singleton. Accessible as
/// [VGAudioExtractionBeginResult.unsupportedPlatform].
final class VGAudioExtractionBeginUnsupported
    extends VGAudioExtractionBeginResult {
  static const VGAudioExtractionBeginUnsupported _instance =
      VGAudioExtractionBeginUnsupported._();
  const VGAudioExtractionBeginUnsupported._() : super._();
}

// ─── Service ──────────────────────────────────────────────────────────────────

/// Managed, cancellable audio extraction service.
///
/// Uses the existing `vanguard_media_engine` [MethodChannel]. No separate
/// channel is created — all routing goes through the shared plugin channel.
///
/// Platform support: **iOS and Android**. On any other platform, [begin]
/// returns [VGAudioExtractionBeginResult.unsupportedPlatform] synchronously
/// without invoking any channel method.
///
/// [begin] is **synchronous** — it returns immediately with a
/// [VGAudioExtractionBeginResult]. On iOS/Android the native
/// `beginAudioExtraction` call is sent asynchronously;
/// [VGAudioExtractionOperation.result] resolves when the native pipeline
/// reaches a terminal state.
///
/// Usage:
/// ```dart
/// final beginResult = VGAudioExtractionService.begin(
///   operationId: 'op-1',
///   sourcePath:  '/path/to/video.mp4',
///   outputPath:  '/path/to/output.m4a',
/// );
/// switch (beginResult) {
///   case VGAudioExtractionBeginStarted(:final operation):
///     final terminal = await operation.result;
///     if (terminal is VGAudioExtractionSuccess) {
///       print(terminal.outputPath);
///     }
///   case VGAudioExtractionBeginUnsupported():
///     // handle unsupported platform
/// }
/// ```
final class VGAudioExtractionService {
  // Private constructor — static-only API.
  const VGAudioExtractionService._();

  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  static bool? _debugIsIOSOverride;

  /// Controlled test-only setter to override iOS platform detection.
  /// Passing null restores production platform detection.
  @visibleForTesting
  static void debugSetIsIOSOverrideForTesting(bool? value) {
    _debugIsIOSOverride = value;
  }

  /// Begins a managed audio extraction. **Returns synchronously.**
  ///
  /// [operationId] must be non-empty and unique among active extractions.
  /// [sourcePath] must be a non-empty path to a readable media file.
  /// [outputPath] must be a non-empty writable destination path.
  /// [trimStartSeconds] optional trim start (seconds; must be finite and ≥ 0).
  ///   If omitted, trimming starts at 0.
  /// [trimEndSeconds] optional trim end (seconds; must be finite and > start).
  ///   If only [trimEndSeconds] is provided, extraction is [0, end).
  ///   If only [trimStartSeconds] is provided, extraction is [start, EOF).
  ///   Negative, NaN, or infinite values for either bound are rejected as
  ///   [VGAudioExtractionError.invalidArgument] on [operation.result].
  ///
  /// Returns [VGAudioExtractionBeginResult.unsupportedPlatform] immediately on
  /// unsupported platforms — no operation is created, no channel method is invoked.
  ///
  /// On iOS/Android, returns [VGAudioExtractionBeginStarted] immediately. The
  /// native `beginAudioExtraction` call is sent asynchronously and its
  /// completion resolves [VGAudioExtractionOperation.result].
  static VGAudioExtractionBeginResult begin({
    required String operationId,
    required String sourcePath,
    required String outputPath,
    double? trimStartSeconds,
    double? trimEndSeconds,
  }) {
    // Platform gate — iOS/Android only (or overridden for testing).
    final isSupportedPlatform =
        _debugIsIOSOverride ?? (Platform.isIOS || Platform.isAndroid);
    if (!isSupportedPlatform) {
      return VGAudioExtractionBeginResult.unsupportedPlatform;
    }

    // Build operation before any async work so the caller receives an
    // operation handle immediately without awaiting the native begin call.
    final completer = Completer<VGAudioExtractionResult>();
    final operation = VGAudioExtractionOperation._(
      operationId: operationId,
      channel: _channel,
      completer: completer,
    );

    // Detach the native begin call. This unawaited future resolves the
    // completer exactly once when the native pipeline reaches terminal state.
    _beginNative(
      operationId: operationId,
      sourcePath: sourcePath,
      outputPath: outputPath,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      operation: operation,
    );

    return VGAudioExtractionBeginStarted(operation);
  }

  /// Sends the native `beginAudioExtraction` call and resolves [operation]
  /// with the terminal result. Runs detached — the caller does not await this.
  static Future<void> _beginNative({
    required String operationId,
    required String sourcePath,
    required String outputPath,
    required double? trimStartSeconds,
    required double? trimEndSeconds,
    required VGAudioExtractionOperation operation,
  }) async {
    try {
      final args = <String, Object?>{
        'operationId': operationId,
        'sourcePath': sourcePath,
        'outputPath': outputPath,
        'trimStartSeconds': ?trimStartSeconds,
        'trimEndSeconds': ?trimEndSeconds,
      };
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'beginAudioExtraction',
        args,
      );
      final path = raw?['outputPath'] as String?;
      if (path != null) {
        operation._complete(VGAudioExtractionSuccess(path));
      } else {
        operation._complete(
          VGAudioExtractionFailure(
            VGAudioExtractionError.internalFailure,
            message: 'Native returned success without outputPath',
          ),
        );
      }
    } on PlatformException catch (e) {
      operation._complete(
        VGAudioExtractionFailure(_mapErrorCode(e.code), message: e.message),
      );
    } catch (e) {
      operation._complete(
        VGAudioExtractionFailure(
          VGAudioExtractionError.internalFailure,
          message: e.toString(),
        ),
      );
    }
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────

/// Maps a normalized native error code string to [VGAudioExtractionError].
/// Falls through to [internalFailure] for any unrecognized code.
VGAudioExtractionError _mapErrorCode(String code) {
  return switch (code) {
    'invalidArgument' => VGAudioExtractionError.invalidArgument,
    'operationAlreadyExists' => VGAudioExtractionError.operationAlreadyExists,
    'noAudioTrack' => VGAudioExtractionError.noAudioTrack,
    'cancelled' => VGAudioExtractionError.cancelled,
    'readFailure' => VGAudioExtractionError.readFailure,
    'writeFailure' => VGAudioExtractionError.writeFailure,
    _ => VGAudioExtractionError.internalFailure,
  };
}

/// Maps a native disposition string to [VGAudioExtractionCancelDisposition],
/// returning null for any unrecognized string so the caller can throw.
VGAudioExtractionCancelDisposition? _parseDisposition(String disposition) {
  return switch (disposition) {
    'cancellationCompleted' =>
      VGAudioExtractionCancelDisposition.cancellationCompleted,
    'alreadyTerminal' => VGAudioExtractionCancelDisposition.alreadyTerminal,
    'notFound' => VGAudioExtractionCancelDisposition.notFound,
    _ => null,
  };
}
