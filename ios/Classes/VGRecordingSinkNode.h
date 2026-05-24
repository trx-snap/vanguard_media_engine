// VGRecordingSinkNode.h
// vanguard_media_engine — Phase 6E.1A
//
// VGRecordingSinkNode is the graph-aware recording terminal sink.
// When wired as a child of VGFanOutSink, it will receive processed
// (effects-applied) graph output frames and delegate frame delivery
// to VanguardCameraMediaSource so that existing audio-video synchronization,
// clock management, and hardware encoder ownership remain in the source.
//
// Architecture (Delegated Recording — Option A):
//   - Conforms to VGFrameSink (extends VGNode). Role: VGNodeRoleSink.
//   - Input port: "video_in" / VGMediaTypeVideo / required.
//   - Does NOT own its own encoder or writer.
//   - Holds a weak reference to VanguardCameraMediaSource. The source owns
//     the writer; the sink only forwards frames when enabled.
//   - Future Phase 6E.1 steps will add bounded async handoff and processed-frame recording.
//
// Current status — Phase 6E.1A (SKELETON ONLY):
//   - All protocol methods are declared and stubbed.
//   - presentEnvelope: returns immediately unless ready and enabled.
//   - No frames are forwarded, retained, or encoded in this step.
//   - No encoder, no writer, no queue crossing in this step.
//   - This file exists only to prove the type compiles alongside the
//     rest of the graph infrastructure. Runtime behavior is unchanged.
//
// Forbidden in this step (6E.1A):
//   - No frame appending or encoding.
//   - No queue crossing.
//   - No wiring into VGCameraGraphSession or VGCameraGraphFactory.
//
// Future steps will:
//   6E.1B — Wire into VGFanOutSink via VGCameraGraphSession (inactive by default).
//   6E.1C — Implement frame forwarding to VanguardCameraMediaSource.
//   6E.1D — Enable by default; remove raw-path recording from VanguardCameraMediaSource.
//
// PORTABLE: VGFrameSink contract is platform-agnostic.
// PLATFORM: iOS — CoreMedia, CoreVideo. AVFoundation is owned by the delegate.

#pragma once

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>

// Forward declaration — avoids importing VanguardCameraMediaSource.h in the
// graph layer. Full import lives in the .m.
@class VanguardCameraMediaSource;

NS_ASSUME_NONNULL_BEGIN

// ─── VGRecordingSinkNode ──────────────────────────────────────────────────────

/// Graph terminal sink that receives processed camera frames and delegates
/// encoding to VanguardCameraMediaSource (Option A delegated architecture).
///
/// Phase 6E.1A: Skeleton only. presentEnvelope: is a no-op while disabled.
@interface VGRecordingSinkNode : NSObject <VGFrameSink>

// ─── Properties ───────────────────────────────────────────────────────────────

/// The synthesized nodeId for this sink.
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Controls whether frames are forwarded to the source for encoding.
///
/// Phase 6E.1A: Declared but has no effect — presentEnvelope: is a no-op
/// regardless of this value until Phase 6E.1C wires the forwarding path.
///
/// Thread-safe: atomic. Written by VGCameraGraphSession on session queue;
/// read on graph execution queue.
@property (atomic, assign, getter=isEnabled) BOOL enabled;

// ─── Designated initializer ───────────────────────────────────────────────────

/// Designated initializer.
///
/// @param nodeId   Unique graph node identifier. Must not be nil or empty.
/// @param source   The camera source that owns the writer and will
///                 receive forwarded frames. Held weakly — the source owns
///                 the graph session and must outlive individual graph runs.
/// @return An initialized instance, or nil if nodeId is invalid.
- (instancetype)initWithNodeId:(NSString *)nodeId
                        source:(VanguardCameraMediaSource *)source NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithNodeId:source:.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
