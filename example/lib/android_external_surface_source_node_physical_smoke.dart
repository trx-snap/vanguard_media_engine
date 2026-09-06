// android_external_surface_source_node_physical_smoke.dart
// Vanguard Media Engine -- P1-EXTERNAL-SURFACE-SOURCE-NODE-A
// Physical smoke test for platform-neutral ExternalSurfaceSourceNode
// logical DAG source. Diagnostic-only: no Android Surface/SurfaceTexture/
// ANativeWindow/AHardwareBuffer/EGL/GLES/Vulkan/JNI resource ownership, no
// rendering, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_external_surface_source_node_smoke.dart';

void main() {
  runApp(const AndroidExternalSurfaceSourceNodePhysicalSmokeApp());
}

class AndroidExternalSurfaceSourceNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidExternalSurfaceSourceNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidExternalSurfaceSourceNodePhysicalSmokeApp> createState() =>
      _AndroidExternalSurfaceSourceNodePhysicalSmokeAppState();
}

class _AndroidExternalSurfaceSourceNodePhysicalSmokeAppState
    extends State<AndroidExternalSurfaceSourceNodePhysicalSmokeApp> {
  String _status = 'Running ExternalSurfaceSourceNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kExternalSurfaceSourceNodeStartMarker);

    VGExternalSurfaceSourceNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGExternalSurfaceSourceNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGExternalSurfaceSourceNodeSmokeRunner',
      'slice': 'P1-EXTERNAL-SURFACE-SOURCE-NODE-A',
      'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kExternalSurfaceSourceNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kExternalSurfaceSourceNodePassMarker
          : kExternalSurfaceSourceNodeFailMarker,
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
