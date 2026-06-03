// VGDualCameraCompositorNode.m
// vanguard_media_engine — Phase 7.x-B / Phase 7.x-F / Phase 7.x-G / Phase 7.x-J / Phase 7.x-K
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
// Phase 7.x-G: Secondary clip AVAssetReader added, mirroring the primary
//   reader pattern exactly. pullFrame: drives the secondary reader with the
//   same requested-PTS/sample-window pacing (RR-146 equivalent) as the primary.
//   The decoded secondary buffer is tracked internally but NOT rendered; the
//   visual output remains primary-only pass-through.
//   Secondary EOS does not end the stream; primary EOS still governs.
//   Both readers are torn down together on seek, invalidate, and dispose.
//   No PiP. No CoreImage. No Metal.
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

// ─── Phase 7.x-H: CoreImage for PiP compositing ───────────────────────────────
#import <CoreImage/CoreImage.h>

// ─── Phase 7.x-N: QuartzCore for CACurrentMediaTime() pull-frame timing ──────
#import <QuartzCore/QuartzCore.h>

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

// ─── Phase 7.x-K: Split-screen wire key ──────────────────────────────────────
static NSString * const kVGDCCNSplitLayoutKey      = @"splitLayout";
static NSString * const kVGDCCNSplitRatioKey       = @"splitRatio";

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

// ─── Phase 7.x-H: Shared CIContext ───────────────────────────────────────────
//
// Lazily created once, reused across all frames.
// Pattern mirrors VGTimelineCompositorNode._VGTCNSharedCIContext.
// kCIContextWorkingColorSpace = NSNull disables color-space conversion,
// matching the VanguardDualCameraCompositor.swift pattern and the existing
// timeline compositor convention. Thread-safe via dispatch_once.
static CIContext *_VGDCCNSharedCIContext(void) {
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{
            kCIContextWorkingColorSpace : [NSNull null],
        }];
    });
    return ctx;
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
/// Parses a VGSplitScreenLayoutConfig from a Dart-side splitLayout dictionary.
/// Missing or invalid keys fall back to defaults (splitRatio=0.5).
static VGSplitScreenLayoutConfig _VGDCCNParseSplitLayout(NSDictionary<NSString *, id> * _Nullable dict) {
    VGSplitScreenLayoutConfig cfg;
    cfg.splitRatio = 0.5; // default

    if (!dict || ![dict isKindOfClass:[NSDictionary class]]) {
        return cfg;
    }

    NSNumber *sr = dict[kVGDCCNSplitRatioKey];
    if ([sr isKindOfClass:[NSNumber class]] &&
        sr.doubleValue >= 0.2 && sr.doubleValue <= 0.8) {
        cfg.splitRatio = sr.doubleValue;
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
// Phase 7.x-G: Identical lifecycle applied to secondary reader.
//   _secondaryReader / _secondaryOutput mirror the primary pattern.
//   Both are cancelled/rebuilt together on seek and invalidate.
//   A _secondaryEOSReached flag tracks secondary exhaustion without halting
//   the primary stream. When YES, secondary decode is skipped and the primary
//   frame is delivered as-is (primary-only pass-through continues).
//
// Last-decoded buffer ownership (RR-36):
//   - _primaryLastBuffer: retained +1 by this node.
//   - Purpose: extend the CVPixelBuffer's lifetime through the VGFrameEnvelope
//     delivery to the renderer sink. Cleared before each new decode and on
//     seek / invalidate.
//   - The VGFrameEnvelope.payload.videoBuffer is documented as +0. The renderer
//     (VanguardGraphRuntime / FlutterTexture) retains the buffer under its own
//     lock before we clear _primaryLastBuffer.
//   - _secondaryLastBuffer: retained +1 by this node. Never delivered to the
//     renderer. Released on seek/invalidate/EOS.
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
//   - Secondary reader uses equivalent _secondaryLastSamplePTS / _secondaryLastSampleDuration.
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

// ─── Secondary reader (Phase 7.x-G) ───────────────────────────────────────────
// All fields mirror the primary reader pattern exactly.

@property (nonatomic, nullable) AVAssetReader                      *secondaryReader;
@property (nonatomic, nullable) AVAssetReaderVideoCompositionOutput *secondaryOutput;

// Nominal frame rate of the secondary clip's video composition.
// Set on reader build; reset to 30.0 on clear.
@property (nonatomic) double secondarySourceFPS;

// Phase 7.x-G: Sample-window reuse cache (RR-146 equivalent).
@property (nonatomic) double secondaryLastSamplePTS;      // asset-local PTS; -1.0 = empty
@property (nonatomic) double secondaryLastSampleDuration; // asset-local sample duration

// Last decoded secondary buffer. Retained +1. Never delivered to renderer.
// Released on seek, invalidate, secondary EOS, and when a new secondary sample
// is decoded.
@property (nonatomic) CVPixelBufferRef secondaryLastBuffer; // nullable; +1

// When YES, secondary reader has exhausted. pullFrame: skips secondary decode
// and continues delivering primary frames. Reset to NO on seek/invalidate.
@property (nonatomic) BOOL secondaryEOSReached;

// Display-correct output dimensions of the secondary clip.
// Probed synchronously during init; DEV-only diagnostic.
@property (nonatomic) CGSize secondaryRenderSize;

@end

@implementation VGDualCameraCompositorNode {
    // VGNode identity fields.
    NSString       *_nodeId;
    NSArray<id>    *_ports;       // stored for declaredPorts

    // Invalidation guard (atomic per VGNode contract).
    atomic_bool     _invalidated;

    // Phase 7.x-H: composited output buffer (primary + secondary PiP).
    // Retained +1 by this node. Released before each new compose, on seek,
    // on invalidate, and in dealloc.
    CVPixelBufferRef _compositedLastBuffer;

    // One-time log guard: YES after first composited frame is generated.
    BOOL _compositedFirstFrameLogged;

    // Phase 7.x-K: one-time log guard for split-screen first frame.
    BOOL _splitFirstFrameLogged;

    // Phase 7.x-L: Still-image pixel buffers.
    // Loaded once from the source image file via CIImage; retained +1.
    // NULL when the clip is not a still-image kind or has not been loaded yet.
    // Released on seek/invalidate/clear/dealloc.
    CVPixelBufferRef _primaryImageBuffer;   // primary still-image (nullable; +1)
    CVPixelBufferRef _secondaryImageBuffer; // secondary still-image (nullable; +1)

    // Phase 7.x-L: YES once the primary still-image buffer has been logged.
    BOOL _primaryImageLogged;
    // Phase 7.x-L: YES when the secondary clip is a still image.
    // When YES, _advanceSecondaryReaderToRequestedPTS: returns immediately
    // (image is already in _secondaryLastBuffer; no AVAssetReader needed).
    BOOL _secondaryIsImage;
    // Phase 7.x-L: YES once the secondary still-image buffer has been logged.
    BOOL _secondaryImageLogged;

    // Phase 7.x-N: DEV telemetry counters.
    // All atomic — safe to read from any thread for the telemetry route.
    // Reset to 0 by devResetTelemetry. Never read on the critical path.
    atomic_uint_fast64_t _primaryPullCount;       // total pullFrame: calls (incl. cache hits)
    atomic_uint_fast64_t _primaryDecodeCount;     // copyNextSampleBuffer calls on the PRIMARY reader
    atomic_uint_fast64_t _secondaryDecodeCount;   // copyNextSampleBuffer calls on the SECONDARY reader (Phase 7.x-P)
    atomic_uint_fast64_t _compositedFrameCount;   // total successful CoreImage composites (all modes)
    // Buffer byte estimates — updated atomically from pull queue alongside buffer stores.
    // Avoids reading _primaryLastBuffer/_secondaryLastBuffer from the main thread.
    atomic_uint_fast64_t _primaryLastBufferEstBytes;   // last primary buffer bytesPerRow*height
    atomic_uint_fast64_t _secondaryLastBufferEstBytes; // last secondary buffer bytesPerRow*height

    // Phase 7.x-N (patch): additional composition / fallback / image counters.
    atomic_uint_fast64_t _pipCompositionCount;          // successful PiP composites
    atomic_uint_fast64_t _splitScreenCompositionCount;  // successful split-screen composites
    atomic_uint_fast64_t _compositionFailureCount;      // composite attempted but _compositeWith* returned NULL
    atomic_uint_fast64_t _fallbackToPrimaryCount;       // delivered primary-only because secondary/composite unavailable
    atomic_uint_fast64_t _imageBufferBuildCount;        // successful _buildImageBufferForClip calls (primary + secondary)
    atomic_uint_fast64_t _outputBufferCreateCount;      // successful CVPixelBufferCreate in composite methods

    // Phase 7.x-N (patch): pull-frame timing (all in nanoseconds, stored atomically).
    // CACurrentMediaTime() returns absolute seconds; multiply by 1e9 for uint64 ns.
    // uint64 overflows at ~584 years — safe.
    //
    // Phase 7.x-P: _firstFrameLatencyNs replaces _firstFrameWallTimeNs.
    //   Stores the elapsed ns from pullFrame: entry (_pullT0Ns) to the first
    //   successful delivered frame — a true latency, not an absolute timestamp.
    //   0 = not yet measured (arms on first delivery; re-arms after reset).
    atomic_uint_fast64_t _firstFrameLatencyNs;   // ns elapsed from pullFrame: entry to first successful frame (Phase 7.x-P)
    atomic_uint_fast64_t _lastPullFrameNs;        // duration of last pullFrame: in ns
    atomic_uint_fast64_t _maxPullFrameNs;         // peak pullFrame: duration since last reset
    atomic_uint_fast64_t _totalPullFrameNs;       // sum of all pullFrame: durations for average
    atomic_uint_fast64_t _pullTimedCallCount;     // number of timing samples (denominator for average)
}

@synthesize primaryClip   = _primaryClip;
@synthesize secondaryClip = _secondaryClip;
@synthesize layoutMode    = _layoutMode;
@synthesize pipLayout     = _pipLayout;
@synthesize splitLayout   = _splitLayout;
@synthesize primaryRenderSize   = _primaryRenderSize;
@synthesize secondaryRenderSize = _secondaryRenderSize;

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
        if (![layoutModeStr isKindOfClass:[NSString class]]) {
            if (outError) {
                *outError = _VGDCCNError(
                    VGDualCameraCompositorNodeErrorUnsupportedLayoutMode,
                    ([NSString stringWithFormat:
                        @"VGDualCameraCompositorNode: unsupported layoutMode '%@'. "
                         "Phase 7.x-K supports 'pip' and 'splitScreen'.",
                        layoutModeStr]));
            }
            return nil;
        }
        if ([layoutModeStr isEqualToString:@"pip"]) {
            parsedLayoutMode = VGDualCameraLayoutModePiP;
        } else if ([layoutModeStr isEqualToString:@"splitScreen"]) {
            parsedLayoutMode = VGDualCameraLayoutModeSplitScreen;
        } else {
            if (outError) {
                *outError = _VGDCCNError(
                    VGDualCameraCompositorNodeErrorUnsupportedLayoutMode,
                    ([NSString stringWithFormat:
                        @"VGDualCameraCompositorNode: unsupported layoutMode '%@'. "
                         "Phase 7.x-K supports 'pip' and 'splitScreen'.",
                        layoutModeStr]));
            }
            return nil;
        }
    }

    // ── 5. Parse pipLayout (optional; defaults on missing/invalid) ───────────

    id pipLayoutRaw = parameters[kVGDCCNPiPLayoutKey];
    VGPiPLayoutConfig parsedPipLayout = _VGDCCNParsePiPLayout(
        [pipLayoutRaw isKindOfClass:[NSDictionary class]] ? pipLayoutRaw : nil);

    // ── 5b. Phase 7.x-K: Parse splitLayout (optional; defaults on missing/invalid) ─

    id splitLayoutRaw = parameters[kVGDCCNSplitLayoutKey];
    VGSplitScreenLayoutConfig parsedSplitLayout = _VGDCCNParseSplitLayout(
        [splitLayoutRaw isKindOfClass:[NSDictionary class]] ? splitLayoutRaw : nil);

    // ── 6. Commit ────────────────────────────────────────────────────────────

    self = [super init];
    if (!self) { return nil; }

    _nodeId       = [nodeId copy];
    _ports        = ports ? [ports copy] : @[];
    _primaryClip   = primary;
    _secondaryClip = secondary;
    _layoutMode    = parsedLayoutMode;
    _pipLayout     = parsedPipLayout;
    _splitLayout   = parsedSplitLayout;
    atomic_store(&_invalidated, false);

    // Phase 7.x-F: reader state initialised to nil.
    _primaryReader            = nil;
    _primaryOutput            = nil;
    _primarySourceFPS         = 30.0;
    _primaryLastSamplePTS     = -1.0;
    _primaryLastSampleDuration = 0.0;
    _primaryLastBuffer        = NULL;
    atomic_store(&_primaryGeneration, 0);

    // Phase 7.x-G: secondary reader state initialised to nil.
    _secondaryReader            = nil;
    _secondaryOutput            = nil;
    _secondarySourceFPS         = 30.0;
    _secondaryLastSamplePTS     = -1.0;
    _secondaryLastSampleDuration = 0.0;
    _secondaryLastBuffer         = NULL;
    _secondaryEOSReached         = NO;

    // Phase 7.x-H: composited buffer state.
    _compositedLastBuffer       = NULL;
    _compositedFirstFrameLogged = NO;
    // Phase 7.x-K: split-screen log guard.
    _splitFirstFrameLogged      = NO;

    // Phase 7.x-L: still-image buffer state.
    _primaryImageBuffer   = NULL;
    _secondaryImageBuffer = NULL;
    _primaryImageLogged   = NO;
    _secondaryIsImage     = NO;
    _secondaryImageLogged = NO;

    // Phase 7.x-N / 7.x-P: DEV telemetry counters — initialise to zero.
    atomic_init(&_primaryPullCount,            0);
    atomic_init(&_primaryDecodeCount,          0);
    atomic_init(&_secondaryDecodeCount,        0); // Phase 7.x-P: secondary reader decodes
    atomic_init(&_compositedFrameCount,        0);
    atomic_init(&_primaryLastBufferEstBytes,   0);
    atomic_init(&_secondaryLastBufferEstBytes, 0);
    // Phase 7.x-N (patch): composition / fallback / image / timing.
    atomic_init(&_pipCompositionCount,         0);
    atomic_init(&_splitScreenCompositionCount, 0);
    atomic_init(&_compositionFailureCount,     0);
    atomic_init(&_fallbackToPrimaryCount,      0);
    atomic_init(&_imageBufferBuildCount,       0);
    atomic_init(&_outputBufferCreateCount,     0);
    // Phase 7.x-P: _firstFrameLatencyNs replaces _firstFrameWallTimeNs (true latency).
    atomic_init(&_firstFrameLatencyNs,         0);
    atomic_init(&_lastPullFrameNs,             0);
    atomic_init(&_maxPullFrameNs,              0);
    atomic_init(&_totalPullFrameNs,            0);
    atomic_init(&_pullTimedCallCount,          0);

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
          "primary=%@ | secondary=%@ | layoutMode=%@ | "
          "pipLayout={anchor=%ld wf=%.3f mf=%.3f cr=%.1f op=%.2f} | "
          "splitLayout={ratio=%.3f}",
          _nodeId,
          _primaryClip.clipId,
          _secondaryClip.clipId,
          (parsedLayoutMode == VGDualCameraLayoutModeSplitScreen) ? @"splitScreen" : @"pip",
          (long)parsedPipLayout.anchor,
          parsedPipLayout.widthFraction,
          parsedPipLayout.marginFraction,
          parsedPipLayout.cornerRadius,
          parsedPipLayout.opacity,
          parsedSplitLayout.splitRatio);

    // Phase 7.x-G: Probe secondaryRenderSize synchronously, same pattern as primary.
    _secondaryRenderSize = CGSizeMake(1280.0, 720.0);
    {
        NSString *secURLStr = secondary.sourceURL;
        if (secURLStr.length > 0) {
            NSURL *secAssetURL = [NSURL fileURLWithPath:secURLStr];
            NSDictionary *opts = @{ AVURLAssetPreferPreciseDurationAndTimingKey : @NO };
            AVURLAsset *secProbeAsset = [AVURLAsset URLAssetWithURL:secAssetURL options:opts];
            NSArray<AVAssetTrack *> *secVideoTracks = [secProbeAsset
                tracksWithMediaType:AVMediaTypeVideo];
            AVAssetTrack *secProbeTrack = secVideoTracks.firstObject;
            if (secProbeTrack) {
                CGAffineTransform secTx  = secProbeTrack.preferredTransform;
                CGSize             secNat = secProbeTrack.naturalSize;
                CGSize             secDisplay = CGSizeApplyAffineTransform(secNat, secTx);
                secDisplay = CGSizeMake(fabs(secDisplay.width), fabs(secDisplay.height));
                if (secDisplay.width > 1.0 && secDisplay.height > 1.0) {
                    _secondaryRenderSize = secDisplay;
                } else if (secNat.width > 1.0 && secNat.height > 1.0) {
                    _secondaryRenderSize = secNat;
                }
                NSLog(@"[VGDualCameraCompositorNode][7.x-G] init probe: "
                      "secondaryRenderSize={%.0f,%.0f} natural={%.0f,%.0f} clipId=%@",
                      _secondaryRenderSize.width, _secondaryRenderSize.height,
                      secNat.width, secNat.height, secondary.clipId);
            } else {
                NSLog(@"[VGDualCameraCompositorNode][7.x-G] init probe: "
                      "no video track found for secondary — using DEV fallback 1280x720. clipId=%@",
                      secondary.clipId);
            }
        } else {
            NSLog(@"[VGDualCameraCompositorNode][7.x-G] init probe: "
                  "secondary sourceURL empty — using DEV fallback 1280x720. clipId=%@",
                  secondary.clipId);
        }
    }

    // ── Phase 7.x-L: Image-primary canvas override ───────────────────────────
    //
    // When primary is a still image and secondary is video, there is no AVAsset
    // video track on the primary to probe, so _primaryRenderSize remains at the
    // DEV fallback (1280x720 landscape). That fallback produces a visually wrong
    // landscape canvas for portrait dual-camera preview.
    //
    // Rule: image primary + video secondary → use secondary video render size.
    // This ensures _primaryRenderSize (and thus the image buffer canvas) matches
    // the display-correct portrait dimensions probed from the secondary video.
    //
    // Vid+Vid, Vid+Img, and Img+Img are all unaffected: this guard is only true
    // when primary.mediaKind == Image AND secondary.mediaKind == Video AND the
    // secondary probe produced a valid non-fallback size.
    if (primary.mediaKind == VGClipMediaKindImage &&
        secondary.mediaKind == VGClipMediaKindVideo &&
        _secondaryRenderSize.width  > 0.0 &&
        _secondaryRenderSize.height > 0.0) {
        _primaryRenderSize = _secondaryRenderSize;
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] image-primary canvas uses secondary "
              "video render size | size=%.0fx%.0f",
              _primaryRenderSize.width, _primaryRenderSize.height);
    }

    return self;
}

