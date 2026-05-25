// VGPhotoSinkNode.h
// vanguard_media_engine — Phase 6E.2A
//
// VGPhotoSinkNode is the graph-aware photo capture terminal sink.
// When wired as a child of VGFanOutSink, it will receive processed
// (effects-applied) graph output frames. In Phase 6E.2A this node is
// an idle skeleton — presentEnvelope: is an unconditional no-op.
//
// Architecture (Graph-Backed Photo Capture):
//   - Conforms to VGFrameSink (extends VGNode). Role: VGNodeRoleSink.
//   - Input port: "video_in" / VGMediaTypeVideo / required.
//   - Does NOT arm, latch, encode, retain buffers, or write files in this phase.
//   - Future Phase 6E.2B steps will add one-shot arming/latching and JPEG encoding.
//
// Current status — Phase 6E.2A (SKELETON / NO-OP):
//   - Included as last child of VGFanOutSink via VGCameraGraphFactory.
//   - presentEnvelope: is an unconditional no-op.
//   - No runtime photo behavior is added in this phase.
//   - takePhoto routing is unchanged (still uses raw _latestBuffer path).
//
// Future steps will:
//   6E.2B — Add arming/latching and one-shot JPEG capture.
//   6E.2C — Route takePhotoToURL through the graph path.
//
// PORTABLE: VGFrameSink contract is platform-agnostic.
// PLATFORM: iOS — no platform frameworks imported in this header.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGPhotoSinkNode ──────────────────────────────────────────────────────────

/// Graph terminal sink that will receive processed camera frames for photo capture.
///
/// Phase 6E.2A: Skeleton only. presentEnvelope: is an unconditional no-op.
/// No arming, buffer retention, encoding, or file I/O is present in this phase.
@interface VGPhotoSinkNode : NSObject <VGFrameSink>

// ─── Properties ───────────────────────────────────────────────────────────────

/// The synthesized nodeId for this sink.
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Whether the sink is ready to receive frames.
///
/// Always YES after a successful init. Live camera fan-out sinks are not
/// prepared by the scheduler; readiness is established at init time.
@property (atomic, readonly, getter=isReady) BOOL ready;

// ─── Designated initializer ───────────────────────────────────────────────────

/// Designated initializer.
///
/// @param nodeId   Unique graph node identifier. Must not be nil or empty.
/// @return An initialized instance, or nil if nodeId is invalid.
- (nullable instancetype)initWithNodeId:(NSString *)nodeId NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithNodeId:.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
