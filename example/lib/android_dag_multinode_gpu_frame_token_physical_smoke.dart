// android_dag_multinode_gpu_frame_token_physical_smoke.dart
// Vanguard Media Engine -- P1-DAG-MULTINODE-GPU-FRAME-TOKEN-CONTRACT
// Physical smoke test for platform-neutral, non-owning GPU frame token identity/binding contract.
// Diagnostic-only: no cameras, no Surface/TextureRegistry allocation, no rendering, no GPU transport, no product/editor/app wiring.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_dag_multinode_gpu_frame_token_smoke.dart';

void main() {
  runApp(const AndroidDagMultinodeGpuFrameTokenPhysicalSmokeApp());
}

class AndroidDagMultinodeGpuFrameTokenPhysicalSmokeApp extends StatefulWidget {
  const AndroidDagMultinodeGpuFrameTokenPhysicalSmokeApp({super.key});

  @override
  State<AndroidDagMultinodeGpuFrameTokenPhysicalSmokeApp> createState() =>
      _AndroidDagMultinodeGpuFrameTokenPhysicalSmokeAppState();
}

class _AndroidDagMultinodeGpuFrameTokenPhysicalSmokeAppState
    extends State<AndroidDagMultinodeGpuFrameTokenPhysicalSmokeApp> {
  String _status = 'Running DagMultinodeGpuFrameToken physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kDagMultinodeGpuFrameTokenStartMarker);

    VGDagMultinodeGpuFrameTokenSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGDagMultinodeGpuFrameTokenSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGDagMultinodeGpuFrameTokenSmokeRunner',
      'slice': 'P1-DAG-MULTINODE-GPU-FRAME-TOKEN-CONTRACT',
      'proofBoundary': kDagMultinodeGpuFrameTokenProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kDagMultinodeGpuFrameTokenJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kDagMultinodeGpuFrameTokenPassMarker
          : kDagMultinodeGpuFrameTokenFailMarker,
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
