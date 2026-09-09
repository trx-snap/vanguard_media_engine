// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.

import 'package:flutter/services.dart';

import 'vg_duet_composition_descriptor.dart';
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
}
