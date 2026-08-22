// Vanguard Android True-DAG Phase 4C3S: Physical RTC all-up smoke test.
//
// Sequentially invokes all five Android RTC MethodChannel smoke routes:
//   1. runAndroidDagPhase4C3DRtcContractSmoke (Phase 4C3D: RTC video contracts)
//   2. runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke (Phase 4C3G: Realtime video adapters)
//   3. runAndroidDagPhase4C3KRtcMetadataSmoke (Phase 4C3K: RTC timestamp & orientation metadata)
//   4. runAndroidDagPhase4C3NRtcBackpressureSmoke (Phase 4C3N: RTC backpressure controller)
//   5. runAndroidDagPhase4C3QRtcFrameValidatorSmoke (Phase 4C3Q: RTC frame validator)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _width = int.fromEnvironment('WIDTH', defaultValue: 64);
const int _height = int.fromEnvironment('HEIGHT', defaultValue: 64);
const int _frameCount = int.fromEnvironment('FRAME_COUNT', defaultValue: 3);

void main() {
  runApp(const AndroidRtcAllUpPhysicalSmokeApp());
}

class AndroidRtcAllUpPhysicalSmokeApp extends StatefulWidget {
  const AndroidRtcAllUpPhysicalSmokeApp({super.key});

  @override
  State<AndroidRtcAllUpPhysicalSmokeApp> createState() =>
      _AndroidRtcAllUpPhysicalSmokeAppState();
}

