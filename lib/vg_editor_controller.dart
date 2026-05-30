// vg_editor_controller.dart
// Vanguard Media Engine — Phase 7 Stage 7.8
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.8 — NATIVE INGESTION & PRODUCTION ROUTE HARDENING
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGEditorController is the formal Dart-side coordinator for the Phase 7
// timeline editor API. It wraps MethodChannel routes behind a typed,
// lifecycle-safe, ValueNotifier-based interface.
//
// DESIGN PRINCIPLES:
//   - Controller does NOT call setMethodCallHandler (Opus M1).
//     The owning widget/playground sets the handler and delegates to:
//       controller.handleNativeCallback(call)
//   - dispose() is synchronous (Opus M3). disposeAsync() performs native cleanup.
//   - State is exposed through ValueNotifier<VGEditorValue> for Flutter-native
//     reactivity without external state management dependencies.
//   - Concurrent operations are guarded by _busy flag.
//   - All methods throw StateError after dispose.
//
// PRODUCTION NATIVE METHOD CHANNEL ROUTES (Phase 7.8, DEC-140):
//   createTimelineTexture → initialize()
//   timelinePlay          → play()
//   timelinePause         → pause()
//   timelineSeek          → seek()
//   updateTimeline        → updateDraft()
//   exportTimeline        → export()
//   disposeTimeline       → disposeAsync() / dispose()
//
// LEGACY DEV ROUTES (retained for playground compatibility, DEC-138):
//   dev_createTimelineTexture  (accessed via legacy VGEditorController path
//   dev_timelinePlay            when useRealVideoClips is explicitly set for
//   dev_timelinePause           playground use)
//   dev_timelineSeek
//   dev_updateTimeline
//   dev_timelineExport
//   dev_disposeTimeline
//
// NATIVE CALLBACKS (delegated from owning widget):
//   onTimelineFrame → handleNativeCallback → updates currentPTS + ptsStream
//   onTimelineEOS   → handleNativeCallback → sets isPlaying=false + eosStream
//
// PAYLOAD CONTRACT (Phase 7.8):
//   Production routes send: { 'draft': draft.toMap() }
//   The full VGEditorDraft is serialized and consumed natively.
//   No fixture-generation flags are sent on production routes.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';
import 'vg_editor_export_result.dart';
import 'vg_editor_value.dart';

/// The formal Dart-side controller for the Phase 7 timeline editor API.
///
/// [VGEditorController] coordinates native MethodChannel routes
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
/// - [disposeAsync] performs the async native teardown (`disposeTimeline`).
/// - [dispose] is synchronous — it closes streams and calls `super.dispose()`.
/// - In the owning widget's `dispose()`, call `disposeAsync()` first (if
///   `mounted` context permits), then `dispose()`.
class VGEditorController extends ValueNotifier<VGEditorValue> {
  /// Creates a [VGEditorController] with the given [initialDraft].
  ///
  /// [channel] defaults to the shared `vanguard_media_engine` MethodChannel.
  /// Inject a different channel in tests to mock native behaviour.
  ///
  /// [useRealVideoClips] — **deprecated, dev-internal flag**.
  /// Previously controlled whether the native `dev_*` routes generate real
  /// H.264 clips or solid-color synthetic clips. Retained for backward
  /// compatibility with legacy dev routes and existing tests. Production
  /// routes ignore this parameter entirely; they always consume the full
  /// [VGEditorDraft.clips] sourcePath values (Phase 7.8, DEC-140).
  VGEditorController({
    required VGEditorDraft initialDraft,
    MethodChannel? channel,
    @Deprecated(
      'Phase 7.8: production editor routes consume real VGEditorDraft '
      'sourcePath values. This flag is retained only for legacy dev routes.',
    )
    // ignore: deprecated_member_use_from_same_package
    this.useRealVideoClips = true,
  })  : _channel = channel ?? const MethodChannel('vanguard_media_engine'),
        super(VGEditorValue.initial(initialDraft));

  // ── Channel ────────────────────────────────────────────────────────────────

  final MethodChannel _channel;

