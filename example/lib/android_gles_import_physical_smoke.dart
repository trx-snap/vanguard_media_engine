import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesImportPhysicalSmokeApp());
}

class AndroidGlesImportPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesImportPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesImportPhysicalSmokeApp> createState() =>
      _AndroidGlesImportPhysicalSmokeAppState();
}

class _AndroidGlesImportPhysicalSmokeAppState
    extends State<AndroidGlesImportPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android GLES import Unit Y physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1YGlesImportSmoke',
        <String, dynamic>{'width': 64, 'height': 64},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'exception:${error.runtimeType}',
        'preInitImport': 'not_run',
        'preInitHandle': 0,
        'preInitDescriptorZero': false,
        'initialize': 'not_run',
        'nullBufferImport': 'not_run',
        'nullHandleImport': 'not_run',
        'nullDescriptorImport': 'not_run',
        'validImportA': 'not_run',
        'handleA': 0,
        'descriptorWidth': 0,
        'descriptorHeight': 0,
        'descriptorLayers': 0,
        'descriptorFormat': 0,
        'descriptorUsageSampled': false,
        'hasAAfterImport': false,
        'duplicateImport': 'not_run',
        'duplicateHandle': 0,
        'hasAAfterDuplicate': false,
        'renderFrame': 'not_run',
        'validImportB': 'not_run',
        'handleB': 0,
        'distinctHandles': false,
        'hasBAfterImport': false,
        'releaseA': 'not_run',
        'releaseAFence': -1,
        'hasAAfterRelease': false,
        'doubleReleaseA': 'not_run',
        'shutdown': 'not_run',
        'hasBAfterShutdown': false,
        'idempotentShutdown': 'not_run',
        'proofBoundary': 'gles_ahb_rgba_import_no_renderFrame',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final preInitImport = (payload['preInitImport'] as String?) ?? '';
    final preInitHandle = (payload['preInitHandle'] as num?)?.toInt() ?? 0;
    final preInitDescriptorZero = payload['preInitDescriptorZero'] == true;
    final initialize = (payload['initialize'] as String?) ?? '';
    final nullBufferImport = (payload['nullBufferImport'] as String?) ?? '';
    final nullHandleImport = (payload['nullHandleImport'] as String?) ?? '';
    final nullDescriptorImport =
        (payload['nullDescriptorImport'] as String?) ?? '';
    final validImportA = (payload['validImportA'] as String?) ?? '';
    final handleA = (payload['handleA'] as num?)?.toInt() ?? 0;
    final descriptorWidth = (payload['descriptorWidth'] as num?)?.toInt() ?? 0;
    final descriptorHeight =
        (payload['descriptorHeight'] as num?)?.toInt() ?? 0;
    final descriptorLayers =
        (payload['descriptorLayers'] as num?)?.toInt() ?? 0;
    final descriptorFormat =
        (payload['descriptorFormat'] as num?)?.toInt() ?? 0;
    final descriptorUsageSampled = payload['descriptorUsageSampled'] == true;
    final hasAAfterImport = payload['hasAAfterImport'] == true;
    final duplicateImport = (payload['duplicateImport'] as String?) ?? '';
    final duplicateHandle = (payload['duplicateHandle'] as num?)?.toInt() ?? 0;
    final hasAAfterDuplicate = payload['hasAAfterDuplicate'] == true;
    final renderFrame = (payload['renderFrame'] as String?) ?? '';
    final validImportB = (payload['validImportB'] as String?) ?? '';
    final handleB = (payload['handleB'] as num?)?.toInt() ?? 0;
    final distinctHandles = payload['distinctHandles'] == true;
    final hasBAfterImport = payload['hasBAfterImport'] == true;
    final releaseA = (payload['releaseA'] as String?) ?? '';
    final releaseAFence = (payload['releaseAFence'] as num?)?.toInt() ?? 0;
    final hasAAfterRelease = payload['hasAAfterRelease'] == true;
    final doubleReleaseA = (payload['doubleReleaseA'] as String?) ?? '';
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final hasBAfterShutdown = payload['hasBAfterShutdown'] == true;
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        preInitImport == 'rejected_as_expected' &&
        preInitHandle == 0 &&
        preInitDescriptorZero &&
        initialize == 'success' &&
        nullBufferImport == 'rejected_as_expected' &&
        nullHandleImport == 'rejected_as_expected' &&
        nullDescriptorImport == 'rejected_as_expected' &&
        validImportA == 'success' &&
        handleA > 0 &&
        descriptorWidth == 64 &&
        descriptorHeight == 64 &&
        descriptorLayers == 1 &&
        descriptorFormat != 0 &&
        descriptorUsageSampled &&
        hasAAfterImport &&
        duplicateImport == 'rejected_as_expected' &&
        duplicateHandle == 0 &&
        hasAAfterDuplicate &&
        renderFrame == 'no_surface' &&
        validImportB == 'success' &&
        handleB > 0 &&
        distinctHandles &&
        hasBAfterImport &&
        releaseA == 'success' &&
        releaseAFence == -1 &&
        !hasAAfterRelease &&
        doubleReleaseA == 'rejected_as_expected' &&
        shutdown == 'success' &&
        !hasBAfterShutdown &&
        idempotentShutdown == 'success' &&
        proofBoundary == 'gles_ahb_rgba_import_no_renderFrame';

    // ignore: avoid_print
    print('ANDROID_GLES_IMPORT_UNIT_Y_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_IMPORT_UNIT_Y_PHYSICAL_PASS'
          : 'ANDROID_GLES_IMPORT_UNIT_Y_PHYSICAL_FAIL',
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
