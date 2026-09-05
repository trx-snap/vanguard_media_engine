// android_dag_multinode_topology_composition_physical_smoke.dart
// Vanguard Media Engine -- P1-DAG-MULTINODE-TOPOLOGY-COMPOSITION
// Physical smoke test for real-node multinode DAG topology composition.
// Diagnostic-only: no cameras, no Surface/TextureRegistry allocation, no rendering, no GPU transport, no product/editor/app wiring.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_dag_multinode_topology_composition_smoke.dart';

void main() {
  runApp(const AndroidDagMultinodeTopologyCompositionPhysicalSmokeApp());
}

class AndroidDagMultinodeTopologyCompositionPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDagMultinodeTopologyCompositionPhysicalSmokeApp({super.key});

  @override
  State<AndroidDagMultinodeTopologyCompositionPhysicalSmokeApp> createState() =>
      _AndroidDagMultinodeTopologyCompositionPhysicalSmokeAppState();
}

class _AndroidDagMultinodeTopologyCompositionPhysicalSmokeAppState
    extends State<AndroidDagMultinodeTopologyCompositionPhysicalSmokeApp> {
  String _status = 'Running DagMultinodeTopologyComposition physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kDagMultinodeTopologyCompositionStartMarker);

    VGDagMultinodeTopologyCompositionSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGDagMultinodeTopologyCompositionSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGDagMultinodeTopologyCompositionSmokeRunner',
      'slice': 'P1-DAG-MULTINODE-TOPOLOGY-COMPOSITION',
      'proofBoundary': kDagMultinodeTopologyCompositionProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kDagMultinodeTopologyCompositionJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kDagMultinodeTopologyCompositionPassMarker
          : kDagMultinodeTopologyCompositionFailMarker,
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
