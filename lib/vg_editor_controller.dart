// vg_editor_controller.dart
// Vanguard Media Engine — Phase 7 Stage 7.7
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.7 — EDITOR CONTROLLER API
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGEditorController is the formal Dart-side coordinator for the Phase 7
// timeline editor API. It wraps the proven Phase 7.6 dev_ MethodChannel routes
// behind a typed, lifecycle-safe, ValueNotifier-based interface.
//
// DESIGN PRINCIPLES:
//   - Zero native changes. All native routes are the existing dev_ proof routes.
//   - Controller does NOT call setMethodCallHandler (Opus M1).
//     The owning widget/playground sets the handler and delegates to:
//       controller.handleNativeCallback(call)
//   - dispose() is synchronous (Opus M3). disposeAsync() performs native cleanup.
//   - State is exposed through ValueNotifier<VGEditorValue> for Flutter-native
//     reactivity without external state management dependencies.
//   - Concurrent operations are guarded by _busy flag.
//   - All methods throw StateError after dispose.
//
// NATIVE METHOD CHANNEL ROUTES (dev_ proof paths, DEC-138):
//   dev_createTimelineTexture → initialize()
//   dev_timelinePlay          → play()
//   dev_timelinePause         → pause()
//   dev_timelineSeek          → seek()
//   dev_updateTimeline        → updateDraft()
//   dev_timelineExport        → export()
//   dev_disposeTimeline       → disposeAsync()
//
// NATIVE CALLBACKS (delegated from owning widget):
//   onTimelineFrame → handleNativeCallback → updates currentPTS + ptsStream
//   onTimelineEOS   → handleNativeCallback → sets isPlaying=false + eosStream
//
// TEMPORARY PROOF FLAG:
//   useRealVideoClips — constructor parameter, marked as dev/proof-only.
//   The native dev_ routes currently generate fixture clips based on this flag
//   rather than using the draft's sourcePaths. This is a Stage 7.7 limitation
//   that will be resolved when native routes consume full VGEditorDraft maps.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';
import 'vg_editor_export_result.dart';
import 'vg_editor_value.dart';

/// The formal Dart-side controller for the Phase 7 timeline editor API.
///
/// [VGEditorController] coordinates the native `dev_*` MethodChannel routes
/// behind a typed, lifecycle-safe, [ValueNotifier]-based interface.
///
/// ## Usage
///
/// ```dart
/// // 1. Create with an initial draft.
/// final controller = VGEditorController(initialDraft: draft);
///
/// // 2. Set the MethodChannel handler in the owning widget's initState,
/// //    delegating callbacks to the controller (Opus M1).
/// _channel.setMethodCallHandler(controller.handleNativeCallback);
///
/// // 3. Initialize the native timeline texture.
/// await controller.initialize();
///
/// // 4. Use value.textureId to display the preview.
/// Texture(textureId: controller.value.textureId!)
///
/// // 5. Dispose (both sync and async) in widget dispose().
/// await controller.disposeAsync();
/// controller.dispose();
/// ```
///
/// ## MethodChannel Ownership (Opus M1)
///
/// [VGEditorController] **never** calls [MethodChannel.setMethodCallHandler].
/// The owning widget is responsible for registering the handler and delegating
/// to [handleNativeCallback]. This prevents replacing an existing handler on
/// the shared `vanguard_media_engine` channel.
///
/// ## Disposal (Opus M3)
///
/// - [disposeAsync] performs the async native teardown (`dev_disposeTimeline`).
/// - [dispose] is synchronous — it closes streams and calls `super.dispose()`.
/// - In the owning widget's `dispose()`, call `disposeAsync()` first (if
///   `mounted` context permits), then `dispose()`.
class VGEditorController extends ValueNotifier<VGEditorValue> {
  /// Creates a [VGEditorController] with the given [initialDraft].
  ///
  /// [channel] defaults to the shared `vanguard_media_engine` MethodChannel.
  /// Inject a different channel in tests to mock native behaviour.
  ///
  /// [useRealVideoClips] — **proof-only, dev-internal flag**.
  /// When true, the native `dev_*` routes generate real H.264 moving-pattern
  /// clips instead of solid-color synthetic clips. This flag is passed through
  /// the wire args because the current native dev routes use fixture clip
  /// generation rather than the draft's [VGClipDescriptor.sourcePath] values.
  /// Will be removed once native routes consume full draft maps.
  VGEditorController({
    required VGEditorDraft initialDraft,
    MethodChannel? channel,
    this.useRealVideoClips = true,
  })  : _channel = channel ?? const MethodChannel('vanguard_media_engine'),
        super(VGEditorValue.initial(initialDraft));

