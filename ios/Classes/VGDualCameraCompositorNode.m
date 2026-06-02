// VGDualCameraCompositorNode.m
// vanguard_media_engine — Phase 7.x-B / Phase 7.x-F
//
// Phase 7.x-B skeleton only. Not integrated into the live runtime.
// Phase 7.x-F: Primary clip AVAssetReader added. pullFrame: now decodes
//              and returns primary clip frames with correct sample-window
//              pacing. Secondary remains parsed/stored but is not decoded
//              or rendered.
// Phase 7.x-F (patch): Adds sample-window reuse guard (RR-146 equivalent).
//   _primaryLastSamplePTS / _primaryLastSampleDuration track the cached
//   sample window. pullFrame: maps request.requestedPTS → assetTime using
//   trimStartSeconds + elapsed * speed, and reuses the cached pixel buffer
//   while the requested asset time falls inside [lastSamplePTS, lastSamplePTS
//   + lastSampleDuration). copyNextSampleBuffer is called only when the
//   current cached window does not cover the requested time.
//
// ═══════════════════════════════════════════════════════════════════════════════
// DESIGN OVERVIEW
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGDualCameraCompositorNode is a <VGSourceNode>-conforming compositor. It:
//   - Parses two VGClipDescriptors (primary + secondary) from the Dart
//     VGDualCameraDescriptor.toMap() wire format.
//   - Parses and stores layout configuration (layoutMode + pipLayout).
//   - Validates all descriptor fields on init; returns nil with a
//     VGDualCameraCompositorNodeErrorDomain error on any validation failure.
//   - Phase 7.x-F: Lazily initializes an AVAssetReader for the primaryClip
//     on the first pullFrame: call, and vends decoded BGRA pixel buffers.
//   - Phase 7.x-F: Uses AVAssetReaderVideoCompositionOutput with an
//     AVMutableVideoComposition to bake preferredTransform (orientation
//     normalization identical to the Phase 7.9 timeline path).
//   - Phase 7.x-F: seekTo:generation: cancels the active reader, increments
//     the atomic generation, and forces a rebuild on the next pullFrame:.
//   - Secondary clip remains parsed/stored but unused. No PiP. No CoreImage.
//
// ── SUPPORTED CLIP SHAPES (Phase 7.x-F) ─────────────────────────────────────
//
//   SUPPORTED:
//     • primaryClip.mediaKind == VGClipMediaKindVideo
//     • primaryClip.freezePTS == nil (not a freeze-frame clip)
//     • primaryClip.isReversed == NO (forward playback only)
//     • primaryClip.sourceURL: valid absolute path to a readable video file
//
//   UNSUPPORTED (logged and return skippedWithGeneration:):
//     • still-image clips (VGClipMediaKindImage)
//     • freeze-frame clips (freezePTS != nil)
//     • reversed clips (isReversed == YES)
//     • missing or invalid source path
//     • unsupported media kinds
//
// ── DEFERRED TO PHASE 7.x-G ─────────────────────────────────────────────────
//
//   • Secondary clip AVAssetReader
//   • CoreImage PiP compositing (CISourceOverCompositing + geometry)
//   • Still / freeze / reverse descriptor support
//   • Audio
//   • Export path
//
// ── HARD CONSTRAINTS ─────────────────────────────────────────────────────────
//
//   DO NOT touch VanguardMediaEnginePlugin.swift, VGTimelineCompositorNode.*,
//   VGEditorGraphFactory.*, VanguardDualCameraCompositor.swift,
//   VanguardCompositor.metal, camera/session/capture files, connectsapp_*/,
//   or UMF docs.
//   DO NOT touch AVCaptureMultiCamSession or VGMultiCamSessionController.
//   DO NOT start Phase 8.
//
// ── IMPORTS ──────────────────────────────────────────────────────────────────
//
//   Foundation + UMF headers.
//   AVFoundation, CoreMedia, CoreVideo for Phase 7.x-F reader path.
//   No camera/session headers.

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

// ─── Phase 7.x-F: AVFoundation / CoreMedia / CoreVideo ───────────────────────
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

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