  // ── Dev proof flag (deprecated) ────────────────────────────────────────────

  /// **Deprecated — dev/proof-only.** Controls whether legacy `dev_*` routes
  /// generate real H.264 moving-pattern clips (true) or solid-color synthetic
  /// clips (false).
  ///
  /// Production routes introduced in Phase 7.8 (DEC-140) ignore this flag
  /// entirely. It is retained only for backward compatibility with the legacy
  /// `dev_*` playground and existing tests. Will be removed in a future stage.
  @Deprecated(
    'Phase 7.8: production editor routes consume real VGEditorDraft '
    'sourcePath values. This flag is retained only for legacy dev routes.',
  )
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
  /// Maps to `createTimelineTexture` (Phase 7.8 production route, DEC-140).
  /// Sends the full [VGEditorDraft] serialized under the `'draft'` key.
  /// On success, [value.textureId] is set and [value.isReady] becomes true.
  ///
  /// Throws [StateError] if already disposed.
  /// Throws [PlatformException] on native failure (e.g. FILE_UNREADABLE,
  /// MISSING_DRAFT, EMPTY_CLIPS, UNSUPPORTED_MEDIA_KIND).
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
        'createTimelineTexture',
        {
          'draft': value.draft.toMap(),
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
    } on PlatformException catch (e) {
      value = value.copyWith(
        isReady: false,
        statusMessage: 'Initialize error [${e.code}]: ${e.message}',
      );
      notifyListeners();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  /// Starts or resumes timeline playback.
  ///
  /// Maps to `timelinePlay` (Phase 7.8 production route).
  /// No-op if already playing, not ready, or busy.
  ///
  /// Throws [StateError] if disposed.
  Future<void> play() async {
    _assertNotDisposed();
    if (!value.isReady || _busy || value.isPlaying) return;

    try {
      await _channel.invokeMethod<void>('timelinePlay');
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
  /// Maps to `timelinePause` (Phase 7.8 production route).
  /// No-op if already paused, not ready, or busy.
  ///
  /// Throws [StateError] if disposed.
  Future<void> pause() async {
    _assertNotDisposed();
    if (!value.isReady || _busy || !value.isPlaying) return;

    try {
      await _channel.invokeMethod<void>('timelinePause');
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
  /// Maps to `timelineSeek` (Phase 7.8 production route).
  /// No-op if not ready.
  ///
  /// Throws [StateError] if disposed.
  Future<void> seek(double seconds) async {
    _assertNotDisposed();
    if (!value.isReady) return;

    try {
      await _channel.invokeMethod<void>(
        'timelineSeek',
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
  /// Maps to `updateTimeline` (Phase 7.8 production route, DEC-140).
  /// Sends the full [nextDraft] serialized under the `'draft'` key.
  /// Pauses playback before rebuild. Resets [currentPTS] to 0.0 on success.
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
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'updateTimeline',
        {
          'draft': nextDraft.toMap(),
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
    } on PlatformException catch (e) {
      value = value.copyWith(
        isReady: false,
        statusMessage: 'Rebuild error [${e.code}]: ${e.message}',
      );
      notifyListeners();
      rethrow;
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
  /// Maps to `exportTimeline` (Phase 7.8 production route, DEC-140).
  /// Sends the full active [VGEditorDraft] under `'draft'` plus export
  /// configuration fields from [request]. Creates an independent native
  /// compositor — does not reuse the playback runtime.
  /// Pauses playback before export.
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
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'exportTimeline',
        {
          'draft': value.draft.toMap(),
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
    } on PlatformException catch (e) {
      value = value.copyWith(
        isExporting: false,
        statusMessage: 'Export error [${e.code}]: ${e.message}',
      );
      notifyListeners();
      rethrow;
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
  /// Maps to `disposeTimeline` (Phase 7.8 production route).
  /// Safe to call multiple times (idempotent).
  ///
  /// Call this before [dispose] in the owning widget's dispose lifecycle.
  Future<void> disposeAsync() async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('disposeTimeline');
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
    _channel.invokeMethod<void>('disposeTimeline').catchError((_) {});

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
