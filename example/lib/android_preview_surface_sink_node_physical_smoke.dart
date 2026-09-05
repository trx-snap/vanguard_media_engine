// android_preview_surface_sink_node_physical_smoke.dart
// Vanguard Media Engine -- P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE
// Physical smoke test for platform-neutral PreviewSurfaceSinkNode logical DAG sink.
// Diagnostic-only: no cameras, no Surface/TextureRegistry allocation, no rendering, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_preview_surface_sink_node_smoke.dart';

void main() {
  runApp(const AndroidPreviewSurfaceSinkNodePhysicalSmokeApp());
}

class AndroidPreviewSurfaceSinkNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidPreviewSurfaceSinkNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidPreviewSurfaceSinkNodePhysicalSmokeApp> createState() =>
      _AndroidPreviewSurfaceSinkNodePhysicalSmokeAppState();
}

class _AndroidPreviewSurfaceSinkNodePhysicalSmokeAppState
    extends State<AndroidPreviewSurfaceSinkNodePhysicalSmokeApp> {
  String _status = 'Running PreviewSurfaceSinkNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kPreviewSurfaceSinkNodeStartMarker);

    VGPreviewSurfaceSinkNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGPreviewSurfaceSinkNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGPreviewSurfaceSinkNodeSmokeRunner',
      'slice': 'P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE',
      'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kPreviewSurfaceSinkNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kPreviewSurfaceSinkNodePassMarker
          : kPreviewSurfaceSinkNodeFailMarker,
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
