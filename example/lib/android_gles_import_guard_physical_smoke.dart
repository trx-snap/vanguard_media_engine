import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesImportGuardPhysicalSmokeApp());
}

class AndroidGlesImportGuardPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesImportGuardPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesImportGuardPhysicalSmokeApp> createState() =>
      _AndroidGlesImportGuardPhysicalSmokeAppState();
}

class _AndroidGlesImportGuardPhysicalSmokeAppState
    extends State<AndroidGlesImportGuardPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES AHardwareBuffer import guard fail-closed Unit AG physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AGGlesImportGuardSmoke',
        <String, dynamic>{'width': 64, 'height': 64},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'exception:${error.runtimeType}',
        'unsupportedFormatAllocation': 'exception:${error.runtimeType}',
        'clientVersion': 0,
        'vendor': '',
        'renderer': '',
        'version': '',
        'validBufferDescribe': 'not_run',
        'validBufferFormat': 0,
        'validBufferUsage': 0,
        'missingUsageBufferDescribe': 'not_run',
        'missingUsageBufferFormat': 0,
        'missingUsageBufferUsage': 0,
        'missingUsageHasSampled': false,
        'unsupportedFormatBufferDescribe': 'not_run',
        'unsupportedFormatBufferFormat': 0,
        'unsupportedFormatBufferUsage': 0,
        'unsupportedFormatIsRgb565': false,
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
        'missingUsageImport': 'not_run',
        'missingUsageHandle': 0,
        'missingUsageDescZero': false,
        'missingUsageLastError': 'none',
        'hasMissingUsageAfterImport': false,
        'unsupportedFormatImport': 'not_run',
        'unsupportedFormatHandle': 0,
        'unsupportedFormatDescZero': false,
        'unsupportedFormatLastError': 'none',
        'hasUnsupportedFormatAfterImport': false,
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
            'gles_ahb_import_guard_fail_closed_no_yuv_no_oes_release_fence_optional_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final unsupportedFormatAllocation =
        (payload['unsupportedFormatAllocation'] as String?) ?? '';
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
    final missingUsageBufferDescribe =
        (payload['missingUsageBufferDescribe'] as String?) ?? '';
    final missingUsageBufferFormat =
        (payload['missingUsageBufferFormat'] as num?)?.toInt() ?? 0;
    final missingUsageBufferUsage =
        (payload['missingUsageBufferUsage'] as num?)?.toInt() ?? 0;
    final missingUsageHasSampled = payload['missingUsageHasSampled'] == true;
    final unsupportedFormatBufferDescribe =
        (payload['unsupportedFormatBufferDescribe'] as String?) ?? '';
    final unsupportedFormatBufferFormat =
        (payload['unsupportedFormatBufferFormat'] as num?)?.toInt() ?? 0;
    final unsupportedFormatBufferUsage =
        (payload['unsupportedFormatBufferUsage'] as num?)?.toInt() ?? 0;
    final unsupportedFormatIsRgb565 =
        payload['unsupportedFormatIsRgb565'] == true;
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
        (payload['validPreReleaseFence'] as num?)?.toInt() ?? -1;
    final hasValidPreAfterRelease = payload['hasValidPreAfterRelease'] == true;
    final missingUsageImport = (payload['missingUsageImport'] as String?) ?? '';
    final missingUsageHandle =
        (payload['missingUsageHandle'] as num?)?.toInt() ?? 0;
    final missingUsageDescZero = payload['missingUsageDescZero'] == true;
    final missingUsageLastError =
        (payload['missingUsageLastError'] as String?) ?? '';
    final hasMissingUsageAfterImport =
        payload['hasMissingUsageAfterImport'] == true;
    final unsupportedFormatImport =
        (payload['unsupportedFormatImport'] as String?) ?? '';
    final unsupportedFormatHandle =
        (payload['unsupportedFormatHandle'] as num?)?.toInt() ?? 0;
    final unsupportedFormatDescZero =
        payload['unsupportedFormatDescZero'] == true;
    final unsupportedFormatLastError =
        (payload['unsupportedFormatLastError'] as String?) ?? '';
    final hasUnsupportedFormatAfterImport =
        payload['hasUnsupportedFormatAfterImport'] == true;
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
        (payload['validPostReleaseFence'] as num?)?.toInt() ?? -1;
    final hasValidPostAfterRelease =
        payload['hasValidPostAfterRelease'] == true;
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        unsupportedFormatAllocation == 'success' &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        validBufferDescribe == 'success' &&
        validBufferFormat == 1 &&
        validBufferUsage > 0 &&
        missingUsageBufferDescribe == 'success' &&
        missingUsageBufferFormat == 1 &&
        missingUsageBufferUsage > 0 &&
        !missingUsageHasSampled &&
        unsupportedFormatBufferDescribe == 'success' &&
        unsupportedFormatBufferFormat == 4 &&
        unsupportedFormatBufferUsage > 0 &&
        unsupportedFormatIsRgb565 &&
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
        validPreReleaseFence >= -1 &&
        !hasValidPreAfterRelease &&
        missingUsageImport == 'rejected_as_expected' &&
        missingUsageHandle == 0 &&
        missingUsageDescZero &&
        missingUsageLastError == 'ahb_import_missing_gpu_sampled_usage' &&
        !hasMissingUsageAfterImport &&
        unsupportedFormatImport == 'rejected_as_expected' &&
        unsupportedFormatHandle == 0 &&
        unsupportedFormatDescZero &&
        unsupportedFormatLastError == 'ahb_import_unsupported_format' &&
        !hasUnsupportedFormatAfterImport &&
        validPostImport == 'success' &&
        validPostHandle > 0 &&
        validPostDescWidth == 64 &&
        validPostDescHeight == 64 &&
        validPostDescLayers == 1 &&
        validPostDescFormat == 1 &&
        validPostDescUsageSampled &&
        hasValidPostAfterImport &&
        validPostRelease == 'success' &&
        validPostReleaseFence >= -1 &&
        !hasValidPostAfterRelease &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_ahb_import_guard_fail_closed_no_yuv_no_oes_release_fence_optional_no_product';

    // ignore: avoid_print
    print('ANDROID_GLES_IMPORT_GUARD_UNIT_AG_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_IMPORT_GUARD_UNIT_AG_PHYSICAL_PASS'
          : 'ANDROID_GLES_IMPORT_GUARD_UNIT_AG_PHYSICAL_FAIL',
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
