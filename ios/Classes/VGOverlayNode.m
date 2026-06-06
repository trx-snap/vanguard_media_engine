// VGOverlayNode.m
// vanguard_media_engine — Phase 8.5
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 8.5 — NATIVE OVERLAY NODE PASS-THROUGH STUB
// ═══════════════════════════════════════════════════════════════════════════════
//
// Implementation of VGOverlayNode.
//
// This file does NOT import:
//   VanguardMediaEnginePlugin, VGEditorGraphFactory,
//   VGTimelinePlaybackGraphFactory, VanguardGraphRuntime,
//   VGGraphSchedulerV2, VGTimelineCompositorNode,
//   VGTimelineExportHelper, any Metal shader, any Flutter type,
//   any AVFoundation type, any CoreImage type.
//
// The only runtime behavior is:
//   1. Parse VGCanvasDescriptor from parameters[@"canvas"] (defensive).
//   2. Parse NSArray<VGOverlayDescriptor *> from parameters[@"overlays"] (defensive).
//   3. processEnvelope:device: returns the input envelope unchanged.
//
// All VGNode protocol requirements follow the VGLegacyFilterAdapter pattern.

#import "VGOverlayNode.h"

// ─── Phase 8.1 canvas descriptor ─────────────────────────────────────────────
#import <UMF/VGCanvasDescriptor.h>

// ─── Phase 8.3 overlay descriptor ────────────────────────────────────────────
#import <UMF/VGOverlayDescriptor.h>

// ─── UMF graph context (required by VGNode lifecycle) ────────────────────────
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGNode.h>

// ─── System ──────────────────────────────────────────────────────────────────
#import <os/log.h>

// ─── Module-private log ───────────────────────────────────────────────────────
static os_log_t sOverlayNodeLog;

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - @implementation VGOverlayNode
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGOverlayNode {
    NSString                       *_nodeId;
    BOOL                            _enabled;
    VGCanvasDescriptor             *_canvas;
    NSArray<VGOverlayDescriptor *> *_overlays;
}

// ─── Module initialization ────────────────────────────────────────────────────

+ (void)initialize {
    if (self == [VGOverlayNode class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sOverlayNodeLog = os_log_create("com.vanguard.engine", "VGOverlayNode");
        });
    }
}

// ─── Designated initializer ───────────────────────────────────────────────────

- (instancetype)initWithNodeId:(NSString *)nodeId
                    parameters:(nullable NSDictionary<NSString *, id> *)parameters
                         ports:(nullable NSArray<VGMediaPort *> *)ports
                         error:(NSError * _Nullable * _Nullable)outError {
    NSParameterAssert(nodeId != nil);

    self = [super init];
    if (!self) return nil;

    _nodeId = [nodeId copy];

    // ── enabled ──────────────────────────────────────────────────────────────
    // Default YES. If parameters supplies an NSNumber for "enabled", honour it.
    id enabledRaw = parameters[@"enabled"];
    if ([enabledRaw isKindOfClass:[NSNumber class]]) {
        _enabled = [(NSNumber *)enabledRaw boolValue];
    } else {
        _enabled = YES;
    }

    // ── canvas ───────────────────────────────────────────────────────────────
    // Defensive parse: NSDictionary → VGCanvasDescriptor.
    // Any missing or non-dictionary value falls back to the UMF default canvas.
    id canvasRaw = parameters[@"canvas"];
    if ([canvasRaw isKindOfClass:[NSDictionary class]]) {
        VGCanvasDescriptor *parsed =
            [VGCanvasDescriptor fromDictionary:(NSDictionary *)canvasRaw];
        _canvas = parsed ?: [VGCanvasDescriptor defaultCanvas];
    } else {
        _canvas = [VGCanvasDescriptor defaultCanvas];
    }

    // ── overlays ─────────────────────────────────────────────────────────────
    // Defensive parse: NSArray<NSDictionary *> → NSArray<VGOverlayDescriptor *>.
    // Non-array values → empty array.
    // Non-dictionary elements within the array → skipped (defensive).
    id overlaysRaw = parameters[@"overlays"];
    if ([overlaysRaw isKindOfClass:[NSArray class]]) {
        NSArray *rawArray = (NSArray *)overlaysRaw;
        NSMutableArray<VGOverlayDescriptor *> *parsed =
            [NSMutableArray arrayWithCapacity:rawArray.count];
        for (id element in rawArray) {
            if (![element isKindOfClass:[NSDictionary class]]) {
                os_log_debug(sOverlayNodeLog,
                             "[VGOverlayNode] overlays: skipping non-dictionary element "
                             "(class=%{public}@)",
                             NSStringFromClass([element class]));
                continue;
            }
            VGOverlayDescriptor *descriptor =
                [VGOverlayDescriptor fromDictionary:(NSDictionary *)element];
            if (descriptor) {
                [parsed addObject:descriptor];
            }
        }
        _overlays = [parsed copy];
    } else {
        _overlays = @[];
    }

    // ── outError ─────────────────────────────────────────────────────────────
    // Phase 8.5: no parse failure is fatal. Always clear the error output.
    if (outError) {
        *outError = nil;
    }

    os_log_debug(sOverlayNodeLog,
                 "[VGOverlayNode] init: nodeId=%{public}@ enabled=%d "
                 "canvas=%ldx%ld overlays=%lu",
                 _nodeId, (int)_enabled,
                 (long)_canvas.width, (long)_canvas.height,
                 (unsigned long)_overlays.count);

    return self;
}

