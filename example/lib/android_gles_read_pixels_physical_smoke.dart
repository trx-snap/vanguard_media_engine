import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesReadPixelsPhysicalSmokeApp());
}

class AndroidGlesReadPixelsPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesReadPixelsPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesReadPixelsPhysicalSmokeApp> createState() =>
      _AndroidGlesReadPixelsPhysicalSmokeAppState();
}

class _AndroidGlesReadPixelsPhysicalSmokeAppState
    extends State<AndroidGlesReadPixelsPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES diagnostic read-pixels Unit AB physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ABGlesReadPixelsSmoke',
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
        'preInitRead': 'not_run',
        'preInitLastError': '',
        'initialize': 'not_run',
        'preAttachRead': 'not_run',
        'preAttachLastError': '',
        'attach': 'exception:${error.runtimeType}',
        'hasSurfaceAfterAttach': false,
        'surfaceKindAfterAttach': 'none',
        'widthAfterAttach': 0,
        'heightAfterAttach': 0,
        'nullRead': 'not_run',
        'nullReadLastError': '',
        'zeroRead': 'not_run',
        'zeroReadLastError': '',
        'smallCapacityRead': 'not_run',
        'smallCapacityLastError': '',
        'outOfBoundsRead': 'not_run',
        'outOfBoundsLastError': '',
        'directClearForReadback': 'not_run',
        'centerRead': 'not_run',
        'centerReadLastError': '',
        'centerR': 0,
        'centerG': 0,
        'centerB': 0,
        'centerA': 0,
        'centerPixelMatches': false,
        'fullRead': 'not_run',
        'fullReadLastError': '',
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'postDetachRead': 'not_run',
        'postDetachLastError': '',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_diagnostic_read_pixels_rgba_window_surface_no_yuv_no_fence_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final preInitRead = (payload['preInitRead'] as String?) ?? '';
    final preInitLastError = (payload['preInitLastError'] as String?) ?? '';
    final initialize = (payload['initialize'] as String?) ?? '';
    final preAttachRead = (payload['preAttachRead'] as String?) ?? '';
    final preAttachLastError = (payload['preAttachLastError'] as String?) ?? '';
    final attach = (payload['attach'] as String?) ?? '';
    final hasSurfaceAfterAttach = payload['hasSurfaceAfterAttach'] == true;
    final surfaceKindAfterAttach =
        (payload['surfaceKindAfterAttach'] as String?) ?? '';
    final widthAfterAttach =
        (payload['widthAfterAttach'] as num?)?.toInt() ?? 0;
    final heightAfterAttach =
        (payload['heightAfterAttach'] as num?)?.toInt() ?? 0;
    final nullRead = (payload['nullRead'] as String?) ?? '';
    final nullReadLastError = (payload['nullReadLastError'] as String?) ?? '';
    final zeroRead = (payload['zeroRead'] as String?) ?? '';
    final zeroReadLastError = (payload['zeroReadLastError'] as String?) ?? '';
    final smallCapacityRead = (payload['smallCapacityRead'] as String?) ?? '';
    final smallCapacityLastError =
        (payload['smallCapacityLastError'] as String?) ?? '';
    final outOfBoundsRead = (payload['outOfBoundsRead'] as String?) ?? '';
    final outOfBoundsLastError =
        (payload['outOfBoundsLastError'] as String?) ?? '';
    final directClearForReadback =
        (payload['directClearForReadback'] as String?) ?? '';
    final centerRead = (payload['centerRead'] as String?) ?? '';
    final centerReadLastError =
        (payload['centerReadLastError'] as String?) ?? '';
    final centerPixelMatches = payload['centerPixelMatches'] == true;
    final fullRead = (payload['fullRead'] as String?) ?? '';
    final fullReadLastError = (payload['fullReadLastError'] as String?) ?? '';
    final detach = (payload['detach'] as String?) ?? '';
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final postDetachRead = (payload['postDetachRead'] as String?) ?? '';
    final postDetachLastError =
        (payload['postDetachLastError'] as String?) ?? '';
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        preInitRead == 'rejected_as_expected' &&
        preInitLastError == 'backend_not_initialized' &&
        initialize == 'success' &&
        preAttachRead == 'rejected_as_expected' &&
        preAttachLastError == 'no_surface_attached' &&
        attach == 'success' &&
        hasSurfaceAfterAttach &&
        surfaceKindAfterAttach == 'window' &&
        widthAfterAttach == 64 &&
        heightAfterAttach == 64 &&
        nullRead == 'rejected_as_expected' &&
        nullReadLastError == 'diagnostic_read_pixels_invalid_argument' &&
        zeroRead == 'rejected_as_expected' &&
        zeroReadLastError == 'diagnostic_read_pixels_invalid_dimensions' &&
        smallCapacityRead == 'rejected_as_expected' &&
        smallCapacityLastError == 'diagnostic_read_pixels_capacity_too_small' &&
        outOfBoundsRead == 'rejected_as_expected' &&
        outOfBoundsLastError == 'diagnostic_read_pixels_out_of_bounds' &&
        directClearForReadback == 'success' &&
        centerRead == 'success' &&
        centerReadLastError.isEmpty &&
        centerPixelMatches &&
        fullRead == 'success' &&
        fullReadLastError.isEmpty &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        postDetachRead == 'rejected_as_expected' &&
        postDetachLastError == 'no_surface_attached' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_diagnostic_read_pixels_rgba_window_surface_no_yuv_no_fence_no_product';

    // ignore: avoid_print
    print('ANDROID_GLES_READ_PIXELS_UNIT_AB_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_READ_PIXELS_UNIT_AB_PHYSICAL_PASS'
          : 'ANDROID_GLES_READ_PIXELS_UNIT_AB_PHYSICAL_FAIL',
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
