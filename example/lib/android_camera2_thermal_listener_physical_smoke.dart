// android_camera2_thermal_listener_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit T: Android Camera2 Dynamic Thermal
// Listener & Fallback Telemetry Physical Proof Foundation Smoke Harness.
//
// Proof lanes:
//   Lane 1: getThermalState() succeeds and returns a raw value mapping to a
//           valid VGThermalState.
//   Lane 2: diagnostic route runAndroidDagPhase3UnitTThermalListenerSmoke
//           returns success == true.
//   Lane 3: diagnostics.listenerApiSupported and diagnostics.listenerRegistered
//           are coherent (registered can only be true when API-supported).
//   Lane 4: proofBoundary == dynamic_thermal_listener_no_camera_open_no_forced_heat
//           and every nonClaims entry is false.
//   Lane 5: simulateThermalState(serious) is observed on
//           VGThermalMonitor.onThermalStateChanged.
//   Lane 6: simulateThermalState(critical) is observed on the same stream.
//   Lane 7: simulateThermalState(nominal) (reset) is observed on the same
//           stream.
//   Lane 8: the three simulated events above arrive in the order they were
//           issued (serious -> critical -> nominal).
//   Lane 9: an out-of-range raw simulateThermalState call (bypassing the
//           Dart enum) fails with INVALID_ARG and does not emit a stream
//           event.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ThermalListenerPhysicalSmokeApp());
}

class AndroidCamera2ThermalListenerPhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2ThermalListenerPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ThermalListenerPhysicalSmokeApp> createState() =>
      _AndroidCamera2ThermalListenerPhysicalSmokeAppState();
}