// ─── Phase 7.x-F: Output settings for AVAssetReaderVideoCompositionOutput ────
// Match VGTimelineCompositorNode Phase 7.9 output settings:
// 32BGRA + Metal + IOSurface. Same pixel format as the playback path for
// downstream renderer compatibility.
static NSDictionary *_VGDCCNOutputSettings(void) {
    return @{
        (id)kCVPixelBufferPixelFormatTypeKey  : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
}

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

// ─── Phase 7.x-F: Private class extension for reader state ───────────────────
//
// All AVAssetReader state is kept here in the .m class extension, not in the
// public header. This follows the hard constraint to avoid exposing AVFoundation
// in the public interface.
//
// Reader lifecycle:
//   - _primaryReader / _primaryOutput: allocated lazily on the first pullFrame:
//     call, when _primaryReader is nil and the node is not invalidated.
//   - Released and rebuilt on seekTo:generation: and on invalidate.
//   - Thread safety: pullFrame: and seekTo:generation: are both called on the
//     VGGraphSchedulerV2 pull queue (a serial GCD queue). This node does not
//     introduce its own lock for reader state; it relies on the scheduler's
//     serial dispatch guarantee.
//   - invalidate may be called from any thread; it uses atomic_exchange for the
//     guard and then cancels the reader from whichever thread it is on.
//     The reader reference is nilled before returning. If a concurrent pullFrame:
//     is in-flight, it will see the generation mismatch (incremented by
//     seekTo:generation:) or the invalidated flag, and return skipped.
//
// Last-decoded buffer ownership (RR-36):
//   - _primaryLastBuffer: retained +1 by this node.
//   - Purpose: extend the CVPixelBuffer's lifetime through the VGFrameEnvelope
//     delivery to the renderer sink. Cleared before each new decode and on
//     seek / invalidate.
//   - The VGFrameEnvelope.payload.videoBuffer is documented as +0. The renderer
//     (VanguardGraphRuntime / FlutterTexture) retains the buffer under its own
//     lock before we clear _primaryLastBuffer.
//
// Phase 7.x-F (patch) — Sample-window tracking (RR-146 equivalent):
//   - _primaryLastSamplePTS:      asset-local PTS of the cached frame, in seconds.
//                                  -1.0 means no frame is cached.
//   - _primaryLastSampleDuration: duration of the cached frame, in seconds.
//                                  Used to compute the half-open window
//                                  [_primaryLastSamplePTS,
//                                   _primaryLastSamplePTS + _primaryLastSampleDuration).
//   - Both are reset to -1.0 / 0.0 on seek, invalidate, reader build, and EOS.
//   - The sourceFPS fallback is stored as _primarySourceFPS and set when the reader
//     is built, mirroring _VGClipReader.sourceFPS in VGTimelineCompositorNode.
@interface VGDualCameraCompositorNode ()

// ─── Primary reader (Phase 7.x-F) ────────────────────────────────────────────
@property (nonatomic, nullable) AVAssetReader                      *primaryReader;
@property (nonatomic, nullable) AVAssetReaderVideoCompositionOutput *primaryOutput;

// Nominal frame rate of the primary clip's video composition.
// Used as fallback duration when CMSampleBufferGetDuration returns invalid/indefinite.
// Set on reader build; reset to 30.0 on clear.
@property (nonatomic) double primarySourceFPS;

// Phase 7.x-F (patch): Sample-window reuse cache (RR-146 equivalent).
// Both fields are reset to -1.0 / 0.0 whenever the cached sample is invalidated.
@property (nonatomic) double primaryLastSamplePTS;      // asset-local PTS; -1.0 = empty
@property (nonatomic) double primaryLastSampleDuration; // asset-local sample duration

// Last decoded/delivered primary buffer. Retained +1 by this node.
// Cleared on seek, on invalidate, on EOS, and when a new sample is decoded.
// Purpose: extend lifetime of the CVPixelBuffer through envelope delivery.
@property (nonatomic) CVPixelBufferRef primaryLastBuffer; // nullable; +1

// Generation counter. Updated atomically on seekTo:generation:.
// Captured at the start of each pullFrame: and compared against
// request.generation to detect stale requests across seeks.
@property (nonatomic) _Atomic(uint64_t) primaryGeneration;

// Phase 7.x-F (aspect ratio, Option B): Display-correct output dimensions of
// the primary clip. Set once during the first _buildPrimaryReaderStartingAtTime:
// call after the video track is probed, using the same naturalSize +
// preferredTransform logic as VanguardFileMediaSource._probeAsset.
// Initialized to {1280, 720} DEV fallback; updated on reader build.
// Accessible publicly as -primaryRenderSize.
@property (nonatomic) CGSize primaryRenderSize;

@end

@implementation VGDualCameraCompositorNode {
    // VGNode identity fields.
    NSString       *_nodeId;
    NSArray<id>    *_ports;       // stored for declaredPorts

    // Invalidation guard (atomic per VGNode contract).
    atomic_bool     _invalidated;
}

@synthesize primaryClip   = _primaryClip;
@synthesize secondaryClip = _secondaryClip;
@synthesize layoutMode    = _layoutMode;
@synthesize pipLayout     = _pipLayout;
@synthesize primaryRenderSize = _primaryRenderSize;

// CVPixelBufferRef property synthesized manually to handle CF retain/release.
// We do NOT use @synthesize for primaryLastBuffer because it is a CF type
// that requires manual ownership management. The ivars are declared below.

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

    // Phase 7.x-F: reader state initialised to nil.
    _primaryReader            = nil;
    _primaryOutput            = nil;
    _primarySourceFPS         = 30.0;
    _primaryLastSamplePTS     = -1.0;
    _primaryLastSampleDuration = 0.0;
    _primaryLastBuffer        = NULL;
    atomic_store(&_primaryGeneration, 0);

    // Phase 7.x-F (aspect ratio, Option B, timing fix):
    // Probe primaryRenderSize synchronously during init so dev_createDualCameraTexture
    // can read the correct display dimensions before the first async pullFrame: fires.
    //
    // naturalSize + preferredTransform is pure metadata access (no decoding); it
    // completes in < 1 ms for local assets and is safe on the calling thread.
    // Mirrors VanguardFileMediaSource._probeAsset logic.
    //
    // Set fallback first so any early-return paths below leave a safe value.
    _primaryRenderSize = CGSizeMake(1280.0, 720.0);
    {
        NSString *urlStr = primary.sourceURL;
        if (urlStr.length > 0) {
            NSURL *assetURL = [NSURL fileURLWithPath:urlStr];
            NSDictionary *opts = @{ AVURLAssetPreferPreciseDurationAndTimingKey : @NO };
            AVURLAsset *probeAsset = [AVURLAsset URLAssetWithURL:assetURL options:opts];
            // Synchronously load tracks (metadata only, no decoding).
            NSArray<AVAssetTrack *> *videoTracks = [probeAsset
                tracksWithMediaType:AVMediaTypeVideo];
            AVAssetTrack *probeTrack = videoTracks.firstObject;
            if (probeTrack) {
                CGAffineTransform tx  = probeTrack.preferredTransform;
                CGSize             nat = probeTrack.naturalSize;
                CGSize             display = CGSizeApplyAffineTransform(nat, tx);
                display = CGSizeMake(fabs(display.width), fabs(display.height));
                if (display.width > 1.0 && display.height > 1.0) {
                    _primaryRenderSize = display;
                } else if (nat.width > 1.0 && nat.height > 1.0) {
                    _primaryRenderSize = nat; // transform produced degenerate: use natural
                }
                NSLog(@"[VGDualCameraCompositorNode][7.x-F] init probe: "
                      "primaryRenderSize={%.0f,%.0f} natural={%.0f,%.0f} clipId=%@",
                      _primaryRenderSize.width, _primaryRenderSize.height,
                      nat.width, nat.height, primary.clipId);
            } else {
                NSLog(@"[VGDualCameraCompositorNode][7.x-F] init probe: "
                      "no video track found — using DEV fallback 1280x720. clipId=%@",
                      primary.clipId);
            }
        } else {
            NSLog(@"[VGDualCameraCompositorNode][7.x-F] init probe: "
                  "sourceURL empty — using DEV fallback 1280x720. clipId=%@",
                  primary.clipId);
        }
    }

    NSLog(@"[VGDualCameraCompositorNode][7.x-F] init ok | nodeId=%@ | "
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

// ─── Phase 7.x-F: Dealloc — release retained CVPixelBuffer ───────────────────

- (void)dealloc {
    // Release the retained primary buffer if any.
    // dealloc is single-threaded (no concurrent access after last release).
    if (_primaryLastBuffer) {
        CVPixelBufferRelease(_primaryLastBuffer);
        _primaryLastBuffer = NULL;
    }
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
    return @[[VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo]];
}

// ─── VGNode protocol — lifecycle ─────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Phase 7.x-F: No heavy prepare needed; reader is built lazily on first pull.
    // Calls completion asynchronously on a background queue per VGNode contract:
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

    // Phase 7.x-F: Cancel and release the primary reader.
    // invalidate may be called from any thread.
    [self _cancelAndClearPrimaryReader];
}

// ─── VGNode protocol — format negotiation ────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Phase 7.x-F: format negotiation not implemented.
    // Returning nil is safe: VGGraphPlanner treats nil as "unable to negotiate"
    // and skips format propagation for this node.
    return nil;
}

