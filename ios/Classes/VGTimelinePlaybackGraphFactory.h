// VGTimelinePlaybackGraphFactory.h
// Vanguard Media Engine — Phase 7 Stage 7.5C
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.5C — VISUAL TIMELINE PLAYBACK PROOF FACTORY
// ═══════════════════════════════════════════════════════════════════════════════
//
// This factory is deliberately separate from VGPlaybackGraphFactory (Phase 4)
// for two reasons:
//
//   1. VGPlaybackGraphFactory accepts V1 id<VanguardMediaSource> objects and
//      wraps them in V2 adapters.  VGTimelineCompositorNode is a V2-native
//      <VGSourceNode> — it does NOT need or tolerate an adapter wrapper.
//      Modifying the existing factory to handle this case would risk
//      destabilizing the validated, stable V1→V2 playback path.
//
//   2. Scope isolation: this factory is a Stage 7.5C proof artifact.  Keeping
//      it in a separate file allows it to be cleanly removed or promoted to
//      production without touching any existing Stage 4–6 factory code.
//
// ── GRAPH TOPOLOGY ─────────────────────────────────────────────────────────
//
//   ┌──────────────────────────────────────────────┐
//   │  timeline (VGTimelineCompositorNode)          │  role: compositor
//   │  port: video_out                              │  (self-sourcing <VGSourceNode>)
//   └──────────────────────┬───────────────────────┘
//                          │  synchronous, dropLatest
//   ┌──────────────────────▼───────────────────────┐
//   │  renderer_sink (VGRendererSinkAdapter)        │  role: sink
//   │  port: video_in (required)                    │
//   └──────────────────────────────────────────────┘
//
// Clock policy: VGClockPolicyHybrid (MOD-3 requirement).
//   Source-of-truth: VGClockPolicy.h §"Use for: file playback, timeline scrub"
//   and UMF_V2_01_Core_DAG_Architecture.md §6.5 (clockPolicy: hybrid).
//
// VGGraphPlanner: intentionally NOT called (consistent with Stage 7.5A/B pattern
//   and Opus MOD required modification). The topology is trivially
//   [compositor → sink]; schedulers discover the compositor via the Phase 7
//   self-sourcing-compositor fallback without requiring a VGExecutionPlan.
//
// VGGraphValidator: called after descriptor construction to verify structural
//   integrity (NoSource check patched in Stage 7.5A to accept self-sourcing
//   compositor nodes with zero incoming edges).
//
// ── STAGE BOUNDARIES ───────────────────────────────────────────────────────
//
//   Stage 7.5A — VGTimelineCompositorNode (DONE)
//   Stage 7.5B — Headless execution proof (DONE)
//   Stage 7.5C — This file: visual playback proof via VanguardMetalRenderer
//   Stage 7.6  — ConnectsApp editor integration (deferred)
//
// ── FILES NOT TOUCHED ──────────────────────────────────────────────────────
//
//   VGPlaybackGraphFactory.h/.m       — stable Phase 4 factory, untouched
//   VGTimelineCompositorNode.h/.m     — stable Stage 7.5A node, untouched
//   VGEditorGraphFactory.h/.m         — stable Stage 7.4 factory, untouched
//   VGGraphSchedulerV2.m              — stable push-mode scheduler, untouched
//   packages/UMF/**                   — untouched
//   connectsapp_app/**                — untouched
//
// Pure construction — no state stored. All methods are class methods.
// init is unavailable; do not instantiate this class.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations — full types imported in .m only.
@class VGTimelineCompositorNode;
@class VanguardMetalRenderer;

// ─── VGTimelinePlaybackGraphFactory ──────────────────────────────────────────
/// Phase 7 Stage 7.5C: pure graph-construction factory for the visual timeline
/// playback proof.
///
/// Accepts a pre-initialized VGTimelineCompositorNode and a VanguardMetalRenderer,
/// builds a V2 graph descriptor, validates it, and returns the live node map
/// needed to wire the pull-mode playback loop.
///
/// Does NOT call VGGraphPlanner (trivial compositor → sink topology).
/// Does NOT call prepare/start/invalidate on any node.
/// Does NOT modify VGPlaybackGraphFactory.
///
/// All methods are class methods. This class must not be instantiated.
@interface VGTimelinePlaybackGraphFactory : NSObject

/// Build a V2 timeline playback graph.
///
/// Steps:
///   (a) Build VGGraphNodeDescriptor for the compositor node.
///   (b) Build VGRendererSinkAdapter wrapping the renderer.
///   (c) Build VGGraphNodeDescriptors for both nodes.
///   (d) Build a synchronous, dropLatest VGGraphConnection
///       (timeline:video_out → sink:video_in).
///   (e) Build VGGraphDescriptor with VGClockPolicyHybrid.
///   (f) Validate via VGGraphValidator (patched NoSource check).
///   (g) Return result dictionary.
///
/// @param compositorNode  A fully initialized VGTimelineCompositorNode.
///                        This node is V2-native and does NOT require an adapter.
/// @param renderer        The VanguardMetalRenderer instance to use as the
///                        frame sink. Stored as weak in VGRendererSinkAdapter.
/// @param outError        On failure, set to a descriptive NSError.
///                        On success, set to nil.
/// @return A dictionary on success, or nil on validation failure:
///   @"compositorNode" — the VGTimelineCompositorNode (same as input)
///   @"sinkAdapter"    — VGRendererSinkAdapter wrapping the renderer
///   @"descriptor"     — VGGraphDescriptor (validated)
///   @"nodes"          — NSDictionary<NSString *, id<VGNode>> nodeId → node
+ (nullable NSDictionary<NSString *, id> *)
    buildTimelineGraphWithCompositorNode:(VGTimelineCompositorNode *)compositorNode
                                renderer:(VanguardMetalRenderer *)renderer
                                   error:(NSError * _Nullable * _Nullable)outError;

/// init is unavailable. Use the class method above.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
