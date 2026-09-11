// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.

import 'package:flutter/services.dart';

import 'vg_duet_composition_descriptor.dart';
import 'vg_duet_export.dart';
import 'vg_duet_models.dart';
import 'vg_duet_source.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Abstract platform interface
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract Duet platform interface.
///
/// Decouples the Dart contracts from the native engine implementation.
/// All mutating methods require a [sessionId] returned by [initializeSession].
abstract class VGDuetPlatformInterface {
  const VGDuetPlatformInterface();

  /// Initializes a new Duet session for the given [source] and [trimWindow].
  ///
  /// Returns a unique [sessionId] string that must be passed to all subsequent
  /// calls. Throws [VGDuetException] with [VGDuetErrorCode.sourceInvalid] if
  /// the source cannot be opened by the native engine.
  Future<String> initializeSession({
    required VGDuetSource source,
    required VGDuetTrimWindow trimWindow,
  });

  /// Updates the active layout configuration for [sessionId].
  Future<void> updateLayout({
    required String sessionId,
    required VGDuetLayoutConfig layoutConfig,
  });

  /// Sets the recording speed multiplier for [sessionId].
  ///
  /// [speed] must be one of 0.3, 0.5, 1.0, 2.0, 3.0.
  Future<void> setRecordingSpeed({
    required String sessionId,
    required double speed,
  });

  /// Sets the independent audio mix gains for [sessionId].
  ///
  /// Both [sourceGain] and [micGain] must be in the range [0.0, 1.0].
  Future<void> setAudioMixGains({
    required String sessionId,
    required double sourceGain,
    required double micGain,
  });

  /// Starts recording for [sessionId].
  Future<void> startRecording({required String sessionId});

  /// Pauses recording for [sessionId] (segment boundary).
  Future<void> pauseRecording({required String sessionId});

  /// Resumes recording for [sessionId] after a pause.
  Future<void> resumeRecording({required String sessionId});

  /// Deletes the most recently recorded segment for [sessionId].
  Future<void> deleteLastSegment({required String sessionId});

  /// Stops recording for [sessionId] and returns the [VGDuetCaptureResult].
  Future<VGDuetCaptureResult> stopRecording({required String sessionId});

  /// Releases all native resources associated with [sessionId].
  Future<void> disposeSession({required String sessionId});

  /// Attaches a Flutter texture to [sessionId] for true Duet preview.
  ///
  /// Returns a [VGDuetPreviewTexture] with the registered [textureId].
  /// Repeated calls for the same active session are idempotent; the existing
  /// texture descriptor is returned without allocating a second texture.
  /// Throws [VGDuetException] with [VGDuetErrorCode.compositionFailed] on
  /// allocation or layout failure.
  Future<VGDuetPreviewTexture> attachPreviewTexture({
    required String sessionId,
    VGDuetSize canvasSize = const VGDuetSize(1080, 1920),
    VGDuetLayoutConfig? layoutConfig,
  });

  /// Detaches and releases the preview texture for [sessionId].
  ///
  /// Idempotent: if no preview attachment exists for an otherwise active
  /// session, succeeds as a no-op. Unknown sessions return
  /// [VGDuetException] with code 'session_not_found'.
  Future<void> detachPreviewTexture({required String sessionId});

  // ── Slice 5B-A: descriptor-bound offline export ───────────────────────────