  // ── Channel ────────────────────────────────────────────────────────────────

  final MethodChannel _channel;

  // ── Dev proof flag ─────────────────────────────────────────────────────────

  /// **Dev/proof-only.** Controls whether the native layer generates real H.264
  /// moving-pattern clips (true) or solid-color synthetic clips (false).
  ///
  /// This is a Stage 7.7 limitation — the native dev_ routes do not yet
  /// consume the draft's [VGClipDescriptor.sourcePath] values. Will be removed
  /// in a future stage when the native layer fully hydrates from the draft.
  // ignore: diagnostic_describe_all_properties
  final bool useRealVideoClips;

  // ── Streams ────────────────────────────────────────────────────────────────

  final StreamController<double> _ptsController =
      StreamController<double>.broadcast();
  final StreamController<void> _eosController =
      StreamController<void>.broadcast();

  /// Broadcast stream emitting the current playhead position (in seconds) on
  /// every `onTimelineFrame` native callback.
  ///
  /// Use this for granular PTS updates independent of [ValueNotifier] rebuilds.
  Stream<double> get ptsStream => _ptsController.stream;

  /// Broadcast stream emitting an event when the timeline reaches end-of-stream.
  Stream<void> get eosStream => _eosController.stream;

  // ── Guards ─────────────────────────────────────────────────────────────────

  /// Whether an async operation is currently in progress.
  bool _busy = false;

  /// Whether [dispose] has been called.
  bool _disposed = false;

  // ── Convenience accessors ──────────────────────────────────────────────────

  /// The active draft. Immutable. Updated by [updateDraft].
  VGEditorDraft get draft => value.draft;

  /// The Flutter texture ID for the active timeline renderer.
  /// Null until [initialize] completes.
  int? get textureId => value.textureId;

  /// Current playhead position in seconds.
  double get currentPTS => value.currentPTS;

  /// Whether the timeline is currently playing.
  bool get isPlaying => value.isPlaying;

  /// Whether the controller is initialized and ready for playback.
  bool get isReady => value.isReady;

  /// Whether an export is currently in progress.
  bool get isExporting => value.isExporting;

  // ── Native callback delegation (Opus M1) ────────────────────────────────────

