// android_hardware_buffer_source_node_physical_smoke.dart
// Vanguard Media Engine -- P1-DAG-MULTINODE-HARDWARE-BUFFER-SOURCE-NODE
// Physical smoke test for platform-neutral HardwareBufferSourceNode logical DAG source.
// Diagnostic-only: no cameras, no HardwareBuffer allocation, no rendering, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_hardware_buffer_source_node_smoke.dart';

void main() {
  runApp(const AndroidHardwareBufferSourceNodePhysicalSmokeApp());
}

class AndroidHardwareBufferSourceNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidHardwareBufferSourceNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidHardwareBufferSourceNodePhysicalSmokeApp> createState() =>
      _AndroidHardwareBufferSourceNodePhysicalSmokeAppState();
}

class _AndroidHardwareBufferSourceNodePhysicalSmokeAppState
    extends State<AndroidHardwareBufferSourceNodePhysicalSmokeApp> {
  String _status = 'Running HardwareBufferSourceNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kHardwareBufferSourceNodeStartMarker);

    VGHardwareBufferSourceNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGHardwareBufferSourceNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGHardwareBufferSourceNodeSmokeRunner',
      'slice': 'P1-DAG-MULTINODE-HARDWARE-BUFFER-SOURCE-NODE',
      'proofBoundary': kHardwareBufferSourceNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kHardwareBufferSourceNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kHardwareBufferSourceNodePassMarker
          : kHardwareBufferSourceNodeFailMarker,
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
