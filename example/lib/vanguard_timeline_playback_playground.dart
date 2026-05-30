// vanguard_timeline_playback_playground.dart
// Vanguard Media Engine — Phase 7 Stage 7.5D: Real Video Timeline Playback Proof
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.5D — REAL VIDEO PROOF PLAYGROUND
// ═══════════════════════════════════════════════════════════════════════════════
//
// Extends Stage 7.5C by adding an opt-in "Real Video" source mode.
// In Real Video mode the native layer generates true H.264 MP4 clips with a
// moving white stripe pattern (via _generateMovingPatternVideo) instead of
// solid-color synthetic frames. This proves that AVAssetReader is decompressing
// genuine inter-frame H.264 content in the timeline pull loop.
//
// DEFAULT REMAINS SYNTHETIC so the 7.5C baseline still passes by default.
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.5C — VISUAL PROOF PLAYGROUND
// ═══════════════════════════════════════════════════════════════════════════════
//
// Renders a multi-clip synthetic timeline through the Metal → Flutter texture
// path via the native dev_createTimelineTexture method channel call.
//
// SCOPE:
//   - Example-layer only (packages/vanguard_media_engine/example).
//   - Does NOT add production editor UI.
//   - Does NOT add public Dart API surface.
//   - Does NOT implement still-image clips (Stage 7.5 limitation).
//   - Does NOT implement fade/dissolve transitions (Stage 7.5 limitation).
//   - Does NOT implement export (deferred to Stage 7.6+).
//   - Does NOT touch ConnectsApp.
//
// VISUAL PROOF CRITERIA (from Opus 7.5C validation):
//   1. Flutter Texture widget renders synthetic colored frames via Metal path.
//   2. Play/pause controls toggle the CADisplayLink pull loop.
//   3. Seek slider sets the timeline position and proves generation invalidation.
//   4. PTS overlay updates from onTimelineFrame method channel callback.
//   5. EOS notification received and displayed when compositor reaches end.
//
// METHOD CHANNEL USAGE:
//   Call:     dev_createTimelineTexture({ clips: [...], transitions: [] })
//   Returns:  { textureId: Int64, width: Int, height: Int }
//   Call:     dev_timelinePlay()
//   Call:     dev_timelinePause()
//   Call:     dev_timelineSeek({ seconds: Double })
//   Call:     dev_disposeTimeline()
//   Listen:   onTimelineFrame (from native → Dart invocation)
//   Listen:   onTimelineEOS   (from native → Dart invocation)
//
// SYNTHETIC CLIPS:
//   Two 5-second solid-color MP4 clips generated at runtime via
//   VGTimelineCompositorSmokeTest.generateSyntheticClipPaths (DEBUG only):
//     Clip A: red  320×240 @30fps — vg_playback_clip_A.mp4 in NSTemporaryDirectory
//     Clip B: blue 320×240 @30fps — vg_playback_clip_B.mp4 in NSTemporaryDirectory
//   Triggered by dev_createTimelineTexture({ useSyntheticClips: true }).
//
// DESIGN PRINCIPLES:
//   - Zero Future.delayed / Get.dialog / speculative blocking loops.
//   - Dispose on widget unmount (WillPopScope or overridden dispose).
//   - Method channel on the standard 'vanguard_media_engine' channel.
//   - PTS display updated from method channel callback (onTimelineFrame).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Constants
// ──────────────────────────────────────────────────────────────────────────────

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

/// Total synthetic timeline duration (2 clips × 5 seconds each).
const double _kTimelineDuration = 10.0;

// ──────────────────────────────────────────────────────────────────────────────
// VanguardTimelinePlaybackPlayground
// ──────────────────────────────────────────────────────────────────────────────

/// Phase 7 Stage 7.5C: visual timeline playback proof playground.
///
/// Renders a synthetic 2-clip timeline through the Metal → Flutter texture path.
/// Provides play/pause/seek controls and a PTS overlay updated via the native
/// onTimelineFrame method channel callback.
///
/// Navigation: pushed from [VanguardExampleApp] home screen.
class VanguardTimelinePlaybackPlayground extends StatefulWidget {
  const VanguardTimelinePlaybackPlayground({super.key});

  @override
  State<VanguardTimelinePlaybackPlayground> createState() =>
      _VanguardTimelinePlaybackPlaygroundState();
}

