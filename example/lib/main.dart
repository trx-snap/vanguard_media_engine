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
// Constraints honoured:
//   - No modification of connectsapp_app or connectsapp_* directories.
//   - No native iOS/Android file edits.
//   - No packages/UMF modifications.
//   - Zero speculative UI blocking loops.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

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
/// Each preset is a [VGPresetDescriptor] built from [VGFilterSpecs] helpers.
/// The "None" preset carries an empty filterStack (clears filters on native).
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
  _PresetEntry(
    label: 'Glow',
    emoji: '✧',
    descriptor: VGPresetDescriptor(
      id: 'glow',
      name: 'Glow',
      filterStack: [
        VGFilterSpecs.beauty(intensity: 0.7),
        VGFilterSpecs.lut(intensity: 0.4),
      ],
    ),
  ),
  _PresetEntry(
    label: 'LUT',
    emoji: '◈',
    descriptor: VGPresetDescriptor(
      id: 'lut-only',
      name: 'LUT',
      filterStack: [VGFilterSpecs.lut(intensity: 1.0)],
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
    WidgetsBinding.instance.addObserver(this);
    _startSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
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
  // Preset application (Phase 6C.2A — rebuild transaction)
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _applyPreset(int index) async {
    final session = _session;
    if (session == null || _applyingPreset) return;
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
      // After preset change, clamp beauty slider if not supported.
      setState(() => _applyingPreset = false);
      _showStatus('Preset applied: ${preset.name}');
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _applyingPreset = false);
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
      return VGCameraPreview(session: session);
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
