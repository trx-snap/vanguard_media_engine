// VGAudioRouteSnapshotTests.m
// Vanguard Media Engine — Audio Slice N
//
// Isolation tests for VGAudioRouteSnapshot and VGBuildAudioRouteSnapshot.

#import <XCTest/XCTest.h>
#import "VGAudioRouteSnapshot.h"
#import <AVFoundation/AVFoundation.h>

#if VG_USE_V2_GRAPH

@interface VGAudioRouteSnapshotTests : XCTestCase
@end

@implementation VGAudioRouteSnapshotTests

- (void)test_emptyRouteSnapshot {
    VGAudioRouteSnapshot *snapshot = VGBuildAudioRouteSnapshot(@[], @[], @[]);
    XCTAssertFalse(snapshot.inputAvailable);
    XCTAssertEqualObjects(snapshot.activeInputType, @"none");
    XCTAssertEqualObjects(snapshot.activeInputName, @"");
    XCTAssertEqualObjects(snapshot.activeInputUID, @"");
    XCTAssertNil(snapshot.activeInputDataSourceName);
    XCTAssertEqualObjects(snapshot.availableInputTypes, @[]);
    XCTAssertEqualObjects(snapshot.activeOutputTypes, @[]);
    XCTAssertFalse(snapshot.hasHeadphoneOutput);
    XCTAssertFalse(snapshot.activeInputIsExternal);

    NSDictionary *map = [snapshot toMap];
    XCTAssertEqualObjects(map[@"inputAvailable"], @NO);
    XCTAssertEqualObjects(map[@"activeInputType"], @"none");
    XCTAssertEqualObjects(map[@"hasHeadphoneOutput"], @NO);
    XCTAssertEqualObjects(map[@"activeInputIsExternal"], @NO);
}

- (void)test_builtInMicRouteSnapshot {
    VGPortSnapshot *inputPort = [[VGPortSnapshot alloc] initWithPortType:AVAudioSessionPortBuiltInMic
                                                                portName:@"iPhone Mic"
                                                                     UID:@"mic_1"
                                                  selectedDataSourceName:@"Front"];
    VGPortSnapshot *outputPort = [[VGPortSnapshot alloc] initWithPortType:AVAudioSessionPortBuiltInSpeaker
                                                                 portName:@"Speaker"
                                                                      UID:@"speaker_1"
                                                   selectedDataSourceName:nil];

    VGAudioRouteSnapshot *snapshot = VGBuildAudioRouteSnapshot(@[inputPort], @[outputPort], @[inputPort]);
    XCTAssertTrue(snapshot.inputAvailable);
    XCTAssertEqualObjects(snapshot.activeInputType, @"builtInMic");
    XCTAssertEqualObjects(snapshot.activeInputName, @"iPhone Mic");
    XCTAssertEqualObjects(snapshot.activeInputUID, @"mic_1");
    XCTAssertEqualObjects(snapshot.activeInputDataSourceName, @"Front");
    XCTAssertEqualObjects(snapshot.availableInputTypes, @[@"builtInMic"]);
    XCTAssertEqualObjects(snapshot.activeOutputTypes, @[@"builtInSpeaker"]);
    XCTAssertFalse(snapshot.hasHeadphoneOutput);
    XCTAssertFalse(snapshot.activeInputIsExternal); // Built-in mic is NOT external

    NSDictionary *map = [snapshot toMap];
    XCTAssertEqualObjects(map[@"activeInputIsExternal"], @NO);
}

- (void)test_headsetMicRouteSnapshot {
    VGPortSnapshot *inputPort = [[VGPortSnapshot alloc] initWithPortType:AVAudioSessionPortHeadsetMic
                                                                portName:@"Headset Mic"
                                                                     UID:@"mic_headset"
                                                  selectedDataSourceName:nil];
    VGPortSnapshot *outputPort = [[VGPortSnapshot alloc] initWithPortType:AVAudioSessionPortHeadphones
                                                                 portName:@"Headphones"
                                                                      UID:@"hp_1"
                                                   selectedDataSourceName:nil];

    VGAudioRouteSnapshot *snapshot = VGBuildAudioRouteSnapshot(@[inputPort], @[outputPort], @[inputPort]);
    XCTAssertTrue(snapshot.inputAvailable);
    XCTAssertEqualObjects(snapshot.activeInputType, @"headsetMic");
    XCTAssertTrue(snapshot.activeInputIsExternal); // Headset mic is external
    XCTAssertTrue(snapshot.hasHeadphoneOutput); // Headphones output is headphone

    NSDictionary *map = [snapshot toMap];
    XCTAssertEqualObjects(map[@"activeInputIsExternal"], @YES);
    XCTAssertEqualObjects(map[@"hasHeadphoneOutput"], @YES);
}