  /// Exports a Duet composition offline, descriptor-bound (no sessionId).
  ///
  /// Encodes a video-only MP4 to [outputPath] from [descriptor]. The output
  /// file is written atomically: the engine writes to a temp path and renames
  /// on success; failure deletes the temp. Fails with
  /// [VGDuetException(code: compositionFailed)] if [outputPath] already exists,
  /// if encoding fails, or if another export is already active
  /// (`export_busy` from the platform maps to [VGDuetErrorCode.compositionFailed]).
  ///
  /// Only one Duet export may be active at a time on Android.
  ///
  /// Parameters:
  /// - [descriptor]: full composition descriptor; must have a valid local
  ///   source file path reachable on disk.
  /// - [outputPath]: absolute path for the final MP4 output.
  /// - [targetSize]: output video dimensions (default 1080×1920).
  /// - [videoBitRate]: encoding bit rate in bits/s (default 8 Mbps).
  Future<VGDuetExportResult> exportDuetComposition({
    required VGDuetCompositionDescriptor descriptor,
    required String outputPath,
    VGDuetSize targetSize = const VGDuetSize(1080, 1920),
    int videoBitRate = 8000000,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Default MethodChannel implementation
// ─────────────────────────────────────────────────────────────────────────────

/// Default [VGDuetPlatformInterface] backed by an injectable [MethodChannel].
///
/// Channel name: `vanguard_media_engine`
///
/// Method names are documented per-method below. The channel is injectable
/// to allow unit tests to inject a [MockMethodChannel] without any platform
/// setup.
class MethodChannelVGDuetPlatform extends VGDuetPlatformInterface {
  /// The method channel used to communicate with the native engine.
  final MethodChannel channel;

  const MethodChannelVGDuetPlatform({
    this.channel = const MethodChannel('vanguard_media_engine'),
  });

  // ── initializeDuetSession ──────────────────────────────────────────────────
  @override
  Future<String> initializeSession({
    required VGDuetSource source,
    required VGDuetTrimWindow trimWindow,
  }) async {
    try {
      final result = await channel.invokeMethod<String>(
        'initializeDuetSession',
        <String, dynamic>{
          'source': source.toMap(),
          'trimWindow': trimWindow.toMap(),
        },
      );
      if (result == null || result.isEmpty) {
        throw VGDuetException(
          code: VGDuetErrorCode.sourceInvalid,
          message: 'initializeDuetSession returned null or empty sessionId.',
        );
      }
      return result;
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.sourceInvalid,
        message: e.message ?? 'initializeDuetSession failed.',
        cause: e,
      );
    }
  }

  // ── updateDuetLayout ───────────────────────────────────────────────────────
  @override
  Future<void> updateLayout({
    required String sessionId,
    required VGDuetLayoutConfig layoutConfig,
  }) async {
    try {
      await channel.invokeMethod<void>('updateDuetLayout', <String, dynamic>{
        'sessionId': sessionId,
        'layoutConfig': layoutConfig.toMap(),
      });
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message: e.message ?? 'updateDuetLayout failed.',
        cause: e,
      );
    }
  }

  // ── setDuetRecordingSpeed ──────────────────────────────────────────────────
  @override
  Future<void> setRecordingSpeed({
    required String sessionId,
    required double speed,
  }) async {
    try {
      await channel.invokeMethod<void>(
        'setDuetRecordingSpeed',
        <String, dynamic>{'sessionId': sessionId, 'speed': speed},
      );
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.unknown,
        message: e.message ?? 'setDuetRecordingSpeed failed.',
        cause: e,
      );
    }
  }

