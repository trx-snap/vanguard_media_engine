// vanguard_manual_test_playground.dart
// Vanguard Media Engine — Phase 7 Stage 7.10 / Phase 7.11 / Phase 7.18B2: Manual Test Playground
//
// ════════════════════════════════════════════════════════════════════════════════
// STAGES 7.10 + 7.11 — MANUAL TEST PLAYGROUND (HANIF DEVICE TEST TARGET)
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.10 — MANUAL TEST PLAYGROUND (HANIF DEVICE TEST TARGET)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Reusable manual test screen designed specifically for Hanif's physical device
// validation of Phase 7.10 transitions and Phase 7.9 orientation normalization.
//
// KEY DESIGN GOALS:
//   - Zero copying required from Desktop — uses local bundled test assets.
//   - Copies assets to system temp at runtime and builds VGEditorDraft.
//   - Uses modern ValueNotifier-based VGEditorController.
//   - Supports switching transitions (Hard Cut, Dissolve, Fade).
//   - Clearly labels all paths, exist statuses, and the final decision block:
//     "Manual Phase 7 Test Fixture — Hanif decides PASS/FAIL".
//

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

class VanguardManualTestPlayground extends StatefulWidget {
  const VanguardManualTestPlayground({super.key});

  @override
  State<VanguardManualTestPlayground> createState() =>
      _VanguardManualTestPlaygroundState();
}