// ─── Phase 7.x-F / 7.x-G: Dealloc — release retained CVPixelBuffers ─────────

- (void)dealloc {
    // Release the retained primary buffer if any.
    // dealloc is single-threaded (no concurrent access after last release).
    if (_primaryLastBuffer) {
        CVPixelBufferRelease(_primaryLastBuffer);
        _primaryLastBuffer = NULL;
    }
    // Phase 7.x-G: Release the retained secondary buffer if any.
    // Mirrors primary buffer release. invalidate normally handles this, but dealloc
    // is the last-resort safety net if the node is torn down without invalidate.
    if (_secondaryLastBuffer) {
        CVPixelBufferRelease(_secondaryLastBuffer);
        _secondaryLastBuffer = NULL;
    }
    // Phase 7.x-H: Release composited buffer.
    if (_compositedLastBuffer) {
        CVPixelBufferRelease(_compositedLastBuffer);
        _compositedLastBuffer = NULL;
    }
    // Phase 7.x-L: Release still-image buffers.
    if (_primaryImageBuffer) {
        CVPixelBufferRelease(_primaryImageBuffer);
        _primaryImageBuffer = NULL;
    }
    if (_secondaryImageBuffer) {
        CVPixelBufferRelease(_secondaryImageBuffer);
        _secondaryImageBuffer = NULL;
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
    // Phase 7.x-G: Cancel and release the secondary reader together.
    // invalidate may be called from any thread.
    [self _cancelAndClearPrimaryReader];
    [self _cancelAndClearSecondaryReader];
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

    // Phase 7.x-G: Clear both readers together on seek.
    [self _cancelAndClearPrimaryReader];
    [self _cancelAndClearSecondaryReader];

    NSLog(@"[VGDualCameraCompositorNode][7.x-F/G] seekTo: time=%.3fs gen=%llu",
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

    // Phase 7.x-N: DEV telemetry — count every valid (non-cancelled, non-invalidated) pull.
    // Also capture wall-clock t0 for pull-frame timing.
    atomic_fetch_add(&_primaryPullCount, 1);
    // Phase 7.x-N (patch): timing start.
    uint64_t _pullT0Ns = (uint64_t)(CACurrentMediaTime() * 1.0e9);

    // ── 2. Generation guard ─────────────────────────────────────────────────
    //
    // If the scheduler's request.generation differs from our stored generation,
    // we are receiving a stale request from before a seek. Return skipped.
    uint64_t currentGen = atomic_load(&_primaryGeneration);
    if (request.generation != currentGen) {
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // ── 3. Primary clip shape guard ─────────────────────────────────────────
    //
    // Phase 7.x-F: video-only; Phase 7.x-L adds VGClipMediaKindImage.
    // Audio-only and unknown media kinds remain unsupported.
    VGClipDescriptor *clip = _primaryClip;

    if (clip.mediaKind != VGClipMediaKindVideo &&
        clip.mediaKind != VGClipMediaKindImage) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-F/L][DEV] primaryClip has unsupported "
              "mediaKind=%ld. Only Video and Image are supported. "
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

    // ── Phase 7.x-L: Still-image primary clip — lazy load only ───────────────
    //
    // Image clips bypass AVAssetReader entirely. We load the source once into
    // a Metal-compatible 32BGRA CVPixelBuffer and cache it for the full clip duration.
    //
    // This block sets _primaryLastBuffer and the pseudo sample-window, then falls
    // through to the shared flow: global EOS check → secondary lazy init →
    // secondary advance → sample-window cache-hit → composition/delivery.
    //
    // It does NOT return early. That is the key difference from the previous
    // broken implementation which bypassed secondary initialization.
    if (clip.mediaKind == VGClipMediaKindImage) {
        if (_primaryImageBuffer == NULL) {
            size_t imgW = (size_t)(_primaryRenderSize.width  > 1.0 ? _primaryRenderSize.width  : 1280.0);
            size_t imgH = (size_t)(_primaryRenderSize.height > 1.0 ? _primaryRenderSize.height : 720.0);
            CVPixelBufferRef imgBuf = [self _buildImageBufferForClip:clip
                                                         renderWidth:imgW
                                                        renderHeight:imgH];
            if (imgBuf == NULL) {
                NSLog(@"[VGDualCameraCompositorNode][7.x-L] primary image buffer build failed "
                      "— returning skipped. clipId=%@", clip.clipId);
                return [VGFrameResult skippedWithGeneration:request.generation];
            }
            _primaryImageBuffer = imgBuf; // node owns +1 from _buildImageBufferForClip
            // Phase 7.x-N (patch): count successful primary image buffer builds.
            atomic_fetch_add(&_imageBufferBuildCount, 1);
        }

        // Populate _primaryLastBuffer once (or after seek when _primaryImageBuffer was reset).
        if (_primaryLastBuffer != _primaryImageBuffer) {
            if (_primaryLastBuffer) {
                CVPixelBufferRelease(_primaryLastBuffer);
            }
            CVPixelBufferRetain(_primaryImageBuffer); // +1 for _primaryLastBuffer
            _primaryLastBuffer = _primaryImageBuffer;
            // Phase 7.x-N: update byte estimate atomically.
            {
                size_t bpr = CVPixelBufferGetBytesPerRow(_primaryLastBuffer);
                size_t h   = CVPixelBufferGetHeight(_primaryLastBuffer);
                atomic_store(&_primaryLastBufferEstBytes, (uint64_t)(bpr * h));
            }

            // Pseudo sample-window covering the full clip duration so the cache-hit
            // path below fires on every subsequent frame without re-entering this block.
            double imgSpeed = (clip.speed > 0.0) ? clip.speed : 1.0;
            double imgClipDur = (clip.trimEndSeconds - clip.trimStartSeconds) / imgSpeed;
            _primaryLastSamplePTS      = 0.0;
            _primaryLastSampleDuration = imgClipDur > 0.0 ? imgClipDur : 3600.0;
        }

        // One-time log.
        if (!_primaryImageLogged) {
            _primaryImageLogged = YES;
            NSLog(@"[VGDualCameraCompositorNode][7.x-L] primary image buffer ready | "
                  "size=%zux%zu clipId=%@",
                  CVPixelBufferGetWidth(_primaryImageBuffer),
                  CVPixelBufferGetHeight(_primaryImageBuffer),
                  clip.clipId);
        }

        // Fall through to: global EOS (step 4) → secondary lazy init (step 5b) →
        // reader-status guard (skipped for image) → sample-window cache-hit (step 7) →
        // secondary advance → composition → delivery.
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
    // Phase 7.x-L: Image primary has no AVAssetReader; skip reader init entirely.
    if (clip.mediaKind != VGClipMediaKindImage && _primaryReader == nil) {
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

    // ── 5b. Lazy secondary reader / image initialization (Phase 7.x-G / 7.x-L) ─
    //
    // Video: mirror the primary reader lazy build.
    // Image (Phase 7.x-L): load once into _secondaryLastBuffer; no AVAssetReader needed.
    // Unsupported shapes (audio, unknown, freeze, reversed) skip silently.
    if (!_secondaryEOSReached && _secondaryReader == nil && !_secondaryIsImage) {
        VGClipDescriptor *secClip = _secondaryClip;

        // Phase 7.x-L: still-image secondary.
        if (secClip.mediaKind == VGClipMediaKindImage &&
            secClip.freezePTS == nil &&
            !secClip.isReversed &&
            secClip.sourceURL.length > 0) {

            // Load the secondary image at a reasonable size. Use the primary
            // render size as the target canvas so composition dimensions match.
            size_t secImgW = (size_t)(_primaryRenderSize.width  > 1.0 ? _primaryRenderSize.width  : 1280.0);
            size_t secImgH = (size_t)(_primaryRenderSize.height > 1.0 ? _primaryRenderSize.height : 720.0);
            CVPixelBufferRef secImgBuf = [self _buildImageBufferForClip:secClip
                                                            renderWidth:secImgW
                                                           renderHeight:secImgH];
            if (secImgBuf != NULL) {
                // Release any previous secondary buffer.
                if (_secondaryLastBuffer) {
                    CVPixelBufferRelease(_secondaryLastBuffer);
                }
                _secondaryImageBuffer = secImgBuf; // node owns +1
                CVPixelBufferRetain(secImgBuf);    // +1 for _secondaryLastBuffer
                _secondaryLastBuffer        = secImgBuf;
                // Phase 7.x-N: update byte estimate atomically.
                {
                    size_t bpr = CVPixelBufferGetBytesPerRow(_secondaryLastBuffer);
                    size_t h   = CVPixelBufferGetHeight(_secondaryLastBuffer);
                    atomic_store(&_secondaryLastBufferEstBytes, (uint64_t)(bpr * h));
                }
                _secondaryLastSamplePTS     = 0.0;
                double secSpeed = (secClip.speed > 0.0) ? secClip.speed : 1.0;
                double secDur   = (secClip.trimEndSeconds - secClip.trimStartSeconds) / secSpeed;
                _secondaryLastSampleDuration = secDur > 0.0 ? secDur : 3600.0;
                _secondaryIsImage            = YES;
                // Phase 7.x-N (patch): count successful secondary image buffer builds.
                atomic_fetch_add(&_imageBufferBuildCount, 1);
                // Do NOT mark EOS: image is always available.
            } else {
                NSLog(@"[VGDualCameraCompositorNode][7.x-L] secondary image buffer build failed — "
                      "secondary decode skipped. clipId=%@", secClip.clipId);
                _secondaryEOSReached = YES;
            }

        } else {
            // Video secondary (existing path).
            BOOL secCanRead = (secClip.mediaKind == VGClipMediaKindVideo &&
                               secClip.freezePTS == nil &&
                               !secClip.isReversed &&
                               secClip.sourceURL.length > 0);
            if (secCanRead) {
                // Map primary requestedPTSSecs to secondary asset time.
                double secSpeed = (secClip.speed > 0.0) ? secClip.speed : 1.0;
                double secAssetTime = secClip.trimStartSeconds + requestedPTSSecs * secSpeed;
                if (secAssetTime < secClip.trimStartSeconds) { secAssetTime = secClip.trimStartSeconds; }
                if (secAssetTime > secClip.trimEndSeconds)   { secAssetTime = secClip.trimEndSeconds;   }

                NSError *secBuildError = nil;
                BOOL secBuilt = [self _buildSecondaryReaderStartingAtTime:secAssetTime
                                                                    error:&secBuildError];
                if (!secBuilt) {
                    NSLog(@"[VGDualCameraCompositorNode][7.x-G] Failed to build secondary reader: %@. "
                          "Secondary decode disabled for this session. clipId=%@",
                          secBuildError.localizedDescription, secClip.clipId);
                    _secondaryEOSReached = YES;
                }
            } else {
                NSLog(@"[VGDualCameraCompositorNode][7.x-G/L] secondary clip shape unsupported "
                      "(mediaKind=%ld freezePTS=%@ isReversed=%d sourceURL=%@); "
                      "secondary decode skipped. clipId=%@",
                      (long)_secondaryClip.mediaKind,
                      _secondaryClip.freezePTS,
                      _secondaryClip.isReversed,
                      _secondaryClip.sourceURL.length > 0 ? @"<set>" : @"<empty>",
                      _secondaryClip.clipId);
                _secondaryEOSReached = YES;
            }
        }
    }

    // ── 6. Check reader is still alive ──────────────────────────────────────
    //
    // AVAssetReader.status transitions from Reading to Completed/Failed/Cancelled
    // once the stream is exhausted or cancelled.
    // Phase 7.x-L: Image primary has no _primaryReader; skip this guard entirely.
    if (clip.mediaKind != VGClipMediaKindImage &&
        _primaryReader.status != AVAssetReaderStatusReading) {
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

        // Phase 7.x-G/L: Advance secondary reader in parallel with primary cache hit.
        // Image secondary: no-op (buffer is always ready). Video secondary: advance reader.
        // The secondary advance result does not affect primary delivery.
        if (!_secondaryEOSReached) {
            if (!_secondaryIsImage) {
                BOOL secOk = [self _advanceSecondaryReaderToRequestedPTS:requestedPTSSecs
                                                              generation:currentGen];
                if (!secOk) {
                    _secondaryEOSReached = YES;
                }
            }
        }

        // Phase 7.x-H/K: Attempt composition if secondary buffer is available.
        // Branch on layoutMode: PiP (7.x-H/J) or split-screen (7.x-K).
        // Fallback to primary-only envelope if compositing fails or secondary unavailable.
        if (_secondaryLastBuffer != NULL) {
            CVPixelBufferRef composited = NULL;
            BOOL isSplitMode = (_layoutMode == VGDualCameraLayoutModeSplitScreen);
            if (isSplitMode) {
                composited = [self _compositeWithSplitScreen:cachedBuf
                                                  secondary:_secondaryLastBuffer];
            } else {
                composited = [self _compositeWithPrimary:cachedBuf
                                              secondary:_secondaryLastBuffer];
            }
            if (composited != NULL) {
                // Phase 7.x-N: DEV telemetry — count successful compositions.
                atomic_fetch_add(&_compositedFrameCount, 1);
                if (isSplitMode) {
                    atomic_fetch_add(&_splitScreenCompositionCount, 1);
                } else {
                    atomic_fetch_add(&_pipCompositionCount, 1);
                }
                // Release old composited buffer before storing new one.
                if (_compositedLastBuffer) {
                    CVPixelBufferRelease(_compositedLastBuffer);
                }
                _compositedLastBuffer = composited; // node takes +1 from _composite

                VGFrameEnvelope compEnvelope;
                compEnvelope.pts        = request.requestedPTS;
                compEnvelope.dts        = kCMTimeInvalid;
                compEnvelope.duration   = CMTimeMakeWithSeconds(_primaryLastSampleDuration, 600);
                compEnvelope.generation = currentGen;
                compEnvelope.mediaType  = VGMediaTypeVideo;
                compEnvelope.payload.videoBuffer = (void *)composited; // +0 in envelope
                compEnvelope.metadata   = NULL;

                // Phase 7.x-N / 7.x-P: record timing for this delivered composited frame.
                // Phase 7.x-P: capture first-frame latency (elapsed from _pullT0Ns).
                {
                    uint64_t dur = (uint64_t)(CACurrentMediaTime() * 1.0e9) - _pullT0Ns;
                    atomic_store(&_lastPullFrameNs, dur);
                    atomic_fetch_add(&_totalPullFrameNs, dur);
                    atomic_fetch_add(&_pullTimedCallCount, 1);
                    uint64_t prev = atomic_load(&_maxPullFrameNs);
                    while (dur > prev) {
                        if (atomic_compare_exchange_weak(&_maxPullFrameNs, &prev, dur)) break;
                    }
                    uint64_t zero = 0;
                    atomic_compare_exchange_strong(&_firstFrameLatencyNs, &zero, dur);
                }

                return [VGFrameResult deliveredWithEnvelope:compEnvelope generation:currentGen];
            }
            // Compositing failed — fall through to primary-only delivery below.
            // Phase 7.x-N (patch): count the failure and the fallback.
            atomic_fetch_add(&_compositionFailureCount, 1);
            atomic_fetch_add(&_fallbackToPrimaryCount, 1);
        } else {
            // No secondary buffer available — deliver primary-only.
            // Phase 7.x-N (patch): count fallback when secondary was expected but missing.
            if (!_secondaryEOSReached) {
                atomic_fetch_add(&_fallbackToPrimaryCount, 1);
            }
        }

        // Phase 7.x-N (patch): record timing for primary-only delivery.
        // Phase 7.x-P: capture first-frame latency (elapsed from _pullT0Ns).
        {
            uint64_t dur = (uint64_t)(CACurrentMediaTime() * 1.0e9) - _pullT0Ns;
            atomic_store(&_lastPullFrameNs, dur);
            atomic_fetch_add(&_totalPullFrameNs, dur);
            atomic_fetch_add(&_pullTimedCallCount, 1);
            uint64_t prev = atomic_load(&_maxPullFrameNs);
            while (dur > prev) {
                if (atomic_compare_exchange_weak(&_maxPullFrameNs, &prev, dur)) break;
            }
            uint64_t zero = 0;
            atomic_compare_exchange_strong(&_firstFrameLatencyNs, &zero, dur);
        }

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

        // Phase 7.x-N: DEV telemetry — count each real decode call.
        atomic_fetch_add(&_primaryDecodeCount, 1);
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
        // Phase 7.x-N: update byte estimate atomically.
        {
            size_t bpr = CVPixelBufferGetBytesPerRow(_primaryLastBuffer);
            size_t h   = CVPixelBufferGetHeight(_primaryLastBuffer);
            atomic_store(&_primaryLastBufferEstBytes, (uint64_t)(bpr * h));
        }

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

            // Phase 7.x-G/L: Advance secondary reader in parallel with primary frame
            // delivery. Image secondary: no-op. Video secondary: advance reader.
            // The secondary advance result does not affect primary delivery.
            if (!_secondaryEOSReached) {
                if (!_secondaryIsImage) {
                    BOOL secOk = [self _advanceSecondaryReaderToRequestedPTS:requestedPTSSecs
                                                                  generation:currentGen];
                    if (!secOk) {
                        _secondaryEOSReached = YES;
                    }
                }
            }

            // Phase 7.x-H/K: Attempt composition if secondary buffer is available.
            // Branch on layoutMode: PiP (7.x-H/J) or split-screen (7.x-K).
            // Fallback to primary-only envelope if compositing fails or secondary unavailable.
            if (_secondaryLastBuffer != NULL) {
                CVPixelBufferRef composited = NULL;
                BOOL isSplitMode2 = (_layoutMode == VGDualCameraLayoutModeSplitScreen);
                if (isSplitMode2) {
                    composited = [self _compositeWithSplitScreen:pixelBuffer
                                                      secondary:_secondaryLastBuffer];
                } else {
                    composited = [self _compositeWithPrimary:pixelBuffer
                                                  secondary:_secondaryLastBuffer];
                }
                if (composited != NULL) {
                    // Phase 7.x-N: DEV telemetry — count successful compositions.
                    atomic_fetch_add(&_compositedFrameCount, 1);
                    if (isSplitMode2) {
                        atomic_fetch_add(&_splitScreenCompositionCount, 1);
                    } else {
                        atomic_fetch_add(&_pipCompositionCount, 1);
                    }
                    // Release old composited buffer before storing new one.
                    if (_compositedLastBuffer) {
                        CVPixelBufferRelease(_compositedLastBuffer);
                    }
                    _compositedLastBuffer = composited; // node takes +1 from _composite

                    VGFrameEnvelope compEnvelope;
                    compEnvelope.pts        = request.requestedPTS;
                    compEnvelope.dts        = kCMTimeInvalid;
                    compEnvelope.duration   = CMTimeMakeWithSeconds(sDur, 600);
                    compEnvelope.generation = currentGen;
                    compEnvelope.mediaType  = VGMediaTypeVideo;
                    compEnvelope.payload.videoBuffer = (void *)composited; // +0 in envelope
                    compEnvelope.metadata   = NULL;

                    // Phase 7.x-N (patch): record timing for composited frame delivery.
                    // Phase 7.x-P: capture first-frame latency (elapsed from _pullT0Ns).
                    {
                        uint64_t dur = (uint64_t)(CACurrentMediaTime() * 1.0e9) - _pullT0Ns;
                        atomic_store(&_lastPullFrameNs, dur);
                        atomic_fetch_add(&_totalPullFrameNs, dur);
                        atomic_fetch_add(&_pullTimedCallCount, 1);
                        uint64_t prev = atomic_load(&_maxPullFrameNs);
                        while (dur > prev) {
                            if (atomic_compare_exchange_weak(&_maxPullFrameNs, &prev, dur)) break;
                        }
                        uint64_t zero = 0;
                        atomic_compare_exchange_strong(&_firstFrameLatencyNs, &zero, dur);
                    }

                    return [VGFrameResult deliveredWithEnvelope:compEnvelope generation:currentGen];
                }
                // Compositing failed — fall through to primary-only delivery below.
                // Phase 7.x-N (patch): count the failure and the fallback.
                atomic_fetch_add(&_compositionFailureCount, 1);
                atomic_fetch_add(&_fallbackToPrimaryCount, 1);
            } else {
                // No secondary buffer — deliver primary-only.
                if (!_secondaryEOSReached) {
                    atomic_fetch_add(&_fallbackToPrimaryCount, 1);
                }
            }

            // Phase 7.x-N (patch): record timing for primary-only delivery.
            // Phase 7.x-P: capture first-frame latency (elapsed from _pullT0Ns).
            {
                uint64_t dur = (uint64_t)(CACurrentMediaTime() * 1.0e9) - _pullT0Ns;
                atomic_store(&_lastPullFrameNs, dur);
                atomic_fetch_add(&_totalPullFrameNs, dur);
                atomic_fetch_add(&_pullTimedCallCount, 1);
                uint64_t prev = atomic_load(&_maxPullFrameNs);
                while (dur > prev) {
                    if (atomic_compare_exchange_weak(&_maxPullFrameNs, &prev, dur)) break;
                }
                uint64_t zero = 0;
                atomic_compare_exchange_strong(&_firstFrameLatencyNs, &zero, dur);
            }

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

// ─── Phase 7.x-L: Private — Build still-image pixel buffer ──────────────────────
//
// Loads a still image from clip.sourceURL using the CoreImage-native path
// (CIImage imageWithContentsOfURL:). Does NOT use UIKit/UIImage.
//
// The image is aspect-fill scaled into a renderWidth × renderHeight canvas,
// centered, and rendered once into a Metal-compatible 32BGRA CVPixelBuffer
// using the shared CIContext.
//
// Ownership: Returns a CVPixelBufferRef at +1 (caller owns via CVPixelBufferCreate).
//            Returns NULL on any failure (logs the reason); does not crash.
//
// Calling convention: called at most once per clip lifecycle (lazy, on first pullFrame:).
// Callers store the result in _primaryImageBuffer or _secondaryImageBuffer and
// must release it on seek, invalidate, and dealloc.

- (nullable CVPixelBufferRef)_buildImageBufferForClip:(VGClipDescriptor *)clip
                                          renderWidth:(size_t)renderWidth
                                         renderHeight:(size_t)renderHeight {
    if (!clip || clip.sourceURL.length == 0) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: nil clip or empty sourceURL.");
        return NULL;
    }

    if (renderWidth < 1 || renderHeight < 1) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: degenerate canvas "
              "size %zux%zu for clipId=%@.", renderWidth, renderHeight, clip.clipId);
        return NULL;
    }

    // ── 1. Load CIImage from file URL (CoreImage-native; no UIKit) ─────────────
    NSURL *fileURL = [NSURL fileURLWithPath:clip.sourceURL];
    if (!fileURL) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: invalid fileURL "
              "for sourceURL=%@ clipId=%@.", clip.sourceURL, clip.clipId);
        return NULL;
    }

    CIImage *srcImage = [CIImage imageWithContentsOfURL:fileURL];
    if (!srcImage) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: CIImage load failed "
              "for sourceURL=%@ clipId=%@.", clip.sourceURL, clip.clipId);
        return NULL;
    }

    // ── 2. Normalize CIImage origin to (0, 0) ──────────────────────────────────
    CGRect srcExtent = srcImage.extent;
    // CGRectIsFinite is not declared in all SDK configurations; use isfinite()
    // on individual fields instead (equivalent check, always available via math.h).
    BOOL extentFinite = (isfinite(srcExtent.origin.x) &&
                         isfinite(srcExtent.origin.y) &&
                         isfinite(srcExtent.size.width) &&
                         isfinite(srcExtent.size.height));
    if (!extentFinite || srcExtent.size.width < 1.0 || srcExtent.size.height < 1.0) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: degenerate CIImage "
              "extent for clipId=%@.", clip.clipId);
        return NULL;
    }

    CIImage *normalized = srcImage;
    if (srcExtent.origin.x != 0.0 || srcExtent.origin.y != 0.0) {
        CGAffineTransform normT = CGAffineTransformMakeTranslation(-srcExtent.origin.x,
                                                                    -srcExtent.origin.y);
        normalized = [srcImage imageByApplyingTransform:normT];
        srcExtent  = normalized.extent;
    }

    double srcW = srcExtent.size.width;
    double srcH = srcExtent.size.height;

    // ── 3. Aspect-fill scale into canvas ──────────────────────────────────────
    //
    // scale = MAX(canvasW / srcW, canvasH / srcH) — fills the canvas entirely.
    // Center the scaled image so equal amounts are cropped from each side.
    double canvasW = (double)renderWidth;
    double canvasH = (double)renderHeight;
    double scaleX  = (srcW > 0.0) ? canvasW / srcW : 1.0;
    double scaleY  = (srcH > 0.0) ? canvasH / srcH : 1.0;
    double scale   = MAX(scaleX, scaleY);
    if (scale <= 0.0) { scale = 1.0; }

    CGAffineTransform scaleT = CGAffineTransformMakeScale(scale, scale);
    CIImage *scaled = [normalized imageByApplyingTransform:scaleT];

    // Center-translate so scaled image is centered over {0, 0, canvasW, canvasH}.
    double scaledW  = srcW * scale;
    double scaledH  = srcH * scale;
    double offsetX  = (canvasW - scaledW) * 0.5;
    double offsetY  = (canvasH - scaledH) * 0.5;
    CGAffineTransform transT = CGAffineTransformMakeTranslation(offsetX, offsetY);
    CIImage *centered = [scaled imageByApplyingTransform:transT];

    // Crop to canvas bounds — removes any overflow from aspect-fill.
    CGRect canvasRect = CGRectMake(0.0, 0.0, canvasW, canvasH);
    CIImage *cropped  = [centered imageByCroppingToRect:canvasRect];
    if (!cropped) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: imageByCroppingToRect "
              "returned nil for clipId=%@.", clip.clipId);
        return NULL;
    }

    // ── 4. Allocate output CVPixelBuffer ──────────────────────────────────────
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey    : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef outputBuf = NULL;
    CVReturn cvRet = CVPixelBufferCreate(
        kCFAllocatorDefault,
        renderWidth, renderHeight,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &outputBuf);

    if (cvRet != kCVReturnSuccess || outputBuf == NULL) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: CVPixelBufferCreate "
              "failed (ret=%d) for clipId=%@.", cvRet, clip.clipId);
        return NULL;
    }
    // Phase 7.x-N (patch): count successful output buffer allocations.
    atomic_fetch_add(&_outputBufferCreateCount, 1);

    // ── 5. Render CIImage into output buffer ──────────────────────────────────
    [_VGDCCNSharedCIContext() render:cropped
                     toCVPixelBuffer:outputBuf
                               bounds:canvasRect
                           colorSpace:nil];

    NSLog(@"[VGDualCameraCompositorNode][7.x-L] _buildImageBuffer: image rendered ok "
          "| canvas=%zux%zu srcSize=%.0fx%.0f scale=%.4f clipId=%@",
          renderWidth, renderHeight, srcW, srcH, scale, clip.clipId);

    return outputBuf; // Caller owns +1 from CVPixelBufferCreate
}