- (void)test_otherUnrecognizedPortIsExternal {
    // "other" is any portType unrecognized (e.g. some third-party accessory or generic type)
    VGPortSnapshot *inputPort = [[VGPortSnapshot alloc] initWithPortType:@"UnrecognizedSpecialPortType"
                                                                portName:@"Special Input"
                                                                     UID:@"mic_special"
                                                  selectedDataSourceName:nil];
    VGPortSnapshot *outputPort = [[VGPortSnapshot alloc] initWithPortType:AVAudioSessionPortBluetoothA2DP
                                                                 portName:@"BT Output"
                                                                      UID:@"bt_out"
                                                   selectedDataSourceName:nil];

    VGAudioRouteSnapshot *snapshot = VGBuildAudioRouteSnapshot(@[inputPort], @[outputPort], @[inputPort]);
    XCTAssertTrue(snapshot.inputAvailable);
    XCTAssertEqualObjects(snapshot.activeInputType, @"other");
    XCTAssertTrue(snapshot.activeInputIsExternal); // "other" unrecognized is external/recordable
    XCTAssertTrue(snapshot.hasHeadphoneOutput); // Bluetooth A2DP is headphone output
}

- (void)test_tableDrivenRoutesAndDeduplication {
    struct TestRow {
        __unsafe_unretained NSString *portType;
        __unsafe_unretained NSString *expectedNormalised;
        BOOL expectedIsExternal;
    } table[] = {
        { AVAudioSessionPortBuiltInMic, @"builtInMic", NO },
        { AVAudioSessionPortHeadsetMic, @"headsetMic", YES },
        { AVAudioSessionPortBluetoothHFP, @"bluetoothHfp", YES },
        { AVAudioSessionPortUSBAudio, @"usbAudio", YES },
        { AVAudioSessionPortLineIn, @"lineIn", YES },
        { @"SomeRandomThirdPartyPort", @"other", YES },
    };

    for (int i = 0; i < sizeof(table)/sizeof(table[0]); i++) {
        VGPortSnapshot *inputPort = [[VGPortSnapshot alloc] initWithPortType:table[i].portType
                                                                    portName:@"Test Port"
                                                                         UID:@"uid"
                                                      selectedDataSourceName:nil];
        VGAudioRouteSnapshot *snapshot = VGBuildAudioRouteSnapshot(@[inputPort], @[], @[]);
        XCTAssertEqualObjects(snapshot.activeInputType, table[i].expectedNormalised);
        XCTAssertEqual(snapshot.activeInputIsExternal, table[i].expectedIsExternal);
    }

    // Test none
    VGAudioRouteSnapshot *noneSnapshot = VGBuildAudioRouteSnapshot(@[], @[], @[]);
    XCTAssertEqualObjects(noneSnapshot.activeInputType, @"none");
    XCTAssertFalse(noneSnapshot.activeInputIsExternal);

    // Test deduplication and sorting
    VGPortSnapshot *pBuiltIn = [[VGPortSnapshot alloc] initWithPortType:AVAudioSessionPortBuiltInMic portName:@"Builtin" UID:@"1" selectedDataSourceName:nil];
    VGPortSnapshot *pHeadset = [[VGPortSnapshot alloc] initWithPortType:AVAudioSessionPortHeadsetMic portName:@"Headset" UID:@"2" selectedDataSourceName:nil];

    VGAudioRouteSnapshot *dedupSnapshot = VGBuildAudioRouteSnapshot(@[], @[], @[pHeadset, pBuiltIn, pHeadset]);
    NSArray<NSString *> *expectedAvailable = @[@"builtInMic", @"headsetMic"];
    XCTAssertEqualObjects(dedupSnapshot.availableInputTypes, expectedAvailable);
}

@end

#endif // VG_USE_V2_GRAPH
