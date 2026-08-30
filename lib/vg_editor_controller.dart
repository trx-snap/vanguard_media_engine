// vg_editor_controller.dart
// Vanguard Media Engine — Phase 7 Stage 7.8 / Stage 7.13 / Stage 7.14 / Stage 7.15 / Phase 7.19B
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
// CACHE METRICS ROUTES (Phase 7.18B1 native / Phase 7.18B2 Dart, DEC-152):
//   getTimelineCacheStats → getTimelineCacheStats()
//   clearTimelineCache    → clearTimelineCache()
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

import 'src/channel/vanguard_channel_dispatcher.dart';
import 'vg_audio_recording_models.dart';
import 'vg_clip_descriptor.dart';
import 'vg_dual_camera_descriptor.dart';
import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';
import 'vg_editor_export_result.dart';
import 'vg_editor_value.dart';
import 'vg_reverse_sidecar_status.dart';

// ── Phase 10-C Slice R: generic preview-derivation seam ─────────────────────
//
// [VGEditorPreviewDraftDeriver] is a function type that takes a raw authoring
// [VGEditorDraft] (source) and returns a disposable derived draft ready for
// native renderer serialisation.  The deriver must be:
//   - pure (no I/O, no MethodChannel calls)
//   - idempotent (same source → structurally equal output)
//   - ephemeral (the returned draft must not be persisted as authoring state)
//
// The default deriver used by [VGEditorController] is behaviorally identical to:
//   source.flattenOriginalClipAudio().applyAudioCompositionPolicy()
//
// Product-specific derivers (e.g. ConnectsApp Original Sound policy) may be
// injected at construction time via [VGEditorController.previewDraftDeriver].
// Vanguard itself never owns product policy.

