// VGOverlayNode.h
// vanguard_media_engine — Phase 8.5
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 8.5 — NATIVE OVERLAY NODE PASS-THROUGH STUB
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGOverlayNode is the first native consumer of the Phase 8.3 VGOverlayDescriptor
// and Phase 8.1 VGCanvasDescriptor data models. It conforms to VGTransformNode
// so it can be inserted into a V2 graph DAG in a future phase once the runtime
// pull loop supports transform node interposition between compositor and sink.
//
// ── PHASE 8.5 SCOPE ─────────────────────────────────────────────────────────
//
//   IMPLEMENTED:
//     • <VGTransformNode> protocol conformance (VGNode + processEnvelope:device:).
//     • Defensive parsing of VGCanvasDescriptor from parameters[@"canvas"].
//     • Defensive parsing of NSArray<VGOverlayDescriptor *> from
//       parameters[@"overlays"].
//     • Pass-through processEnvelope:device: (returns input envelope unchanged).
//     • enabled gate: when NO, returns input envelope unchanged (protocol rule).
//
//   DEFERRED (Phase 8.6+):
//     • Metal / CoreImage rendering of text, emoji, sticker overlays.
//     • Runtime graph wiring (timeline pull loop modification).
//     • Plugin parameter extraction and forwarding.
//     • Asset resolution (VGAssetResolverMVP — Phase 8 full scope).
//     • Audio sidecar / muxing.
//
// ── RUNTIME STATUS ───────────────────────────────────────────────────────────
//
//   NOT wired to any runtime path in Phase 8.5.
//   The timeline pull loop (VanguardGraphRuntime._timelineDisplayLinkFired:) is
//   a direct compositor → sink delivery; processEnvelope:device: is not called
//   in that path. This node is ready to be inserted once the runtime pull loop
//   is updated to interpose transform nodes (Phase 8.6+).
//
// ── CANONICAL REFERENCE ──────────────────────────────────────────────────────
//
//   VGLegacyFilterAdapter.h/.m — canonical VGTransformNode implementation pattern.
//   VGTransformNode.h — protocol definition.
//   VGCanvasDescriptor.h — Phase 8.1 canvas data model.
//   VGOverlayDescriptor.h — Phase 8.3 overlay data model.
//
// ── FILES NOT TOUCHED ────────────────────────────────────────────────────────
//
//   VanguardMediaEnginePlugin.swift
//   VGEditorGraphFactory.h/.m
//   VGTimelinePlaybackGraphFactory.h/.m
//   VanguardGraphRuntime.h/.m
//   VGGraphSchedulerV2.h/.m
//   VGTimelineCompositorNode.h/.m
//   VGTimelineExportHelper.h/.m
//   packages/UMF/**
//   packages/vanguard_media_engine/lib/**
//   packages/vanguard_media_engine/test/**
//   packages/vanguard_media_engine/example/**
//
// Phase 8.5. No Flutter, no FFI, no ConnectsApp, no Metal, no CoreImage.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations — full types imported in .m only.
@class VGCanvasDescriptor;
@class VGOverlayDescriptor;

// ─── VGOverlayNode ────────────────────────────────────────────────────────────

/// Phase 8.5 pass-through stub for timed text/emoji/sticker overlay compositing.
///
/// Conforms to <VGTransformNode> to participate in a V2 graph DAG.
/// In Phase 8.5 the node is pass-through only: processEnvelope:device: returns
/// the input envelope unchanged. Rendering is deferred to Phase 8.6+.
///
/// The node parses a VGCanvasDescriptor and an ordered array of
/// VGOverlayDescriptor objects from its initializer parameters dictionary.
/// All parsing is defensive — missing, nil, or malformed values produce safe
/// defaults (defaultCanvas / empty overlay array) without returning an error.
///
/// **Phase 8.5**: Pass-through only. Not wired to any runtime path.
@interface VGOverlayNode : NSObject <VGTransformNode>

// ─── Identity ─────────────────────────────────────────────────────────────────

/// Stable unique identifier for this node within a graph session.
/// Matches VGGraphNodeDescriptor.nodeId when the node is used in a graph.
@property (nonatomic, readonly, copy) NSString *nodeId;

// ─── VGTransformNode control ──────────────────────────────────────────────────

/// When NO, processEnvelope:device: returns the input envelope unchanged.
/// Default: YES.
/// Hot-parameter: safe to toggle while the graph is running.
@property (nonatomic, assign) BOOL enabled;

/// Declared upper bound on GPU execution time per frame in milliseconds.
/// Phase 8.5 stub: returns 0.0 (pass-through, no GPU work).
/// Must be updated to an accurate value in Phase 8.6 when rendering is added.
@property (nonatomic, readonly) float estimatedGPUCostMs;

// ─── Canvas descriptor ────────────────────────────────────────────────────────

/// The render canvas configuration parsed from parameters[@"canvas"].
///
/// If parameters[@"canvas"] is a valid NSDictionary, it is deserialized via
/// [VGCanvasDescriptor fromDictionary:]. If missing or malformed, falls back
/// to [VGCanvasDescriptor defaultCanvas] (1080×1920, fit, opaque black).
@property (nonatomic, readonly, strong) VGCanvasDescriptor *canvas;

// ─── Overlay descriptors ──────────────────────────────────────────────────────

/// The ordered array of timed overlay elements parsed from parameters[@"overlays"].
///
/// If parameters[@"overlays"] is a valid NSArray, each element that is an
/// NSDictionary is deserialized via [VGOverlayDescriptor fromDictionary:].
/// Non-dictionary elements are skipped. If missing or malformed, returns @[].
@property (nonatomic, readonly, copy) NSArray<VGOverlayDescriptor *> *overlays;

// ─── Designated initializer ───────────────────────────────────────────────────

/// Designated initializer. Parses canvas and overlays from the parameters
/// dictionary. Never returns nil — all parsing failures produce safe defaults.
///
/// @param nodeId     Unique node identifier. Must not be nil.
/// @param parameters Optional parameters dictionary. Recognized keys:
///                     - @"canvas"   : NSDictionary → VGCanvasDescriptor
///                     - @"overlays" : NSArray<NSDictionary *> → VGOverlayDescriptor[]
///                     - @"enabled"  : NSNumber (BOOL); default YES
///                   Unknown keys are silently ignored.
/// @param ports      Port array from VGGraphNodeDescriptor. Accepted but unused
///                   in Phase 8.5 (all ports are declared programmatically).
/// @param outError   Always set to nil in Phase 8.5 (no parse error is fatal).
///                   Reserved for future validation errors. May be NULL.
- (instancetype)initWithNodeId:(NSString *)nodeId
                    parameters:(nullable NSDictionary<NSString *, id> *)parameters
                         ports:(nullable NSArray<VGMediaPort *> *)ports
                         error:(NSError * _Nullable * _Nullable)outError
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
