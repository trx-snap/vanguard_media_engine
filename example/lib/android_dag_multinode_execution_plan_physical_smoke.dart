// example/lib/android_dag_multinode_execution_plan_physical_smoke.dart
//
// P1-DAG-MULTINODE-CORE-EXEC-PLAN: physical-device smoke entry point for the
// bounded engine-only GraphExecutionPlanner diagnostic
// (runAndroidDagPhase1DagMultinodeExecutionPlanSmoke). Invokes the
// MethodChannel route, validates pass==true and that the raw native result
// carries the diagnostic-only proof boundary/non-claims, prints the required
// markers, and exits 0/1.
//
// Diagnostic-only: no production timeline playback, no product/editor/app/
// ConnectsApp wiring, no SurfaceProducer production path.
//
// Run with: flutter run -t example/lib/android_dag_multinode_execution_plan_physical_smoke.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

const List<String> _kExpectedProofBoundaryTokens = <String>[
  'diagnostic_only_engine_execution_plan',
  'no_production_timeline_playback',
  'no_product_editor_app_connectsapp_wiring',
  'no_surfaceproducer_production_path',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ExecutionPlanSmokeApp());
}

class _ExecutionPlanSmokeApp extends StatefulWidget {
  const _ExecutionPlanSmokeApp();

  @override
  State<_ExecutionPlanSmokeApp> createState() => _ExecutionPlanSmokeAppState();
}

class _ExecutionPlanSmokeAppState extends State<_ExecutionPlanSmokeApp> {
  String _status = 'Running...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'runAndroidDagPhase1DagMultinodeExecutionPlanSmoke',
      );

      final pass = result?['pass'] == true;
      final raw = (result?['raw'] as String?) ?? '';
      final proofBoundary = (result?['proofBoundary'] as String?) ?? '';
      final totalLanes = result?['totalLanes'];
      final passedLanes = result?['passedLanes'];

      final boundaryOk = _kExpectedProofBoundaryTokens.every(
        (token) => raw.contains(token),
      );
      final overallPass = pass && boundaryOk;

      final escapedRaw = raw.replaceAll('\\', r'\\').replaceAll('"', r'\"');
      final escapedBoundary = proofBoundary
          .replaceAll('\\', r'\\')
          .replaceAll('"', r'\"');
      final json =
          '{"pass":$pass,"boundaryOk":$boundaryOk,'
          '"totalLanes":$totalLanes,"passedLanes":$passedLanes,'
          '"proofBoundary":"$escapedBoundary","raw":"$escapedRaw"}';

      // ignore: avoid_print
      print('ANDROID_DAG_PHASE1_DAG_MULTINODE_EXEC_PLAN_JSON:$json');

      setState(() => _status = overallPass ? 'PASS' : 'FAIL');

      if (overallPass) {
        // ignore: avoid_print
        print('ANDROID_DAG_PHASE1_DAG_MULTINODE_EXEC_PLAN_PHYSICAL_SMOKE_PASS');
        exit(0);
      } else {
        // ignore: avoid_print
        print('ANDROID_DAG_PHASE1_DAG_MULTINODE_EXEC_PLAN_PHYSICAL_SMOKE_FAIL');
        exit(1);
      }
    } catch (e) {
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXEC_PLAN_JSON:'
        '{"error":"${e.toString().replaceAll('"', r'\"')}"}',
      );
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE1_DAG_MULTINODE_EXEC_PLAN_PHYSICAL_SMOKE_FAIL');
      setState(() => _status = 'FAIL: $e');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'P1-DAG-MULTINODE-CORE-EXEC-PLAN smoke: $_status',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      ),
    );
  }
}