// ─── Phase 7.x-K: Private — Split-screen CoreImage compositor ────────────────────
//
// Composites primary and secondary into a vertical split-screen layout.
// Primary fills the top half; secondary fills the bottom half.
// The split point is determined by _splitLayout.splitRatio.
//
// Portrait split geometry (CoreImage Y-up, origin bottom-left):
//   canvas   = (primW, primH)
//   topH     = round(primH * splitRatio)    ← primary (top)
//   bottomH  = primH - topH                 ← secondary (bottom)
//
//   primary target rect   = {x=0, y=bottomH, w=primW, h=topH}   (upper band)
//   secondary target rect = {x=0, y=0,       w=primW, h=bottomH} (lower band)
//
// Each clip is aspect-fill scaled into its target rect:
//   scale = MAX(targetW / sourceW, targetH / sourceH)
// Centered, then cropped to prevent bleed across the split boundary.
//
// Returns a new CVPixelBufferRef at +1 (caller owns). Returns NULL on failure.

- (CVPixelBufferRef)_compositeWithSplitScreen:(CVPixelBufferRef)primaryBuf
                                    secondary:(CVPixelBufferRef)secondaryBuf {
    if (!primaryBuf || !secondaryBuf) {
        return NULL;
    }

    // ── 1. Dimensions ───────────────────────────────────────────────────────────
    size_t primW = CVPixelBufferGetWidth(primaryBuf);
    size_t primH = CVPixelBufferGetHeight(primaryBuf);
    size_t secW  = CVPixelBufferGetWidth(secondaryBuf);
    size_t secH  = CVPixelBufferGetHeight(secondaryBuf);

    if (primW == 0 || primH == 0 || secW == 0 || secH == 0) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-K] _splitComposite: degenerate dimensions "
              "prim=%zux%zu sec=%zux%zu — skipping.", primW, primH, secW, secH);
        return NULL;
    }

    // ── 2. Split geometry ───────────────────────────────────────────────────────
    double sr = _splitLayout.splitRatio;
    // Clamp to safe range.
    if (sr < 0.2) { sr = 0.2; }
    if (sr > 0.8) { sr = 0.8; }

    // topH: height of the primary (top) band (CoreImage Y-up: upper y values).
    // bottomH: height of the secondary (bottom) band (y=0 at bottom-left).
    double topH    = floor((double)primH * sr);
    double bottomH = (double)primH - topH;

    // Guard: both bands must be at least 1 pixel.
    if (topH < 1.0 || bottomH < 1.0) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-K] _splitComposite: degenerate band height "
              "topH=%.0f bottomH=%.0f — skipping.", topH, bottomH);
        return NULL;
    }

    double canvasW = (double)primW;
    double canvasH = (double)primH;

    // ── 3. Build CIImages ────────────────────────────────────────────────────────
    CIImage *primaryCI   = [CIImage imageWithCVPixelBuffer:primaryBuf];
    CIImage *secondaryCI = [CIImage imageWithCVPixelBuffer:secondaryBuf];
    if (!primaryCI || !secondaryCI) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-K] _splitComposite: CIImage creation failed.");
        return NULL;
    }

    // ── 4. Helper: aspect-fill + crop a CIImage into a target rect ──────────
    //
    // For each band:
    //   1. Normalize source origin to (0,0).
    //   2. Compute scale = MAX(targetW/sourceW, targetH/sourceH).
    //   3. Scale.
    //   4. Center-translate so the scaled image is centered over the target rect
    //      (origin at targetOriginX, targetOriginY).
    //   5. Crop to the target rect to prevent bleed.
    //
    // CoreImage Y-up: top band origin Y = bottomH, bottom band origin Y = 0.

    // — Primary (top band) —————————————————————————————————————
    // Target rect (CIImage Y-up): {x=0, y=bottomH, w=canvasW, h=topH}
    CGRect topRect    = CGRectMake(0.0, bottomH, canvasW, topH);
    CGRect bottomRect = CGRectMake(0.0, 0.0,     canvasW, bottomH);

    // Aspect-fill helper — normalize, scale-to-fill, center, crop.
    CIImage *(^aspectFillIntoRect)(CIImage *, size_t, size_t, CGRect) =
        ^CIImage *(CIImage *src, size_t srcW, size_t srcH, CGRect targetRect) {
            // 1. Normalize origin.
            CIImage *norm = src;
            CGPoint srcOrigin = norm.extent.origin;
            if (srcOrigin.x != 0.0 || srcOrigin.y != 0.0) {
                CGAffineTransform normT = CGAffineTransformMakeTranslation(-srcOrigin.x, -srcOrigin.y);
                norm = [norm imageByApplyingTransform:normT];
            }

            // 2. Scale = MAX(targetW / srcW, targetH / srcH).
            double scaleX = (srcW > 0) ? CGRectGetWidth(targetRect)  / (double)srcW : 1.0;
            double scaleY = (srcH > 0) ? CGRectGetHeight(targetRect) / (double)srcH : 1.0;
            double scale = MAX(scaleX, scaleY);
            if (scale <= 0.0) { scale = 1.0; }

            // 3. Apply uniform scale.
            CGAffineTransform scaleT = CGAffineTransformMakeScale(scale, scale);
            CIImage *scaled = [norm imageByApplyingTransform:scaleT];

            // 4. Center-translate: move the scaled image so its center aligns with
            //    the target rect center.
            double scaledW = (double)srcW * scale;
            double scaledH = (double)srcH * scale;
            double offsetX = CGRectGetMinX(targetRect) + (CGRectGetWidth(targetRect)  - scaledW) * 0.5;
            double offsetY = CGRectGetMinY(targetRect) + (CGRectGetHeight(targetRect) - scaledH) * 0.5;
            CGAffineTransform transT = CGAffineTransformMakeTranslation(offsetX, offsetY);
            CIImage *centered = [scaled imageByApplyingTransform:transT];

            // 5. Crop strictly to targetRect — prevents bleed into the other band.
            return [centered imageByCroppingToRect:targetRect];
        };

    CIImage *topBand    = aspectFillIntoRect(primaryCI,   primW, primH, topRect);
    CIImage *bottomBand = aspectFillIntoRect(secondaryCI, secW,  secH,  bottomRect);

    if (!topBand || !bottomBand) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-K] _splitComposite: aspectFill failed.");
        return NULL;
    }

    // ── 5. Composite: top band over bottom band (source-over on non-overlapping extents) ─
    //
    // Because the two rects are non-overlapping and the crops are strict,
    // imageByCompositingOverImage: simply unions them on the canvas.
    // We use a black backing canvas to ensure the full primW x primH output.
    CGRect canvasRect = CGRectMake(0, 0, canvasW, canvasH);
    CIImage *blackCanvas = [[CIImage imageWithColor:[CIColor blackColor]]
        imageByCroppingToRect:canvasRect];
    CIImage *withBottom  = [bottomBand imageByCompositingOverImage:blackCanvas];
    CIImage *composited  = [topBand    imageByCompositingOverImage:withBottom];

    if (!composited) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-K] _splitComposite: compositing failed.");
        return NULL;
    }

    // ── 6. Create output CVPixelBuffer ─────────────────────────────────────────────
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey    : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef outputBuf = NULL;
    CVReturn cvRet = CVPixelBufferCreate(
        kCFAllocatorDefault,
        primW, primH,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &outputBuf);

    if (cvRet != kCVReturnSuccess || outputBuf == NULL) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-K] _splitComposite: CVPixelBufferCreate failed (ret=%d).", cvRet);
        return NULL;
    }
    // Phase 7.x-N (patch): count successful output buffer allocations.
    atomic_fetch_add(&_outputBufferCreateCount, 1);

    // ── 7. Render into output buffer ─────────────────────────────────────────────
    CGRect renderBounds = CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH);
    [_VGDCCNSharedCIContext() render:composited
                     toCVPixelBuffer:outputBuf
                               bounds:renderBounds
                           colorSpace:nil];

    // ── 8. One-time first-frame log (Phase 7.x-K) ─────────────────────────────
    if (!_splitFirstFrameLogged) {
        _splitFirstFrameLogged = YES;
        NSLog(@"[VGDualCameraCompositorNode][7.x-K] first split-screen frame generated | "
              "primaryRect=(0,%.0f,%.0f,%.0f) secondaryRect=(0,0,%.0f,%.0f) "
              "splitRatio=%.3f canvas=%zux%zu",
              bottomH, canvasW, topH,
              canvasW, bottomH,
              sr, primW, primH);
    }

    return outputBuf; // Caller owns +1 from CVPixelBufferCreate
}

