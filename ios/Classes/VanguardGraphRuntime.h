// VanguardGraphRuntime.h
// Vanguard Media Engine — Phase 1B, P1B-01
//
// Transitional concrete wrapper around VanguardMetalRenderer + Vanguard source
// classes. Satisfies the VGGraphRuntime public interface frozen in UMF.
//
// PUBLIC INTERFACE — do not modify without a charter update (C-5).
// Internals will be replaced in Phase 2. (C-2: not wired to any production
// path.)
//
// Depends on: VGGraphRuntime (UMF), VanguardMetalRenderer,
// VanguardFileMediaSource,
//             VanguardImageMediaSource, VGResourceAllocator.

#import "VanguardPlaybackTypes.h" // VGAudioRole — required for Phase 2 audio role APIs
// Phase 4 Batch 3 / Phase 7 Stage 7.5C: imported OUTSIDE any #if guard so the
// preprocessor can read VG_USE_V2_GRAPH before the guarded declarations below.
#import "VGUseV2Graph.h"
#import <Flutter/Flutter.h>
#import <UMF/VGGraphRuntime.h>
// P3-3 TRANSITIONAL — remove in Phase 4 (DEC-50, RR-31)
#import <UMF/VGMetalFilterNode.h> // runtime-owned UMF filter node protocol

// Phase 7 Stage 7.5C: forward-declare at file scope so the @interface below
// can reference VGTimelineCompositorNode in method signatures when V2 is enabled.
// @class is not valid inside an @interface body — it must appear at file scope.
#if VG_USE_V2_GRAPH
@class VGTimelineCompositorNode;
@protocol VGSourceNode;
#endif

NS_ASSUME_NONNULL_BEGIN

/// Concrete transitional graph runtime.
///
/// Designated initialiser requires the Flutter texture registry and method
/// channel that VanguardMetalRenderer needs for GPU texture display and
/// playback-event callbacks. The VGGraphRuntime base class interface
/// (prepareWithURL:completion:, play, pause, seekTo:, invalidate, state,
/// textureId, masterClock) is fully implemented here.
///
/// Thread-safety: matches the contract declared in VGGraphRuntime.h.
///   - prepareWithURL:completion: dispatches all work off the calling thread.
///   - play / pause / seekTo: — main thread only.
///   - invalidate — thread-safe (guarded by _Atomic(BOOL) _invalidated).
@interface VanguardGraphRuntime : VGGraphRuntime

/// Phase 2 designated initialiser — stores the caller's desired audio role.
/// @param registry  Flutter texture registry (owned by the plugin; must outlive
/// this object).
/// @param channel   Method channel for onPlaybackComplete /
/// onNodeDurationProbed callbacks.
/// @param role      Desired audio role. Resolved against VGResourceAllocator
/// during prepare;
///                  actual effective role may be Muted if the slot is already
///                  held.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                          methodChannel:(FlutterMethodChannel *)channel
                       desiredAudioRole:(VGAudioRole)role
    NS_DESIGNATED_INITIALIZER;

/// Phase 1 compatible convenience initialiser. Defaults to VGAudioRoleActive.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                          methodChannel:(FlutterMethodChannel *)channel;

/// Unavailable — use initWithTextureRegistry:methodChannel: or the
/// three-argument form.
- (instancetype)init NS_UNAVAILABLE;

// ─── Phase 2 audio role properties ───────────────────────────────────────────

/// The audio role requested by the caller at initialisation time.
/// Fixed after init; may differ from effectiveAudioRole after allocator
/// arbitration.
@property(nonatomic, readonly) VGAudioRole desiredAudioRole;

/// The audio role resolved by VGResourceAllocator during
/// prepareWithURL:completion:. Updated in-place by
/// transitionToRole:completion:.
@property(atomic, readonly) VGAudioRole effectiveAudioRole;

/// The natural pixel dimensions of the source.
/// Zero until prepareWithURL:completion: completes successfully.
@property(nonatomic, readonly) CGSize renderSize;

// ─── Phase 2 lifecycle methods
// ─────────────────────────────────────────────────

/// Transitions this runtime to the given audio role.
/// Acquires or relinquishes the VGResourceAllocator slot as needed.
/// Calls completion YES on success; NO if the allocator denies the request.
/// Dispatched off the calling thread; completion fires on a background queue.
- (void)transitionToRole:(VGAudioRole)role
              completion:(nullable void (^)(BOOL success))completion;

