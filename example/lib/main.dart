// example/lib/main.dart
// Vanguard Media Engine — Full-Screen Camera Reference Screen
//
// Demonstrates the complete Phase 6 API surface:
//   - VGCameraSession.create / dispose (lifecycle)
//   - VGCameraPreview (GPU texture widget)
//   - applyTransaction with rebuild preset (Phase 6C.2A)
//   - applyTransaction with hot beauty.intensity update (Phase 6C.2B)
//   - switchCamera (front/back flip)
//   - setTorchMode (torch toggle)
//   - takePhoto (JPEG capture to temp path)
//   - startRecording / stopRecording (MP4 to temp path)
//
// Scope: package example only. Zero production-app modifications.
// Phase 7 Stage 7.3: adds VanguardTimelinePlayground navigation entry.
// Constraints honoured:
//   - No modification of connectsapp_app or connectsapp_* directories.
//   - No native iOS/Android file edits.
//   - No packages/UMF modifications.
//   - Zero speculative UI blocking loops.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// Phase 7 Stage 7.10: manual timeline transition test playground (engine/example only).
import 'vanguard_manual_test_playground.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Entry point
// ──────────────────────────────────────────────────────────────────────────────

void main() {
  runApp(const VanguardExampleApp());
}

// ──────────────────────────────────────────────────────────────────────────────
// App root
// ──────────────────────────────────────────────────────────────────────────────

class VanguardExampleApp extends StatelessWidget {
  const VanguardExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vanguard Camera Reference',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF00D4AA),
        ),
      ),
      home: const FullScreenCameraScreen(),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Preset definitions
// ──────────────────────────────────────────────────────────────────────────────

/// Preset catalogue used by the preset selector strip.
///
/// Only presets whose filter types are currently supported by the native
/// camera graph path are included here. LUT and LUT-composite presets
/// (Glow, LUT) are omitted: VGCameraGraphSession rejects \"lut\" specs with
/// UNSUPPORTED_FILTER_TYPE. They will be restored once LUT is constructable.
final List<_PresetEntry> _kPresets = [
  _PresetEntry(
    label: 'None',
    emoji: '✕',
    descriptor: VGPresetDescriptor(
      id: 'none',
      name: 'None',
      filterStack: const [],
    ),
  ),
  _PresetEntry(
    label: 'Soft',
    emoji: '✦',
    descriptor: VGPresetDescriptor(
      id: 'soft',
      name: 'Soft',
      filterStack: [VGFilterSpecs.beauty(intensity: 0.5)],
    ),
  ),
];

class _PresetEntry {
  const _PresetEntry({
    required this.label,
    required this.emoji,
    required this.descriptor,
  });
  final String label;
  final String emoji;
  final VGPresetDescriptor descriptor;
}

// ──────────────────────────────────────────────────────────────────────────────
// Full-screen camera screen
// ──────────────────────────────────────────────────────────────────────────────

class FullScreenCameraScreen extends StatefulWidget {
  const FullScreenCameraScreen({super.key});

  @override
  State<FullScreenCameraScreen> createState() => _FullScreenCameraScreenState();
}

