// VGPlatformViewSinkAdapter.h
// vanguard_media_engine — Phase 6B-POC2 / Duet Phase 4B-B
//
// VGPlatformViewSinkAdapter is a VGFrameSink terminal node that bridges
// the V2 graph pipeline to any VanguardCameraFrameReceiver. Originally built
// for VanguardCameraPlatformView / MTKView (POC2, hence the name); it is the
// generic processed-output receiver sink of the camera graph and is also the
// egress of VGCameraGraphSession's graph-only mode (Duet foreground provider).
//
// It holds a WEAK reference to an object conforming to VanguardCameraFrameReceiver
// and forwards the graph-processed CVPixelBuffer via onFrame:pts: on each
// presentEnvelope: call.
//
// Ownership contract:
//   presentEnvelope: receives the envelope at +0.
//   The CVPixelBuffer pointer is NOT retained here — we pass it at +0 to
//   onFrame:pts:. The receiver MUST retain what it keeps past the call
//   (VanguardCameraPlatformView does so via ARC on assignment to latestBuffer;
//   the Duet graph provider takes an explicit +1 before storing). No extra
//   CVPixelBufferRetain is performed in this adapter.
//
// Thread safety:
//   presentEnvelope: is called on the graph execution queue (com.vanguard.cameraGraphExecution).
//   The weak-to-strong promotion of _receiver is atomic under ARC.
//   Receivers must keep onFrame:pts: fast (lock-guarded slot swap) — it runs
//   inside the graph frame block.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>
#import "VanguardCameraMediaSource.h"  // VanguardCameraFrameReceiver protocol

NS_ASSUME_NONNULL_BEGIN

/// Thin V2 sink adapter that forwards processed graph frames to a
/// VanguardCameraFrameReceiver (VanguardCameraPlatformView / MTKView, the Duet
/// graph foreground provider, or any other processed-frame consumer).
///
/// Used by VGFanOutSink as a child alongside (renderer mode) or instead of
/// (graph-only mode) VGRendererSinkAdapter to deliver filter-chain output.
@interface VGPlatformViewSinkAdapter : NSObject <VGFrameSink>

/// The frame receiver. Stored WEAK to avoid retain cycle.
/// If deallocated before presentEnvelope: fires, envelopes are silently dropped.
@property (nonatomic, weak, readonly, nullable) id<VanguardCameraFrameReceiver> receiver;

/// Designated initializer.
/// @param receiver  The VanguardCameraFrameReceiver to forward frames to.
///                  Stored as weak — must outlive any active graph session.
- (instancetype)initWithReceiver:(id<VanguardCameraFrameReceiver>)receiver NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
