// Copyright (c) Connects — Vanguard Phase 1.
// Unit and contract tests for public Dart backend capability diagnostics client.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
  });

  // ---------------------------------------------------------------------------
  // 1. VGRenderBackend Enum Parser
  // ---------------------------------------------------------------------------
  group('VGRenderBackend', () {
    test('fromRaw correctly maps integer codes to enum variants', () {
      expect(VGRenderBackend.fromRaw(0), equals(VGRenderBackend.vulkan));
      expect(VGRenderBackend.fromRaw(1), equals(VGRenderBackend.gles));
      expect(VGRenderBackend.fromRaw(2), equals(VGRenderBackend.unavailable));
      expect(VGRenderBackend.fromRaw(3), equals(VGRenderBackend.unavailable));
      expect(VGRenderBackend.fromRaw(-1), equals(VGRenderBackend.unavailable));
      expect(VGRenderBackend.fromRaw(99), equals(VGRenderBackend.unavailable));
      expect(
        VGRenderBackend.fromRaw(null),
        equals(VGRenderBackend.unavailable),
      );
    });

    test('fromValue parses ints, strings, and enum values defensively', () {
      expect(VGRenderBackend.fromValue(0), equals(VGRenderBackend.vulkan));
      expect(VGRenderBackend.fromValue(1), equals(VGRenderBackend.gles));
      expect(VGRenderBackend.fromValue(2), equals(VGRenderBackend.unavailable));
      expect(VGRenderBackend.fromValue('0'), equals(VGRenderBackend.vulkan));
      expect(VGRenderBackend.fromValue('1'), equals(VGRenderBackend.gles));
      expect(
        VGRenderBackend.fromValue('2'),
        equals(VGRenderBackend.unavailable),
      );
      expect(
        VGRenderBackend.fromValue('vulkan'),
        equals(VGRenderBackend.vulkan),
      );
      expect(VGRenderBackend.fromValue('gles'), equals(VGRenderBackend.gles));
      expect(
        VGRenderBackend.fromValue('unavailable'),
        equals(VGRenderBackend.unavailable),
      );
      expect(
        VGRenderBackend.fromValue('unknown_str'),
        equals(VGRenderBackend.unavailable),
      );
      expect(
        VGRenderBackend.fromValue(VGRenderBackend.vulkan),
        equals(VGRenderBackend.vulkan),
      );
      expect(
        VGRenderBackend.fromValue(null),
        equals(VGRenderBackend.unavailable),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Report and Disabled Flags Parsing
  // ---------------------------------------------------------------------------
  group('VGBackendCapabilityReport & VGDisabledCapabilityFlags Parsing', () {
    test(
      'full Vulkan pass report parsing and no major disabled flags except isGlesPrivateAhbImportDisabled when false is returned',
      () {
        final rawMap = <Object?, Object?>{
          'pass': true,
          'vulkanSupported': true,
          'glesSupported': true,
          'selectedBackend': 0,
          'fallbackReason': 'none',
          'gpuVendor': 'Qualcomm',
          'gpuRenderer': 'Adreno (TM) 740',
          'vendorId': 0x5143,
          'deviceId': 0x0740,
          'apiVersion': 4198400,
          'vulkanDriverVersion': 512520000,
          'profileGateStatus': 'avp2022_partial_pass',
          'blacklistStatus': 'not_blacklisted',
          'decodedFramePreferredPath': 'vulkan_primary',
          'glesDecodedSurfaceTextureOesSupported': true,
          'glesPrivateAhbImportSupported': false,
          'glesPrivateAhbImportStatus':
              'deferred_ahb_import_unsupported_format',
          'glesDecodedFallbackPolicy':
              'surface_texture_oes_without_private_ahb_import',
          'customTelemetryKey': 'preserved_data',
        };

        final report = VGBackendCapabilityReport.fromMap(rawMap);

        expect(report.pass, isTrue);
        expect(report.vulkanSupported, isTrue);
        expect(report.glesSupported, isTrue);
        expect(report.selectedBackend, equals(VGRenderBackend.vulkan));
        expect(report.isVulkanSelected, isTrue);
        expect(report.isGlesSelected, isFalse);
        expect(report.isUnavailable, isFalse);
        expect(report.isVulkanUsable, isTrue);
        expect(report.fallbackReason, equals('none'));
        expect(report.gpuVendor, equals('Qualcomm'));
        expect(report.gpuRenderer, equals('Adreno (TM) 740'));
        expect(report.vendorId, equals(0x5143));
        expect(report.deviceId, equals(0x0740));
        expect(report.apiVersion, equals(4198400));
        expect(report.vulkanDriverVersion, equals(512520000));
        expect(report.profileGateStatus, equals('avp2022_partial_pass'));
        expect(report.blacklistStatus, equals('not_blacklisted'));
        expect(report.decodedFramePreferredPath, equals('vulkan_primary'));
        expect(report.glesDecodedSurfaceTextureOesSupported, isTrue);
        expect(report.glesPrivateAhbImportSupported, isFalse);
        expect(
          report.glesPrivateAhbImportStatus,
          equals('deferred_ahb_import_unsupported_format'),
        );
        expect(
          report.glesDecodedFallbackPolicy,
          equals('surface_texture_oes_without_private_ahb_import'),
        );
        expect(
          report.diagnostics['customTelemetryKey'],
          equals('preserved_data'),
        );

        // Disabled flags verification: no major disabled flags except isGlesPrivateAhbImportDisabled
        final flags = report.disabledFlags;
        expect(flags.isVulkanDisabled, isFalse);
        expect(flags.isGlesDisabled, isFalse);
        expect(flags.isGlesFallbackActive, isFalse);
        expect(flags.isGpuDriverBlacklisted, isFalse);
        expect(flags.isAvp2022ProfileGateFailed, isFalse);
        expect(flags.isGlesPrivateAhbImportDisabled, isTrue);
        expect(flags.isGlesDecodedSurfaceTextureOesDisabled, isFalse);
        expect(flags.isRenderingUnavailable, isFalse);
        expect(flags.disabledFeatureKeys, equals(['gles_private_ahb_import']));
      },
    );

    test(
      'GLES fallback/blacklisted/failed-profile report parsing with disabled keys',
      () {
        // Scenario A: GLES fallback due to missing instance extensions
        final fallbackMap = <Object?, Object?>{
          'pass': false,
          'vulkanSupported': false,
          'glesSupported': true,
          'selectedBackend': 1,
          'fallbackReason': 'missing_required_instance_extensions',
          'gpuVendor': 'ARM',
          'gpuRenderer': 'Mali-G78',
          'vendorId': 0x13b5,
          'deviceId': 0x0100,
          'apiVersion': 4194304,
          'vulkanDriverVersion': 100,
          'profileGateStatus': 'failed_instance_extensions',
          'blacklistStatus': 'not_evaluated',
          'decodedFramePreferredPath': 'gles_surface_texture_oes',
          'glesDecodedSurfaceTextureOesSupported': true,
          'glesPrivateAhbImportSupported': false,
          'glesPrivateAhbImportStatus':
              'deferred_ahb_import_unsupported_format',
          'glesDecodedFallbackPolicy':
              'surface_texture_oes_without_private_ahb_import',
        };

        final fallbackReport = VGBackendCapabilityReport.fromMap(fallbackMap);
        expect(fallbackReport.selectedBackend, equals(VGRenderBackend.gles));
        expect(fallbackReport.isGlesSelected, isTrue);
        expect(fallbackReport.isVulkanSelected, isFalse);
        expect(fallbackReport.isGlesUsable, isTrue);

        final fallbackFlags = fallbackReport.disabledFlags;
        expect(fallbackFlags.isVulkanDisabled, isTrue);
        expect(fallbackFlags.isGlesDisabled, isFalse);
        expect(fallbackFlags.isGlesFallbackActive, isTrue);
        expect(fallbackFlags.isGpuDriverBlacklisted, isFalse);
        expect(fallbackFlags.isAvp2022ProfileGateFailed, isTrue);
        expect(fallbackFlags.isGlesPrivateAhbImportDisabled, isTrue);
        expect(fallbackFlags.isGlesDecodedSurfaceTextureOesDisabled, isFalse);
        expect(fallbackFlags.isRenderingUnavailable, isFalse);
        expect(
          fallbackFlags.disabledFeatureKeys,
          containsAll(<String>[
            'vulkan',
            'gles_fallback',
            'avp2022_profile_gate_failed',
            'gles_private_ahb_import',
          ]),
        );

        // Scenario B: Blacklisted GPU driver
        final blacklistedMap = <Object?, Object?>{
          'pass': false,
          'vulkanSupported': false,
          'glesSupported': true,
          'selectedBackend': 1,
          'fallbackReason': 'blacklisted_gpu_driver',
          'gpuVendor': 'Qualcomm',
          'gpuRenderer': 'Adreno 540',
          'vendorId': 0x5143,
          'deviceId': 0x0540,
          'apiVersion': 4198400,
          'vulkanDriverVersion': 50,
          'profileGateStatus': 'failed_blacklisted',
          'blacklistStatus': 'blacklisted_match',
          'decodedFramePreferredPath': 'gles_surface_texture_oes',
          'glesDecodedSurfaceTextureOesSupported': true,
          'glesPrivateAhbImportSupported': false,
          'glesPrivateAhbImportStatus':
              'deferred_ahb_import_unsupported_format',
          'glesDecodedFallbackPolicy':
              'surface_texture_oes_without_private_ahb_import',
        };

        final blacklistedReport = VGBackendCapabilityReport.fromMap(
          blacklistedMap,
        );
        final blacklistedFlags = blacklistedReport.disabledFlags;
        expect(blacklistedFlags.isGpuDriverBlacklisted, isTrue);
        expect(blacklistedFlags.isAvp2022ProfileGateFailed, isTrue);
        expect(blacklistedFlags.isVulkanDisabled, isTrue);
        expect(blacklistedFlags.isGlesFallbackActive, isTrue);
        expect(
          blacklistedFlags.disabledFeatureKeys,
          contains('gpu_driver_blacklisted'),
        );
        expect(
          blacklistedFlags.disabledFeatureKeys,
          contains('avp2022_profile_gate_failed'),
        );

        // Scenario C: Failed profile gate (device extensions failure)
        final failedProfileMap = <Object?, Object?>{
          'pass': false,
          'vulkanSupported': false,
          'glesSupported': true,
          'selectedBackend': 1,
          'fallbackReason': 'missing_required_device_extensions',
          'gpuVendor': 'IMG',
          'gpuRenderer': 'PowerVR',
          'vendorId': 0x1010,
          'deviceId': 0x0001,
          'apiVersion': 4198400,
          'vulkanDriverVersion': 1,
          'profileGateStatus': 'failed_device_extensions',
          'blacklistStatus': 'not_evaluated',
          'decodedFramePreferredPath': 'gles_surface_texture_oes',
          'glesDecodedSurfaceTextureOesSupported': true,
          'glesPrivateAhbImportSupported': false,
        };

        final failedProfileReport = VGBackendCapabilityReport.fromMap(
          failedProfileMap,
        );
        expect(
          failedProfileReport.disabledFlags.isAvp2022ProfileGateFailed,
          isTrue,
        );
        expect(
          failedProfileReport.disabledFlags.disabledFeatureKeys,
          contains('avp2022_profile_gate_failed'),
        );

        // Scenario D: Rendering completely unavailable
        final unavailableMap = <Object?, Object?>{
          'pass': false,
          'vulkanSupported': false,
          'glesSupported': false,
          'selectedBackend': 2,
          'fallbackReason': 'no_render_backend_available',
          'gpuVendor': '',
          'gpuRenderer': '',
          'vendorId': 0,
          'deviceId': 0,
          'apiVersion': 0,
          'vulkanDriverVersion': 0,
          'profileGateStatus': 'unsupported',
          'blacklistStatus': 'not_evaluated',
          'decodedFramePreferredPath': 'unknown',
          'glesDecodedSurfaceTextureOesSupported': false,
          'glesPrivateAhbImportSupported': false,
        };

        final unavailableReport = VGBackendCapabilityReport.fromMap(
          unavailableMap,
        );
        expect(
          unavailableReport.selectedBackend,
          equals(VGRenderBackend.unavailable),
        );
        expect(unavailableReport.isUnavailable, isTrue);
        expect(unavailableReport.disabledFlags.isRenderingUnavailable, isTrue);
        expect(unavailableReport.disabledFlags.isVulkanDisabled, isTrue);
        expect(unavailableReport.disabledFlags.isGlesDisabled, isTrue);
        expect(
          unavailableReport.disabledFlags.disabledFeatureKeys,
          containsAll(<String>['vulkan', 'gles', 'rendering_unavailable']),
        );
      },
    );

    test(
      'defensive parsing for string numbers, missing booleans, unknown selectedBackend',
      () {
        final malformedMap = <Object?, Object?>{
          'pass': 'true',
          'vulkanSupported': 'false',
          'glesSupported': 1, // num truthy
          'selectedBackend': 999, // unknown backend code
          'fallbackReason': null,
          'vendorId': '0x5143', // hex string
          'deviceId': '1856', // decimal string
          'apiVersion': '4198400',
          'vulkanDriverVersion': '512520000',
          'profileGateStatus': null,
          'blacklistStatus': null,
          'glesDecodedSurfaceTextureOesSupported': 'false',
          'glesPrivateAhbImportSupported': null, // missing -> false
        };

        final report = VGBackendCapabilityReport.fromMap(malformedMap);

        expect(report.pass, isTrue);
        expect(report.vulkanSupported, isFalse);
        expect(report.glesSupported, isTrue);
        expect(report.selectedBackend, equals(VGRenderBackend.unavailable));
        expect(report.fallbackReason, equals(''));
        expect(report.vendorId, equals(0x5143));
        expect(report.deviceId, equals(1856));
        expect(report.apiVersion, equals(4198400));
        expect(report.vulkanDriverVersion, equals(512520000));
        expect(report.profileGateStatus, equals(''));
        expect(report.blacklistStatus, equals(''));
        expect(report.glesDecodedSurfaceTextureOesSupported, isFalse);
        expect(report.glesPrivateAhbImportSupported, isFalse);
        expect(report.disabledFlags.isRenderingUnavailable, isTrue);
      },
    );

    test('toMap() preserves diagnostics and disabled flags', () {
      final original = VGBackendCapabilityReport.fromMap(<Object?, Object?>{
        'pass': true,
        'vulkanSupported': true,
        'glesSupported': true,
        'selectedBackend': 0,
        'fallbackReason': 'none',
        'gpuVendor': 'Qualcomm',
        'gpuRenderer': 'Adreno 740',
        'vendorId': 0x5143,
        'deviceId': 0x0740,
        'apiVersion': 4198400,
        'vulkanDriverVersion': 512520000,
        'profileGateStatus': 'avp2022_partial_pass',
        'blacklistStatus': 'not_blacklisted',
        'decodedFramePreferredPath': 'vulkan_primary',
        'glesDecodedSurfaceTextureOesSupported': true,
        'glesPrivateAhbImportSupported': false,
        'glesPrivateAhbImportStatus': 'deferred',
        'glesDecodedFallbackPolicy': 'oes',
        'nestedTelemetry': {'clock': 1000, 'freq': 'max'},
      });

      final map = original.toMap();

      expect(map['pass'], isTrue);
      expect(map['vulkanSupported'], isTrue);
      expect(map['glesSupported'], isTrue);
      expect(map['selectedBackend'], equals(0));
      expect(map['fallbackReason'], equals('none'));
      expect(map['gpuVendor'], equals('Qualcomm'));
      expect(map['gpuRenderer'], equals('Adreno 740'));
      expect(map['vendorId'], equals(0x5143));
      expect(map['deviceId'], equals(0x0740));
      expect(map['apiVersion'], equals(4198400));
      expect(map['vulkanDriverVersion'], equals(512520000));
      expect(map['profileGateStatus'], equals('avp2022_partial_pass'));
      expect(map['blacklistStatus'], equals('not_blacklisted'));
      expect(map['decodedFramePreferredPath'], equals('vulkan_primary'));
      expect(map['glesDecodedSurfaceTextureOesSupported'], isTrue);
      expect(map['glesPrivateAhbImportSupported'], isFalse);
      expect(map['glesPrivateAhbImportStatus'], equals('deferred'));
      expect(map['glesDecodedFallbackPolicy'], equals('oes'));

      // Disabled flags preserved
      expect(map['disabledFlags'], isA<Map<String, Object?>>());
      final disabledFlagsMap = map['disabledFlags'] as Map<String, Object?>;
      expect(disabledFlagsMap['isVulkanDisabled'], isFalse);
      expect(disabledFlagsMap['isGlesPrivateAhbImportDisabled'], isTrue);
      expect(
        disabledFlagsMap['disabledFeatureKeys'],
        equals(['gles_private_ahb_import']),
      );

      // Raw diagnostics preserved
      expect(map['diagnostics'], isA<Map<String, Object?>>());
      final diagnostics = map['diagnostics'] as Map<String, Object?>;
      expect(
        diagnostics['nestedTelemetry'],
        equals({'clock': 1000, 'freq': 'max'}),
      );

      // Deserializing from toMap() yields an equivalent report
      final reconstructed = VGBackendCapabilityReport.fromMap(map);
      expect(reconstructed.pass, equals(original.pass));
      expect(reconstructed.selectedBackend, equals(original.selectedBackend));
      expect(reconstructed.disabledFlags, equals(original.disabledFlags));
      expect(
        reconstructed.disabledFlags.disabledFeatureKeys,
        equals(original.disabledFlags.disabledFeatureKeys),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 3. VGBackendCapabilityClient MethodChannel Contract
  // ---------------------------------------------------------------------------
  group('VGBackendCapabilityClient MethodChannel', () {
    test(
      'mock MethodChannel invokes exactly runAndroidDagPhase2QCapabilityProbe and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'runAndroidDagPhase2QCapabilityProbe') {
            return <Object?, Object?>{
              'pass': true,
              'vulkanSupported': true,
              'glesSupported': true,
              'selectedBackend': 0,
              'fallbackReason': 'none',
              'gpuVendor': 'Qualcomm',
              'gpuRenderer': 'Adreno (TM) 740',
              'vendorId': 0x5143,
              'deviceId': 0x0740,
              'apiVersion': 4198400,
              'vulkanDriverVersion': 512520000,
              'profileGateStatus': 'avp2022_partial_pass',
              'blacklistStatus': 'not_blacklisted',
              'decodedFramePreferredPath': 'vulkan_primary',
              'glesDecodedSurfaceTextureOesSupported': true,
              'glesPrivateAhbImportSupported': false,
              'glesPrivateAhbImportStatus':
                  'deferred_ahb_import_unsupported_format',
              'glesDecodedFallbackPolicy':
                  'surface_texture_oes_without_private_ahb_import',
            };
          }
          return null;
        });

        final client = VGBackendCapabilityClient(channel: channel);
        final report = await client.probeBackendCapabilities();

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('runAndroidDagPhase2QCapabilityProbe'),
        );
        expect(recordedCall!.arguments, isNull);

        expect(report.pass, isTrue);
        expect(report.vulkanSupported, isTrue);
        expect(report.glesSupported, isTrue);
        expect(report.selectedBackend, equals(VGRenderBackend.vulkan));
        expect(report.isVulkanSelected, isTrue);
        expect(report.isGlesSelected, isFalse);
        expect(report.disabledFlags.isVulkanDisabled, isFalse);
        expect(report.disabledFlags.isGlesPrivateAhbImportDisabled, isTrue);
      },
    );

    test('non-map response returns typed failure report', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runAndroidDagPhase2QCapabilityProbe') {
          return 'unexpected_string_not_a_map';
        }
        return null;
      });

      final client = VGBackendCapabilityClient(channel: channel);
      final report = await client.probeBackendCapabilities();

      expect(report.pass, isFalse);
      expect(report.selectedBackend, equals(VGRenderBackend.unavailable));
      expect(report.fallbackReason, equals('invalid_response:String'));
      expect(report.disabledFlags.isRenderingUnavailable, isTrue);
    });

    test('MissingPluginException returns unsupported report', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw MissingPluginException('No implementation found');
      });

      final client = VGBackendCapabilityClient(channel: channel);
      final report = await client.probeBackendCapabilities();

      expect(report.pass, isFalse);
      expect(report.vulkanSupported, isFalse);
      expect(report.glesSupported, isFalse);
      expect(report.selectedBackend, equals(VGRenderBackend.unavailable));
      expect(report.fallbackReason, equals('unsupported_platform'));
      expect(report.profileGateStatus, equals('unsupported_platform'));
      expect(report.isUnavailable, isTrue);
      expect(report.disabledFlags.isRenderingUnavailable, isTrue);
      expect(report.disabledFlags.isVulkanDisabled, isTrue);
      expect(report.disabledFlags.isGlesDisabled, isTrue);
      expect(
        report.disabledFlags.disabledFeatureKeys,
        containsAll(<String>['vulkan', 'gles', 'rendering_unavailable']),
      );
    });

    test(
      'PlatformException or thrown StateError returns failure report',
      () async {
        // Test PlatformException
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NATIVE_PROBE_ERROR',
            message: 'VkInstance creation failed catastrophically',
          );
        });

        final client = VGBackendCapabilityClient(channel: channel);
        final reportPlatformException = await client.probeBackendCapabilities();

        expect(reportPlatformException.pass, isFalse);
        expect(
          reportPlatformException.selectedBackend,
          equals(VGRenderBackend.unavailable),
        );
        expect(
          reportPlatformException.fallbackReason,
          contains('exception:NATIVE_PROBE_ERROR'),
        );
        expect(
          reportPlatformException.disabledFlags.isRenderingUnavailable,
          isTrue,
        );

        // Test thrown StateError (generic error)
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw StateError('Simulated unexpected state failure');
        });

        final reportStateError = await client.probeBackendCapabilities();
        expect(reportStateError.pass, isFalse);
        expect(
          reportStateError.selectedBackend,
          equals(VGRenderBackend.unavailable),
        );
        expect(
          reportStateError.fallbackReason,
          contains('Simulated unexpected state failure'),
        );
        expect(reportStateError.disabledFlags.isRenderingUnavailable, isTrue);
      },
    );
  });
}
