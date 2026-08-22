// Vanguard Android True-DAG Phase 4B2A: Deterministic playback state machine
// and timeline clock diagnostic smoke.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4B2AClockStateSmokeApp());
}

class AndroidDagPhase4B2AClockStateSmokeApp extends StatefulWidget {
  const AndroidDagPhase4B2AClockStateSmokeApp({super.key});

  @override
  State<AndroidDagPhase4B2AClockStateSmokeApp> createState() =>
      _AndroidDagPhase4B2AClockStateSmokeAppState();
}

class _AndroidDagPhase4B2AClockStateSmokeAppState
    extends State<AndroidDagPhase4B2AClockStateSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 4B2A clock & state smoke…';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    var pass = false;
    var raw = '';
    var invalidTransitionPass = false;
    var pausedPositionUs = -1;
    var resumedPositionUs = -1;
    var seekPositionUs = -1;
    final stateSequence = <String>[];

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4B2AClockStateSmoke',
      );
      final map = Map<String, dynamic>.from(response! as Map);
      pass = map['pass'] == true;
      raw = map['raw'] as String? ?? '';
      invalidTransitionPass = map['invalidTransitionPass'] == true;
      pausedPositionUs = (map['pausedPositionUs'] as num?)?.toInt() ?? -1;
      resumedPositionUs = (map['resumedPositionUs'] as num?)?.toInt() ?? -1;
      seekPositionUs = (map['seekPositionUs'] as num?)?.toInt() ?? -1;
      final seqList = map['stateSequence'] as List?;
      if (seqList != null) {
        stateSequence.addAll(seqList.map((e) => e.toString()));
      }
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2A_ERROR: $error\n$stack');
      pass = false;
      raw = 'status=FAIL;reason=dart_exception:$error';
    }

    final payload = <String, dynamic>{
      'pass': pass,
      'stateSequence': stateSequence,
      'invalidTransitionPass': invalidTransitionPass,
      'pausedPositionUs': pausedPositionUs,
      'resumedPositionUs': resumedPositionUs,
      'seekPositionUs': seekPositionUs,
      'raw': raw,
    };

    // ignore: avoid_print
    print('ANDROID_DAG_PHASE4B2A_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4B2A_CLOCK_STATE_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4B2A_CLOCK_STATE_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: $raw';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
