import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesYcbcrImportGuardPhysicalSmokeApp());
}

class AndroidGlesYcbcrImportGuardPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesYcbcrImportGuardPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesYcbcrImportGuardPhysicalSmokeApp> createState() =>
      _AndroidGlesYcbcrImportGuardPhysicalSmokeAppState();
}

class _AndroidGlesYcbcrImportGuardPhysicalSmokeAppState
    extends State<AndroidGlesYcbcrImportGuardPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES YCBCR_420_888 AHardwareBuffer import guard fail-closed Unit AH physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke',
        <String, dynamic>{'width': 64, 'height': 64},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'exception:${error.runtimeType}',
        'ycbcrAllocation': 'exception:${error.runtimeType}',
        'clientVersion': 0,
        'vendor': '',
        'renderer': '',
        'version': '',
        'validBufferDescribe': 'not_run',
        'validBufferFormat': 0,
        'validBufferUsage': 0,
        'ycbcrBufferDescribe': 'not_run',
        'ycbcrBufferFormat': 0,
        'ycbcrBufferUsage': 0,
        'ycbcrFormatIs420888': false,
        'initialize': 'not_run',
        'validPreImport': 'not_run',
        'validPreHandle': 0,
        'validPreDescWidth': 0,
        'validPreDescHeight': 0,
        'validPreDescLayers': 0,
        'validPreDescFormat': 0,
        'validPreDescUsageSampled': false,
        'hasValidPreAfterImport': false,
        'validPreRelease': 'not_run',
        'validPreReleaseFence': -1,
        'hasValidPreAfterRelease': false,
        'ycbcrImport': 'not_run',
        'ycbcrHandle': 0,
        'ycbcrDescZero': false,
        'ycbcrLastError': 'none',
        'hasYcbcrAfterImport': false,
        'validPostImport': 'not_run',
        'validPostHandle': 0,
        'validPostDescWidth': 0,
        'validPostDescHeight': 0,
        'validPostDescLayers': 0,
        'validPostDescFormat': 0,
        'validPostDescUsageSampled': false,
        'hasValidPostAfterImport': false,
        'validPostRelease': 'not_run',
        'validPostReleaseFence': -1,
        'hasValidPostAfterRelease': false,
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_ycbcr_ahb_import_guard_fail_closed_no_oes_no_release_fence_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final ycbcrAllocation = (payload['ycbcrAllocation'] as String?) ?? '';
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final validBufferDescribe =
        (payload['validBufferDescribe'] as String?) ?? '';
    final validBufferFormat =
        (payload['validBufferFormat'] as num?)?.toInt() ?? 0;
    final validBufferUsage =
        (payload['validBufferUsage'] as num?)?.toInt() ?? 0;
    final ycbcrBufferDescribe =
        (payload['ycbcrBufferDescribe'] as String?) ?? '';
    final ycbcrBufferFormat =
        (payload['ycbcrBufferFormat'] as num?)?.toInt() ?? 0;
    final ycbcrBufferUsage =
        (payload['ycbcrBufferUsage'] as num?)?.toInt() ?? 0;
    final ycbcrFormatIs420888 = payload['ycbcrFormatIs420888'] == true;
    final initialize = (payload['initialize'] as String?) ?? '';
    final validPreImport = (payload['validPreImport'] as String?) ?? '';
    final validPreHandle = (payload['validPreHandle'] as num?)?.toInt() ?? 0;
    final validPreDescWidth =
        (payload['validPreDescWidth'] as num?)?.toInt() ?? 0;
    final validPreDescHeight =
        (payload['validPreDescHeight'] as num?)?.toInt() ?? 0;
    final validPreDescLayers =
        (payload['validPreDescLayers'] as num?)?.toInt() ?? 0;
    final validPreDescFormat =
        (payload['validPreDescFormat'] as num?)?.toInt() ?? 0;
    final validPreDescUsageSampled =
        payload['validPreDescUsageSampled'] == true;
    final hasValidPreAfterImport = payload['hasValidPreAfterImport'] == true;
    final validPreRelease = (payload['validPreRelease'] as String?) ?? '';
    final validPreReleaseFence =
        (payload['validPreReleaseFence'] as num?)?.toInt() ?? 0;
    final hasValidPreAfterRelease = payload['hasValidPreAfterRelease'] == true;
    final ycbcrImport = (payload['ycbcrImport'] as String?) ?? '';
    final ycbcrHandle = (payload['ycbcrHandle'] as num?)?.toInt() ?? 0;
    final ycbcrDescZero = payload['ycbcrDescZero'] == true;
    final ycbcrLastError = (payload['ycbcrLastError'] as String?) ?? '';
    final hasYcbcrAfterImport = payload['hasYcbcrAfterImport'] == true;
    final validPostImport = (payload['validPostImport'] as String?) ?? '';
    final validPostHandle = (payload['validPostHandle'] as num?)?.toInt() ?? 0;
    final validPostDescWidth =
        (payload['validPostDescWidth'] as num?)?.toInt() ?? 0;
    final validPostDescHeight =
        (payload['validPostDescHeight'] as num?)?.toInt() ?? 0;
    final validPostDescLayers =
        (payload['validPostDescLayers'] as num?)?.toInt() ?? 0;
    final validPostDescFormat =
        (payload['validPostDescFormat'] as num?)?.toInt() ?? 0;
    final validPostDescUsageSampled =
        payload['validPostDescUsageSampled'] == true;
    final hasValidPostAfterImport = payload['hasValidPostAfterImport'] == true;
    final validPostRelease = (payload['validPostRelease'] as String?) ?? '';
    final validPostReleaseFence =
        (payload['validPostReleaseFence'] as num?)?.toInt() ?? 0;
    final hasValidPostAfterRelease =
        payload['hasValidPostAfterRelease'] == true;
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        ycbcrAllocation == 'success' &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        validBufferDescribe == 'success' &&
        validBufferFormat == 1 &&
        validBufferUsage > 0 &&
        ycbcrBufferDescribe == 'success' &&
        ycbcrBufferFormat == 35 &&
        ycbcrBufferUsage > 0 &&
        ycbcrFormatIs420888 &&
        initialize == 'success' &&
        validPreImport == 'success' &&
        validPreHandle > 0 &&
        validPreDescWidth == 64 &&
        validPreDescHeight == 64 &&
        validPreDescLayers == 1 &&
        validPreDescFormat == 1 &&
        validPreDescUsageSampled &&
        hasValidPreAfterImport &&
        validPreRelease == 'success' &&
        validPreReleaseFence == -1 &&
        !hasValidPreAfterRelease &&
        ycbcrImport == 'rejected_as_expected' &&
        ycbcrHandle == 0 &&
        ycbcrDescZero &&
        ycbcrLastError == 'ahb_import_unsupported_format' &&
        !hasYcbcrAfterImport &&
        validPostImport == 'success' &&
        validPostHandle > 0 &&
        validPostDescWidth == 64 &&
        validPostDescHeight == 64 &&
        validPostDescLayers == 1 &&
        validPostDescFormat == 1 &&
        validPostDescUsageSampled &&
        hasValidPostAfterImport &&
        validPostRelease == 'success' &&
        validPostReleaseFence == -1 &&
        !hasValidPostAfterRelease &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_ycbcr_ahb_import_guard_fail_closed_no_oes_no_release_fence_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_YCBCR_IMPORT_GUARD_UNIT_AH_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_YCBCR_IMPORT_GUARD_UNIT_AH_PHYSICAL_PASS'
          : 'ANDROID_GLES_YCBCR_IMPORT_GUARD_UNIT_AH_PHYSICAL_FAIL',
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
