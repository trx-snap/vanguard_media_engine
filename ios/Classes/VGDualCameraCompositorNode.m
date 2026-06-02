// VGDualCameraCompositorNode.m
// vanguard_media_engine — Phase 7.x-B
//
// Phase 7.x-B skeleton only. Not integrated into the live runtime.
//
// ═══════════════════════════════════════════════════════════════════════════════
// DESIGN OVERVIEW
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGDualCameraCompositorNode is a non-executable skeleton implementing the
// <VGSourceNode> protocol. It:
//   - Parses two VGClipDescriptors (primary + secondary) from the Dart
//     VGDualCameraDescriptor.toMap() wire format.
//   - Parses and stores layout configuration (layoutMode + pipLayout).
//   - Validates all descriptor fields on init; returns nil with a
//     VGDualCameraCompositorNodeErrorDomain error on any validation failure.
//   - Stubs pullFrame:, startProducing, stopProducing, seekTo:generation:,
//     prepareWithContext:completion:, invalidate, declaredPorts, and
//     negotiateFormatForPort:inputFormats:.
//   - Does NOT allocate pixel buffers, open media files, or perform CoreImage work.
//
// ── DEFERRED TO PHASE 7.x-C ─────────────────────────────────────────────────
//
//   • AVAssetReader instantiation for primary and secondary clip decoding.
//   • CoreImage PiP compositing (geometry math from VanguardDualCameraCompositor).
//   • MethodChannel routing in VanguardMediaEnginePlugin.
//   • Integration with VanguardGraphRuntime.prepareTimeline:.
//   • VGExportScheduler dual-camera export path.
//
// ── HARD CONSTRAINTS ─────────────────────────────────────────────────────────
//
//   DO NOT touch VanguardMediaEnginePlugin.swift, VGTimelineCompositorNode.*,
//   VGEditorGraphFactory.*, VanguardDualCameraCompositor.swift,
//   VanguardCompositor.metal, camera/session/capture files, connectsapp_*/,
//   or UMF docs.
//
// ── IMPORTS ──────────────────────────────────────────────────────────────────
//
//   Foundation + UMF headers only.
//   No AVFoundation, CoreMedia, CoreImage, Metal, Flutter.
//   Camera/session headers are intentionally excluded.

#import "VGDualCameraCompositorNode.h"

// ─── UMF protocol / type imports ─────────────────────────────────────────────
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGNode.h>
#import <UMF/VGSourceNode.h>

// ─── System ───────────────────────────────────────────────────────────────────
#import <os/log.h>
#include <stdatomic.h>

// ─── Error domain ────────────────────────────────────────────────────────────
NSString * const VGDualCameraCompositorNodeErrorDomain = @"VGDualCameraCompositorNode";

// ─── Wire keys (mirror Dart VGDualCameraDescriptor.toMap()) ──────────────────
static NSString * const kVGDCCNPrimaryClipKey   = @"primaryClip";
static NSString * const kVGDCCNSecondaryClipKey = @"secondaryClip";
static NSString * const kVGDCCNLayoutModeKey    = @"layoutMode";
static NSString * const kVGDCCNPiPLayoutKey     = @"pipLayout";

// ─── PiP layout wire keys (mirror Dart VGPiPLayoutDescriptor.toMap()) ────────
static NSString * const kVGDCCNPiPAnchorKey         = @"anchor";
static NSString * const kVGDCCNPiPWidthFractionKey  = @"widthFraction";
static NSString * const kVGDCCNPiPMarginFractionKey = @"marginFraction";
static NSString * const kVGDCCNPiPCornerRadiusKey   = @"cornerRadius";
static NSString * const kVGDCCNPiPOpacityKey        = @"opacity";