// ─── VGNode protocol — nodeType (legacy VGMediaNode compat) ──────────────────

- (NSString *)nodeType {
    return @"VGDualCameraCompositorNode";
}

// ─── VGSourceNode protocol — push-mode production ────────────────────────────

- (void)startProducing {
    // Push-mode is not applicable to a pull-based compositor. No-op.
}

- (void)stopProducing {
    // Push-mode is not applicable to a pull-based compositor. No-op.
}

// ─── VGSourceNode protocol — seek ────────────────────────────────────────────

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
    // Phase 7.x-F: Increment generation atomically and cancel the active reader.
    //
    // Generation increment must precede reader cancellation so that any concurrent
    // pullFrame: in-flight (on the same serial queue) sees the new generation and
    // returns skipped rather than delivering a stale frame.
    //
    // Note: VGGraphSchedulerV2 calls seekTo:generation: on the pull queue (same
    // serial queue as pullFrame:). This means in practice they cannot be truly
    // concurrent, but we use atomic_store to match the contract documented in
    // VGSourceNode.h: "Thread-safe: may be called from any thread."
    atomic_store(&_primaryGeneration, generation);

    [self _cancelAndClearPrimaryReader];

    NSLog(@"[VGDualCameraCompositorNode][7.x-F] seekTo: time=%.3fs gen=%llu",
          CMTimeGetSeconds(time),
          (unsigned long long)generation);
}