// ─── Phase 7.x-H: Private — PiP CoreImage compositor ────────────────────────
//
// Composites secondaryBuf as a rectangular PiP inset over primaryBuf.
// Uses PiP geometry from _pipLayout (parsed from Dart descriptor).
//
// CoreImage coordinate system is Y-up (origin at bottom-left):
//   bottom anchors: margin from minY.
//   top anchors:    margin from maxY (primaryHeight - pipH - margin from minY).
//
// Returns a new CVPixelBufferRef at +1 (caller owns). Caller must
// CVPixelBufferRelease when done. Returns NULL on failure (logs error).

- (CVPixelBufferRef)_compositeWithPrimary:(CVPixelBufferRef)primaryBuf
                                secondary:(CVPixelBufferRef)secondaryBuf {
    if (!primaryBuf || !secondaryBuf) {
        return NULL;
    }

    // ── 1. Dimensions ───────────────────────────────────────────────────────
    size_t primW = CVPixelBufferGetWidth(primaryBuf);
    size_t primH = CVPixelBufferGetHeight(primaryBuf);
    size_t secW  = CVPixelBufferGetWidth(secondaryBuf);
    size_t secH  = CVPixelBufferGetHeight(secondaryBuf);

    if (primW == 0 || primH == 0 || secW == 0 || secH == 0) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-H] _composite: degenerate buffer dimensions "
              "prim=%zux%zu sec=%zux%zu — skipping composition.", primW, primH, secW, secH);
        return NULL;
    }

    // ── 2. PiP geometry (spec: §5 of Phase 7.x-H requirement) ───────────────
    VGPiPLayoutConfig pip = _pipLayout;
    double wf = pip.widthFraction;
    double mf = pip.marginFraction;

    // Clamp widthFraction: must produce a non-zero, bounded PiP width.
    if (wf < 0.01) { wf = 0.01; }
    if (wf > 0.95) { wf = 0.95; }

    double pipW = (double)primW * wf;
    double pipH = (secH > 0 && secW > 0)
                  ? pipW * (double)secH / (double)secW
                  : pipW; // fallback: square
    double margin = (double)primW * mf;

    // Clamp: PiP must fit within primary bounds after margin.
    // Maximum pipW such that pipW + 2*margin <= primW.
    double maxPipW = (double)primW - 2.0 * margin;
    if (maxPipW < 1.0) { maxPipW = 1.0; margin = 0.0; }
    if (pipW > maxPipW) { pipW = maxPipW; }

    // Recompute pipH after pipW clamp.
    if (secW > 0) { pipH = pipW * (double)secH / (double)secW; }
    if (pipH < 1.0) { pipH = 1.0; }

    // Clamp pipH so PiP fits vertically.
    double maxPipH = (double)primH - 2.0 * margin;
    if (maxPipH < 1.0) { maxPipH = 1.0; }
    if (pipH > maxPipH) {
        pipH = maxPipH;
        // Preserve aspect ratio: scale pipW down proportionally.
        if (secH > 0) { pipW = pipH * (double)secW / (double)secH; }
    }

    // ── 3. Anchor → CIImage Y-up origin ────────────────────────────────────
    // CIImage coordinate system: Y=0 at bottom, Y=primH at top.
    // margin from the edge:
    //   bottom anchors: pipOriginY = margin
    //   top anchors:    pipOriginY = primH - pipH - margin
    double pipOriginX = 0.0;
    double pipOriginY = 0.0;

    switch (pip.anchor) {
        case VGPiPAnchorTopLeft:
            pipOriginX = margin;
            pipOriginY = (double)primH - pipH - margin;
            break;
        case VGPiPAnchorTopRight:
            pipOriginX = (double)primW - pipW - margin;
            pipOriginY = (double)primH - pipH - margin;
            break;
        case VGPiPAnchorBottomLeft:
            pipOriginX = margin;
            pipOriginY = margin;
            break;
        case VGPiPAnchorBottomRight:
        default:
            pipOriginX = (double)primW - pipW - margin;
            pipOriginY = margin;
            break;
    }

    // Clamp origin so PiP stays within primary bounds.
    if (pipOriginX < 0.0) { pipOriginX = 0.0; }
    if (pipOriginY < 0.0) { pipOriginY = 0.0; }
    if (pipOriginX + pipW > (double)primW) { pipOriginX = (double)primW - pipW; }
    if (pipOriginY + pipH > (double)primH) { pipOriginY = (double)primH - pipH; }

    // ── 4. Build CIImages ────────────────────────────────────────────────────
    CIImage *primaryCI  = [CIImage imageWithCVPixelBuffer:primaryBuf];
    CIImage *secondaryCI = [CIImage imageWithCVPixelBuffer:secondaryBuf];

    if (!primaryCI || !secondaryCI) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-H] _composite: CIImage creation failed.");
        return NULL;
    }

    // ── 5. Scale secondary to PiP size ───────────────────────────────────────
    // CIImage extent origin may be non-zero (CoreImage convention); normalize first.
    // Use CGAffineTransform translation via -imageByApplyingTransform: (not CATransform3D).
    CIImage *secNorm = secondaryCI;
    CGPoint secOrigin = secNorm.extent.origin;
    if (secOrigin.x != 0.0 || secOrigin.y != 0.0) {
        CGAffineTransform normT = CGAffineTransformMakeTranslation(-secOrigin.x, -secOrigin.y);
        secNorm = [secNorm imageByApplyingTransform:normT];
    }

    double scaleX = (secW > 0) ? pipW / (double)secW : 1.0;
    double scaleY = (secH > 0) ? pipH / (double)secH : 1.0;
    CGAffineTransform scaleT = CGAffineTransformMakeScale(scaleX, scaleY);
    CIImage *secScaled = [secNorm imageByApplyingTransform:scaleT];

    // ── 6. Translate secondary to PiP position ───────────────────────────────
    CGAffineTransform translateT = CGAffineTransformMakeTranslation(pipOriginX, pipOriginY);
    CIImage *secPositioned = [secScaled imageByApplyingTransform:translateT];

    // ── 7. Phase 7.x-J: Apply corner radius mask (CIRoundedRectangleGenerator) ──
    //
    // Mirrors VanguardDualCameraCompositor.swift §E (CIRoundedRectangleGenerator
    // + CIBlendWithAlphaMask). The mask is built in PiP-local space (origin 0,0)
    // then applied BEFORE translation so the extent matches the scaled PiP image.
    //
    // cornerRadius = 0.0  → mask covers the full rectangle → identical to 7.x-H.
    // cornerRadius > 0.0  → corners are transparent (alpha = 0).
    //
    // Clamp cornerRadius: must be >= 0 and <= half the shortest PiP dimension
    // so the rounded rect does not degenerate into a circle or become invisible.
    CIImage *secStyled = secPositioned;
    double cr = pip.cornerRadius;
    if (cr < 0.0) { cr = 0.0; }
    double maxCR = MIN(pipW, pipH) * 0.5;
    if (cr > maxCR) { cr = maxCR; }

    if (cr > 0.0) {
        // Build mask in PiP-local space: extent = {0, 0, pipW, pipH}.
        // secPositioned extent origin = (pipOriginX, pipOriginY) after the
        // translation above; we need the mask in the same coordinate space.
        CGRect pipLocalRect = CGRectMake(pipOriginX, pipOriginY, pipW, pipH);
        CIImage *mask = [CIFilter filterWithName:@"CIRoundedRectangleGenerator"
                                   keysAndValues:
                             @"inputExtent",  [CIVector vectorWithCGRect:pipLocalRect],
                             @"inputRadius",  @(cr),
                             @"inputColor",   [CIColor whiteColor],
                             nil].outputImage;
        if (mask) {
            mask = [mask imageByCroppingToRect:pipLocalRect];
            // CIBlendWithAlphaMask: pixels where mask.alpha > 0 are kept,
            // corners are transparent. Background = empty (transparent).
            // Use CIFilter (ObjC API) not applyingFilter:withInputParameters: (Swift-only).
            CIFilter *blendFilter = [CIFilter filterWithName:@"CIBlendWithAlphaMask"
                                                keysAndValues:
                kCIInputImageKey,       secPositioned,
                kCIInputMaskImageKey,   mask,
                kCIInputBackgroundImageKey, [CIImage emptyImage],
                nil];
            CIImage *masked = blendFilter.outputImage;
            if (masked) {
                secStyled = masked;
            }
        }
    }

    // ── 8. Phase 7.x-J: Apply opacity (CIColorMatrix alpha-channel multiply) ─
    //
    // Multiplies each pixel's alpha channel by pip.opacity.
    // opacity = 1.0 → no change (identity).
    // opacity = 0.0 → fully transparent PiP (invisible, no crash).
    //
    // CIColorMatrix inputAVector: {0, 0, 0, opacity} multiplies alpha by opacity.
    // inputRVector / inputGVector / inputBVector are identity (passthrough).
    double op = pip.opacity;
    if (op < 0.0) { op = 0.0; }
    if (op > 1.0) { op = 1.0; }

    if (op < 1.0) {
        // Use CIFilter (ObjC API) not applyingFilter:withInputParameters: (Swift-only).
        // CIColorMatrix multiplies each channel component:
        //   R' = dot(pixel, inputRVector), etc.
        //   A' = dot(pixel, inputAVector) = pixel.a * op  (since inputAVector.w = op).
        CIFilter *opacityFilter = [CIFilter filterWithName:@"CIColorMatrix"
                                              keysAndValues:
            kCIInputImageKey,           secStyled,
            @"inputRVector",   [CIVector vectorWithX:1 Y:0 Z:0 W:0],
            @"inputGVector",   [CIVector vectorWithX:0 Y:1 Z:0 W:0],
            @"inputBVector",   [CIVector vectorWithX:0 Y:0 Z:1 W:0],
            @"inputAVector",   [CIVector vectorWithX:0 Y:0 Z:0 W:op],
            @"inputBiasVector",[CIVector vectorWithX:0 Y:0 Z:0 W:0],
            nil];
        CIImage *withOpacity = opacityFilter.outputImage;
        if (withOpacity) {
            secStyled = withOpacity;
        }
    }

    // ── 9. Composite: styled secondary over primary (Porter-Duff SourceOver) ─
    CIImage *composited = [secStyled imageByCompositingOverImage:primaryCI];
    if (!composited) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-J] _composite: imageByCompositingOverImage: returned nil.");
        return NULL;
    }

    // ── 10. Create output CVPixelBuffer ──────────────────────────────────────
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey    : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef outputBuf = NULL;
    CVReturn cvRet = CVPixelBufferCreate(
        kCFAllocatorDefault,
        primW, primH,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &outputBuf);

    if (cvRet != kCVReturnSuccess || outputBuf == NULL) {
        NSLog(@"[VGDualCameraCompositorNode][7.x-J] _composite: CVPixelBufferCreate failed (ret=%d).", cvRet);
        return NULL;
    }
    // Phase 7.x-N (patch): count successful output buffer allocations.
    atomic_fetch_add(&_outputBufferCreateCount, 1);

    // ── 11. Render CIImage into output buffer ─────────────────────────────────
    CGRect renderBounds = CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH);
    [_VGDCCNSharedCIContext() render:composited
                      toCVPixelBuffer:outputBuf
                                bounds:renderBounds
                            colorSpace:nil];

    // ── 12. One-time first-frame log (Phase 7.x-J: includes cr and op) ───────
    if (!_compositedFirstFrameLogged) {
        _compositedFirstFrameLogged = YES;
        NSLog(@"[VGDualCameraCompositorNode][7.x-J] first composited frame generated | "
              "pipRect=(%.0f,%.0f,%.0f,%.0f) primSize=%zux%zu secSize=%zux%zu "
              "anchor=%ld wf=%.3f mf=%.3f cr=%.1f op=%.2f",
              pipOriginX, pipOriginY, pipW, pipH,
              primW, primH, secW, secH,
              (long)pip.anchor, pip.widthFraction, pip.marginFraction,
              cr, op);
    }

    return outputBuf; // Caller owns +1 from CVPixelBufferCreate
}

