import 'dart:async';
import 'package:flutter/services.dart';

class VGDuetVulkanPreviewIngestCombinedSmokeReport {
  final Map<String, dynamic> _raw;

  VGDuetVulkanPreviewIngestCombinedSmokeReport._(this._raw);

  bool get pass => _raw['pass'] == true;
  bool get isPass => pass;
  String get marker =>
      _raw['marker']?.toString() ??
      'ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_PHYSICAL_FAIL';
  String get failureReason =>
      _raw['failureReason']?.toString() ?? 'unknown_error';
  String get proofBoundary =>
      _raw['proofBoundary']?.toString() ?? 'MISSING_PROOF_BOUNDARY';
  Map<String, dynamic> get details => _raw['details'] is Map
      ? Map<String, dynamic>.from(_raw['details'] as Map)
      : {};

  Map<String, dynamic> toMap() => Map.unmodifiable(_raw);

  static const MethodChannel _defaultChannel = MethodChannel(
    "vanguard_media_engine",
  );

  static Future<VGDuetVulkanPreviewIngestCombinedSmokeReport>
  runAndroidDuetVulkanPreviewIngestCombinedSmoke({
    required String clipPath,
    Duration timeout = const Duration(seconds: 45),
    int? maxFrames,
    MethodChannel channel = _defaultChannel,
  }) async {
    try {
      final result = await channel
          .invokeMethod('runAndroidDuetVulkanPreviewIngestCombinedSmoke', {
            'clipPath': clipPath,
            'maxFrames': ?maxFrames,
          })
          .timeout(timeout);

      if (result is Map) {
        return VGDuetVulkanPreviewIngestCombinedSmokeReport._(
          Map<String, dynamic>.from(result),
        );
      }
      return VGDuetVulkanPreviewIngestCombinedSmokeReport._({
        'pass': false,
        'failureReason': 'invalid_method_result_type',
        'marker': 'ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_PHYSICAL_FAIL',
      });
    } on TimeoutException {
      return VGDuetVulkanPreviewIngestCombinedSmokeReport._({
        'pass': false,
        'failureReason': 'dart_timeout',
        'marker': 'ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_PHYSICAL_FAIL',
      });
    } catch (e) {
      return VGDuetVulkanPreviewIngestCombinedSmokeReport._({
        'pass': false,
        'failureReason': 'exception_thrown:${e.runtimeType}',
        'marker': 'ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_PHYSICAL_FAIL',
      });
    }
  }
}
