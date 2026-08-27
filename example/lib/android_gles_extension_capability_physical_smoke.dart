import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesExtensionCapabilityPhysicalSmokeApp());
}

class AndroidGlesExtensionCapabilityPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesExtensionCapabilityPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesExtensionCapabilityPhysicalSmokeApp> createState() =>
      _AndroidGlesExtensionCapabilityPhysicalSmokeAppState();
}

class _AndroidGlesExtensionCapabilityPhysicalSmokeAppState
    extends State<AndroidGlesExtensionCapabilityPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES extension capability Unit AI physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AIGlesExtensionCapabilitySmoke',
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
        'eglExtensionsAvailable': false,
        'glExtensionsAvailable': false,
        'hasEglAndroidImageNativeBuffer': false,
        'hasEglAndroidGetNativeClientBuffer': false,
        'hasEglKhrImageBase': false,
        'hasEglAndroidNativeFenceSync': false,
        'hasEglKhrFenceSync': false,
        'hasGlOesEglImage': false,
        'hasGlOesEglImageExternal': false,
        'hasGlExtYuvTarget': false,
        'symbolEglGetNativeClientBufferAndroid': false,
        'symbolEglCreateImageKhr': false,
        'symbolEglDestroyImageKhr': false,
        'symbolGlEglImageTargetTexture2DOes': false,
        'symbolEglCreateSyncKhr': false,
        'symbolEglDestroySyncKhr': false,
        'symbolEglDupNativeFenceFdAndroid': false,
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_egl_extension_capability_inventory_no_import_no_render_no_product',
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
    final eglExtensionsAvailable = payload['eglExtensionsAvailable'] == true;
    final glExtensionsAvailable = payload['glExtensionsAvailable'] == true;
    final symbolEglGetNativeClientBufferAndroid =
        payload['symbolEglGetNativeClientBufferAndroid'] == true;
    final symbolEglCreateImageKhr = payload['symbolEglCreateImageKhr'] == true;
    final symbolEglDestroyImageKhr =
        payload['symbolEglDestroyImageKhr'] == true;
    final symbolGlEglImageTargetTexture2DOes =
        payload['symbolGlEglImageTargetTexture2DOes'] == true;
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
        eglExtensionsAvailable &&
        glExtensionsAvailable &&
        symbolEglGetNativeClientBufferAndroid &&
        symbolEglCreateImageKhr &&
        symbolEglDestroyImageKhr &&
        symbolGlEglImageTargetTexture2DOes &&
        (shutdown == 'success' || shutdown == true) &&
        (idempotentShutdown == 'success' || idempotentShutdown == true) &&
        proofBoundary ==
            'gles_egl_extension_capability_inventory_no_import_no_render_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_EXTENSION_CAPABILITY_UNIT_AI_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_EXTENSION_CAPABILITY_UNIT_AI_PHYSICAL_PASS'
          : 'ANDROID_GLES_EXTENSION_CAPABILITY_UNIT_AI_PHYSICAL_FAIL',
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