// ─── Phase 7.x-G: Private — advance secondary reader to cover requestedPTSSecs ─────────
//
// Called from pullFrame: after the primary frame is determined.
// Drives the secondary AVAssetReader with the same sample-window reuse pacing
// as the primary reader (RR-146 equivalent).
//
// The secondary buffer is decoded and stored in _secondaryLastBuffer (+1).
// In Phase 7.x-H it feeds the compositor. Released on seek/invalidate/EOS/dealloc.
//
// Returns: YES if a frame was decoded or reused. NO if secondary is exhausted
// or an error occurred (caller marks _secondaryEOSReached = YES).

- (BOOL)_advanceSecondaryReaderToRequestedPTS:(double)requestedPTSSecs
                                    generation:(uint64_t)currentGen {
    if (_secondaryEOSReached || _secondaryReader == nil) {
        return NO;
    }

    VGClipDescriptor *secClip = _secondaryClip;
    double secSpeed    = (secClip.speed > 0.0) ? secClip.speed : 1.0;
    double secAssetTime = secClip.trimStartSeconds + requestedPTSSecs * secSpeed;
    if (secAssetTime < secClip.trimStartSeconds) { secAssetTime = secClip.trimStartSeconds; }
    if (secAssetTime > secClip.trimEndSeconds)   { secAssetTime = secClip.trimEndSeconds;   }

    // ── Sample-window reuse guard (RR-146 equivalent for secondary) ──────────────
    if (_secondaryLastBuffer != NULL &&
        _secondaryLastSamplePTS >= 0.0 &&
        secAssetTime >= _secondaryLastSamplePTS &&
        secAssetTime <  _secondaryLastSamplePTS + _secondaryLastSampleDuration) {
        // Cache hit: reuse without decoding.
        return YES;
    }

    // Check secondary reader health.
    if (_secondaryReader.status != AVAssetReaderStatusReading) {
        AVAssetReaderStatus status = _secondaryReader.status;
        _secondaryLastSamplePTS      = -1.0;
        _secondaryLastSampleDuration = 0.0;
        NSLog(@"[VGDualCameraCompositorNode][7.x-G] secondary reader not reading (status=%ld). "
              "Marking secondary EOS. clipId=%@", (long)status, secClip.clipId);
        return NO;
    }

    // Advance reader until window covers secAssetTime or EOS.
    // Guard against unbounded iteration with a conservative frame-count cap.
    // 300 iterations is generous enough for any clip at up to 120 fps.
    const NSInteger kMaxSecondaryReadIterations = 300;
    NSInteger iterations = 0;

    while (iterations < kMaxSecondaryReadIterations) {
        iterations++;

        // Generation guard: bail if seek happened during secondary decode.
        if (atomic_load(&_primaryGeneration) != currentGen) {
            return NO;
        }

        if (_secondaryReader.status != AVAssetReaderStatusReading) {
            AVAssetReaderStatus status = _secondaryReader.status;
            _secondaryLastSamplePTS      = -1.0;
            _secondaryLastSampleDuration = 0.0;
            if (status == AVAssetReaderStatusCompleted) {
                NSLog(@"[VGDualCameraCompositorNode][7.x-G] secondary reader EOS in advance loop. "
                      "clipId=%@", secClip.clipId);
            } else {
                NSLog(@"[VGDualCameraCompositorNode][7.x-G] secondary reader status=%ld in advance loop. "
                      "clipId=%@", (long)status, secClip.clipId);
            }
            return NO;
        }

        // Phase 7.x-P: count each real secondary decode call.
        atomic_fetch_add(&_secondaryDecodeCount, 1);
        CMSampleBufferRef secSampleBuf = [_secondaryOutput copyNextSampleBuffer]; // +1

        if (!secSampleBuf) {
            // NULL: secondary reader exhausted or cancelled.
            _secondaryLastSamplePTS      = -1.0;
            _secondaryLastSampleDuration = 0.0;
            NSLog(@"[VGDualCameraCompositorNode][7.x-G] secondary reader null sample "
                  "(status=%ld). Marking secondary EOS. clipId=%@",
                  (long)_secondaryReader.status, secClip.clipId);
            return NO;
        }

        CVImageBufferRef secImageBuffer = CMSampleBufferGetImageBuffer(secSampleBuf);
        if (!secImageBuffer) {
            // Timing-only sample. Skip and continue.
            CFRelease(secSampleBuf);
            continue;
        }

        // Extract timing.
        CMTime rawSecPTS = CMSampleBufferGetPresentationTimeStamp(secSampleBuf);
        CMTime rawSecDur = CMSampleBufferGetDuration(secSampleBuf);

        double secSPTS = CMTIME_IS_VALID(rawSecPTS) ? CMTimeGetSeconds(rawSecPTS) : -1.0;
        double secSDur = (CMTIME_IS_VALID(rawSecDur) &&
                          !CMTIME_IS_INDEFINITE(rawSecDur) &&
                          CMTimeGetSeconds(rawSecDur) > 0.0)
                         ? CMTimeGetSeconds(rawSecDur)
                         : (1.0 / MAX(_secondarySourceFPS, 1.0));

        // Retain secondary pixel buffer (+1).
        CVPixelBufferRef secPixelBuffer = (CVPixelBufferRef)secImageBuffer;
        CVPixelBufferRetain(secPixelBuffer); // +1: node cache ref

        // Release previous cached secondary buffer.
        if (_secondaryLastBuffer) {
            CVPixelBufferRelease(_secondaryLastBuffer);
        }
        _secondaryLastBuffer        = secPixelBuffer; // node takes +1
        _secondaryLastSamplePTS      = secSPTS;
        _secondaryLastSampleDuration = secSDur;
        // Phase 7.x-N: update byte estimate atomically.
        {
            size_t bpr = CVPixelBufferGetBytesPerRow(_secondaryLastBuffer);
            size_t h   = CVPixelBufferGetHeight(_secondaryLastBuffer);
            atomic_store(&_secondaryLastBufferEstBytes, (uint64_t)(bpr * h));
        }

        CFRelease(secSampleBuf); // release CMSampleBufferRef +1

        // Generation guard post-decode.
        if (atomic_load(&_primaryGeneration) != currentGen) {
            CVPixelBufferRelease(_secondaryLastBuffer);
            _secondaryLastBuffer        = NULL;
            _secondaryLastSamplePTS      = -1.0;
            _secondaryLastSampleDuration = 0.0;
            return NO;
        }

        NSLog(@"[VGDualCameraCompositorNode][7.x-G] secondary decoded frame: "
              "secAssetTime=%.3fs samplePTS=%.3fs dur=%.3fs clipId=%@",
              secAssetTime, secSPTS, secSDur, secClip.clipId);

        // Check if window covers requested time or reader has advanced past it.
        BOOL secWindowCovers = (secSPTS >= 0.0 &&
                                secAssetTime >= secSPTS &&
                                secAssetTime <  secSPTS + secSDur);
        BOOL secPastRequest  = (secSPTS > secAssetTime);

        if (secWindowCovers || secPastRequest) {
            return YES; // Frame ready; no rendering — primary pass-through continues.
        }
        // Continue advancing.
    }

    // Fell out of the loop: iteration cap exceeded.
    NSLog(@"[VGDualCameraCompositorNode][7.x-G] secondary advance cap reached at "
          "secAssetTime=%.3fs after %ld iterations. clipId=%@",
          secAssetTime, (long)iterations, secClip.clipId);
    return YES; // Not an error; just stop advancing this frame.
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
    // Note: if primaryLastBuffer == primaryImageBuffer, both point to the same
    // underlying buffer. We release them separately; the ivar is set to NULL
    // after each release so there is no double-release risk.
    if (_primaryLastBuffer) {
        CVPixelBufferRelease(_primaryLastBuffer);
        _primaryLastBuffer = NULL;
    }

    // Phase 7.x-L: Release still-image buffer on reader clear / seek.
    // This forces a reload on the next pullFrame: after a seek, ensuring the
    // static buffer is regenerated cleanly.
    if (_primaryImageBuffer) {
        CVPixelBufferRelease(_primaryImageBuffer);
        _primaryImageBuffer = NULL;
    }
    _primaryImageLogged = NO;

    // Phase 7.x-H: Release composited buffer whenever primary resets.
    // Both readers are always cleared together on seek/invalidate, so clearing
    // here (rather than a separate helper) avoids delivering a stale composite
    // that mixes old primary and new secondary after a seek.
    if (_compositedLastBuffer) {
        CVPixelBufferRelease(_compositedLastBuffer);
        _compositedLastBuffer = NULL;
    }
}