/// A pure function from a raw authoring [VGEditorDraft] to a disposable derived
/// draft suitable for native renderer serialisation.
///
/// The returned draft must be ephemeral — it must not be persisted as
/// authoring state, placed in undo/redo history, or re-normalized.
typedef VGEditorPreviewDraftDeriver =
    VGEditorDraft Function(VGEditorDraft source);

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
/// // 2. Initialize the native timeline texture.
/// //    The controller automatically registers its timeline subscription
/// //    with [VanguardChannelDispatcher] when initialize() completes.
/// await controller.initialize();
///
/// // 3. Use value.textureId to display the preview.
/// Texture(textureId: controller.value.textureId!)
///
/// // 4. Dispose (both sync and async) in widget dispose().
/// await controller.disposeAsync();
/// controller.dispose();
/// ```
///
/// ## MethodChannel Ownership
///
/// [VGEditorController] does NOT call [MethodChannel.setMethodCallHandler].
/// Timeline callbacks (onTimelineFrame, onTimelineEOS) are received via
/// [VanguardChannelDispatcher] subscription registered after [initialize]
/// returns a textureId. The dispatcher is the sole handler owner.
///
/// ## Disposal (Opus M3)
///
/// - [disposeAsync] performs the async native teardown (`disposeTimeline`)
///   and unregisters the timeline subscription.
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
    // Phase 10-C Slice R: optional deriver injection.
    // When null, [_derivePreviewDraft] uses the default derivation
    // (flattenOriginalClipAudio + applyAudioCompositionPolicy).
    VGEditorPreviewDraftDeriver? previewDraftDeriver,
  }) : _channel = channel ?? const MethodChannel('vanguard_media_engine'),
       _previewDraftDeriver = previewDraftDeriver,
       super(VGEditorValue.initial(initialDraft));

  // ── Channel ────────────────────────────────────────────────────────────────

  final MethodChannel _channel;

  // ── Phase 10-C Slice R: derivation seam ───────────────────────────────────

  /// Optional injected deriver. When non-null, used by [_derivePreviewDraft]
  /// in [initialize] and [updateDraft] instead of the default derivation.
  final VGEditorPreviewDraftDeriver? _previewDraftDeriver;

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

  // ── Dispatcher subscription ────────────────────────────────────────────────

  /// Active timeline subscription from [VanguardChannelDispatcher].
  /// Registered after [initialize] returns a textureId.
  /// Unregistered in [disposeAsync] / [dispose].
  VGTimelineSubscription? _timelineSubscription;

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

  // ── Teardown — exact-once dispatch (Phase 10-C Slice D teardown fix) ────────
  //
  // _rawTeardownFuture is the bare MethodChannel future for `disposeTimeline`,
  // set the first time native teardown is dispatched. It propagates any
  // PlatformException or error the native side returns.
  //
  // _teardownFuture is the best-effort wrapper: the same dispatch but with
  // errors swallowed via .catchError. This is what [disposeAsync] and the
  // fire-and-forget path in [dispose] return.
  //
  // Both fields are set atomically (same microtask) so there is never a window
  // where one is set and the other is not.
  //
  // Invariants:
  //   - `disposeTimeline` is sent to native exactly once.
  //   - Repeated [disposeAsync] calls join the same best-effort future.
  //   - [disposeAsyncConfirmed] joins the same raw future and propagates errors.
  //   - [disposeAsync] followed by [dispose] does not send a second request.
  //   - [disposeAsyncConfirmed] followed by [disposeAsync] (or vice-versa) shares
  //     the single dispatch.
  //   - [dispose] alone still triggers native teardown (fire-and-forget).
  Future<void>? _rawTeardownFuture;
  Future<void>? _teardownFuture;

  // ── Latest-wins seek coalescer ─────────────────────────────────────────────
  //
  // When the user scrubs rapidly, multiple seek() calls arrive faster than
  // the native compositor can decode and deliver onTimelineFrame callbacks.
  // Without coalescing the channel fills with pending seeks that replay as a
  // backlog after the gesture ends.
  //
  // Strategy (pure Dart, no native changes):
  //   - _pendingCoalescedSeek: the most recently requested seek time.
  //     Updated synchronously on every scrub event by seekCoalesced().
  //   - _coalescedSeekInFlight: true while a native seek() is awaiting its
  //     onTimelineFrame acknowledgement.
  //   - When a seek completes (onTimelineFrame delivers the matching generation),
  //     _drainCoalescedSeek() dispatches the next pending seek if one exists.
  //
  // This ensures at most ONE native seek is active at a time while always
  // converging on the most recently requested position.

  double? _pendingCoalescedSeek;
  bool _coalescedSeekInFlight = false;

  // Generation tracking: native compositor increments generation on each seek.
  // We track the highest generation we dispatched so that onTimelineFrame
  // callbacks for earlier generations can be filtered out.
  int _latestDispatchedGeneration = 0;

  // ── Convenience accessors ──────────────────────────────────────────────────

  /// The active draft. Immutable. Updated by [updateDraft].
  VGEditorDraft get draft => value.draft;

  /// The Flutter texture ID for the active timeline renderer.
  /// Null until [initialize] completes.
  int? get textureId => value.textureId;

  /// Native render width in pixels returned by the active timeline renderer.
  /// Null until [initialize] completes or while rebuilding.
  int? get renderWidth => value.renderWidth;

  /// Native render height in pixels returned by the active timeline renderer.
  /// Null until [initialize] completes or while rebuilding.
  int? get renderHeight => value.renderHeight;

  /// Aspect ratio (width / height) of the rendered timeline texture.
  double? get renderAspectRatio => value.renderAspectRatio;

  /// Current playhead position in seconds.
  double get currentPTS => value.currentPTS;

  /// Whether the timeline is currently playing.
  bool get isPlaying => value.isPlaying;

  /// Whether the controller is initialized and ready for playback.
  bool get isReady => value.isReady;

  /// Whether an export is currently in progress.
  bool get isExporting => value.isExporting;

  // ── Native callback handling ───────────────────────────────────────────────

  /// Handles native → Dart timeline callbacks.
  ///
  /// Internally called when the [VanguardChannelDispatcher] routes
  /// `onTimelineFrame` or `onTimelineEOS` to this controller's subscription.
  ///
  /// This method is also public for backward-compatibility with existing
  /// playgrounds that were written under the Opus M1 pattern. Those playgrounds
  /// may still call this directly, but they no longer need to own a
  /// `setMethodCallHandler` registration — the dispatcher handles routing.
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
        // Pin currentPTS to durationSeconds on EOS so that the replay-at-end
        // check in play() (currentPTS >= durationSeconds) fires reliably.
        //
        // On device the last onTimelineFrame PTS is the decoded frame's
        // presentation timestamp, which is typically a few frames SHORT of the
        // total timeline duration (e.g. 9.97s vs 10.0s). Without this pin the
        // play() condition (9.97 >= 10.0) is false, no seek-to-zero occurs, and
        // native immediately returns EOS again — appearing as if Play did nothing.
        value = value.copyWith(
          isPlaying: false,
          currentPTS: value.draft.durationSeconds,
          statusMessage: 'End of timeline',
        );
        notifyListeners();
        break;
    }
    return null;
  }

  void _onTimelineFrame(double pts, int generation) {
    if (_disposed) return;

    // Track the highest generation we have received from native.
    if (generation > _latestDispatchedGeneration) {
      _latestDispatchedGeneration = generation;
    }

    if (!_ptsController.isClosed) _ptsController.add(pts);
    value = value.copyWith(currentPTS: pts);
    notifyListeners();

    // A frame has arrived — if a coalesced seek was in flight, it has now
    // been acknowledged. Drain any pending next seek.
    if (_coalescedSeekInFlight) {
      _coalescedSeekInFlight = false;
      _drainCoalescedSeek();
    }
  }

  void _onTimelineEOS() {
    if (_disposed) return;
    if (!_eosController.isClosed) _eosController.add(null);
    value = value.copyWith(
      isPlaying: false,
      currentPTS: value.draft.durationSeconds,
      statusMessage: 'End of timeline',
    );
    notifyListeners();
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  // ── Phase 10-C Slice F: preview-derivation boundary ──────────────────────
  //
  // Returns a disposable derived draft suitable for preview serialisation.
  //
  // Contract:
  //   - `source` is the raw authoring draft; it is never mutated.
  //   - The returned draft is ephemeral — it must not be persisted back into
  //     any controller authoring state, undo/redo history or user state.
  //   - Calling this twice with the same unchanged raw source always produces
  //     structurally equal output (idempotent).  Because flattenOriginalClipAudio
  //     derives Original tracks from `source.clips`, repeated calls never
  //     accumulate duplicate tracks.
  //   - Do NOT filter Voiceover before calling this.  Voiceover must pass
  //     through applyAudioCompositionPolicy so that Original muting matches
  //     export policy exactly (preview/export parity).
  //   - `durationSeconds` must be taken from the raw `source`, not from the
  //     derived draft, because derivation does not alter timeline structure.
  /// Returns a disposable derived draft for preview/native serialisation.
  ///
  /// When [_previewDraftDeriver] is set (Phase 10-C Slice R injection), delegates
  /// to it. Otherwise uses the default derivation:
  ///   source.flattenOriginalClipAudio().applyAudioCompositionPolicy()
  ///
  /// Behavioral contract:
  ///   - [source] is the raw authoring draft — never mutated.
  ///   - The returned draft is ephemeral — must not be persisted.
  ///   - Calling twice with the same unchanged source produces equal output.
  VGEditorDraft _derivePreviewDraft(VGEditorDraft source) {
    final deriver = _previewDraftDeriver;
    if (deriver != null) {
      return deriver(source);
    }
    return source.flattenOriginalClipAudio().applyAudioCompositionPolicy();
  }

  /// Initializes the native timeline texture using the current draft.
  ///
  /// Maps to `createTimelineTexture` (Phase 7.8 production route, DEC-140).
  /// Sends the derived preview [VGEditorDraft] serialized under the `'draft'`
  /// key (flattenOriginalClipAudio → applyAudioCompositionPolicy).  The raw
  /// authoring draft is preserved unchanged in controller state.
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
      renderWidth: null,
      renderHeight: null,
      statusMessage: 'Preparing timeline…',
    );
    notifyListeners();

    try {
      // Phase 10-C Slice F: derive the disposable preview draft from the raw
      // authoring draft.  The raw draft (value.draft) is never mutated.
      final previewDraft = _derivePreviewDraft(value.draft);
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'createTimelineTexture',
        {
          'draft': previewDraft.toMap(),
          // Phase 10-C Slice D: authoritative timeline duration for audio scheduling.
          // Taken from the raw draft — derivation does not alter timeline structure.
          'durationSeconds': value.draft.durationSeconds,
        },
      );

      final id = (result?['textureId'] as num?)?.toInt();
      if (id == null || id < 0) {
        throw StateError(
          '[VGEditorController] initialize: native returned invalid textureId=$id',
        );
      }
      final width = (result?['width'] as num?)?.toInt();
      final height = (result?['height'] as num?)?.toInt();

      // Unregister any previous subscription before registering a new one.
      // This prevents stale map entries if initialize() is called more than once.
      final dispatcher = VanguardChannelDispatcher.instance;
      if (_timelineSubscription != null) {
        dispatcher.unregisterTimelineListener(_timelineSubscription!);
        _timelineSubscription = null;
      }
      _timelineSubscription = dispatcher.registerTimelineListener(
        textureId: id,
        onFrame: _onTimelineFrame,
        onEOS: _onTimelineEOS,
      );

      value = value.copyWith(
        textureId: id,
        renderWidth: width,
        renderHeight: height,
        isReady: true,
        currentPTS: 0.0,
        isPlaying: false,
        statusMessage:
            'Ready — ${value.draft.durationSeconds.toStringAsFixed(1)}s',
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
  /// **Replay-at-end behaviour:** If [currentPTS] is at or beyond the draft
  /// duration (i.e. the timeline has reached end-of-stream), this method
  /// automatically seeks to `0.0s` first, then starts playback. This allows
  /// the user to press Play again after the timeline finishes without having
  /// to manually seek to the beginning.
  ///
  /// Throws [StateError] if disposed.
  Future<void> play() async {
    _assertNotDisposed();
    if (!value.isReady || _busy || value.isPlaying) return;

    try {
      // Replay-at-end: if the playhead is at or past the end of the timeline,
      // seek back to the beginning before starting playback so the native
      // compositor does not immediately return EOS on the first frame request.
      final durationSeconds = value.draft.durationSeconds;
      if (durationSeconds > 0.0 && value.currentPTS >= durationSeconds) {
        await _channel.invokeMethod<void>('timelineSeek', {'seconds': 0.0});
        value = value.copyWith(currentPTS: 0.0);
      }

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
        statusMessage: 'Paused at ${value.currentPTS.toStringAsFixed(2)}s',
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
  /// [resumeAfterSeek] tells the native session whether to continue playback
  /// from the seek target instead of holding paused there. Defaults to
  /// `false`, preserving prior pause-on-seek behaviour for existing callers.
  ///
  /// Throws [StateError] if disposed.
  Future<void> seek(double seconds, {bool resumeAfterSeek = false}) async {
    _assertNotDisposed();
    if (!value.isReady) return;

    try {
      await _channel.invokeMethod<void>('timelineSeek', {
        'seconds': seconds,
        'resumeAfterSeek': resumeAfterSeek,
      });
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

  /// Requests a seek to [seconds] using latest-wins coalescing.
  ///
  /// Unlike [seek], this method does not await the native operation.
  /// It records [seconds] as the next desired seek position and dispatches
  /// to native only when no other seek is currently in flight. If a seek IS
  /// already in flight, the position is stored and dispatched automatically
  /// when the in-flight seek is acknowledged via [_onTimelineFrame].
  ///
  /// Use this for high-frequency scrub gestures to avoid flooding the
  /// MethodChannel with redundant seeks. Use [seek] for one-shot programmatic
  /// seeks (loop start, play-at-beginning) where you need to await completion.
  ///
  /// No-op if not ready or disposed.
  void seekCoalesced(double seconds) {
    if (_disposed || !value.isReady) return;
    _pendingCoalescedSeek = seconds;
    if (!_coalescedSeekInFlight) {
      _drainCoalescedSeek();
    }
  }

  void _drainCoalescedSeek() {
    final next = _pendingCoalescedSeek;
    if (next == null || _disposed || !value.isReady) return;
    _pendingCoalescedSeek = null;
    _coalescedSeekInFlight = true;
    _latestDispatchedGeneration++;
    // Fire-and-forget: a scrub seek failure is non-fatal.
    _channel
        .invokeMethod<void>('timelineSeek', {'seconds': next})
        .then((_) {
          if (_disposed) {
            _coalescedSeekInFlight = false;
            return;
          }
          // Update PTS optimistically so the UI stays responsive.
          // Do NOT clear _coalescedSeekInFlight here — the channel returning
          // only means native accepted the command, not that the frame is
          // rendered. The flag is cleared exclusively in _onTimelineFrame
          // so the next seek is held until the frame is actually delivered.
          value = value.copyWith(
            currentPTS: next,
            statusMessage: 'Seeked to ${next.toStringAsFixed(2)}s',
          );
          notifyListeners();
        })
        .catchError((Object _) {
          // On dispatch failure, release the in-flight lock so future scrubs
          // are not permanently blocked.
          _coalescedSeekInFlight = false;
          _drainCoalescedSeek();
        });
  }

  /// Discards any pending coalesced seek without dispatching it.
  ///
  /// Call this before issuing a direct [seek] (e.g. on drag end) so that
  /// an already-queued coalesced position cannot overwrite the final target
  /// after the direct seek completes.
  void cancelPendingCoalescedSeek() {
    _pendingCoalescedSeek = null;
  }

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

    final oldSubscription = _timelineSubscription;

    _busy = true;
    // Clear texture immediately so stale frames disappear.
    value = value.copyWith(
      draft: nextDraft,
      textureId: null,
      renderWidth: null,
      renderHeight: null,
      isReady: false,
      currentPTS: 0.0,
      isPlaying: false,
      statusMessage: 'Rebuilding timeline…',
    );
    notifyListeners();

    try {
      // Phase 10-C Slice F: derive the disposable preview draft from nextDraft,
      // not value.draft, to avoid serialising a stale authoring state.
      // The raw nextDraft is never mutated.
      final previewDraft = _derivePreviewDraft(nextDraft);
      final result = await _channel.invokeMapMethod<String, dynamic>('updateTimeline', {
        'draft': previewDraft.toMap(),
        // Phase 10-C Slice D: authoritative timeline duration for audio scheduling.
        // VGEditorDraft.durationSeconds is computed by subtracting non-hard-cut
        // transition overlaps from the sum of clip timelineDurations.
        // The native plugin passes this to VanguardAudioPreviewRuntime so it can
        // compute boundary-timer delays correctly without reading draft internals.
        'durationSeconds': nextDraft.durationSeconds,
      });

      final id = (result?['textureId'] as num?)?.toInt();
      if (id == null || id < 0) {
        throw StateError(
          '[VGEditorController] updateDraft: native returned invalid textureId=$id',
        );
      }
      final width = (result?['width'] as num?)?.toInt();
      final height = (result?['height'] as num?)?.toInt();

      // Safe listener handoff: register new before unregistering old to avoid gaps.
      final dispatcher = VanguardChannelDispatcher.instance;
      if (oldSubscription == null ||
          oldSubscription.textureId != id ||
          // ignore: invalid_use_of_visible_for_testing_member
          !dispatcher.hasTimelineListenerForTesting(id)) {
        final newSubscription = dispatcher.registerTimelineListener(
          textureId: id,
          onFrame: _onTimelineFrame,
          onEOS: _onTimelineEOS,
        );
        _timelineSubscription = newSubscription;

        if (oldSubscription != null) {
          dispatcher.unregisterTimelineListener(oldSubscription);
        }
      }

      value = value.copyWith(
        textureId: id,
        renderWidth: width,
        renderHeight: height,
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

  // ── Trim editing (Phase 7.13 / DEC-146) ──────────────────────────────

  /// Adjusts the trim window of [clipId] and pushes the updated timeline to
  /// the native renderer.
  ///
  /// Delegates trim-range validation and sequential layout recomputation to
  /// [VGEditorDraft.trimClip]. On success, calls [updateDraft] which sends the
  /// rebuilt draft to the `updateTimeline` native route, resets [currentPTS]
  /// to 0.0, and notifies listeners.
  ///
  /// [trimStartSeconds] and [trimEndSeconds] are in source-asset seconds
  /// (same coordinate space as [VGClipDescriptor.trimStartSeconds]/
  /// [VGClipDescriptor.trimEndSeconds]).
  ///
  /// Throws [StateError] if the controller is disposed or currently busy with
  /// another operation.
  /// Throws [ArgumentError] (from [VGEditorDraft.trimClip]) if the trim range
  /// is invalid. The [ArgumentError] is propagated without invoking the
  /// MethodChannel.
  Future<void> trimClip({
    required String clipId,
    required double trimStartSeconds,
    required double trimEndSeconds,
  }) async {
    _assertNotDisposed();
    if (_busy) {
      throw StateError(
        '[VGEditorController] trimClip: controller is busy with another operation.',
      );
    }

    // Compute the new draft first (throws ArgumentError on invalid range).
    // Do this BEFORE setting _busy so the caller can catch ArgumentError
    // without affecting the busy-lock state.
    final newDraft = value.draft.trimClip(
      clipId: clipId,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
    );

    // Push to native via updateDraft (handles busy-lock, pause, and state).
    await updateDraft(newDraft);
  }

  // ── Split editing (Phase 7.14 / DEC-147) ────────────────────────────────

  /// Splits [clipId] at [splitSeconds] (absolute source-local seconds) and
  /// pushes the rebuilt timeline to the native renderer.
  ///
  /// Delegates split math, ID generation, and transition rebinding to
  /// [VGEditorDraft.splitClip]. On success, calls [updateDraft] which sends
  /// the rebuilt draft to the `updateTimeline` native route, resets
  /// [currentPTS] to 0.0, and notifies listeners.
  ///
  /// [splitSeconds] must be strictly within the clip's active trim window
  /// (`trimStartSeconds < splitSeconds < trimEndSeconds`).
  ///
  /// Throws [StateError] if the controller is disposed or currently busy with
  /// another operation.
  /// Throws [ArgumentError] (from [VGEditorDraft.splitClip]) if the split
  /// position is invalid. The [ArgumentError] is propagated without invoking
  /// the MethodChannel.
  Future<void> splitClip({
    required String clipId,
    required double splitSeconds,
  }) async {
    _assertNotDisposed();
    if (_busy) {
      throw StateError(
        '[VGEditorController] splitClip: controller is busy with another operation.',
      );
    }

    // Compute the new draft first (throws ArgumentError on invalid position).
    // Do this BEFORE setting _busy so the caller can catch ArgumentError
    // without affecting the busy-lock state.
    final newDraft = value.draft.splitClip(
      clipId: clipId,
      splitSeconds: splitSeconds,
    );

    // Push to native via updateDraft (handles busy-lock, pause, and state).
    await updateDraft(newDraft);
  }

  // ── Reorder editing (Phase 7.15 / DEC-148) ───────────────────────────────

  /// Moves the clip at [fromIndex] to [toIndex] in the timeline and pushes
  /// the rebuilt timeline to the native renderer.
  ///
  /// Delegates reorder logic and **Option D boundary-slot transition
  /// relinking** to [VGEditorDraft.reorderClip]. On success, calls
  /// [updateDraft] which sends the fully resolved draft to the `updateTimeline`
  /// native route, resets [currentPTS] to 0.0, and notifies listeners.
  /// No native ObjC/Swift changes are involved — native receives the rebuilt
  /// draft via the existing `updateTimeline` MethodChannel route.
  ///
  /// **Option D transition policy**: Transitions are treated as boundary-slot
  /// effects. For a timeline with N clips there are N-1 boundary slots. After
  /// the move, each slot retains its original transition — but `fromClipId` and
  /// `toClipId` are rewritten to the new adjacent clip pair at that slot while
  /// `id`, `type`, `durationSeconds`, and `curve` are preserved intact.
  /// Transitions therefore remain visible after a reorder rather than being
  /// silently dropped (Phase 7.15 / DEC-148).
  ///
  /// **No-op guard**: If [fromIndex] == [toIndex], [VGEditorDraft.reorderClip]
  /// returns the same instance. The controller detects this via identity check
  /// (`identical`) and returns immediately without calling the MethodChannel.
  /// Controller state (textureId, currentPTS, isReady) is left unchanged.
  ///
  /// Throws [StateError] if the controller is disposed or currently busy with
  /// another operation.
  /// Throws [ArgumentError] (from [VGEditorDraft.reorderClip]) if the indices
  /// are out of range or if a relinked transition's `durationSeconds` exceeds
  /// either new adjacent clip's `timelineDuration`. The [ArgumentError] is
  /// propagated without invoking the MethodChannel.
  Future<void> reorderClip({
    required int fromIndex,
    required int toIndex,
  }) async {
    _assertNotDisposed();
    if (_busy) {
      throw StateError(
        '[VGEditorController] reorderClip: controller is busy with another operation.',
      );
    }

    // Compute the new draft first (throws ArgumentError on invalid indices).
    // Do this BEFORE setting _busy so the caller can catch ArgumentError
    // without affecting the busy-lock state.
    final newDraft = value.draft.reorderClip(
      fromIndex: fromIndex,
      toIndex: toIndex,
    );

    // No-op guard: draft.reorderClip returns the same instance when
    // fromIndex == toIndex. Skip the MethodChannel to avoid a spurious
    // updateTimeline call that would reset currentPTS and flicker the UI.
    if (identical(newDraft, value.draft)) return;

    // Push to native via updateDraft (handles busy-lock, pause, and state).
    await updateDraft(newDraft);
  }

  // ── Reverse playback (Phase 7.19B / DEC-154) ───────────────────────────

  /// Toggles the [VGClipDescriptor.isReversed] flag of [clipId] and pushes the
  /// updated timeline to the native renderer.
  ///
  /// Delegates validation to [VGEditorDraft.reverseClip]. On success, calls
  /// [updateDraft] which sends the rebuilt draft to the `updateTimeline` native
  /// route, resets [currentPTS] to 0.0, and notifies listeners.
  ///
  /// Throws [StateError] if the controller is disposed or currently busy with
  /// another operation.
  /// Throws [ArgumentError] (from [VGEditorDraft.reverseClip]) if the clip is
  /// not found, not a video clip, or is a freeze-frame clip. The [ArgumentError]
  /// is propagated without invoking the MethodChannel.
  Future<void> reverseClip({required String clipId}) async {
    _assertNotDisposed();
    if (_busy) {
      throw StateError(
        '[VGEditorController] reverseClip: controller is busy with another operation.',
      );
    }

    // Compute the new draft first (throws ArgumentError on invalid clip).
    // Do this BEFORE setting _busy so the caller can catch ArgumentError
    // without affecting the busy-lock state.
    final newDraft = value.draft.reverseClip(clipId: clipId);

    // Push to native via updateDraft (handles busy-lock, pause, and state).
    await updateDraft(newDraft);

    // Phase 7.20D: if the clip is now reversed, kick off background sidecar
    // preparation (fire-and-forget). The native compositor (Phase 7.20C)
    // picks up the ready sidecar on the next compositor pull cycle.
    // Does not block reverseClip completion and is safe to ignore on failure.
    if (!_disposed) {
      final toggled = value.draft.clips.firstWhere(
        (c) => c.id == clipId,
        orElse: () => value.draft.clips.first,
      );
      if (toggled.isReversed) {
        prepareReverseSidecars().catchError((_) => <VGReverseSidecarStatus>[]);
      }
    }
  }

  // ── Frame cache stats (Phase 7.18B2 / DEC-152) ────────────────────────────

  /// Returns a live snapshot of the native frame cache metrics.
  ///
  /// Maps to `getTimelineCacheStats` (Phase 7.18B1 native route, DEC-152).
  ///
  /// Returns a [Map] with the following integer keys (all values ≥ 0):
  /// - `frameCacheBytes`     — current bytes held in the LRU cache.
  /// - `frameCacheHits`      — total cache hits since last flush.
  /// - `frameCacheMisses`    — total cache misses since last flush.
  /// - `frameCacheEvictions` — total LRU evictions since last flush.
  /// - `frameCacheInserts`   — total successful inserts since last flush.
  /// - `frameCacheEntries`   — current number of cached frame entries.
  ///
  /// Returns an empty map if no timeline compositor is active or if the
  /// native runtime returns an empty result. Never throws on native failure.
  ///
  /// Does NOT require [isReady] — safe to call at any lifecycle point after
  /// construction and before [dispose].
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<Map<String, int>> getTimelineCacheStats() async {
    _assertNotDisposed();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getTimelineCacheStats',
      );
      if (result == null || result.isEmpty) return const {};
      return result.map((k, v) => MapEntry(k, (v as num).toInt()));
    } on PlatformException catch (_) {
      // Best-effort — native may have no active timeline or compositor.
      return const {};
    }
  }

  /// Evicts all entries from the native frame cache and resets all counters.
  ///
  /// Maps to `clearTimelineCache` (Phase 7.18B1 native route, DEC-152).
  ///
  /// Forces a cold decode on the next scrub or seek, enabling manual
  /// before/after latency benchmarks in the DEV harness.
  ///
  /// No-op if no timeline compositor is active. Always completes without
  /// error — native failure is silently swallowed (best-effort).
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<void> clearTimelineCache() async {
    _assertNotDisposed();
    try {
      await _channel.invokeMethod<void>('clearTimelineCache');
    } on PlatformException catch (_) {
      // Best-effort — native may have no active timeline or compositor.
    }
  }

  // ── Reverse sidecar (Phase 7.20D / DEC-155) ─────────────────────────────────

  /// Prepares reverse sidecar assets for all currently reversed video clips in
  /// the active draft.
  ///
  /// Maps to `prepareReverseSidecars` (Phase 7.20B native route).
  /// Builds the clip list from [value.draft.clips] where
  /// [VGClipDescriptor.isReversed] == true, then dispatches background H.264
  /// All-Intra transcode tasks via [VGReverseSidecarManager].
  ///
  /// Returns a [List<VGReverseSidecarStatus>] — one entry per reversed clip.
  /// Returns an empty list if there are no reversed clips in the current draft.
  ///
  /// **Preview only.** The export compositor must NOT call this method.
  /// See VGReverseSidecarManager.h § Export isolation.
  ///
  /// Never throws on native failure — [PlatformException] is swallowed and
  /// an empty list is returned (best-effort).
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<List<VGReverseSidecarStatus>> prepareReverseSidecars() async {
    _assertNotDisposed();
    final reversedClips = value.draft.clips.where((c) => c.isReversed).toList();
    if (reversedClips.isEmpty) return const [];

    final clips = reversedClips.map((c) {
      return <String, Object>{
        'clipId': c.id,
        'sourcePath': c.sourcePath,
        'trimStart': c.trimStartSeconds,
        'trimEnd': c.trimEndSeconds,
        'targetWidth': value.draft.canvasWidth.toDouble(),
        'targetHeight': value.draft.canvasHeight.toDouble(),
        'sourceHash': _sidecarSourceHash(c),
      };
    }).toList();

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepareReverseSidecars',
        {'clips': clips},
      );
      final clipList = (result?['clips'] as List?) ?? [];
      return clipList
          .whereType<Map<Object?, Object?>>()
          .map(VGReverseSidecarStatus.fromMap)
          .toList();
    } on PlatformException catch (_) {
      // Best-effort — native may have no active compositor.
      return const [];
    } on MissingPluginException catch (_) {
      // Best-effort — native route not implemented on this platform.
      return const [];
    }
  }

  /// Returns a live status snapshot for the given [clipId]'s reverse sidecar.
  ///
  /// Maps to `getSidecarStatus` (Phase 7.20B native route).
  /// The native implementation is synchronous (lock-acquire + dict lookup).
  ///
  /// Returns an idle [VGReverseSidecarStatus] if no record exists for [clipId]
  /// or on native failure.
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<VGReverseSidecarStatus> getSidecarStatus({
    required String clipId,
  }) async {
    _assertNotDisposed();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getSidecarStatus',
        {'clipId': clipId},
      );
      if (result == null) {
        return VGReverseSidecarStatus(
          clipId: clipId,
          state: VGReverseSidecarState.idle,
        );
      }
      return VGReverseSidecarStatus.fromMap(
        result.map((k, v) => MapEntry<Object?, Object?>(k, v)),
      );
    } on PlatformException catch (_) {
      return VGReverseSidecarStatus(
        clipId: clipId,
        state: VGReverseSidecarState.idle,
      );
    } on MissingPluginException catch (_) {
      return VGReverseSidecarStatus(
        clipId: clipId,
        state: VGReverseSidecarState.idle,
      );
    }
  }

  /// Cancels all in-flight sidecar transcodes and deletes all sidecar files.
  ///
  /// Maps to `cleanupReverseSidecars` (Phase 7.20B native route).
  /// Best-effort — never throws. No-op if no sidecars exist.
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<void> cleanupReverseSidecars() async {
    _assertNotDisposed();
    try {
      await _channel.invokeMethod<void>('cleanupReverseSidecars');
    } on PlatformException catch (_) {
      // Best-effort.
    } on MissingPluginException catch (_) {
      // Best-effort — native route not implemented on this platform.
    }
  }

  // ── Export ───────────────────────────────────────────────────────────────────────

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
        '[VGEditorController] export: an export is already in progress',
      );
    }

    // Pause before export.
    if (value.isPlaying) await pause();

    value = value.copyWith(
      isExporting: true,
      statusMessage: 'Exporting timeline…',
    );
    notifyListeners();

    try {
      // Phase 8.14C: flatten original clip audio into explicit sidecar tracks
      // before serialising. Pure operation — no I/O, appends to existing plan.
      // Phase 10-C Slice B: apply composition-policy normalization (static
      // Original muting + VO-triggered ducking) to the flattened raw snapshot.
      // The result is a disposable derived VGEditorDraft — it is never assigned
      // back to value.draft or any canonical authoring state.
      final exportDraft = value.draft
          .flattenOriginalClipAudio()
          .applyAudioCompositionPolicy();
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'exportTimeline',
        {'draft': exportDraft.toMap(), ...request.toMap()},
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

  // ── Disposal (Opus M3 / Phase 10-C Slice D teardown fix) ──────────────────

  /// Asynchronously tears down the native timeline.
  ///
  /// Maps to `disposeTimeline` (Phase 7.8 production route).
  ///
  /// Repeated calls are safe and idempotent — every call returns the same
  /// teardown future. Native `disposeTimeline` is dispatched exactly once.
  ///
  /// Errors from the native side are swallowed (best-effort). Use
  /// [disposeAsyncConfirmed] when the caller must distinguish a confirmed
  /// native teardown from a failed one.
  ///
  /// Call this before [dispose] in the owning widget's dispose lifecycle.
  Future<void> disposeAsync() {
    if (_disposed) {
      return Future<void>.value();
    }

    // If native teardown has already been dispatched, return the cached
    // best-effort future so the caller joins the in-flight operation without
    // sending a second disposeTimeline request.
    if (_teardownFuture != null) {
      return _teardownFuture!;
    }

    _dispatchTeardown();
    return _teardownFuture!;
  }

  /// Asynchronously tears down the native timeline and propagates failures.
  ///
  /// Maps to `disposeTimeline` (Phase 7.8 production route).
  ///
  /// Like [disposeAsync], dispatches `disposeTimeline` at most once — if
  /// teardown was already initiated (by [disposeAsync] or a prior call to this
  /// method), this joins the same raw in-flight native operation rather than
  /// sending a second request.
  ///
  /// Unlike [disposeAsync], this method propagates any [PlatformException] or
  /// other error returned by the native side. The caller can use this to
  /// distinguish a confirmed native teardown from an unconfirmed one.
  ///
  /// Compatible with [disposeAsync] and [dispose] in any call order:
  ///   - [disposeAsyncConfirmed] → [disposeAsync]:  both join the same dispatch;
  ///     [disposeAsync] still swallows the error.
  ///   - [disposeAsync] → [disposeAsyncConfirmed]:  [disposeAsyncConfirmed]
  ///     joins the raw future and will propagate an error if native failed
  ///     (even if [disposeAsync] already swallowed it).
  ///   - [dispose] → [disposeAsyncConfirmed]:  [dispose] already triggered
  ///     the native call; [disposeAsyncConfirmed] joins the raw future.
  ///
  /// Never sends a second `disposeTimeline` request regardless of call order.
  Future<void> disposeAsyncConfirmed() {
    // Check for an already-dispatched raw teardown first — even if dispose()
    // has been called. If dispose() fired _dispatchTeardown() before this
    // method was reached, we must join that raw future and propagate its native
    // error rather than returning a silent completed future.
    if (_rawTeardownFuture != null) {
      return _rawTeardownFuture!;
    }

    // Only return a completed future when the controller is disposed AND no
    // raw teardown was ever dispatched (i.e. native was never called at all).
    if (_disposed) {
      return Future<void>.value();
    }

    // Dispatch exactly once, then return the raw (error-propagating) future.
    _dispatchTeardown();
    return _rawTeardownFuture!;
  }

  /// Internal: dispatches `disposeTimeline` exactly once, populating both
  /// [_rawTeardownFuture] (error-propagating) and [_teardownFuture]
  /// (best-effort / error-swallowing). Called by [disposeAsync],
  /// [disposeAsyncConfirmed], and [dispose]. Must not be called when
  /// [_rawTeardownFuture] is already set.
  void _dispatchTeardown() {
    assert(
      _rawTeardownFuture == null,
      '_dispatchTeardown called after teardown already dispatched',
    );

    // Unregister timeline subscription so no callbacks arrive after teardown
    // begins. Done synchronously before the MethodChannel call so the
    // subscription cannot deliver frames during the async native call.
    final dispatcher = VanguardChannelDispatcher.instance;
    if (_timelineSubscription != null) {
      dispatcher.unregisterTimelineListener(_timelineSubscription!);
      _timelineSubscription = null;
    }

    // Store the raw future first. Both fields are set in the same microtask
    // so there is never a window where one is set and the other is not.
    _rawTeardownFuture = _channel.invokeMethod<void>('disposeTimeline');

    _teardownFuture = _rawTeardownFuture!.catchError((e) {
      // Best-effort — native may already be gone.
    });
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
    if (_disposed) {
      return;
    }
    _disposed = true;

    // Unregister timeline subscription if disposeAsync was not called first.
    final dispatcher = VanguardChannelDispatcher.instance;
    if (_timelineSubscription != null) {
      dispatcher.unregisterTimelineListener(_timelineSubscription!);
      _timelineSubscription = null;
    }

    // Close streams before super.dispose() to avoid adding to closed streams.
    _ptsController.close();
    _eosController.close();

    // Dispatch native teardown fire-and-forget ONLY if neither disposeAsync()
    // nor disposeAsyncConfirmed() has already done so. Delegates to
    // _dispatchTeardown() so disposeTimeline is sent exactly once regardless
    // of which disposal path the caller used.
    if (_rawTeardownFuture == null) {
      _dispatchTeardown();
    }

    super.dispose();
  }

  // ── Phase 7.x-C / 7.x-E: DEV dual-camera routes ─────────────────────────

  /// **DEV-only.** Validates that a [VGDualCameraDescriptor] can be
  /// deserialised correctly by the native [VGDualCameraCompositorNode].
  ///
  /// Invokes `dev_validateDualCameraDescriptor` — a non-playback native route
  /// introduced in Phase 7.x-C. The native side instantiates the ObjC node,
  /// verifies all descriptor fields, and immediately discards the node.
  ///
  /// On success, returns a map such as:
  /// ```json
  /// { "ok": true, "nodeClass": "VGDualCameraCompositorNode",
  ///   "layoutMode": "pip",
  ///   "primaryClipId": "clip-A", "secondaryClipId": "clip-B" }
  /// ```
  ///
  /// On native validation failure, throws [PlatformException] with
  /// code `DUAL_CAMERA_DESCRIPTOR_INVALID`.
  ///
  /// Does NOT:
  ///   - create a texture
  ///   - start playback
  ///   - modify the active draft
  ///   - touch VanguardGraphRuntime
  ///   - instantiate AVAssetReader
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<Map<String, Object?>> devValidateDualCameraDescriptor(
    VGDualCameraDescriptor descriptor,
  ) async {
    _assertNotDisposed();
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'dev_validateDualCameraDescriptor',
      {'descriptor': descriptor.toMap()},
    );
    return raw ?? const {};
  }

  // ── Phase 7.x-E: DEV dual-camera texture mount ────────────────────────────

  /// **DEV-only.** Mounts [VGDualCameraCompositorNode] in the generic runtime
  /// (Phase 7.x-D) and returns a Flutter texture ID.
  ///
  /// Invokes `dev_createDualCameraTexture`. The native side:
  ///   1. Instantiates [VGDualCameraCompositorNode] from [descriptor].
  ///   2. Creates a [VanguardGraphRuntime] isolated from the session registry.
  ///   3. Calls `prepareTimeline(sourceNode:)` to register a Flutter texture.
  ///   4. Returns the live textureId.
  ///
  /// The node returns `VGFrameStatusSkipped` for every frame — blank/transparent
  /// output is expected. This proves the generic runtime can host the node without
  /// crashing or leaking resources.
  ///
  /// On success, returns a map containing at minimum:
  /// ```json
  /// { "ok": true, "textureId": 42, "nodeClass": "VGDualCameraCompositorNode",
  ///   "layoutMode": "pip",
  ///   "primaryClipId": "...", "secondaryClipId": "..." }
  /// ```
  ///
  /// [width] and [height] are forwarded as hints to native (optional).
  ///
  /// Does NOT:
  ///   - modify the active draft or timeline
  ///   - create an AVAssetReader
  ///   - render or composite any frames
  ///   - touch camera/session code
  ///   - affect the normal timeline runtime
  ///
  /// Throws [PlatformException] with code `DUAL_CAMERA_TEXTURE_CREATE_FAILED`
  /// on native failure.
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<Map<String, Object?>> devCreateDualCameraTexture(
    VGDualCameraDescriptor descriptor, {
    int? width,
    int? height,
  }) async {
    _assertNotDisposed();
    final payload = <String, Object?>{
      'descriptor': descriptor.toMap(),
      if (width != null) 'width': width,
      if (height != null) 'height': height,
    };
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'dev_createDualCameraTexture',
      payload,
    );
    return raw ?? const {};
  }

  /// **DEV-only.** Invalidates and releases the DEV dual-camera runtime mounted
  /// by [devCreateDualCameraTexture].
  ///
  /// Invokes `dev_disposeDualCameraTexture`. No-op if no DEV dual-camera runtime
  /// is currently mounted. Swallows [PlatformException] (best-effort).
  ///
  /// Does NOT affect the normal timeline runtime or session registry.
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<void> devDisposeDualCameraTexture() async {
    _assertNotDisposed();
    try {
      await _channel.invokeMethod<void>('dev_disposeDualCameraTexture');
    } on PlatformException catch (_) {
      // Best-effort — native may already be gone.
    }
  }

  // ── Phase 7.x-N: DEV dual-camera compositor telemetry ──────────────────────

  /// **DEV-only.** Returns a snapshot of frame-level telemetry counters from
  /// the mounted [VGDualCameraCompositorNode].
  ///
  /// Invokes `dev_getDualCameraTelemetry`. Returns an empty map if no DEV
  /// dual-camera runtime is mounted or on native failure.
  ///
  /// Returned keys (`int` unless noted):
  /// - `pullFrameCallCount`          — total `pullFrame:` calls since last reset.
  /// - `primaryPullCount`            — alias for `pullFrameCallCount`.
  /// - `primaryDecodeCount`          — `copyNextSampleBuffer` decode calls.
  /// - `successfulFrameCount`        — frames delivered (not skipped/EOS).
  /// - `compositedFrameCount`        — total CoreImage composites (all modes).
  /// - `pipCompositionCount`         — successful PiP composites.
  /// - `splitScreenCompositionCount` — successful split-screen composites.
  /// - `compositionFailureCount`     — composites attempted but failed.
  /// - `fallbackToPrimaryCount`      — primary-only deliveries.
  /// - `imageBufferBuildCount`       — successful image buffer builds.
  /// - `outputBufferCreateCount`     — successful CVPixelBufferCreate calls.
  /// - `primaryBufferEstBytes`       — estimated bytes of current primary buffer.
  /// - `secondaryBufferEstBytes`     — estimated bytes of current secondary buffer.
  /// - `estimatedRetainedBufferBytes`— primary + secondary byte sum.
  /// - `firstFrameMs` (**double**)   — monotonic stamp of first delivered frame.
  /// - `lastPullFrameMs` (**double**)— last delivery duration in ms.
  /// - `maxPullFrameMs` (**double**) — peak delivery duration in ms.
  /// - `averagePullFrameMs` (**double**)— mean delivery duration in ms.
  /// - `estimatedRetainedBufferMB` (**double**)— retained buffer in MB.
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<Map<String, num>> devGetDualCameraTelemetry() async {
    _assertNotDisposed();
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'dev_getDualCameraTelemetry',
      );
      if (raw == null || raw.isEmpty) return const {};
      return raw.map((k, v) => MapEntry(k, v as num));
    } on PlatformException catch (_) {
      return const {};
    }
  }

  /// **DEV-only.** Resets all [VGDualCameraCompositorNode] telemetry counters
  /// to zero.
  ///
  /// Invokes `dev_resetDualCameraTelemetry`. No-op if no DEV dual-camera
  /// runtime is mounted. Swallows [PlatformException] (best-effort).
  ///
  /// Throws [StateError] if [dispose] has been called.
  Future<void> devResetDualCameraTelemetry() async {
    _assertNotDisposed();
    try {
      await _channel.invokeMethod<void>('dev_resetDualCameraTelemetry');
    } on PlatformException catch (_) {
      // Best-effort.
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('[VGEditorController] method called after dispose()');
    }
  }

  /// Computes a stable hash string for sidecar identity checks.
  ///
  /// Encodes (sourcePath + trimStart + trimEnd + canvasWidth + canvasHeight)
  /// as a pipe-delimited string. Matches the sourceHash contract documented
  /// in VGReverseSidecarManager.h § Sidecar identity (sourceHash).
  String _sidecarSourceHash(VGClipDescriptor clip) =>
      '${clip.sourcePath}'
      '|${clip.trimStartSeconds}'
      '|${clip.trimEndSeconds}'
      '|${value.draft.canvasWidth}x${value.draft.canvasHeight}';

  // ── Audio Recording — Slice M ──────────────────────────────────────────────

  /// Starts audio recording to [outputPath] using the active timeline runtime.
  ///
  /// Maps to `startAudioRecording` (Slice M). The native layer reads the
  /// current `VGTimelineStateSnapshot` to compute the authoritative start PTS
  /// without any involvement from the Dart layer.
  ///
  /// Returns a [VGAudioRecordingStartResult] containing the file path, native
  /// start PTS, and a headphone-connection indicator.
  ///
  /// Throws [PlatformException] if no active timeline runtime is present, if
  /// the timeline snapshot is invalid, or if the recorder fails to start.
  /// Throws [StateError] if disposed.
  Future<VGAudioRecordingStartResult> startAudioRecording(
    String outputPath,
  ) async {
    _assertNotDisposed();
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'startAudioRecording',
      {'outputPath': outputPath},
    );
    final result = VGAudioRecordingStartResult.fromMap(raw ?? const {});
    if (result == null) {
      throw PlatformException(
        code: 'INVALID_RESPONSE',
        message: 'startAudioRecording: native returned incomplete map',
      );
    }
    return result;
  }

  /// Stops the active audio recording.
  ///
  /// Maps to `stopAudioRecording` (Slice M). The native layer finalises the
  /// file and restores the AVAudioSession category to `.playback`.
  ///
  /// Returns a [VGAudioRecordingStopResult] containing the file path, start
  /// PTS, and total recorded duration.
  ///
  /// Throws [PlatformException] if no recording is active or if file
  /// finalisation fails. Throws [StateError] if disposed.
  Future<VGAudioRecordingStopResult> stopAudioRecording() async {
    _assertNotDisposed();
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'stopAudioRecording',
    );
    final result = VGAudioRecordingStopResult.fromMap(raw ?? const {});
    if (result == null) {
      throw PlatformException(
        code: 'INVALID_RESPONSE',
        message: 'stopAudioRecording: native returned incomplete map',
      );
    }
    return result;
  }

  // ── Debug ──────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGEditorController('
      'draftId: ${draft.id}, '
      'textureId: $textureId, '
      'pts: ${currentPTS.toStringAsFixed(2)}s, '
      'ready: $isReady, '
      'playing: $isPlaying, '
      'exporting: $isExporting, '
      'tearingDown: ${_teardownFuture != null}, '
      'disposed: $_disposed)';
}
