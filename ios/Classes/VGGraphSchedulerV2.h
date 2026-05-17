// VGGraphSchedulerV2.h
// Phase 4 Batch 2: V2 graph scheduler. No runtime wiring.
//
// VGGraphSchedulerV2 is the V2 plan-driven scheduler for the
// VGGraphDescriptor-driven playback pipeline.
//
// Role:
//   Receives push-mode frames via VGFrameDelegate.didReceiveRawFrame:,
//   executes VGExecutionPlan.topologicalOrder over live V2 adapter nodes,
//   and delivers the final processed envelope to id<VGFrameSink>.
//
// Design constraints:
//   - Conforms to VGFrameDelegate, NOT the legacy VGGraphScheduler protocol.
//   - Holds id<VGFrameSink> — NOT VanguardMetalRenderer — as the delivery target.
//   - Does NOT import VanguardMetalRenderer, VGCameraSourceAdapter, or
//     VanguardGraphRuntime.
//   - Does NOT call pullFrame: in Phase 4 (push-mode only).
//   - Does NOT wire itself into VanguardGraphRuntime. Wiring is Phase 4B+.
//
// Execution model:
//   didReceiveRawFrame: is called on _videoDecodeQueue (the source's serial
//   decode queue). Queue identity is preserved — no dispatch. This matches
//   V1 VanguardGraphScheduler threading exactly (G-02 A/V sync ordering).
//
// Buffer ownership (RR-36):
//   Source-owned buffer: NOT released by scheduler after delivery.
//   Filter-produced NEW buffer: scheduler holds +1, released after presentEnvelope:.
//   Passthrough buffer (same pointer from metadata node): NOT scheduler-owned.
//   Intermediate buffers: released within didReceiveRawFrame: when superseded.
//   On NULL filter output: revert to source envelope, release metadata, break.
//
// Metadata cleanup (DEC-102):
//   VGFrameEnvelopeReleaseMetadata is called on currentEnvelope after
//   presentEnvelope: returns. This releases the CFRetained metadata pointer
//   attached by VGMetadataNode.enrichEnvelope:device:.
//
// Thread safety (DEC-54):
//   _executionOrder is computed at init and immutable — no lock needed.
//   _invalidated is _Atomic(BOOL) — safe for cross-queue reads.
//   _running is accessed only on _videoDecodeQueue (same serial queue).
//
// Phase 4 Batch 2. No runtime wiring. Source pullFrame: not called.
// Phase 4B+: runtime wiring and context preparation lifecycle.

#pragma once

#import <Foundation/Foundation.h>
#import <CoreMedia/CMTime.h>
#import <UMF/VGFrameDelegate.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMasterClock.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGGraphSchedulerV2 ──────────────────────────────────────────────────────
/// V2 plan-driven push-mode scheduler for the VGGraphDescriptor pipeline.
///
/// Receives raw frames from the renderer via VGFrameDelegate, executes the
/// execution plan over live V2 adapter nodes, and delivers processed frames
/// to the registered id<VGFrameSink>.
///
/// Does NOT conform to the legacy VGGraphScheduler protocol.
/// Does NOT import or reference VanguardMetalRenderer or VanguardGraphRuntime.
@interface VGGraphSchedulerV2 : NSObject <VGFrameDelegate>

/// Designated initializer.
///
/// @param plan     The topologically ordered execution plan from VGGraphPlanner.
/// @param nodes    Live node instances keyed by nodeId (from VGPlaybackGraphFactory).
/// @param context  The graph execution context holding state and the resource allocator.
- (instancetype)initWithPlan:(VGExecutionPlan *)plan
                       nodes:(NSDictionary<NSString *, id<VGNode>> *)nodes
                     context:(VGGraphExecutionContext *)context NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use -initWithPlan:nodes:context:.
- (instancetype)init NS_UNAVAILABLE;

// ─── Delivery target ──────────────────────────────────────────────────────────

/// The V2 frame sink (typically VGRendererSinkAdapter wrapping VanguardMetalRenderer).
///
/// Weak reference: the runtime owns both the scheduler and the sink adapter.
/// Set by the runtime after construction, before the first frame arrives.
/// May be nil — frames are safely dropped if nil.
@property (nonatomic, weak, nullable) id<VGFrameSink> sink;

// ─── Runtime state ────────────────────────────────────────────────────────────

/// YES when the scheduler is actively dispatching frames to the execution plan.
@property (nonatomic, readonly, getter=isRunning) BOOL running;

// ─── Lifecycle ────────────────────────────────────────────────────────────────

/// Transition the graph to running state.
///
/// Sets running = YES, calls [sourceNode startProducing], and transitions the
/// execution context to VGGraphStateRunning.
///
/// The clock parameter is accepted for API symmetry with the V1 scheduler and
/// future hybrid-clock support (Phase 6+). It is not used in Phase 4 push mode
/// because the source drives its own decode rate.
///
/// No-op if already invalidated.
///
/// @param clock  Optional master clock. Nil is accepted for push-mode sources.
- (void)startWithClock:(nullable id<VGMasterClock>)clock;

/// Suspend frame dispatch.
///
/// Sets running = NO, calls [sourceNode stopProducing], and transitions the
/// execution context to VGGraphStatePaused.
- (void)pause;

/// Resume frame dispatch after pause.
///
/// Sets running = YES, calls [sourceNode startProducing], and transitions the
/// execution context to VGGraphStateRunning. No-op if already invalidated.
- (void)resume;

/// Seek the source to the specified output-timeline PTS.
///
/// Increments the context generation counter atomically, then forwards
/// seekTo:generation: to the source node so in-flight frames from the
/// previous position are discarded.
///
/// Does NOT call pullFrame: (push mode only in Phase 4).
///
/// @param time        Target PTS in the output timeline.
/// @param generation  The caller's generation hint (ignored — context generation is used).
- (void)seekTo:(CMTime)time generation:(uint64_t)generation;

/// Tear down the scheduler and all node instances.
///
/// Idempotent: the first call stops source production, invalidates all nodes,
/// transitions the context to VGGraphStateStopped, and sets running = NO.
/// Subsequent calls are no-ops.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