// ─── VGSourceNode protocol — pull-mode production ────────────────────────────
//
// Phase 7.x-F (patch) — Frame pacing design:
//
// VGGraphSchedulerV2 calls pullFrame: at the display refresh rate (60 Hz or
// 120 Hz on ProMotion devices). Without pacing, a sequential AVAssetReader
// would be driven at display rate, consuming a 30 fps clip at 2–4× speed
// and exhausting the reader prematurely (the same bug class as the
// pre-Phase-7.11 reverse sidecar exhaustion).
//
// The fix mirrors the VGTimelineCompositorNode Phase 7.11 RR-146 per-reader
// reuse guard:
//
//   1. Map request.requestedPTS → assetTime:
//        elapsed  = requestedPTS (seconds) — this node has no timeline-start
//                   offset; the 7.x-E DEV route mounts the node with the
//                   clip starting at global PTS 0.
//        assetTime = clip.trimStartSeconds + elapsed * clip.speed
//        Clamped to [trimStartSeconds, trimEndSeconds].
//
//   2. Sample-window reuse guard:
//        If _primaryLastBuffer is valid AND assetTime falls inside
//        [_primaryLastSamplePTS, _primaryLastSamplePTS + _primaryLastSampleDuration),
//        return the cached buffer (+1 retain) WITHOUT calling copyNextSampleBuffer.
//
//   3. Advance reader only when needed:
//        If the cached window does not cover assetTime, call copyNextSampleBuffer
//        in a loop until the decoded sample's window covers assetTime or EOS.
//        On each iteration the old cached buffer is released and the new one
//        is retained (+1). The loop exits when covered or EOS.

- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    // ── 1. Cancellation / invalidation guard ────────────────────────────────
    //
    // Per VGSourceNode contract:
    //   "Check request.isCancelled before expensive decode; return .skipped if set."
    if (request.isCancelled) {
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    if (atomic_load(&_invalidated)) {
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // ── 2. Generation guard ─────────────────────────────────────────────────
    //
    // If the scheduler's request.generation differs from our stored generation,
    // we are receiving a stale request from before a seek. Return skipped.
    uint64_t currentGen = atomic_load(&_primaryGeneration);
    if (request.generation != currentGen) {
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // ── 3. Unsupported primary clip shape guard ─────────────────────────────
    //
    // Phase 7.x-F supports only simple forward video clips.
    // Unsupported shapes log a DEV warning and return skipped (no crash).
    VGClipDescriptor *clip = _primaryClip;

    if (clip.mediaKind == VGClipMediaKindImage) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-F][DEV] primaryClip is a still-image clip "
              "(mediaKind=Image). Still-image primary clips are unsupported in Phase 7.x-F. "
              "Returning skipped. clipId=%@", clip.clipId);
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    if (clip.mediaKind != VGClipMediaKindVideo) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-F][DEV] primaryClip has unsupported "
              "mediaKind=%ld. Only VGClipMediaKindVideo is supported in Phase 7.x-F. "
              "Returning skipped. clipId=%@", (long)clip.mediaKind, clip.clipId);
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    if (clip.freezePTS != nil) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-F][DEV] primaryClip is a freeze-frame clip "
              "(freezePTS=%.3fs). Freeze-frame primary clips are unsupported in Phase 7.x-F. "
              "Returning skipped. clipId=%@", clip.freezePTS.doubleValue, clip.clipId);
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    if (clip.isReversed) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-F][DEV] primaryClip has isReversed=YES. "
              "Reversed primary clips are unsupported in Phase 7.x-F. "
              "Returning skipped. clipId=%@", clip.clipId);
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    if (clip.sourceURL.length == 0) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-F][DEV] primaryClip has empty sourceURL. "
              "Returning skipped. clipId=%@", clip.clipId);
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // ── 4. EOS check: requested timeline PTS exceeds primary clip duration ────
    //
    // The DEV runtime uses PTS starting at 0; the clip starts at
    // global timeline PTS 0. The clip's playback duration is:
    //   durationSeconds = (trimEndSeconds - trimStartSeconds) / speed
    //
    // If requestedPTS >= durationSeconds the primary clip has ended. Return
    // endOfStream so VanguardGraphRuntime stops its CADisplayLink clock.
    // Without this guard the assetTime clamp below pins to trimEndSeconds and
    // the last cached frame is delivered forever (EOS_FAIL_RUNTIME_CONTINUES_FOREVER).
    double eosSpeed = (clip.speed > 0.0) ? clip.speed : 1.0;
    double clipDurationSeconds = (clip.trimEndSeconds - clip.trimStartSeconds) / eosSpeed;

    // Obtain requestedPTSSecs early for the EOS check (also used below in step 4).
    double requestedPTSSecs = 0.0;
    if (CMTIME_IS_VALID(request.requestedPTS)) {
        requestedPTSSecs = CMTimeGetSeconds(request.requestedPTS);
        if (requestedPTSSecs < 0.0) { requestedPTSSecs = 0.0; }
    }

    if (clipDurationSeconds > 0.0 && requestedPTSSecs >= clipDurationSeconds) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-F] EOS: requestedPTS=%.3fs >= "
              "clipDuration=%.3fs — returning endOfStream. clipId=%@",
              requestedPTSSecs, clipDurationSeconds, clip.clipId);
        // Release cached buffer; reader will be cancelled on next seekTo: or invalidate.
        if (_primaryLastBuffer) {
            CVPixelBufferRelease(_primaryLastBuffer);
            _primaryLastBuffer        = NULL;
            _primaryLastSamplePTS      = -1.0;
            _primaryLastSampleDuration = 0.0;
        }
        return [VGFrameResult endOfStreamWithGeneration:request.generation];
    }

    // ── 5. Map requestedPTS → assetTime ────────────────────────────────────
    //
    // The 7.x-E DEV texture route mounts this node with the clip starting at
    // global timeline PTS 0, so elapsed = requestedPTS directly.
    //
    // assetTime = trimStartSeconds + elapsed * speed
    //
    // speed: must be > 0 by VGClipDescriptor.isValid contract. Defensively
    // clamp to 1.0 if somehow zero or negative (belt-and-suspenders).
    double speed = (clip.speed > 0.0) ? clip.speed : 1.0;
    double assetTime = clip.trimStartSeconds + requestedPTSSecs * speed;

    // Clamp to [trimStartSeconds, trimEndSeconds] for float safety.
    if (assetTime < clip.trimStartSeconds) { assetTime = clip.trimStartSeconds; }
    if (assetTime > clip.trimEndSeconds)   { assetTime = clip.trimEndSeconds;   }

    // ── 5. Lazy reader initialization ───────────────────────────────────────
    //
    // Build the AVAssetReader on the first pullFrame: call after init or seek.
    // Pass the initial assetTime so the reader's timeRange starts there,
    // avoiding unnecessary sequential reads from trimStartSeconds when the
    // first requested PTS is non-zero (e.g., after a mid-clip seek).
    if (_primaryReader == nil) {
        NSError *buildError = nil;
        BOOL built = [self _buildPrimaryReaderStartingAtTime:assetTime
                                                       error:&buildError];
        if (!built || _primaryReader == nil) {
            NSLog(@"[VGDualCameraCompositorNode][7.x-F] Failed to build primary reader: %@. "
                  "Returning skipped. clipId=%@",
                  buildError.localizedDescription, clip.clipId);
            return [VGFrameResult skippedWithGeneration:request.generation];
        }
    }

    // ── 6. Check reader is still alive ──────────────────────────────────────
    //
    // AVAssetReader.status transitions from Reading to Completed/Failed/Cancelled
    // once the stream is exhausted or cancelled.
    if (_primaryReader.status != AVAssetReaderStatusReading) {
        AVAssetReaderStatus status = _primaryReader.status;
        if (status == AVAssetReaderStatusCompleted) {
            NSLog(@"[VGDualCameraCompositorNode][7.x-F] primary reader EOS at assetTime=%.3fs. "
                  "clipId=%@", assetTime, clip.clipId);
            return [VGFrameResult endOfStreamWithGeneration:request.generation];
        } else {
            NSLog(@"[VGDualCameraCompositorNode][7.x-F] primary reader status=%ld, "
                  "returning skipped. clipId=%@", (long)status, clip.clipId);
            return [VGFrameResult skippedWithGeneration:request.generation];
        }
    }

    // ── 7. Sample-window reuse guard (Phase 7.x-F patch, RR-146 equivalent) ──
    //
    // If the requested assetTime falls within the currently cached sample's
    // time window, return the cached pixel buffer without calling
    // copyNextSampleBuffer. This prevents the 60/120 Hz display-link from
    // consuming the 30 fps video stream at 2–4× speed.
    //
    // Window: [_primaryLastSamplePTS, _primaryLastSamplePTS + _primaryLastSampleDuration)
    // Half-open to handle exact frame boundaries without double-serving.
    if (_primaryLastBuffer != NULL &&
        _primaryLastSamplePTS >= 0.0 &&
        assetTime >= _primaryLastSamplePTS &&
        assetTime < _primaryLastSamplePTS + _primaryLastSampleDuration) {
        // Cache hit: return the retained buffer with an additional +1 for
        // the caller (VGFrameEnvelope +0 contract; the node's +1 remains).
        CVPixelBufferRef cachedBuf = _primaryLastBuffer;
        CVPixelBufferRetain(cachedBuf); // +1 for envelope delivery

        VGFrameEnvelope envelope;
        envelope.pts        = request.requestedPTS;
        envelope.dts        = kCMTimeInvalid;
        envelope.duration   = CMTimeMakeWithSeconds(_primaryLastSampleDuration, 600);
        envelope.generation = currentGen;
        envelope.mediaType  = VGMediaTypeVideo;
        envelope.payload.videoBuffer = (void *)cachedBuf; // +0 in envelope; two +1 refs in flight
        envelope.metadata   = NULL;

        CVPixelBufferRelease(cachedBuf); // release the extra +1 we just took above
        // (The node's +1 in _primaryLastBuffer extends the buffer lifetime
        //  past this return. The renderer will retain under its own lock.)

        return [VGFrameResult deliveredWithEnvelope:envelope generation:currentGen];
    }

    // ── 8. Advance reader until requested assetTime is covered or EOS ────────
    //
    // Call copyNextSampleBuffer in a loop. On each iteration:
    //   - Extract the sample PTS and duration.
    //   - Update the node-level sample-window cache.
    //   - If the new window covers assetTime, stop and return this frame.
    //   - If samplePTS > assetTime (reader has advanced past the requested time,
    //     e.g., after a seek), stop and return the current frame as the nearest
    //     safe forward sample.
    //   - Otherwise continue reading until the window catches up.
    //
    // Memory ownership (RR-36) per iteration:
    //   CMSampleBufferRef: +1 from copyNextSampleBuffer → CFRelease after use.
    //   CVPixelBufferRef:  +0 from CMSampleBufferGetImageBuffer → CVRetain to cache.
    //   _primaryLastBuffer: old buffer released before the new one is stored.
    while (YES) {
        // Check generation before each decode iteration to bail early on seek.
        if (request.isCancelled || atomic_load(&_primaryGeneration) != currentGen) {
            return [VGFrameResult skippedWithGeneration:request.generation];
        }

        // Check reader health before each sample pull.
        if (_primaryReader.status != AVAssetReaderStatusReading) {
            AVAssetReaderStatus status = _primaryReader.status;
            if (status == AVAssetReaderStatusCompleted) {
                _primaryLastSamplePTS      = -1.0;
                _primaryLastSampleDuration = 0.0;
                NSLog(@"[VGDualCameraCompositorNode][7.x-F] primary reader EOS in advance loop. "
                      "clipId=%@", clip.clipId);
                return [VGFrameResult endOfStreamWithGeneration:request.generation];
            } else {
                NSLog(@"[VGDualCameraCompositorNode][7.x-F] primary reader status=%ld in advance loop, "
                      "returning skipped. clipId=%@", (long)status, clip.clipId);
                return [VGFrameResult skippedWithGeneration:request.generation];
            }
        }

        CMSampleBufferRef sampleBuf = [_primaryOutput copyNextSampleBuffer]; // +1

        if (!sampleBuf) {
            // NULL: reader exhausted or cancelled.
            AVAssetReaderStatus status = _primaryReader.status;
            _primaryLastSamplePTS      = -1.0;
            _primaryLastSampleDuration = 0.0;
            if (status == AVAssetReaderStatusCompleted) {
                NSLog(@"[VGDualCameraCompositorNode][7.x-F] primary reader EOS (null sample in loop). "
                      "clipId=%@", clip.clipId);
                return [VGFrameResult endOfStreamWithGeneration:request.generation];
            } else {
                NSLog(@"[VGDualCameraCompositorNode][7.x-F] null sample in advance loop, status=%ld. "
                      "Returning skipped. clipId=%@", (long)status, clip.clipId);
                return [VGFrameResult skippedWithGeneration:request.generation];
            }
        }

        // Extract pixel buffer (+0 from sample buffer).
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuf);
        if (!imageBuffer) {
            // Timing-only sample (no image payload). Skip and continue.
            CFRelease(sampleBuf);
            continue;
        }

        // Extract sample timing.
        CMTime rawSamplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuf);
        CMTime rawSampleDur = CMSampleBufferGetDuration(sampleBuf);

        double sPTS = CMTIME_IS_VALID(rawSamplePTS) ? CMTimeGetSeconds(rawSamplePTS) : -1.0;
        // Use sample duration if valid and positive; fall back to 1/sourceFPS.
        double sDur = (CMTIME_IS_VALID(rawSampleDur) &&
                       !CMTIME_IS_INDEFINITE(rawSampleDur) &&
                       CMTimeGetSeconds(rawSampleDur) > 0.0)
                      ? CMTimeGetSeconds(rawSampleDur)
                      : (1.0 / MAX(_primarySourceFPS, 1.0));

        // Retain pixel buffer for the cache (+1).
        CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)imageBuffer;
        CVPixelBufferRetain(pixelBuffer); // +1: node cache ref

        // Release previous cached buffer.
        if (_primaryLastBuffer) {
            CVPixelBufferRelease(_primaryLastBuffer);
        }
        _primaryLastBuffer        = pixelBuffer; // node takes +1
        _primaryLastSamplePTS      = sPTS;
        _primaryLastSampleDuration = sDur;

        // Done with sample buffer.
        CFRelease(sampleBuf); // release CMSampleBufferRef +1

        // Post-decode generation guard: bail if seek happened during decode.
        if (atomic_load(&_primaryGeneration) != currentGen) {
            CVPixelBufferRelease(_primaryLastBuffer);
            _primaryLastBuffer        = NULL;
            _primaryLastSamplePTS      = -1.0;
            _primaryLastSampleDuration = 0.0;
            return [VGFrameResult skippedWithGeneration:request.generation];
        }

        // Check if this sample's window covers the requested assetTime,
        // or if the reader has advanced past assetTime (nearest forward sample).
        // In both cases: return this sample.
        BOOL windowCoversRequest = (sPTS >= 0.0 &&
                                    assetTime >= sPTS &&
                                    assetTime <  sPTS + sDur);
        BOOL readerPassedRequest  = (sPTS > assetTime);

        if (windowCoversRequest || readerPassedRequest) {
            // ── 9. Build VGFrameEnvelope and return ─────────────────────────
            //
            // VGFrameEnvelope.payload.videoBuffer is +0 per contract.
            // The node's _primaryLastBuffer (+1) extends the buffer lifetime
            // past this return. The renderer retains under its own lock.
            VGFrameEnvelope envelope;
            envelope.pts        = request.requestedPTS; // use output-timeline PTS
            envelope.dts        = kCMTimeInvalid;
            envelope.duration   = CMTimeMakeWithSeconds(sDur, 600);
            envelope.generation = currentGen;
            envelope.mediaType  = VGMediaTypeVideo;
            envelope.payload.videoBuffer = (void *)pixelBuffer; // +0 in envelope
            envelope.metadata   = NULL;

            return [VGFrameResult deliveredWithEnvelope:envelope generation:currentGen];
        }

        // This sample's window does not cover assetTime and hasn't passed it yet.
        // Continue to next sample. The old _primaryLastBuffer is already
        // released and the new one stored; loop again.
    }
    // Unreachable: loop always returns or falls through via the early-exits above.
    // Defensive fallback for static analyser.
    return [VGFrameResult skippedWithGeneration:request.generation];
}

