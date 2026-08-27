import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesAcquireFencePhysicalSmokeApp());
}

class AndroidGlesAcquireFencePhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesAcquireFencePhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesAcquireFencePhysicalSmokeApp> createState() =>
      _AndroidGlesAcquireFencePhysicalSmokeAppState();
}

class _AndroidGlesAcquireFencePhysicalSmokeAppState
    extends State<AndroidGlesAcquireFencePhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES acquire-fence Unit AE physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AEGlesAcquireFenceSmoke',
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
        'symbolsResolved': false,
        'nativeFenceExtension': 'not_run',
        'preInitImport': 'not_run',
        'preInitHandle': 0,
        'preInitDescriptorZero': false,
        'initialize': 'not_run',
        'invalidFenceImport': 'not_run',
        'invalidFenceLastError': 'none',
        'invalidFenceDescriptorZero': false,
        'invalidFenceHandle': 0,
        'invalidFenceClosed': false,
        'timeoutImport': 'not_run',
        'timeoutLastError': 'none',
        'timeoutDescriptorZero': false,
        'timeoutHandle': 0,
        'timeoutFdClosed': false,
        'signaledFenceCreate': 'not_run',
        'signaledFenceDup': 'not_run',
        'signaledFenceFd': -1,
        'signaledImport': 'not_run',
        'signaledFdClosed': false,
        'signaledHandle': 0,
        'descriptorWidth': 0,
        'descriptorHeight': 0,
        'descriptorLayers': 0,
        'descriptorFormat': 0,
        'descriptorUsageSampled': false,
        'hasAfterImport': false,
        'release': 'not_run',
        'releaseFence': -1,
        'hasAfterRelease': false,
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_ahb_rgba_import_acquire_fence_wait_close_no_yuv_no_release_fence_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final symbolsResolved = payload['symbolsResolved'] == true;
    final nativeFenceExtension =
        (payload['nativeFenceExtension'] as String?) ?? '';
    final preInitImport = (payload['preInitImport'] as String?) ?? '';
    final preInitHandle = (payload['preInitHandle'] as num?)?.toInt() ?? 0;
    final preInitDescriptorZero = payload['preInitDescriptorZero'] == true;
    final initialize = (payload['initialize'] as String?) ?? '';
    final invalidFenceImport = (payload['invalidFenceImport'] as String?) ?? '';
    final invalidFenceLastError =
        (payload['invalidFenceLastError'] as String?) ?? '';
    final invalidFenceDescriptorZero =
        payload['invalidFenceDescriptorZero'] == true;
    final invalidFenceHandle =
        (payload['invalidFenceHandle'] as num?)?.toInt() ?? 0;
    final invalidFenceClosed = payload['invalidFenceClosed'] == true;
    final timeoutImport = (payload['timeoutImport'] as String?) ?? '';
    final timeoutLastError = (payload['timeoutLastError'] as String?) ?? '';
    final timeoutDescriptorZero = payload['timeoutDescriptorZero'] == true;
    final timeoutHandle = (payload['timeoutHandle'] as num?)?.toInt() ?? 0;
    final timeoutFdClosed = payload['timeoutFdClosed'] == true;
    final signaledFenceCreate =
        (payload['signaledFenceCreate'] as String?) ?? '';
    final signaledFenceDup = (payload['signaledFenceDup'] as String?) ?? '';
    final signaledFenceFd = (payload['signaledFenceFd'] as num?)?.toInt() ?? -1;
    final signaledImport = (payload['signaledImport'] as String?) ?? '';
    final signaledFdClosed = payload['signaledFdClosed'] == true;
    final signaledHandle = (payload['signaledHandle'] as num?)?.toInt() ?? 0;
    final descriptorWidth = (payload['descriptorWidth'] as num?)?.toInt() ?? 0;
    final descriptorHeight =
        (payload['descriptorHeight'] as num?)?.toInt() ?? 0;
    final descriptorLayers =
        (payload['descriptorLayers'] as num?)?.toInt() ?? 0;
    final descriptorFormat =
        (payload['descriptorFormat'] as num?)?.toInt() ?? 0;
    final descriptorUsageSampled = payload['descriptorUsageSampled'] == true;
    final hasAfterImport = payload['hasAfterImport'] == true;
    final release = (payload['release'] as String?) ?? '';
    final releaseFence = (payload['releaseFence'] as num?)?.toInt() ?? 0;
    final hasAfterRelease = payload['hasAfterRelease'] == true;
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        symbolsResolved &&
        nativeFenceExtension == 'supported' &&
        preInitImport == 'rejected_as_expected' &&
        preInitHandle == 0 &&
        preInitDescriptorZero &&
        initialize == 'success' &&
        invalidFenceImport == 'rejected_as_expected' &&
        invalidFenceLastError == 'ahb_import_acquire_fence_wait_failed' &&
        invalidFenceDescriptorZero &&
        invalidFenceHandle == 0 &&
        invalidFenceClosed &&
        timeoutImport == 'rejected_as_expected' &&
        timeoutLastError == 'ahb_import_acquire_fence_wait_timeout' &&
        timeoutDescriptorZero &&
        timeoutHandle == 0 &&
        timeoutFdClosed &&
        signaledFenceCreate == 'success' &&
        signaledFenceDup == 'success' &&
        signaledFenceFd >= 0 &&
        signaledImport == 'success' &&
        signaledFdClosed &&
        signaledHandle > 0 &&
        descriptorWidth == 64 &&
        descriptorHeight == 64 &&
        descriptorLayers == 1 &&
        descriptorFormat != 0 &&
        descriptorUsageSampled &&
        hasAfterImport &&
        release == 'success' &&
        releaseFence == -1 &&
        !hasAfterRelease &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_ahb_rgba_import_acquire_fence_wait_close_no_yuv_no_release_fence_no_product';

    // ignore: avoid_print
    print('ANDROID_GLES_ACQUIRE_FENCE_UNIT_AE_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_ACQUIRE_FENCE_UNIT_AE_PHYSICAL_PASS'
          : 'ANDROID_GLES_ACQUIRE_FENCE_UNIT_AE_PHYSICAL_FAIL',
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