// ─── Phase 7.x-G: Private — build secondary AVAssetReader ────────────────────────
//
// Identical structure to _buildPrimaryReaderStartingAtTime:error:.
// Builds an AVAssetReader + AVAssetReaderVideoCompositionOutput for _secondaryClip.
// timeRange must be set before -startReading (Apple contract).

- (BOOL)_buildSecondaryReaderStartingAtTime:(double)startTimeSecs
                                       error:(NSError **)outError {
    VGClipDescriptor *secClip = _secondaryClip;

    NSURL *assetURL = [NSURL fileURLWithPath:secClip.sourceURL];
    if (!assetURL) {
        if (outError) {
            *outError = [NSError errorWithDomain:VGDualCameraCompositorNodeErrorDomain
                                           code:3200
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:
                                               @"VGDualCameraCompositorNode[7.x-G]: "
                                                "invalid sourceURL for secondaryClip '%@': %@",
                                               secClip.clipId, secClip.sourceURL]}];
        }
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];

    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = tracks.firstObject;
    if (!videoTrack) {
        if (outError) {
            *outError = [NSError errorWithDomain:VGDualCameraCompositorNodeErrorDomain
                                           code:3201
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:
                                               @"VGDualCameraCompositorNode[7.x-G]: "
                                                "no video track for secondaryClip '%@' at %@",
                                               secClip.clipId, secClip.sourceURL]}];
        }
        return NO;
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
    if (!reader) {
        if (outError) *outError = readerError;
        return NO;
    }

    // Set timeRange before startReading (Apple requirement).
    CMTime assetStart    = CMTimeMakeWithSeconds(startTimeSecs,          600);
    CMTime assetEnd      = CMTimeMakeWithSeconds(secClip.trimEndSeconds, 600);
    CMTime assetDuration = asset.duration;

    if (CMTIME_IS_VALID(assetDuration) &&
        CMTimeCompare(assetStart, assetDuration) >= 0) {
        assetStart = assetDuration;
    }
    CMTime readEnd = assetEnd;
    if (CMTIME_IS_VALID(assetDuration) &&
        CMTimeCompare(assetEnd, assetDuration) > 0) {
        readEnd = assetDuration;
    }
    if (CMTimeCompare(assetStart, readEnd) < 0) {
        CMTime readDuration = CMTimeSubtract(readEnd, assetStart);
        reader.timeRange = CMTimeRangeMake(assetStart, readDuration);
    }

    // Phase 7.9-identical orientation normalization via AVMutableVideoComposition.
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

    // Both must be set before startReading (Apple contract).
    output.videoComposition       = videoComposition;
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        if (outError) {
            *outError = [NSError errorWithDomain:VGDualCameraCompositorNodeErrorDomain
                                           code:3202
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:
                                               @"VGDualCameraCompositorNode[7.x-G]: "
                                                "cannot add output for secondaryClip '%@'.",
                                               secClip.clipId]}];
        }
        return NO;
    }

    [reader addOutput:output];

    if (![reader startReading]) {
        if (outError) *outError = reader.error;
        return NO;
    }

    // Compute source FPS (mirrors primary build).
    double sourceFPS = 30.0;
    if (videoComposition &&
        CMTIME_IS_VALID(videoComposition.frameDuration) &&
        CMTimeGetSeconds(videoComposition.frameDuration) > 0.0) {
        sourceFPS = 1.0 / CMTimeGetSeconds(videoComposition.frameDuration);
    } else if (videoTrack.nominalFrameRate > 0.0f) {
        sourceFPS = (double)videoTrack.nominalFrameRate;
    }

    _secondaryReader             = reader;
    _secondaryOutput             = output;
    _secondarySourceFPS          = sourceFPS;
    _secondaryLastSamplePTS      = -1.0;
    _secondaryLastSampleDuration = 0.0;

    NSLog(@"[VGDualCameraCompositorNode][7.x-G] secondary reader built ok | "
          "clipId=%@ start=%.3fs end=%.3fs fps=%.1f",
          secClip.clipId, startTimeSecs, secClip.trimEndSeconds, sourceFPS);

    return YES;
}