/// Invalidates the runtime then drains pending decode work before calling
/// completion. completion is always delivered on the main queue. Required for
/// G-02-T2 safe teardown.
- (void)invalidateAsync:(dispatch_block_t)completion;

// ─── Phase 2 forwarding methods
// ────────────────────────────────────────────────

/// Forwards playback rate to the renderer/source.
- (void)setPlaybackRate:(double)rate;

/// Forwards seek-preview pause gate to the source (test-only path).
- (void)setSeekPreviewPaused:(BOOL)paused;

/// Reads seek-preview pause state from the source.
- (BOOL)seekPreviewPaused;

// ─── P3-3 TRANSITIONAL filter chain ownership
// ────────────────────────────────── Remove in Phase 4 when VGGraphScheduler
// owns callback interception (DEC-50, RR-31).

/// Sets the runtime-owned UMF filter chain.
///
/// The runtime stores the chain (logical ownership) and forwards it to the
/// renderer via -[VanguardMetalRenderer setRuntimeFilterChain:] (physical
/// execution). This is the sole public interface for filter chain control in
/// P3-3.
///
/// Swap safety: renderer uses dispatch_barrier_async on videoDecodeQueue.
/// Arrays are copied defensively. Nodes removed from the chain have
/// -[VGMetalFilterNode invalidate] called before the chain is forwarded.
///
/// Pass nil or empty array to clear the runtime chain (renderer reverts to
/// legacy VanguardFilterNode path if any is installed).
/// Thread-safe: may be called from any thread.
- (void)setFilterChain:(nullable NSArray<id<VGMetalFilterNode>> *)chain;

/// P4-10: Constructs a filter chain from an ordered array of spec dictionaries
/// and applies it via -setFilterChain:.
///
/// Each spec dictionary must contain:
///   - `"type"` (NSString): one of `"lut"`, `"beauty"`, `"segmentation"`.
///   - `"enabled"` (NSNumber/BOOL, optional): node enable state. Defaults YES.
///   - `"parameters"` (NSDictionary, optional): per-node tuning params.
///     Recognised keys per type:
///       lut/beauty → `"intensity"` (float). beauty → `"radius"` (int).
///
/// @param specs   Ordered array of spec dicts (Dart → native method-channel payload).
/// @param unknown Set to the first unrecognised type string on return, or nil.
///
/// @return YES if all types were recognised and the chain was applied.
///         NO  if any type was unrecognised (*unknown is set); chain NOT applied.
///
/// Thread-safe: delegates to -setFilterChain: which is already thread-safe.
- (BOOL)setFilterChainFromSpecs:(NSArray<NSDictionary *> *)specs
                        unknown:(NSString *_Nullable *_Nullable)unknown
    NS_SWIFT_NAME(setFilterChain(fromSpecs:unknown:));

// ─── P3-4 Thermal back-pressure
// ──────────────────────────────────────────────── Receives thermal state from
// VGPluginLifecycleObserver and applies the 3-tier degradation policy to the
// runtime-owned filter chain (DEC-40).
//
// Tier policy (matches VGPluginLifecycleObserver thermal handler tiers):
//   nominal / fair   → all nodes enabled
//   serious          → non-LUT nodes disabled (segmentation most expensive)
//   critical         → all nodes disabled (chain present; zero GPU work)
//
// Thread-safe: may be called from any thread (main queue in practice via
// VGPluginLifecycleObserver which uses queue: .main).
// Does NOT modify the chain array — only mutates node.enabled on existing
// nodes. Nodes added or replaced via setFilterChain: after this call inherit
// the last-applied thermal state on the NEXT setRuntimeThermalState: call.

/// Applies thermal degradation policy to all VGMetalFilterNode objects
/// currently in the runtime-owned filter chain.
///
/// @param state  The current NSProcessInfoThermalState from ProcessInfo.
- (void)setRuntimeThermalState:(NSProcessInfoThermalState)state
    NS_SWIFT_NAME(setRuntimeThermalState(_:));

