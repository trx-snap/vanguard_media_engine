// VGOverlayNode.h
// vanguard_media_engine — Phase 8.5 / Phase 8.7
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 8.5 — NATIVE OVERLAY NODE PASS-THROUGH STUB
// PHASE 8.7 — EXPORT-ONLY DEBUG RECTANGLE RENDERING
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGOverlayNode is the native consumer of the Phase 8.3 VGOverlayDescriptor
// and Phase 8.1 VGCanvasDescriptor data models. It conforms to VGTransformNode
// so it participates in the V2 graph DAG between VGTimelineCompositorNode and
// VGVideoEncoderSinkNode during export.
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
// ── PHASE 8.7 SCOPE ─────────────────────────────────────────────────────────
//
//   IMPLEMENTED:
//     • Export-only debug rectangle rendering via CoreImage.
//     • Active overlay filtering by PTS (envelope.pts).
//     • zIndex-sorted compositing using CISourceOverCompositing.
//     • Solid semi-transparent red rectangles representing overlay bounds.
//     • Overlay geometry: translationX/Y, width, height, scale, rotation, opacity.
//     • Canvas → output coordinate scaling (scaleX/scaleY).
//     • CoreImage Y-axis flip (top-left canvas → bottom-left CoreImage).
//     • Rotation via CGAffineTransform around rectangle center.
//     • New CVPixelBuffer allocated only when active overlays exist.
//     • Fast pass-through when no overlays are active (zero allocation).
//     • Fallback to original envelope on any render failure.
//     • Shared static CIContext singleton (dispatch_once).
//     • estimatedGPUCostMs updated to 2.0f.
//
//   DEFERRED (Phase 8.8+):
//     • CoreText / CTFont text rasterization.
//     • Emoji glyph rendering.
//     • Sticker / image loading and decoding.
//     • Asset resolver (VGAssetResolverMVP).
//     • CVPixelBufferPool optimization.
//     • Runtime / preview graph wiring.
//     • Plugin parameter extraction and forwarding.
//     • Audio sidecar / muxing.
//
// ── RUNTIME STATUS ───────────────────────────────────────────────────────────
//
//   Phase 8.6 wired VGOverlayNode into the export graph between
//   VGTimelineCompositorNode and VGVideoEncoderSinkNode (conditional on
//   overlays being non-empty). The preview runtime is NOT wired — this node
//   is export-only in Phase 8.7.
//
//   processEnvelope:device: fast path:
//     When no overlays are active for the current PTS, the original envelope is
//     returned EXACTLY unchanged. No buffer allocation. No CoreImage invocation.
//
//   processEnvelope:device: render path:
//     When active overlays exist, a new CVPixelBuffer is allocated via
//     CVPixelBufferCreate. Active overlays are composited as solid rectangles
//     over the input frame. The new buffer is returned at +1; VGExportScheduler
//     owns and releases it after sink delivery (RR-36).
//
// ── BUFFER OWNERSHIP (RR-36) ─────────────────────────────────────────────────
//
//   The output buffer returned during rendering is at +1 from CVPixelBufferCreate.
//   VGExportScheduler detects (newBuffer != frame) and takes ownership.
//   VGOverlayNode never retains or releases the output buffer.
//   The input CVPixelBuffer is never mutated in place.
//
// ── CANONICAL REFERENCE ──────────────────────────────────────────────────────
//
//   VGLegacyFilterAdapter.h/.m — canonical VGTransformNode implementation pattern.
//   VGTransformNode.h — protocol definition.
//   VGCanvasDescriptor.h — Phase 8.1 canvas data model.
//   VGOverlayDescriptor.h — Phase 8.3 overlay data model.
//   VGTimelineCompositorNode.m — CIContext / CVPixelBufferCreate patterns.
//   VGExportScheduler.m — RR-36 buffer ownership / pointer-comparison logic.
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
//   VGExportScheduler.h/.m
//   VGVideoEncoderSinkNode.h/.m
//   packages/UMF/**
//   packages/vanguard_media_engine/lib/**
//   packages/vanguard_media_engine/test/**
//   packages/vanguard_media_engine/example/**
//
// Phase 8.7. Export-only. No Flutter, no FFI, no ConnectsApp, no Metal shaders,
// no CoreText, no AVFoundation, no preview runtime wiring.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations — full types imported in .m only.
@class VGCanvasDescriptor;
@class VGOverlayDescriptor;

// ─── VGOverlayNode ────────────────────────────────────────────────────────────

/// Phase 8.5/8.7 overlay compositing node for timed text/emoji/sticker overlays.
///
/// Conforms to <VGTransformNode> to participate in a V2 graph DAG.
///
/// **Phase 8.7 behaviour**:
///   - When no overlays are active for the current PTS, the input envelope is
///     returned unchanged (zero allocation, zero CoreImage work).
///   - When active overlays exist, renders solid semi-transparent debug
///     rectangles using CoreImage and returns a new CVPixelBuffer at +1.
///     VGExportScheduler owns and releases the output buffer after delivery.
///   - Export-only. Preview runtime wiring is deferred to Phase 8.8+.
///
/// The node parses a VGCanvasDescriptor and an ordered array of
/// VGOverlayDescriptor objects from its initializer parameters dictionary.
/// All parsing is defensive — missing, nil, or malformed values produce safe
/// defaults (defaultCanvas / empty overlay array) without returning an error.
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
/// Phase 8.7: 2.0ms conservative estimate for CoreImage compositing at 1080p.
/// DEC-58: VGGraphSchedulerV2 uses this for GPU budget enforcement.
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
///                   (all ports are declared programmatically).
/// @param outError   Always set to nil (no parse error is fatal).
///                   Reserved for future validation errors. May be NULL.
- (instancetype)initWithNodeId:(NSString *)nodeId
                    parameters:(nullable NSDictionary<NSString *, id> *)parameters
                         ports:(nullable NSArray<VGMediaPort *> *)ports
                         error:(NSError * _Nullable * _Nullable)outError
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
