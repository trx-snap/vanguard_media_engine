// vg_audio_recording_models.dart
// Vanguard Media Engine — Audio Slice N
//
// Immutable result models for VGEditorController.startAudioRecording and
// VGEditorController.stopAudioRecording.
//
// Design rules:
//   - Pure value types. Failures throw from the controller.
//   - fromMap unpacks the native result dictionary returned by the MethodChannel.
//   - Isolated here to keep VGEditorController and VGAudioPlaybackService slim.
//   - Android-compatible: no iOS-specific field names are required by callers.
//
// Slice N additions:
//   - VGAudioRouteSnapshotResult: route info nested under "audioRoute" key.
//   - VGTransitionStatus: session-restore and preview-recovery diagnostics
//     nested under "transitionStatus" key in the stop result.
//   - VGAudioRecordingStartResult.audioRoute: nested route snapshot.
//   - VGAudioRecordingStopResult.transitionStatus: nested diagnostic status.
//   - Backward-compat: sessionRestored getter delegates to transitionStatus.

// ─── VGAudioRouteSnapshotResult ───────────────────────────────────────────────

/// Immutable route information captured after AVAudioSession switches to
/// PlayAndRecord. Parsed from the nested "audioRoute" map in the start result.
///
/// [activeInputType]       — normalised port type of the first active input, or
///                           "none" when no input is available.
///                           Values: "builtInMic", "headsetMic", "bluetoothHfp",
///                           "usbAudio", "lineIn", "other", "none".
/// [activeInputIsExternal] — true for headsetMic, bluetoothHfp, usbAudio,
///                           lineIn, and "other" (recordable, unclassified).
///                           false only for builtInMic and "none".
/// [availableInputTypes]   — deduplicated, sorted list of available input types.
/// [hasHeadphoneOutput]    — true if any output is wired headphones, BT HFP,
///                           A2DP, or LE.
/// [inputAvailable]        — true if currentRoute.inputs was non-empty after
///                           PlayAndRecord activation.
final class VGAudioRouteSnapshotResult {
  const VGAudioRouteSnapshotResult({
    required this.activeInputType,
    required this.activeInputName,
    required this.activeInputUID,
    required this.availableInputTypes,
    required this.activeOutputTypes,
    required this.hasHeadphoneOutput,
    required this.activeInputIsExternal,
    required this.inputAvailable,
    this.activeInputDataSourceName,
  });

  final String activeInputType;
  final String activeInputName;
  final String activeInputUID;
  final String? activeInputDataSourceName;
  final List<String> availableInputTypes;
  final List<String> activeOutputTypes;
  final bool hasHeadphoneOutput;
  final bool activeInputIsExternal;
  final bool inputAvailable;

