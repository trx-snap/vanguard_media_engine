// VGTimelineCompositorNode.h
// vanguard_media_engine — Phase 7 Stage 7.5
//
// VGTimelineCompositorNode is the first executable multi-clip timeline compositor.
//
// ═══════════════════════════════════════════════════════════════════════════════
// DUAL NATURE: DESCRIPTOR ROLE vs. RUNTIME PROTOCOL
// ═══════════════════════════════════════════════════════════════════════════════
//
// Descriptor / topology role:  VGNodeRoleCompositor (= 3)
//   - Stored in VGGraphNodeDescriptor.nodeRole.
//   - Matches §6.5 canonical: "role: compositor".
//   - VGEditorGraphFactory sets this role when building the graph descriptor.
//   - nodeRole property returns VGNodeRoleCompositor at runtime.
//
// Runtime execution protocol:  <VGSourceNode>
//   - This node self-sources: it internally manages AVAssetReader instances,
//     one per clip, and exposes a single video_out pull port.
//   - VGGraphSchedulerV2 and VGExportScheduler discover it via the Phase 7
//     self-sourcing-compositor fallback (MOD-1 of Opus validation).
//   - Conforms to <VGSourceNode>: pullFrame: / seekTo:generation:.
//
// ── STAGE 7.5 FIRST EXECUTABLE SLICE — SCOPE ──────────────────────────────────
//
//   SUPPORTED in this slice:
//     • Multi-clip video timelines (VGClipMediaKindVideo only).
//     • High-precision global-PTS → clip-local asset PTS mapping.
//     • AVAssetReader-based sequential per-clip video decoding.
//     • Hard-cut (VGTransitionTypeNone) and zero-duration transitions.
//     • Generation-safe pull: stale frames across seeks are always suppressed.
//     • Buffer lifecycle safety per RR-36 (CVPixelBuffer retain/release).
//
//   UNSUPPORTED in this slice (deferred):
//     • Still-image clips (VGClipMediaKindImage) — rejected at prepare time.
//     • Fade / cross-dissolve transition blending — rejected at init time.
//     • Audio — no audio tracks decoded or forwarded (Phase 8+).
//     • GPU / Core Image / Metal blending (Phase 7.5B+).
//     • Pre-warming of next clip reader (performance optimisation, later).
//
// ── DESCRIPTORSSTAGE GUARD ────────────────────────────────────────────────────
//
//   This node rejects initialization from Stage 7.4 non-executable descriptors.
//   Descriptors must set parameters[@"descriptorStage"] = @"7.5_executable".
//   Initialization returns nil (via error) for "7.4_non_executable".
//
// ── IMPORTS ──────────────────────────────────────────────────────────────────
//
//   #import <UMF/VGSourceNode.h>  — pull-mode VGNode + VGSourceNode protocol.
//   #import <UMF/VGMediaPort.h>   — for port declarations in declaredPorts.
//
// Phase 7 Stage 7.5. No Flutter, no FFI, no ConnectsApp, no audio, no Metal.
//
// PLATFORM: AVFoundation — AVAssetReader, AVAssetReaderTrackOutput (iOS 14.0+).

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGSourceNode.h>

@class VGMediaPort;

NS_ASSUME_NONNULL_BEGIN

// ─── VGTimelineCompositorNode ─────────────────────────────────────────────────
/// Phase 7 Stage 7.5 self-sourcing timeline compositor node.
///
/// Conforms to <VGSourceNode> for pull-mode integration with VGGraphSchedulerV2
/// and VGExportScheduler. Returns VGNodeRoleCompositor from nodeRole to match
/// the topology descriptor (VGEditorGraphFactory / §6.5).
///
/// Deserialized from VGGraphNodeDescriptor parameters:
///   parameters[@"clips"]           — NSArray<NSDictionary *> of clip descriptors.
///   parameters[@"transitions"]     — NSArray<NSDictionary *> of transition descriptors.
///   parameters[@"descriptorStage"] — must be @"7.5_executable".
///
/// First-slice limitations:
///   Video clips only. Image and audio clips are rejected at prepare time.
///   Non-hard-cut transitions (fade, dissolve) are rejected at init time.
///   Audio is not decoded. Timeline produces video frames only.
@interface VGTimelineCompositorNode : NSObject <VGSourceNode>

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize from the graph node descriptor parameters produced by VGEditorGraphFactory.
///
/// @param nodeId     The nodeId matching the corresponding VGGraphNodeDescriptor.
/// @param parameters The parameters dictionary from VGGraphNodeDescriptor.
///                   Must contain:
///                     - @"descriptorStage": @"7.5_executable"
///                     - @"clips": NSArray<NSDictionary *>
///                     - @"transitions": NSArray<NSDictionary *> (may be empty)
/// @param ports      The ports array from VGGraphNodeDescriptor.
///
/// Returns nil if:
///   - parameters[@"descriptorStage"] is @"7.4_non_executable".
///   - parameters[@"clips"] is missing or empty after deserialization.
///   - A non-hard-cut transition (fade/dissolve) is present (Stage 7.5 limitation).
///   - Any clip has mediaKind other than VGClipMediaKindVideo.
- (nullable instancetype)initWithNodeId:(NSString *)nodeId
                             parameters:(NSDictionary<NSString *, id> *)parameters
                                  ports:(NSArray<VGMediaPort *> *)ports
                                  error:(NSError * _Nullable * _Nullable)outError
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
