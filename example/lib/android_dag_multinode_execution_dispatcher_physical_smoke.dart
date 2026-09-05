// android_dag_multinode_execution_dispatcher_physical_smoke.dart
// Vanguard Media Engine -- P1-DAG-MULTINODE-EXECUTION-DISPATCHER
// Physical smoke test for platform-neutral DAG multinode execution dispatcher foundation.
// Diagnostic-only: no Node::execute, no OS/GPU resource ownership, no rendering, no GPU transport, no product/editor/app wiring.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_dag_multinode_execution_dispatcher_smoke.dart';

void main() {
  runApp(const AndroidDagMultinodeExecutionDispatcherPhysicalSmokeApp());
}

class AndroidDagMultinodeExecutionDispatcherPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDagMultinodeExecutionDispatcherPhysicalSmokeApp({super.key});

  @override
  State<AndroidDagMultinodeExecutionDispatcherPhysicalSmokeApp> createState() =>
      _AndroidDagMultinodeExecutionDispatcherPhysicalSmokeAppState();
}

class _AndroidDagMultinodeExecutionDispatcherPhysicalSmokeAppState
    extends State<AndroidDagMultinodeExecutionDispatcherPhysicalSmokeApp> {
  String _status = 'Running DagMultinodeExecutionDispatcher physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kDagMultinodeExecutionDispatcherStartMarker);

    VGDagMultinodeExecutionDispatcherSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGDagMultinodeExecutionDispatcherSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGDagMultinodeExecutionDispatcherSmokeRunner',
      'slice': 'P1-DAG-MULTINODE-EXECUTION-DISPATCHER',
      'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kDagMultinodeExecutionDispatcherJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kDagMultinodeExecutionDispatcherPassMarker
          : kDagMultinodeExecutionDispatcherFailMarker,
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
