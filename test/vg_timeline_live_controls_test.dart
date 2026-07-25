// vg_timeline_live_controls_test.dart
// Vanguard Media Engine — Audio Track Interaction Programme S-P1
//
// Unit tests for VGTimelineLiveControls.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> log = [];
  late MethodChannel mockChannel;

  setUp(() {
    log.clear();
    mockChannel = const MethodChannel('vanguard_media_engine_test_channel');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
      log.add(call);
      if (call.method == 'timeline_setFilterChain') {
        final args = call.arguments as Map<Object?, Object?>?;
        final textureId = args?['textureId'] as int?;
        if (textureId == 991) {
          throw PlatformException(
            code: 'NO_TIMELINE',
            message: 'No active timeline target',
          );
        } else if (textureId == 992) {
          throw PlatformException(
            code: 'STALE_TIMELINE',
            message: 'Stale textureId',
          );
        } else if (textureId == 993) {
          throw PlatformException(
            code: 'UNKNOWN_FILTER',
            message: 'Unknown filter type',
          );
        }
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mockChannel, null);
  });

  group('VGTimelineLiveControls Dart Unit Tests', () {
    test('1. Correct timeline_setFilterChain route and serialized payload', () async {
      final controls = VGTimelineLiveControls(channel: mockChannel);
      await controls.setFilterChain(
        textureId: 42,
        filters: [VGFilterSpecs.lut(intensity: 0.7)],
      );

      expect(log.length, equals(1));
      expect(log.first.method, equals('timeline_setFilterChain'));

      final args = log.first.arguments as Map<Object?, Object?>;
      expect(args['textureId'], equals(42));

      final filters = args['filters'] as List<Object?>;
      expect(filters.length, equals(1));

      final spec = filters.first as Map<Object?, Object?>;
      expect(spec['type'], equals('lut'));
      expect(spec['enabled'], isTrue);
      expect(spec['parameters'], equals({'intensity': 0.7}));
    });

    test('2. Ordered multi-filter serialization', () async {
      final controls = VGTimelineLiveControls(channel: mockChannel);
      await controls.setFilterChain(
        textureId: 100,
        filters: [
          VGFilterSpecs.lut(intensity: 0.5),
          VGFilterSpecs.beauty(intensity: 0.8, radius: 3.0),
          VGFilterSpecs.segmentation(),
        ],
      );

      expect(log.length, equals(1));
      final args = log.first.arguments as Map<Object?, Object?>;
      expect(args['textureId'], equals(100));

      final filters = args['filters'] as List<Object?>;
      expect(filters.length, equals(3));

      final spec0 = filters[0] as Map<Object?, Object?>;
      expect(spec0['type'], equals('lut'));
      expect(spec0['parameters'], equals({'intensity': 0.5}));

      final spec1 = filters[1] as Map<Object?, Object?>;
      expect(spec1['type'], equals('beauty'));
      expect(spec1['parameters'], equals({'intensity': 0.8, 'radius': 3.0}));

      final spec2 = filters[2] as Map<Object?, Object?>;
      expect(spec2['type'], equals('segmentation'));
    });

    test('3. Empty filter list is transmitted unchanged for clearing', () async {
      final controls = VGTimelineLiveControls(channel: mockChannel);
      await controls.setFilterChain(textureId: 7, filters: []);

      expect(log.length, equals(1));
      final args = log.first.arguments as Map<Object?, Object?>;
      expect(args['textureId'], equals(7));

      final filters = args['filters'] as List<Object?>;
      expect(filters, isEmpty);
    });

    test('4. Negative textureId throws PlatformException(code: INVALID_ARG) before any channel call', () async {
      final controls = VGTimelineLiveControls(channel: mockChannel);

      try {
        await controls.setFilterChain(
          textureId: -1,
          filters: [VGFilterSpecs.lut()],
        );
        fail('Expected PlatformException for negative textureId');
      } on PlatformException catch (e) {
        expect(e.code, equals('INVALID_ARG'));
        expect(e.message, contains('textureId must be non-negative'));
      }

      // Must NOT invoke the channel
      expect(log, isEmpty);
    });

    test('5. assertValid() rejects an unknown filter in test/debug mode', () async {
      final controls = VGTimelineLiveControls(channel: mockChannel);
      const invalidSpec = VGFilterSpec(type: 'invalid_custom_filter');

      expect(
        () async => await controls.setFilterChain(
          textureId: 1,
          filters: [invalidSpec],
        ),
        throwsA(isA<AssertionError>()),
      );

      // Must NOT invoke the channel
      expect(log, isEmpty);
    });

    test('6. Native NO_TIMELINE, STALE_TIMELINE, and UNKNOWN_FILTER PlatformExceptions propagate unchanged', () async {
      final controls = VGTimelineLiveControls(channel: mockChannel);

      // NO_TIMELINE
      try {
        await controls.setFilterChain(
          textureId: 991,
          filters: [VGFilterSpecs.lut()],
        );
        fail('Expected PlatformException NO_TIMELINE');
      } on PlatformException catch (e) {
        expect(e.code, equals('NO_TIMELINE'));
      }

      // STALE_TIMELINE
      try {
        await controls.setFilterChain(
          textureId: 992,
          filters: [VGFilterSpecs.lut()],
        );
        fail('Expected PlatformException STALE_TIMELINE');
      } on PlatformException catch (e) {
        expect(e.code, equals('STALE_TIMELINE'));
      }

      // UNKNOWN_FILTER
      try {
        await controls.setFilterChain(
          textureId: 993,
          filters: [VGFilterSpecs.lut()],
        );
        fail('Expected PlatformException UNKNOWN_FILTER');
      } on PlatformException catch (e) {
        expect(e.code, equals('UNKNOWN_FILTER'));
      }
    });

    test('7. Injected MethodChannel is used', () async {
      final customChannel = const MethodChannel('custom_vanguard_channel');
      final customLog = <MethodCall>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(customChannel, (MethodCall call) async {
        customLog.add(call);
        return null;
      });

      final controls = VGTimelineLiveControls(channel: customChannel);
      await controls.setFilterChain(textureId: 5, filters: []);

      expect(customLog.length, equals(1));
      expect(customLog.first.method, equals('timeline_setFilterChain'));
      expect(log, isEmpty);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(customChannel, null);
    });

    test('8. No unexpected second channel invocation', () async {
      final controls = VGTimelineLiveControls(channel: mockChannel);

      await controls.setFilterChain(textureId: 10, filters: []);
      expect(log.length, equals(1));

      await controls.setFilterChain(
        textureId: 10,
        filters: [VGFilterSpecs.lut()],
      );
      expect(log.length, equals(2));
    });
  });
}