// ─── Phase 7.x-G: Private — cancel and clear secondary reader ─────────────────────
//
// Cancels the active secondary AVAssetReader, nils reader and output references,
// resets sample-window cache fields, releases the retained secondary buffer,
// and resets _secondaryEOSReached so a fresh seek rebuilds cleanly.
// Idempotent: safe to call when reader is already nil.

- (void)_cancelAndClearSecondaryReader {
    AVAssetReader *reader = _secondaryReader;
    if (reader) {
        [reader cancelReading];
        _secondaryReader = nil;
        _secondaryOutput = nil;
    }

    _secondaryLastSamplePTS      = -1.0;
    _secondaryLastSampleDuration = 0.0;
    _secondarySourceFPS          = 30.0;
    _secondaryEOSReached         = NO;

    if (_secondaryLastBuffer) {
        CVPixelBufferRelease(_secondaryLastBuffer);
        _secondaryLastBuffer = NULL;
    }

    // Phase 7.x-L: Release still-image buffer and reset image state.
    if (_secondaryImageBuffer) {
        CVPixelBufferRelease(_secondaryImageBuffer);
        _secondaryImageBuffer = NULL;
    }
    _secondaryIsImage     = NO;
    _secondaryImageLogged = NO;
}

// ─── Phase 7.x-N: DEV telemetry ──────────────────────────────────────────────