// ─── Phase 7.x-F: Private — build primary AVAssetReader ──────────────────────
//
// Builds an AVAssetReader + AVAssetReaderVideoCompositionOutput for _primaryClip.
//
// Orientation normalization (Phase 7.9 convention):
//   Uses AVAssetReaderVideoCompositionOutput with an auto-generated
//   AVMutableVideoComposition from videoCompositionWithPropertiesOfAsset:.
//   This bakes the track's preferredTransform at decode time, identical to
//   the VGTimelineCompositorNode Phase 7.9 path. No aspect-fit canvas
//   normalization in Phase 7.x-F (deferred to 7.x-G alongside PiP).
//
// Trim range:
//   reader.timeRange is set to [trimStartSeconds, trimEndSeconds) before
//   startReading, so that the reader positions itself at the correct start.
//
// Returns YES and populates self.primaryReader / self.primaryOutput on success.
// Returns NO and sets outError on failure.

- (BOOL)_buildPrimaryReaderStartingAtTime:(double)startTimeSecs
                                    error:(NSError **)outError {
    VGClipDescriptor *clip = _primaryClip;

    // ── Build AVURLAsset ──────────────────────────────────────────────────────
    NSURL *assetURL = [NSURL fileURLWithPath:clip.sourceURL];
    if (!assetURL) {
        if (outError) {
            *outError = [NSError errorWithDomain:VGDualCameraCompositorNodeErrorDomain
                                           code:3100
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:
                                               @"VGDualCameraCompositorNode[7.x-F]: "
                                                "invalid sourceURL for primaryClip '%@': %@",
                                               clip.clipId, clip.sourceURL]}];
        }
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];

    // ── Find first video track ────────────────────────────────────────────────
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = tracks.firstObject;
    if (!videoTrack) {
        if (outError) {
            *outError = [NSError errorWithDomain:VGDualCameraCompositorNodeErrorDomain
                                           code:3101
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:
                                               @"VGDualCameraCompositorNode[7.x-F]: "
                                                "no video track found in asset for "
                                                "primaryClip '%@' at %@",
                                               clip.clipId, clip.sourceURL]}];
        }
        return NO;
    }

    // ── Create AVAssetReader ──────────────────────────────────────────────────
    NSError *readerError = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
    if (!reader) {
        if (outError) *outError = readerError;
        return NO;
    }

    // ── Set timeRange (trim window) ───────────────────────────────────────────
    //
    // timeRange must be set BEFORE startReading (Apple requirement).
    // We start at startTimeSecs (= trimStartSeconds on first build; updated
    // by seekTo: to the new seek position) and read to trimEndSeconds.
    // Clamp to asset duration to avoid invalid ranges.
    CMTime assetStart    = CMTimeMakeWithSeconds(startTimeSecs,             600);
    CMTime assetEnd      = CMTimeMakeWithSeconds(clip.trimEndSeconds,       600);
    CMTime assetDuration = asset.duration;

    // Clamp assetStart to [0, assetDuration).
    if (CMTIME_IS_VALID(assetDuration) &&
        CMTimeCompare(assetStart, assetDuration) >= 0) {
        assetStart = assetDuration; // will produce EOS immediately
    }

    // Clamp assetEnd to assetDuration.
    CMTime readEnd = assetEnd;
    if (CMTIME_IS_VALID(assetDuration) &&
        CMTimeCompare(assetEnd, assetDuration) > 0) {
        readEnd = assetDuration;
    }

    if (CMTimeCompare(assetStart, readEnd) < 0) {
        CMTime readDuration = CMTimeSubtract(readEnd, assetStart);
        reader.timeRange = CMTimeRangeMake(assetStart, readDuration);
    }
    // else: zero-length range → reader produces EOS immediately (safe).

    // ── Phase 7.9-identical orientation normalization ─────────────────────────
    //
    // AVAssetReaderVideoCompositionOutput applies the video composition
    // instructions (which include preferredTransform) at decode time.
    // This is the identical convention used by VGTimelineCompositorNode (Phase 7.9).
    //
    // No canvas aspect-fit normalization in Phase 7.x-F (deferred to 7.x-G).
    // The auto-generated composition preserves the asset's display dimensions.
    //
    // API note: videoCompositionWithPropertiesOfAsset: is deprecated in iOS 18.
    // The synchronous variant is used here (identical to VGTimelineCompositorNode).
    // Migration to the async API is deferred (same rationale as timeline node).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVMutableVideoComposition *videoComposition =
        [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset];