// ─── Private error factory ────────────────────────────────────────────────────
static NSError *_VGDCCNError(VGDualCameraCompositorNodeErrorCode code, NSString *message) {
    return [NSError errorWithDomain:VGDualCameraCompositorNodeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// ─── Private helpers ──────────────────────────────────────────────────────────

/// Parses a VGPiPAnchor from its wire string value.
/// Returns VGPiPAnchorBottomRight for any unrecognized value (same as Dart default).
static VGPiPAnchor _VGDCCNPiPAnchorFromString(NSString * _Nullable str) {
    if ([str isEqualToString:@"topLeft"])     return VGPiPAnchorTopLeft;
    if ([str isEqualToString:@"topRight"])    return VGPiPAnchorTopRight;
    if ([str isEqualToString:@"bottomLeft"])  return VGPiPAnchorBottomLeft;
    return VGPiPAnchorBottomRight; // default
}

/// Parses a VGPiPLayoutConfig from a Dart-side pipLayout dictionary.
/// Missing or invalid keys fall back to defaults matching Dart VGPiPLayoutDescriptor.
static VGPiPLayoutConfig _VGDCCNParsePiPLayout(NSDictionary<NSString *, id> * _Nullable dict) {
    VGPiPLayoutConfig cfg;

    // Defaults mirror Dart const VGPiPLayoutDescriptor() defaults.
    cfg.anchor         = VGPiPAnchorBottomRight;
    cfg.widthFraction  = 0.35;
    cfg.marginFraction = 0.018;
    cfg.cornerRadius   = 24.0;
    cfg.opacity        = 1.0;

    if (!dict || ![dict isKindOfClass:[NSDictionary class]]) {
        return cfg; // return defaults
    }

    NSString *anchorStr = dict[kVGDCCNPiPAnchorKey];
    if ([anchorStr isKindOfClass:[NSString class]]) {
        cfg.anchor = _VGDCCNPiPAnchorFromString(anchorStr);
    }

    NSNumber *wf = dict[kVGDCCNPiPWidthFractionKey];
    if ([wf isKindOfClass:[NSNumber class]] &&
        wf.doubleValue >= 0.05 && wf.doubleValue <= 0.75) {
        cfg.widthFraction = wf.doubleValue;
    }

    NSNumber *mf = dict[kVGDCCNPiPMarginFractionKey];
    if ([mf isKindOfClass:[NSNumber class]] && mf.doubleValue >= 0.0) {
        cfg.marginFraction = mf.doubleValue;
    }

    NSNumber *cr = dict[kVGDCCNPiPCornerRadiusKey];
    if ([cr isKindOfClass:[NSNumber class]] && cr.doubleValue >= 0.0) {
        cfg.cornerRadius = cr.doubleValue;
    }

    NSNumber *op = dict[kVGDCCNPiPOpacityKey];
    if ([op isKindOfClass:[NSNumber class]] &&
        op.doubleValue >= 0.0 && op.doubleValue <= 1.0) {
        cfg.opacity = op.doubleValue;
    }

    return cfg;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGDualCameraCompositorNode
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGDualCameraCompositorNode {
    // VGNode identity fields.
    NSString       *_nodeId;
    NSArray<id>    *_ports;       // stored for declaredPorts; unused in 7.x-B

    // Invalidation guard (atomic per VGNode contract).
    atomic_bool     _invalidated;
}

@synthesize primaryClip   = _primaryClip;
@synthesize secondaryClip = _secondaryClip;
@synthesize layoutMode    = _layoutMode;
@synthesize pipLayout     = _pipLayout;

// ─── Designated initializer ───────────────────────────────────────────────────

- (nullable instancetype)initWithNodeId:(NSString *)nodeId
                             parameters:(NSDictionary<NSString *, id> *)parameters
                                  ports:(NSArray<id> *)ports
                                  error:(NSError * _Nullable * _Nullable)outError {
    NSParameterAssert(nodeId.length > 0);
    NSParameterAssert(parameters);

    // ── 1. Parse primaryClip ────────────────────────────────────────────────

    id primaryRaw = parameters[kVGDCCNPrimaryClipKey];
    if (![primaryRaw isKindOfClass:[NSDictionary class]]) {
        if (outError) {
            *outError = _VGDCCNError(
                VGDualCameraCompositorNodeErrorMissingPrimaryClip,
                @"VGDualCameraCompositorNode: parameters missing or invalid 'primaryClip' key.");
        }
        return nil;
    }

    VGClipDescriptor *primary = [VGClipDescriptor fromDictionary:(NSDictionary<NSString *, id> *)primaryRaw];
    if (!primary) {
        if (outError) {
            *outError = _VGDCCNError(
                VGDualCameraCompositorNodeErrorInvalidPrimaryClip,
                @"VGDualCameraCompositorNode: primaryClip failed +fromDictionary: — "
                 "descriptor is nil or contains invalid field values.");
        }
        return nil;
    }

    if (![primary isValid]) {
        if (outError) {
            *outError = _VGDCCNError(
                VGDualCameraCompositorNodeErrorInvalidPrimaryClip,
                ([NSString stringWithFormat:
                    @"VGDualCameraCompositorNode: primaryClip id='%@' failed -isValid.",
                    primary.clipId]));
        }
        return nil;
    }

    // ── 2. Parse secondaryClip ──────────────────────────────────────────────

    id secondaryRaw = parameters[kVGDCCNSecondaryClipKey];
    if (![secondaryRaw isKindOfClass:[NSDictionary class]]) {
        if (outError) {
            *outError = _VGDCCNError(
                VGDualCameraCompositorNodeErrorMissingSecondaryClip,
                @"VGDualCameraCompositorNode: parameters missing or invalid 'secondaryClip' key.");
        }
        return nil;
    }

    VGClipDescriptor *secondary = [VGClipDescriptor fromDictionary:(NSDictionary<NSString *, id> *)secondaryRaw];
    if (!secondary) {
        if (outError) {
            *outError = _VGDCCNError(
                VGDualCameraCompositorNodeErrorInvalidSecondaryClip,
                @"VGDualCameraCompositorNode: secondaryClip failed +fromDictionary: — "
                 "descriptor is nil or contains invalid field values.");
        }
        return nil;
    }

    if (![secondary isValid]) {
        if (outError) {
            *outError = _VGDCCNError(
                VGDualCameraCompositorNodeErrorInvalidSecondaryClip,
                ([NSString stringWithFormat:
                    @"VGDualCameraCompositorNode: secondaryClip id='%@' failed -isValid.",
                    secondary.clipId]));
        }
        return nil;
    }

    // ── 3. Validate no duplicate clip IDs ───────────────────────────────────

    if ([primary.clipId isEqualToString:secondary.clipId]) {
        if (outError) {
            *outError = _VGDCCNError(
                VGDualCameraCompositorNodeErrorDuplicateClipId,
                ([NSString stringWithFormat:
                    @"VGDualCameraCompositorNode: primaryClip and secondaryClip share the "
                     "same clipId='%@'. Each clip must have a unique ID.",
                    primary.clipId]));
        }
        return nil;
    }

    // ── 4. Parse and validate layoutMode ────────────────────────────────────
    //
    // Phase 7.x-B only supports "pip". Other values are rejected with a clear
    // error rather than silently falling back, to prevent misconfigured
    // callers from receiving a wrong-mode skeleton.

    NSString *layoutModeStr = parameters[kVGDCCNLayoutModeKey];
    VGDualCameraLayoutMode parsedLayoutMode = VGDualCameraLayoutModePiP; // default
    if (layoutModeStr != nil) {
        if (![layoutModeStr isKindOfClass:[NSString class]] ||
            ![layoutModeStr isEqualToString:@"pip"]) {
            if (outError) {
                *outError = _VGDCCNError(
                    VGDualCameraCompositorNodeErrorUnsupportedLayoutMode,
                    ([NSString stringWithFormat:
                        @"VGDualCameraCompositorNode: unsupported layoutMode '%@'. "
                         "Phase 7.x-B only supports 'pip'.",
                        layoutModeStr]));
            }
            return nil;
        }
        // layoutModeStr == @"pip" → parsedLayoutMode already VGDualCameraLayoutModePiP.
    }

    // ── 5. Parse pipLayout (optional; defaults on missing/invalid) ───────────

    id pipLayoutRaw = parameters[kVGDCCNPiPLayoutKey];
    VGPiPLayoutConfig parsedPipLayout = _VGDCCNParsePiPLayout(
        [pipLayoutRaw isKindOfClass:[NSDictionary class]] ? pipLayoutRaw : nil);

    // ── 6. Commit ────────────────────────────────────────────────────────────

    self = [super init];
    if (!self) { return nil; }

    _nodeId       = [nodeId copy];
    _ports        = ports ? [ports copy] : @[];
    _primaryClip   = primary;
    _secondaryClip = secondary;
    _layoutMode    = parsedLayoutMode;
    _pipLayout     = parsedPipLayout;
    atomic_store(&_invalidated, false);

    NSLog(@"[VGDualCameraCompositorNode][7.x-B] init ok | nodeId=%@ | "
          "primary=%@ | secondary=%@ | layoutMode=pip | "
          "pipLayout={anchor=%ld wf=%.3f mf=%.3f cr=%.1f op=%.2f}",
          _nodeId,
          _primaryClip.clipId,
          _secondaryClip.clipId,
          (long)parsedPipLayout.anchor,
          parsedPipLayout.widthFraction,
          parsedPipLayout.marginFraction,
          parsedPipLayout.cornerRadius,
          parsedPipLayout.opacity);

    return self;
}

// ─── VGNode protocol — identity ───────────────────────────────────────────────

- (NSString *)nodeId {
    return _nodeId;
}

- (NSString *)nodeClass {
    return @"VGDualCameraCompositorNode";
}

- (VGNodeRole)nodeRole {
    // Topology role: compositor (multi-source → single video_out).
    // Matches VGNodeRoleCompositor used by VGTimelineCompositorNode.
    return VGNodeRoleCompositor;
}

// ─── VGNode protocol — ports ──────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    // Phase 7.x-B: returns a single video_out port.
    // Mirrors VGTimelineCompositorNode port declaration convention.
    // Actual port set will be revisited in 7.x-C when runtime integration begins.
    return @[[VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo]];
}

// ─── VGNode protocol — lifecycle ─────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Phase 7.x-B skeleton only; decoding and PiP composition deferred to 7.x-C.
    // Calls completion asynchronously (on a background queue) with no error,
    // matching the contract documented in VGNode.h:
    //   "completion fires on a background queue, never synchronously."
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completion(nil);
    });
}