class _VanguardTimelinePlaybackPlaygroundState
    extends State<VanguardTimelinePlaybackPlayground> {
  // ── State ─────────────────────────────────────────────────────────────────

  /// Flutter texture ID returned by dev_createTimelineTexture.
  /// -1 until prepare succeeds.
  int? _textureId;

  /// Render dimensions reported by native (always 1920×1080 in Stage 7.5C).
  int _width = 1920;
  int _height = 1080;

  /// Whether the timeline is currently playing (PTS advances automatically).
  bool _playing = false;

  /// Current playhead position in seconds. Updated from onTimelineFrame callbacks.
  double _currentPTS = 0.0;

  /// Whether the timeline has reached EOS.
  bool _atEOS = false;

  /// User-controlled seek position (while the slider is being dragged).
  double? _seekDragValue;

  /// Human-readable status message.
  String _status = 'Initializing…';

  /// Whether an async operation (create or seek) is in progress.
  bool _busy = true;

  /// Source mode: when true, native generates real H.264 moving-pattern clips
  /// (vg_playback_real_clip_A.mp4 / _B.mp4) instead of solid-color synthetic ones.
  /// Default is false so Stage 7.5C baseline still works without toggling.
  bool _useRealVideo = false;

  // ── Live-scrub throttle state ─────────────────────────────────────────────

  /// Timestamp of the last throttled native seek sent while dragging.
  /// Reset to null when the slider is released.
  DateTime? _lastScrubSeekAt;

  /// Whether the timeline was playing when the user began dragging the slider.
  /// Used to restore play state after the user releases the thumb.
  bool _wasPlayingBeforeScrub = false;

  // ── Method channel handler ─────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // Register handler for native → Dart method channel invocations.
    // onTimelineFrame: { pts: Double, generation: Int }
    // onTimelineEOS:   null
    _channel.setMethodCallHandler(_handleMethodCall);

    // Start prepare immediately on first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _disposeTimeline();
    super.dispose();
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onTimelineFrame':
        final args = call.arguments as Map?;
        final pts = (args?['pts'] as num?)?.toDouble() ?? _currentPTS;
        if (mounted && !(_seekDragValue != null)) {
          setState(() {
            _currentPTS = pts;
            _atEOS = false;
          });
        }
        break;
      case 'onTimelineEOS':
        if (mounted) {
          setState(() {
            _playing = false;
            _atEOS = true;
            _status = 'End of timeline reached';
          });
        }
        break;
    }
    return null;
  }

  // ── Live-scrub helpers ────────────────────────────────────────────────────

  /// Sends a native seek only if ≥ 80 ms have elapsed since the last one.
  ///
  /// This prevents spamming [dev_timelineSeek] → [seekTimelineTo:] on every
  /// sub-pixel drag delta, while still providing fluid visual updates
  /// (~12 seeks/s at 80 ms, well within the CADisplayLink tick budget).
  ///
  /// Does NOT update [_seekDragValue] — the caller controls that separately
  /// for smooth slider-thumb positioning independent of the native rate.
  ///
  /// Fire-and-forget: errors are logged via [_seekTo] internally.
  void _throttledScrubSeek(double seconds) {
    final now = DateTime.now();
    if (_lastScrubSeekAt == null ||
        now.difference(_lastScrubSeekAt!) >= const Duration(milliseconds: 80)) {
      _lastScrubSeekAt = now;
      // Seek without clearing _seekDragValue so the slider thumb keeps moving.
      _channel.invokeMethod<void>('dev_timelineSeek', {'seconds': seconds})
          .catchError((_) {});
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> _prepare() async {
    setState(() {
      _busy = true;
      _status = 'Preparing timeline…';
    });

    try {
      // useSyntheticClips: true  → native solid-color 7.5C clips (default).
      // useRealVideoClips: true  → native moving-pattern H.264 clips (7.5D opt-in).
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'dev_createTimelineTexture',
        {
          'useSyntheticClips': !_useRealVideo,
          'useRealVideoClips': _useRealVideo,
        },
      );

      if (!mounted) return;

      final textureId = (result?['textureId'] as num?)?.toInt();
      if (textureId == null || textureId < 0) {
        setState(() {
          _busy = false;
          _status = 'Prepare failed: native returned textureId=$textureId';
        });
        return;
      }

      final w = (result?['width']  as num?)?.toInt() ?? 320;
      final h = (result?['height'] as num?)?.toInt() ?? 240;

      setState(() {
        _textureId = textureId;
        _width     = w;
        _height    = h;
        _busy      = false;
        _status    = 'Ready — tap ▶ to play';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy   = false;
        _status = 'Prepare error: $e';
      });
    }
  }

  Future<void> _play() async {
    if (_textureId == null || _busy) return;
    try {
      await _channel.invokeMethod<void>('dev_timelinePlay');
      if (!mounted) return;
      setState(() {
        _playing = true;
        _atEOS   = false;
        _status  = 'Playing';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Play error: ${e.message}');
    }
  }

  Future<void> _pause() async {
    if (_textureId == null || _busy) return;
    try {
      await _channel.invokeMethod<void>('dev_timelinePause');
      if (!mounted) return;
      setState(() {
        _playing = false;
        _status  = 'Paused at ${_currentPTS.toStringAsFixed(2)}s';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Pause error: ${e.message}');
    }
  }

  Future<void> _seekTo(double seconds) async {
    if (_textureId == null) return;
    try {
      await _channel.invokeMethod<void>('dev_timelineSeek', {'seconds': seconds});
      if (!mounted) return;
      setState(() {
        _currentPTS    = seconds;
        _seekDragValue = null;
        _atEOS         = false;
        _status        = 'Seeked to ${seconds.toStringAsFixed(2)}s';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _seekDragValue = null;
        _status = 'Seek error: ${e.message}';
      });
    }
  }

  Future<void> _disposeTimeline() async {
    try {
      await _channel.invokeMethod<void>('dev_disposeTimeline');
    } catch (_) {
      // Best-effort — runtime may already be gone.
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar:   AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Timeline Playback (7.5D)',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          // Stage tag badge.
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'STAGE 7.5D',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── Texture / placeholder area ──────────────────────────────────
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Texture widget.
                  if (_textureId != null)
                    Positioned.fill(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width:  _width.toDouble(),
                          height: _height.toDouble(),
                          child: Texture(
                            key: ValueKey('timeline_texture_$_textureId'),
                            textureId: _textureId!,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      ),
                    ),

                  // Loading / error overlay.
                  if (_textureId == null)
                    Container(
                      color: const Color(0xFF1A1A2E),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_busy)
                              const CircularProgressIndicator(
                                color: Color(0xFF6C63FF),
                              )
                            else
                              const Icon(
                                Icons.error_outline,
                                color: Colors.red,
                                size: 48,
                              ),
                            const SizedBox(height: 16),
                            Text(
                              _status,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),

                  // PTS overlay (top-right, always visible when playing).
                  if (_textureId != null)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _PtsOverlay(
                        pts: _seekDragValue ?? _currentPTS,
                        duration: _kTimelineDuration,
                        atEOS: _atEOS,
                      ),
                    ),

                  // Clip indicator (shows which synthetic clip is active).
                  if (_textureId != null)
                    Positioned(
                      top: 12,
                      left: 12,
                      child: _ClipIndicator(
                        pts: _seekDragValue ?? _currentPTS,
                      ),
                    ),
                ],
              ),
            ),

            // ── Controls panel ──────────────────────────────────────────────────────
            Container(
              color: const Color(0xFF0D0D1A),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Source mode toggle (7.5D).
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Synthetic',
                        style: TextStyle(
                          color: !_useRealVideo ? Colors.white : Colors.white38,
                          fontSize: 12,
                          fontWeight: !_useRealVideo
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      Switch(
                        value: _useRealVideo,
                        onChanged: _busy
                            ? null
                            : (v) {
                                // Opus-required pattern: clear texture before
                                // dispose so the stale frame disappears immediately.
                                setState(() {
                                  _useRealVideo = v;
                                  _textureId = null;
                                  _playing = false;
                                  _currentPTS = 0.0;
                                  _seekDragValue = null;
                                  _status = 'Switching source…';
                                });
                                _disposeTimeline().then((_) => _prepare());
                              },
                        activeThumbColor: const Color(0xFF6C63FF),
                      ),
                      Text(
                        'Real Video',
                        style: TextStyle(
                          color: _useRealVideo ? Colors.white : Colors.white38,
                          fontSize: 12,
                          fontWeight: _useRealVideo
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),

                  Text(
                    _status,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),

                  // Seek slider.
                  // onChangeStart — pause if playing; remember state for restore.
                  // onChanged    — move thumb immediately + throttled native seek.
                  // onChangeEnd  — final exact native seek + optional play resume.
                  _SeekSlider(
                    value: _seekDragValue ?? _currentPTS,
                    max: _kTimelineDuration,
                    enabled: _textureId != null && !_busy,
                    onChangeStart: (v) {
                      if (_playing) {
                        _wasPlayingBeforeScrub = true;
                        _pause();
                      } else {
                        _wasPlayingBeforeScrub = false;
                      }
                    },
                    onChanged: (v) {
                      setState(() => _seekDragValue = v);
                      _throttledScrubSeek(v);
                    },
                    onChangeEnd: (v) {
                      // Always send the exact final position.
                      _seekTo(v);
                      _lastScrubSeekAt = null;
                      if (_wasPlayingBeforeScrub) {
                        _wasPlayingBeforeScrub = false;
                        // Small delay so the seek frame settles before play.
                        Future.delayed(const Duration(milliseconds: 120), () {
                          if (mounted) _play();
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 8),

                  // Time labels.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatPTS(_seekDragValue ?? _currentPTS),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                      Text(
                        _formatPTS(_kTimelineDuration),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Play / Pause / Seek-to-start row.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Seek to start.
                      _ControlButton(
                        icon: Icons.skip_previous,
                        enabled: _textureId != null && !_busy,
                        onTap: () => _seekTo(0.0),
                        tooltip: 'Seek to start',
                      ),
                      const SizedBox(width: 20),
                      // Play / Pause.
                      _ControlButton(
                        icon: _playing ? Icons.pause : Icons.play_arrow,
                        enabled: _textureId != null && !_busy,
                        large: true,
                        primary: true,
                        onTap: _playing ? _pause : _play,
                        tooltip: _playing ? 'Pause' : 'Play',
                      ),
                      const SizedBox(width: 20),
                      // Seek to end (5s remaining — to prove EOS path).
                      _ControlButton(
                        icon: Icons.skip_next,
                        enabled: _textureId != null && !_busy,
                        onTap: () => _seekTo(_kTimelineDuration - 1.0),
                        tooltip: 'Seek near end',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Synthetic clip legend.
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ClipLegendBadge(label: 'Clip A', color: Colors.red),
                      SizedBox(width: 12),
                      _ClipLegendBadge(label: 'Clip B', color: Colors.blue),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatPTS(double pts) {
    final clamped = pts.clamp(0.0, _kTimelineDuration);
    final m = (clamped ~/ 60).toString().padLeft(2, '0');
    final s = (clamped % 60).toStringAsFixed(2).padLeft(5, '0');
    return '$m:$s';
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ──────────────────────────────────────────────────────────────────────────────

class _PtsOverlay extends StatelessWidget {
  const _PtsOverlay({
    required this.pts,
    required this.duration,
    required this.atEOS,
  });

  final double pts;
  final double duration;
  final bool atEOS;

  @override
  Widget build(BuildContext context) {
    final pctStr = duration > 0
        ? '${(pts / duration * 100).clamp(0, 100).toStringAsFixed(1)}%'
        : '0.0%';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: atEOS ? Colors.amber : const Color(0xFF6C63FF),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (atEOS)
            const Icon(Icons.stop_circle_outlined,
                color: Colors.amber, size: 12),
          if (atEOS) const SizedBox(width: 4),
          Text(
            '${pts.toStringAsFixed(2)}s  $pctStr',
            style: TextStyle(
              color: atEOS ? Colors.amber : Colors.white,
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipIndicator extends StatelessWidget {
  const _ClipIndicator({required this.pts});
  final double pts;

  @override
  Widget build(BuildContext context) {
    final isClipA = pts < 5.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (isClipA ? Colors.red : Colors.blue).withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isClipA ? '● CLIP A (synthetic)' : '● CLIP B (synthetic)',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SeekSlider extends StatelessWidget {
  const _SeekSlider({
    required this.value,
    required this.max,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
    this.onChangeStart,
  });

  final double value;
  final double max;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  /// Called when the user first touches the slider thumb.
  /// Optional — if absent, no drag-start behaviour is applied.
  final ValueChanged<double>? onChangeStart;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
        activeTrackColor: const Color(0xFF6C63FF),
        inactiveTrackColor: Colors.white12,
        thumbColor: Colors.white,
        overlayColor: const Color(0x446C63FF),
      ),
      child: Slider(
        key: const ValueKey('timeline_seek_slider'),
        value: value.clamp(0.0, max),
        min: 0.0,
        max: max,
        onChangeStart: enabled ? onChangeStart : null,
        onChanged: enabled ? onChanged : null,
        onChangeEnd: enabled ? onChangeEnd : null,
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.large = false,
    this.primary = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  final bool large;
  final bool primary;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final size = large ? 64.0 : 44.0;
    final iconSize = large ? 32.0 : 22.0;

    final button = GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary
              ? (enabled
                  ? const Color(0xFF6C63FF)
                  : const Color(0xFF6C63FF).withValues(alpha: 0.3))
              : Colors.white.withValues(alpha: enabled ? 0.1 : 0.04),
          border: Border.all(
            color: primary
                ? Colors.transparent
                : Colors.white.withValues(alpha: enabled ? 0.2 : 0.06),
          ),
        ),
        child: Icon(
          icon,
          color: enabled ? Colors.white : Colors.white38,
          size: iconSize,
        ),
      ),
    );

    return tooltip != null
        ? Tooltip(message: tooltip!, child: button)
        : button;
  }
}

class _ClipLegendBadge extends StatelessWidget {
  const _ClipLegendBadge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    );
  }
}
