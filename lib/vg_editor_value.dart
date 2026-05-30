// vg_editor_value.dart
// Vanguard Media Engine — Phase 7 Stage 7.7
//
// Immutable snapshot of VGEditorController state for ValueNotifier.
//
// Design rules (Opus M2):
//   - Immutable value type — all fields final.
//   - Held by VGEditorController extends ValueNotifier<VGEditorValue>.
//   - copyWith enables efficient incremental updates without full rebuilds.
//   - VGEditorController replaces the value by calling notifyListeners() after
//     each state mutation via: value = value.copyWith(...).

import 'vg_editor_draft.dart';

/// Immutable snapshot of a [VGEditorController]'s observable state.
///
/// [VGEditorController] extends `ValueNotifier<VGEditorValue>`. Every time the
/// controller transitions to a new state (e.g. playback starts, draft updates,
/// export completes), it replaces its [ValueNotifier.value] with a new
/// [VGEditorValue] via [copyWith] and calls [notifyListeners].
///
/// Widgets consuming a [VGEditorController] should use [ValueListenableBuilder]
/// or [ListenableBuilder] with `controller.value` to rebuild efficiently on
/// state changes.
final class VGEditorValue {
  /// Creates a snapshot of the controller's observable state.
  const VGEditorValue({
    required this.draft,
    this.textureId,
    this.currentPTS = 0.0,
    this.isPlaying = false,
    this.isReady = false,
    this.isExporting = false,
    this.statusMessage,
  });

  /// Convenience factory for the initial controller state.
  ///
  /// Sets [isReady] = false, [isPlaying] = false, [currentPTS] = 0.0,
  /// [textureId] = null, [isExporting] = false.
  factory VGEditorValue.initial(VGEditorDraft draft) {
    return VGEditorValue(
      draft: draft,
      statusMessage: 'Initializing…',
    );
  }

  // ── Fields ─────────────────────────────────────────────────────────────────

  /// The active composition recipe. Immutable. Replaced by [VGEditorController.updateDraft].
  final VGEditorDraft draft;

  /// Flutter texture ID for the active timeline renderer.
  ///
  /// Null until [VGEditorController.initialize] completes successfully.
  /// Also becomes null transiently during [VGEditorController.updateDraft]
  /// while the native timeline is being rebuilt.
  final int? textureId;

  /// Current playhead position in seconds.
  ///
  /// Updated continuously from `onTimelineFrame` native callbacks while
  /// playing, and set to 0.0 after [VGEditorController.updateDraft].
  final double currentPTS;

  /// Whether the timeline is currently advancing (play loop active).
  final bool isPlaying;

  /// Whether the controller has been initialized and a valid [textureId]
  /// is available. False until [VGEditorController.initialize] completes.
  final bool isReady;

  /// Whether an export operation is currently in progress.
  final bool isExporting;

  /// Human-readable status message for display in the playground UI.
  ///
  /// Null when idle. Updated by controller lifecycle transitions.
  final String? statusMessage;

  // ── Derived helpers ────────────────────────────────────────────────────────

  /// The total timeline duration from the active draft in seconds.
  ///
  /// Convenience alias for [draft.durationSeconds].
  double get durationSeconds => draft.durationSeconds;

  // ── copyWith ───────────────────────────────────────────────────────────────

  /// Returns a copy of this value with the specified fields replaced.
  ///
  /// Use the `clearStatusMessage` flag to explicitly null-out `statusMessage`
  /// (since null cannot be distinguished from "not provided" in normal copyWith).
  VGEditorValue copyWith({
    VGEditorDraft? draft,
    Object? textureId = _kNoValue,
    double? currentPTS,
    bool? isPlaying,
    bool? isReady,
    bool? isExporting,
    Object? statusMessage = _kNoValue,
  }) {
    return VGEditorValue(
      draft: draft ?? this.draft,
      textureId: textureId == _kNoValue ? this.textureId : textureId as int?,
      currentPTS: currentPTS ?? this.currentPTS,
      isPlaying: isPlaying ?? this.isPlaying,
      isReady: isReady ?? this.isReady,
      isExporting: isExporting ?? this.isExporting,
      statusMessage: statusMessage == _kNoValue
          ? this.statusMessage
          : statusMessage as String?,
    );
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorValue &&
          other.draft == draft &&
          other.textureId == textureId &&
          other.currentPTS == currentPTS &&
          other.isPlaying == isPlaying &&
          other.isReady == isReady &&
          other.isExporting == isExporting &&
          other.statusMessage == statusMessage;

  @override
  int get hashCode => Object.hash(
        draft,
        textureId,
        currentPTS,
        isPlaying,
        isReady,
        isExporting,
        statusMessage,
      );

  @override
  String toString() => 'VGEditorValue('
      'draft: ${draft.id}, '
      'textureId: $textureId, '
      'pts: ${currentPTS.toStringAsFixed(2)}s, '
      'playing: $isPlaying, '
      'ready: $isReady, '
      'exporting: $isExporting, '
      'status: $statusMessage)';
}

// ── Sentinel for copyWith nullable fields ─────────────────────────────────────
const _kNoValue = Object();
