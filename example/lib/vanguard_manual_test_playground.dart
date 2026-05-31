// vanguard_manual_test_playground.dart
// Vanguard Media Engine — Phase 7 Stage 7.10: Manual Test Playground
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

  // ── Temp File Paths ─────────────────────────────────────────────────────────
  String? _tempPathA;
  String? _tempPathB;

  bool _existsA = false;
  bool _existsB = false;

  // ── Canvas Configurations ──────────────────────────────────────────────────
  int _canvasWidth = 1280;
  int _canvasHeight = 720;
  final int _fps = 30;

  // ── Active Transition ──────────────────────────────────────────────────────
  String _selectedTransition = 'dissolve'; // 'hard_cut' | 'dissolve' | 'fade'

  // ── Controller & Lifecycle ──────────────────────────────────────────────────
  VGEditorController? _controller;
  bool _copyingAssets = true;
  String _status = 'Initializing...';
  String? _copyError;

  // ── Export State ───────────────────────────────────────────────────────────
  bool _exporting = false;
  VGEditorExportResult? _exportResult;

  // ── Seek scrub throttle ────────────────────────────────────────────────────
  double? _seekDragValue;
  DateTime? _lastScrubSeekAt;

  @override
  void initState() {
    super.initState();
    _prepareAssets();
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller?.disposeAsync().catchError((_) {});
    _controller?.dispose();
    super.dispose();
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

      if (!mounted) return;

      setState(() {
        _tempPathA = pathA;
        _tempPathB = pathB;
        _existsA = existsA;
        _existsB = existsB;
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
      ),
      VGClipDescriptor(
        id: 'clip-B',
        sourcePath: _tempPathB!,
        durationSeconds: 5.56,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.56,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1E29),
        title: const Text(
          'Phase 7.10 Manual Device Test',
          style: TextStyle(
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

                        // ── Playback & Texture Preview ───────────────────────
                        if (_controller != null) ...[
                          _buildPreviewCard(),
                          const SizedBox(height: 12),
                        ],

                        // ── Export Card ───────────────────────────────────────
                        _buildExportCard(),
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
        ],
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
}
