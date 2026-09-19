// android_dual_camera_stream_test.dart
// Vanguard Media Engine — Android Dual Camera Test Harness
//
// Demonstrates:
// 1. Native Engine Dual Camera Discovery & Hardware Probing (VGCameraSession)
// 2. Full HD 1080x1920 Concurrent Streaming via Vanguard Engine
// 3. User-selectable Grid Options:
//    - H Split (Horizontal 50/50, aspect-ratio preserved)
//    - V Split (Vertical 50/50, aspect-ratio preserved)
//    - PiP (120Hz Free-Floating Picture-in-Picture)

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    title: 'Vanguard Dual Camera',
    debugShowCheckedModeBanner: false,
    home: AndroidDualCameraStreamTestScreen(),
  ));
}

class AndroidDualCameraStreamTestScreen extends StatefulWidget {
  const AndroidDualCameraStreamTestScreen({super.key});

  @override
  State<AndroidDualCameraStreamTestScreen> createState() =>
      _AndroidDualCameraStreamTestScreenState();
}

class _AndroidDualCameraStreamTestScreenState
    extends State<AndroidDualCameraStreamTestScreen> {
  // Grid layout options
  VGDualCameraGridOption _gridOption = VGDualCameraGridOption.pip;
  bool _isFrontPrimary = false;

  // Controllers
  final TextEditingController _frontIdController =
      TextEditingController(text: '1');
  final TextEditingController _backIdController =
      TextEditingController(text: '0');

  // Engine MultiCam Session State
  VGMultiCamRenderTextureSession? _session;
  bool _isRunning = false;
  bool _isStarting = false;
  String _statusMessage = 'Engine Ready — Probing hardware...';
  final List<String> _logs = [];

  // Discovery & Probe Data
  bool? _halAdvertisedConcurrent;
  List<Map<String, String>> _candidatePairs = [];
  final Map<String, bool> _probedPairResults = {};
  bool _isProbingPairs = false;

  @override
  void initState() {
    super.initState();
    _log('Initializing Engine Dual Camera Test Harness...');
    _probeHardwareSupport();
    _discoverCameraPairs();
  }

  @override
  void dispose() {
    if (_isRunning) {
      _stopDualCamera(silent: true);
    }
    _frontIdController.dispose();
    _backIdController.dispose();
    super.dispose();
  }

  void _log(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    final entry = '[$time] $message';
    // ignore: avoid_print
    print('[DualCamEngine] $entry');
    if (mounted) {
      setState(() {
        _logs.insert(0, entry);
        if (_logs.length > 60) _logs.removeLast();
      });
    }
  }

  Future<void> _probeHardwareSupport() async {
    try {
      final supported = await VGCameraSession.isMultiCamSupported();
      if (mounted) {
        setState(() {
          _halAdvertisedConcurrent = supported;
        });
      }
      _log('HAL concurrentCameraIds advertised: $supported');
    } catch (e) {
      _log('Hardware probe error: $e');
    }
  }

  Future<void> _discoverCameraPairs() async {
    try {
      final result = await VGCameraSession.discoverDualCameraPairs();
      if (result != null && mounted) {
        final rawPairs = result['candidatePairs'] as List<Object?>? ?? [];
        final parsedPairs = <Map<String, String>>[];
        for (final p in rawPairs) {
          if (p is Map) {
            parsedPairs.add({
              'frontId': p['frontId']?.toString() ?? '1',
              'backId': p['backId']?.toString() ?? '0',
            });
          }
        }

        final recFront = result['recommendedFrontId']?.toString() ?? '1';
        final recBack = result['recommendedBackId']?.toString() ?? '0';

        setState(() {
          _candidatePairs = parsedPairs;
          if (_frontIdController.text.isEmpty) {
            _frontIdController.text = recFront;
          }
          if (_backIdController.text.isEmpty) {
            _backIdController.text = recBack;
          }
        });

        _log(
          'Discovered ${result['allCameraIds']} cameras. Candidate pairs: ${parsedPairs.map((e) => "${e['frontId']}+${e['backId']}").toList()}',
        );

        _probeAllPairs();
      }
    } catch (e) {
      _log('Camera pair discovery error: $e');
    }
  }

  Future<void> _probeAllPairs() async {
    if (_candidatePairs.isEmpty || _isProbingPairs || _isRunning) return;
    setState(() => _isProbingPairs = true);
    _log('Probing ${_candidatePairs.length} candidate pairs on hardware...');

    String? firstWorkingFront;
    String? firstWorkingBack;

    for (final pair in _candidatePairs) {
      final f = pair['frontId']!;
      final b = pair['backId']!;
      final key = '$f+$b';
      try {
        final res = await VGCameraSession.probeDualCameraPair(
          frontDeviceId: f,
          backDeviceId: b,
        );
        final supported = res?['supported'] == true;
        if (mounted) {
          setState(() {
            _probedPairResults[key] = supported;
          });
        }
        if (supported) {
          _log('PROBE SUCCESS: Pair Front=$f + Back=$b is HARDWARE SUPPORTED!');
          firstWorkingFront ??= f;
          firstWorkingBack ??= b;
        } else {
          final err = res?['error'] ?? 'hardware rejected';
          _log('PROBE REJECTED: Pair Front=$f + Back=$b -> $err');
        }
      } catch (e) {
        _log('PROBE EXCEPTION on $key: $e');
        if (mounted) {
          setState(() {
            _probedPairResults[key] = false;
          });
        }
      }
    }

    if (mounted) {
      setState(() {
        _isProbingPairs = false;
        if (firstWorkingFront != null && firstWorkingBack != null) {
          _frontIdController.text = firstWorkingFront;
          _backIdController.text = firstWorkingBack;
          _log('Auto-selected verified pair: Front=$firstWorkingFront + Back=$firstWorkingBack');
        }
      });
    }
  }

  Future<void> _startDualCamera() async {
    if (_isRunning || _isStarting) return;

    final frontId = _frontIdController.text.trim();
    final backId = _backIdController.text.trim();

    if (frontId.isEmpty || backId.isEmpty) {
      _log('ERROR: frontDeviceId and backDeviceId must be specified.');
      return;
    }

    setState(() {
      _isStarting = true;
      _statusMessage = 'Engine starting dual camera (Front=$frontId, Back=$backId)...';
    });

    try {
      _log('Invoking VGCameraSession.startMultiCamPreview(front="$frontId", back="$backId", 1080x1920)...');
      final session = await VGCameraSession.startMultiCamPreview(
        frontDeviceId: frontId,
        backDeviceId: backId,
        width: 1080,
        height: 1920,
      );

      if (session != null) {
        setState(() {
          _session = session;
          _isRunning = true;
          _isStarting = false;
          _statusMessage = 'STREAMING — Front #${session.textureId}, Back #${session.backTextureId}';
        });
        _log('SUCCESS: Dual preview streaming via engine! Front: #${session.textureId}, Back: #${session.backTextureId} (1080x1920 Full HD)');
      } else {
        setState(() {
          _isStarting = false;
          _statusMessage = 'Engine returned null session';
        });
        _log('ERROR: startMultiCamPreview returned null.');
      }
    } on PlatformException catch (pe) {
      setState(() {
        _isStarting = false;
        _isRunning = false;
        _statusMessage = 'PlatformException: [${pe.code}] ${pe.message}';
      });
      _log('PLATFORM ERROR: code=${pe.code}, msg=${pe.message}');
    } catch (e, st) {
      setState(() {
        _isStarting = false;
        _isRunning = false;
        _statusMessage = 'Unexpected Error: $e';
      });
      _log('EXCEPTION: $e\n$st');
    }
  }

  Future<void> _stopDualCamera({bool silent = false}) async {
    if (!silent) _log('Stopping dual camera via engine...');
    try {
      await VGCameraSession.stopMultiCamPreview();
      if (mounted) {
        setState(() {
          _isRunning = false;
          _isStarting = false;
          _session = null;
          _statusMessage = 'Stopped — Dual camera resources released';
        });
      }
      if (!silent) _log('Dual camera stopped cleanly.');
    } catch (e) {
      if (!silent) _log('Stop exception: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF0F1015),
      appBar: AppBar(
        backgroundColor: const Color(0xFF171822),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.camera_rounded, color: Color(0xFF6C63FF), size: 24),
            SizedBox(width: 8),
            Text(
              'Vanguard Dual Camera',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Re-probe cameras',
            onPressed: () {
              _probeHardwareSupport();
              _discoverCameraPairs();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            final isLandscape = orientation == Orientation.landscape;

            final preview = Container(
              margin: EdgeInsets.fromLTRB(12, isLandscape ? 6 : 12, 12, 6),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isRunning
                      ? const Color(0xFF00D4AA).withValues(alpha: 0.7)
                      : Colors.white12,
                  width: _isRunning ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: _buildCameraViewport(),
            );

            final controls = Container(
              margin: EdgeInsets.fromLTRB(
                isLandscape ? 6 : 12,
                6,
                12,
                isLandscape ? 6 : 12,
              ),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF171822),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStatusBar(),
                  const SizedBox(height: 8),

                  // Three Grid Options (H Split, V Split, PiP)
                  _buildGridOptionsSelector(),
                  const SizedBox(height: 8),

                  // Candidate Pair Chips
                  if (_candidatePairs.isNotEmpty && !_isRunning) ...[
                    _buildCandidatePairsSelector(),
                    const SizedBox(height: 8),
                  ],

                  // Camera ID inputs and Start/Stop Actions
                  _buildActionControls(),
                  const SizedBox(height: 8),

                  // Live Event Logs
                  Expanded(child: _buildLogsConsole()),
                ],
              ),
            );

            if (isLandscape) {
              return Row(
                children: [
                  Expanded(flex: 6, child: preview),
                  Expanded(flex: 5, child: controls),
                ],
              );
            }

            return Column(
              children: [
                Expanded(flex: 5, child: preview),
                Expanded(flex: 6, child: controls),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCameraViewport() {
    if (!_isRunning || _session == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isStarting ? Icons.hourglass_top_rounded : Icons.videocam_outlined,
              size: 48,
              color: _isStarting ? const Color(0xFF00D4AA) : Colors.white24,
            ),
            const SizedBox(height: 12),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isStarting ? const Color(0xFF00D4AA) : Colors.white54,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    return VGDualCameraPreview(
      session: _session!,
      gridOption: _gridOption,
      isFrontPrimary: _isFrontPrimary,
      onSwapCameras: () {
        setState(() => _isFrontPrimary = !_isFrontPrimary);
        _log('Swapped primary/secondary camera positions');
      },
    );
  }

  Widget _buildStatusBar() {
    final halText = _halAdvertisedConcurrent == true
        ? 'HAL Concurrent: YES'
        : _halAdvertisedConcurrent == false
            ? 'HAL: Generic Camera2'
            : 'HAL: Checking...';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isRunning
                  ? const Color(0xFF00D4AA)
                  : (_isStarting ? Colors.orange : Colors.grey),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF6C63FF).withValues(alpha: 0.5)),
            ),
            child: Text(
              halText,
              style: const TextStyle(fontSize: 10, color: Color(0xFFA5A0FF), fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridOptionsSelector() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildGridOptionButton(
              mode: VGDualCameraGridOption.splitH,
              label: 'H Split',
              icon: Icons.table_rows_rounded,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _buildGridOptionButton(
              mode: VGDualCameraGridOption.splitV,
              label: 'V Split',
              icon: Icons.view_column_rounded,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _buildGridOptionButton(
              mode: VGDualCameraGridOption.pip,
              label: 'PiP',
              icon: Icons.picture_in_picture_alt_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridOptionButton({
    required VGDualCameraGridOption mode,
    required String label,
    required IconData icon,
  }) {
    final selected = _gridOption == mode;
    return InkWell(
      onTap: () {
        setState(() => _gridOption = mode);
        _log('Selected Grid Option: $label');
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF6C63FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: selected ? Colors.white : Colors.white60),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCandidatePairsSelector() {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _candidatePairs.length,
        separatorBuilder: (context, index) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final pair = _candidatePairs[index];
          final f = pair['frontId']!;
          final b = pair['backId']!;
          final key = '$f+$b';
          final isSelected = _frontIdController.text == f && _backIdController.text == b;
          final isSupported = _probedPairResults[key];

          Color chipBorder = Colors.white24;
          if (isSupported == true) {
            chipBorder = const Color(0xFF00D4AA);
          } else if (isSupported == false) {
            chipBorder = Colors.redAccent.withValues(alpha: 0.6);
          }

          return InkWell(
            onTap: () {
              setState(() {
                _frontIdController.text = f;
                _backIdController.text = b;
              });
              _log('Selected candidate pair: Front=$f, Back=$b');
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF6C63FF).withValues(alpha: 0.4) : Colors.black26,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: chipBorder, width: isSelected ? 1.5 : 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isSupported == true
                        ? Icons.check_circle
                        : (isSupported == false ? Icons.cancel : Icons.help_outline),
                    size: 13,
                    color: isSupported == true
                        ? const Color(0xFF00D4AA)
                        : (isSupported == false ? Colors.redAccent : Colors.white38),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'F:$f + B:$b',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? Colors.white : Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionControls() {
    return Row(
      children: [
        // Front ID Field
        Expanded(
          flex: 2,
          child: TextField(
            controller: _frontIdController,
            enabled: !_isRunning && !_isStarting,
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Front ID',
              labelStyle: const TextStyle(fontSize: 10, color: Colors.white54),
              filled: true,
              fillColor: Colors.black26,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Back ID Field
        Expanded(
          flex: 2,
          child: TextField(
            controller: _backIdController,
            enabled: !_isRunning && !_isStarting,
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Back ID',
              labelStyle: const TextStyle(fontSize: 10, color: Colors.white54),
              filled: true,
              fillColor: Colors.black26,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Swap Cameras Button
        IconButton(
          onPressed: _isRunning ? () => setState(() => _isFrontPrimary = !_isFrontPrimary) : null,
          icon: const Icon(Icons.swap_vert_rounded, size: 22),
          tooltip: 'Swap Primary Camera',
          color: const Color(0xFF00D4AA),
        ),
        const SizedBox(width: 4),

        // Start / Stop Button
        Expanded(
          flex: 3,
          child: ElevatedButton.icon(
            onPressed: _isStarting
                ? null
                : (_isRunning ? _stopDualCamera : _startDualCamera),
            style: ElevatedButton.styleFrom(
              backgroundColor: _isRunning ? Colors.redAccent.shade700 : const Color(0xFF6C63FF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: Icon(
              _isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 18,
            ),
            label: Text(
              _isRunning ? 'Stop' : 'Start Preview',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogsConsole() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: ListView.builder(
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          Color logColor = Colors.white60;
          if (log.contains('SUCCESS')) {
            logColor = const Color(0xFF00D4AA);
          } else if (log.contains('ERROR') || log.contains('REJECTED')) {
            logColor = Colors.redAccent;
          } else if (log.contains('Invoking')) {
            logColor = const Color(0xFFA5A0FF);
          }
          return Text(
            log,
            style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: logColor),
          );
        },
      ),
    );
  }
}
