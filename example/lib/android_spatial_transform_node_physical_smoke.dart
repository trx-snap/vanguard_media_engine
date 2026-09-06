// android_spatial_transform_node_physical_smoke.dart
// Vanguard Media Engine -- P5-SPATIAL-TRANSFORM-NODE-A
// Physical smoke test for platform-neutral SpatialTransformNode logical DAG
// processing node. Diagnostic-only: no renderer, shader, texture, decoder,
// Android lifecycle, or GPU object ownership, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_spatial_transform_node_smoke.dart';

void main() {
  runApp(const AndroidSpatialTransformNodePhysicalSmokeApp());
}

class AndroidSpatialTransformNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidSpatialTransformNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidSpatialTransformNodePhysicalSmokeApp> createState() =>
      _AndroidSpatialTransformNodePhysicalSmokeAppState();
}

class _AndroidSpatialTransformNodePhysicalSmokeAppState
    extends State<AndroidSpatialTransformNodePhysicalSmokeApp> {
  String _status = 'Running SpatialTransformNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kSpatialTransformNodeStartMarker);

    VGSpatialTransformNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGSpatialTransformNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGSpatialTransformNodeSmokeRunner',
      'slice': 'P5-SPATIAL-TRANSFORM-NODE-A',
      'proofBoundary': kSpatialTransformNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kSpatialTransformNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass ? kSpatialTransformNodePassMarker : kSpatialTransformNodeFailMarker,
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