- (void)invalidate {
    // Idempotent guard. atomic_exchange returns the old value; if it was already
    // true, invalidation already happened. Second call is a safe no-op.
    if (atomic_exchange(&_invalidated, true)) {
        return; // already invalidated
    }
    // Phase 7.x-B: no resources to release. No AVAssetReader, no pixel buffers.
    // 7.x-C will release decoded buffers and cancel any in-flight readers here.
}

// ─── VGNode protocol — format negotiation ────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 7.x-B skeleton only; format negotiation deferred to 7.x-C.
    // Returning nil here is safe: VGGraphPlanner treats nil as "unable to negotiate"
    // and skips format propagation for unexecuted skeleton nodes.
    return nil;
}

// ─── VGNode protocol — nodeType (legacy VGMediaNode compat) ──────────────────

- (NSString *)nodeType {
    return @"VGDualCameraCompositorNode";
}

// ─── VGSourceNode protocol — push-mode production ────────────────────────────

- (void)startProducing {
    // Push-mode is not applicable to a pull-based compositor.
    // Phase 7.x-B skeleton only — no-op.
}

- (void)stopProducing {
    // Phase 7.x-B skeleton only — no-op.
}

// ─── VGSourceNode protocol — pull-mode production ────────────────────────────

- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    // Phase 7.x-B skeleton only; decoding and PiP composition deferred to 7.x-C.
    //
    // VGFrameStatusSkipped is semantically correct here:
    //   - The node is a non-executable skeleton.
    //   - Returning Skipped matches the pattern used by VGCameraSourceAdapter
    //     (push-only source, pull not applicable) and signals to the scheduler
    //     that no frame is available without indicating a failure or EOS.
    //   - Returning EndOfStream would incorrectly terminate the graph.
    //   - Returning Error would surface as a user-visible failure.
    //
    // Phase 7.x-C will replace this with:
    //   - Primary clip AVAssetReader decode at request.requestedPTS.
    //   - Secondary clip AVAssetReader decode at request.requestedPTS.
    //   - CoreImage PiP compositing (reusing geometry from VanguardDualCameraCompositor).
    //   - Delivery of the composited CVPixelBuffer via VGFrameResult.deliveredWithEnvelope:.
    return [VGFrameResult skippedWithGeneration:request.generation];
}

// ─── VGSourceNode protocol — seek ────────────────────────────────────────────

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
    // Phase 7.x-B skeleton only — no-op.
    // Phase 7.x-C will store `generation` atomically and cancel the active readers here.
    (void)time;
    (void)generation;
}

@end