  /// Parses from the nested "audioRoute" sub-map in the start result.
  /// Returns null if [map] is null or missing the required activeInputType key.
  static VGAudioRouteSnapshotResult? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final activeInputType = map['activeInputType'] as String?;
    if (activeInputType == null) return null;
    return VGAudioRouteSnapshotResult(
      activeInputType: activeInputType,
      activeInputName: (map['activeInputName'] as String?) ?? '',
      activeInputUID: (map['activeInputUID'] as String?) ?? '',
      activeInputDataSourceName: map['activeInputDataSourceName'] as String?,
      availableInputTypes: _toStringList(map['availableInputTypes']),
      activeOutputTypes: _toStringList(map['activeOutputTypes']),
      hasHeadphoneOutput: (map['hasHeadphoneOutput'] as bool?) ?? false,
      activeInputIsExternal: (map['activeInputIsExternal'] as bool?) ?? false,
      inputAvailable: (map['inputAvailable'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'activeInputType': activeInputType,
        'activeInputName': activeInputName,
        'activeInputUID': activeInputUID,
        'activeInputDataSourceName': activeInputDataSourceName,
        'availableInputTypes': availableInputTypes,
        'activeOutputTypes': activeOutputTypes,
        'hasHeadphoneOutput': hasHeadphoneOutput,
        'activeInputIsExternal': activeInputIsExternal,
        'inputAvailable': inputAvailable,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGAudioRouteSnapshotResult &&
          other.activeInputType == activeInputType &&
          other.activeInputName == activeInputName &&
          other.activeInputUID == activeInputUID &&
          other.inputAvailable == inputAvailable &&
          other.hasHeadphoneOutput == hasHeadphoneOutput &&
          other.activeInputIsExternal == activeInputIsExternal;

  @override
  int get hashCode =>
      Object.hash(activeInputType, activeInputName, activeInputUID,
          inputAvailable, hasHeadphoneOutput, activeInputIsExternal);

  @override
  String toString() => 'VGAudioRouteSnapshotResult('
      'activeInputType: $activeInputType, '
      'hasHeadphoneOutput: $hasHeadphoneOutput, '
      'activeInputIsExternal: $activeInputIsExternal, '
      'inputAvailable: $inputAvailable)';

  static List<String> _toStringList(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList(growable: false);
    }
    return const [];
  }
}

// ─── VGTransitionStatus ───────────────────────────────────────────────────────

/// Session-restore and preview-recovery diagnostics from a stop operation.
/// Nested under the "transitionStatus" key in the stop result map.
///
/// [sessionRestored]   — true if AVAudioSession was restored to Playback.
/// [previewRecovered]  — true if the audio preview engine recovered successfully.
/// [sessionErrorCode]  — optional opaque code string when sessionRestored=false.
/// [previewErrorCode]  — optional opaque code string when previewRecovered=false.
///                       "RECOVERY_RUNTIME_NIL" if stop was called with no runtime.
/// [terminationReason] — optional platform-neutral reason when a system event
///                       terminated an active recording. Absent (null) for normal
///                       user-initiated stops.
///
/// Frozen [terminationReason] values:
///   "interruption" — AVAudioSession interruption (phone call, Siri, alarm).
///   "background"   — App entered the background.
///   "routeLost"    — Physical audio device removed (oldDeviceUnavailable).
///   "routeChanged" — New audio device appeared during active capture.
///
/// Missing or malformed transitionStatus defaults all booleans to false and
/// all optional strings to null.
final class VGTransitionStatus {
  const VGTransitionStatus({
    required this.sessionRestored,
    required this.previewRecovered,
    this.sessionErrorCode,
    this.previewErrorCode,
    this.terminationReason,
  });

  final bool sessionRestored;
  final bool previewRecovered;

  /// Non-null when sessionRestored is false. Opaque; treat as diagnostic only.
  final String? sessionErrorCode;

  /// Non-null when previewRecovered is false. Opaque; treat as diagnostic only.
  final String? previewErrorCode;

  /// Non-null when a system event (interruption, background, route loss)
  /// terminated an active recording before the user called stopAudioRecording.
  ///
  /// Platform-neutral frozen values: "interruption", "background",
  /// "routeLost", "routeChanged".
  ///
  /// Null for normal user-initiated stops.
  final String? terminationReason;

  /// Parses from the nested "transitionStatus" sub-map.
  /// Returns a fully-false instance if [map] is null or malformed.
  static VGTransitionStatus fromMap(Map<Object?, Object?>? map) {
    if (map == null) {
      return const VGTransitionStatus(
          sessionRestored: false, previewRecovered: false);
    }
    return VGTransitionStatus(
      sessionRestored:  (map['sessionRestored'] as bool?) ?? false,
      previewRecovered: (map['previewRecovered'] as bool?) ?? false,
      sessionErrorCode:  map['sessionErrorCode'] as String?,
      previewErrorCode:  map['previewErrorCode'] as String?,
      terminationReason: map['terminationReason'] as String?,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'sessionRestored':  sessionRestored,
        'previewRecovered': previewRecovered,
        if (sessionErrorCode  != null) 'sessionErrorCode':  sessionErrorCode,
        if (previewErrorCode  != null) 'previewErrorCode':  previewErrorCode,
        if (terminationReason != null) 'terminationReason': terminationReason,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGTransitionStatus &&
          other.sessionRestored  == sessionRestored  &&
          other.previewRecovered == previewRecovered &&
          other.sessionErrorCode == sessionErrorCode &&
          other.previewErrorCode == previewErrorCode &&
          other.terminationReason == terminationReason;

  @override
  int get hashCode => Object.hash(
      sessionRestored,
      previewRecovered,
      sessionErrorCode,
      previewErrorCode,
      terminationReason);

  @override
  String toString() => 'VGTransitionStatus('
      'sessionRestored: $sessionRestored, '
      'previewRecovered: $previewRecovered'
      '${sessionErrorCode  != null ? ", sessionErrorCode: $sessionErrorCode"   : ""}'
      '${previewErrorCode  != null ? ", previewErrorCode: $previewErrorCode"   : ""}'
      '${terminationReason != null ? ", terminationReason: $terminationReason" : ""}'
      ')';
}

// ─── VGAudioRecordingStartResult ──────────────────────────────────────────────

/// Result returned from [VGEditorController.startAudioRecording].
///
/// [filePath]              — Absolute path to the file being recorded to.
/// [startPTS]              — Authoritative timeline PTS (seconds) at the moment
///                           native recording started.
/// [isHeadphonesConnected] — true if a wired or wireless headphone output was
///                           active when recording started. Derived by the
///                           handler from routeSnapshot.hasHeadphoneOutput.
///                           Preserved at the top level for backward compatibility.
/// [audioRoute]            — Full route snapshot nested under "audioRoute".
///                           Null only for legacy callers or malformed maps.
final class VGAudioRecordingStartResult {
  const VGAudioRecordingStartResult({
    required this.filePath,
    required this.startPTS,
    required this.isHeadphonesConnected,
    this.audioRoute,
  });

  /// Absolute path to the recording file.
  final String filePath;

  /// Authoritative timeline PTS at recording start (seconds).
  final double startPTS;

  /// Whether headphones (wired or Bluetooth) were connected at start time.
  final bool isHeadphonesConnected;

  /// Full route details from the coordinator after PlayAndRecord activation.
  /// Parsed from the nested "audioRoute" sub-map.
  final VGAudioRouteSnapshotResult? audioRoute;

  // ── Deserialisation ──────────────────────────────────────────────────────

  /// Deserialises from the native start result dictionary.
  ///
  /// Expected map shape:
  /// ```json
  /// {
  ///   "filePath": "/absolute/path/to/recording.m4a",
  ///   "startPTS": 3.14159,
  ///   "isHeadphonesConnected": true,
  ///   "audioRoute": {
  ///     "activeInputType": "builtInMic",
  ///     ...
  ///   }
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
      audioRoute: VGAudioRouteSnapshotResult.fromMap(
          map['audioRoute'] as Map<Object?, Object?>?),
    );
  }

  // ── Serialisation ────────────────────────────────────────────────────────

  /// Serialises to a JSON-compatible map (for tests and logging).
  Map<String, Object?> toMap() {
    final m = <String, Object?>{
      'filePath': filePath,
      'startPTS': startPTS,
      'isHeadphonesConnected': isHeadphonesConnected,
    };
    if (audioRoute != null) {
      m['audioRoute'] = audioRoute!.toMap();
    }
    return m;
  }

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
      'headphones: $isHeadphonesConnected, '
      'audioRoute: $audioRoute)';
}

// ─── VGAudioRecordingStopResult ───────────────────────────────────────────────

/// Result returned from [VGEditorController.stopAudioRecording].
///
/// [filePath]          — Absolute path to the completed recording file.
/// [startPTS]          — The authoritative start PTS captured at record start.
/// [durationSeconds]   — Duration of the recorded audio in seconds.
/// [transitionStatus]  — Session-restore and preview-recovery diagnostics.
///                       Defaults to all-false when the native map is missing
///                       the "transitionStatus" key.
/// [sessionRestored]   — Compatibility getter; delegates to
///                       transitionStatus.sessionRestored.
final class VGAudioRecordingStopResult {
  const VGAudioRecordingStopResult({
    required this.filePath,
    required this.startPTS,
    required this.durationSeconds,
    VGTransitionStatus? transitionStatus,
  }) : transitionStatus = transitionStatus ??
            const VGTransitionStatus(
                sessionRestored: false, previewRecovered: false);

  /// Absolute path to the completed recording.
  final String filePath;

  /// Authoritative timeline PTS at which recording began (seconds).
  final double startPTS;

  /// Duration of the recorded audio in seconds.
  final double durationSeconds;

  /// Nested session-restore and preview-recovery diagnostics.
  final VGTransitionStatus transitionStatus;

  /// Backward-compatibility getter — delegates to transitionStatus.
  bool get sessionRestored => transitionStatus.sessionRestored;

  // ── Deserialisation ──────────────────────────────────────────────────────

  /// Deserialises from the native stop result dictionary.
  ///
  /// Expected map shape:
  /// ```json
  /// {
  ///   "filePath": "/absolute/path/to/recording.m4a",
  ///   "startPTS": 3.14159,
  ///   "durationSeconds": 4.012,
  ///   "transitionStatus": {
  ///     "sessionRestored": true,
  ///     "previewRecovered": true
  ///   }
  /// }
  /// ```
  ///
  /// Returns `null` if required fields are missing or malformed.
  /// Missing/malformed transitionStatus defaults both booleans to false.
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
      transitionStatus: VGTransitionStatus.fromMap(
          map['transitionStatus'] as Map<Object?, Object?>?),
    );
  }

  // ── Serialisation ────────────────────────────────────────────────────────

  /// Serialises to a JSON-compatible map (for tests and logging).
  Map<String, Object?> toMap() => <String, Object?>{
        'filePath': filePath,
        'startPTS': startPTS,
        'durationSeconds': durationSeconds,
        'transitionStatus': transitionStatus.toMap(),
      };

  // ── Equality ─────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGAudioRecordingStopResult &&
          other.filePath == filePath &&
          other.startPTS == startPTS &&
          other.durationSeconds == durationSeconds &&
          other.transitionStatus == transitionStatus;

  @override
  int get hashCode =>
      Object.hash(filePath, startPTS, durationSeconds, transitionStatus);

  @override
  String toString() => 'VGAudioRecordingStopResult('
      'filePath: ${filePath.split('/').last}, '
      'startPTS: ${startPTS.toStringAsFixed(3)}s, '
      'duration: ${durationSeconds.toStringAsFixed(3)}s, '
      'transitionStatus: $transitionStatus)';
}