class _VanguardManualTestPlaygroundState
    extends State<VanguardManualTestPlayground> {
  // ── Asset Paths ────────────────────────────────────────────────────────────
  static const String _kAssetPathA = 'assets/manual_test_clips/clip_A.mov';
  static const String _kAssetPathB = 'assets/manual_test_clips/clip_B.mov';
  // Phase 7.12: approved still-image test fixture (Hanif explicit approval).
  static const String _kAssetPathC = 'assets/manual_test_clips/still_C.png';

  // ── Temp File Paths ─────────────────────────────────────────────────────────
  String? _tempPathA;
  String? _tempPathB;
  String? _tempPathC; // Phase 7.12: still-image fixture

  bool _existsA = false;
  bool _existsB = false;
  bool _existsC = false; // Phase 7.12

  // ── Canvas Configurations ──────────────────────────────────────────────────
  int _canvasWidth = 1280;
  int _canvasHeight = 720;
  final int _fps = 30;

  // ── Phase 7.12: still-image test mode toggle ─────────────────────────────
  // false: Clip B uses clip_B.mov (Phases 7.10/7.11 test).
  // true:  Clip B uses still_C.png with VGMediaKind.image, 5.0 s hold (Phase 7.12 test).
  bool _useStillImageClipB = false;

  // ── Phase 7.16: still-image fit mode and crop rect (DEV validation only) ─
  VGStillImageFitMode _stillFitMode = VGStillImageFitMode.fit;
  bool _useStillCrop = false;

  // ── Phase 7.17: freeze-frame apply status (DEV validation only) ─────────
  bool _freezeApplied = false;

  // ── Phase 7.19B: reverse-clip apply status (DEV validation only) ────────
  bool _reverseApplied = false;

  // ── Phase 7.20D: Reverse sidecar status HUD state ───────────────────────────
  // Latest statuses returned by prepareReverseSidecars() or getSidecarStatus().
  List<VGReverseSidecarStatus>? _sidecarStatuses;
  bool _sidecarBusy = false; // true while an action is in-flight

  // ── Phase 7.18B2: Cache Metrics HUD state ──────────────────────────────────
  Map<String, int> _cacheStats = const {};
  bool _fetchingStats = false;

  // ── Active Transition ──────────────────────────────────────────────────────
  String _selectedTransition = 'dissolve'; // 'hard_cut' | 'dissolve' | 'fade'

  // ── Controller & Lifecycle ──────────────────────────────────────────────────
  VGEditorController? _controller;
  bool _copyingAssets = true;
  String _status = 'Initializing...';
  String? _copyError;

  // ── Export State ──────────────────────────────────────────────────────────────
  bool _exporting = false;
  VGEditorExportResult? _exportResult;

  // ── Phase 7.13: Trim Debug State ───────────────────────────────────────────
  // true once _trimClipA() succeeds; resets when timeline is rebuilt.
  bool _trimApplied = false;

  // ── Phase 7.14: Split Debug State ────────────────────────────────────
  // true once _splitClipA() succeeds; resets when timeline is rebuilt.
  bool _splitApplied = false;

  // ── Phase 7.15: Reorder Debug State ─────────────────────────────────
  // true once _reorderClips() succeeds; resets when timeline is rebuilt.
  bool _reorderApplied = false;

  // ── Seek scrub throttle ────────────────────────────────────────────────────
  double? _seekDragValue;
  DateTime? _lastScrubSeekAt;

  // ── Phase 7.11: Per-clip transform state ──────────────────────────────────
  // All fields default to identity. Sliders drive these; rebuild is debounced.
  double _clipAScaleX     = 1.0;
  double _clipAScaleY     = 1.0;
  double _clipARotation   = 0.0; // radians
  double _clipAOpacity    = 1.0;
  double _clipATransX     = 0.0; // canvas pixels
  double _clipATransY     = 0.0; // canvas pixels

  double _clipBScaleX     = 1.0;
  double _clipBScaleY     = 1.0;
  double _clipBRotation   = 0.0;
  double _clipBOpacity    = 1.0;
  double _clipBTransX     = 0.0;
  double _clipBTransY     = 0.0;

  // Debounce timer: rebuild waits 500 ms after last slider change.
  // (D7: debounced playground rebuild)
  Timer? _transformDebounce;

  @override
  void initState() {
    super.initState();
    _prepareAssets();
  }

  @override
  void dispose() {
    _transformDebounce?.cancel();
    _channel.setMethodCallHandler(null);
    _controller?.disposeAsync().catchError((_) {});
    _controller?.dispose();
    super.dispose();
  }

  // Phase 7.11: debounced rebuild — waits 500 ms after last slider change
  // before tearing down and rebuilding the native compositor. This prevents
  // excessive teardown/rebuild during slider drag without blocking the UI.
  void _debouncedRebuild() {
    _transformDebounce?.cancel();
    _transformDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _rebuildTimeline();
    });
  }

  // ── Copy Assets and Prepare Timeline ────────────────────────────────────────

  Future<void> _prepareAssets() async {
    setState(() {
      _copyingAssets = true;
      _status = 'Copying bundled assets to temp...';
      _copyError = null;
    });

    try {
      // 1. Copy Asset A
      final pathA = await _copyAssetToTemp(_kAssetPathA, 'clip_A.mov');
      final fileA = File(pathA);
      final existsA = await fileA.exists();

      // 2. Copy Asset B
      final pathB = await _copyAssetToTemp(_kAssetPathB, 'clip_B.mov');
      final fileB = File(pathB);
      final existsB = await fileB.exists();

      // 3. Phase 7.12: Copy still-image fixture C
      final pathC = await _copyAssetToTemp(_kAssetPathC, 'still_C.png');
      final fileC = File(pathC);
      final existsC = await fileC.exists();

      if (!mounted) return;

      setState(() {
        _tempPathA = pathA;
        _tempPathB = pathB;
        _tempPathC = pathC;
        _existsA = existsA;
        _existsB = existsB;
        _existsC = existsC;
        _copyingAssets = false;
        _status = 'Assets ready in temp. Initializing timeline...';
      });

      if (existsA && existsB) {
        await _rebuildTimeline();
      } else {
        setState(() {
          _status = 'Error: Fixture files were copied but do not exist in temp.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _copyingAssets = false;
        _status = 'Error loading assets: $e';
        _copyError = e.toString();
      });
    }
  }

  Future<String> _copyAssetToTemp(String assetPath, String fileName) async {
    final byteData = await rootBundle.load(assetPath);
    final file = File('${Directory.systemTemp.path}/$fileName');
    await file.writeAsBytes(byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    ));
    return file.path;
  }

  // ── Rebuild VGEditorDraft and VGEditorController ───────────────────────────

  Future<void> _rebuildTimeline() async {
    if (_tempPathA == null || _tempPathB == null) return;

    setState(() {
      _status = 'Building draft...';
    });

    // Clean up previous controller
    if (_controller != null) {
      _channel.setMethodCallHandler(null);
      await _controller!.disposeAsync().catchError((_) {});
      _controller!.dispose();
      _controller = null;
    }

    // Build the draft
    final clips = [
      VGClipDescriptor(
        id: 'clip-A',
        sourcePath: _tempPathA!,
        durationSeconds: 5.06,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.06,
        // Phase 7.11: apply clip A transform when non-identity.
        transform: (_clipAScaleX != 1.0 || _clipAScaleY != 1.0 ||
                    _clipARotation != 0.0 || _clipAOpacity != 1.0 ||
                    _clipATransX != 0.0 || _clipATransY != 0.0)
            ? VGClipTransformDescriptor(
                scaleX: _clipAScaleX,
                scaleY: _clipAScaleY,
                rotation: _clipARotation,
                opacity: _clipAOpacity,
                translationX: _clipATransX,
                translationY: _clipATransY,
              )
            : null,
      ),
      // Phase 7.12: when _useStillImageClipB is true, Clip B becomes a still image.
      // The existing A→B transition selector and Clip B transform sliders apply to
      // the still image exactly as they do to the video clip (unified pipeline).
      VGClipDescriptor(
        id: 'clip-B',
        sourcePath: _useStillImageClipB ? _tempPathC! : _tempPathB!,
        mediaKind: _useStillImageClipB ? VGMediaKind.image : VGMediaKind.video,
        durationSeconds: _useStillImageClipB ? 5.0 : 5.56,
        trimStartSeconds: 0.0,
        trimEndSeconds: _useStillImageClipB ? 5.0 : 5.56,
        // Phase 7.16: Apply fitMode and cropRect when Clip B is still image
        fitMode: _useStillImageClipB ? _stillFitMode : VGStillImageFitMode.fit,
        cropRect: (_useStillImageClipB && _useStillCrop) ? const [0.1, 0.1, 0.8, 0.8] : null,
        // Phase 7.11 + 7.12: apply clip B transform when non-identity.
        // Applies to both video and still-image variants of Clip B.
        transform: (_clipBScaleX != 1.0 || _clipBScaleY != 1.0 ||
                    _clipBRotation != 0.0 || _clipBOpacity != 1.0 ||
                    _clipBTransX != 0.0 || _clipBTransY != 0.0)
            ? VGClipTransformDescriptor(
                scaleX: _clipBScaleX,
                scaleY: _clipBScaleY,
                rotation: _clipBRotation,
                opacity: _clipBOpacity,
                translationX: _clipBTransX,
                translationY: _clipBTransY,
              )
            : null,
      ),
    ];

    List<VGTransitionDescriptor> transitions = [];
    if (_selectedTransition == 'hard_cut') {
      transitions = [
        VGTransitionDescriptor(
          id: 'tr-AB',
          type: VGTransitionType.none,
          durationSeconds: 0.0,
          fromClipId: 'clip-A',
          toClipId: 'clip-B',
        ),
      ];
    } else if (_selectedTransition == 'dissolve') {
      transitions = [
        VGTransitionDescriptor(
          id: 'tr-AB',
          type: VGTransitionType.dissolve,
          durationSeconds: 1.0,
          fromClipId: 'clip-A',
          toClipId: 'clip-B',
        ),
      ];
    } else if (_selectedTransition == 'fade') {
      transitions = [
        VGTransitionDescriptor(
          id: 'tr-AB',
          type: VGTransitionType.fade,
          durationSeconds: 1.0,
          fromClipId: 'clip-A',
          toClipId: 'clip-B',
        ),
      ];
    }

    // Build transition-aware timeline layout (preserving canvas dimensions)
    final draft = VGEditorDraft.sequentialWithTransitions(
      id: 'manual-test-draft-${DateTime.now().millisecondsSinceEpoch}',
      clips: clips,
      transitions: transitions,
      canvasWidth: _canvasWidth,
      canvasHeight: _canvasHeight,
      fps: _fps,
    );

    final controller = VGEditorController(initialDraft: draft);

    // Register method channel callback handler
    _channel.setMethodCallHandler(controller.handleNativeCallback);

    setState(() {
      _controller = controller;
      _seekDragValue = null;
      _exportResult = null;
      _trimApplied = false;
      _splitApplied = false;
      _reorderApplied = false;
      _freezeApplied = false;
      _reverseApplied = false;
      // Phase 7.20D: reset sidecar status on every timeline rebuild.
      _sidecarStatuses = null;
      _sidecarBusy = false;
    });

    try {
      await controller.initialize();
      if (mounted) {
        setState(() {
          _status = 'Timeline texture initialized successfully.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Failed to initialize native compositor texture: $e';
        });
      }
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null || !c.isReady) return;

    if (c.isPlaying) {
      await c.pause().catchError((_) {});
    } else {
      await c.play().catchError((_) {});
    }
    setState(() {});
  }

  // Phase 7.13: trim debug trigger — trims Clip A to [1.5s → 4.5s].
  // Verifies that trimClip calls updateTimeline and shrinks timeline duration.
  Future<void> _trimClipA() async {
    final c = _controller;
    if (c == null || !c.isReady || _exporting) return;

    try {
      await c.trimClip(
        clipId: 'clip-A',
        trimStartSeconds: 1.5,
        trimEndSeconds: 4.5,
      );
      if (mounted) {
        setState(() {
          _trimApplied = true;
          _status = 'Trim OK — Clip A trimmed to [1.5s → 4.5s]. '
              'Duration: ${c.draft.durationSeconds.toStringAsFixed(2)}s';
        });
      }
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _status = 'Trim rejected: $e');
    } catch (e) {
      if (mounted) setState(() => _status = 'Trim error: $e');
    }
  }

  // Phase 7.14: split debug trigger — splits Clip A at 3.0s into
  // Clip A [0s → 3.0s] and Clip A-split-1 [3.0s → 5.06s].
  // Verifies splitClip calls updateTimeline and increases clip count.
  Future<void> _splitClipA() async {
    final c = _controller;
    if (c == null || !c.isReady || _exporting) return;

    try {
      await c.splitClip(
        clipId: 'clip-A',
        splitSeconds: 3.0,
      );
      if (mounted) {
        setState(() {
          _splitApplied = true;
          _status = 'Split OK — Clip A split at 3.0s. '
              'Clips: ${c.draft.clips.length}, '
              'Duration: ${c.draft.durationSeconds.toStringAsFixed(2)}s';
        });
      }
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _status = 'Split rejected: $e');
    } catch (e) {
      if (mounted) setState(() => _status = 'Split error: $e');
    }
  }

  // Phase 7.15: reorder debug trigger — moves Clip A (index 0) to index 1,
  // swapping [A, B] → [B, A]. Verifies reorderClip calls updateTimeline and
  // updates clip ordering. Only valid on a two-clip baseline timeline.
  Future<void> _reorderClips() async {
    final c = _controller;
    if (c == null || !c.isReady || _exporting) return;

    // Requires at least 2 clips to do a meaningful swap.
    if (c.draft.clips.length < 2) {
      setState(() => _status = 'Reorder skipped — need ≥2 clips. Use baseline timeline.');
      return;
    }

    // Always swap index 0 and index 1 for a predictable, repeatable debug move.
    final fromIdx = 0;
    final toIdx = 1;
    try {
      await c.reorderClip(fromIndex: fromIdx, toIndex: toIdx);
      if (mounted) {
        final newOrder = c.draft.clips.map((cl) => cl.id).join(' → ');
        setState(() {
          _reorderApplied = true;
          _status = 'Reorder OK — clip order: $newOrder. '
              'Duration: ${c.draft.durationSeconds.toStringAsFixed(2)}s';
        });
      }
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _status = 'Reorder rejected: $e');
    } catch (e) {
      if (mounted) setState(() => _status = 'Reorder error: $e');
    }
  }

  // Phase 7.17: freeze frame debug trigger — freezes Clip A at 3.0s for 2.0s.
  // Verifies freezeClip calls updateTimeline, increases clip count, and inserts a freeze frame.
  Future<void> _freezeClipA() async {
    final c = _controller;
    if (c == null || !c.isReady || _exporting) return;

    try {
      final newDraft = c.draft.freezeClip(
        'clip-A',
        3.0,
        2.0,
      );
      await c.updateDraft(newDraft);
      if (mounted) {
        setState(() {
          _freezeApplied = true;
          _status = 'Freeze OK — Clip A frozen at 3.0s for 2.0s. '
              'Clips: ${c.draft.clips.length}, '
              'Duration: ${c.draft.durationSeconds.toStringAsFixed(2)}s';
        });
      }
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _status = 'Freeze rejected: $e');
    } catch (e) {
      if (mounted) setState(() => _status = 'Freeze error: $e');
    }
  }

  // Phase 7.19B: reverse clip debug trigger — toggles isReversed on Clip A.
  // Verifies reverseClip calls updateTimeline and isReversed toggles on the descriptor.
  Future<void> _reverseClipA() async {
    final c = _controller;
    if (c == null || !c.isReady || _exporting) return;

    try {
      await c.reverseClip(clipId: 'clip-A');
      final nowReversed = c.draft.clips
          .firstWhere((clip) => clip.id == 'clip-A',
              orElse: () => c.draft.clips.first)
          .isReversed;
      if (mounted) {
        setState(() {
          _reverseApplied = nowReversed;
          _status = nowReversed
              ? 'Reverse ON — Clip A is now playing in reverse.'
              : 'Reverse OFF — Clip A restored to forward playback.';
        });
      }
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _status = 'Reverse rejected: $e');
    } catch (e) {
      if (mounted) setState(() => _status = 'Reverse error: $e');
    }
  }

  // Phase 7.20D: trigger background sidecar preparation for all reversed clips.
  Future<void> _prepareSidecars() async {
    final c = _controller;
    if (c == null || !c.isReady || _sidecarBusy) return;
    setState(() {
      _sidecarBusy = true;
      _status = 'Preparing reverse sidecars...';
    });
    try {
      final statuses = await c.prepareReverseSidecars();
      if (mounted) {
        setState(() {
          _sidecarStatuses = statuses;
          _sidecarBusy = false;
          _status = statuses.isEmpty
              ? 'No reversed clips — sidecar preparation skipped.'
              : 'Sidecar preparation complete: '
                  '${statuses.map((s) => '${s.clipId}=${s.state.name}').join(', ')}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sidecarBusy = false;
          _status = 'Sidecar prepare error: $e';
        });
      }
    }
  }

  // Phase 7.20D: query sidecar status for Clip A.
  Future<void> _getSidecarStatusForClipA() async {
    final c = _controller;
    if (c == null || _sidecarBusy) return;
    setState(() {
      _sidecarBusy = true;
      _status = 'Querying sidecar status for clip-A...';
    });
    try {
      final status = await c.getSidecarStatus(clipId: 'clip-A');
      if (mounted) {
        setState(() {
          _sidecarStatuses = [status];
          _sidecarBusy = false;
          _status = 'Sidecar status: clip-A = ${status.state.name} '
              '(progress ${(status.progress * 100).toStringAsFixed(0)}%)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sidecarBusy = false;
          _status = 'Sidecar status error: $e';
        });
      }
    }
  }

  // Phase 7.20D: cancel all in-flight transcodes and delete all sidecar files.
  Future<void> _cleanupSidecars() async {
    final c = _controller;
    if (c == null || _sidecarBusy) return;
    setState(() {
      _sidecarBusy = true;
      _status = 'Cleaning up all sidecars...';
    });
    try {
      await c.cleanupReverseSidecars();
      if (mounted) {
        setState(() {
          _sidecarStatuses = null;
          _sidecarBusy = false;
          _status = 'Sidecar cleanup complete — all files deleted.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sidecarBusy = false;
          _status = 'Sidecar cleanup error: $e';
        });
      }
    }
  }

  Future<void> _export() async {
    final c = _controller;
    if (c == null || !c.isReady || _exporting) return;

    setState(() {
      _exporting = true;
      _exportResult = null;
      _status = 'Exporting composition to H.264 MP4...';
    });

    try {
      final result = await c.export(const VGEditorExportRequest());
      if (mounted) {
        setState(() {
          _exporting = false;
          _exportResult = result;
          _status = 'Export succeeded: ${result.path}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _exporting = false;
          _status = 'Export failed: $e';
        });
      }
    }
  }

  // Phase 7.18B2: fetch live cache stats from the native frame cache.
  Future<void> _fetchCacheStats() async {
    final c = _controller;
    if (c == null || _fetchingStats) return;
    setState(() => _fetchingStats = true);
    try {
      final stats = await c.getTimelineCacheStats();
      if (mounted) setState(() => _cacheStats = stats);
    } finally {
      if (mounted) setState(() => _fetchingStats = false);
    }
  }

  // Phase 7.18B2: evict all frame cache entries and reset counters,
  // then immediately re-fetch to show zeroed stats.
  Future<void> _clearCache() async {
    final c = _controller;
    if (c == null || _fetchingStats) return;
    setState(() => _fetchingStats = true);
    try {
      await c.clearTimelineCache();
      final stats = await c.getTimelineCacheStats();
      if (mounted) {
        setState(() {
          _cacheStats = stats;
          _status = 'Cache cleared — counters reset.';
        });
      }
    } finally {
      if (mounted) setState(() => _fetchingStats = false);
    }
  }

  void _throttledScrubSeek(double seconds) {
    final now = DateTime.now();
    if (_lastScrubSeekAt == null ||
        now.difference(_lastScrubSeekAt!) >= const Duration(milliseconds: 80)) {
      _lastScrubSeekAt = now;
      _channel
          .invokeMethod<void>('timelineSeek', {'seconds': seconds})
          .catchError((_) {});
    }
  }

  // ── Build UI ───────────────────────────────────────────────────────────────

  String get _appBarTitle =>
      'Phase 7.10-7.18B Manual Device Test (DEV ONLY)';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1E29),
        title: Text(
          _appBarTitle,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
      body: _copyingAssets
          ? _buildLoadingScreen()
          : Column(
              children: [
                // ── PASS/FAIL Header ──────────────────────────────────────────
                _buildDecisionHeader(),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ── File & Path Status Card ───────────────────────────
                        _buildFileStatusCard(),
                        const SizedBox(height: 12),

                        // ── Transition & Canvas Controller Card ───────────────
                        _buildSetupControlsCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.11: Clip A Transform Controls ─────────────
                        _buildTransformCard(
                          clipLabel: 'CLIP A',
                          accentColor: const Color(0xFF6C63FF),
                          scaleX: _clipAScaleX,
                          scaleY: _clipAScaleY,
                          rotation: _clipARotation,
                          opacity: _clipAOpacity,
                          transX: _clipATransX,
                          transY: _clipATransY,
                          onScaleX: (v) { setState(() => _clipAScaleX = v); _debouncedRebuild(); },
                          onScaleY: (v) { setState(() => _clipAScaleY = v); _debouncedRebuild(); },
                          onRotation: (v) { setState(() => _clipARotation = v); _debouncedRebuild(); },
                          onOpacity: (v) { setState(() => _clipAOpacity = v); _debouncedRebuild(); },
                          onTransX: (v) { setState(() => _clipATransX = v); _debouncedRebuild(); },
                          onTransY: (v) { setState(() => _clipATransY = v); _debouncedRebuild(); },
                          onReset: () {
                            setState(() {
                              _clipAScaleX = 1.0; _clipAScaleY = 1.0;
                              _clipARotation = 0.0; _clipAOpacity = 1.0;
                              _clipATransX = 0.0; _clipATransY = 0.0;
                            });
                            _rebuildTimeline();
                          },
                        ),
                        const SizedBox(height: 12),

                        // ── Phase 7.11: Clip B Transform Controls ─────────────
                        _buildTransformCard(
                          clipLabel: 'CLIP B',
                          accentColor: const Color(0xFF00D4AA),
                          scaleX: _clipBScaleX,
                          scaleY: _clipBScaleY,
                          rotation: _clipBRotation,
                          opacity: _clipBOpacity,
                          transX: _clipBTransX,
                          transY: _clipBTransY,
                          onScaleX: (v) { setState(() => _clipBScaleX = v); _debouncedRebuild(); },
                          onScaleY: (v) { setState(() => _clipBScaleY = v); _debouncedRebuild(); },
                          onRotation: (v) { setState(() => _clipBRotation = v); _debouncedRebuild(); },
                          onOpacity: (v) { setState(() => _clipBOpacity = v); _debouncedRebuild(); },
                          onTransX: (v) { setState(() => _clipBTransX = v); _debouncedRebuild(); },
                          onTransY: (v) { setState(() => _clipBTransY = v); _debouncedRebuild(); },
                          onReset: () {
                            setState(() {
                              _clipBScaleX = 1.0; _clipBScaleY = 1.0;
                              _clipBRotation = 0.0; _clipBOpacity = 1.0;
                              _clipBTransX = 0.0; _clipBTransY = 0.0;
                            });
                            _rebuildTimeline();
                          },
                        ),
                        const SizedBox(height: 12),

                        // ── Playback & Texture Preview ───────────────────────
                        if (_controller != null) ...[
                          _buildPreviewCard(),
                          const SizedBox(height: 12),
                        ],

                        // ── Export Card ───────────────────────────────────────
                        _buildExportCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.13: Trim Debug Card ────────────────────────
                        _buildTrimDebugCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.14: Split Debug Card ───────────────────────
                        _buildSplitDebugCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.15: Reorder Debug Card ──────────────────────
                        _buildReorderDebugCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.17: Freeze Debug Card ───────────────────────
                        _buildFreezeDebugCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.19B: Reverse Debug Card ─────────────────────────
                        _buildReverseDebugCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.20D: Reverse Sidecar Status HUD ──────────────
                        _buildSidecarStatusCard(),
                        const SizedBox(height: 12),

                        // ── Phase 7.18B2: Cache Metrics HUD ─────────────────────
                        _buildCacheMetricsCard(),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildLoadingScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF6C63FF)),
            const SizedBox(height: 24),
            Text(
              _status,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (_copyError != null) ...[
              const SizedBox(height: 12),
              Text(
                _copyError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDecisionHeader() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFE53935),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Manual Phase 7 Test Fixture — Hanif decides PASS/FAIL',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileStatusCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TEST FIXTURE FILES',
            style: TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          _buildPathRow(
            label: 'Clip A',
            assetPath: _kAssetPathA,
            tempPath: _tempPathA ?? 'Not copied',
            exists: _existsA,
          ),
          const Divider(color: Colors.white10, height: 16),
          _buildPathRow(
            label: 'Clip B',
            assetPath: _kAssetPathB,
            tempPath: _tempPathB ?? 'Not copied',
            exists: _existsB,
          ),
          const Divider(color: Colors.white10, height: 16),
          // Phase 7.12: still-image fixture row.
          _buildPathRow(
            label: 'Still C (img)',
            assetPath: _kAssetPathC,
            tempPath: _tempPathC ?? 'Not copied',
            exists: _existsC,
          ),
          const SizedBox(height: 10),
          // Phase 7.12: toggle to replace Clip B with still_C.png.
          Row(
            children: [
              const Icon(Icons.image_outlined, color: Color(0xFFFF9E00), size: 14),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Use Still Image as Clip B',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ),
              Switch(
                value: _useStillImageClipB,
                activeColor: const Color(0xFFFF9E00),
                onChanged: _existsC
                    ? (v) {
                        setState(() => _useStillImageClipB = v);
                        _rebuildTimeline();
                      }
                    : null,
              ),
            ],
          ),
          if (_useStillImageClipB) ...[
            const Divider(color: Colors.white10, height: 16),
            // Phase 7.16: Still Image Fit/Crop controls (DEV validation only)
            const Text(
              'PHASE 7.16 — STILL IMAGE FIT & CROP (DEV ONLY)',
              style: TextStyle(
                color: Color(0xFFFF9E00),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.fit_screen_outlined, color: Color(0xFFFF9E00), size: 14),
                const SizedBox(width: 6),
                const Text(
                  'Fit Mode:',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(width: 12),
                _buildStillFitButton(VGStillImageFitMode.fit, 'Fit (letterbox)'),
                const SizedBox(width: 8),
                _buildStillFitButton(VGStillImageFitMode.fill, 'Fill (cover)'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.crop_outlined, color: Color(0xFFFF9E00), size: 14),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Apply Crop Rect [0.1, 0.1, 0.8, 0.8]',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
                Switch(
                  value: _useStillCrop,
                  activeColor: const Color(0xFFFF9E00),
                  onChanged: (v) {
                    setState(() => _useStillCrop = v);
                    _rebuildTimeline();
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStillFitButton(VGStillImageFitMode mode, String label) {
    final active = _stillFitMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() => _stillFitMode = mode);
        _rebuildTimeline();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFF9E00) : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? const Color(0xFFFF9E00) : Colors.white10,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPathRow({
    required String label,
    required String assetPath,
    required String tempPath,
    required bool exists,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF00D4AA),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: exists
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    exists ? Icons.check_circle_outline : Icons.error_outline,
                    color: exists ? Colors.green : Colors.red,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    exists ? 'EXISTS' : 'MISSING',
                    style: TextStyle(
                      color: exists ? Colors.green : Colors.red,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Asset: $assetPath',
          style: const TextStyle(color: Colors.white30, fontSize: 10),
        ),
        const SizedBox(height: 2),
        SelectableText(
          'Temp: $tempPath',
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildSetupControlsCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TIMELINE LAYOUT CONFIGURATION',
            style: TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),

          // ── Selected Transition Toggles ──
          const Text(
            'Visual Transition Type',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _buildTransitionButton('hard_cut', 'Hard Cut (0s)'),
              const SizedBox(width: 8),
              _buildTransitionButton('dissolve', 'Dissolve (1s)'),
              const SizedBox(width: 8),
              _buildTransitionButton('fade', 'Fade (1s)'),
            ],
          ),
          const SizedBox(height: 12),

          // ── Selected Canvas Size Toggles ──
          const Text(
            'Canvas Dimensions (Strict Ingestion)',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _buildCanvasButton(1280, 720, '1280×720 @30'),
              const SizedBox(width: 8),
              _buildCanvasButton(640, 360, '640×360 @30'),
              const SizedBox(width: 8),
              _buildCanvasButton(1920, 1080, '1920×1080 @30'),
            ],
          ),
          const SizedBox(height: 12),

          // ── Status Line ──
          Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.white38, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _status,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTransitionButton(String type, String label) {
    final active = _selectedTransition == type;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedTransition = type);
          _rebuildTimeline();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF6C63FF) : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? const Color(0xFF6C63FF) : Colors.white10,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvasButton(int w, int h, String label) {
    final active = _canvasWidth == w && _canvasHeight == h;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _canvasWidth = w;
            _canvasHeight = h;
          });
          _rebuildTimeline();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF00D4AA) : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? const Color(0xFF00D4AA) : Colors.white10,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // Phase 7.11: Transform Controls Card
  // ─────────────────────────────────────────────────────────────────

  Widget _buildTransformCard({
    required String clipLabel,
    required Color accentColor,
    required double scaleX,
    required double scaleY,
    required double rotation,
    required double opacity,
    required double transX,
    required double transY,
    required ValueChanged<double> onScaleX,
    required ValueChanged<double> onScaleY,
    required ValueChanged<double> onRotation,
    required ValueChanged<double> onOpacity,
    required ValueChanged<double> onTransX,
    required ValueChanged<double> onTransY,
    required VoidCallback onReset,
  }) {
    final bool isIdentity = scaleX == 1.0 && scaleY == 1.0 &&
        rotation == 0.0 && opacity == 1.0 && transX == 0.0 && transY == 0.0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isIdentity ? Colors.white10 : accentColor.withValues(alpha: 0.5),
          width: isIdentity ? 1.0 : 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  color: isIdentity ? Colors.white24 : accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$clipLabel SPATIAL TRANSFORM (7.11)',
                style: TextStyle(
                  color: isIdentity ? const Color(0xFF6C7A9C) : accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (!isIdentity)
                GestureDetector(
                  onTap: onReset,
                  child: Text(
                    'RESET',
                    style: TextStyle(
                      color: accentColor.withValues(alpha: 0.8),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
              if (isIdentity)
                const Text(
                  'IDENTITY',
                  style: TextStyle(
                    color: Colors.white24,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Scale X
          _buildSliderRow(
            label: 'Scale X', value: scaleX,
            min: 0.1, max: 3.0, displayDecimals: 2,
            onChanged: onScaleX,
            accentColor: accentColor,
          ),
          // Scale Y
          _buildSliderRow(
            label: 'Scale Y', value: scaleY,
            min: 0.1, max: 3.0, displayDecimals: 2,
            onChanged: onScaleY,
            accentColor: accentColor,
          ),
          // Rotation (radians, display in degrees)
          _buildSliderRow(
            label: 'Rotation',
            value: rotation,
            min: -3.1416, max: 3.1416,
            displayDecimals: 2,
            displaySuffix: ' rad',
            onChanged: onRotation,
            accentColor: accentColor,
          ),
          // Opacity
          _buildSliderRow(
            label: 'Opacity', value: opacity,
            min: 0.0, max: 1.0, displayDecimals: 2,
            onChanged: onOpacity,
            accentColor: accentColor,
          ),
          // Translation X
          _buildSliderRow(
            label: 'Trans X', value: transX,
            min: -640.0, max: 640.0, displayDecimals: 0,
            displaySuffix: 'px',
            onChanged: onTransX,
            accentColor: accentColor,
          ),
          // Translation Y
          _buildSliderRow(
            label: 'Trans Y', value: transY,
            min: -360.0, max: 360.0, displayDecimals: 0,
            displaySuffix: 'px',
            onChanged: onTransY,
            accentColor: accentColor,
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int displayDecimals,
    String displaySuffix = '',
    required ValueChanged<double> onChanged,
    required Color accentColor,
  }) {
    final displayValue = displayDecimals == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(displayDecimals);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: accentColor,
                inactiveTrackColor: Colors.white10,
                thumbColor: accentColor,
                overlayColor: accentColor.withValues(alpha: 0.15),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 2,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '$displayValue$displaySuffix',
              style: TextStyle(color: accentColor, fontSize: 10, fontFamily: 'monospace'),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildPreviewCard() {
    return ValueListenableBuilder<VGEditorValue>(
      valueListenable: _controller!,
      builder: (context, v, _) {
        final duration = v.draft.durationSeconds;
        final pts = _seekDragValue ?? v.currentPTS;
        final isReady = v.isReady && v.textureId != null;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1F1E29),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'VISUAL PLATFORM PREVIEW',
                style: TextStyle(
                  color: Color(0xFF6C7A9C),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),

              // ── Flutter Texture Box ──
              AspectRatio(
                aspectRatio: _canvasWidth / _canvasHeight,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: isReady
                      ? Texture(textureId: v.textureId!)
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(
                                  color: Color(0xFF6C63FF)),
                              const SizedBox(height: 10),
                              Text(
                                v.statusMessage ?? 'Preparing texture...',
                                style: const TextStyle(
                                    color: Colors.white30, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),

              // ── PTS and Texture Info Row ──
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Texture ID: ${v.textureId ?? '—'}',
                    style: const TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                  Text(
                    'PTS: ${pts.toStringAsFixed(2)}s / ${duration.toStringAsFixed(2)}s',
                    style: const TextStyle(
                      color: Color(0xFF00D4AA),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // ── Slider ──
              Slider(
                value: pts.clamp(0.0, duration.clamp(0.01, double.infinity)),
                min: 0.0,
                max: duration.clamp(0.01, double.infinity),
                onChanged: isReady
                    ? (val) {
                        setState(() => _seekDragValue = val);
                        _throttledScrubSeek(val);
                      }
                    : null,
                onChangeEnd: isReady
                    ? (val) {
                        setState(() => _seekDragValue = null);
                        _controller!.seek(val).catchError((_) {});
                      }
                    : null,
              ),

              // ── Play/Pause Button ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: isReady ? _togglePlay : null,
                    icon: Icon(
                      v.isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 16,
                    ),
                    label: Text(v.isPlaying ? 'Pause' : 'Play'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C63FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: isReady
                        ? () => _controller!.seek(0.0).catchError((_) {})
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white10,
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    child: const Text('Rewind'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildExportCard() {
    final ready = _controller?.isReady == true && !_exporting;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'OFFLINE H.264 COMPOSITOR EXPORT',
            style: TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),

          ElevatedButton.icon(
            onPressed: ready ? _export : null,
            icon: _exporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.file_download_outlined, size: 16),
            label: Text(_exporting ? 'Exporting...' : 'Export Timeline'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D4AA),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),

          if (_exportResult != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green, size: 14),
                      SizedBox(width: 6),
                      Text(
                        'Export Succeeded',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    'Path: ${_exportResult!.path}',
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Duration: ${_exportResult!.durationSeconds.toStringAsFixed(3)}s',
                    style: const TextStyle(color: Colors.white30, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Phase 7.13: Trim Debug Card ──────────────────────────────────────────────

  Widget _buildTrimDebugCard() {
    final ready = _controller?.isReady == true && !_exporting;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PHASE 7.13 — TRIM EDITING DEBUG',
            style: TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tap to trim Clip A to [1.5s → 4.5s]. '
            'Verifies updateTimeline is called and duration shrinks.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: ready ? _trimClipA : null,
            icon: _trimApplied
                ? const Icon(Icons.check_circle_outline, size: 16)
                : const Icon(Icons.content_cut_outlined, size: 16),
            label: Text(
              _trimApplied
                  ? 'Trim Applied — tap to re-apply'
                  : 'Trim Clip A → [1.5s – 4.5s]',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE07B39),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Phase 7.14: Split Debug Card ─────────────────────────────────────────────

  Widget _buildSplitDebugCard() {
    final ready = _controller?.isReady == true && !_exporting;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PHASE 7.14 — SPLIT EDITING DEBUG',
            style: TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tap to split Clip A at 3.0s into two clips. '
            'Verifies updateTimeline is called and clip count increases.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: ready ? _splitClipA : null,
            icon: _splitApplied
                ? const Icon(Icons.check_circle_outline, size: 16)
                : const Icon(Icons.cut_outlined, size: 16),
            label: Text(
              _splitApplied
                  ? 'Split Applied — tap to re-apply'
                  : 'Split Clip A @ 3.0s',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3D7AEB),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Phase 7.15: Reorder Debug Card ──────────────────────────────────────────

  Widget _buildReorderDebugCard() {
    final ready = _controller?.isReady == true && !_exporting;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PHASE 7.15 — REORDER EDITING DEBUG',
            style: TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Swaps Clip A (index 0) and Clip B (index 1). '
            'Verifies updateTimeline is called and clip order changes.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: ready ? _reorderClips : null,
            icon: _reorderApplied
                ? const Icon(Icons.check_circle_outline, size: 16)
                : const Icon(Icons.swap_vert_outlined, size: 16),
            label: Text(
              _reorderApplied
                  ? 'Reorder Applied — tap to re-apply'
                  : 'Reorder: Swap Clip A ↔ Clip B',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9C27B0),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Phase 7.17: Freeze Frame Debug Card ────────────────────────────────────────

  Widget _buildFreezeDebugCard() {
    final ready = _controller?.isReady == true && !_exporting;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PHASE 7.17 — FREEZE FRAME EDITING (DEV ONLY)',
            style: TextStyle(
              color: Color(0xFF00D4AA),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Freeze Clip A at 3.0s with a 2.0s hold duration. '
            'Verifies freezeClip splits and inserts a static video frame.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: ready ? _freezeClipA : null,
            icon: _freezeApplied
                ? const Icon(Icons.check_circle_outline, size: 16)
                : const Icon(Icons.ac_unit_outlined, size: 16),
            label: Text(
              _freezeApplied
                  ? 'Freeze Applied — tap to re-apply'
                  : 'Freeze Clip A @ 3.0s for 2.0s',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D4AA),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Phase 7.19B: Reverse Playback Debug Card ──────────────────────────────

  Widget _buildReverseDebugCard() {
    final ready = _controller?.isReady == true && !_exporting;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _reverseApplied
              ? const Color(0xFFFF6B6B).withValues(alpha: 0.6)
              : Colors.white10,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PHASE 7.19B — REVERSE PLAYBACK (DEV ONLY)',
            style: TextStyle(
              color: Color(0xFFFF6B6B),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Toggles isReversed on Clip A. '
            'Verifies reverseClip calls updateTimeline and the clip plays backwards.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: ready ? _reverseClipA : null,
            icon: _reverseApplied
                ? const Icon(Icons.check_circle_outline, size: 16)
                : const Icon(Icons.swap_horiz_outlined, size: 16),
            label: Text(
              _reverseApplied
                  ? 'Reverse ON — tap to restore forward'
                  : 'Reverse Clip A',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCacheMetricsCard() {
    final ready     = _controller != null;
    final hits      = _cacheStats['frameCacheHits']      ?? 0;
    final misses    = _cacheStats['frameCacheMisses']    ?? 0;
    final evictions = _cacheStats['frameCacheEvictions'] ?? 0;
    final inserts   = _cacheStats['frameCacheInserts']   ?? 0;
    final entries   = _cacheStats['frameCacheEntries']   ?? 0;
    final bytes     = _cacheStats['frameCacheBytes']     ?? 0;
    const maxBytes  = 32 * 1024 * 1024; // 32 MB budget (Phase 7.18A)

    final totalLookups = hits + misses;
    final hitRatePct   = totalLookups > 0
        ? (hits / totalLookups * 100.0).toStringAsFixed(1)
        : '—';
    final usageMb = (bytes / (1024 * 1024)).toStringAsFixed(2);
    const budgetMb = '32.00';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF6C63FF).withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.speed_outlined, color: Color(0xFF6C63FF), size: 14),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'PHASE 7.18B2 — FRAME CACHE METRICS (DEV ONLY)',
                  style: TextStyle(
                    color: Color(0xFF6C63FF),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              if (_fetchingStats)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF6C63FF),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Live native LRU frame cache counters. '
            'Tap "Fetch Stats" to refresh. "Clear Cache" forces cold decode.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 10),

          // ── Stats rows ────────────────────────────────────────────────────
          if (_cacheStats.isNotEmpty) ...[
            _buildStatRow('Hits',      '$hits',        const Color(0xFF00D4AA)),
            _buildStatRow('Misses',    '$misses',      Colors.orangeAccent),
            _buildStatRow('Hit rate',  '$hitRatePct%', const Color(0xFF6C63FF)),
            _buildStatRow('Evictions', '$evictions',   Colors.redAccent),
            _buildStatRow('Inserts',   '$inserts',     Colors.white54),
            _buildStatRow('Entries',   '$entries',     Colors.white54),
            _buildStatRow(
              'Cache used',
              '$usageMb MB / $budgetMb MB',
              bytes > maxBytes * 0.9 ? Colors.redAccent : Colors.white54,
            ),
            const SizedBox(height: 8),
            // Budget fill bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (bytes / maxBytes).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(
                  bytes > maxBytes * 0.9
                      ? Colors.redAccent
                      : const Color(0xFF6C63FF),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ] else ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No stats yet — tap "Fetch Stats" to load.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ],

          // ── Buttons ────────────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: ready && !_fetchingStats ? _fetchCacheStats : null,
                  icon: const Icon(Icons.refresh_outlined, size: 14),
                  label: const Text('Fetch Stats'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: ready && !_fetchingStats ? _clearCache : null,
                  icon: const Icon(Icons.delete_outline, size: 14),
                  label: const Text('Clear Cache'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // ── Phase 7.20D: Reverse Sidecar Status HUD ────────────────────────────────

  Widget _buildSidecarStatusCard() {
    final ready = _controller?.isReady == true && !_sidecarBusy;

    Color _stateColor(VGReverseSidecarState s) {
      switch (s) {
        case VGReverseSidecarState.ready:       return const Color(0xFF00D4AA);
        case VGReverseSidecarState.preparing:   return const Color(0xFFFF9E00);
        case VGReverseSidecarState.failed:      return Colors.redAccent;
        case VGReverseSidecarState.invalidated: return Colors.white54;
        default:                                return Colors.white24;
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFFF6B6B).withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.sync_outlined, color: Color(0xFFFF6B6B), size: 14),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'PHASE 7.20D — REVERSE SIDECAR STATUS (DEV ONLY)',
                  style: TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              if (_sidecarBusy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFFFF6B6B),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Controls VGReverseSidecarManager. '
            'Tap "Prepare Sidecars" after toggling Reverse ON above. '
            '"Get Status" polls clip-A. "Cleanup" deletes all sidecar files.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 10),

          // ── Status Rows ───────────────────────────────────────────────────
          if (_sidecarStatuses != null && _sidecarStatuses!.isNotEmpty) ...[
            for (final s in _sidecarStatuses!) ...[
              Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                      color: _stateColor(s.state),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    s.clipId,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.state.name.toUpperCase(),
                    style: TextStyle(
                      color: _stateColor(s.state),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${(s.progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: _stateColor(s.state),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              if (s.state == VGReverseSidecarState.preparing) ...[
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: s.progress,
                    minHeight: 4,
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFFF9E00),
                    ),
                  ),
                ),
              ],
              if (s.errorMessage != null) ...[
                const SizedBox(height: 2),
                Text(
                  'Error: ${s.errorMessage}',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 9),
                ),
              ],
              if (s.sidecarPath != null) ...[
                const SizedBox(height: 2),
                SelectableText(
                  'Path: ${s.sidecarPath}',
                  style: const TextStyle(color: Colors.white30, fontSize: 9),
                ),
              ],
              const SizedBox(height: 6),
            ],
            const Divider(color: Colors.white10, height: 8),
            const SizedBox(height: 6),
          ] else ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'No sidecar status yet — tap "Prepare Sidecars" or "Get Status".',
                style: TextStyle(color: Colors.white30, fontSize: 10),
              ),
            ),
          ],

          // ── Action Buttons ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: ready ? _prepareSidecars : null,
                  icon: const Icon(Icons.compress_outlined, size: 14),
                  label: const Text('Prepare Sidecars'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B6B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _controller != null && !_sidecarBusy
                      ? _getSidecarStatusForClipA
                      : null,
                  icon: const Icon(Icons.info_outline, size: 14),
                  label: const Text('Get Status'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C7A9C),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _controller != null && !_sidecarBusy
                      ? _cleanupSidecars
                      : null,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 14),
                  label: const Text('Cleanup'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white12,
                    foregroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