class _AndroidCamera2ThermalListenerPhysicalSmokeAppState
    extends State<AndroidCamera2ThermalListenerPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  static const String _proofBoundary =
      'dynamic_thermal_listener_no_camera_open_no_forced_heat';

  String _status = 'Initializing Camera2 Thermal Listener Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<bool> _waitForState(
    List<VGThermalState> received,
    VGThermalState expected,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (received.contains(expected)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return received.contains(expected);
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_T_THERMAL_LISTENER_SMOKE_START');
    String? topLevelError;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;
    var lane9Pass = false;

    int? initialRaw;
    Map<String, dynamic>? diagnosticReport;
    final receivedStates = <VGThermalState>[];
    StreamSubscription<VGThermalState>? subscription;
    String? invalidArgErrorCode;

    try {
      // 0. Subscribe first so no simulated event is missed.
      subscription = VGThermalMonitor.onThermalStateChanged.listen(
        receivedStates.add,
      );

      // 1. getThermalState() — one-shot native query.
      final currentState = await VGThermalMonitor.getThermalState().timeout(
        const Duration(seconds: 15),
      );
      initialRaw = currentState.index;
      lane1Pass = VGThermalState.values.contains(currentState);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_1: pass=$lane1Pass '
        'currentState=${currentState.name} raw=$initialRaw',
      );

      // 2. Diagnostic route — proves API/snapshot/listener registration state.
      final rawReport = await _channel
          .invokeMethod<Object?>('runAndroidDagPhase3UnitTThermalListenerSmoke')
          .timeout(const Duration(seconds: 15));
      diagnosticReport = Map<String, dynamic>.from(rawReport! as Map);
      lane2Pass = diagnosticReport['success'] == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_2: pass=$lane2Pass '
        'success=${diagnosticReport['success']}',
      );

      // Lane 3: listener registration coherent with API support.
      final diagnostics = Map<String, dynamic>.from(
        diagnosticReport['diagnostics'] as Map? ?? const {},
      );
      final listenerApiSupported = diagnostics['listenerApiSupported'] == true;
      final listenerRegistered = diagnostics['listenerRegistered'] == true;
      lane3Pass = listenerApiSupported
          ? listenerRegistered
          : !listenerRegistered;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_3: pass=$lane3Pass '
        'listenerApiSupported=$listenerApiSupported listenerRegistered=$listenerRegistered',
      );

      // Lane 4: proof boundary string + non-claims all false.
      final nonClaims = Map<String, dynamic>.from(
        diagnosticReport['nonClaims'] as Map? ?? const {},
      );
      final allNonClaimsFalse = nonClaims.values.every((v) => v == false);
      lane4Pass =
          diagnosticReport['proofBoundary'] == _proofBoundary &&
          allNonClaimsFalse;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_4: pass=$lane4Pass '
        'proofBoundary=${diagnosticReport['proofBoundary']} nonClaims=$nonClaims',
      );

      // 3. Simulate serious -> critical -> nominal, asserting each arrives.
      await VGThermalMonitor.simulateThermalState(VGThermalState.serious);
      lane5Pass = await _waitForState(receivedStates, VGThermalState.serious);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_5: pass=$lane5Pass '
        'receivedStates=${receivedStates.map((s) => s.name).toList()}',
      );

      await VGThermalMonitor.simulateThermalState(VGThermalState.critical);
      lane6Pass = await _waitForState(receivedStates, VGThermalState.critical);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_6: pass=$lane6Pass '
        'receivedStates=${receivedStates.map((s) => s.name).toList()}',
      );

      await VGThermalMonitor.simulateThermalState(VGThermalState.nominal);
      lane7Pass = await _waitForState(receivedStates, VGThermalState.nominal);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_7: pass=$lane7Pass '
        'receivedStates=${receivedStates.map((s) => s.name).toList()}',
      );

      // Lane 8: arrival order matches issue order.
      final seriousIdx = receivedStates.indexOf(VGThermalState.serious);
      final criticalIdx = seriousIdx >= 0
          ? receivedStates.indexOf(VGThermalState.critical, seriousIdx + 1)
          : -1;
      final nominalIdx = criticalIdx >= 0
          ? receivedStates.indexOf(VGThermalState.nominal, criticalIdx + 1)
          : -1;
      lane8Pass =
          seriousIdx >= 0 &&
          criticalIdx > seriousIdx &&
          nominalIdx > criticalIdx;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_8: pass=$lane8Pass '
        'seriousIdx=$seriousIdx criticalIdx=$criticalIdx nominalIdx=$nominalIdx',
      );

      // Lane 9: out-of-range raw value (bypassing the Dart enum) -> INVALID_ARG,
      // no extra stream event.
      final countBeforeInvalid = receivedStates.length;
      try {
        await _channel.invokeMethod<void>('simulateThermalState', {
          'rawValue': 99,
        });
      } on PlatformException catch (e) {
        invalidArgErrorCode = e.code;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      lane9Pass =
          invalidArgErrorCode == 'INVALID_ARG' &&
          receivedStates.length == countBeforeInvalid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_SMOKE_LANE_9: pass=$lane9Pass '
        'errorCode=$invalidArgErrorCode countBeforeInvalid=$countBeforeInvalid '
        'countAfterInvalid=${receivedStates.length}',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Thermal listener smoke exceeded 15 seconds: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_THERMAL_LISTENER_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_THERMAL_LISTENER_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      await subscription?.cancel();

      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          lane6Pass &&
          lane7Pass &&
          lane8Pass &&
          lane9Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidThermalStateBridge',
        'slice':
            'Phase 3-Unit T — Android Camera2 Dynamic Thermal Listener & '
            'Fallback Telemetry Physical Proof Foundation',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _proofBoundary,
        'initialRaw': initialRaw,
        'receivedStates': receivedStates.map((s) => s.name).toList(),
        'lanes': <String, dynamic>{
          'lane1_getThermalStateValid': {'pass': lane1Pass, 'raw': initialRaw},
          'lane2_diagnosticRouteSuccess': {
            'pass': lane2Pass,
            'success': diagnosticReport?['success'],
          },
          'lane3_listenerRegistrationCoherent': {'pass': lane3Pass},
          'lane4_proofBoundaryAndNonClaims': {'pass': lane4Pass},
          'lane5_seriousEventArrives': {'pass': lane5Pass},
          'lane6_criticalEventArrives': {'pass': lane6Pass},
          'lane7_nominalResetEventArrives': {'pass': lane7Pass},
          'lane8_eventOrderPreserved': {'pass': lane8Pass},
          'lane9_invalidRawValueRejected': {
            'pass': lane9Pass,
            'errorCode': invalidArgErrorCode,
          },
        },
        'diagnosticReport': diagnosticReport,
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_T_THERMAL_LISTENER_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_T_THERMAL_LISTENER_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_T_THERMAL_LISTENER_PHYSICAL_FAIL',
      );

      if (mounted) {
        setState(() {
          _status = allPass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(allPass ? 0 : 1);
    }
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
