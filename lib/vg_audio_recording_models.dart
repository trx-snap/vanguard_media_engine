// vg_audio_recording_models.dart
// Vanguard Media Engine — Audio Slice M
//
// Immutable result models for VGEditorController.startAudioRecording and
// VGEditorController.stopAudioRecording.
//
// Design rules:
//   - Pure value types. Failures throw from the controller.
//   - fromMap unpacks the native result dictionary returned by the MethodChannel.
//   - Isolated here to keep VGEditorController and VGAudioPlaybackService slim.

/// Result returned from [VGEditorController.startAudioRecording].
///
/// [filePath]             — Absolute path to the file being recorded to.
/// [startPTS]             — Authoritative timeline PTS (seconds) at the moment
///                          native recording started, computed from the
///                          VGTimelineStateSnapshot.
/// [isHeadphonesConnected] — YES if a wired or wireless headphone route was
///                           active when recording started. Exposed so the
///                           caller can surface appropriate UX warnings.
final class VGAudioRecordingStartResult {
  const VGAudioRecordingStartResult({
    required this.filePath,
    required this.startPTS,
    required this.isHeadphonesConnected,
  });

  /// Absolute path to the recording file.
  final String filePath;

  /// Authoritative timeline PTS at recording start (seconds).
  final double startPTS;

  /// Whether headphones (wired or Bluetooth) were connected at start time.
  final bool isHeadphonesConnected;

  // ── Deserialisation ──────────────────────────────────────────────────────

  /// Deserialises from the native start result dictionary.
  ///
  /// Expected map shape:
  /// ```json
  /// {
  ///   "filePath": "/absolute/path/to/recording.m4a",
  ///   "startPTS": 3.14159,
  ///   "isHeadphonesConnected": true
  /// }
  /// ```
  ///
  /// Returns `null` if required fields are missing or malformed.
  static VGAudioRecordingStartResult? fromMap(Map<Object?, Object?> map) {
    final filePath = map['filePath'] as String?;
    final startPTS = (map['startPTS'] as num?)?.toDouble();
    if (filePath == null || filePath.isEmpty || startPTS == null) return null;
    return VGAudioRecordingStartResult(
      filePath: filePath,
      startPTS: startPTS,
      isHeadphonesConnected: (map['isHeadphonesConnected'] as bool?) ?? false,
    );
  }

  // ── Serialisation ────────────────────────────────────────────────────────

  /// Serialises to a JSON-compatible map (for tests and logging).
  Map<String, Object?> toMap() => <String, Object?>{
        'filePath': filePath,
        'startPTS': startPTS,
        'isHeadphonesConnected': isHeadphonesConnected,
      };

  // ── Equality ─────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGAudioRecordingStartResult &&
          other.filePath == filePath &&
          other.startPTS == startPTS &&
          other.isHeadphonesConnected == isHeadphonesConnected;

  @override
  int get hashCode => Object.hash(filePath, startPTS, isHeadphonesConnected);

  @override
  String toString() => 'VGAudioRecordingStartResult('
      'filePath: ${filePath.split('/').last}, '
      'startPTS: ${startPTS.toStringAsFixed(3)}s, '
      'headphones: $isHeadphonesConnected)';
}

// ─────────────────────────────────────────────────────────────────────────────

/// Result returned from [VGEditorController.stopAudioRecording].
///
/// [filePath]        — Absolute path to the completed recording file.
/// [startPTS]        — The same authoritative start PTS captured at record start.
/// [durationSeconds] — Duration of the recorded audio in seconds.
final class VGAudioRecordingStopResult {
  const VGAudioRecordingStopResult({
    required this.filePath,
    required this.startPTS,
    required this.durationSeconds,
  });

  /// Absolute path to the completed recording.
  final String filePath;

  /// Authoritative timeline PTS at which recording began (seconds).
  final double startPTS;

  /// Duration of the recorded audio in seconds.
  final double durationSeconds;

  // ── Deserialisation ──────────────────────────────────────────────────────

  /// Deserialises from the native stop result dictionary.
  ///
  /// Expected map shape:
  /// ```json
  /// {
  ///   "filePath": "/absolute/path/to/recording.m4a",
  ///   "startPTS": 3.14159,
  ///   "durationSeconds": 4.012
  /// }
  /// ```
  ///
  /// Returns `null` if required fields are missing or malformed.
  static VGAudioRecordingStopResult? fromMap(Map<Object?, Object?> map) {
    final filePath = map['filePath'] as String?;
    final startPTS = (map['startPTS'] as num?)?.toDouble();
    final durationSeconds = (map['durationSeconds'] as num?)?.toDouble();
    if (filePath == null || filePath.isEmpty ||
        startPTS == null ||
        durationSeconds == null) return null;
    return VGAudioRecordingStopResult(
      filePath: filePath,
      startPTS: startPTS,
      durationSeconds: durationSeconds,
    );
  }

  // ── Serialisation ────────────────────────────────────────────────────────

  /// Serialises to a JSON-compatible map (for tests and logging).
  Map<String, Object?> toMap() => <String, Object?>{
        'filePath': filePath,
        'startPTS': startPTS,
        'durationSeconds': durationSeconds,
      };

  // ── Equality ─────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGAudioRecordingStopResult &&
          other.filePath == filePath &&
          other.startPTS == startPTS &&
          other.durationSeconds == durationSeconds;

  @override
  int get hashCode => Object.hash(filePath, startPTS, durationSeconds);

  @override
  String toString() => 'VGAudioRecordingStopResult('
      'filePath: ${filePath.split('/').last}, '
      'startPTS: ${startPTS.toStringAsFixed(3)}s, '
      'duration: ${durationSeconds.toStringAsFixed(3)}s)';
}
