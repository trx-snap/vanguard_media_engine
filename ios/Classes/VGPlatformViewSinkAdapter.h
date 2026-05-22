// VGPlatformViewSinkAdapter.h
// vanguard_media_engine — Phase 6B-POC2
//
// VGPlatformViewSinkAdapter is a VGFrameSink terminal node that bridges
// the V2 graph pipeline to VanguardCameraPlatformView / MTKView.
//
// It holds a WEAK reference to an object conforming to VanguardCameraFrameReceiver
// (typically VanguardCameraPlatformView) and forwards the graph-processed
// CVPixelBuffer via onFrame:pts: on each presentEnvelope: call.
//
// Ownership contract:
//   presentEnvelope: receives the envelope at +0.
//   The CVPixelBuffer pointer is NOT retained here — we pass it at +0 to
//   onFrame:pts:, which (in VanguardCameraPlatformView) performs its own
//   ARC retain on assignment to latestBuffer. No extra CVPixelBufferRetain
//   is needed in this adapter.
//
// Thread safety:
//   presentEnvelope: is called on the graph execution queue (com.vanguard.cameraGraphExecution).
//   The weak-to-strong promotion of _receiver is atomic under ARC.
//   VanguardCameraPlatformView.onFrame:pts: uses os_unfair_lock for its buffer swap.
//
// POC2 ONLY — Remove before Phase 7 / production.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>
#import "VanguardCameraMediaSource.h"  // VanguardCameraFrameReceiver protocol

NS_ASSUME_NONNULL_BEGIN

/// Thin V2 sink adapter that forwards processed graph frames to a
/// VanguardCameraFrameReceiver (typically VanguardCameraPlatformView / MTKView).
///
/// Used by VGFanOutSink as a second child alongside VGRendererSinkAdapter to
/// deliver Beauty-V2-processed frames to the PlatformView in POC2.
@interface VGPlatformViewSinkAdapter : NSObject <VGFrameSink>

/// The frame receiver (VanguardCameraPlatformView). Stored WEAK to avoid retain cycle.
/// If deallocated before presentEnvelope: fires, envelopes are silently dropped.
@property (nonatomic, weak, readonly, nullable) id<VanguardCameraFrameReceiver> receiver;

/// Designated initializer.
/// @param receiver  The VanguardCameraFrameReceiver to forward frames to.
///                  Stored as weak — must outlive any active graph session.
- (instancetype)initWithReceiver:(id<VanguardCameraFrameReceiver>)receiver NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
