import 'dart:async';
import 'package:flutter/services.dart';

class VGDuetVulkanPreviewPresentationSmokeReport {
  final Map<String, dynamic> _raw;

  VGDuetVulkanPreviewPresentationSmokeReport._(this._raw);

  static const String proofBoundaryConstant =
      'native_android_duet_vulkan_preview_presentation_surfaceproducer_ahb_no_readback_diagnostic_only_no_production_preview_no_export';
  static const String passMarker =
      'ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_PASS';
  static const String failMarker =
      'ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_FAIL';

  static const List<String> gateKeys = <String>[
    'argumentValidationOk',
    'surfaceAcquireOk',
    'nativeWindowOk',
    'vulkanSetupOk',
    'swapchainCreateOk',
    'cameraFrameAcquireOk',
    'decoderFrameAcquireOk',
    'cameraImportOk',
    'decoderImportOk',
    'resolveOk',
    'maskUploadOk',
    'blendRenderNoReadbackOk',
    'swapchainPresentOk',
    'resourceReleaseOk',
    'diagnosticTeardownOk',
    'allNativeLanesPass',
  ];

  bool get pass => _raw['pass'] == true;
  bool get isPass => pass;
  String get status => _raw['status']?.toString() ?? (pass ? 'PASS' : 'FAIL');
  bool get isUnsupported => status.toUpperCase() == 'UNSUPPORTED';
  String get marker =>
      _raw['marker']?.toString() ?? (pass ? passMarker : failMarker);
  String get failureReason => _raw['failureReason']?.toString() ?? '';
  String get proofBoundary =>
      _raw['proofBoundary']?.toString() ?? proofBoundaryConstant;
  bool get allNativeLanesPass => _raw['allNativeLanesPass'] == true;

  Map<String, bool> get gates {
    final rawGates = _raw['gates'];
    if (rawGates is Map) {
      return rawGates.map(
        (key, value) => MapEntry(key.toString(), value == true),
      );
    }
    final map = <String, bool>{};
    for (final key in gateKeys) {
      map[key] = _raw[key] == true;
    }
    return map;
  }

  Map<String, dynamic> get details {
    final d = _raw['details'];
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  Map<String, dynamic> get raw => Map<String, dynamic>.from(_raw);

  bool get argumentValidationOk => gates['argumentValidationOk'] == true;
  bool get surfaceAcquireOk => gates['surfaceAcquireOk'] == true;
  bool get nativeWindowOk => gates['nativeWindowOk'] == true;
  bool get vulkanSetupOk => gates['vulkanSetupOk'] == true;
  bool get swapchainCreateOk => gates['swapchainCreateOk'] == true;
  bool get cameraFrameAcquireOk => gates['cameraFrameAcquireOk'] == true;
  bool get decoderFrameAcquireOk => gates['decoderFrameAcquireOk'] == true;
  bool get cameraImportOk => gates['cameraImportOk'] == true;
  bool get decoderImportOk => gates['decoderImportOk'] == true;
  bool get resolveOk => gates['resolveOk'] == true;
  bool get maskUploadOk => gates['maskUploadOk'] == true;
  bool get blendRenderNoReadbackOk => gates['blendRenderNoReadbackOk'] == true;
  bool get swapchainPresentOk => gates['swapchainPresentOk'] == true;
  bool get resourceReleaseOk => gates['resourceReleaseOk'] == true;
  bool get diagnosticTeardownOk => gates['diagnosticTeardownOk'] == true;

  Map<String, dynamic> toMap() => Map<String, dynamic>.unmodifiable(_raw);

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static Future<VGDuetVulkanPreviewPresentationSmokeReport>
  runAndroidDuetVulkanPreviewPresentationSmoke({
    required String clipPath,
    int? surfaceWidth,
    int? surfaceHeight,
    int? maxFrames,
    Duration timeout = const Duration(seconds: 45),
    MethodChannel channel = _defaultChannel,
  }) async {
    try {
      final args = <String, dynamic>{
        'clipPath': clipPath,
        'surfaceWidth': ?surfaceWidth,
        'surfaceHeight': ?surfaceHeight,
        'maxFrames': ?maxFrames,
        'timeoutMs': timeout.inMilliseconds,
      };

      final result = await channel
          .invokeMethod('runAndroidDuetVulkanPreviewPresentationSmoke', args)
          .timeout(timeout);

      if (result is Map) {
        return VGDuetVulkanPreviewPresentationSmokeReport._(
          Map<String, dynamic>.from(result),
        );
      }
      return VGDuetVulkanPreviewPresentationSmokeReport._({
        'pass': false,
        'status': 'FAIL',
        'failureReason': 'invalid_method_result_type',
        'marker': failMarker,
        'proofBoundary': proofBoundaryConstant,
        'allNativeLanesPass': false,
      });
    } on TimeoutException {
      return VGDuetVulkanPreviewPresentationSmokeReport._({
        'pass': false,
        'status': 'FAIL',
        'failureReason': 'dart_timeout',
        'marker': failMarker,
        'proofBoundary': proofBoundaryConstant,
        'allNativeLanesPass': false,
      });
    } catch (e) {
      return VGDuetVulkanPreviewPresentationSmokeReport._({
        'pass': false,
        'status': 'FAIL',
        'failureReason': 'exception_thrown:${e.runtimeType}:$e',
        'marker': failMarker,
        'proofBoundary': proofBoundaryConstant,
        'allNativeLanesPass': false,
      });
    }
  }
}
