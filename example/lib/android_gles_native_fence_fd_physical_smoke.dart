import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesNativeFenceFdPhysicalSmokeApp());
}

class AndroidGlesNativeFenceFdPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesNativeFenceFdPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesNativeFenceFdPhysicalSmokeApp> createState() =>
      _AndroidGlesNativeFenceFdPhysicalSmokeAppState();
}

class _AndroidGlesNativeFenceFdPhysicalSmokeAppState
    extends State<AndroidGlesNativeFenceFdPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES native fence FD Unit AJ physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AJGlesNativeFenceFdSmoke',
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'exception:${error.runtimeType}',
        'clientVersion': 0,
        'vendor': '',
        'renderer': '',
        'version': '',
        'initialize': 'exception:${error.runtimeType}',
        'eglCurrentDisplayOk': false,
        'symbolsResolved': false,
        'nativeFenceSyncCreate': 'not_run',
        'glFlushOk': false,
        'dupNativeFenceFd': -1,
        'fdOpenBeforeClose': false,
        'waitOutcome': 'not_run',
        'waitSignaled': false,
        'closeResult': 'not_run',
        'fdClosedAfterClose': false,
        'destroySync': 'not_run',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_native_fence_fd_lifecycle_no_releaseHardwareBuffer_path_no_import_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final initialize = payload['initialize'];
    final eglCurrentDisplayOk = payload['eglCurrentDisplayOk'] == true;
    final symbolsResolved = payload['symbolsResolved'] == true;
    final nativeFenceSyncCreate = payload['nativeFenceSyncCreate'];
    final glFlushOk = payload['glFlushOk'] == true;
    final dupNativeFenceFd =
        (payload['dupNativeFenceFd'] as num?)?.toInt() ?? -1;
    final fdOpenBeforeClose = payload['fdOpenBeforeClose'] == true;
    final waitOutcome = (payload['waitOutcome'] as String?) ?? '';
    final waitSignaled = payload['waitSignaled'] == true;
    final closeResult = payload['closeResult'];
    final fdClosedAfterClose = payload['fdClosedAfterClose'] == true;
    final destroySync = payload['destroySync'];
    final shutdown = payload['shutdown'];
    final idempotentShutdown = payload['idempotentShutdown'];
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        (initialize == 'success' || initialize == true) &&
        eglCurrentDisplayOk &&
        symbolsResolved &&
        (nativeFenceSyncCreate == 'success' || nativeFenceSyncCreate == true) &&
        glFlushOk &&
        dupNativeFenceFd >= 0 &&
        fdOpenBeforeClose &&
        waitOutcome == 'signaled' &&
        waitSignaled &&
        (closeResult == 'success' || closeResult == true) &&
        fdClosedAfterClose &&
        (destroySync == 'success' || destroySync == true) &&
        (shutdown == 'success' || shutdown == true) &&
        (idempotentShutdown == 'success' || idempotentShutdown == true) &&
        proofBoundary ==
            'gles_native_fence_fd_lifecycle_no_releaseHardwareBuffer_path_no_import_no_product';

    // ignore: avoid_print
    print('ANDROID_GLES_NATIVE_FENCE_FD_UNIT_AJ_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_NATIVE_FENCE_FD_UNIT_AJ_PHYSICAL_PASS'
          : 'ANDROID_GLES_NATIVE_FENCE_FD_UNIT_AJ_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = isPass ? 'PASS' : 'FAIL';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(body: Center(child: Text(_status))),
    );
  }
}
