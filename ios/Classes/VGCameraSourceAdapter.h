// VGCameraSourceAdapter.h
// Phase 3: Adapter only. No runtime wiring.
//
// Wraps VanguardCameraMediaSource into the V2 VGSourceNode protocol so a live
// camera source can be registered in a VGGraphDescriptor-driven DAG without
// modifying VanguardCameraMediaSource.
//
// Dependency note: Lives in vanguard_media_engine (NOT UMF).
//   vanguard_media_engine → UMF (one-way dependency, no circular risk).
//
// Camera is push-only. pullFrame: returns skipped — not an error.
//   AVCaptureVideoDataOutputSampleBufferDelegate drives frame delivery at
//   hardware rate. There is no mechanism to pull a frame at an arbitrary PTS.
//   Returning VGFrameStatusSkipped is semantically correct (mode mismatch,
//   not failure). Phase 4 scheduler will use startProducing/stopProducing.
//
// VanguardCameraMediaSource does not conform to VGMediaNode.
//   Identity (nodeId, nodeClass) is synthesized by the adapter.
//   nodeId: @"camera_source" (stable constant within a graph session)
//   nodeClass: @"VGCameraSourceAdapter"
//
// Phase 3 stubs:
//   - pullFrame: → returns skippedWithGeneration: (push-only live source)
//   - prepareWithContext:completion: → async stub, calls completion(nil)
//   - invalidate → no-op (lifecycle managed by plugin/runtime)
//   - negotiateFormatForPort:inputFormats: → returns nil

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration — full definition in VanguardCameraMediaSource.h,
// imported in the .m file only.
@class VanguardCameraMediaSource;

/// Thin V2 adapter wrapping VanguardCameraMediaSource as a push-mode VGSourceNode.
///
/// Push-mode delegation:
///   startProducing → [source start] — starts AVCaptureSession
///   stopProducing  → [source stop]  — stops session, releases _latestBuffer
///
/// pullFrame: returns VGFrameStatusSkipped unconditionally. The camera hardware
/// drives frame delivery at capture rate; synchronous pull at arbitrary PTS is
/// not possible. This is a mode mismatch (not a failure condition).
///
/// The source is retained strongly — camera source lifecycle is explicit
/// (created at mode entry, stopped at mode exit) and does not risk a retain cycle.
@interface VGCameraSourceAdapter : NSObject <VGSourceNode>

/// The wrapped camera media source. Retained by this adapter.
@property (nonatomic, strong, readonly) VanguardCameraMediaSource *source;

/// Designated initialiser.
/// @param source  The VanguardCameraMediaSource instance to wrap. Must not be nil.
- (instancetype)initWithSource:(VanguardCameraMediaSource *)source NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