// ─── VGNode — Identity ────────────────────────────────────────────────────────

- (NSString *)nodeId {
    return _nodeId;
}

- (NSString *)nodeClass {
    return NSStringFromClass([self class]);
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

// ─── VGNode — Port declaration ────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    // Standard single-input / single-output video transform port pair.
    // Matches the port names used by VGLegacyFilterAdapter.
    return @[
        [VGMediaPort inputPort:@"video_in"
                     mediaType:VGMediaTypeVideo
                      required:YES],
        [VGMediaPort outputPort:@"video_out"
                      mediaType:VGMediaTypeVideo],
    ];
}

// ─── VGNode — Lifecycle ───────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Phase 8.5: no resources to warm up. Fire completion immediately.
    // Context is accepted for API symmetry and future Phase 8.6 use.
    (void)context;
    os_log_debug(sOverlayNodeLog,
                 "[VGOverlayNode] prepareWithContext: nodeId=%{public}@", _nodeId);
    completion(nil);
}

- (void)invalidate {
    // Phase 8.5: no resources held; nothing to release.
    os_log_debug(sOverlayNodeLog,
                 "[VGOverlayNode] invalidate: nodeId=%{public}@", _nodeId);
}

// ─── VGNode — Format negotiation (Phase 8.5 stub) ────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 8.5 stub. Format negotiation deferred to Phase 8.6+.
    // Return nil per VGLegacyFilterAdapter Phase 3 stub precedent.
    (void)portId;
    (void)inputFormats;
    return nil;
}

// ─── VGTransformNode — Control ────────────────────────────────────────────────

- (BOOL)enabled {
    return _enabled;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
}

- (float)estimatedGPUCostMs {
    // Phase 8.5 pass-through: no GPU work. Return 0.0.
    // Must be updated to an accurate value when rendering is added (Phase 8.6+).
    return 0.0f;
}

// ─── VGTransformNode — Frame processing ──────────────────────────────────────

/// Pass-through implementation.
///
/// Phase 8.5: no rendering. Returns the input envelope unchanged in ALL cases:
///   - When enabled == NO  (protocol requirement)
///   - When enabled == YES (Phase 8.5 stub — rendering deferred)
///
/// No pixel buffer modification. No metadata modification. No Metal work.
/// No CVPixelBuffer retain/release (source-owned buffer contract preserved).
///
/// DEC-58: executes synchronously, sub-microsecond, no GPU work.
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    // device is accepted to satisfy the protocol signature.
    // No GPU work is performed in Phase 8.5.
    (void)device;

    // Return input envelope unchanged.
    // Buffer ownership is NOT transferred — source retains its +1.
    return envelope;
}

// ─── Canvas and overlay accessors ─────────────────────────────────────────────

- (VGCanvasDescriptor *)canvas {
    return _canvas;
}

- (NSArray<VGOverlayDescriptor *> *)overlays {
    return _overlays;
}

@end