  /// Handles native → Dart MethodChannel callbacks delegated by the owning
  /// widget.
  ///
  /// The owning widget must register its own [MethodChannel.setMethodCallHandler]
  /// and forward calls here. This controller never registers its own handler
  /// to avoid replacing handlers on the shared channel (Opus M1).
  ///
  /// Handled callbacks:
  /// - `onTimelineFrame` — updates [currentPTS] and emits [ptsStream].
  /// - `onTimelineEOS`   — sets [isPlaying] = false and emits [eosStream].
  Future<dynamic> handleNativeCallback(MethodCall call) async {
    if (_disposed) return null;

    switch (call.method) {
      case 'onTimelineFrame':
        final args = call.arguments as Map?;
        final pts = (args?['pts'] as num?)?.toDouble();
        if (pts != null) {
          if (!_ptsController.isClosed) _ptsController.add(pts);
          value = value.copyWith(currentPTS: pts);
          notifyListeners();
        }
        break;

      case 'onTimelineEOS':
        if (!_eosController.isClosed) _eosController.add(null);
        value = value.copyWith(
          isPlaying: false,
          statusMessage: 'End of timeline',
        );
        notifyListeners();
        break;
    }
    return null;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Initializes the native timeline texture using the current draft.
  ///
  /// Maps to `dev_createTimelineTexture`. On success, [value.textureId] is set
  /// and [value.isReady] becomes true.
  ///
  /// Throws [StateError] if already disposed.
  /// Throws [PlatformException] on native failure.
  Future<void> initialize() async {
    _assertNotDisposed();
    if (_busy) return;
    _busy = true;

    value = value.copyWith(
      isReady: false,
      textureId: null,
      statusMessage: 'Preparing timeline…',
    );
    notifyListeners();

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'dev_createTimelineTexture',
        {
          'useSyntheticClips': !useRealVideoClips,
          'useRealVideoClips': useRealVideoClips,
        },
      );

      final id = (result?['textureId'] as num?)?.toInt();
      if (id == null || id < 0) {
        throw StateError(
          '[VGEditorController] initialize: native returned invalid textureId=$id',
        );
      }

      value = value.copyWith(
        textureId: id,
        isReady: true,
        currentPTS: 0.0,
        isPlaying: false,
        statusMessage: 'Ready — ${value.draft.durationSeconds.toStringAsFixed(1)}s',
      );
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  /// Starts or resumes timeline playback.
  ///
  /// Maps to `dev_timelinePlay`. No-op if already playing, not ready, or busy.
  ///
  /// Throws [StateError] if disposed.
  Future<void> play() async {
    _assertNotDisposed();
    if (!value.isReady || _busy || value.isPlaying) return;

    try {
      await _channel.invokeMethod<void>('dev_timelinePlay');
      value = value.copyWith(isPlaying: true, statusMessage: 'Playing');
      notifyListeners();
    } on PlatformException catch (e) {
      value = value.copyWith(statusMessage: 'Play error: ${e.message}');
      notifyListeners();
      rethrow;
    }
  }

  /// Pauses timeline playback.
  ///
  /// Maps to `dev_timelinePause`. No-op if already paused, not ready, or busy.
  ///
  /// Throws [StateError] if disposed.
  Future<void> pause() async {
    _assertNotDisposed();
    if (!value.isReady || _busy || !value.isPlaying) return;

    try {
      await _channel.invokeMethod<void>('dev_timelinePause');
      value = value.copyWith(
        isPlaying: false,
        statusMessage:
            'Paused at ${value.currentPTS.toStringAsFixed(2)}s',
      );
      notifyListeners();
    } on PlatformException catch (e) {
      value = value.copyWith(statusMessage: 'Pause error: ${e.message}');
      notifyListeners();
      rethrow;
    }
  }

  /// Seeks the timeline to [seconds].
  ///
  /// Maps to `dev_timelineSeek`. No-op if not ready.
  ///
  /// Throws [StateError] if disposed.
  Future<void> seek(double seconds) async {
    _assertNotDisposed();
    if (!value.isReady) return;

    try {
      await _channel.invokeMethod<void>(
        'dev_timelineSeek',
        {'seconds': seconds},
      );
      value = value.copyWith(
        currentPTS: seconds,
        statusMessage: 'Seeked to ${seconds.toStringAsFixed(2)}s',
      );
      notifyListeners();
    } on PlatformException catch (e) {
      value = value.copyWith(statusMessage: 'Seek error: ${e.message}');
      notifyListeners();
      rethrow;
    }
  }

  // ── Draft mutation ─────────────────────────────────────────────────────────

  /// Replaces the active draft and rebuilds the native timeline.
  ///
  /// Maps to `dev_updateTimeline` (tear-down-and-rebuild pattern from 7.6).
  /// Pauses playback before rebuild. Resets [currentPTS] to 0.0 on success.
  ///
  /// The native route uses [useRealVideoClips] and extracts trim values from
  /// the first two clips in the draft. This is a Stage 7.7 limitation —
  /// full draft → native mapping is deferred to a future stage.
  ///
  /// Throws [StateError] if disposed or busy.
  Future<void> updateDraft(VGEditorDraft nextDraft) async {
    _assertNotDisposed();
    if (_busy) return;

    // Pause before rebuild.
    if (value.isPlaying) await pause();

    _busy = true;
    // Clear texture immediately so stale frames disappear.
    value = value.copyWith(
      draft: nextDraft,
      textureId: null,
      isReady: false,
      currentPTS: 0.0,
      isPlaying: false,
      statusMessage: 'Rebuilding timeline…',
    );
    notifyListeners();

    try {
      // Extract trim state from the first two clips for the dev_ route.
      // Stage 7.7: native dev_updateTimeline uses these four trim values
      // rather than parsing the full VGEditorDraft map.
      final trimArgs = _buildTrimArgs(nextDraft);

      final result = await _channel.invokeMapMethod<String, dynamic>(
        'dev_updateTimeline',
        {
          'useRealVideoClips': useRealVideoClips,
          ...trimArgs,
        },
      );

      final id = (result?['textureId'] as num?)?.toInt();
      if (id == null || id < 0) {
        throw StateError(
          '[VGEditorController] updateDraft: native returned invalid textureId=$id',
        );
      }

      value = value.copyWith(
        textureId: id,
        isReady: true,
        statusMessage:
            'Timeline rebuilt — ${nextDraft.durationSeconds.toStringAsFixed(1)}s',
      );
      notifyListeners();
    } catch (e) {
      value = value.copyWith(
        isReady: false,
        statusMessage: 'Rebuild error: $e',
      );
      notifyListeners();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  // ── Export ─────────────────────────────────────────────────────────────────

  /// Exports the current draft as an MP4 video file.
  ///
  /// Maps to `dev_timelineExport`. Creates an independent native compositor —
  /// does not reuse the playback runtime. Pauses playback before export.
  ///
  /// Returns a [VGEditorExportResult] on success.
  /// Throws [StateError] if disposed, not ready, or another export is running.
  /// Throws [PlatformException] on native failure.
  Future<VGEditorExportResult> export(VGEditorExportRequest request) async {
    _assertNotDisposed();
    if (!value.isReady) {
      throw StateError('[VGEditorController] export: controller is not ready');
    }
    if (value.isExporting) {
      throw StateError(
          '[VGEditorController] export: an export is already in progress');
    }

    // Pause before export.
    if (value.isPlaying) await pause();

    value = value.copyWith(
      isExporting: true,
      statusMessage: 'Exporting timeline…',
    );
    notifyListeners();

    try {
      final trimArgs = _buildTrimArgs(value.draft);

      final result = await _channel.invokeMapMethod<String, dynamic>(
        'dev_timelineExport',
        {
          'useRealVideoClips': useRealVideoClips,
          ...trimArgs,
          ...request.toMap(),
        },
      );

      if (result == null) {
        throw StateError(
          '[VGEditorController] export: native returned null result',
        );
      }

      final exportResult = VGEditorExportResult.fromMap(
        result.map((k, v) => MapEntry<Object?, Object?>(k, v)),
      );
      if (exportResult == null) {
        throw StateError(
          '[VGEditorController] export: native returned failure result',
        );
      }

      value = value.copyWith(
        isExporting: false,
        statusMessage:
            'Export complete — ${exportResult.durationSeconds.toStringAsFixed(2)}s',
      );
      notifyListeners();
      return exportResult;
    } catch (e) {
      value = value.copyWith(
        isExporting: false,
        statusMessage: 'Export error: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  // ── Disposal (Opus M3) ─────────────────────────────────────────────────────

  /// Asynchronously tears down the native timeline.
  ///
  /// Maps to `dev_disposeTimeline`. Safe to call multiple times (idempotent).
  ///
  /// Call this before [dispose] in the owning widget's dispose lifecycle.
  Future<void> disposeAsync() async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('dev_disposeTimeline');
    } catch (_) {
      // Best-effort — native may already be gone.
    }
  }

  /// Synchronously closes streams and releases [ValueNotifier] resources.
  ///
  /// Implements [ValueNotifier.dispose] contract — synchronous (Opus M3).
  ///
  /// Call [disposeAsync] first to perform native teardown, then call this.
  /// Safe to call if [disposeAsync] was not called — native teardown is
  /// fire-and-forgotten in that case.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    // Close streams before super.dispose() to avoid adding to closed streams.
    _ptsController.close();
    _eosController.close();

    // Fire-and-forget native teardown if disposeAsync() was not called.
    // This matches VanguardEngine._disposeSync() pattern (line 233).
    _channel.invokeMethod<void>('dev_disposeTimeline').catchError((_) {});

    super.dispose();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError(
        '[VGEditorController] method called after dispose()',
      );
    }
  }

  /// Extracts the trim wire args expected by the native dev_ routes from the
  /// active draft's first two clips.
  ///
  /// Stage 7.7: the native dev_ routes expect explicit trim args rather than
  /// parsing a full draft map. This adapter maps the draft's clip trim windows
  /// into the established 7.6 wire format.
  Map<String, double> _buildTrimArgs(VGEditorDraft draft) {
    final clipA = draft.clips.isNotEmpty ? draft.clips[0] : null;
    final clipB = draft.clips.length > 1 ? draft.clips[1] : null;

    return {
      'trimAStart': clipA?.trimStartSeconds ?? 0.0,
      'trimAEnd': clipA?.trimEndSeconds ?? 5.0,
      'trimBStart': clipB?.trimStartSeconds ?? 0.0,
      'trimBEnd': clipB?.trimEndSeconds ?? 5.0,
    };
  }

  // ── Debug ──────────────────────────────────────────────────────────────────

  @override
  String toString() => 'VGEditorController('
      'draftId: ${draft.id}, '
      'textureId: $textureId, '
      'pts: ${currentPTS.toStringAsFixed(2)}s, '
      'ready: $isReady, '
      'playing: $isPlaying, '
      'exporting: $isExporting, '
      'disposed: $_disposed)';
}