#pragma clang diagnostic pop

    NSDictionary *outputSettings = _VGDCCNOutputSettings();
    AVAssetReaderVideoCompositionOutput *output =
        [[AVAssetReaderVideoCompositionOutput alloc]
            initWithVideoTracks:@[videoTrack]
                   videoSettings:outputSettings];

    // videoComposition must be set BEFORE startReading (Apple requirement).
    output.videoComposition = videoComposition;

    // alwaysCopiesSampleData = NO: vend original decoded buffers (read-only).
    // Avoids per-frame allocation. Matches VGTimelineCompositorNode pattern.
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        if (outError) {
            *outError = [NSError errorWithDomain:VGDualCameraCompositorNodeErrorDomain
                                           code:3102
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:
                                               @"VGDualCameraCompositorNode[7.x-F]: "
                                                "cannot add AVAssetReaderVideoCompositionOutput "
                                                "for primaryClip '%@'.",
                                               clip.clipId]}];
        }
        return NO;
    }

    [reader addOutput:output];

    // ── Start reading ─────────────────────────────────────────────────────────
    if (![reader startReading]) {
        if (outError) *outError = reader.error;
        return NO;
    }

    // ── Compute source FPS from video composition (mirrors VGTimelineCompositorNode) ─
    // Prefer videoComposition.frameDuration when valid (set by
    // videoCompositionWithPropertiesOfAsset: from track properties).
    // Fall back to track nominalFrameRate, then 30.0 fps.
    double sourceFPS = 30.0;
    if (videoComposition &&
        CMTIME_IS_VALID(videoComposition.frameDuration) &&
        CMTimeGetSeconds(videoComposition.frameDuration) > 0.0) {
        sourceFPS = 1.0 / CMTimeGetSeconds(videoComposition.frameDuration);
    } else if (videoTrack.nominalFrameRate > 0.0f) {
        sourceFPS = (double)videoTrack.nominalFrameRate;
    }

    // ── Phase 7.x-F (aspect ratio, Option B): Compute display-correct render size ─
    //
    // Mirrors VanguardFileMediaSource._probeAsset logic (VanguardFileMediaSource.m
    // lines ~418–453). Applies preferredTransform to naturalSize so that portrait
    // clips (naturalSize = {W, H} in landscape sensor encoding) report portrait
    // display dimensions and the Dart manual harness can constrain AspectRatio
    // correctly without hardcoding 16/9.
    //
    // No canvas-fit. No PiP geometry. Raw display dimensions only.
    {
        CGAffineTransform transform  = videoTrack.preferredTransform;
        CGSize            natural    = videoTrack.naturalSize;
        CGSize            displaySz  = CGSizeApplyAffineTransform(natural, transform);
        displaySz = CGSizeMake(fabs(displaySz.width), fabs(displaySz.height));

        if (displaySz.width > 1.0 && displaySz.height > 1.0) {
            _primaryRenderSize = displaySz;
        } else {
            // Fallback: natural size without transform, or DEV fallback.
            _primaryRenderSize = (natural.width > 1.0 && natural.height > 1.0)
                                     ? natural
                                     : CGSizeMake(1280.0, 720.0);
            NSLog(@"[VGDualCameraCompositorNode][7.x-F] primaryRenderSize fallback used: "
                  "{%.0f, %.0f} (transform produced zero/near-zero component). clipId=%@",
                  _primaryRenderSize.width, _primaryRenderSize.height, clip.clipId);
        }
        NSLog(@"[VGDualCameraCompositorNode][7.x-F] primaryRenderSize={%.0f,%.0f} "
              "naturalSize={%.0f,%.0f} clipId=%@",
              _primaryRenderSize.width, _primaryRenderSize.height,
              natural.width, natural.height, clip.clipId);
    }

    // ── Store reader state ────────────────────────────────────────────────────
    _primaryReader    = reader;
    _primaryOutput    = output;
    _primarySourceFPS = sourceFPS;
    // Reset sample-window cache: newly built reader has no cached frame.
    _primaryLastSamplePTS      = -1.0;
    _primaryLastSampleDuration = 0.0;

    NSLog(@"[VGDualCameraCompositorNode][7.x-F] primary reader built ok | "
          "clipId=%@ start=%.3fs end=%.3fs fps=%.1f",
          clip.clipId, startTimeSecs, clip.trimEndSeconds, sourceFPS);

    return YES;
}

// ─── Phase 7.x-F: Private — cancel and clear primary reader ──────────────────
//
// Cancels the active AVAssetReader, nils reader and output references, and
// releases the retained last-delivered buffer. Idempotent: safe to call when
// reader is already nil.
//
// Thread safety: may be called from any thread. Relies on the scheduler's
// serial-queue guarantee for normal seek/invalidate paths. For the invalidate
// path (which may come from any thread), we rely on the atomic _invalidated
// flag being set before this method is called, so concurrent pullFrame: calls
// will see the invalidated state and return skipped without touching the reader.

- (void)_cancelAndClearPrimaryReader {
    AVAssetReader *reader = _primaryReader;
    if (reader) {
        [reader cancelReading];
        _primaryReader = nil;
        _primaryOutput = nil;
    }

    // Reset sample-window cache fields.
    _primaryLastSamplePTS      = -1.0;
    _primaryLastSampleDuration = 0.0;
    _primarySourceFPS          = 30.0;

    // Release last-delivered buffer.
    if (_primaryLastBuffer) {
        CVPixelBufferRelease(_primaryLastBuffer);
        _primaryLastBuffer = NULL;
    }
}

@end
