// vg_reverse_sidecar_status.dart
// Vanguard Media Engine — Phase 7.20D (DEC-155)
//
// Dart-side model for reverse sidecar asset state.
// Mirrors VGReverseSidecarState / VGReverseSidecarStatus in
// VGReverseSidecarManager.h (Phase 7.20A).
//
// Used by VGEditorController.prepareReverseSidecars() and
// VGEditorController.getSidecarStatus().

/// Lifecycle state of a single reverse sidecar asset.
///
/// State transitions (mirrors VGReverseSidecarState in VGReverseSidecarManager.h):
///
///   [ idle ] ──(prepareReverseSidecars)──► [ preparing ]
///   [ preparing ] ──(success)──► [ ready ]
///   [ preparing ] ──(error)──► [ failed ]
///   [ preparing/ready ] ──(params changed)──► [ invalidated ]
///   [ invalidated ] ──(cleanup complete)──► [ idle ]
///   [ failed ] ──(retry)──► [ preparing ]
enum VGReverseSidecarState {
  /// No sidecar task has been started for this clip.
  idle,

  /// Background H.264 All-Intra transcode is currently in progress.
  preparing,

  /// Sidecar .mov file exists and is ready for compositor use.
  ready,

  /// A non-cancellation error occurred during transcoding.
  /// See [VGReverseSidecarStatus.errorMessage] for details.
  failed,

  /// Clip parameters changed or sidecar was explicitly invalidated.
  /// Callers should re-trigger [VGEditorController.prepareReverseSidecars]
  /// if the clip is still reversed.
  invalidated,

  /// Unknown / future native state — forward-compatible default.
  unknown,
}

/// Immutable snapshot of a reverse sidecar asset's lifecycle state.
///
/// Returned by:
///   - [VGEditorController.prepareReverseSidecars] (one entry per reversed clip)
///   - [VGEditorController.getSidecarStatus]
///
/// Mirrors VGReverseSidecarStatus (@interface) in VGReverseSidecarManager.h.
final class VGReverseSidecarStatus {
  const VGReverseSidecarStatus({
    required this.clipId,
    required this.state,
    this.sidecarPath,
    this.errorMessage,
    this.progress = 0.0,
  });

  /// Stable clip identifier from the timeline descriptor.
  final String clipId;

  /// Current lifecycle state of this sidecar.
  final VGReverseSidecarState state;

  /// Absolute path to the ready sidecar .mov file.
  ///
  /// Non-null only when [state] == [VGReverseSidecarState.ready].
  /// The file lives under NSTemporaryDirectory()/VGReverseSidecars/ and
  /// may be evicted by iOS under disk pressure — callers must handle a
  /// disappearing sidecar by re-triggering [VGEditorController.prepareReverseSidecars].
  final String? sidecarPath;

  /// Human-readable error description.
  ///
  /// Non-null only when [state] == [VGReverseSidecarState.failed].
  final String? errorMessage;

  /// Transcode progress in [0.0, 1.0].
  ///
  /// 0.0 when idle / failed / invalidated. 1.0 when ready.
  /// Updated periodically during [VGReverseSidecarState.preparing].
  final double progress;

  // ── Deserialization ──────────────────────────────────────────────────────

  /// Deserialises from a MethodChannel response map.
  ///
  /// Tolerant of missing fields — returns an idle status for [clipId] if
  /// required keys are absent.
  static VGReverseSidecarStatus fromMap(Map<Object?, Object?> map) {
    final clipId   = map['clipId']   as String? ?? '';
    final stateStr = map['state']    as String? ?? 'idle';
    final state = switch (stateStr) {
      'idle'        => VGReverseSidecarState.idle,
      'preparing'   => VGReverseSidecarState.preparing,
      'ready'       => VGReverseSidecarState.ready,
      'failed'      => VGReverseSidecarState.failed,
      'invalidated' => VGReverseSidecarState.invalidated,
      _             => VGReverseSidecarState.unknown,
    };
    final rawProgress = (map['progress'] as num?)?.toDouble() ?? 0.0;
    return VGReverseSidecarStatus(
      clipId:       clipId,
      state:        state,
      sidecarPath:  map['sidecarPath']  as String?,
      errorMessage: map['errorMessage'] as String?,
      progress:     rawProgress.clamp(0.0, 1.0),
    );
  }

  @override
  String toString() => 'VGReverseSidecarStatus('
      'clipId: $clipId, '
      'state: $state, '
      'progress: ${progress.toStringAsFixed(2)}, '
      'sidecarPath: $sidecarPath, '
      'errorMessage: $errorMessage)';
}
