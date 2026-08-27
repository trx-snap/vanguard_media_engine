import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesReleaseNullFencePhysicalSmokeApp());
}

class AndroidGlesReleaseNullFencePhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesReleaseNullFencePhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesReleaseNullFencePhysicalSmokeApp> createState() =>
      _AndroidGlesReleaseNullFencePhysicalSmokeAppState();
}

class _AndroidGlesReleaseNullFencePhysicalSmokeAppState
    extends State<AndroidGlesReleaseNullFencePhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES release null fence Unit AL physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ALGlesReleaseNullFenceSmoke',
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
        'bufferWidth': 0,
        'bufferHeight': 0,
        'bufferLayers': 0,
        'bufferFormat': 0,
        'bufferUsageSampled': false,
        'initialize': 'exception:${error.runtimeType}',
        'import1': 'not_run',
        'handle1': 0,
        'desc1Width': 0,
        'desc1Height': 0,
        'desc1Layers': 0,
        'desc1Format': 0,
        'desc1UsageSampled': false,
        'hasAfterImport1': false,
        'nullFenceRelease1': 'not_run',
        'hasAfterNullFenceRelease1': false,
        'nullFenceDoubleRelease1': 'not_run',
        'import2': 'not_run',
        'handle2': 0,
        'desc2Width': 0,
        'desc2Height': 0,
        'desc2Layers': 0,
        'desc2Format': 0,
        'desc2UsageSampled': false,
        'hasAfterImport2': false,
        'release2': 'not_run',
        'release2Fence': -1,
        'hasAfterRelease2': false,
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_release_null_fence_output_contract_release_fence_optional_no_render_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final bufferDescribe = payload['bufferDescribe'];
    final bufferWidth = (payload['bufferWidth'] as num?)?.toInt() ?? 0;
    final bufferHeight = (payload['bufferHeight'] as num?)?.toInt() ?? 0;
    final bufferLayers = (payload['bufferLayers'] as num?)?.toInt() ?? 0;
    final bufferFormat = (payload['bufferFormat'] as num?)?.toInt() ?? 0;
    final bufferUsageSampled = payload['bufferUsageSampled'] == true;
    final initialize = payload['initialize'];
    final import1 = payload['import1'];
    final handle1 = (payload['handle1'] as num?)?.toInt() ?? 0;
    final desc1Width = (payload['desc1Width'] as num?)?.toInt() ?? 0;
    final desc1Height = (payload['desc1Height'] as num?)?.toInt() ?? 0;
    final desc1Layers = (payload['desc1Layers'] as num?)?.toInt() ?? 0;
    final desc1Format = (payload['desc1Format'] as num?)?.toInt() ?? 0;
    final desc1UsageSampled = payload['desc1UsageSampled'] == true;
    final hasAfterImport1 = payload['hasAfterImport1'] == true;
    final nullFenceRelease1 = payload['nullFenceRelease1'];
    final hasAfterNullFenceRelease1 =
        payload['hasAfterNullFenceRelease1'] == true;
    final nullFenceDoubleRelease1 = payload['nullFenceDoubleRelease1'];
    final import2 = payload['import2'];
    final handle2 = (payload['handle2'] as num?)?.toInt() ?? 0;
    final desc2Width = (payload['desc2Width'] as num?)?.toInt() ?? 0;
    final desc2Height = (payload['desc2Height'] as num?)?.toInt() ?? 0;
    final desc2Layers = (payload['desc2Layers'] as num?)?.toInt() ?? 0;
    final desc2Format = (payload['desc2Format'] as num?)?.toInt() ?? 0;
    final desc2UsageSampled = payload['desc2UsageSampled'] == true;
    final hasAfterImport2 = payload['hasAfterImport2'] == true;
    final release2 = payload['release2'];
    final release2Fence = (payload['release2Fence'] as num?)?.toInt() ?? -1;
    final hasAfterRelease2 = payload['hasAfterRelease2'] == true;
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
        bufferWidth == 64 &&
        bufferHeight == 64 &&
        bufferLayers == 1 &&
        bufferFormat == 1 &&
        bufferUsageSampled &&
        (initialize == 'success' || initialize == true) &&
        (import1 == 'success' || import1 == true) &&
        handle1 > 0 &&
        desc1Width == 64 &&
        desc1Height == 64 &&
        desc1Layers == 1 &&
        desc1Format == 1 &&
        desc1UsageSampled &&
        hasAfterImport1 &&
        (nullFenceRelease1 == 'success' || nullFenceRelease1 == true) &&
        !hasAfterNullFenceRelease1 &&
        (nullFenceDoubleRelease1 == 'rejected_as_expected' ||
            nullFenceDoubleRelease1 == true) &&
        (import2 == 'success' || import2 == true) &&
        handle2 > 0 &&
        desc2Width == 64 &&
        desc2Height == 64 &&
        desc2Layers == 1 &&
        desc2Format == 1 &&
        desc2UsageSampled &&
        hasAfterImport2 &&
        (release2 == 'success' || release2 == true) &&
        release2Fence >= -1 &&
        !hasAfterRelease2 &&
        (shutdown == 'success' || shutdown == true) &&
        (idempotentShutdown == 'success' || idempotentShutdown == true) &&
        proofBoundary ==
            'gles_release_null_fence_output_contract_release_fence_optional_no_render_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_RELEASE_NULL_FENCE_UNIT_AL_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_RELEASE_NULL_FENCE_UNIT_AL_PHYSICAL_PASS'
          : 'ANDROID_GLES_RELEASE_NULL_FENCE_UNIT_AL_PHYSICAL_FAIL',
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
