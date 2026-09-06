// android_graphic_overlay_compositor_node_physical_smoke.dart
// Vanguard Media Engine -- P5-GRAPHIC-OVERLAY-COMPOSITOR-NODE-A
// Physical smoke test for platform-neutral GraphicOverlayCompositorNode
// logical DAG compositor node. Diagnostic-only: no renderer, PNG decoder,
// text rasterizer, shader, texture, decoder, Android lifecycle, or GPU
// object ownership, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_graphic_overlay_compositor_node_smoke.dart';

void main() {
  runApp(const AndroidGraphicOverlayCompositorNodePhysicalSmokeApp());
}

class AndroidGraphicOverlayCompositorNodePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidGraphicOverlayCompositorNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidGraphicOverlayCompositorNodePhysicalSmokeApp> createState() =>
      _AndroidGraphicOverlayCompositorNodePhysicalSmokeAppState();
}

class _AndroidGraphicOverlayCompositorNodePhysicalSmokeAppState
    extends State<AndroidGraphicOverlayCompositorNodePhysicalSmokeApp> {
  String _status = 'Running GraphicOverlayCompositorNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kGraphicOverlayCompositorNodeStartMarker);

    VGGraphicOverlayCompositorNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGGraphicOverlayCompositorNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGGraphicOverlayCompositorNodeSmokeRunner',
      'slice': 'P5-GRAPHIC-OVERLAY-COMPOSITOR-NODE-A',
      'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kGraphicOverlayCompositorNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kGraphicOverlayCompositorNodePassMarker
          : kGraphicOverlayCompositorNodeFailMarker,
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: $topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
