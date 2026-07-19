// VGAudioRouteSnapshot.m
// Vanguard Media Engine — Audio Slice N

#import "VGAudioRouteSnapshot.h"
#import <AVFoundation/AVFoundation.h>

#if VG_USE_V2_GRAPH

// ─── Normalisation helpers ────────────────────────────────────────────────────

static NSString *VGNormaliseInputPortType(NSString *portType) {
    if ([portType isEqualToString:AVAudioSessionPortBuiltInMic])   return @"builtInMic";
    if ([portType isEqualToString:AVAudioSessionPortHeadsetMic])   return @"headsetMic";
    if ([portType isEqualToString:AVAudioSessionPortBluetoothHFP]) return @"bluetoothHfp";
    if ([portType isEqualToString:AVAudioSessionPortUSBAudio])     return @"usbAudio";
    if ([portType isEqualToString:AVAudioSessionPortLineIn])       return @"lineIn";
    return @"other";
}

static NSString *VGNormaliseOutputPortType(NSString *portType) {
    if ([portType isEqualToString:AVAudioSessionPortHeadphones])      return @"headphones";
    if ([portType isEqualToString:AVAudioSessionPortBluetoothHFP])    return @"bluetoothHfp";
    if ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP])   return @"bluetoothA2dp";
    if ([portType isEqualToString:AVAudioSessionPortBluetoothLE])     return @"bluetoothLe";
    if ([portType isEqualToString:AVAudioSessionPortBuiltInSpeaker])  return @"builtInSpeaker";
    if ([portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) return @"builtInReceiver";
    if ([portType isEqualToString:AVAudioSessionPortUSBAudio])        return @"usbAudio";
    return @"other";
}

