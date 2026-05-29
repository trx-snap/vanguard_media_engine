// vanguard_timeline_execution_playground.dart
// Vanguard Media Engine — Phase 7 Stage 7.5B
//
// Package example app playground for timeline compositor execution proof.
//
// PURPOSE:
//   Triggers the native VGTimelineCompositorSmokeTest and displays results
//   in a terminal-style log console. This is an example-only debug tool.
//   No ConnectsApp dependency. No production usage.
//
// WHAT THIS VALIDATES (Stage 7.5B):
//   - VGTimelineCompositorNode end-to-end execution pipeline.
//   - VGEditorGraphFactory descriptor construction.
//   - VGGraphValidator self-sourcing compositor acceptance.
//   - Frame pull, clip sequencing, EOS detection, seek/generation handling.
//
// WHAT THIS DOES NOT DO:
//   - No Metal rendering or GPU display.
//   - No audio decoding.
//   - No ConnectsApp integration.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry widget
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 7 Stage 7.5B — Timeline execution proof playground.
///
/// Use `Navigator.push(context, MaterialPageRoute(builder: (_) => const VanguardTimelineExecutionPlayground()))`.
class VanguardTimelineExecutionPlayground extends StatefulWidget {
  const VanguardTimelineExecutionPlayground({super.key});

  @override
  State<VanguardTimelineExecutionPlayground> createState() =>
      _VanguardTimelineExecutionPlaygroundState();
}

class _VanguardTimelineExecutionPlaygroundState
    extends State<VanguardTimelineExecutionPlayground> {
  static const _channel = MethodChannel('vanguard_media_engine');

  // ── State ─────────────────────────────────────────────────────────────────
  bool _running = false;
  bool _completed = false;
  bool? _overallSuccess;
  List<_StepResult> _steps = [];
  List<String> _logs = [];
  String? _error;

  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ── Run the test ──────────────────────────────────────────────────────────

  Future<void> _runExecutionProof() async {
    setState(() {
      _running = true;
      _completed = false;
      _overallSuccess = null;
      _steps = [];
      _logs = [];
      _error = null;
    });

    try {
      // Use synthetic videos (pass nil paths → native generates them).
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'dev_proveTimelineExecution',
        <String, dynamic>{},
      );

      if (result == null) {
        setState(() {
          _running = false;
          _completed = true;
          _overallSuccess = false;
          _error = 'Native returned null';
          _logs = ['Error: Native returned null result'];
        });
        return;
      }

      final success = result['success'] as bool? ?? false;
      final rawSteps = result['steps'] as List<dynamic>? ?? [];
      final rawLogs = result['logs'] as List<dynamic>? ?? [];
      final error = result['error'] as String?;

      final steps = rawSteps.map((s) {
        final map = s as Map<dynamic, dynamic>;
        return _StepResult(
          name: map['name'] as String? ?? '',
          passed: map['passed'] as bool? ?? false,
          detail: map['detail'] as String? ?? '',
        );
      }).toList();

      setState(() {
        _running = false;
        _completed = true;
        _overallSuccess = success;
        _steps = steps;
        _logs = rawLogs.map((l) => l.toString()).toList();
        _error = error;
      });

      // Scroll to bottom after results arrive.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } on PlatformException catch (e) {
      setState(() {
        _running = false;
        _completed = true;
        _overallSuccess = false;
        _error = '${e.code}: ${e.message}';
        _logs = ['PlatformException: ${e.code} — ${e.message}'];
      });
    } catch (e) {
      setState(() {
        _running = false;
        _completed = true;
        _overallSuccess = false;
        _error = e.toString();
        _logs = ['Exception: $e'];
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: const Text(
          'Timeline Execution Proof',
          style: TextStyle(
            color: Color(0xFFC9D1D9),
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFFC9D1D9)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              'Phase 7 · Stage 7.5B · VGTimelineCompositorNode',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // ── Status bar ──────────────────────────────────────────────────
          _buildStatusBar(),

          // ── Step results ────────────────────────────────────────────────
          if (_steps.isNotEmpty) _buildStepResults(),

          // ── Log console ────────────────────────────────────────────────
          Expanded(child: _buildLogConsole()),

          // ── Action bar ─────────────────────────────────────────────────
          _buildActionBar(),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (_running) {
      statusColor = const Color(0xFFF0883E);
      statusText = 'Running execution proof...';
      statusIcon = Icons.hourglass_top;
    } else if (!_completed) {
      statusColor = const Color(0xFF8B949E);
      statusText = 'Ready — tap "Run" to start';
      statusIcon = Icons.play_circle_outline;
    } else if (_overallSuccess == true) {
      statusColor = const Color(0xFF3FB950);
      statusText = 'ALL STEPS PASSED';
      statusIcon = Icons.check_circle;
    } else {
      statusColor = const Color(0xFFF85149);
      statusText = 'FAILED: ${_error ?? "Unknown error"}';
      statusIcon = Icons.error;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.1),
        border: Border(bottom: BorderSide(color: statusColor.withValues(alpha: 0.3))),
      ),
      child: Row(
        children: [
          if (_running)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: statusColor,
              ),
            )
          else
            Icon(statusIcon, size: 16, color: statusColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                color: statusColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_completed && _steps.isNotEmpty)
            Text(
              '${_steps.where((s) => s.passed).length}/${_steps.length}',
              style: TextStyle(
                color: statusColor,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStepResults() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _steps.length,
        itemBuilder: (context, index) {
          final step = _steps[index];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  step.passed ? '✅' : '❌',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.name,
                        style: TextStyle(
                          color: step.passed
                              ? const Color(0xFFC9D1D9)
                              : const Color(0xFFF85149),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (step.detail.isNotEmpty)
                        Text(
                          step.detail,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildLogConsole() {
    if (_logs.isEmpty && !_running) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal,
              size: 48,
              color: Colors.white.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 12),
            Text(
              'Console output will appear here',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25),
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF010409),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Console title bar.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF161B22),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(7),
                topRight: Radius.circular(7),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _running
                        ? const Color(0xFFF0883E)
                        : (_overallSuccess == true
                            ? const Color(0xFF3FB950)
                            : const Color(0xFFF85149)),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'vanguard_smoke_test',
                  style: TextStyle(
                    color: Color(0xFF8B949E),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          // Log lines.
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(10),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final line = _logs[index];
                Color lineColor;
                if (line.contains('✅')) {
                  lineColor = const Color(0xFF3FB950);
                } else if (line.contains('❌')) {
                  lineColor = const Color(0xFFF85149);
                } else if (line.contains('═') || line.contains('───')) {
                  lineColor = const Color(0xFF58A6FF);
                } else if (line.contains('ℹ️')) {
                  lineColor = const Color(0xFFF0883E);
                } else {
                  lineColor = const Color(0xFF8B949E);
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Text(
                    line,
                    style: TextStyle(
                      color: lineColor,
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(top: BorderSide(color: Color(0xFF30363D))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _running ? null : _runExecutionProof,
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_arrow, size: 20),
                label: Text(_running ? 'Running...' : 'Run Execution Proof'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _running
                      ? const Color(0xFF30363D)
                      : const Color(0xFF238636),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step result model
// ─────────────────────────────────────────────────────────────────────────────

class _StepResult {
  final String name;
  final bool passed;
  final String detail;

  const _StepResult({
    required this.name,
    required this.passed,
    required this.detail,
  });
}