// ─── Phase 7 Stage 7.5C / Phase 7.x-D: Generic Source Node Playback ─────────
//
// This section is only compiled when VG_USE_V2_GRAPH=1.
// When VG_USE_V2_GRAPH=0, production V1 playback behavior is entirely unchanged.
//
// Phase 7.x-D: The prepare entry point now accepts any id<VGSourceNode> instead
// of a concrete VGTimelineCompositorNode. This allows future VGDualCameraCompositorNode
// instances to be mounted in the same runtime without modifying this interface again.
//
// Existing callers (Swift plugin) continue to pass VGTimelineCompositorNode instances.
// Timeline-specific methods (seekTimelineTo:, timelineCacheStatistics, flushTimelineCaches)
// remain unchanged and guard internally with isKindOfClass: to preserve timeline behavior.
//
// This does NOT modify the existing prepareWithURL:completion: path.
// This does NOT add dual-camera playback.

#if VG_USE_V2_GRAPH

/// Phase 7 Stage 7.5C / Phase 7.x-D: Prepare the runtime for source-node playback.
///
/// Accepts any pre-initialized id<VGSourceNode> (e.g. VGTimelineCompositorNode),
/// builds a two-node V2 graph via VGTimelinePlaybackGraphFactory, registers a
/// Flutter texture, and wires a CADisplayLink-driven pull loop that calls
/// pullFrame: on the source node and delivers frames to VanguardMetalRenderer via
/// VGRendererSinkAdapter.presentEnvelope:.
///
/// The existing prepareWithURL:completion: path (V1 and V2 push-mode) is
/// completely unmodified when this method is used instead.
///
/// Timeline-specific methods (seekTimelineTo:, timelineCacheStatistics,
/// flushTimelineCaches) remain functional when the sourceNode is a
/// VGTimelineCompositorNode. They safely no-op or return empty defaults
/// for other source node types.
///
/// @param sourceNode  A fully initialized id<VGSourceNode>.
///                    Must not be nil. Lifecycle is owned by the caller until
///                    this runtime is invalidated.
/// @param completion  Fires on the main queue with the registered Flutter
///                    textureId on success, or -1 + error on failure.
///                    Never called synchronously on the calling thread.
- (void)prepareWithSourceNode:(id<VGSourceNode>)sourceNode
                   completion:(void (^)(int64_t textureId,
                                       NSError *_Nullable error))completion
    NS_SWIFT_NAME(prepareTimeline(sourceNode:completion:));

/// Phase 7 Stage 7.5C: Seek the timeline compositor to the given PTS (seconds).
///
/// Wraps VGTimelineCompositorNode.seekTo:generation: using the runtime's
/// current generation counter. Safe to call from the main thread.
/// No-op if the runtime is not in the timeline playback state.
- (void)seekTimelineTo:(double)seconds
    NS_SWIFT_NAME(seekTimeline(to:));

/// Phase 7 Stage 7.5C: Start the timeline pull loop.
/// Sets timelineIsPlaying = YES. The CADisplayLink is already running;
/// this flag causes it to advance PTS on each tick.
/// Must be called on the main thread.
- (void)_timelinePlay
    NS_SWIFT_NAME(_timelinePlay());

/// Phase 7 Stage 7.5C: Pause the timeline pull loop.
/// Sets timelineIsPlaying = NO. The CADisplayLink continues ticking so
/// a paused seek (scrub) still delivers frames on demand.
/// Must be called on the main thread.
- (void)_timelinePause
    NS_SWIFT_NAME(_timelinePause());

// ─── Phase 7.18B1: Cache metrics and flush ─────────────────────────────────
//
// Forwarding wrappers so the Swift plugin and VGPluginLifecycleObserver can
// reach the compositor's frame cache without accessing the private
// timelineCompositor ivar directly.
//
// Both are thread-safe (delegate to os_unfair_lock-guarded cache methods).
// Both are no-ops if no timeline compositor has been prepared.

/// Returns a snapshot of the active timeline frame cache metrics, or an empty
/// dictionary if no timeline compositor is active.
///
/// Keys (all NSNumber): frameCacheBytes, frameCacheHits, frameCacheMisses,
///   frameCacheEvictions, frameCacheInserts, frameCacheEntries.
- (NSDictionary<NSString *, NSNumber *> *)timelineCacheStatistics
    NS_SWIFT_NAME(timelineCacheStatistics());

/// Flushes all entries from the active timeline frame cache and resets metric
/// counters. No-op if no timeline compositor is active.
- (void)flushTimelineCaches
    NS_SWIFT_NAME(flushTimelineCaches());

#endif // VG_USE_V2_GRAPH

@end

NS_ASSUME_NONNULL_END
