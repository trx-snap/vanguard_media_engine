import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesReleaseFenceProductionPhysicalSmokeApp());
}

class AndroidGlesReleaseFenceProductionPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesReleaseFenceProductionPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesReleaseFenceProductionPhysicalSmokeApp> createState() =>
      _AndroidGlesReleaseFenceProductionPhysicalSmokeAppState();
}

class _AndroidGlesReleaseFenceProductionPhysicalSmokeAppState
    extends State<AndroidGlesReleaseFenceProductionPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES release fence production Unit AK physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke',
        <String, dynamic>{'width': 64, 'height': 64},
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
        'bufferDescribe': 'not_run',
        'initialize': 'exception:${error.runtimeType}',
        'attach': 'not_run',
        'import': 'not_run',
        'handle': 0,
        'diagnosticRender': 'not_run',
        'releaseBuffer': 'not_run',
        'releaseFenceFd': -1,
        'releaseFenceHighFd': -1,
        'releaseFenceHighFdOpen': false,
        'releaseFenceWaitOutcome': 'not_run',
        'releaseFenceWaitSignaled': false,
        'releaseFenceOriginalClose': 'not_run',
        'releaseFenceHighClose': 'not_run',
        'releaseFenceHighFdClosedAfterClose': false,
        'hasAfterRelease': false,
        'doubleRelease': 'not_run',
        'doubleReleaseFence': -1,
        'detach': 'not_run',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_release_fence_production_fd_live_poll_close_no_yuv_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final bufferDescribe = payload['bufferDescribe'];
    final initialize = payload['initialize'];
    final attach = payload['attach'];
    final import = payload['import'];
    final handle = (payload['handle'] as num?)?.toInt() ?? 0;
    final diagnosticRender = payload['diagnosticRender'];
    final releaseBuffer = payload['releaseBuffer'];
    final releaseFenceFd = (payload['releaseFenceFd'] as num?)?.toInt() ?? -1;
    final releaseFenceHighFd =
        (payload['releaseFenceHighFd'] as num?)?.toInt() ?? -1;
    final releaseFenceHighFdOpen = payload['releaseFenceHighFdOpen'] == true;
    final releaseFenceWaitOutcome = payload['releaseFenceWaitOutcome'];
    final releaseFenceWaitSignaled = payload['releaseFenceWaitSignaled'] == true;
    final releaseFenceOriginalClose = payload['releaseFenceOriginalClose'];
    final releaseFenceHighClose = payload['releaseFenceHighClose'];
    final releaseFenceHighFdClosedAfterClose =
        payload['releaseFenceHighFdClosedAfterClose'] == true;
    final hasAfterRelease = payload['hasAfterRelease'] == true;
    final doubleRelease = payload['doubleRelease'];
    final doubleReleaseFence =
        (payload['doubleReleaseFence'] as num?)?.toInt() ?? -1;
    final detach = payload['detach'];
    final shutdown = payload['shutdown'];
    final idempotentShutdown = payload['idempotentShutdown'];
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        (bufferDescribe == 'success' || bufferDescribe == true) &&
        (initialize == 'success' || initialize == true) &&
        (attach == 'success' || attach == true) &&
        (import == 'success' || import == true) &&
        handle > 0 &&
        (diagnosticRender == 'success' || diagnosticRender == true) &&
        (releaseBuffer == 'success' || releaseBuffer == true) &&
        releaseFenceFd >= 0 &&
        releaseFenceHighFd >= 1000 &&
        releaseFenceHighFdOpen &&
        releaseFenceWaitOutcome == 'signaled' &&
        releaseFenceWaitSignaled &&
        (releaseFenceOriginalClose == 'success' ||
            releaseFenceOriginalClose == true) &&
        (releaseFenceHighClose == 'success' || releaseFenceHighClose == true) &&
        releaseFenceHighFdClosedAfterClose &&
        !hasAfterRelease &&
        (doubleRelease == 'rejected_as_expected' || doubleRelease == true) &&
        doubleReleaseFence == -1 &&
        (detach == 'success' || detach == true) &&
        (shutdown == 'success' || shutdown == true) &&
        (idempotentShutdown == 'success' || idempotentShutdown == true) &&
        proofBoundary ==
            'gles_release_fence_production_fd_live_poll_close_no_yuv_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_RELEASE_FENCE_PRODUCTION_UNIT_AK_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_RELEASE_FENCE_PRODUCTION_UNIT_AK_PHYSICAL_PASS'
          : 'ANDROID_GLES_RELEASE_FENCE_PRODUCTION_UNIT_AK_PHYSICAL_FAIL',
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