class _AndroidRtcAllUpPhysicalSmokeAppState
    extends State<AndroidRtcAllUpPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android RTC all-up physical smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 2));

    final results = <String, dynamic>{};
    bool allPass = true;

    // 1. Phase 4C3D: RTC Contract Smoke
    try {
      if (mounted) {
        setState(() {
          _status = 'Running Phase 4C3D RTC contract smoke…';
        });
      }
      final resp = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C3DRtcContractSmoke',
        <String, dynamic>{
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
        },
      );
      if (resp == null || resp is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3DRtcContractSmoke returned invalid response: $resp',
        );
      }
      final map = Map<String, dynamic>.from(resp);
      final pass = map['pass'] == true;
      results['contract'] = <String, dynamic>{
        'pass': pass,
        'raw': map['raw']?.toString() ?? (pass ? 'status=OK' : 'status=FAIL'),
        'details': map,
      };
      if (!pass) allPass = false;
    } catch (e, st) {
      // ignore: avoid_print
      print('ANDROID_RTC_ALL_UP_CONTRACT_ERROR: $e\n$st');
      results['contract'] = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception:$e',
      };
      allPass = false;
    }

    // 2. Phase 4C3G: Realtime Video Adapter Smoke
    try {
      if (mounted) {
        setState(() {
          _status = 'Running Phase 4C3G realtime video adapter smoke…';
        });
      }
      final resp = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke',
        <String, dynamic>{
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
        },
      );
      if (resp == null || resp is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke returned invalid response: $resp',
        );
      }
      final map = Map<String, dynamic>.from(resp);
      final pass = map['pass'] == true;
      results['adapter'] = <String, dynamic>{
        'pass': pass,
        'raw': map['raw']?.toString() ?? (pass ? 'status=OK' : 'status=FAIL'),
        'details': map,
      };
      if (!pass) allPass = false;
    } catch (e, st) {
      // ignore: avoid_print
      print('ANDROID_RTC_ALL_UP_ADAPTER_ERROR: $e\n$st');
      results['adapter'] = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception:$e',
      };
      allPass = false;
    }

    // 3. Phase 4C3K: RTC Metadata Smoke
    try {
      if (mounted) {
        setState(() {
          _status = 'Running Phase 4C3K RTC metadata smoke…';
        });
      }
      final resp = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C3KRtcMetadataSmoke',
      );
      if (resp == null || resp is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3KRtcMetadataSmoke returned invalid response: $resp',
        );
      }
      final map = Map<String, dynamic>.from(resp);
      final pass = map['pass'] == true;
      results['metadata'] = <String, dynamic>{
        'pass': pass,
        'raw': map['raw']?.toString() ?? (pass ? 'status=OK' : 'status=FAIL'),
        'details': map,
      };
      if (!pass) allPass = false;
    } catch (e, st) {
      // ignore: avoid_print
      print('ANDROID_RTC_ALL_UP_METADATA_ERROR: $e\n$st');
      results['metadata'] = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception:$e',
      };
      allPass = false;
    }

    // 4. Phase 4C3N: RTC Backpressure Smoke
    try {
      if (mounted) {
        setState(() {
          _status = 'Running Phase 4C3N RTC backpressure smoke…';
        });
      }
      final resp = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C3NRtcBackpressureSmoke',
      );
      if (resp == null || resp is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3NRtcBackpressureSmoke returned invalid response: $resp',
        );
      }
      final map = Map<String, dynamic>.from(resp);
      final pass = map['pass'] == true;
      results['backpressure'] = <String, dynamic>{
        'pass': pass,
        'raw': map['raw']?.toString() ?? (pass ? 'status=OK' : 'status=FAIL'),
        'details': map,
      };
      if (!pass) allPass = false;
    } catch (e, st) {
      // ignore: avoid_print
      print('ANDROID_RTC_ALL_UP_BACKPRESSURE_ERROR: $e\n$st');
      results['backpressure'] = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception:$e',
      };
      allPass = false;
    }

    // 5. Phase 4C3Q: RTC Frame Validator Smoke
    try {
      if (mounted) {
        setState(() {
          _status = 'Running Phase 4C3Q RTC frame validator smoke…';
        });
      }
      final resp = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C3QRtcFrameValidatorSmoke',
        <String, dynamic>{'width': _width, 'height': _height},
      );
      if (resp == null || resp is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3QRtcFrameValidatorSmoke returned invalid response: $resp',
        );
      }
      final map = Map<String, dynamic>.from(resp);
      final pass = map['pass'] == true;
      results['validator'] = <String, dynamic>{
        'pass': pass,
        'raw': map['raw']?.toString() ?? (pass ? 'status=OK' : 'status=FAIL'),
        'details': map,
      };
      if (!pass) allPass = false;
    } catch (e, st) {
      // ignore: avoid_print
      print('ANDROID_RTC_ALL_UP_VALIDATOR_ERROR: $e\n$st');
      results['validator'] = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception:$e',
      };
      allPass = false;
    }

    final diagMap = <String, dynamic>{
      'pass': allPass,
      'routes': results,
      'contractPass': results['contract']?['pass'] == true,
      'adapterPass': results['adapter']?['pass'] == true,
      'metadataPass': results['metadata']?['pass'] == true,
      'backpressurePass': results['backpressure']?['pass'] == true,
      'validatorPass': results['validator']?['pass'] == true,
      'contractRaw': results['contract']?['raw'] ?? '',
      'adapterRaw': results['adapter']?['raw'] ?? '',
      'metadataRaw': results['metadata']?['raw'] ?? '',
      'backpressureRaw': results['backpressure']?['raw'] ?? '',
      'validatorRaw': results['validator']?['raw'] ?? '',
    };

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print('ANDROID_RTC_ALL_UP_PHYSICAL_JSON:${jsonEncode(diagMap)}');
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_RTC_ALL_UP_PHYSICAL_PASS'
          : 'ANDROID_RTC_ALL_UP_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (all 5 RTC smoke routes verified)'
            : 'FAIL (contract=${results['contract']?['pass']}, adapter=${results['adapter']?['pass']}, metadata=${results['metadata']?['pass']}, backpressure=${results['backpressure']?['pass']}, validator=${results['validator']?['pass']})';
      });
    }

    // Exit process after marker so flutter run can finish unattended
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
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