// hasHeadphoneOutput: YES for wired headphones, HFP, A2DP, or LE outputs.
// Preserves existing isHeadphonesConnected output-based semantics.
static BOOL VGOutputHasHeadphone(NSArray<VGPortSnapshot *> *outputs) {
    for (VGPortSnapshot *p in outputs) {
        if ([p.portType isEqualToString:AVAudioSessionPortHeadphones] ||
            [p.portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [p.portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [p.portType isEqualToString:AVAudioSessionPortBluetoothLE]) {
            return YES;
        }
    }
    return NO;
}

// activeInputIsExternal:
//   YES — headsetMic, bluetoothHfp, usbAudio, lineIn, other.
//   "other" is an unrecognised port type that AVAudioSession only reports when
//   the hardware is genuinely present and capable of capture, so it is treated
//   as external/recordable.
//   NO  — builtInMic, none.
static BOOL VGInputIsExternal(NSString *normalisedType) {
    return [normalisedType isEqualToString:@"headsetMic"]   ||
           [normalisedType isEqualToString:@"bluetoothHfp"] ||
           [normalisedType isEqualToString:@"usbAudio"]     ||
           [normalisedType isEqualToString:@"lineIn"]       ||
           [normalisedType isEqualToString:@"other"];
}

// ─── VGPortSnapshot ───────────────────────────────────────────────────────────

@implementation VGPortSnapshot

- (instancetype)initWithPortType:(NSString *)portType
                        portName:(NSString *)portName
                             UID:(NSString *)UID
          selectedDataSourceName:(nullable NSString *)dataSourceName {
    self = [super init];
    if (self) {
        _portType = [portType copy];
        _portName = [portName copy];
        _UID = [UID copy];
        _selectedDataSourceName = [dataSourceName copy];
    }
    return self;
}

@end

// ─── VGRouteSnapshot ─────────────────────────────────────────────────────────

@implementation VGRouteSnapshot

- (instancetype)initWithInputs:(NSArray<VGPortSnapshot *> *)inputs
                       outputs:(NSArray<VGPortSnapshot *> *)outputs {
    self = [super init];
    if (self) {
        _inputs  = [inputs copy];
        _outputs = [outputs copy];
    }
    return self;
}

@end

// ─── VGAudioRouteSnapshot ────────────────────────────────────────────────────

@implementation VGAudioRouteSnapshot

- (instancetype)initWithInputAvailable:(BOOL)inputAvailable
                       activeInputType:(NSString *)activeInputType
                       activeInputName:(NSString *)activeInputName
                        activeInputUID:(NSString *)activeInputUID
               activeInputDataSourceName:(nullable NSString *)dataSourceName
                   availableInputTypes:(NSArray<NSString *> *)availableInputTypes
                     activeOutputTypes:(NSArray<NSString *> *)activeOutputTypes
                    hasHeadphoneOutput:(BOOL)hasHeadphoneOutput
                  activeInputIsExternal:(BOOL)activeInputIsExternal {
    self = [super init];
    if (self) {
        _inputAvailable        = inputAvailable;
        _activeInputType       = [activeInputType copy];
        _activeInputName       = [activeInputName copy];
        _activeInputUID        = [activeInputUID copy];
        _activeInputDataSourceName = [dataSourceName copy];
        _availableInputTypes   = [availableInputTypes copy];
        _activeOutputTypes     = [activeOutputTypes copy];
        _hasHeadphoneOutput    = hasHeadphoneOutput;
        _activeInputIsExternal = activeInputIsExternal;
    }
    return self;
}

- (NSDictionary<NSString *, id> *)toMap {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    map[@"inputAvailable"]        = @(_inputAvailable);
    map[@"activeInputType"]       = _activeInputType;
    map[@"activeInputName"]       = _activeInputName;
    map[@"activeInputUID"]        = _activeInputUID;
    if (_activeInputDataSourceName) {
        map[@"activeInputDataSourceName"] = _activeInputDataSourceName;
    } else {
        map[@"activeInputDataSourceName"] = [NSNull null];
    }
    map[@"availableInputTypes"]   = _availableInputTypes;
    map[@"activeOutputTypes"]     = _activeOutputTypes;
    map[@"hasHeadphoneOutput"]    = @(_hasHeadphoneOutput);
    map[@"activeInputIsExternal"] = @(_activeInputIsExternal);
    return [map copy];
}

@end

// ─── Factory helper used by VGAudioSessionTransitionCoordinator ──────────────

VGAudioRouteSnapshot *VGBuildAudioRouteSnapshot(
    NSArray<VGPortSnapshot *> *inputPorts,
    NSArray<VGPortSnapshot *> *outputPorts,
    NSArray<VGPortSnapshot *> *availablePorts) {

    BOOL inputAvailable = inputPorts.count > 0;

    // Active input (first current input).
    NSString *activeType = @"none";
    NSString *activeName = @"";
    NSString *activeUID  = @"";
    NSString *activeDataSource = nil;
    BOOL isExternal = NO;

    if (inputAvailable) {
        VGPortSnapshot *first = inputPorts.firstObject;
        activeType = VGNormaliseInputPortType(first.portType);
        activeName = first.portName;
        activeUID  = first.UID;
        activeDataSource = first.selectedDataSourceName;
        isExternal = VGInputIsExternal(activeType);
    }

    // Available input types: normalise, deduplicate, sort alphabetically.
    NSMutableOrderedSet<NSString *> *avail = [NSMutableOrderedSet orderedSet];
    for (VGPortSnapshot *p in availablePorts) {
        [avail addObject:VGNormaliseInputPortType(p.portType)];
    }
    NSArray<NSString *> *availSorted =
        [[avail array] sortedArrayUsingSelector:@selector(compare:)];

    // Active output types: normalise, preserve order.
    NSMutableArray<NSString *> *outTypes = [NSMutableArray array];
    for (VGPortSnapshot *p in outputPorts) {
        [outTypes addObject:VGNormaliseOutputPortType(p.portType)];
    }

    BOOL hasHeadphone = VGOutputHasHeadphone(outputPorts);

    return [[VGAudioRouteSnapshot alloc]
        initWithInputAvailable:inputAvailable
               activeInputType:activeType
               activeInputName:activeName
                activeInputUID:activeUID
       activeInputDataSourceName:activeDataSource
           availableInputTypes:availSorted
             activeOutputTypes:outTypes
            hasHeadphoneOutput:hasHeadphone
          activeInputIsExternal:isExternal];
}

#endif // VG_USE_V2_GRAPH
