// android_filter_node_physical_smoke.dart
// Vanguard Media Engine -- P5-FILTER-NODE-A
// Physical smoke test for platform-neutral FilterNode logical DAG
// processing node. Diagnostic-only: no renderer, shader, texture, decoder,
// Android lifecycle, or GPU object ownership, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_filter_node_smoke.dart';

void main() {
  runApp(const AndroidFilterNodePhysicalSmokeApp());
}

class AndroidFilterNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidFilterNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidFilterNodePhysicalSmokeApp> createState() =>
      _AndroidFilterNodePhysicalSmokeAppState();
}

class _AndroidFilterNodePhysicalSmokeAppState
    extends State<AndroidFilterNodePhysicalSmokeApp> {
  String _status = 'Running FilterNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kFilterNodeStartMarker);

    VGFilterNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGFilterNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGFilterNodeSmokeRunner',
      'slice': 'P5-FILTER-NODE-A',
      'proofBoundary': kFilterNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kFilterNodeJsonPrefix${jsonEncode(payload)}');
    print(pass ? kFilterNodePassMarker : kFilterNodeFailMarker);

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
