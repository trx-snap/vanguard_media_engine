// VGExportScheduler.h
// vanguard_media_engine — Phase 5C-1
//
// VGExportScheduler is the pull-mode export frame pump for offline video export.
//
// Architecture:
//   - Does NOT subclass VGGraphSchedulerV2 (push-mode only).
//   - Does NOT conform to VGFrameDelegate (no push-mode entry point).
//   - Does NOT import VanguardMetalRenderer, VanguardGraphRuntime,
//     VGVideoEncoderSinkNode, AVAssetWriter, or VideoToolbox.
//   - Uses VGClockPolicyPull semantics: the scheduler drives frame requests
//     from the source via pullFrame: at the sink's pace.
//
// Execution model:
//   startExport dispatches the pull loop on a private serial queue.
//   The loop calls [sourceNode pullFrame:request] for each frame, walks
//   execution order forward for transforms/metadata nodes, and delivers
//   the final envelope to id<VGFrameSink> via presentEnvelope:.
//
// Completion:
//   completionHandler is invoked exactly once across all terminal paths
//   (EOS success, source error, cancelExport, or invalidate).
//
// Phase 5C-1: Scheduler skeleton only. No real encoder. No AVAssetWriter.
//             No runtime integration. VGExportFileSourceNode (5C-2) not yet
//             implemented — use a conforming mock source for testing.
//
// PORTABLE: Scheduler logic is platform-agnostic.
// PLATFORM: Metal — processEnvelope:device: and enrichEnvelope:device:
//           receive the shared MTLDevice from the execution context.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGGraphExecutionContext.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGExportScheduler ────────────────────────────────────────────────────────
/// Pull-mode export scheduler skeleton.
///
/// Drives a VGClockPolicyPull graph: the scheduler issues VGFrameRequest objects
/// to the source node, walks transforms/metadata forward, and delivers each
/// processed envelope to the registered sink.
///
/// Designed for offline (non-real-time) export where the encoder sink paces
/// the graph — VGSinkAdmissionPolicyNeverDrop is satisfied by the pull contract
/// rather than by semaphore blocking on a push thread.
///
/// Phase 5C-1: Skeleton. Sink is optional; no encoder is wired yet.
@interface VGExportScheduler : NSObject

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize the export scheduler.
///
/// @param plan     The pre-computed execution plan (topological order).
/// @param nodes    Live node instances keyed by nodeId.
/// @param context  The graph execution context (clock must be nil for export).
/// @param fps      Frame rate for PTS generation (e.g. 30, 60).
- (instancetype)initWithPlan:(VGExecutionPlan *)plan
                       nodes:(NSDictionary<NSString *, id<VGNode>> *)nodes
                     context:(VGGraphExecutionContext *)context
                         fps:(int32_t)fps NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// ─── Sink ─────────────────────────────────────────────────────────────────────

/// The terminal frame sink. Weak reference to avoid retain cycles.
/// In Phase 5C-1 this may be nil (frames are processed but not delivered).
/// In Phase 5C-4+ this will be a VGVideoEncoderSinkNode.
@property (nonatomic, weak, nullable) id<VGFrameSink> sink;

// ─── State ────────────────────────────────────────────────────────────────────

/// YES while the pull loop is executing on the export queue.
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// YES after cancelExport or invalidate has been called.
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;

// ─── Completion ───────────────────────────────────────────────────────────────

/// Called exactly once when the export finishes, is cancelled, or errors.
/// Invoked on an unspecified background queue (the export queue).
/// success == YES means the source reached EndOfStream cleanly.
/// success == NO means the export was cancelled or hit a source error.
@property (nonatomic, copy, nullable) void (^completionHandler)(BOOL success,
                                                                 NSError * _Nullable error);

// ─── Control ──────────────────────────────────────────────────────────────────

/// Start the pull loop asynchronously on the internal export queue.
/// No-op if already running, cancelled, or invalidated.
/// completionHandler must be set before calling startExport.
- (void)startExport;

/// Cancel the export. Atomic. Safe from any thread.
/// The pull loop will exit on the next iteration check.
/// completionHandler fires once with success == NO.
- (void)cancelExport;

/// Idempotent teardown. Cancels the export, invalidates all nodes,
/// transitions the context to VGGraphStateStopped, and fires completionHandler
/// once (if not already fired). Safe from any thread.
- (void)invalidate;
@end


NS_ASSUME_NONNULL_END
