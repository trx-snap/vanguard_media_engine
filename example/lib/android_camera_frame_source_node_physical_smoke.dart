// android_camera_frame_source_node_physical_smoke.dart
// Vanguard Media Engine -- P3-CAMERA-FRAME-SOURCE-NODE-A
// Physical smoke test for platform-neutral CameraFrameSourceNode logical
// DAG source. Diagnostic-only: no Camera2/NDK capture session, no hardware
// buffer ownership, no rendering, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_camera_frame_source_node_smoke.dart';

void main() {
  runApp(const AndroidCameraFrameSourceNodePhysicalSmokeApp());
}

class AndroidCameraFrameSourceNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidCameraFrameSourceNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidCameraFrameSourceNodePhysicalSmokeApp> createState() =>
      _AndroidCameraFrameSourceNodePhysicalSmokeAppState();
}

class _AndroidCameraFrameSourceNodePhysicalSmokeAppState
    extends State<AndroidCameraFrameSourceNodePhysicalSmokeApp> {
  String _status = 'Running CameraFrameSourceNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kCameraFrameSourceNodeStartMarker);

    VGCameraFrameSourceNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGCameraFrameSourceNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGCameraFrameSourceNodeSmokeRunner',
      'slice': 'P3-CAMERA-FRAME-SOURCE-NODE-A',
      'proofBoundary': kCameraFrameSourceNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kCameraFrameSourceNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kCameraFrameSourceNodePassMarker
          : kCameraFrameSourceNodeFailMarker,
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
