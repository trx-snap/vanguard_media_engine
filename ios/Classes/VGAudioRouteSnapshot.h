// VGAudioRouteSnapshot.h
// Vanguard Media Engine — Audio Slice N
//
// Immutable plain-value route snapshot produced after an AVAudioSession
// category activation. Contains both input and output port information and
// exposes headphone-output and external-microphone convenience flags.
//
// VISIBILITY: Module-visible (not in private_header_files) so Swift can
// read the snapshot returned by the coordinator.
//
// The backend seam (VGAudioSessionBackend) returns VGPortSnapshot values
// instead of AVAudioSessionPortDescription / AVAudioSessionRouteDescription
// so that tests can construct fake routes without AVFoundation hardware
// objects.
//
// Threading: All methods must be called on the main thread.

#pragma once

#import <Foundation/Foundation.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── VGPortSnapshot ───────────────────────────────────────────────────────────

/// Immutable plain-value representation of one audio port.
/// Replaces AVAudioSessionPortDescription at the testable seam boundary.
@interface VGPortSnapshot : NSObject

/// AVAudioSessionPort string constant (e.g. AVAudioSessionPortBuiltInMic).
@property(nonatomic, readonly) NSString *portType;

/// Human-readable port name (e.g. "iPhone Microphone").
@property(nonatomic, readonly) NSString *portName;

/// Stable hardware UID.
@property(nonatomic, readonly) NSString *UID;

/// Name of the selected data source, or nil.
@property(nonatomic, readonly, nullable) NSString *selectedDataSourceName;

- (instancetype)initWithPortType:(NSString *)portType
                        portName:(NSString *)portName
                             UID:(NSString *)UID
          selectedDataSourceName:(nullable NSString *)dataSourceName
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// ─── VGRouteSnapshot ─────────────────────────────────────────────────────────

/// Immutable plain-value route: current inputs + current outputs.
/// Replaces AVAudioSessionRouteDescription at the testable seam boundary.
@interface VGRouteSnapshot : NSObject

@property(nonatomic, readonly) NSArray<VGPortSnapshot *> *inputs;
@property(nonatomic, readonly) NSArray<VGPortSnapshot *> *outputs;

- (instancetype)initWithInputs:(NSArray<VGPortSnapshot *> *)inputs
                       outputs:(NSArray<VGPortSnapshot *> *)outputs
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// ─── VGAudioRouteSnapshot ────────────────────────────────────────────────────

/// Processed route snapshot produced by the coordinator after PlayAndRecord
/// activation. Provides normalised type strings and convenience flags.
///
/// Normalised input type strings:
///   "builtInMic"   — AVAudioSessionPortBuiltInMic  (built-in mic; NOT external)
///   "headsetMic"   — AVAudioSessionPortHeadsetMic  (external wired)
///   "bluetoothHfp" — AVAudioSessionPortBluetoothHFP (external wireless)
///   "usbAudio"     — AVAudioSessionPortUSBAudio     (external USB)
///   "lineIn"       — AVAudioSessionPortLineIn       (external line-level)
///   "other"        — any unrecognised input port; AVAudioSession only reports
///                    it when the hardware is present and capable of capture,
///                    so it is treated as recordable and external.
///   "none"         — no input present on currentRoute
///
/// activeInputIsExternal:
///   YES  — headsetMic, bluetoothHfp, usbAudio, lineIn, other
///   NO   — builtInMic, none
///
/// hasHeadphoneOutput is YES for wired headphones, Bluetooth HFP, A2DP, or LE.
/// It preserves the existing output-based isHeadphonesConnected semantics
/// (output detection only — no implication about microphone type or permission).
///
/// inputAvailable reflects the presence of an input on currentRoute after
/// PlayAndRecord activation. It does NOT imply that microphone permission
/// has been granted; AVAudioSession reports route state regardless of
/// permission status.
@interface VGAudioRouteSnapshot : NSObject

/// YES if currentRoute.inputs was non-empty after category activation.
/// Does NOT imply microphone permission.
@property(nonatomic, readonly) BOOL inputAvailable;

/// Normalised port type of the first currentRoute.inputs entry, or "none".
@property(nonatomic, readonly) NSString *activeInputType;

/// Human-readable name of the active input port. Empty string when none.
@property(nonatomic, readonly) NSString *activeInputName;

/// Stable UID of the active input port. Empty string when none.
@property(nonatomic, readonly) NSString *activeInputUID;

/// Data source name of the active input, or nil.
@property(nonatomic, readonly, nullable) NSString *activeInputDataSourceName;

/// Normalised, deduplicated, alphabetically sorted types from availableInputs.
@property(nonatomic, readonly) NSArray<NSString *> *availableInputTypes;

/// Normalised port types from currentRoute.outputs, preserving route order.
@property(nonatomic, readonly) NSArray<NSString *> *activeOutputTypes;

/// YES if any output port is wired headphones, Bluetooth HFP, A2DP, or LE.
/// Matches the existing isHeadphonesConnected semantics (output-based).
@property(nonatomic, readonly) BOOL hasHeadphoneOutput;

/// YES for known external input types AND "other" (recordable, unclassified).
/// NO only for builtInMic and none.
@property(nonatomic, readonly) BOOL activeInputIsExternal;

- (instancetype)initWithInputAvailable:(BOOL)inputAvailable
                       activeInputType:(NSString *)activeInputType
                       activeInputName:(NSString *)activeInputName
                        activeInputUID:(NSString *)activeInputUID
               activeInputDataSourceName:(nullable NSString *)dataSourceName
                   availableInputTypes:(NSArray<NSString *> *)availableInputTypes
                     activeOutputTypes:(NSArray<NSString *> *)activeOutputTypes
                    hasHeadphoneOutput:(BOOL)hasHeadphoneOutput
                  activeInputIsExternal:(BOOL)activeInputIsExternal
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Serialises to a Flutter-compatible dictionary suitable for the MethodChannel
/// result map. All keys are stable across releases.
- (NSDictionary<NSString *, id> *)toMap;

@end

// ─── Factory helper ───────────────────────────────────────────────────────────

/// Builds a VGAudioRouteSnapshot from raw VGPortSnapshot arrays.
/// Defined in VGAudioRouteSnapshot.m; called by VGAudioSessionTransitionCoordinator
/// after PlayAndRecord activation.
VGAudioRouteSnapshot *VGBuildAudioRouteSnapshot(
    NSArray<VGPortSnapshot *> *inputPorts,
    NSArray<VGPortSnapshot *> *outputPorts,
    NSArray<VGPortSnapshot *> *availablePorts);

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
