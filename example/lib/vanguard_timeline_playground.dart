// vanguard_timeline_playground.dart
// Vanguard Media Engine — Phase 7 Stage 7.3
//
// Package example app playground for descriptor/playhead validation.
//
// PURPOSE:
//   Validates VGClipDescriptor and VGTransitionDescriptor Dart models in
//   the package example app. This screen is engine/example validation only.
//   No ConnectsApp dependency. No native timeline rendering.
//
// WHAT THIS VALIDATES (Stage 7.1 + 7.3):
//   - VGClipDescriptor construction, validation asserts, copyWith, toMap.
//   - VGTransitionDescriptor construction, validation asserts, copyWith, toMap.
//   - Live trim slider → descriptor update loop.
//   - Serialised descriptor map output.
//
// WHAT THIS DOES NOT DO:
//   - No native VGTimelineCompositorNode rendering (Stage 7.5).
//   - No VGEditorGraphFactory graph construction (Stage 7.4).
//   - No FFI expansion (deferred per Opus validation recommendation).
//   - No ConnectsApp editor integration (Stage 7.6).
//   - No actual media file loading or AVFoundation usage.
//
// CLEARLY LABELLED: "Descriptor Playground — Stage 7.1/7.3"

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry widget
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 7 Stage 7.3 — Timeline descriptor validation playground.
///
/// Use `Navigator.push(context, MaterialPageRoute(builder: (_) => const VanguardTimelinePlayground()))`.
/// Or open from the example app's camera screen via the "Timeline Playground" button.
class VanguardTimelinePlayground extends StatefulWidget {
  const VanguardTimelinePlayground({super.key});

  @override
  State<VanguardTimelinePlayground> createState() =>
      _VanguardTimelinePlaygroundState();
}