class _FullScreenCameraScreenState extends State<FullScreenCameraScreen>
    with WidgetsBindingObserver {
  // ── Session state ──────────────────────────────────────────────────────────

  VGCameraSession? _session;
  bool _sessionStarting = false;
  String? _errorMessage;

  // ── Camera control state ───────────────────────────────────────────────────

  VGCameraPosition _position = VGCameraPosition.front;
  bool _torchOn = false;
  bool _switching = false;

  // ── Preset state ───────────────────────────────────────────────────────────

  int _selectedPresetIndex = 0; // index into _kPresets
  bool _applyingPreset = false;

  // ── Beauty intensity (hot parameter) ──────────────────────────────────────

  double _beautyIntensity = 0.5;
  // We only show the slider when a beauty-carrying preset is active.
  bool get _activePresetHasBeauty => _kPresets[_selectedPresetIndex]
      .descriptor
      .filterStack
      .any((f) => f.type == 'beauty');

  // ── Zoom state ─────────────────────────────────────────────────────────────

  double _zoomFactor = 1.0;
  double _baseZoomFactor = 1.0;
  DateTime _lastZoomTime = DateTime.fromMillisecondsSinceEpoch(0);
  // Show zoom badge transiently after a pinch gesture.
  bool _zoomBadgeVisible = false;
  Timer? _zoomBadgeTimer;
  // Device-native zoom capability bounds — loaded after session starts and
  // reloaded after every camera switch. Falls back to 1.0–6.0 if the native
  // query fails or the session is not yet ready.
  VGCameraZoomCapabilities _zoomCapabilities = VGCameraZoomCapabilities.fallback;

  // ── Focus / expose overlay state ───────────────────────────────────────────

  Offset? _focusTapPosition; // screen coords for indicator placement
  bool _focusRingVisible = false;
  Timer? _focusTimer;

  // ── Recording state ────────────────────────────────────────────────────────

  bool _recording = false;
  bool _recordingBusy = false;

  // ── Photo state ────────────────────────────────────────────────────────────

  bool _takingPhoto = false;
  String? _lastPhotoPath;

  // ── Status overlay ─────────────────────────────────────────────────────────

  String? _statusMessage;
  Timer? _statusTimer;

  // ──────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // ── Portrait orientation lock ──────────────────────────────────────────────
    // This package reference screen is portrait-canonical. The 9:16 FittedBox
    // preview layout and _mapPreviewTapToCameraPoint both assume portrait
    // 1080×1920 capture buffers. Full landscape camera support (dynamic buffer
    // dimensions, orientation-aware coordinate mapping) is explicitly deferred
    // and is not part of this Phase 6 reference path.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addObserver(this);
    _startSession();
  }

  @override
  void dispose() {
    // Restore system default so other screens are not portrait-locked.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _zoomBadgeTimer?.cancel();
    _focusTimer?.cancel();
    _session?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume camera on foreground return; stop on background.
    if (state == AppLifecycleState.resumed && _session == null) {
      _startSession();
    } else if (state == AppLifecycleState.paused) {
      _session?.dispose();
      if (mounted) {
        setState(() {
          _session = null;
          _recording = false;
        });
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Session management
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _startSession() async {
    if (_sessionStarting) return;
    setState(() {
      _sessionStarting = true;
      _errorMessage = null;
    });
    try {
      final session = await VGCameraSession.create(
        position: _position,
        fps: 30,
      );
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _sessionStarting = false;
      });
      // Load device-native zoom capabilities. Uses fallback (1.0–6.0) on
      // any failure so pinch-zoom continues working regardless.
      final caps = await session.getZoomCapabilities();
      if (mounted) {
        setState(() {
          _zoomCapabilities = caps;
          // Clamp current zoom factor into new capability range in case the
          // capability max is tighter than the default 6.0 fallback.
          _zoomFactor = _zoomFactor
              .clamp(caps.minZoomFactor, caps.maxZoomFactor)
              .toDouble();
        });
      }

    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _sessionStarting = false;
        _errorMessage = 'Camera error: ${e.code} — ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sessionStarting = false;
        _errorMessage = 'Camera error: $e';
      });
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Camera controls
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _flipCamera() async {
    final session = _session;
    if (session == null || _switching || _recording) return;
    setState(() => _switching = true);
    try {
      final next = _position == VGCameraPosition.front
          ? VGCameraPosition.back
          : VGCameraPosition.front;
      await session.switchCamera(next);
      if (!mounted) return;
      setState(() {
        _position = next;
        // Torch is not available on front camera — reset.
        if (_position == VGCameraPosition.front && _torchOn) {
          _torchOn = false;
        }
        // Reset zoom to 1× when switching cameras. The new camera may have a
        // different range; we hold off clamping until capabilities are loaded.
        _zoomFactor = 1.0;
        _baseZoomFactor = 1.0;
      });
      // Reload zoom capabilities for the new camera. Front and back cameras
      // have different recommended max zoom values — do not reuse stale caps.
      final caps = await session.getZoomCapabilities();
      if (!mounted) return;
      setState(() {
        _zoomCapabilities = caps;
        // Clamp current zoom into the new range (1.0 is already safe, but
        // guard in case future code changes _zoomFactor above).
        _zoomFactor =
            _zoomFactor.clamp(caps.minZoomFactor, caps.maxZoomFactor).toDouble();
      });
    } on PlatformException catch (e) {
      _showStatus('Flip failed: ${e.code}');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _toggleTorch() async {
    final session = _session;
    if (session == null || _position == VGCameraPosition.front) return;
    final next = !_torchOn;
    try {
      await session.setTorchMode(next ? VGTorchMode.on : VGTorchMode.off);
      if (!mounted) return;
      setState(() => _torchOn = next);
    } on PlatformException catch (e) {
      _showStatus('Torch error: ${e.code}');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Zoom gesture handlers
  // ──────────────────────────────────────────────────────────────────────────

  void _handleScaleStart(ScaleStartDetails details) {
    _baseZoomFactor = _zoomFactor;
  }

  Future<void> _handleScaleUpdate(ScaleUpdateDetails details) async {
    if (details.pointerCount < 2) return; // single-finger drag — ignore
    final session = _session;
    if (session == null) return;

    final newZoom = (_baseZoomFactor * details.scale)
        .clamp(_zoomCapabilities.minZoomFactor, _zoomCapabilities.maxZoomFactor)
        .toDouble();

    if ((newZoom - _zoomFactor).abs() < 0.01) return; // dead-band

    // Throttle native calls to ~30 fps.
    final now = DateTime.now();
    if (now.difference(_lastZoomTime).inMilliseconds < 33) return;
    _lastZoomTime = now;

    setState(() {
      _zoomFactor = newZoom;
      _zoomBadgeVisible = true;
    });

    // Show badge for 1.5 s after the last pinch movement.
    _zoomBadgeTimer?.cancel();
    _zoomBadgeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _zoomBadgeVisible = false);
    });

    try {
      await session.setZoom(newZoom);
    } catch (_) {
      // Silently absorb — zoom badge already updated; don't break preview.
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Preview → camera coordinate mapping
  // ──────────────────────────────────────────────────────────────────────────

  /// Maps a tap position in widget-local screen coordinates to a normalised
  /// camera point in the range [0, 1] × [0, 1].
  ///
  /// [VGCameraPreview] renders the 9:16 (portrait) sensor feed with
  /// aspect-fill (cover) semantics — whichever axis overflows the widget is
  /// centre-cropped.  This helper recovers the correct sensor fraction by
  /// computing the rendered dimensions, then shifts the tap into that space
  /// before normalising and clamping.
  ///
  /// Front-camera output is mirrored horizontally on the preview so the
  /// displayed image is a "mirror"; the sensor point is un-mirrored by
  /// flipping `mappedX` before passing it to AVFoundation.
  Offset _mapPreviewTapToCameraPoint({
    required Offset localTap,
    required Size widgetSize,
    required bool isFrontCamera,
  }) {
    // The camera preview is always a 9:16 portrait feed.
    const double previewAspectRatio = 9.0 / 16.0;

    final double widgetAspectRatio = widgetSize.width / widgetSize.height;

    double renderedWidth = widgetSize.width;
    double renderedHeight = widgetSize.height;
    double offsetX = 0.0;
    double offsetY = 0.0;

    if (widgetAspectRatio > previewAspectRatio) {
      // Widget is wider than the preview — top/bottom are cropped.
      renderedHeight = widgetSize.width / previewAspectRatio;
      offsetY = (renderedHeight - widgetSize.height) / 2.0;
    } else {
      // Widget is taller than (or equal to) the preview — sides are cropped.
      renderedWidth = widgetSize.height * previewAspectRatio;
      offsetX = (renderedWidth - widgetSize.width) / 2.0;
    }

    final double mappedX =
        ((localTap.dx + offsetX) / renderedWidth).clamp(0.0, 1.0);
    final double mappedY =
        ((localTap.dy + offsetY) / renderedHeight).clamp(0.0, 1.0);

    // Mirror X for the front camera so the sensor point matches the
    // un-mirrored sensor frame that AVFoundation expects.
    final double cameraX = isFrontCamera ? 1.0 - mappedX : mappedX;
    final double cameraY = mappedY;

    return Offset(cameraX, cameraY);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Tap-to-focus / tap-to-expose
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _handleTapDown(TapDownDetails details, BoxConstraints constraints) async {
    final session = _session;
    if (session == null) return;

    final tapPos = details.localPosition;
    final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);

    // Map the screen tap to normalised camera sensor coordinates using the
    // cover-crop-aware helper.  The focus ring is kept at the original screen
    // tap position so the visual feedback reflects where the user tapped.
    final mapped = _mapPreviewTapToCameraPoint(
      localTap: tapPos,
      widgetSize: widgetSize,
      isFrontCamera: _position == VGCameraPosition.front,
    );

    setState(() {
      // Focus ring stays at screen-space tap position, not the mapped point.
      _focusTapPosition = tapPos;
      _focusRingVisible = true;
    });

    // Auto-hide the ring after 2 s.
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusRingVisible = false);
    });

    try {
      await session.setFocusPoint(mapped.dx, mapped.dy);
    } catch (_) {
      // Silently absorb — focus indicator is already shown.
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Preset application (Phase 6C.2A — rebuild transaction)
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _applyPreset(int index) async {
    final session = _session;
    if (session == null || _applyingPreset) return;
    // Capture prior index so we can revert on failure — prevents the beauty
    // slider from becoming sticky on an unapplied preset.
    final previousIndex = _selectedPresetIndex;
    setState(() {
      _applyingPreset = true;
      _selectedPresetIndex = index;
    });
    try {
      final preset = _kPresets[index].descriptor;
      final payload = session.prepareTransaction((tx) {
        tx.applyPreset(preset);
      });
      await session.applyTransaction(payload);
      if (!mounted) return;
      setState(() => _applyingPreset = false);
      _showStatus('Preset applied: ${preset.name}');
    } on PlatformException catch (e) {
      if (!mounted) return;
      // Revert selection so slider visibility reflects the actual active preset.
      setState(() {
        _applyingPreset = false;
        _selectedPresetIndex = previousIndex;
      });
      _showStatus('Preset error: ${e.code}');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Hot beauty intensity update (Phase 6C.2B — hot parameter transaction)
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _applyBeautyIntensity(double value) async {
    final session = _session;
    if (session == null) return;
    setState(() => _beautyIntensity = value);
    try {
      final payload = session.prepareTransaction((tx) {
        tx.setParameter('beauty', 'intensity', value);
      });
      await session.applyTransaction(payload);
    } on PlatformException {
      // Silently absorb — slider will stay at last value; no graph rebuild.
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Photo capture
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _takePhoto() async {
    final session = _session;
    if (session == null || _takingPhoto) return;
    setState(() => _takingPhoto = true);
    try {
      final dir = Directory.systemTemp.path;
      final path = '$dir/vg_photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final written = await session.takePhoto(path);
      if (!mounted) return;
      setState(() {
        _lastPhotoPath = written;
        _takingPhoto = false;
      });
      _showStatus('Photo saved');
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _takingPhoto = false);
      _showStatus('Photo error: ${e.code}');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Recording
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _toggleRecording() async {
    final session = _session;
    if (session == null || _recordingBusy) return;
    setState(() => _recordingBusy = true);
    try {
      if (!_recording) {
        final dir = Directory.systemTemp.path;
        final path = '$dir/vg_rec_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await session.startRecording(path);
        if (!mounted) return;
        setState(() => _recording = true);
        _showStatus('Recording…');
      } else {
        final stats = await session.stopRecording();
        if (!mounted) return;
        setState(() => _recording = false);
        _showStatus(
          'Saved: ${stats.filePath.split('/').last} '
          '(${stats.totalFrames} frames, ${stats.droppedFrames} dropped)',
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _recording = false);
      _showStatus('Recording error: ${e.code}');
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Status banner helper
  // ──────────────────────────────────────────────────────────────────────────

  void _showStatus(String message) {
    _statusTimer?.cancel();
    if (!mounted) return;
    setState(() => _statusMessage = message);
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _statusMessage = null);
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera preview (full-screen) ───────────────────────────────────
          _buildPreview(),

          // ── Gradient overlays ─────────────────────────────────────────────
          _buildTopGradient(),
          _buildBottomGradient(),

          // ── Top controls row ──────────────────────────────────────────────
          _buildTopControls(),

          // ── Preset strip ──────────────────────────────────────────────────
          _buildPresetStrip(),

          // ── Beauty intensity slider ───────────────────────────────────────
          if (_activePresetHasBeauty) _buildBeautySlider(),

          // ── Bottom shutter row ────────────────────────────────────────────
          _buildBottomControls(),

          // ── Status banner ─────────────────────────────────────────────────
          if (_statusMessage != null) _buildStatusBanner(),

          // ── Recording indicator ───────────────────────────────────────────
          if (_recording) _buildRecordingPill(),
        ],
      ),
    );
  }

  // ── Preview ────────────────────────────────────────────────────────────────

  Widget _buildPreview() {
    final session = _session;
    if (session != null) {
      // Wrap the live preview in a LayoutBuilder so tap-to-focus can access
      // the real widget dimensions for coordinate mapping.
      return LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            onScaleStart: _handleScaleStart,
            onScaleUpdate: (details) => _handleScaleUpdate(details),
            onTapDown: (details) => _handleTapDown(details, constraints),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 9:16 cover/crop layout — matches _mapPreviewTapToCameraPoint math.
                // ClipRect clips overflow; FittedBox scales to fill the full-screen
                // stack; SizedBox constrains the texture to 9:16 before scaling.
                ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: 9,
                      height: 16,
                      child: VGCameraPreview(session: session),
                    ),
                  ),
                ),
                // Zoom badge.
                if (_zoomBadgeVisible) _buildZoomBadge(),
                // Focus / expose ring.
                if (_focusRingVisible && _focusTapPosition != null)
                  _buildFocusRing(_focusTapPosition!),
              ],
            ),
          );
        },
      );
    }
    if (_sessionStarting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF6C63FF)),
            SizedBox(height: 16),
            Text(
              'Starting camera…',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      );
    }
    // Error state.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white38,
              size: 64,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? 'Camera unavailable',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startSession,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Zoom badge ─────────────────────────────────────────────────────────────

  Widget _buildZoomBadge() {
    final label = _zoomCapabilities.displayLabelFor(_zoomFactor);

    return Positioned(
      bottom: 200,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _zoomBadgeVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24, width: 1),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Focus ring ─────────────────────────────────────────────────────────────

  Widget _buildFocusRing(Offset tapPos) {
    const ringSize = 72.0;
    return Positioned(
      left: tapPos.dx - ringSize / 2,
      top: tapPos.dy - ringSize / 2,
      child: _FocusRingWidget(size: ringSize),
    );
  }

  // ── Gradient overlays ──────────────────────────────────────────────────────

  Widget _buildTopGradient() => Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: 160,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent],
        ),
      ),
    ),
  );

  Widget _buildBottomGradient() => Positioned(
    bottom: 0,
    left: 0,
    right: 0,
    height: 280,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xEE000000), Colors.transparent],
        ),
      ),
    ),
  );

  // ── Top controls ───────────────────────────────────────────────────────────

  Widget _buildTopControls() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              // Torch button (back camera only).
              _CameraIconButton(
                key: const ValueKey('torch_btn'),
                icon: _torchOn ? Icons.flash_on : Icons.flash_off,
                active: _torchOn,
                enabled:
                    _session != null &&
                    _position == VGCameraPosition.back &&
                    !_switching,
                onTap: _toggleTorch,
                tooltip: 'Toggle torch',
              ),
              const Spacer(),
              // Session / texture ID label (debug info).
              if (_session != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'tex:${_session!.textureId}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              // Phase 7 playground navigation buttons — wrapped in a
              // scrollable container to prevent overflow on narrow screens.
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Phase 7 Stage 7.10: manual device test playground.
                      _CameraIconButton(
                        key: const ValueKey('manual_device_test_btn'),
                        icon: Icons.flourescent_outlined,
                        active: false,
                        enabled: true,
                        onTap: () async {
                          // Stop the single-camera session before pushing so the
                          // MultiCam playground can safely start its own session.
                          _session?.dispose();
                          setState(() {
                            _session = null;
                          });

                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const VanguardManualTestPlayground(),
                            ),
                          );

                          if (!mounted) return;

                          // Restart the single-camera preview on pop.
                          _startSession();
                        },
                        tooltip: 'Manual Device Test (Hanif decides PASS/FAIL)',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Preset strip ───────────────────────────────────────────────────────────

  Widget _buildPresetStrip() {
    return Positioned(
      bottom: 180,
      left: 0,
      right: 0,
      child: SizedBox(
        height: 72,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: _kPresets.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, i) {
            final preset = _kPresets[i];
            final selected = i == _selectedPresetIndex;
            return GestureDetector(
              onTap: _applyingPreset || _session == null
                  ? null
                  : () => _applyPreset(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: selected
                      ? const Color(0xFF6C63FF)
                      : Colors.white.withValues(alpha: 0.12),
                  border: selected
                      ? Border.all(color: Colors.white54, width: 1.5)
                      : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(preset.emoji, style: const TextStyle(fontSize: 18)),
                    const SizedBox(height: 4),
                    Text(
                      preset.label,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white60,
                        fontSize: 11,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Beauty intensity slider ────────────────────────────────────────────────

  Widget _buildBeautySlider() {
    return Positioned(
      bottom: 258,
      left: 24,
      right: 24,
      child: Row(
        children: [
          const Icon(Icons.auto_fix_high, color: Colors.white54, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                activeTrackColor: const Color(0xFF6C63FF),
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: const Color(0x446C63FF),
              ),
              child: Slider(
                value: _beautyIntensity,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                onChanged: _session == null ? null : _applyBeautyIntensity,
              ),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              _beautyIntensity.toStringAsFixed(2),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Bottom shutter row ─────────────────────────────────────────────────────

  Widget _buildBottomControls() {
    final sessionReady = _session != null;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Photo thumbnail / last photo indicator.
              _PhotoThumbButton(
                key: const ValueKey('photo_thumb'),
                path: _lastPhotoPath,
                enabled: sessionReady && !_takingPhoto,
                onTap: _takePhoto,
              ),

              // Shutter (record toggle).
              _ShutterButton(
                key: const ValueKey('shutter_btn'),
                recording: _recording,
                busy: _recordingBusy || !sessionReady,
                onTap: _toggleRecording,
              ),

              // Camera flip button.
              _CameraIconButton(
                key: const ValueKey('flip_btn'),
                icon: Icons.flip_camera_ios_outlined,
                enabled: sessionReady && !_switching && !_recording,
                onTap: _flipCamera,
                tooltip: 'Flip camera',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Status banner ──────────────────────────────────────────────────────────

  Widget _buildStatusBanner() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 56, left: 24, right: 24),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF6C63FF).withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _statusMessage!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Recording pill ─────────────────────────────────────────────────────────

  Widget _buildRecordingPill() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 56),
          child: Center(child: _RecordingPill()),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Composable sub-widgets
// ──────────────────────────────────────────────────────────────────────────────

/// Animated focus / exposure ring.
///
/// Draws a yellow square ring that scales in, holds, then fades out.
class _FocusRingWidget extends StatefulWidget {
  const _FocusRingWidget({required this.size});
  final double size;

  @override
  State<_FocusRingWidget> createState() => _FocusRingWidgetState();
}

class _FocusRingWidgetState extends State<_FocusRingWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    // Scale from 1.4 → 1.0 (snap-in feel).
    _scale = Tween<double>(begin: 1.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    // Fade from 0 → 1 for the first 30% then hold.
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 70,
      ),
    ]).animate(_ctrl);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Opacity(
          opacity: _opacity.value,
          child: Transform.scale(
            scale: _scale.value,
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: CustomPaint(
                painter: _FocusRingPainter(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Draws a square focus-ring (four corner brackets) in yellow.
class _FocusRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFD600) // vivid yellow
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final cornerLen = size.width * 0.28;
    final r = 4.0; // corner radius
    final l = 0.0;
    final w = size.width;
    final h = size.height;

    // Top-left corner.
    canvas.drawPath(
      Path()
        ..moveTo(l, l + cornerLen)
        ..lineTo(l, l + r)
        ..arcToPoint(Offset(l + r, l), radius: Radius.circular(r))
        ..lineTo(l + cornerLen, l),
      paint,
    );
    // Top-right corner.
    canvas.drawPath(
      Path()
        ..moveTo(w - cornerLen, l)
        ..lineTo(w - r, l)
        ..arcToPoint(Offset(w, l + r), radius: Radius.circular(r))
        ..lineTo(w, l + cornerLen),
      paint,
    );
    // Bottom-right corner.
    canvas.drawPath(
      Path()
        ..moveTo(w, h - cornerLen)
        ..lineTo(w, h - r)
        ..arcToPoint(Offset(w - r, h), radius: Radius.circular(r))
        ..lineTo(w - cornerLen, h),
      paint,
    );
    // Bottom-left corner.
    canvas.drawPath(
      Path()
        ..moveTo(l + cornerLen, h)
        ..lineTo(l + r, h)
        ..arcToPoint(Offset(l, h - r), radius: Radius.circular(r))
        ..lineTo(l, h - cornerLen),
      paint,
    );

    // Centre cross-hair dot.
    canvas.drawCircle(
      Offset(w / 2, h / 2),
      math.min(2.5, size.width * 0.04),
      paint..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Pulsing red "REC" pill shown while recording is active.
class _RecordingPill extends StatefulWidget {
  @override
  State<_RecordingPill> createState() => _RecordingPillState();
}

class _RecordingPillState extends State<_RecordingPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fiber_manual_record, color: Colors.white, size: 10),
            SizedBox(width: 6),
            Text(
              'REC',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular shutter button that animates between capture and stop states.
class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    super.key,
    required this.recording,
    required this.busy,
    required this.onTap,
  });

  final bool recording;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: recording ? Colors.red : Colors.white,
          boxShadow: [
            BoxShadow(
              color: (recording ? Colors.red : Colors.white).withValues(
                alpha: 0.35,
              ),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            width: recording ? 26 : 62,
            height: recording ? 26 : 62,
            decoration: BoxDecoration(
              color: recording ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(recording ? 6 : 31),
              border: recording
                  ? null
                  : Border.all(color: Colors.black12, width: 3),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small camera icon button used for torch and flip actions.
class _CameraIconButton extends StatelessWidget {
  const _CameraIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.enabled = true,
    this.tooltip = '',
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool enabled;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? const Color(0xFF6C63FF).withValues(alpha: 0.85)
                : Colors.black38,
            border: Border.all(
              color: active ? const Color(0xFF6C63FF) : Colors.white24,
              width: 1.5,
            ),
          ),
          child: Icon(
            icon,
            color: enabled ? Colors.white : Colors.white38,
            size: 22,
          ),
        ),
      ),
    );
  }
}

/// Shows the last captured photo as a small thumbnail; tapping triggers
/// the next photo capture.
class _PhotoThumbButton extends StatelessWidget {
  const _PhotoThumbButton({
    super.key,
    required this.path,
    required this.enabled,
    required this.onTap,
  });

  final String? path;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white30, width: 1.5),
          color: Colors.black38,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: path != null
              ? Image.file(
                  File(path!),
                  fit: BoxFit.cover,
                  errorBuilder: (ctx, err, stack) => const Icon(
                    Icons.broken_image,
                    color: Colors.white38,
                    size: 20,
                  ),
                )
              : const Icon(
                  Icons.photo_camera_outlined,
                  color: Colors.white54,
                  size: 22,
                ),
        ),
      ),
    );
  }
}