  // ── setDuetAudioMixGains ───────────────────────────────────────────────────
  @override
  Future<void> setAudioMixGains({
    required String sessionId,
    required double sourceGain,
    required double micGain,
  }) async {
    try {
      await channel.invokeMethod<void>(
        'setDuetAudioMixGains',
        <String, dynamic>{
          'sessionId': sessionId,
          'sourceGain': sourceGain,
          'micGain': micGain,
        },
      );
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.unknown,
        message: e.message ?? 'setDuetAudioMixGains failed.',
        cause: e,
      );
    }
  }

  // ── startDuetRecording ────────────────────────────────────────────────────
  @override
  Future<void> startRecording({required String sessionId}) async {
    try {
      await channel.invokeMethod<void>('startDuetRecording', <String, dynamic>{
        'sessionId': sessionId,
      });
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.cameraUnavailable,
        message: e.message ?? 'startDuetRecording failed.',
        cause: e,
      );
    }
  }

  // ── pauseDuetRecording ────────────────────────────────────────────────────
  @override
  Future<void> pauseRecording({required String sessionId}) async {
    try {
      await channel.invokeMethod<void>('pauseDuetRecording', <String, dynamic>{
        'sessionId': sessionId,
      });
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.unknown,
        message: e.message ?? 'pauseDuetRecording failed.',
        cause: e,
      );
    }
  }

  // ── resumeDuetRecording ───────────────────────────────────────────────────
  @override
  Future<void> resumeRecording({required String sessionId}) async {
    try {
      await channel.invokeMethod<void>('resumeDuetRecording', <String, dynamic>{
        'sessionId': sessionId,
      });
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.unknown,
        message: e.message ?? 'resumeDuetRecording failed.',
        cause: e,
      );
    }
  }

  // ── deleteLastDuetSegment ─────────────────────────────────────────────────
  @override
  Future<void> deleteLastSegment({required String sessionId}) async {
    try {
      await channel.invokeMethod<void>(
        'deleteLastDuetSegment',
        <String, dynamic>{'sessionId': sessionId},
      );
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.unknown,
        message: e.message ?? 'deleteLastDuetSegment failed.',
        cause: e,
      );
    }
  }

  // ── stopDuetRecording ─────────────────────────────────────────────────────
  @override
  Future<VGDuetCaptureResult> stopRecording({required String sessionId}) async {
    try {
      final result = await channel.invokeMethod<Map>(
        'stopDuetRecording',
        <String, dynamic>{'sessionId': sessionId},
      );
      if (result == null) {
        throw VGDuetException(
          code: VGDuetErrorCode.compositionFailed,
          message: 'stopDuetRecording returned null.',
        );
      }
      final map = Map<String, dynamic>.from(result);
      final segmentAssets =
          (map['segmentAssets'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [];
      final segmentsList =
          (map['segments'] as List<dynamic>?)
              ?.map(
                (e) =>
                    VGDuetSegment.fromMap(Map<String, dynamic>.from(e as Map)),
              )
              .toList() ??
          [];

      // Reconstruct the descriptor from the returned map.
      final descriptorMap = Map<String, dynamic>.from(
        map['compositionDescriptor'] as Map,
      );
      final descriptor = VGDuetCompositionDescriptor.fromMap(descriptorMap);

      // Prefer the native-provided segmentCount; fall back deterministically.
      final int segmentCount;
      final rawCount = map['segmentCount'];
      if (rawCount is num) {
        segmentCount = rawCount.toInt();
      } else if (segmentsList.isNotEmpty) {
        segmentCount = segmentsList.length;
      } else if (descriptor.segments.isNotEmpty) {
        segmentCount = descriptor.segments.length;
      } else if (segmentAssets.isNotEmpty) {
        segmentCount = segmentAssets.length;
      } else {
        throw VGDuetException(
          code: VGDuetErrorCode.compositionFailed,
          message:
              'stopDuetRecording: cannot determine segmentCount — '
              'native map missing segmentCount, segments, and segmentAssets.',
        );
      }

      return VGDuetCaptureResult(
        compositionDescriptor: descriptor,
        segmentAssets: segmentAssets,
        totalDurationMs: (map['totalDurationMs'] as num).toInt(),
        segmentCount: segmentCount,
        proofOutputPath: map['proofOutputPath'] as String?,
      );
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message: e.message ?? 'stopDuetRecording failed.',
        cause: e,
      );
    }
  }

  // ── disposeDuetSession ────────────────────────────────────────────────────
  @override
  Future<void> disposeSession({required String sessionId}) async {
    try {
      await channel.invokeMethod<void>('disposeDuetSession', <String, dynamic>{
        'sessionId': sessionId,
      });
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.unknown,
        message: e.message ?? 'disposeDuetSession failed.',
        cause: e,
      );
    }
  }

  // ── attachDuetPreviewTexture ───────────────────────────────────────────────
  @override
  Future<VGDuetPreviewTexture> attachPreviewTexture({
    required String sessionId,
    VGDuetSize canvasSize = const VGDuetSize(1080, 1920),
    VGDuetLayoutConfig? layoutConfig,
  }) async {
    try {
      final payload = <String, dynamic>{
        'sessionId': sessionId,
        'canvasSize': canvasSize.toMap(),
        if (layoutConfig != null) 'layoutConfig': layoutConfig.toMap(),
      };
      final result = await channel.invokeMethod<Map>(
        'attachDuetPreviewTexture',
        payload,
      );
      if (result == null) {
        throw VGDuetException(
          code: VGDuetErrorCode.compositionFailed,
          message: 'attachDuetPreviewTexture returned null.',
        );
      }
      return VGDuetPreviewTexture.fromMap(Map<String, dynamic>.from(result));
    } on VGDuetException {
      rethrow;
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message: e.message ?? 'attachDuetPreviewTexture failed.',
        cause: e,
      );
    }
  }

  // ── detachDuetPreviewTexture ───────────────────────────────────────────────
  @override
  Future<void> detachPreviewTexture({required String sessionId}) async {
    try {
      await channel.invokeMethod<void>(
        'detachDuetPreviewTexture',
        <String, dynamic>{'sessionId': sessionId},
      );
    } on PlatformException catch (e) {
      // session_not_found and invalid_state are surfaced as compositionFailed.
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message: e.message ?? 'detachDuetPreviewTexture failed.',
        cause: e,
      );
    }
  }

  // ── exportDuetComposition (Slice 5B-A) ────────────────────────────────────

  /// Native method name: `exportDuetComposition`
  ///
  /// Payload keys: `descriptor` (Map), `outputPath` (String),
  ///   `targetSize` (Map{width, height}), `videoBitRate` (int).
  ///
  /// Success reply: Map with keys `outputPath`, `durationMs`, `fileSizeBytes`.
  /// Error codes from native: `export_busy`, `source_invalid`, `disk_full`, etc.
  /// All native errors are wrapped in [VGDuetException(code: compositionFailed)].
  @override
  Future<VGDuetExportResult> exportDuetComposition({
    required VGDuetCompositionDescriptor descriptor,
    required String outputPath,
    VGDuetSize targetSize = const VGDuetSize(1080, 1920),
    int videoBitRate = 8000000,
  }) async {
    try {
      final result = await channel
          .invokeMethod<Map>('exportDuetComposition', <String, dynamic>{
            'descriptor': descriptor.toMap(),
            'outputPath': outputPath,
            'targetSize': targetSize.toMap(),
            'videoBitRate': videoBitRate,
          });
      if (result == null) {
        throw VGDuetException(
          code: VGDuetErrorCode.compositionFailed,
          message: 'exportDuetComposition returned null result.',
        );
      }
      return VGDuetExportResult.fromMap(Map<String, dynamic>.from(result));
    } on VGDuetException {
      rethrow;
    } on PlatformException catch (e) {
      throw VGDuetException(
        code: VGDuetErrorCode.compositionFailed,
        message: e.message ?? 'exportDuetComposition failed.',
        cause: e,
      );
    }
  }
}