class _VanguardTimelinePlaygroundState
    extends State<VanguardTimelinePlayground>
    with SingleTickerProviderStateMixin {
  // ── Sample data ─────────────────────────────────────────────────────────────
  // Two sample clips backed by placeholder paths. No real files required
  // for descriptor validation in Stage 7.1/7.3.

  static const double _kSampleDuration = 15.0; // seconds
  static const double _kMinTrimLength = 1.0;   // enforce minimum trim window

  late VGClipDescriptor _clipA;
  late VGClipDescriptor _clipB;
  late VGTransitionDescriptor _transition;

  // ── Trim slider state (clip A) ───────────────────────────────────────────────
  double _trimStart = 0.0;
  double _trimEnd = 10.0;

  // ── Transition state ─────────────────────────────────────────────────────────
  VGTransitionType _transitionType = VGTransitionType.dissolve;
  VGTransitionCurve _transitionCurve = VGTransitionCurve.easeInOut;
  double _transitionDuration = 0.5;

  // ── Active inspector tab ─────────────────────────────────────────────────────
  int _inspectorTab = 0; // 0 = Clip A, 1 = Clip B, 2 = Transition

  // ── Tab controller for inspector ─────────────────────────────────────────────
  late TabController _tabController;

  // ── Speed (Clip A) ───────────────────────────────────────────────────────────
  double _clipASpeed = 1.0;

  // ── Media kind (Clip A) ──────────────────────────────────────────────────────
  VGMediaKind _clipAKind = VGMediaKind.video;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() => _inspectorTab = _tabController.index);
    });
    _rebuildDescriptors();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Descriptor assembly
  // ─────────────────────────────────────────────────────────────────────────────

  void _rebuildDescriptors() {
    // Clip A: driven by the trim sliders in this playground.
    _clipA = VGClipDescriptor(
      id: 'clip-playground-A',
      sourcePath: '/tmp/playground_clip_A.mp4',
      mediaKind: _clipAKind,
      startTimeSeconds: 0.0,
      durationSeconds: _kSampleDuration,
      trimStartSeconds: _trimStart,
      trimEndSeconds: _trimEnd,
      speed: _clipASpeed,
    );

    // Clip B: fixed reference clip (no live sliders in this slice).
    _clipB = VGClipDescriptor(
      id: 'clip-playground-B',
      sourcePath: '/tmp/playground_clip_B.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: _clipA.timelineDuration,
      durationSeconds: 12.0,
      trimStartSeconds: 1.0,
      trimEndSeconds: 11.0,
      speed: 1.0,
    );

    // Transition: between Clip A and Clip B.
    _transition = VGTransitionDescriptor(
      id: 'tr-playground-AB',
      type: _transitionType,
      durationSeconds: _transitionDuration,
      fromClipId: _clipA.id,
      toClipId: _clipB.id,
      curve: _transitionCurve,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Slider handlers
  // ─────────────────────────────────────────────────────────────────────────────

  void _onTrimRangeChanged(RangeValues values) {
    final start = values.start;
    var end = values.end;
    // Guard minimum trim length.
    if (end - start < _kMinTrimLength) {
      end = (start + _kMinTrimLength).clamp(0.0, _kSampleDuration);
    }
    setState(() {
      _trimStart = start;
      _trimEnd = end;
      _rebuildDescriptors();
    });
  }

  void _onTransitionDurationChanged(double value) {
    setState(() {
      _transitionDuration = value;
      _rebuildDescriptors();
    });
  }

  void _onTransitionTypeChanged(VGTransitionType? type) {
    if (type == null) return;
    setState(() {
      _transitionType = type;
      _rebuildDescriptors();
    });
  }

  void _onTransitionCurveChanged(VGTransitionCurve? curve) {
    if (curve == null) return;
    setState(() {
      _transitionCurve = curve;
      _rebuildDescriptors();
    });
  }

  void _onSpeedChanged(double value) {
    setState(() {
      _clipASpeed = value;
      _rebuildDescriptors();
    });
  }

  void _onMediaKindChanged(VGMediaKind? kind) {
    if (kind == null) return;
    setState(() {
      _clipAKind = kind;
      _rebuildDescriptors();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A12),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // ── Phase banner ───────────────────────────────────────────────────
          _buildPhaseBanner(),

          // ── Timeline visualisation ────────────────────────────────────────
          _buildTimelineViz(),

          // ── Clip A trim controls ──────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  _buildClipAControls(),
                  const SizedBox(height: 16),
                  _buildTransitionControls(),
                  const SizedBox(height: 16),
                  _buildInspector(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // App bar
  // ─────────────────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF12121E),
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      title: const Text(
        'Timeline Playground',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 16, top: 10, bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF6C63FF).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF6C63FF), width: 1),
          ),
          child: const Text(
            'Stage 7.1 / 7.3',
            style: TextStyle(
              color: Color(0xFF6C63FF),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Phase banner
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildPhaseBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF1A1A2E),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: const Text(
        '⚠️  Descriptor Playground — Stage 7.1/7.3  ·  No native rendering  ·  No source files required',
        style: TextStyle(
          color: Color(0xFFFFCC44),
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Timeline visualisation
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildTimelineViz() {
    final totalTimeline = _clipA.timelineDuration + _clipB.timelineDuration;
    final clipAFraction =
        totalTimeline > 0 ? _clipA.timelineDuration / totalTimeline : 0.5;

    return Container(
      color: const Color(0xFF12121E),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TIMELINE ARRANGEMENT',
            style: TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;
              final overlapWidth =
                  totalWidth * (_transitionDuration / totalTimeline).clamp(0.0, 0.15);
              final clipAWidth = totalWidth * clipAFraction - overlapWidth / 2;
              final clipBWidth = totalWidth * (1 - clipAFraction) - overlapWidth / 2;

              return SizedBox(
                height: 52,
                child: Stack(
                  children: [
                    // ── Clip A block ──────────────────────────────────────────
                    Positioned(
                      left: 0,
                      top: 6,
                      width: clipAWidth + overlapWidth,
                      height: 40,
                      child: _ClipBlock(
                        label: 'A',
                        subtitle:
                            '${_clipA.trimDuration.toStringAsFixed(1)}s  ×${_clipA.speed}',
                        color: const Color(0xFF6C63FF),
                        isActive: _inspectorTab == 0,
                        onTap: () => _tabController.animateTo(0),
                      ),
                    ),
                    // ── Transition overlap indicator ────────────────────────
                    if (!_transition.isHardCut)
                      Positioned(
                        left: clipAWidth,
                        top: 0,
                        width: overlapWidth * 2,
                        height: 52,
                        child: Center(
                          child: Container(
                            width: overlapWidth * 2,
                            height: 52,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  const Color(0xFF6C63FF).withValues(alpha: 0.4),
                                  const Color(0xFF00D4AA).withValues(alpha: 0.4),
                                ],
                              ),
                            ),
                            child: Center(
                              child: Text(
                                _transitionTypeLabel(_transitionType),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    // ── Clip B block ──────────────────────────────────────────
                    Positioned(
                      left: clipAWidth + overlapWidth,
                      top: 6,
                      width: clipBWidth + overlapWidth,
                      height: 40,
                      child: _ClipBlock(
                        label: 'B',
                        subtitle: '${_clipB.trimDuration.toStringAsFixed(1)}s',
                        color: const Color(0xFF00D4AA),
                        isActive: _inspectorTab == 1,
                        onTap: () => _tabController.animateTo(1),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          // ── Timeline duration label ─────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.access_time, color: Color(0xFF6C7A9C), size: 12),
              const SizedBox(width: 4),
              Text(
                'Total: ${(_clipA.timelineDuration + _clipB.timelineDuration).toStringAsFixed(2)}s'
                '  ·  Clip A: ${_clipA.timelineDuration.toStringAsFixed(2)}s'
                '  ·  Clip B: ${_clipB.timelineDuration.toStringAsFixed(2)}s',
                style: const TextStyle(
                  color: Color(0xFF6C7A9C),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _transitionTypeLabel(VGTransitionType t) {
    switch (t) {
      case VGTransitionType.none:
        return 'CUT';
      case VGTransitionType.fade:
        return 'FADE';
      case VGTransitionType.dissolve:
        return 'DSLV';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Clip A controls
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildClipAControls() {
    return _Section(
      title: 'CLIP A — TRIM WINDOW',
      badge: 'VGClipDescriptor',
      badgeColor: const Color(0xFF6C63FF),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Trim range slider ────────────────────────────────────────────
          Row(
            children: [
              _LabelText('Trim'),
              Expanded(
                child: RangeSlider(
                  values: RangeValues(_trimStart, _trimEnd),
                  min: 0.0,
                  max: _kSampleDuration,
                  divisions: 150,
                  activeColor: const Color(0xFF6C63FF),
                  inactiveColor: const Color(0xFF2A2A40),
                  labels: RangeLabels(
                    '${_trimStart.toStringAsFixed(2)}s',
                    '${_trimEnd.toStringAsFixed(2)}s',
                  ),
                  onChanged: _onTrimRangeChanged,
                ),
              ),
            ],
          ),
          // ── Trim result ──────────────────────────────────────────────────
          _ValueRow('trimStart', '${_trimStart.toStringAsFixed(3)}s'),
          _ValueRow('trimEnd', '${_trimEnd.toStringAsFixed(3)}s'),
          _ValueRow('trimDuration', '${_clipA.trimDuration.toStringAsFixed(3)}s'),
          const SizedBox(height: 8),
          // ── Speed slider ─────────────────────────────────────────────────
          Row(
            children: [
              _LabelText('Speed'),
              Expanded(
                child: Slider(
                  value: _clipASpeed,
                  min: 0.25,
                  max: 4.0,
                  divisions: 60,
                  activeColor: const Color(0xFF6C63FF),
                  inactiveColor: const Color(0xFF2A2A40),
                  label: '${_clipASpeed.toStringAsFixed(2)}×',
                  onChanged: _onSpeedChanged,
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${_clipASpeed.toStringAsFixed(2)}×',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          _ValueRow('timelineDuration', '${_clipA.timelineDuration.toStringAsFixed(3)}s'),
          const SizedBox(height: 8),
          // ── Media kind ───────────────────────────────────────────────────
          Row(
            children: [
              _LabelText('Kind'),
              const SizedBox(width: 8),
              ...VGMediaKind.values.map((kind) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _KindChip(
                      label: kind.value,
                      selected: _clipAKind == kind,
                      onTap: () => _onMediaKindChanged(kind),
                    ),
                  )),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Transition controls
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildTransitionControls() {
    return _Section(
      title: 'TRANSITION A → B',
      badge: 'VGTransitionDescriptor',
      badgeColor: const Color(0xFF00D4AA),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Type selector ────────────────────────────────────────────────
          Row(
            children: [
              _LabelText('Type'),
              const SizedBox(width: 8),
              ...VGTransitionType.values.map((t) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _KindChip(
                      label: t.value,
                      selected: _transitionType == t,
                      color: const Color(0xFF00D4AA),
                      onTap: () => _onTransitionTypeChanged(t),
                    ),
                  )),
            ],
          ),
          const SizedBox(height: 8),
          // ── Duration slider ──────────────────────────────────────────────
          Row(
            children: [
              _LabelText('Dur.'),
              Expanded(
                child: Slider(
                  value: _transitionDuration,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  activeColor: const Color(0xFF00D4AA),
                  inactiveColor: const Color(0xFF2A2A40),
                  label: '${_transitionDuration.toStringAsFixed(2)}s',
                  onChanged: _transition.type == VGTransitionType.none
                      ? null
                      : _onTransitionDurationChanged,
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${_transitionDuration.toStringAsFixed(2)}s',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          // ── Curve selector ───────────────────────────────────────────────
          Row(
            children: [
              _LabelText('Curve'),
              const SizedBox(width: 8),
              Wrap(
                spacing: 6,
                children: VGTransitionCurve.values.map((c) => _KindChip(
                      label: c.value,
                      selected: _transitionCurve == c,
                      color: const Color(0xFF00D4AA),
                      onTap: () => _onTransitionCurveChanged(c),
                    )).toList(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _ValueRow('isHardCut', _transition.isHardCut.toString()),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Inspector (serialised map output)
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildInspector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'DESCRIPTOR INSPECTOR — toMap() OUTPUT',
          style: TextStyle(
            color: Color(0xFF6C7A9C),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF12121E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2A2A40)),
          ),
          child: Column(
            children: [
              TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFF6C63FF),
                labelColor: Colors.white,
                unselectedLabelColor: const Color(0xFF6C7A9C),
                labelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                tabs: const [
                  Tab(text: 'Clip A'),
                  Tab(text: 'Clip B'),
                  Tab(text: 'Transition'),
                ],
              ),
              SizedBox(
                height: 240,
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _JsonView(map: _clipA.toMap()),
                    _JsonView(map: _clipB.toMap()),
                    _JsonView(map: _transition.toMap()),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // ── Round-trip validation ────────────────────────────────────────
        _RoundTripValidator(clipA: _clipA, clipB: _clipB, transition: _transition),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

/// A colour-coded clip block for the timeline visualisation row.
class _ClipBlock extends StatelessWidget {
  const _ClipBlock({
    required this.label,
    required this.subtitle,
    required this.color,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final Color color;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isActive ? 0.30 : 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: color.withValues(alpha: isActive ? 0.90 : 0.40),
            width: isActive ? 1.5 : 1.0,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Clip $label',
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section container with title and badge.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.child,
  });

  final String title;
  final String badge;
  final Color badgeColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF12121E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A40)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF6C7A9C),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.40)),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Label text for slider rows.
class _LabelText extends StatelessWidget {
  const _LabelText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF8A90AB),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Key–value display row for descriptor fields.
class _ValueRow extends StatelessWidget {
  const _ValueRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6C7A9C),
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white70,
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

/// Media kind / transition type chip.
class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color = const Color(0xFF6C63FF),
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.20) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.80)
                : const Color(0xFF2A2A40),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? color : const Color(0xFF6C7A9C),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Pretty-prints a descriptor toMap() result as indented JSON.
class _JsonView extends StatelessWidget {
  const _JsonView({required this.map});
  final Map<String, Object?> map;

  @override
  Widget build(BuildContext context) {
    final encoder = const JsonEncoder.withIndent('  ');
    final json = encoder.convert(map);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: SelectableText(
        json,
        style: const TextStyle(
          color: Color(0xFF9EFFA7),
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.6,
        ),
      ),
    );
  }
}

/// Validates that fromMap(toMap()) round-trips correctly.
class _RoundTripValidator extends StatelessWidget {
  const _RoundTripValidator({
    required this.clipA,
    required this.clipB,
    required this.transition,
  });

  final VGClipDescriptor clipA;
  final VGClipDescriptor clipB;
  final VGTransitionDescriptor transition;

  @override
  Widget build(BuildContext context) {
    // Validate round-trip: toMap → fromMap → equality.
    final clipARestored = VGClipDescriptor.fromMap(
      clipA.toMap().cast<Object?, Object?>(),
    );
    final clipBRestored = VGClipDescriptor.fromMap(
      clipB.toMap().cast<Object?, Object?>(),
    );
    final trRestored = VGTransitionDescriptor.fromMap(
      transition.toMap().cast<Object?, Object?>(),
    );

    final clipAOk = clipARestored == clipA;
    final clipBOk = clipBRestored == clipB;
    final trOk = trRestored == transition;
    final allOk = clipAOk && clipBOk && trOk;

    return Container(
      decoration: BoxDecoration(
        color: allOk
            ? const Color(0xFF00FF88).withValues(alpha: 0.12)
            : const Color(0xFFFF4444).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: allOk ? const Color(0xFF00D4AA) : Colors.red,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                allOk ? Icons.check_circle_outline : Icons.error_outline,
                color: allOk ? const Color(0xFF00D4AA) : Colors.red,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                allOk
                    ? 'Round-trip validation PASSED'
                    : 'Round-trip validation FAILED',
                style: TextStyle(
                  color: allOk ? const Color(0xFF00D4AA) : Colors.red,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _RtRow('Clip A toMap → fromMap == clipA', clipAOk),
          _RtRow('Clip B toMap → fromMap == clipB', clipBOk),
          _RtRow('Transition toMap → fromMap == transition', trOk),
        ],
      ),
    );
  }
}

class _RtRow extends StatelessWidget {
  const _RtRow(this.label, this.ok);
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check : Icons.close,
            size: 12,
            color: ok ? const Color(0xFF00D4AA) : Colors.red,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: ok ? Colors.white70 : Colors.red,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