- (NSDictionary<NSString *, NSNumber *> *)devGetTelemetry {
    // All reads are atomic — safe to call from any thread (e.g. the main thread
    // serving a MethodChannel call) without locking.

    // ── Core counters ────────────────────────────────────────────────────────
    uint64_t pulls         = atomic_load(&_primaryPullCount);
    uint64_t primDecodes   = atomic_load(&_primaryDecodeCount);   // Phase 7.x-P: primary reader only
    uint64_t secDecodes    = atomic_load(&_secondaryDecodeCount); // Phase 7.x-P: secondary reader only
    uint64_t composites    = atomic_load(&_compositedFrameCount);
    uint64_t primBytes     = atomic_load(&_primaryLastBufferEstBytes);
    uint64_t secBytes      = atomic_load(&_secondaryLastBufferEstBytes);

    // ── Phase 7.x-N (patch) counters ────────────────────────────────────────
    uint64_t pipCount        = atomic_load(&_pipCompositionCount);
    uint64_t splitCount      = atomic_load(&_splitScreenCompositionCount);
    uint64_t failCount       = atomic_load(&_compositionFailureCount);
    uint64_t fallbackCount   = atomic_load(&_fallbackToPrimaryCount);
    uint64_t imgBuildCount   = atomic_load(&_imageBufferBuildCount);
    uint64_t outBufCount     = atomic_load(&_outputBufferCreateCount);

    // ── Timing (nanoseconds → milliseconds) ─────────────────────────────────
    // Phase 7.x-P: _firstFrameLatencyNs is a true elapsed-time latency
    //   (from pullFrame: entry to first successful delivered frame), not an
    //   absolute wall-clock timestamp. 0 = not yet measured.
    uint64_t firstLatencyNs  = atomic_load(&_firstFrameLatencyNs);
    uint64_t lastPullNs      = atomic_load(&_lastPullFrameNs);
    uint64_t maxPullNs       = atomic_load(&_maxPullFrameNs);
    uint64_t totalPullNs     = atomic_load(&_totalPullFrameNs);
    uint64_t timedCount      = atomic_load(&_pullTimedCallCount);

    // Convert ns → ms.
    double firstFrameLatencyMs = (firstLatencyNs > 0) ? (double)firstLatencyNs / 1.0e6 : 0.0;
    double lastPullMs          = (double)lastPullNs  / 1.0e6;
    double maxPullMs           = (double)maxPullNs   / 1.0e6;
    double avgPullMs           = (timedCount > 0) ? ((double)totalPullNs / (double)timedCount / 1.0e6) : 0.0;

    // ── Derived: estimated retained buffer bytes ─────────────────────────────
    uint64_t retainedBytes = primBytes + secBytes;
    double   retainedMB    = (double)retainedBytes / (1024.0 * 1024.0);

    // ── Derived: successful output frames ────────────────────────────────────
    // "successfulFrameCount" means pullFrame: returned a delivered (non-skipped) result.
    // We track this via timedCount (every delivery site records timing).
    uint64_t successfulFrames = timedCount;

    return @{
        // Core pull counters (compatible with Phase 7.x-N original keys).
        @"pullFrameCallCount"         : @(pulls),
        @"primaryPullCount"           : @(pulls),           // alias for backward compat
        // Phase 7.x-P: split decode counters — primary reader vs secondary reader.
        @"primaryDecodeCount"         : @(primDecodes),
        @"secondaryDecodeCount"       : @(secDecodes),
        @"successfulFrameCount"       : @(successfulFrames),
        // Composition counters.
        @"compositedFrameCount"       : @(composites),
        @"pipCompositionCount"        : @(pipCount),
        @"splitScreenCompositionCount": @(splitCount),
        @"compositionFailureCount"    : @(failCount),
        @"fallbackToPrimaryCount"     : @(fallbackCount),
        // Image / output buffer build counters.
        @"imageBufferBuildCount"      : @(imgBuildCount),
        @"outputBufferCreateCount"    : @(outBufCount),
        // Buffer byte estimates.
        @"primaryBufferEstBytes"      : @(primBytes),
        @"secondaryBufferEstBytes"    : @(secBytes),
        @"estimatedRetainedBufferBytes" : @(retainedBytes),
        // Timing (double ms, stored as NSNumber doubleValue).
        // Dart side reads as (v as num).toDouble().
        // Phase 7.x-P: firstFrameLatencyMs = true elapsed latency from pullFrame: entry
        //   to first successful frame delivery. 0 = not yet measured.
        //   Replaces the former absolute-timestamp firstFrameMs key.
        @"firstFrameLatencyMs"        : @(firstFrameLatencyMs),
        @"lastPullFrameMs"            : @(lastPullMs),
        @"maxPullFrameMs"             : @(maxPullMs),
        @"averagePullFrameMs"         : @(avgPullMs),
        @"estimatedRetainedBufferMB"  : @(retainedMB),
    };
}

- (void)devResetTelemetry {
    // Core counters.
    atomic_store(&_primaryPullCount,            0);
    atomic_store(&_primaryDecodeCount,          0);
    atomic_store(&_secondaryDecodeCount,        0); // Phase 7.x-P
    atomic_store(&_compositedFrameCount,        0);
    atomic_store(&_primaryLastBufferEstBytes,   0);
    atomic_store(&_secondaryLastBufferEstBytes, 0);
    // Phase 7.x-N (patch): composition / fallback / image / output buffer counters.
    atomic_store(&_pipCompositionCount,         0);
    atomic_store(&_splitScreenCompositionCount, 0);
    atomic_store(&_compositionFailureCount,     0);
    atomic_store(&_fallbackToPrimaryCount,      0);
    atomic_store(&_imageBufferBuildCount,       0);
    atomic_store(&_outputBufferCreateCount,     0);
    // Phase 7.x-N / 7.x-P: timing — zero all and re-arm first-frame latency capture.
    atomic_store(&_firstFrameLatencyNs,         0); // Phase 7.x-P: re-arm on next delivery
    atomic_store(&_lastPullFrameNs,             0);
    atomic_store(&_maxPullFrameNs,              0);
    atomic_store(&_totalPullFrameNs,            0);
    atomic_store(&_pullTimedCallCount,          0);
    NSLog(@"[VGDualCameraCompositorNode][7.x-P] devResetTelemetry: all counters and timing zeroed.");
}

@end
