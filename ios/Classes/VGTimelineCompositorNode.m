// VGTimelineCompositorNode.m
// vanguard_media_engine — Phase 7 Stage 7.5 / Stage 7.10 / Stage 7.12 / Stage 7.16 / Stage 7.18A
//
// Phase 7 Stage 7.5:  First executable multi-clip video timeline compositor.
// Phase 7 Stage 7.10: Native crossfade/dissolve and fade transition execution.
// Phase 7 Stage 7.12: Still-image clip support via ImageIO decode + static buffer cache.
// Phase 7 Stage 7.16: Still-image fit/fill/crop controls (DEC-148).
// Phase 7 Stage 7.18A: Internal byte-budgeted frame cache + best-effort freeze prefetch (DEC-151).
//
// ═══════════════════════════════════════════════════════════════════════════════
// DESIGN OVERVIEW
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGTimelineCompositorNode is a self-sourcing pull producer. It holds an array
// of VGClipDescriptor objects and, on each pullFrame:, maps the requested
// global timeline PTS to the active clip's asset-local decode time, then
// retrieves a frame from that clip's AVAssetReader.
//
// Timeline PTS mapping (§6.11 / Gemini Stage 7.5 timing model):
//
//   For global PTS T and active clip starting at T_clip_start:
//     elapsed_timeline   = T - T_clip_start
//     elapsed_asset      = elapsed_timeline * clip.speed
//     t_asset            = clip.trimStartSeconds + elapsed_asset
//     t_asset            = clamp(t_asset, clip.trimStartSeconds,
//     clip.trimEndSeconds)
//
// Clip selection:
//   A clip is active for T when:
//     T >= clip.startTimeSeconds
//     T <  clip.startTimeSeconds + clip.timelineDuration
//   (end is exclusive; final clip is inclusive at exact end to guard EOS)
//
// Multi-clip sequencing:
//   Each clip has its own AVAssetReader, built lazily on first access and
//   rebuilt on seek. When the requested PTS falls in a different clip than the
//   last-decoded clip, the previous reader is cancelled and the new clip's
//   reader is rebuilt.
//
// ── APPLE FRAMEWORK CHECKS ───────────────────────────────────────────────────
//
// AVAssetReader:
//   - Forward-only: cannot seek mid-stream. Must cancel + recreate on seek.
//   - startReading must be called before copyNextSampleBuffer.
//   - timeRange set BEFORE startReading (not after).
//   - On copyNextSampleBuffer returning NULL: check reader.status for
//     AVAssetReaderStatusCompleted (EOS) or AVAssetReaderStatusFailed (error).
//
// CMSampleBuffer (copyNextSampleBuffer):
//   - Returns +1 CMSampleBufferRef. Caller MUST CFRelease.
//
// CMSampleBufferGetImageBuffer:
//   - Returns +0 CVImageBufferRef. Caller MUST CVPixelBufferRetain if storing.
//
// CVPixelBuffer ownership (RR-36):
//   - _lastDeliveredBuffer: retained +1 by this node.
//   - Released before each new pullFrame: decode.
//   - Released on seek and invalidate.
//   - VGFrameEnvelope.payload.videoBuffer carries +0 per VGFrameEnvelope.h.
//
// Generation atomics:
//   - _generation: updated atomically via atomic_store.
//   - seekTo:generation: atomically stores new generation before rebuilding
//   reader.
//   - pullFrame: captures generation at start; checks request.generation
//   against
//     _generation. Returns .skipped on mismatch.
//
// ── STAGE 7.5 LIMITATIONS (DOCUMENTED — partially resolved in Phase 7.10/7.12) ─
//
//   Image clips:       Phase 7.12: SUPPORTED via ImageIO decode + static buffer
//                      cache in _VGClipReader (DEC-145). AVAssetReader = nil for
//                      image clips. Still-image buffer cached on first pull.
//   Audio clips:       Rejected at init. Returns nil with error.
//   Fade/dissolve:     Phase 7.10: SUPPORTED via dual-reader CoreImage blend path
//                      (DEC-143). Hard-cut (VGTransitionTypeNone) also supported.
//   GPU blending:      Uses CoreImage Metal/GPU path (_VGTCNBlendBuffers). RR-143.
//   Pre-warming:       Not implemented. Performance optimization deferred.
//   Audio sidecar:     Phase 8+.
//
// ── PHASE 7.9 ORIENTATION NORMALIZATION ──────────────────────────────────────
//
// As of Phase 7.9, _buildReaderForClipIndex:startAtTime:error: uses
// AVAssetReaderVideoCompositionOutput + AVMutableVideoComposition instead of
// AVAssetReaderTrackOutput. This applies the track's preferredTransform at
// decode time, producing orientation-normalized pixel buffers for both the
// playback and export paths (both use VGTimelineCompositorNode).
//
// Two-domain orientation policy (DEC-142, DEC-141, DEC-132, RR-141):
//   Camera-produced clips (DEC-132): identity preferredTransform; composition
//     is a no-op. No double rotation.
//   Imported/user-supplied clips (RR-141): may carry 90°/270° transform;
//     composition normalizes them to correct orientation at decode time.
//
// Do NOT add manual CPU/Metal/GPU rotation code on top of this path.
//
// ═══════════════════════════════════════════════════════════════════════════════

#import "VGTimelineCompositorNode.h"

// ─── Descriptor models (UMF Stage 7.1) ───────────────────────────────────────
#import "VGClipDescriptor.h"
#import "VGTransitionDescriptor.h"
// Phase 7.23B (DEC-167): native keyframe transform descriptor + interpolation.
#import <UMF/VGTransformTrackDescriptor.h>

// ─── UMF protocol / type imports ─────────────────────────────────────────────
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGNode.h>
#import <UMF/VGRenderMode.h>
#import <UMF/VGSourceNode.h>

// ─── AVFoundation
// ─────────────────────────────────────────────────────────────
#import <AVFoundation/AVFoundation.h>

// ─── CoreVideo / CoreMedia
// ────────────────────────────────────────────────────
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

// ─── Phase 7.12: ImageIO for still-image decode ───────────────────────────────
#import <ImageIO/ImageIO.h>

// ─── Phase 7.20C: Reverse sidecar manager (preview reader swap) ──────────────
#import "VGReverseSidecarManager.h"

// ─── System
// ───────────────────────────────────────────────────────────────────
#import <os/log.h>
#include <stdatomic.h>

// ─── Error domain
// ─────────────────────────────────────────────────────────────
NSString *const VGTimelineCompositorNodeErrorDomain =
    @"VGTimelineCompositorNode";

// ─── Descriptor stage keys
// ────────────────────────────────────────────────────
static NSString *const kVGTCNDescriptorStageKey = @"descriptorStage";
static NSString *const kVGTCNDescriptorStage75 = @"7.5_executable";
static NSString *const kVGTCNDescriptorStage74 = @"7.4_non_executable";
static NSString *const kVGTCNClipsKey = @"clips";
static NSString *const kVGTCNTransitionsKey = @"transitions";
// Phase 7.x-Q1: dual-camera descriptor key embedded per clip dict.
// Presence indicates this clip is a dual-camera composite (primary = enclosing
// clip; secondary + layout = this nested map). Q1: detected and logged only.
// Q2: secondary reader will be built from this dict.
static NSString *const kVGTCNDualCameraKey = @"dualCamera";

// ─── Canvas dimension keys (Phase 7.9 aspect-fit normalization) ────────────────────────────────────────────────────────
// When present and non-zero, the compositor overrides
// AVMutableVideoComposition.renderSize and applies an aspect-fit affine
// transform via AVMutableVideoCompositionLayerInstruction so that decoded
// frames are mapped into the target canvas rectangle (letterbox/pillarbox).
// When absent or zero, the compositor falls back to the legacy behavior of
// forwarding the asset's native display-size buffers unchanged.
static NSString *const kVGTCNCanvasWidthKey = @"canvasWidth";
static NSString *const kVGTCNCanvasHeightKey = @"canvasHeight";

// ─── Output settings for AVAssetReaderVideoCompositionOutput ─────────────────
// Match VGExportFileSourceNode output settings: 32BGRA + Metal + IOSurface.
// Same pixel format as the playback path (VanguardFileMediaSource) for
// downstream renderer compatibility.
static NSDictionary *_VGTCNOutputSettings(void) {
  return @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
}

// ─── Private error factory
// ────────────────────────────────────────────────────
static NSError *_VGTCNError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:VGTimelineCompositorNodeErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

// ─── Phase 7.10: CoreImage blend helpers ─────────────────────────────────────
//
// _VGTCNSharedCIContext: Lazily initialised Metal/GPU CIContext.
// Thread-safe via dispatch_once; the pull queue is serial.
//
// _VGTCNBlendBuffers: Per-frame CoreImage blend of two CVPixelBuffers.
//   VGTransitionTypeDissolve: linear alpha cross-fade (CIDissolveTransition).
//     alpha 0.0 → outgoing only.  alpha 1.0 → incoming only.
//   VGTransitionTypeFade: two-phase fade through black.
//     alpha [0.0, 0.5) → outgoing fades to black.
//     alpha [0.5, 1.0] → incoming fades in from black.
// Returns new retained CVPixelBufferRef (+1). Caller must CVPixelBufferRelease.
// Returns NULL with *outError on failure; no silent masking (DEC-143).
//
// RR-143: CIContext uses nil options (Metal/GPU on device; CPU fallback in sim).
// RR-144: CIDissolveTransition interpolates in gamma-encoded RGB space, not
//   linear-light. Perceptual blending accuracy is a deferred improvement.

static CIContext *_VGTCNSharedCIContext(void) {
  static CIContext *ctx = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ctx = [CIContext contextWithOptions:nil];
  });
  return ctx;
}

static CVPixelBufferRef _VGTCNBlendBuffers(CVPixelBufferRef outgoing,
                                            CVPixelBufferRef incoming,
                                            VGTransitionType type,
                                            float alpha,
                                            NSError **outError) {
  CIImage *outCI = [CIImage imageWithCVPixelBuffer:outgoing];
  CIImage *inCI  = [CIImage imageWithCVPixelBuffer:incoming];
  CIImage *blendedCI = nil;

  if (type == VGTransitionTypeDissolve) {
    // Cross-dissolve: outgoing ---(alpha)---> incoming.
    CIFilter *f = [CIFilter filterWithName:@"CIDissolveTransition"];
    [f setValue:outCI    forKey:kCIInputImageKey];
    [f setValue:inCI     forKey:@"inputTargetImage"];
    [f setValue:@(alpha) forKey:kCIInputTimeKey];
    blendedCI = f.outputImage;
  } else if (type == VGTransitionTypeFade) {
    // Two-phase fade through black.
    CIImage *black =
        [CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]];
    if (alpha < 0.5f) {
      float t = alpha * 2.0f; // 0→1 across first half
      CIFilter *f = [CIFilter filterWithName:@"CIDissolveTransition"];
      [f setValue:outCI forKey:kCIInputImageKey];
      [f setValue:black forKey:@"inputTargetImage"];
      [f setValue:@(t)  forKey:kCIInputTimeKey];
      blendedCI = f.outputImage;
    } else {
      float t = (alpha - 0.5f) * 2.0f; // 0→1 across second half
      CIFilter *f = [CIFilter filterWithName:@"CIDissolveTransition"];
      [f setValue:black forKey:kCIInputImageKey];
      [f setValue:inCI  forKey:@"inputTargetImage"];
      [f setValue:@(t)  forKey:kCIInputTimeKey];
      blendedCI = f.outputImage;
    }
  }

  if (!blendedCI) {
    if (outError) {
      *outError = _VGTCNError(
          15, @"VGTimelineCompositorNode: CoreImage blend produced no output "
               "image. Unsupported transition type or CIContext unavailable.");
    }
    return NULL;
  }

  size_t w = CVPixelBufferGetWidth(incoming);
  size_t h = CVPixelBufferGetHeight(incoming);
  NSDictionary *attrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey  : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };

  CVPixelBufferRef out = NULL;
  CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &out);
  if (ret != kCVReturnSuccess || !out) {
    if (outError) {
      *outError = _VGTCNError(
          15, @"VGTimelineCompositorNode: CVPixelBufferCreate failed for "
               "transition blend output buffer.");
    }
    return NULL;
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  [_VGTCNSharedCIContext() render:blendedCI
                    toCVPixelBuffer:out
                              bounds:blendedCI.extent
                          colorSpace:cs];
  CGColorSpaceRelease(cs);

  return out; // Caller owns +1 from CVPixelBufferCreate
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 7.x-Q3B: Dual-camera layout types, parsers, and composition helpers
// ─────────────────────────────────────────────────────────────────────────────
//
// Private layout structs mirror VGDualCameraCompositorNode.h public types but
// are named _VGTCN-prefixed to stay local to this translation unit.
// VGDualCameraCompositorNode.h is NOT imported here.
//
// Layout config is parsed ONCE per clip during init from _dualCameraDescDicts
// and stored in _dualCameraLayoutConfigs. pullFrame: reads the parsed value
// for the active clip index — zero dict-parsing overhead per frame.

/// Layout mode tag for dual-camera composition in the timeline path.
typedef NS_ENUM(NSInteger, _VGTCNDualCameraLayoutMode) {
    _VGTCNDualCameraLayoutModePiP         = 0,
    _VGTCNDualCameraLayoutModeSplitScreen = 1,
};

/// PiP anchor corner. Wire values mirror Dart VGPiPAnchor.
typedef NS_ENUM(NSInteger, _VGTCNPiPAnchor) {
    _VGTCNPiPAnchorTopLeft     = 0,
    _VGTCNPiPAnchorTopRight    = 1,
    _VGTCNPiPAnchorBottomLeft  = 2,
    _VGTCNPiPAnchorBottomRight = 3, ///< Default.
};

/// Parsed PiP layout config. Stored per clip at init time.
typedef struct {
    _VGTCNPiPAnchor anchor;
    double           widthFraction;  ///< 0.05–0.75
    double           marginFraction; ///< >= 0.0
    double           cornerRadius;   ///< >= 0.0
    double           opacity;        ///< 0.0–1.0
    /// Phase 7.x-Q3D: Display dimensions of the primary source video after
    /// preferredTransform rotation. Set at reader build time so the PiP
    /// compositor can compute the visible content rect inside the canvas.
    /// CGSizeZero when unknown / no aspect-fit normalization is active.
    CGSize primarySourceSize;
    /// Phase 7.x-Q3E: Display dimensions of the secondary source video after
    /// preferredTransform rotation. Set at secondary reader build time so the
    /// PiP compositor can aspect-fill the secondary content into the PiP rect
    /// (removing black bars introduced by the secondary's canvas aspect-fit).
    /// CGSizeZero when unknown / no canvas normalization active.
    CGSize secondarySourceSize;
} _VGTCNPiPLayoutConfig;

/// Parsed split-screen layout config. Stored per clip at init time.
typedef struct {
    double splitRatio; ///< 0.2–0.8; primary (top) fraction of canvas height.
} _VGTCNSplitScreenLayoutConfig;

/// Tagged layout config union — carries mode + relevant sub-config.
/// Stored as NSValue-wrapped bytes in _dualCameraLayoutConfigs.
typedef struct {
    _VGTCNDualCameraLayoutMode mode;
    _VGTCNPiPLayoutConfig      pip;   ///< Valid when mode == PiP.
    _VGTCNSplitScreenLayoutConfig split; ///< Valid when mode == SplitScreen.
    BOOL enabled; ///< NO if clip has no dualCamera descriptor.
} _VGTCNDualCameraLayoutConfig;

// ── Wire-key constants (mirror Dart VGDualCameraDescriptor.toTimelineMap) ────
static NSString * const kVGTCNQLModeKey        = @"layoutMode";
static NSString * const kVGTCNQPiPLayoutKey    = @"pipLayout";
static NSString * const kVGTCNQSplitLayoutKey  = @"splitLayout";
static NSString * const kVGTCNQPiPAnchorKey    = @"anchor";
static NSString * const kVGTCNQPiPWidthFracKey = @"widthFraction";
static NSString * const kVGTCNQPiPMarginFracKey= @"marginFraction";
static NSString * const kVGTCNQPiPCornerRadKey = @"cornerRadius";
static NSString * const kVGTCNQPiPOpacityKey   = @"opacity";
static NSString * const kVGTCNQSplitRatioKey   = @"splitRatio";

/// Parse PiP anchor from wire string; falls back to BottomRight.
static _VGTCNPiPAnchor _VGTCNParsePiPAnchor(NSString * _Nullable str) {
    if ([str isEqualToString:@"topLeft"])    return _VGTCNPiPAnchorTopLeft;
    if ([str isEqualToString:@"topRight"])   return _VGTCNPiPAnchorTopRight;
    if ([str isEqualToString:@"bottomLeft"]) return _VGTCNPiPAnchorBottomLeft;
    return _VGTCNPiPAnchorBottomRight;
}

/// Parse PiP layout config from Dart-side pipLayout dict.
/// Absent/invalid keys fall back to Dart VGPiPLayoutDescriptor defaults.
static _VGTCNPiPLayoutConfig _VGTCNParsePiPLayout(NSDictionary * _Nullable dict) {
    _VGTCNPiPLayoutConfig cfg;
    cfg.anchor         = _VGTCNPiPAnchorBottomRight;
    cfg.widthFraction  = 0.35;
    cfg.marginFraction = 0.018;
    cfg.cornerRadius   = 24.0;
    cfg.opacity        = 1.0;
    if (!dict || ![dict isKindOfClass:[NSDictionary class]]) return cfg;

    NSString *anchorStr = dict[kVGTCNQPiPAnchorKey];
    if ([anchorStr isKindOfClass:[NSString class]])
        cfg.anchor = _VGTCNParsePiPAnchor(anchorStr);

    NSNumber *wf = dict[kVGTCNQPiPWidthFracKey];
    if ([wf isKindOfClass:[NSNumber class]] && wf.doubleValue >= 0.05 && wf.doubleValue <= 0.75)
        cfg.widthFraction = wf.doubleValue;

    NSNumber *mf = dict[kVGTCNQPiPMarginFracKey];
    if ([mf isKindOfClass:[NSNumber class]] && mf.doubleValue >= 0.0)
        cfg.marginFraction = mf.doubleValue;

    NSNumber *cr = dict[kVGTCNQPiPCornerRadKey];
    if ([cr isKindOfClass:[NSNumber class]] && cr.doubleValue >= 0.0)
        cfg.cornerRadius = cr.doubleValue;

    NSNumber *op = dict[kVGTCNQPiPOpacityKey];
    if ([op isKindOfClass:[NSNumber class]] && op.doubleValue >= 0.0 && op.doubleValue <= 1.0)
        cfg.opacity = op.doubleValue;

    return cfg;
}

/// Parse split-screen layout config from Dart-side splitLayout dict.
/// Absent/invalid keys fall back to splitRatio=0.5.
static _VGTCNSplitScreenLayoutConfig _VGTCNParseSplitLayout(NSDictionary * _Nullable dict) {
    _VGTCNSplitScreenLayoutConfig cfg;
    cfg.splitRatio = 0.5;
    if (!dict || ![dict isKindOfClass:[NSDictionary class]]) return cfg;
    NSNumber *sr = dict[kVGTCNQSplitRatioKey];
    if ([sr isKindOfClass:[NSNumber class]] && sr.doubleValue >= 0.2 && sr.doubleValue <= 0.8)
        cfg.splitRatio = sr.doubleValue;
    return cfg;
}

/// Parse a full dual-camera layout config from a raw dualCamera timeline dict.
/// Returns a disabled config if dict is nil/NSNull.
static _VGTCNDualCameraLayoutConfig _VGTCNParseLayoutConfig(id rawDualCameraDict) {
    _VGTCNDualCameraLayoutConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.enabled = NO;

    if (!rawDualCameraDict || [rawDualCameraDict isKindOfClass:[NSNull class]]
        || ![rawDualCameraDict isKindOfClass:[NSDictionary class]]) {
        return cfg;
    }
    NSDictionary *dict = (NSDictionary *)rawDualCameraDict;
    cfg.enabled = YES;

    NSString *modeStr = dict[kVGTCNQLModeKey];
    if ([modeStr isEqualToString:@"splitScreen"]) {
        cfg.mode  = _VGTCNDualCameraLayoutModeSplitScreen;
        cfg.split = _VGTCNParseSplitLayout(dict[kVGTCNQSplitLayoutKey]);
    } else {
        // Default to PiP for "pip" or any unrecognised value.
        cfg.mode = _VGTCNDualCameraLayoutModePiP;
        cfg.pip  = _VGTCNParsePiPLayout(dict[kVGTCNQPiPLayoutKey]);
    }
    return cfg;
}

// ── Phase 7.x-Q3D: Visible primary content rect helper ──────────────────────
//
// Computes the CGRect within a canvas of canvasSize that contains the visible
// aspect-fit content from a source of sourceSize.
// Mirrors the aspect-fit logic in _buildReaderForClipIndex: (AVComposition
// instruction). Returned rect is in CoreImage Y-up coordinates (Y=0 at bottom).
//
// When sourceSize is degenerate (zero width or height), falls back to the full
// canvas rect so PiP placement degrades gracefully rather than crashing.
static CGRect _VGTCNAspectFitRect(CGSize sourceSize, CGSize canvasSize) {
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0
        || canvasSize.width <= 0.0 || canvasSize.height <= 0.0) {
        // Degenerate: fall back to full canvas.
        return CGRectMake(0.0, 0.0, canvasSize.width, canvasSize.height);
    }
    double scale = MIN(canvasSize.width  / sourceSize.width,
                       canvasSize.height / sourceSize.height);
    double visW = sourceSize.width  * scale;
    double visH = sourceSize.height * scale;
    double x    = (canvasSize.width  - visW) * 0.5;
    double y    = (canvasSize.height - visH) * 0.5; // Y-up: lower origin = bottom letterbox
    return CGRectMake(x, y, visW, visH);
}

// ── Phase 7.x-Q3B: Canvas-authority CVPixelBuffer allocator ─────────────────
// Creates a BGRA + Metal + IOSurface buffer at _targetRenderSize.
// Returns NULL if targetSize is degenerate.
static CVPixelBufferRef _VGTCNCreateCanvasBuffer(CGSize targetSize) {
    if (targetSize.width <= 0.0 || targetSize.height <= 0.0) return NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey    : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef buf = NULL;
    CVReturn ret = CVPixelBufferCreate(
        kCFAllocatorDefault,
        (size_t)targetSize.width,
        (size_t)targetSize.height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &buf);
    return (ret == kCVReturnSuccess) ? buf : NULL;
}

// ── Phase 7.x-Q3B: PiP composition helper ───────────────────────────────────
//
// Composites secondaryBuf as a PiP inset over primaryBuf using pip config.
// Canvas authority: output is allocated at canvasSize, NOT at primaryBuf size.
// Returns new CVPixelBufferRef +1 (caller owns). Returns NULL on any failure.
//
// Port of VGDualCameraCompositorNode._compositeWithPrimary:secondary:
static CVPixelBufferRef _VGTCNCompositePiP(
        CVPixelBufferRef primaryBuf,
        CVPixelBufferRef secondaryBuf,
        _VGTCNPiPLayoutConfig pip,
        CGSize canvasSize) {
    if (!primaryBuf || !secondaryBuf) return NULL;

    size_t primW = CVPixelBufferGetWidth(primaryBuf);
    size_t primH = CVPixelBufferGetHeight(primaryBuf);
    size_t secW  = CVPixelBufferGetWidth(secondaryBuf);
    size_t secH  = CVPixelBufferGetHeight(secondaryBuf);

    if (primW == 0 || primH == 0 || secW == 0 || secH == 0) {
        os_log_error(OS_LOG_DEFAULT,
                     "[VGTCNode-Q3B] PiP: degenerate buffer dimensions "
                     "prim=%zux%zu sec=%zux%zu — skipping.", primW, primH, secW, secH);
        return NULL;
    }

    // Phase 7.x-Q3D: Compute the visible primary content rect.
    // When _targetRenderSize != primaryBuf dimensions OR when primarySourceSize
    // is known, the primary pixel buffer contains letterbox/pillarbox black bars
    // from AVComposition aspect-fit. PiP must be placed relative to the visible
    // content area, not the full canvas.
    //
    // primarySourceSize carries the display dimensions captured at reader build
    // time. When zero (legacy/no aspect-fit), fall back to full primW x primH.
    CGRect visiblePrimRect;
    if (pip.primarySourceSize.width > 0.0 && pip.primarySourceSize.height > 0.0) {
        visiblePrimRect = _VGTCNAspectFitRect(
            pip.primarySourceSize,
            CGSizeMake((double)primW, (double)primH));
    } else {
        // No source size known: treat entire primary buffer as visible.
        visiblePrimRect = CGRectMake(0.0, 0.0, (double)primW, (double)primH);
    }
    double refW = CGRectGetWidth(visiblePrimRect);
    double refH = CGRectGetHeight(visiblePrimRect);
    double refX = CGRectGetMinX(visiblePrimRect);
    double refY = CGRectGetMinY(visiblePrimRect);

    // PiP geometry — widthFraction and margin are fractions of visible primary width.
    double wf = pip.widthFraction;
    double mf = pip.marginFraction;
    if (wf < 0.01) { wf = 0.01; }
    if (wf > 0.95) { wf = 0.95; }

    // Phase 7.x-Q3E (surgical): Compute visible secondary content rect BEFORE
    // deriving pipH. The secondary pixel buffer is aspect-fit into the full
    // canvas by AVComposition, so secW/secH = canvas dimensions (e.g. 1920x1080
    // landscape), not the true secondary content size (e.g. portrait 1080x1920).
    // Using secH/secW for pipH would produce a landscape PiP box, which then
    // forces aspect-fill to aggressively crop portrait content to fill it.
    // Using visSecH/visSecW for pipH makes the PiP box match the actual content.
    CGRect visSecRect;
    if (pip.secondarySourceSize.width > 0.0 && pip.secondarySourceSize.height > 0.0) {
        visSecRect = _VGTCNAspectFitRect(
            pip.secondarySourceSize,
            CGSizeMake((double)secW, (double)secH));
    } else {
        // secondarySourceSize not known: use full buffer (may include black bars,
        // but at least fallback preserves prior behavior without crash).
        visSecRect = CGRectMake(0.0, 0.0, (double)secW, (double)secH);
    }
    double visSecW = CGRectGetWidth(visSecRect);
    double visSecH = CGRectGetHeight(visSecRect);
    // Safety clamp: avoid division-by-zero if rect is degenerate.
    if (visSecW <= 0.0 || visSecH <= 0.0) {
        visSecW = (double)secW;
        visSecH = (double)secH;
        visSecRect = CGRectMake(0.0, 0.0, visSecW, visSecH);
    }

    double pipW  = refW * wf;
    // Use visible secondary aspect ratio, not canvas aspect ratio.
    double pipH  = (visSecH > 0.0 && visSecW > 0.0) ? pipW * visSecH / visSecW : pipW;
    double margin = refW * mf;

    // Clamp pipW so PiP fits within visible primary bounds.
    double maxPipW = refW - 2.0 * margin;
    if (maxPipW < 1.0) { maxPipW = 1.0; margin = 0.0; }
    if (pipW > maxPipW) { pipW = maxPipW; }
    // Recompute pipH after pipW clamp — use visible secondary aspect ratio.
    if (visSecW > 0.0) { pipH = pipW * visSecH / visSecW; }
    if (pipH < 1.0) { pipH = 1.0; }
    double maxPipH = refH - 2.0 * margin;
    if (maxPipH < 1.0) { maxPipH = 1.0; }
    if (pipH > maxPipH) {
        pipH = maxPipH;
        // Preserve visible secondary aspect ratio: scale pipW proportionally.
        if (visSecH > 0.0) { pipW = pipH * visSecW / visSecH; }
    }

    // Anchor → CIImage Y-up origin (Y=0 at bottom-left).
    // Origins are relative to the visible primary content rect, not the full canvas.
    double pipOriginX = 0.0, pipOriginY = 0.0;
    switch (pip.anchor) {
        case _VGTCNPiPAnchorTopLeft:
            pipOriginX = refX + margin;
            pipOriginY = refY + refH - pipH - margin;
            break;
        case _VGTCNPiPAnchorTopRight:
            pipOriginX = refX + refW - pipW - margin;
            pipOriginY = refY + refH - pipH - margin;
            break;
        case _VGTCNPiPAnchorBottomLeft:
            pipOriginX = refX + margin;
            pipOriginY = refY + margin;
            break;
        case _VGTCNPiPAnchorBottomRight:
        default:
            pipOriginX = refX + refW - pipW - margin;
            pipOriginY = refY + margin;
            break;
    }
    // Clamp origin to keep PiP fully inside visible primary rect.
    if (pipOriginX < refX) { pipOriginX = refX; }
    if (pipOriginY < refY) { pipOriginY = refY; }
    if (pipOriginX + pipW > refX + refW) { pipOriginX = refX + refW - pipW; }
    if (pipOriginY + pipH > refY + refH) { pipOriginY = refY + refH - pipH; }

    // Build CIImages.
    CIImage *primaryCI   = [CIImage imageWithCVPixelBuffer:primaryBuf];
    CIImage *secondaryCI = [CIImage imageWithCVPixelBuffer:secondaryBuf];
    if (!primaryCI || !secondaryCI) return NULL;

    // Phase 7.x-Q3E: Aspect-fill secondary into PiP rect with center-crop.
    //
    // The secondary pixel buffer is aspect-fit into the full canvas by AVComposition,
    // producing letterbox/pillarbox black bars. visSecRect (computed above) bounds
    // the visible content. We crop it out, then aspect-fill into the PiP rect.
    //
    // Because pipW/pipH now matches visSecW/visSecH aspect ratio, fillScale using
    // MAX() will be essentially uniform (equal in both axes), eliminating severe
    // crop while still ensuring no black padding at the PiP edges.
    //
    // Pipeline:
    //   1. Normalize secondary CIImage origin to {0,0}.
    //   2. Crop to visSecRect (strips black bars).
    //   3. Normalize cropped origin to {0,0}.
    //   4. Aspect-fill scale: MAX(pipW/visSecW, pipH/visSecH).
    //   5. Scale uniformly.
    //   6. Center-translate over PiP rect.
    //   7. Crop to pipFinalRect (removes any sub-pixel overflow).
    CGRect pipFinalRect = CGRectMake(pipOriginX, pipOriginY, pipW, pipH);

    CIImage *secNorm = secondaryCI;
    CGPoint secOrigin = secNorm.extent.origin;
    if (secOrigin.x != 0.0 || secOrigin.y != 0.0) {
        secNorm = [secNorm imageByApplyingTransform:
                   CGAffineTransformMakeTranslation(-secOrigin.x, -secOrigin.y)];
    }

    // Crop to visible secondary content, removing black bar regions.
    CIImage *secContent = [secNorm imageByCroppingToRect:visSecRect];
    // Normalize cropped origin to {0,0} so scale/translate below use a simple origin.
    if (visSecRect.origin.x != 0.0 || visSecRect.origin.y != 0.0) {
        secContent = [secContent imageByApplyingTransform:
                      CGAffineTransformMakeTranslation(-visSecRect.origin.x,
                                                       -visSecRect.origin.y)];
    }

    // Aspect-fill: scale = MAX so secondary content fills PiP with no black edges.
    // Because pipH/pipW already matches visSecH/visSecW, both axes yield the same
    // scale — the content fits without aggressive crop in the normal case.
    double fillScale = MAX(pipW / visSecW, pipH / visSecH);
    if (fillScale <= 0.0) { fillScale = 1.0; }

    CIImage *secScaled = [secContent imageByApplyingTransform:
                          CGAffineTransformMakeScale(fillScale, fillScale)];

    // Center over PiP rect (Y-up: CIImage origin is bottom-left).
    double scaledW = visSecW * fillScale;
    double scaledH = visSecH * fillScale;
    double tx = pipOriginX + (pipW - scaledW) * 0.5;
    double ty = pipOriginY + (pipH - scaledH) * 0.5;
    CIImage *secTranslated = [secScaled imageByApplyingTransform:
                              CGAffineTransformMakeTranslation(tx, ty)];

    // Crop to PiP rect: removes any sub-pixel overflow from aspect-fill.
    CIImage *secPositioned = [secTranslated imageByCroppingToRect:pipFinalRect];


    // Corner radius mask (CIRoundedRectangleGenerator + CIBlendWithAlphaMask).
    CIImage *secStyled = secPositioned;
    double cr = pip.cornerRadius;
    if (cr < 0.0) { cr = 0.0; }
    double maxCR = MIN(pipW, pipH) * 0.5;
    if (cr > maxCR) { cr = maxCR; }
    if (cr > 0.0) {
        CGRect pipLocalRect = CGRectMake(pipOriginX, pipOriginY, pipW, pipH);
        CIImage *mask = [CIFilter filterWithName:@"CIRoundedRectangleGenerator"
                                   keysAndValues:
                         @"inputExtent", [CIVector vectorWithCGRect:pipLocalRect],
                         @"inputRadius", @(cr),
                         @"inputColor",  [CIColor whiteColor],
                         nil].outputImage;
        if (mask) {
            mask = [mask imageByCroppingToRect:pipLocalRect];
            CIFilter *blendFilter = [CIFilter filterWithName:@"CIBlendWithAlphaMask"
                                                keysAndValues:
                kCIInputImageKey,           secPositioned,
                kCIInputMaskImageKey,       mask,
                kCIInputBackgroundImageKey, [CIImage emptyImage],
                nil];
            CIImage *masked = blendFilter.outputImage;
            if (masked) secStyled = masked;
        }
    }

    // Opacity (CIColorMatrix alpha-channel multiply).
    double op = pip.opacity;
    if (op < 0.0) { op = 0.0; }
    if (op > 1.0) { op = 1.0; }
    if (op < 1.0) {
        CIFilter *opFilter = [CIFilter filterWithName:@"CIColorMatrix"
                                         keysAndValues:
            kCIInputImageKey,    secStyled,
            @"inputRVector",     [CIVector vectorWithX:1 Y:0 Z:0 W:0],
            @"inputGVector",     [CIVector vectorWithX:0 Y:1 Z:0 W:0],
            @"inputBVector",     [CIVector vectorWithX:0 Y:0 Z:1 W:0],
            @"inputAVector",     [CIVector vectorWithX:0 Y:0 Z:0 W:op],
            @"inputBiasVector",  [CIVector vectorWithX:0 Y:0 Z:0 W:0],
            nil];
        CIImage *withOpacity = opFilter.outputImage;
        if (withOpacity) secStyled = withOpacity;
    }

    // Composite secondary over primary (Porter-Duff SourceOver).
    CIImage *composited = [secStyled imageByCompositingOverImage:primaryCI];
    if (!composited) return NULL;

    // Allocate canvas-authoritative output buffer.
    CVPixelBufferRef outputBuf = _VGTCNCreateCanvasBuffer(canvasSize);
    if (!outputBuf) {
        os_log_error(OS_LOG_DEFAULT, "[VGTCNode-Q3B] PiP: CVPixelBufferCreate failed.");
        return NULL;
    }

    CGRect renderBounds = CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH);
    // Phase 7.x-Q3B color-space fix: pass explicit device RGB so Core Image
    // gamma-encodes output values correctly. Matches _VGTCNBlendBuffers pattern.
    // colorSpace:nil would write linear working-space values directly, causing
    // dark/underexposed composited output.
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_VGTCNSharedCIContext() render:composited
                     toCVPixelBuffer:outputBuf
                               bounds:renderBounds
                           colorSpace:cs];
    CGColorSpaceRelease(cs);

    os_log(OS_LOG_DEFAULT,
           "[VGTCNode-Q3B] PiP composited: pip=(%.0f,%.0f,%.0f,%.0f) "
           "prim=%zux%zu sec=%zux%zu anchor=%ld wf=%.3f cr=%.1f op=%.2f",
           pipOriginX, pipOriginY, pipW, pipH,
           primW, primH, secW, secH,
           (long)pip.anchor, pip.widthFraction, cr, op);

    return outputBuf; // Caller owns +1
}

// ── Phase 7.x-Q3B: Split-screen composition helper ──────────────────────────
//
// Primary → top band, secondary → bottom band. Portrait vertical split only.
// Canvas authority: output allocated at canvasSize.
// Port of VGDualCameraCompositorNode._compositeWithSplitScreen:secondary:
static CVPixelBufferRef _VGTCNCompositeSplitScreen(
        CVPixelBufferRef primaryBuf,
        CVPixelBufferRef secondaryBuf,
        _VGTCNSplitScreenLayoutConfig split,
        CGSize canvasSize) {
    if (!primaryBuf || !secondaryBuf) return NULL;

    size_t primW = CVPixelBufferGetWidth(primaryBuf);
    size_t primH = CVPixelBufferGetHeight(primaryBuf);
    size_t secW  = CVPixelBufferGetWidth(secondaryBuf);
    size_t secH  = CVPixelBufferGetHeight(secondaryBuf);

    if (primW == 0 || primH == 0 || secW == 0 || secH == 0) {
        os_log_error(OS_LOG_DEFAULT,
                     "[VGTCNode-Q3B] Split: degenerate dimensions "
                     "prim=%zux%zu sec=%zux%zu — skipping.", primW, primH, secW, secH);
        return NULL;
    }

    // Split geometry (Y-up: top band has higher Y values).
    double sr = split.splitRatio;
    if (sr < 0.2) { sr = 0.2; }
    if (sr > 0.8) { sr = 0.8; }
    double topH    = floor((double)primH * sr);
    double bottomH = (double)primH - topH;
    if (topH < 1.0 || bottomH < 1.0) {
        os_log_error(OS_LOG_DEFAULT,
                     "[VGTCNode-Q3B] Split: degenerate band heights topH=%.0f bottomH=%.0f.",
                     topH, bottomH);
        return NULL;
    }
    double canvasW = (double)primW;
    double canvasH = (double)primH;

    CIImage *primaryCI   = [CIImage imageWithCVPixelBuffer:primaryBuf];
    CIImage *secondaryCI = [CIImage imageWithCVPixelBuffer:secondaryBuf];
    if (!primaryCI || !secondaryCI) return NULL;

    // Aspect-fill helper: normalize → scale-to-fill → center → crop to rect.
    CIImage *(^aspectFillIntoRect)(CIImage *, size_t, size_t, CGRect) =
        ^CIImage *(CIImage *src, size_t srcW, size_t srcH, CGRect targetRect) {
            CIImage *norm = src;
            CGPoint origin = norm.extent.origin;
            if (origin.x != 0.0 || origin.y != 0.0) {
                norm = [norm imageByApplyingTransform:
                        CGAffineTransformMakeTranslation(-origin.x, -origin.y)];
            }
            double sX = (srcW > 0) ? CGRectGetWidth(targetRect)  / (double)srcW : 1.0;
            double sY = (srcH > 0) ? CGRectGetHeight(targetRect) / (double)srcH : 1.0;
            double s  = MAX(sX, sY);
            if (s <= 0.0) { s = 1.0; }
            CIImage *scaled = [norm imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
            double scaledW = (double)srcW * s;
            double scaledH = (double)srcH * s;
            double offX = CGRectGetMinX(targetRect) + (CGRectGetWidth(targetRect)  - scaledW) * 0.5;
            double offY = CGRectGetMinY(targetRect) + (CGRectGetHeight(targetRect) - scaledH) * 0.5;
            CIImage *centered = [scaled imageByApplyingTransform:
                                 CGAffineTransformMakeTranslation(offX, offY)];
            return [centered imageByCroppingToRect:targetRect];
        };

    // CoreImage Y-up: top band rect has higher Y.
    CGRect topRect    = CGRectMake(0.0, bottomH, canvasW, topH);
    CGRect bottomRect = CGRectMake(0.0, 0.0,     canvasW, bottomH);
    CIImage *topBand    = aspectFillIntoRect(primaryCI,   primW, primH, topRect);
    CIImage *bottomBand = aspectFillIntoRect(secondaryCI, secW,  secH,  bottomRect);
    if (!topBand || !bottomBand) return NULL;

    // Black canvas backing prevents any gaps at the split boundary.
    CGRect canvasRect  = CGRectMake(0, 0, canvasW, canvasH);
    CIImage *blackBase = [[CIImage imageWithColor:[CIColor blackColor]]
                          imageByCroppingToRect:canvasRect];
    CIImage *withBottom = [bottomBand imageByCompositingOverImage:blackBase];
    CIImage *composited = [topBand    imageByCompositingOverImage:withBottom];
    if (!composited) return NULL;

    // Allocate canvas-authoritative output buffer.
    CVPixelBufferRef outputBuf = _VGTCNCreateCanvasBuffer(canvasSize);
    if (!outputBuf) {
        os_log_error(OS_LOG_DEFAULT, "[VGTCNode-Q3B] Split: CVPixelBufferCreate failed.");
        return NULL;
    }

    CGRect renderBounds = CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH);
    // Phase 7.x-Q3B color-space fix: explicit device RGB to match PiP path and
    // _VGTCNBlendBuffers. Prevents linear working-space values from being written
    // directly into the output buffer (which would produce dark composited output).
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_VGTCNSharedCIContext() render:composited
                     toCVPixelBuffer:outputBuf
                               bounds:renderBounds
                           colorSpace:cs];
    CGColorSpaceRelease(cs);

    os_log(OS_LOG_DEFAULT,
           "[VGTCNode-Q3B] Split composited: prim=%zux%zu sec=%zux%zu "
           "topH=%.0f bottomH=%.0f splitRatio=%.3f",
           primW, primH, secW, secH, topH, bottomH, sr);

    return outputBuf; // Caller owns +1
}
// ─── End Phase 7.x-Q3B helpers ───────────────────────────────────────────────

// ─── Phase 7.12: Still-image decode helper ───────────────────────────────────
//
// _VGTCNCreatePixelBufferFromStillImage: Decodes a still image at sourceURL
//   into a 32BGRA CVPixelBufferRef at the specified targetSize.
//
// Phase 7.16 DEC-148: Updated to accept fitMode and cropRect.
//
// Crop contract (Phase 7.16):
//   cropRect, when non-nil, is NSArray<NSNumber *> of 4 normalized doubles [x, y, w, h].
//   Coordinate system: CGImage from CGImageSourceCreateThumbnailAtIndex with
//   kCGImageSourceCreateThumbnailWithTransform=YES uses top-left origin (same as UIKit).
//   Crop is applied BEFORE fit/fill scaling (crop-then-fit order).
//
//   Apple documentation notes:
//   - CGImageCreateWithImageInRect: rect is in the CGImage's coordinate system
//     (top-left origin for post-thumbnail normalized images). Returns +1 CGImageRef.
//     The returned image contains a copy of the pixels in the specified rect.
//     If rect extends beyond the bounds, it is clipped to the available region.
//   - kCGImageSourceCreateThumbnailWithTransform=YES applies EXIF orientation,
//     so the thumbnail is already orientation-normalized. Crop is applied after.
//
// Fit/fill contract:
//   fit  (VGStillImageFitModeFit):  scale = MIN(scaleX, scaleY) — letterbox/pillarbox.
//   fill (VGStillImageFitModeFill): scale = MAX(scaleX, scaleY) — no black bars,
//     excess pixels extend beyond canvas bounds and are not drawn.
//
// CoreFoundation objects: fully released before return in all paths.

static CVPixelBufferRef _VGTCNCreatePixelBufferFromStillImage(
    NSURL *sourceURL,
    CGSize targetSize,
    VGStillImageFitMode fitMode,
    NSArray<NSNumber *> * _Nullable cropRect,
    NSError **outError) {
  // ── 1. Create CGImageSource ─────────────────────────────────────────────────
  CGImageSourceRef imgSrc = CGImageSourceCreateWithURL(
      (__bridge CFURLRef)sourceURL, NULL);
  if (!imgSrc) {
    if (outError) {
      *outError = _VGTCNError(
          23, ([NSString stringWithFormat:
                   @"VGTimelineCompositorNode (Phase 7.12): CGImageSourceCreateWithURL "
                    "failed or unsupported image format. sourceURL=%@",
                   sourceURL.lastPathComponent]));
    }
    return NULL;
  }

  // ── 2. Determine max pixel size for downscaling (RR-148 mitigation) ────────
  CGFloat maxPixelSize = 2048.0; // safe fallback when no canvas size supplied
  if (targetSize.width > 0 && targetSize.height > 0) {
    maxPixelSize = MAX(targetSize.width, targetSize.height);
  }

  // ── 3. Decode thumbnail with EXIF orientation normalization ────────────────
  NSDictionary *thumbOptions = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (id)kCGImageSourceCreateThumbnailWithTransform   : @YES,   // apply EXIF orientation
    (id)kCGImageSourceThumbnailMaxPixelSize          : @(maxPixelSize),
  };
  CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(
      imgSrc, 0, (__bridge CFDictionaryRef)thumbOptions);
  CFRelease(imgSrc); // imgSrc no longer needed

  if (!cgImage) {
    if (outError) {
      *outError = _VGTCNError(
          24, ([NSString stringWithFormat:
                   @"VGTimelineCompositorNode (Phase 7.12): CGImageSourceCreateThumbnailAtIndex "
                    "failed. Unsupported image data or corrupt file. sourceURL=%@",
                   sourceURL.lastPathComponent]));
    }
    return NULL;
  }

  // ── 3b. Phase 7.16: Apply crop if cropRect is specified ───────────────────
  // Crop is applied BEFORE fit/fill scaling (crop-then-fit order).
  //
  // After kCGImageSourceCreateThumbnailWithTransform=YES, cgImage is already
  // orientation-normalized (top-left origin). Denormalize the normalized
  // [x, y, w, h] rect into pixel coordinates of the post-thumbnail image.
  //
  // CGImageCreateWithImageInRect: rect uses CGImage coordinate system
  // (top-left origin for this post-thumbnail image). If rect extends beyond
  // image bounds, it is clipped. We clamp defensively before calling.
  //
  // The cropped image becomes the active source for fit/fill scaling below.
  // Release both the crop result and cgImage when done.
  CGImageRef activeImage = cgImage; // owned by this function; released at end
  if (cropRect != nil && cropRect.count == 4) {
    size_t imgW = CGImageGetWidth(cgImage);
    size_t imgH = CGImageGetHeight(cgImage);
    if (imgW > 0 && imgH > 0) {
      double cx = [cropRect[0] doubleValue];
      double cy = [cropRect[1] doubleValue];
      double cw = [cropRect[2] doubleValue];
      double ch = [cropRect[3] doubleValue];

      // Denormalize to pixel coordinates.
      double pixX = cx * (double)imgW;
      double pixY = cy * (double)imgH;
      double pixW = cw * (double)imgW;
      double pixH = ch * (double)imgH;

      // Clamp defensively to image bounds (belt-and-suspenders; input was
      // already validated by VGCDValidateCropRect).
      pixX = MAX(0.0, MIN(pixX, (double)imgW));
      pixY = MAX(0.0, MIN(pixY, (double)imgH));
      pixW = MIN(pixW, (double)imgW - pixX);
      pixH = MIN(pixH, (double)imgH - pixY);

      if (pixW > 0.0 && pixH > 0.0) {
        CGRect cropBounds = CGRectMake(pixX, pixY, pixW, pixH);
        CGImageRef croppedImage = CGImageCreateWithImageInRect(cgImage, cropBounds);
        if (croppedImage) {
          // Transfer ownership: release original, use cropped as active source.
          CGImageRelease(cgImage);
          activeImage = croppedImage; // +1 from CGImageCreateWithImageInRect
          cgImage = NULL;             // prevent double-release at end of function
        }
        // If crop failed (croppedImage == NULL), activeImage remains cgImage;
        // fall through to render with the uncropped image (safe degradation).
      }
    }
  }

  // ── 4. Determine canvas size for output buffer ──────────────────────────
  // Use targetSize when valid, fall back to decoded image dimensions.
  size_t canvasW, canvasH;
  if (targetSize.width > 0 && targetSize.height > 0) {
    canvasW = (size_t)targetSize.width;
    canvasH = (size_t)targetSize.height;
  } else {
    canvasW = CGImageGetWidth(activeImage);
    canvasH = CGImageGetHeight(activeImage);
  }

  if (canvasW == 0 || canvasH == 0) {
    CGImageRelease(activeImage);
    if (outError) {
      *outError = _VGTCNError(
          25, @"VGTimelineCompositorNode (Phase 7.12): canvas or image size is "
               "zero; cannot create pixel buffer.");
    }
    return NULL;
  }

  // ── 5. Create BGRA CVPixelBuffer ────────────────────────────────────
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey  : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferRef pb = NULL;
  CVReturn cvRet = CVPixelBufferCreate(kCFAllocatorDefault, canvasW, canvasH,
                                       kCVPixelFormatType_32BGRA,
                                       (__bridge CFDictionaryRef)pbAttrs, &pb);
  if (cvRet != kCVReturnSuccess || !pb) {
    CGImageRelease(activeImage);
    if (outError) {
      *outError = _VGTCNError(
          25, ([NSString stringWithFormat:
                   @"VGTimelineCompositorNode (Phase 7.12): CVPixelBufferCreate "
                    "failed (CVReturn=%d) for still image canvas %zux%zu.",
                   (int)cvRet, canvasW, canvasH]));
    }
    return NULL;
  }

  // ── 6. Render active image into pixel buffer with fit/fill scaling ─────────
  //
  // Phase 7.16 (DEC-148):
  //   fit  (VGStillImageFitModeFit):  scale = MIN(scaleX, scaleY)
  //     Image fits entirely inside canvas; black bars fill remainder.
  //   fill (VGStillImageFitModeFill): scale = MAX(scaleX, scaleY)
  //     Image fills canvas completely; excess is clipped by canvas bounds.
  //
  // The CGContext clip rect is the full canvas; pixels outside the canvas
  // rect are never written, naturally implementing fill-mode edge clipping.
  CVPixelBufferLockBaseAddress(pb, 0);
  void *base = CVPixelBufferGetBaseAddress(pb);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

  CGContextRef ctx = CGBitmapContextCreate(
      base,
      canvasW, canvasH,
      8,                                              // bits per component
      CVPixelBufferGetBytesPerRow(pb),
      cs,
      kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst); // 32BGRA
  CGColorSpaceRelease(cs);

  if (!ctx) {
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CVPixelBufferRelease(pb);
    CGImageRelease(activeImage);
    if (outError) {
      *outError = _VGTCNError(
          25, @"VGTimelineCompositorNode (Phase 7.12): CGBitmapContextCreate "
               "failed for still image render.");
    }
    return NULL;
  }

  // Fill canvas with black (handles letterbox/pillarbox regions and alpha PNGs).
  CGContextSetFillColorWithColor(ctx, [[UIColor blackColor] CGColor]);
  CGContextFillRect(ctx, CGRectMake(0, 0, canvasW, canvasH));

  // Compute scaled rect: fit or fill, centered on canvas.
  size_t imgW = CGImageGetWidth(activeImage);
  size_t imgH = CGImageGetHeight(activeImage);
  if (imgW > 0 && imgH > 0) {
    double scaleX = (double)canvasW / (double)imgW;
    double scaleY = (double)canvasH / (double)imgH;

    // Phase 7.16: select scale based on fitMode.
    //   fit:  MIN(scaleX, scaleY) — image fits within canvas, black bars possible.
    //   fill: MAX(scaleX, scaleY) — image covers canvas, edges may be clipped.
    double scale;
    if (fitMode == VGStillImageFitModeFill) {
      scale = MAX(scaleX, scaleY);
    } else {
      scale = MIN(scaleX, scaleY); // VGStillImageFitModeFit (default)
    }

    double drawW = imgW * scale;
    double drawH = imgH * scale;
    double drawX = ((double)canvasW - drawW) / 2.0;
    double drawY = ((double)canvasH - drawH) / 2.0;
    CGContextDrawImage(ctx, CGRectMake(drawX, drawY, drawW, drawH), activeImage);
  }

  CGContextRelease(ctx);
  CVPixelBufferUnlockBaseAddress(pb, 0);
  CGImageRelease(activeImage);

  return pb; // caller owns +1 from CVPixelBufferCreate
}

// ─── Phase 7.11: Per-clip CoreImage transform + opacity helper ─────────────────
//
// _VGTCNApplyTransformAndOpacity: applies a VGClipTransformDescriptor to a
//   CVPixelBuffer using CoreImage, returning a new buffer.
//
// Coordinate system notes (DEC-144 / D1):
//   - Dart/UIKit: top-left origin, positive Y down, clockwise rotation positive.
//   - CoreImage:  bottom-left origin, positive Y up, CCW rotation positive.
//   Corrections applied here:
//     anchorY_CI  = (1.0 - anchorY) * frameHeight    (D1: Y-axis flip)
//     rotation_CI = -rotation                         (negate for CCW)
//     translationY_CI = -translationY                 (negate for bottom-up)
//
// Identity optimisation (D4): caller checks isIdentity BEFORE calling here.
//   This helper is only invoked for non-identity transforms.
//
// Returns a new retained CVPixelBufferRef (+1) on success.
// Returns NULL with *outError on failure. No silent masking.
//
// RR-145: Each non-identity transform frame costs one CVPixelBufferCreate +
//   CIAffineTransform render + optional CIColorMatrix. Monitor GPU budget.

static CVPixelBufferRef _VGTCNApplyTransformAndOpacity(
    CVPixelBufferRef sourceBuffer,
    VGClipTransformDescriptor *td,
    NSError **outError) {

  size_t w = CVPixelBufferGetWidth(sourceBuffer);
  size_t h = CVPixelBufferGetHeight(sourceBuffer);

  // Build CoreImage source image.
  CIImage *srcCI = [CIImage imageWithCVPixelBuffer:sourceBuffer];

  // ─ Affine transform (scale + rotation + translation) ────────────────────────
  //
  // Pivot: anchor point in CoreImage coordinates.
  //   anchorX_CI = anchorX * w
  //   anchorY_CI = (1.0 - anchorY) * h   <- D1: Y-axis flip for CoreImage
  //
  // Logical transform order (left-to-right, applied to image point coordinates):
  //   1. Translate to anchor: move anchor point to coordinate origin.
  //   2. Scale around origin.
  //   3. Rotate around origin (negated for CoreGraphics CCW-positive convention).
  //   4. Translate back: restore anchor to its original canvas position.
  //   5. Apply user translation (negate Y for CoreImage bottom-left).
  //
  // RR-147 (Phase 7.11 bugfix): Use CGAffineTransformConcat with individually
  // constructed matrices. CGAffineTransformScale/Rotate/Translate helper functions
  // concatenate such that coordinate transforms are applied in the REVERSE of
  // code-written order (the helper post-multiplies). Using explicit Concat here
  // preserves the intended left-to-right operation order, ensuring the anchor
  // maps back to its original canvas position (not the CoreImage origin) after
  // scale/rotation, fixing the TV-02 left/bottom-edge positioning failure.

  CGFloat anchorX_CI = (CGFloat)(td.anchorX * (double)w);
  CGFloat anchorY_CI = (CGFloat)((1.0 - td.anchorY) * (double)h); // D1

  // Build each component transform independently.
  CGAffineTransform t1 = CGAffineTransformMakeTranslation(-anchorX_CI, -anchorY_CI);
  CGAffineTransform t2 = CGAffineTransformMakeScale((CGFloat)td.scaleX, (CGFloat)td.scaleY);
  CGAffineTransform t3 = CGAffineTransformMakeRotation(-(CGFloat)td.rotation);
  CGAffineTransform t4 = CGAffineTransformMakeTranslation(anchorX_CI, anchorY_CI);
  CGAffineTransform t5 = CGAffineTransformMakeTranslation((CGFloat)td.translationX,
                                                           -(CGFloat)td.translationY);

  // Concatenate in logical left-to-right order: t = t1 · t2 · t3 · t4 · t5.
  CGAffineTransform t = CGAffineTransformConcat(t1, t2);
  t = CGAffineTransformConcat(t, t3);
  t = CGAffineTransformConcat(t, t4);
  t = CGAffineTransformConcat(t, t5);

  CIFilter *affineFilter = [CIFilter filterWithName:@"CIAffineTransform"];
  [affineFilter setValue:srcCI       forKey:kCIInputImageKey];
  [affineFilter setValue:[NSValue valueWithBytes:&t
                                        objCType:@encode(CGAffineTransform)]
                  forKey:@"inputTransform"];
  CIImage *transformedCI = affineFilter.outputImage;
  if (!transformedCI) {
    if (outError) {
      *outError = _VGTCNError(
          20, @"VGTimelineCompositorNode (Phase 7.11): CIAffineTransform "
               "produced no output image.");
    }
    return NULL;
  }

  // Clamp to source frame extent so downstream renderer receives
  // a buffer with defined pixel content outside the transformed region.
  // CIConstantColorGenerator fills any uncovered pixels with black (transparent=0).
  CIImage *black = [CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]];
  CIFilter *composite = [CIFilter filterWithName:@"CISourceOverCompositing"];
  [composite setValue:transformedCI forKey:kCIInputImageKey];
  [composite setValue:[black imageByCroppingToRect:srcCI.extent]
               forKey:kCIInputBackgroundImageKey];
  CIImage *composited = composite.outputImage;
  if (!composited) { composited = transformedCI; } // fallback: skip composite

  // ─ Opacity via CIColorMatrix (alpha channel multiply) ────────────────────
  //
  // CIColorMatrix with identity RGB vectors and alpha vector (0,0,0,opacity)
  // scales the alpha channel by opacity. This preserves RGB values and
  // produces premultiplied-compatible output for subsequent blending.
  CIImage *finalCI = composited;
  if (td.opacity < 1.0) {
    CIFilter *opacityFilter = [CIFilter filterWithName:@"CIColorMatrix"];
    [opacityFilter setValue:composited forKey:kCIInputImageKey];
    // Alpha vector: (0, 0, 0, opacity) — scales A channel by opacity.
    CIVector *alphaVec = [CIVector vectorWithX:0 Y:0 Z:0 W:(CGFloat)td.opacity];
    [opacityFilter setValue:alphaVec forKey:@"inputAVector"];
    // Bias = 0 (no additive bias needed).
    [opacityFilter setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0]
                     forKey:@"inputBiasVector"];
    CIImage *opacityOut = opacityFilter.outputImage;
    if (opacityOut) { finalCI = opacityOut; }
    // If filter fails, fall through with composited image (opacity not applied).
  }

  // ─ Render to new CVPixelBuffer (D5: use CVPixelBufferCreate) ─────────────
  NSDictionary *attrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey    : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferRef out = NULL;
  CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &out);
  if (ret != kCVReturnSuccess || !out) {
    if (outError) {
      *outError = _VGTCNError(
          21, @"VGTimelineCompositorNode (Phase 7.11): CVPixelBufferCreate "
               "failed for transform output buffer.");
    }
    return NULL;
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  [_VGTCNSharedCIContext() render:finalCI
                   toCVPixelBuffer:out
                             bounds:srcCI.extent
                         colorSpace:cs];
  CGColorSpaceRelease(cs);

  return out; // Caller owns +1 from CVPixelBufferCreate
}


// ─── os_log
// ───────────────────────────────────────────────────────────────────
static os_log_t sTimelineLog;

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Private state struct for per-clip reader
// ─────────────────────────────────────────────────────────────────────────────

// Holds the active AVAssetReader + output for a single clip.
// Created lazily; torn down and rebuilt on seek or clip switch.
// _reader and _trackOutput are only valid while _reader.status == Reading.
//
// Phase 7.9: trackOutput is typed as AVAssetReaderOutput (base class) because
// AVAssetReaderVideoCompositionOutput is not an AVAssetReaderTrackOutput.
// copyNextSampleBuffer is declared on AVAssetReaderOutput, so the existing
// call site at pullFrame: continues to work without modification.
//
// Phase 7.11 RR-146 (playback-rate-exhaustion fix):
//   Per-reader frame reuse cache eliminates the dual-reader frame exhaustion
//   bug where the 60/120 Hz CADisplayLink consumed transition frames at display
//   rate (not at the 30 fps clip rate), exhausting AVAssetReader prematurely.
//   Each reader caches its last decoded/transformed CVPixelBuffer. If the
//   requested asset time falls within the cached sample window, copyNextSampleBuffer
//   is skipped and the cached buffer is returned (retained +1) to the caller.
//   The cache is released safely in -dealloc via CVPixelBufferRelease.
@interface _VGClipReader : NSObject
@property(nonatomic) NSUInteger clipIndex; // index in _clips
@property(nonatomic) AVAssetReader *reader;
@property(nonatomic) AVAssetReaderOutput *trackOutput; // Phase 7.9: base type
@property(nonatomic) double sourceFPS;                 // nominal frame rate
// Phase 7.11 RR-146: per-reader frame reuse cache.
// lastDeliveredBuffer: retained +1 by this reader; released in dealloc.
// lastDeliveredAssetPTS:      asset-local PTS of the cached frame; -1.0 = empty.
// lastDeliveredAssetDuration: asset-local sample duration of the cached frame.
@property(nonatomic) CVPixelBufferRef lastDeliveredBuffer;      // nullable; +1
@property(nonatomic) double lastDeliveredAssetPTS;              // -1.0 when empty
@property(nonatomic) double lastDeliveredAssetDuration;
// Phase 7.12: YES for still-image clips. reader and trackOutput are nil.
// Decoded buffer is cached on first pull; subsequent pulls return cached buffer.
@property(nonatomic) BOOL isStaticSource;
// Phase 7.17: Source-local PTS for video-derived freeze frame extraction.
// Non-nil ONLY for freeze clips (mediaKind=video, freezePTS!=nil in descriptor).
// Nil for still-image clips (those decode from sourceURL directly).
// Nil for normal video clips (those use AVAssetReader).
@property(nonatomic, strong, nullable) NSNumber *freezePTS;
// Phase 7.19 (DEC-154): Reverse playback direction flag.
// YES for reversed video clips (isReversed=YES in descriptor).
// When YES, _pullBufferFromReader: uses AVAssetImageGenerator for each frame
// (forward-only AVAssetReader is bypassed). Frames are cached in _frameCache.
// Always NO for still-image and freeze-frame clips (those use isStaticSource=YES).
@property(nonatomic) BOOL isReversed;
// Phase 7.x-Q2: Optional nested secondary reader for dual-camera timeline clips.
// Non-nil only when the enclosing clip carries a VGDualCameraDescriptor.
// Lifecycle: released automatically when this primary reader is deallocated
// (clip switch, seek, or invalidate). No additional teardown code needed.
@property(nonatomic, strong, nullable) _VGClipReader *secondaryClipReader;
// Phase 7.x-Q2: YES when the secondary reader has been exhausted (EOS or error).
// When YES, pullFrame: skips secondary pull for this clip; primary continues.
// Reset to NO when this primary reader is torn down and rebuilt on next clip.
// Ownership: this flag lives on the PRIMARY reader (not the secondary).
@property(nonatomic) BOOL secondaryEOSReached;
// Phase 7.x-Q3A: The VGClipDescriptor this reader was built from.
// For primary readers: always _clips[clipIndex] (set in _buildReaderForClipIndex:).
// For secondary readers: the parsed secondary VGClipDescriptor from the
// dualCamera dictionary (set in _buildSecondaryReaderForDualCamera:).
// This field decouples _pullBufferFromReader: from the _clips array, ensuring
// secondary readers look up the correct sourceURL, fitMode, transform, etc.
// ARC manages lifetime; no manual release needed.
@property(nonatomic, strong, nullable) VGClipDescriptor *resolvedClip;
@end

@implementation _VGClipReader

- (instancetype)init {
  self = [super init];
  if (self) {
    _lastDeliveredBuffer = NULL;
    _lastDeliveredAssetPTS = -1.0;
    _lastDeliveredAssetDuration = 0.0;
  }
  return self;
}

- (void)dealloc {
  // Release the per-reader cached buffer. This fires when the reader is
  // torn down (clip switch, seek, or invalidate), ensuring no CVPixelBuffer
  // outlives its owning AVAssetReader.
  if (_lastDeliveredBuffer) {
    CVPixelBufferRelease(_lastDeliveredBuffer);
    _lastDeliveredBuffer = NULL;
  }
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.18A: Frame cache entry
// ─────────────────────────────────────────────────────────────────────────────

// _VGFrameCacheEntry — one cached (clipIndex, sourceURL, quantized assetPTS,
// renderSize, generation) → CVPixelBufferRef mapping.
//
// Ownership:
//   buffer is retained +1 by the entry.
//   dealloc releases buffer, guarding against double-release via NULL.
//
// assetPTS quantization: rounded to nearest millisecond (0.001 s) to avoid
//   floating-point key mismatches for the same logical frame.
@interface _VGFrameCacheEntry : NSObject
@property (nonatomic) NSUInteger  clipIndex;     // index in _clips
@property (nonatomic, copy) NSString *sourceURL; // clip.sourceURL at cache time
@property (nonatomic) double      assetPTS;      // quantized to 0.001 s
@property (nonatomic) CGSize      renderSize;    // canvas dimensions at cache time
@property (nonatomic) uint64_t    generation;    // graph generation when cached
@property (nonatomic) CVPixelBufferRef buffer;   // retained +1 by this entry
@property (nonatomic) uint64_t    accessOrder;   // monotonic LRU counter
@end

@implementation _VGFrameCacheEntry

- (void)dealloc {
  if (_buffer) {
    CVPixelBufferRelease(_buffer);
    _buffer = NULL;
  }
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.18A: Frame cache
// ─────────────────────────────────────────────────────────────────────────────

// _VGTimelineFrameCache — compositor-private, byte-budgeted LRU cache.
//
// Budget: kVGFrameCacheBudgetBytes (32 MB). Byte-budgeted, not frame-count-
// budgeted, because BGRA buffer sizes vary with render size:
//   640×360   ≈  922 KB → ~34 frames cached
//   1080×1920 ≈ 8.3 MB  →  ~3 frames cached
//
// Thread safety: os_unfair_lock protects the entries array and byte counter.
//   - Pull-thread reads and writes (lookup, insert on sync path).
//   - Prefetch-queue writes (insert on async prefetch completion).
//   - Seek/invalidate caller writes (flush).
//
// Ownership contract:
//   Insert:  cache retains buffer (CVPixelBufferRetain). Caller keeps its own +1.
//   Lookup:  cache retains on return for caller (+1). Caller must release.
//   Evict:   cache releases its retain (CVPixelBufferRelease).
//   Flush:   cache releases all retains.
//   Dealloc: equivalent to flushAll.
//
// TODO: Phase 7.18B — query VGResourceAllocator for dynamic budget adjustment
// and respond to memory-warning notifications.

static const size_t kVGFrameCacheBudgetBytes = 32 * 1024 * 1024; // 32 MB

@interface _VGTimelineFrameCache : NSObject
/// Lookup: returns a retained CVPixelBufferRef (+1) on hit, NULL on miss.
- (nullable CVPixelBufferRef)lookupWithClipIndex:(NSUInteger)clipIndex
                                       sourceURL:(NSString *)sourceURL
                                        assetPTS:(double)assetPTS
                                      renderSize:(CGSize)renderSize
                                      generation:(uint64_t)generation;
/// Insert. Skips if key already cached or single buffer exceeds budget.
- (void)insertWithClipIndex:(NSUInteger)clipIndex
                  sourceURL:(NSString *)sourceURL
                   assetPTS:(double)assetPTS
                 renderSize:(CGSize)renderSize
                 generation:(uint64_t)generation
                     buffer:(CVPixelBufferRef)buffer;
/// Flush all entries whose generation does not match.
- (void)flushForGeneration:(uint64_t)generation;
/// Release all entries. Resets metrics counters.
- (void)flushAll;
/// Current byte usage (for logging).
- (size_t)currentBytes;
/// Phase 7.18B1: Snapshot of cache metrics under lock.
/// Keys: hits, misses, evictions, inserts, entries.
- (NSDictionary<NSString *, NSNumber *> *)statistics;
@end

@implementation _VGTimelineFrameCache {
  NSMutableArray<_VGFrameCacheEntry *> *_entries;
  size_t    _currentBytes;
  uint64_t  _accessCounter;
  os_unfair_lock _lock;
  // Phase 7.18B1: monotonic hit/miss/eviction/insert counters.
  // All incremented under _lock. Reset in flushAll.
  uint64_t  _hitCount;
  uint64_t  _missCount;
  uint64_t  _evictionCount;
  uint64_t  _insertCount;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _entries       = [NSMutableArray array];
    _currentBytes  = 0;
    _accessCounter = 0;
    _lock          = OS_UNFAIR_LOCK_INIT;
    // Phase 7.18B1: initialise metric counters.
    _hitCount      = 0;
    _missCount     = 0;
    _evictionCount = 0;
    _insertCount   = 0;
  }
  return self;
}

- (void)dealloc {
  // Release every retained buffer without taking the lock (already single owner at dealloc).
  for (_VGFrameCacheEntry *e in _entries) {
    if (e.buffer) {
      CVPixelBufferRelease(e.buffer);
      e.buffer = NULL;
    }
  }
  [_entries removeAllObjects];
  _currentBytes = 0;
}

// Quantise assetPTS to nearest millisecond to avoid float key mismatches.
static inline double _VGQuantizePTS(double pts) {
  return round(pts * 1000.0) / 1000.0;
}

- (size_t)currentBytes {
  os_unfair_lock_lock(&_lock);
  size_t b = _currentBytes;
  os_unfair_lock_unlock(&_lock);
  return b;
}

/// Lookup: returns a retained CVPixelBufferRef (+1) on hit, NULL on miss.
- (nullable CVPixelBufferRef)lookupWithClipIndex:(NSUInteger)clipIndex
                                       sourceURL:(NSString *)sourceURL
                                        assetPTS:(double)assetPTS
                                      renderSize:(CGSize)renderSize
                                      generation:(uint64_t)generation {
  double qpts = _VGQuantizePTS(assetPTS);
  os_unfair_lock_lock(&_lock);
  for (_VGFrameCacheEntry *e in _entries) {
    if (e.generation  != generation)             continue;
    if (e.clipIndex   != clipIndex)              continue;
    if (fabs(e.assetPTS - qpts) > 1e-9)         continue;
    if (!CGSizeEqualToSize(e.renderSize, renderSize)) continue;
    if (![e.sourceURL isEqualToString:sourceURL])    continue;
    // Hit: update LRU access order and retain for caller.
    e.accessOrder = ++_accessCounter;
    CVPixelBufferRef buf = e.buffer;
    if (buf) CVPixelBufferRetain(buf); // +1 for caller
    ++_hitCount; // Phase 7.18B1: count cache hit
    os_unfair_lock_unlock(&_lock);
    return buf; // caller owns +1
  }
  ++_missCount; // Phase 7.18B1: count cache miss
  os_unfair_lock_unlock(&_lock);
  return NULL; // miss
}

/// Insert a buffer into the cache. Skip if key already exists.
/// Budget-bounded with LRU eviction.
- (void)insertWithClipIndex:(NSUInteger)clipIndex
                  sourceURL:(NSString *)sourceURL
                   assetPTS:(double)assetPTS
                 renderSize:(CGSize)renderSize
                 generation:(uint64_t)generation
                     buffer:(CVPixelBufferRef)buffer {
  if (!buffer) return;
  size_t bufBytes = CVPixelBufferGetDataSize(buffer);
  // If a single frame exceeds the entire budget, skip caching.
  if (bufBytes > kVGFrameCacheBudgetBytes) return;

  double qpts = _VGQuantizePTS(assetPTS);

  os_unfair_lock_lock(&_lock);

  // Duplicate-key guard: skip if already cached.
  for (_VGFrameCacheEntry *e in _entries) {
    if (e.generation == generation       &&
        e.clipIndex  == clipIndex        &&
        fabs(e.assetPTS - qpts) < 1e-9  &&
        CGSizeEqualToSize(e.renderSize, renderSize) &&
        [e.sourceURL isEqualToString:sourceURL]) {
      os_unfair_lock_unlock(&_lock);
      return; // already cached; no-op
    }
  }

  // Evict LRU entries until we have room.
  while (_currentBytes + bufBytes > kVGFrameCacheBudgetBytes &&
         _entries.count > 0) {
    // Find entry with lowest accessOrder (LRU).
    NSUInteger lruIdx = 0;
    uint64_t   lruOrder = _entries[0].accessOrder;
    for (NSUInteger i = 1; i < _entries.count; i++) {
      if (_entries[i].accessOrder < lruOrder) {
        lruOrder = _entries[i].accessOrder;
        lruIdx = i;
      }
    }
    _VGFrameCacheEntry *evict = _entries[lruIdx];
    size_t evictBytes = CVPixelBufferGetDataSize(evict.buffer);
    CVPixelBufferRelease(evict.buffer); // cache relinquishes its +1
    evict.buffer = NULL;
    _currentBytes -= evictBytes;
    [_entries removeObjectAtIndex:lruIdx];
    ++_evictionCount; // Phase 7.18B1: count eviction
  }

  // Insert new entry.
  _VGFrameCacheEntry *entry = [[_VGFrameCacheEntry alloc] init];
  entry.clipIndex   = clipIndex;
  entry.sourceURL   = [sourceURL copy];
  entry.assetPTS    = qpts;
  entry.renderSize  = renderSize;
  entry.generation  = generation;
  entry.buffer      = buffer;
  CVPixelBufferRetain(buffer); // cache takes +1; caller keeps its own +1
  entry.accessOrder = ++_accessCounter;
  [_entries addObject:entry];
  _currentBytes += bufBytes;
  ++_insertCount; // Phase 7.18B1: count successful insert

  os_unfair_lock_unlock(&_lock);
}

/// Flush all entries whose generation does not match.
- (void)flushForGeneration:(uint64_t)generation {
  os_unfair_lock_lock(&_lock);
  NSMutableIndexSet *stale = [NSMutableIndexSet indexSet];
  for (NSUInteger i = 0; i < _entries.count; i++) {
    if (_entries[i].generation != generation) {
      [stale addIndex:i];
    }
  }
  [stale enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    _VGFrameCacheEntry *e = self->_entries[idx];
    if (e.buffer) {
      size_t eBytes = CVPixelBufferGetDataSize(e.buffer);
      CVPixelBufferRelease(e.buffer);
      e.buffer = NULL;
      self->_currentBytes -= eBytes;
    }
  }];
  [_entries removeObjectsAtIndexes:stale];
  os_unfair_lock_unlock(&_lock);
}

/// Release all cached entries. Resets metrics counters.
- (void)flushAll {
  os_unfair_lock_lock(&_lock);
  for (_VGFrameCacheEntry *e in _entries) {
    if (e.buffer) {
      CVPixelBufferRelease(e.buffer);
      e.buffer = NULL;
    }
  }
  [_entries removeAllObjects];
  _currentBytes = 0;
  // Phase 7.18B1: reset counters on flush so next warm-up starts from zero.
  _hitCount      = 0;
  _missCount     = 0;
  _evictionCount = 0;
  _insertCount   = 0;
  os_unfair_lock_unlock(&_lock);
}

/// Phase 7.18B1: Returns an immutable snapshot of cache metrics under lock.
- (NSDictionary<NSString *, NSNumber *> *)statistics {
  os_unfair_lock_lock(&_lock);
  NSDictionary *snap = @{
    @"hits":      @(_hitCount),
    @"misses":    @(_missCount),
    @"evictions": @(_evictionCount),
    @"inserts":   @(_insertCount),
    @"entries":   @(_entries.count),
    @"bytes":     @(_currentBytes),
  };
  os_unfair_lock_unlock(&_lock);
  return snap;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGTimelineCompositorNode
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGTimelineCompositorNode {

  // ── Identity (stable after init) ──────────────────────────────────────────
  NSString *_nodeId;
  NSArray<VGMediaPort *> *_ports;

  // ── Descriptor data (immutable after init) ────────────────────────────────
  // Sorted ascending by startTimeSeconds (enforced by VGEditorGraphFactory).
  NSArray<VGClipDescriptor *> *_clips;
  NSArray<VGTransitionDescriptor *> *_transitions;
  NSArray<NSDictionary *> *_dualCameraDescDicts; // Phase 7.x-Q1
  // Phase 7.x-Q3B: One NSValue-wrapped _VGTCNDualCameraLayoutConfig per clip.
  // Parsed once at init from _dualCameraDescDicts. NSNull sentinel for no-dual-camera clips.
  NSArray<NSValue *> *_dualCameraLayoutConfigs; // Phase 7.x-Q3B

  // ── Active / outgoing reader state ─────────────────────────────────────────
  // _activeReader:  the incoming (or sole) clip reader. Never nil during decode.
  // _outgoingReader: the outgoing clip reader during a non-hard-cut transition
  //   window. Non-nil only while requestedPTSSecs is within the overlap window
  //   [incomingClip.startTimeSeconds, incomingClip.startTimeSeconds + T].
  //   Torn down when the window ends, on seek, or on invalidate (RR-142).
  _VGClipReader *_activeReader;   // nullable
  _VGClipReader *_outgoingReader; // nullable; non-nil during transition window

  // ── Buffer ownership (RR-36) ──────────────────────────────────────────────
  // _lastDeliveredBuffer: retained +1 by this node. Used ONLY to extend the
  // CVPixelBuffer's lifetime through the VGFrameEnvelope delivery to the
  // renderer sink (which retains it under its own lock before this is cleared).
  // Frame decode pacing is now owned by _VGClipReader.lastDeliveredBuffer
  // (Phase 7.11 RR-146) — not by these node-level fields.
  // Released on seek and invalidate.
  CVPixelBufferRef _lastDeliveredBuffer; // nullable; +1 (envelope lifetime)

  // Node-level frame reuse fields — kept for seekTo: reset path.
  // Phase 7.11 RR-146: actual decode pacing uses _VGClipReader per-reader cache.
  // These are reset on seek to ensure stale values do not poison the per-reader
  // cache after a reader rebuild.
  double _lastDeliveredAssetPTS;    // -1.0 when no cached frame
  double _lastDeliveredAssetDuration;

  // ── Generation (updated atomically on seekTo:generation:) ─────────────────
  // Captured at the start of each pullFrame:. Compared against
  // request.generation to detect stale requests across seeks.
  _Atomic(uint64_t) _generation;

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  // CAS gate: 0 → 1 on invalidate. Idempotent.
  atomic_int _invalidated;

  // ── Total timeline duration ───────────────────────────────────────────────
  // Pre-computed at prepare time: end time of the last clip.
  double _totalTimelineDuration;

  // ── Target canvas dimensions (Phase 7.9) ─────────────────────────────────
  // Non-zero: aspect-fit source frames into this canvas via layer instruction.
  // Zero (CGSizeZero): legacy bypass — forward asset-native buffers unchanged.
  CGSize _targetRenderSize;

  // ── Phase 7.18A: Frame cache + prefetch queue (DEC-151) ──────────────────
  // _frameCache: compositor-private, byte-budgeted (32 MB) LRU cache shared
  //   by the freeze-frame synchronous path and the async prefetch queue.
  //   Thread-safe internally via os_unfair_lock.
  // _prefetchQueue: serial background queue for best-effort freeze prefetch.
  //   Serial (not concurrent) to bound memory and avoid file-handle contention
  //   when multiple freeze clips share the same source asset.
  _VGTimelineFrameCache *_frameCache;
  dispatch_queue_t _prefetchQueue;

  // ── Phase 7.20C: transient render mode ───────────────────────────────────
  // Set at the start of each pullFrame:, read by _buildReaderForClipIndex:.
  // Pull-queue-serial access only — no lock required.
  VGRenderMode _currentRenderMode;

  // ── Phase 7.23B (DEC-167): clip-local elapsed timeline time ────────────────
  // Set before each _pullBufferFromReader: call; read by that method to compute
  // the keyframe-interpolated transform when the resolved clip has a
  // transformTrack. Pull-queue-serial access only — no lock required.
  // 0.0 = clip's first frame on the timeline (post-trim, post-layout).
  double _currentElapsedTimeline;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Init
// ─────────────────────────────────────────────────────────────────────────────

+ (void)initialize {
  if (self == [VGTimelineCompositorNode class]) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      sTimelineLog =
          os_log_create("com.vanguard.engine", "VGTimelineCompositorNode");
    });
  }
}

- (nullable instancetype)
    initWithNodeId:(NSString *)nodeId
        parameters:(NSDictionary<NSString *, id> *)parameters
             ports:(NSArray<VGMediaPort *> *)ports
             error:(NSError *_Nullable __autoreleasing *)outError {
  NSParameterAssert(nodeId.length > 0);
  NSParameterAssert(parameters != nil);
  NSParameterAssert(ports != nil);

  // ── (a) Guard: descriptorStage ────────────────────────────────────────────
  // Reject Stage 7.4 non-executable descriptors. Require "7.5_executable".
  NSString *stage = parameters[kVGTCNDescriptorStageKey];
  if ([stage isEqualToString:kVGTCNDescriptorStage74]) {
    if (outError) {
      *outError = _VGTCNError(
          1, @"VGTimelineCompositorNode: rejected Stage 7.4 non-executable "
             @"descriptor. "
              "Set parameters[@\"descriptorStage\"] = @\"7.5_executable\" "
              "in VGEditorGraphFactory before instantiating this node.");
    }
    return nil;
  }
  if (![stage isEqualToString:kVGTCNDescriptorStage75]) {
    if (outError) {
      *outError = _VGTCNError(
          2,
          ([NSString
              stringWithFormat:
                  @"VGTimelineCompositorNode: unknown descriptorStage \"%@\". "
                   "Expected \"%@\".",
                  stage ?: @"<nil>", kVGTCNDescriptorStage75]));
    }
    return nil;
  }

  // ── (b) Deserialize clip descriptors ─────────────────────────────────────
  id rawClips = parameters[kVGTCNClipsKey];
  if (![rawClips isKindOfClass:[NSArray class]] ||
      ((NSArray *)rawClips).count == 0) {
    if (outError) {
      *outError = _VGTCNError(3, @"VGTimelineCompositorNode: "
                                 @"parameters[\"clips\"] is missing or empty.");
    }
    return nil;
  }

  NSMutableArray<VGClipDescriptor *> *clips =
      [NSMutableArray arrayWithCapacity:((NSArray *)rawClips).count];
  for (id rawClip in (NSArray *)rawClips) {
    if (![rawClip isKindOfClass:[NSDictionary class]]) {
      if (outError) {
        *outError = _VGTCNError(
            4, @"VGTimelineCompositorNode: clip entry in parameters[\"clips\"] "
                "is not a dictionary.");
      }
      return nil;
    }
    VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:rawClip];
    if (!clip) {
      if (outError) {
        *outError = _VGTCNError(
            5, @"VGTimelineCompositorNode: failed to deserialize a "
               @"VGClipDescriptor "
                "from parameters[\"clips\"]. Entry may be malformed or violate "
                "validation constraints.");
      }
      return nil;
    }
    [clips addObject:clip];
  }

  // ── (c) Stage 7.5B: reject unsupported media kinds ──────────────────────────
  // Phase 7.12 (DEC-145): VGClipMediaKindImage is now accepted alongside
  // VGClipMediaKindVideo. Audio and unknown kinds are still rejected explicitly.
  for (NSUInteger i = 0; i < clips.count; i++) {
    VGClipDescriptor *clip = clips[i];
    if (clip.mediaKind != VGClipMediaKindVideo &&
        clip.mediaKind != VGClipMediaKindImage) {
      NSString *kindDesc;
      switch (clip.mediaKind) {
      case VGClipMediaKindAudio:
        kindDesc = @"audio";
        break;
      case VGClipMediaKindUnknown:
        kindDesc = @"unknown";
        break;
      default:
        kindDesc = @"unsupported";
        break;
      }
      if (outError) {
        *outError = _VGTCNError(
            6, ([NSString
                   stringWithFormat:
                       @"VGTimelineCompositorNode: clips[%lu] (id=%@) has "
                        "unsupported mediaKind \"%@\". "
                        "Supported: VGClipMediaKindVideo, VGClipMediaKindImage. "
                        "Audio timelines are Phase 8+.",
                       (unsigned long)i, clip.clipId, kindDesc]));
      }
      return nil;
    }
  }

  // ── (c2) Phase 7.x-Q1: detect dual-camera descriptor per clip ───────────────
  //
  // The Dart VGClipDescriptor.toMap() embeds 'dualCamera' (a secondary-only
  // map) under each clip dict when the clip carries a VGDualCameraDescriptor.
  //
  // Q1 contract:
  //   - A clip dict WITHOUT 'dualCamera': exact existing behavior (no change).
  //   - A clip dict WITH 'dualCamera' that is a valid NSDictionary:
  //       • Accepted without error.
  //       • The clip is parsed as primary (enclosing VGClipDescriptor).
  //       • The nested dict is stored per-clip for future Q2 secondary reader.
  //       • Visual output: primary clip only (single-stream), exactly as if
  //         dualCamera were absent. No rendering difference in Q1.
  //   - A clip dict WITH 'dualCamera' that is NOT a dictionary:
  //       • Rejected at init time (malformed payload guard).
  //
  // RR-162 note: when Q2 builds the secondary reader, double CVPixelBuffer
  // memory will be held during composition. Monitor via estimatedRetainedBufferBytes.
  //
  // Implementation: rawClips is the original array from the parameters dict.
  // We iterate it in parallel with the deserialized clips array to read the
  // raw NSDictionary entry for each clip (VGClipDescriptor does not carry
  // the unrecognised 'dualCamera' key — we preserve it here separately).
  NSMutableArray<NSDictionary *> *dualCameraDescDicts =
      [NSMutableArray arrayWithCapacity:clips.count];
  NSArray *rawClipsArray = (NSArray *)rawClips; // safe: already type-checked above
  for (NSUInteger i = 0; i < clips.count; i++) {
    NSDictionary *rawClip = rawClipsArray[i]; // already validated as NSDictionary
    id rawDualCamera = rawClip[kVGTCNDualCameraKey];
    if (rawDualCamera == nil) {
      // Normal single-stream clip. Store NSNull as sentinel.
      [dualCameraDescDicts addObject:(NSDictionary *)[NSNull null]];
    } else if (![rawDualCamera isKindOfClass:[NSDictionary class]]) {
      // dualCamera key is present but not a dictionary — malformed payload.
      if (outError) {
        *outError = _VGTCNError(
            30,
            ([NSString
                 stringWithFormat:
                     @"VGTimelineCompositorNode (Phase 7.x-Q1): clips[%lu] (id=%@): "
                      "'dualCamera' key is present but is not a dictionary. "
                      "Expected Map<String,Object?> from VGDualCameraDescriptor.toTimelineMap().",
                     (unsigned long)i,
                     ((VGClipDescriptor *)clips[i]).clipId]));
      }
      return nil;
    } else {
      // Valid dual-camera descriptor dict. Store for Q2 secondary reader.
      [dualCameraDescDicts addObject:(NSDictionary *)rawDualCamera];
      os_log(sTimelineLog,
             "[VGTCNode-Q1] clips[%lu] (id=%{public}@): dual-camera descriptor present "
             "(layoutMode=%{public}@). Primary renders as single clip until Q2.",
             (unsigned long)i,
             ((VGClipDescriptor *)clips[i]).clipId,
             rawDualCamera[@"layoutMode"] ?: @"<nil>");
    }
  }
  // _dualCameraDescDicts is stored for Q2 consumption. In Q1 it is held but
  // not acted upon during pullFrame:. Stored after [super init] below.

  // ── (d) Deserialize transition descriptors ────────────────────────────────
  id rawTransitions = parameters[kVGTCNTransitionsKey];
  NSMutableArray<VGTransitionDescriptor *> *transitions =
      [NSMutableArray array];
  if ([rawTransitions isKindOfClass:[NSArray class]]) {
    for (id rawTransition in (NSArray *)rawTransitions) {
      if (![rawTransition isKindOfClass:[NSDictionary class]]) {
        if (outError) {
          *outError = _VGTCNError(
              7, @"VGTimelineCompositorNode: transition entry in "
                  "parameters[\"transitions\"] is not a dictionary.");
        }
        return nil;
      }
      VGTransitionDescriptor *t =
          [VGTransitionDescriptor fromDictionary:rawTransition];
      if (!t) {
        if (outError) {
          *outError = _VGTCNError(
              8, @"VGTimelineCompositorNode: failed to deserialize a "
                  "VGTransitionDescriptor. Entry may be malformed.");
        }
        return nil;
      }
      [transitions addObject:t];
    }
  }

  // ── (e) Phase 7.10: validate non-hard-cut transition parameters ─────────────
  // The Stage 7.5 hard-cut-only rejection gate is lifted. Fade and dissolve
  // transitions are now executed by the dual-reader blend path in pullFrame:.
  // Each non-hard-cut transition is validated for:
  //   (1) durationSeconds > 0 (a dissolve with zero duration is a hard cut)
  //   (2) fromClipId and toClipId are non-nil
  //   (3) from/to IDs reference adjacent clips in ascending start-time order
  //   (4) overlap does not exceed min(outgoing, incoming) timelineDuration
  // Error code 12 is used for all init-time transition validation failures.
  // (Note: error code 12 is also used in _buildReaderForClipIndex: for invalid
  // sourceURL — same error domain, distinct execution paths.)
  for (NSUInteger i = 0; i < transitions.count; i++) {
    VGTransitionDescriptor *t = transitions[i];
    if (t.isHardCut) continue; // Hard cuts: no further validation required.

    // (1) Non-hard-cut transitions must have durationSeconds > 0.
    if (t.durationSeconds <= 0.0) {
      if (outError) {
        *outError = _VGTCNError(
            12, ([NSString
                     stringWithFormat:
                         @"VGTimelineCompositorNode: transitions[%lu] (id=%@): "
                          "non-hard-cut transition must have durationSeconds > 0 "
                          "(got %.3fs).",
                         (unsigned long)i, t.transitionId,
                         t.durationSeconds]));
      }
      return nil;
    }

    // (2) Both clip IDs must be non-nil for the blend path to locate clips.
    if (!t.fromClipId || !t.toClipId) {
      if (outError) {
        *outError = _VGTCNError(
            12, ([NSString
                     stringWithFormat:
                         @"VGTimelineCompositorNode: transitions[%lu] (id=%@): "
                          "non-hard-cut transition requires non-nil fromClipId "
                          "and toClipId.",
                         (unsigned long)i, t.transitionId]));
      }
      return nil;
    }

    // (3) from/to must reference adjacent clips in the sorted order.
    NSUInteger fromIdx = NSNotFound, toIdx = NSNotFound;
    for (NSUInteger j = 0; j < clips.count; j++) {
      if ([clips[j].clipId isEqualToString:t.fromClipId]) fromIdx = j;
      if ([clips[j].clipId isEqualToString:t.toClipId])   toIdx   = j;
    }
    if (fromIdx == NSNotFound || toIdx == NSNotFound || toIdx != fromIdx + 1) {
      if (outError) {
        *outError = _VGTCNError(
            12, ([NSString
                     stringWithFormat:
                         @"VGTimelineCompositorNode: transitions[%lu] (id=%@): "
                          "fromClipId=%@ and toClipId=%@ must reference "
                          "adjacent clips in ascending start-time order.",
                         (unsigned long)i, t.transitionId,
                         t.fromClipId, t.toClipId]));
      }
      return nil;
    }

    // (4) Overlap must not exceed either clip's timelineDuration.
    VGClipDescriptor *fromClip = clips[fromIdx];
    VGClipDescriptor *toClip   = clips[toIdx];
    double minDur = MIN(fromClip.timelineDuration, toClip.timelineDuration);
    if (t.durationSeconds > minDur) {
      if (outError) {
        *outError = _VGTCNError(
            12, ([NSString
                     stringWithFormat:
                         @"VGTimelineCompositorNode: transitions[%lu] (id=%@): "
                          "durationSeconds (%.3fs) exceeds the shorter clip's "
                          "timelineDuration (%.3fs).",
                         (unsigned long)i, t.transitionId,
                         t.durationSeconds, minDur]));
      }
      return nil;
    }
  }

  // ── (f) Store state ───────────────────────────────────────────────────────
  self = [super init];
  if (!self)
    return nil;

  _nodeId = [nodeId copy];
  _ports = [ports copy];
  _clips = [clips copy];
  _transitions = [transitions copy];
  // Phase 7.x-Q1: store dual-camera descriptor dicts for Q2 secondary reader.
  _dualCameraDescDicts = [dualCameraDescDicts copy];

  // Phase 7.x-Q3B: Parse layout configs once from the same source array.
  // This avoids any NSDictionary parsing overhead during pullFrame:.
  {
    NSMutableArray<NSValue *> *layoutConfigs =
        [NSMutableArray arrayWithCapacity:dualCameraDescDicts.count];
    for (id rawDC in dualCameraDescDicts) {
      _VGTCNDualCameraLayoutConfig cfg = _VGTCNParseLayoutConfig(rawDC);
      [layoutConfigs addObject:[NSValue value:&cfg
                                 withObjCType:@encode(_VGTCNDualCameraLayoutConfig)]];
    }
    _dualCameraLayoutConfigs = [layoutConfigs copy];
  }

  _lastDeliveredBuffer = NULL;
  _activeReader = nil;
  _outgoingReader = nil;              // Phase 7.10: non-nil only in transition windows
  // [7.5C] Frame reuse tracking: -1 signals "no cached frame".
  _lastDeliveredAssetPTS = -1.0;
  _lastDeliveredAssetDuration = 0.0;
  atomic_store(&_generation, 0);
  atomic_store(&_invalidated, 0);

  // Phase 7.18A: initialise frame cache and prefetch queue.
  _frameCache     = [[_VGTimelineFrameCache alloc] init];
  _prefetchQueue  = dispatch_queue_create("com.vanguard.timeline.prefetch",
                                          DISPATCH_QUEUE_SERIAL);

  // ── Phase 7.9: Parse canvas dimensions for aspect-fit normalization ────────
  // canvasWidth/canvasHeight are optional. When present and both > 0, the
  // compositor will override AVMutableVideoComposition.renderSize and apply
  // an aspect-fit layer instruction in _buildReaderForClipIndex:.
  // When absent or zero (legacy playground / smoke tests), buffers are
  // forwarded at the asset's native display size (backward compatible).
  NSNumber *cw = parameters[kVGTCNCanvasWidthKey];
  NSNumber *ch = parameters[kVGTCNCanvasHeightKey];
  if (cw && ch && cw.intValue > 0 && ch.intValue > 0) {
    _targetRenderSize = CGSizeMake(cw.intValue, ch.intValue);
  } else {
    _targetRenderSize = CGSizeZero;
  }

  // Pre-compute total timeline duration from the last clip's end.
  // Used for EOS detection.
  VGClipDescriptor *lastClip = _clips.lastObject;
  _totalTimelineDuration =
      lastClip.startTimeSeconds + lastClip.timelineDuration;

  os_log(sTimelineLog,
         "[VGTCNode] init: nodeId=%{public}@ clips=%lu totalDuration=%.3fs canvas=%.0fx%.0f",
         _nodeId, (unsigned long)_clips.count, _totalTimelineDuration,
         _targetRenderSize.width, _targetRenderSize.height);

  return self;
}

- (void)dealloc {
  [self invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — Identity
// ─────────────────────────────────────────────────────────────────────────────

- (NSString *)nodeId {
  return _nodeId;
}
- (NSString *)nodeClass {
  return @"VGTimelineCompositorNode";
}

/// Returns VGNodeRoleCompositor to match the topology descriptor role (§6.5).
/// The node conforms to <VGSourceNode> for self-sourcing pull-mode execution.
/// Schedulers must use the Phase 7 self-sourcing-compositor fallback (MOD-1)
/// to discover this node when no VGNodeRoleSource node exists in the graph.
- (VGNodeRole)nodeRole {
  return VGNodeRoleCompositor;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — Port declaration
// ─────────────────────────────────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
  return _ports;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — Format negotiation
// ─────────────────────────────────────────────────────────────────────────────

- (nullable VGMediaFormat *)
    negotiateFormatForPort:(NSString *)portId
              inputFormats:
                  (NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
  // Self-sourcing: no input formats. Output format declared as 32BGRA.
  // Actual width/height is clip-native; use 0 for "source native" per
  // VGMediaFormat.h.
  if ([portId isEqualToString:@"video_out"]) {
    return [VGMediaFormat videoFormatWithPixelFormat:kCVPixelFormatType_32BGRA
                                               width:0
                                              height:0];
  }
  return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — V2 Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError *_Nullable))completion {
  // Capture graph generation from context.
  uint64_t gen = context.generation;
  atomic_store(&_generation, gen);

  // No async work needed at prepare time for the first slice.
  // Readers are built lazily in pullFrame: (on first access or after seek).
  // This is safe because VGExportScheduler calls pullFrame: on its serial
  // queue, and VGGraphSchedulerV2 calls it on its pull queue — no concurrent
  // access.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    os_log(sTimelineLog,
           "[VGTCNode] prepared: nodeId=%{public}@ generation=%llu",
           self->_nodeId, (unsigned long long)gen);
    if (completion)
      completion(nil);
  });
}

- (void)invalidate {
  // CAS gate: only first caller proceeds. Idempotent after that.
  int expected = 0;
  if (!atomic_compare_exchange_strong(&_invalidated, &expected, 1)) {
    return;
  }

  // Cancel and nil both readers (RR-142: outgoing reader must be torn down on invalidate).
  [self _tearDownOutgoingReader];
  [self _tearDownActiveReader];

  // Release last delivered buffer (RR-36).
  if (_lastDeliveredBuffer) {
    CVPixelBufferRelease(_lastDeliveredBuffer);
    _lastDeliveredBuffer = NULL;
  }

  // Phase 7.18A: flush all cached frames on invalidate.
  [_frameCache flushAll];

  os_log(sTimelineLog, "[VGTCNode] invalidated: nodeId=%{public}@", _nodeId);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSourceNode — Push-mode (no-ops; this is a pull-only node)
// ─────────────────────────────────────────────────────────────────────────────

- (void)startProducing {
  // No-op. VGTimelineCompositorNode is pull-only (VGClockPolicyHybrid).
  // VGGraphSchedulerV2 uses pullFrame:, not push callbacks, for hybrid-clock
  // mode.
}

- (void)stopProducing {
  // No-op. Pull-only source; no push callback to cancel.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSourceNode — Seek
// ─────────────────────────────────────────────────────────────────────────────

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
  // ── 1. Update generation FIRST (atomic) ───────────────────────────────────
  // Any in-flight pullFrame: with the old generation will return .skipped
  // once it checks _generation vs. request.generation.
  atomic_store(&_generation, generation);

  // Phase 7.18A: evict stale-generation cache entries immediately after
  // updating the generation counter. Any in-flight prefetch that captures the
  // old generation will detect the mismatch and discard its result.
  [_frameCache flushForGeneration:generation];

  // ── 2. Release held buffer before tearing down reader (RR-36) ────────────
  if (_lastDeliveredBuffer) {
    CVPixelBufferRelease(_lastDeliveredBuffer);
    _lastDeliveredBuffer = NULL;
  }

  // [7.5C] Reset frame reuse cache — seek invalidates any cached frame.
  _lastDeliveredAssetPTS = -1.0;
  _lastDeliveredAssetDuration = 0.0;

  // ── 3. Tear down the current reader ───────────────────────────────────────
  // AVAssetReader is forward-only; it cannot seek. Must cancel and rebuild
  // on next pullFrame: call. We do NOT rebuild here to avoid blocking seekTo:
  // — the rebuild happens lazily in pullFrame:.
  [self _tearDownOutgoingReader]; // Phase 7.10: tear down outgoing reader on seek
  [self _tearDownActiveReader];

  os_log(sTimelineLog, "[VGTCNode] seekTo: %.3fs generation=%llu",
         CMTIME_IS_VALID(time) ? CMTimeGetSeconds(time) : -1.0,
         (unsigned long long)generation);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Time-remap PTS mapping helper (Phase 7.22B / DEC-165)
// ─────────────────────────────────────────────────────────────────────────────

/// Maps an elapsed timeline duration (seconds since clip start) to the
/// asset-local decode PTS for the given clip.
///
/// When clip.timeRemap is present and has valid segments, segments define
/// the source-time mapping via piecewise-constant speed. clip.speed and
/// clip.isReversed are ignored (timeRemap supersedes both).
///
/// When clip.timeRemap is absent, falls back to the legacy formula:
///   Forward: trimStartSeconds + elapsedTimeline * clip.speed
///   Reverse: trimEndSeconds   - elapsedTimeline * clip.speed
///   Both clamped to [trimStartSeconds, trimEndSeconds].
///
/// This helper is called for the primary active clip and the outgoing
/// transition clip. Secondary dual-camera clips continue using the legacy
/// path directly (timeRemap on secondary clips is deferred to Phase 7.22C+).
static double VGComputeAssetTime(VGClipDescriptor *clip, double elapsedTimeline) {
    VGTimeRemapDescriptor *remap = clip.timeRemap;
    if (remap != nil && remap.segments.count > 0) {
        // ── Time-remap path ────────────────────────────────────────────────
        // Walk segments in order, accumulating timeline duration consumed
        // by each segment. When elapsedTimeline falls inside a segment,
        // compute the source time within that segment.
        double timelineCursor = 0.0;
        for (VGSpeedSegmentDescriptor *seg in remap.segments) {
            double segTimelineDur = seg.sourceDuration / seg.speedMultiplier;
            if (elapsedTimeline <= timelineCursor + segTimelineDur) {
                // elapsedTimeline falls inside this segment.
                double elapsedInSeg = elapsedTimeline - timelineCursor;
                return seg.sourceStartTime + elapsedInSeg * seg.speedMultiplier;
            }
            timelineCursor += segTimelineDur;
        }
        // elapsedTimeline is past all segments — clamp to end of last segment.
        VGSpeedSegmentDescriptor *lastSeg = remap.segments.lastObject;
        return lastSeg.sourceStartTime + lastSeg.sourceDuration; // = sourceEndTime
    }

    // ── Legacy path (no timeRemap) ─────────────────────────────────────────
    // Phase 7.19 (DEC-154): Reverse playback support.
    // Forward: trimStartSeconds + elapsedAsset
    // Reverse: trimEndSeconds   - elapsedAsset
    // Both clamped to [trimStartSeconds, trimEndSeconds] for float safety.
    double elapsedAsset = elapsedTimeline * clip.speed;
    double tAsset;
    if (clip.isReversed) {
        tAsset = clip.trimEndSeconds - elapsedAsset;
    } else {
        tAsset = clip.trimStartSeconds + elapsedAsset;
    }
    tAsset = MAX(tAsset, clip.trimStartSeconds);
    tAsset = MIN(tAsset, clip.trimEndSeconds);
    return tAsset;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSourceNode — Pull-mode
// ─────────────────────────────────────────────────────────────────────────────

- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
  // ── Guard 1: invalidated ──────────────────────────────────────────────────
  if (atomic_load(&_invalidated)) {
    return [VGFrameResult
        errorResult:_VGTCNError(10, @"VGTimelineCompositorNode: pullFrame: "
                                    @"called after invalidate.")
         generation:request.generation];
  }

  // ── Guard 2: cancelled ────────────────────────────────────────────────────
  if (request.isCancelled) {
    return [VGFrameResult skippedWithGeneration:request.generation];
  }

  // ── Guard 3: generation mismatch ─────────────────────────────────────────
  // Capture _generation atomically once at the start of this pull.
  // If a concurrent seekTo:generation: changes it, we detect staleness here
  // or after the expensive AVAssetReader operations below.
  uint64_t capturedGeneration = atomic_load(&_generation);
  if (request.generation != capturedGeneration) {
    return [VGFrameResult skippedWithGeneration:request.generation];
  }

  // Phase 7.20C: capture render mode so _buildReaderForClipIndex: can gate the
  // sidecar reader swap. Set here once per pullFrame: before any reader build.
  // VGRenderModeExport (VGExportScheduler path) bypasses the sidecar swap;
  // VGRenderModePreview uses the sidecar when ready.
  _currentRenderMode = request.mode;

  // ── Compute requested global PTS in seconds ───────────────────────────────
  double requestedPTSSecs = 0.0;
  if (CMTIME_IS_VALID(request.requestedPTS)) {
    requestedPTSSecs = CMTimeGetSeconds(request.requestedPTS);
  }

  // ── EOS check: PTS is past or equal to total timeline duration ────────────
  // Use >= to handle floating point boundary of the last frame.
  if (requestedPTSSecs >= _totalTimelineDuration &&
      _totalTimelineDuration > 0.0) {
    os_log(sTimelineLog,
           "[VGTCNode] EOS: requestedPTS=%.3fs >= totalDuration=%.3fs",
           requestedPTSSecs, _totalTimelineDuration);
    return [VGFrameResult endOfStreamWithGeneration:request.generation];
  }

  // ── Find active clip ──────────────────────────────────────────────────────
  // A clip is active when:
  //   requestedPTSSecs >= clip.startTimeSeconds
  //   requestedPTSSecs <  clip.startTimeSeconds + clip.timelineDuration
  //
  // The clip array is sorted ascending by startTimeSeconds.
  //
  // Phase 7.10: Iterate BACKWARDS (last → first) so that when two clip ranges
  // overlap during a transition window, the incoming (later-index) clip is
  // selected first. This is required for correct transition detection:
  //   Clip A: [0.0, 5.0),  Clip B: [4.0, 9.63)
  //   Overlap: [4.0, 5.0)  → forward loop picks index 0 (Clip A) first,
  //     making `activeClipIndex > 0` false → transition branch never fires.
  //   Backward loop picks index 1 (Clip B) first → transition detection runs.
  // NSInteger avoids unsigned underflow when decrementing past 0.
  NSUInteger activeClipIndex = NSNotFound;
  for (NSInteger i = (NSInteger)_clips.count - 1; i >= 0; i--) {
    VGClipDescriptor *clip = _clips[(NSUInteger)i];
    double clipStart = clip.startTimeSeconds;
    double clipEnd = clipStart + clip.timelineDuration;

    // Final clip: allow exact end boundary to extend EOS detection below.
    // Checked before the range test so PTS at exact end of last clip is caught.
    if ((NSUInteger)i == _clips.count - 1 && requestedPTSSecs >= clipStart) {
      activeClipIndex = (NSUInteger)i;
      break;
    }

    if (requestedPTSSecs >= clipStart && requestedPTSSecs < clipEnd) {
      activeClipIndex = (NSUInteger)i;
      break;
    }
  }

  if (activeClipIndex == NSNotFound) {
    // Gap in timeline (PTS between clips). Return skip — no stale frame.
    os_log(sTimelineLog,
           "[VGTCNode] timeline gap at requestedPTS=%.3fs — skipping",
           requestedPTSSecs);
    return [VGFrameResult skippedWithGeneration:request.generation];
  }

  VGClipDescriptor *activeClip = _clips[activeClipIndex];

  // ── Phase 7.10: Transition window detection ──────────────────────────────
  // When the incoming clip has a non-hard-cut transition from the preceding
  // clip, the overlap window is:
  //   [activeClip.startTimeSeconds, activeClip.startTimeSeconds + T]
  // During this window _outgoingReader decodes the outgoing clip and
  // _activeReader decodes the incoming clip; frames are blended (DEC-143).
  BOOL inTransitionWindow = NO;
  double transitionElapsed = 0.0;
  double transitionDuration = 0.0;
  VGTransitionType transitionType = VGTransitionTypeNone;
  NSUInteger outgoingClipIndex = NSNotFound;
  if (activeClipIndex > 0) {
    VGClipDescriptor *prevClip = _clips[activeClipIndex - 1];
    for (VGTransitionDescriptor *t in _transitions) {
      if (t.isHardCut) continue;
      if ([t.fromClipId isEqualToString:prevClip.clipId] &&
          [t.toClipId isEqualToString:activeClip.clipId]) {
        double elapsed = requestedPTSSecs - activeClip.startTimeSeconds;
        if (elapsed >= 0.0 && elapsed <= t.durationSeconds) {
          inTransitionWindow = YES;
          transitionElapsed = elapsed;
          transitionDuration = t.durationSeconds;
          transitionType = t.type;
          outgoingClipIndex = activeClipIndex - 1;
        }
        break;
      }
    }
  }

  // ── Compute asset-local decode PTS ────────────────────────────────────────
  // Phase 7.22B (DEC-165): VGComputeAssetTime encapsulates both the legacy
  // speed/isReversed path and the new timeRemap piecewise-constant path.
  // freezePTS remains a downstream override applied below, after this mapping.
  double elapsedTimeline = requestedPTSSecs - activeClip.startTimeSeconds;
  double tAsset = VGComputeAssetTime(activeClip, elapsedTimeline);

  // Phase 7.23B (DEC-167): Store clip-local elapsed time so _pullBufferFromReader:
  // can read it when applying keyframe-interpolated transforms.
  // Clamped to >= 0 defensively (requestedPTSSecs could theoretically undershoot).
  _currentElapsedTimeline = MAX(0.0, elapsedTimeline);

  // ── Ensure the correct clip reader is active ──────────────────────────────
  // If the active clip changed since the last pullFrame:, tear down the
  // previous reader and prepare to build a new one for the new clip.
  if (_activeReader && _activeReader.clipIndex != activeClipIndex) {
    // [7.5C] Reset frame reuse cache on clip switch to prevent returning
    // the previous clip's frame for the new clip's asset PTS range.
    _lastDeliveredAssetPTS = -1.0;
    _lastDeliveredAssetDuration = 0.0;
    [self _tearDownActiveReader];
  }

  // Phase 7.10: Tear down outgoing reader when no longer in a transition window.
  if (!inTransitionWindow && _outgoingReader) {
    [self _tearDownOutgoingReader];
  }

  // Build reader if needed (first access or after seek/clip-switch).
  if (!_activeReader) {
    NSError *buildError = nil;
    _activeReader = [self _buildReaderForClipIndex:activeClipIndex
                                       startAtTime:tAsset
                                             error:&buildError];
    if (!_activeReader) {
      os_log_error(sTimelineLog,
                   "[VGTCNode] failed to build reader for clip %lu: %{public}@",
                   (unsigned long)activeClipIndex,
                   buildError.localizedDescription);
      return [VGFrameResult errorResult:buildError
                             generation:request.generation];
    }
  }

  // Phase 7.10: Build outgoing reader for the transition window when needed.
  // The outgoing clip is clips[outgoingClipIndex]; its reader must start at the
  // asset-local time corresponding to the current global PTS (not time 0).
  if (inTransitionWindow) {
    if (!_outgoingReader || _outgoingReader.clipIndex != outgoingClipIndex) {
      [self _tearDownOutgoingReader];
      VGClipDescriptor *outgoingClip = _clips[outgoingClipIndex];
      double elapsedOut = requestedPTSSecs - outgoingClip.startTimeSeconds;
      // Phase 7.22B (DEC-165): use VGComputeAssetTime for outgoing clip.
      double tAssetOut = VGComputeAssetTime(outgoingClip, elapsedOut);
      NSError *outBuildErr = nil;
      _outgoingReader = [self _buildReaderForClipIndex:outgoingClipIndex
                                           startAtTime:tAssetOut
                                                 error:&outBuildErr];
      if (!_outgoingReader) {
        os_log_error(sTimelineLog,
                     "[VGTCNode] transition: failed to build outgoing reader "
                     "clip %lu: %{public}@",
                     (unsigned long)outgoingClipIndex,
                     outBuildErr.localizedDescription);
        return [VGFrameResult errorResult:outBuildErr
                               generation:request.generation];
      }
    }
  }

  // ── Guard: check for generation change after expensive reader build ────────
  // A seek may have arrived while we were building the reader.
  if (request.isCancelled || atomic_load(&_generation) != capturedGeneration) {
    return [VGFrameResult skippedWithGeneration:request.generation];
  }

  // ── Phase 7.10: Transition blend path ─────────────────────────────────────
  // During a transition window pull from both _outgoingReader (outgoing clip)
  // and _activeReader (incoming clip) then blend via CoreImage.
  //
  // Phase 7.11 RR-146: Both readers now use -_pullBufferFromReader:atAssetTime:error:
  // which enforces per-reader frame reuse. This prevents the 60/120 Hz
  // CADisplayLink from consuming transition frames faster than the source clip
  // frame rate, which previously caused premature AVAssetReader exhaustion.
  // Blend failure returns errorResult — no silent masking (DEC-143).
  if (inTransitionWindow) {
    // Release node-level last delivered buffer; the blend will produce a new one.
    if (_lastDeliveredBuffer) {
      CVPixelBufferRelease(_lastDeliveredBuffer);
      _lastDeliveredBuffer = NULL;
    }

    float blendAlpha = (transitionDuration > 0.0)
        ? (float)(transitionElapsed / transitionDuration)
        : 1.0f;

    // Compute outgoing clip asset-local time.
    // Phase 7.22B (DEC-165): use VGComputeAssetTime for the outgoing clip.
    VGClipDescriptor *outgoingClipDesc = _clips[outgoingClipIndex];
    double elapsedOut = requestedPTSSecs - outgoingClipDesc.startTimeSeconds;
    double tAssetOut = VGComputeAssetTime(outgoingClipDesc, elapsedOut);

    // Phase 7.23B (DEC-167): Store outgoing clip-local elapsed time for
    // keyframe-interpolated transform resolution in _pullBufferFromReader:.
    // The primary elapsedTimeline is set above; override with outgoing value
    // immediately before the outgoing pull, then restore for incoming pull.
    double savedElapsedTimeline = _currentElapsedTimeline;
    _currentElapsedTimeline = MAX(0.0, elapsedOut);

    // Pull outgoing frame with per-reader reuse guard + Phase 7.11 / 7.23B transform.
    NSError *outErr = nil;
    CVPixelBufferRef outPB = [self _pullBufferFromReader:_outgoingReader
                                             atAssetTime:tAssetOut
                                                   error:&outErr];

    // Restore primary elapsed for the incoming (active) clip pull.
    _currentElapsedTimeline = savedElapsedTimeline;

    // Pull incoming frame with per-reader reuse guard + Phase 7.11 / 7.23B transform.
    NSError *inErr = nil;
    CVPixelBufferRef inPB = [self _pullBufferFromReader:_activeReader
                                            atAssetTime:tAsset
                                                  error:&inErr];

    CVPixelBufferRef blendedPB = NULL;

    if (inPB && outPB) {
      // Both readers delivered: blend the (already transformed) buffers.
      NSError *blendErr = nil;
      blendedPB = _VGTCNBlendBuffers(outPB, inPB, transitionType,
                                     blendAlpha, &blendErr);
      if (!blendedPB) {
        // Blend failure — report error; do not silently substitute a frame.
        CVPixelBufferRelease(inPB);
        CVPixelBufferRelease(outPB);
        os_log_error(
            sTimelineLog,
            "[VGTCNode] blend error clip %lu→%lu alpha=%.3f: %{public}@",
            (unsigned long)outgoingClipIndex,
            (unsigned long)activeClipIndex, blendAlpha,
            blendErr.localizedDescription);
        return [VGFrameResult errorResult:blendErr
                               generation:request.generation];
      }
    } else if (inPB && !outPB) {
      // Outgoing reader exhausted early — deliver incoming frame unblended.
      [self _tearDownOutgoingReader];
      blendedPB = inPB;
      inPB = NULL; // ownership transferred to blendedPB
    } else if (outPB && !inPB) {
      if (inErr) {
        // Incoming reader error — report it.
        CVPixelBufferRelease(outPB);
        os_log_error(sTimelineLog,
                     "[VGTCNode] transition: incoming reader error clip %lu: %{public}@",
                     (unsigned long)activeClipIndex,
                     inErr.localizedDescription);
        return [VGFrameResult errorResult:inErr generation:request.generation];
      }
      // Incoming reader not yet ready — deliver outgoing frame unblended.
      blendedPB = outPB;
      outPB = NULL; // ownership transferred
    } else {
      // Both readers exhausted — skip this frame.
      return [VGFrameResult skippedWithGeneration:request.generation];
    }

    if (inPB)  CVPixelBufferRelease(inPB);
    if (outPB) CVPixelBufferRelease(outPB);

    // Store blended buffer for node-level envelope lifetime (RR-36).
    // Per-reader caches own decode pacing; node-level field is only for
    // extending the blended buffer lifetime through the envelope delivery.
    _lastDeliveredBuffer = blendedPB;

    CMTime outputDur =
        CMTimeMakeWithSeconds(1.0 / _activeReader.sourceFPS, 600);

    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.mediaType = VGMediaTypeVideo;
    env.payload.videoBuffer = (void *)blendedPB; // +0 in envelope; node holds +1
    env.pts = request.requestedPTS;
    env.dts = kCMTimeInvalid;
    env.duration = outputDur;
    env.generation = request.generation;
    env.metadata = NULL;

    os_log_debug(sTimelineLog,
                 "[VGTCNode] transition delivered: clip %lu→%lu "
                 "alpha=%.3f type=%ld",
                 (unsigned long)outgoingClipIndex,
                 (unsigned long)activeClipIndex,
                 blendAlpha, (long)transitionType);

    return [VGFrameResult deliveredWithEnvelope:env
                                     generation:request.generation];
  }

  // ── Normal single-reader path (non-transition) ────────────────────────────
  // Phase 7.11 RR-146: Use per-reader frame reuse helper.
  // This replaces the former node-level _lastDeliveredBuffer reuse guard
  // and the inline copyNextSampleBuffer + transform blocks.
  //
  // Release node-level buffer before pulling: the per-reader cache now owns
  // decode pacing; the node-level field exists only to extend envelope lifetime.
  if (_lastDeliveredBuffer) {
    CVPixelBufferRelease(_lastDeliveredBuffer);
    _lastDeliveredBuffer = NULL;
  }

  NSError *pullErr = nil;
  CVPixelBufferRef pb = [self _pullBufferFromReader:_activeReader
                                         atAssetTime:tAsset
                                               error:&pullErr];

  if (!pb) {
    if (pullErr) {
      // Error from reader or transform.
      return [VGFrameResult errorResult:pullErr generation:request.generation];
    }
    // Phase 7.12: Static image readers never return NULL without pullErr.
    // Guard against accessing nil reader.status for static source readers.
    if (_activeReader.isStaticSource) {
      return [VGFrameResult skippedWithGeneration:request.generation];
    }
    // NULL without error: reader completed (EOS) or unknown status.
    AVAssetReaderStatus status = _activeReader.reader.status;
    if (status == AVAssetReaderStatusCompleted) {
      os_log(sTimelineLog,
             "[VGTCNode] clip %lu reader completed at requestedPTS=%.3fs",
             (unsigned long)activeClipIndex, requestedPTSSecs);
      if (activeClipIndex >= _clips.count - 1) {
        return [VGFrameResult endOfStreamWithGeneration:request.generation];
      }
      // Not last clip — return skip. Scheduler will request next PTS which
      // falls in the next clip, building a new reader.
      return [VGFrameResult skippedWithGeneration:request.generation];
    } else if (status == AVAssetReaderStatusFailed) {
      NSError *readerErr =
          _activeReader.reader.error
              ?: _VGTCNError(11,
                             @"VGTimelineCompositorNode: AVAssetReader failed "
                              "with unknown error.");
      return [VGFrameResult errorResult:readerErr
                             generation:request.generation];
    }
    // Defensive: unknown status — treat as skip.
    return [VGFrameResult skippedWithGeneration:request.generation];
  }

  // Store for node-level envelope lifetime (RR-36).
  _lastDeliveredBuffer = pb;

  // ── Phase 7.x-Q2: Secondary reader lockstep pull ─────────────────────────
  //
  // If this primary clip has a secondary reader (dual-camera), advance it
  // in lockstep with the primary. Q2 output remains the primary buffer only;
  // the secondary buffer is immediately released (caller's +1), but the
  // secondary reader's lastDeliveredBuffer retains its own +1 for Q3
  // composition. Seek/clip-switch/invalidate cleanup cascades automatically
  // through _activeReader → secondaryClipReader dealloc.
  //
  // Time mapping (Opus Q2 correction):
  //   elapsedTimeline = requestedPTSSecs - primaryClip.startTimeSeconds
  //   secSpeed        = secondaryClip.speed (clamped to > 0)
  //   t_sec_asset     = secondaryClip.trimStartSeconds + elapsedTimeline * secSpeed
  //   t_sec_asset     = clamp(t_sec_asset, trimStartSeconds, trimEndSeconds)
  if (_activeReader.secondaryClipReader != nil &&
      !_activeReader.secondaryEOSReached) {
    // Retrieve the secondary clip descriptor from the stored dicts.
    // _dualCameraDescDicts[activeClipIndex] is validated non-nil (NSDictionary)
    // at reader build time; checking isKindOfClass here is a belt-and-suspenders
    // guard (should always be YES at this point).
    id rawDualCamera = (activeClipIndex < _dualCameraDescDicts.count)
        ? _dualCameraDescDicts[activeClipIndex]
        : nil;
    id rawSecondaryClip = [rawDualCamera isKindOfClass:[NSDictionary class]]
        ? ((NSDictionary *)rawDualCamera)[@"secondaryClip"]
        : nil;
    if ([rawSecondaryClip isKindOfClass:[NSDictionary class]]) {
      VGClipDescriptor *secondaryClip =
          [VGClipDescriptor fromDictionary:(NSDictionary *)rawSecondaryClip];
      if (secondaryClip) {
        // Phase 7.22B (DEC-165): secondary dual-camera clips continue using
        // the legacy speed-only mapping. timeRemap on secondary clips is
        // deferred to Phase 7.22C+ to keep this slice minimal and safe.
        double secSpeed = (secondaryClip.speed > 0.0) ? secondaryClip.speed : 1.0;
        double tSecAsset = secondaryClip.trimStartSeconds + elapsedTimeline * secSpeed;
        tSecAsset = MAX(tSecAsset, secondaryClip.trimStartSeconds);
        tSecAsset = MIN(tSecAsset, secondaryClip.trimEndSeconds);

        NSError *secPullErr = nil;
        CVPixelBufferRef secPB =
            [self _pullBufferFromReader:_activeReader.secondaryClipReader
                           atAssetTime:tSecAsset
                                 error:&secPullErr];
        if (secPB) {
          // Q2: discard caller's +1; secondary reader cache retains its own +1
          // via lastDeliveredBuffer for Q3 composition use.
          CVPixelBufferRelease(secPB);
          os_log_debug(sTimelineLog,
                       "[VGTCNode-Q2] secondary frame pulled: clip=%lu tSec=%.3fs",
                       (unsigned long)activeClipIndex, tSecAsset);
        } else if (!secPullErr) {
          // NULL without error: secondary reader exhausted (EOS).
          _activeReader.secondaryEOSReached = YES;
          os_log(sTimelineLog,
                 "[VGTCNode-Q2] secondary EOS: clip=%lu — future pulls skipped",
                 (unsigned long)activeClipIndex);
        } else {
          // Pull error: mark EOS on secondary to avoid repeated error attempts.
          _activeReader.secondaryEOSReached = YES;
          os_log_error(sTimelineLog,
                       "[VGTCNode-Q2] secondary pull error clip=%lu: %{public}@",
                       (unsigned long)activeClipIndex,
                       secPullErr.localizedDescription);
        }
      }
    }
  }

  // ── Phase 7.x-Q3B: Dual-camera composition ──────────────────────────────────
  //
  // If the active clip has a dual-camera descriptor AND the secondary reader
  // has a cached frame (lastDeliveredBuffer), attempt CoreImage composition
  // (PiP or split-screen) to produce a composite output buffer.
  //
  // Ownership rules:
  //   - primaryBuf (pb) is the _lastDeliveredBuffer, already stored above (+1).
  //   - secondaryPB is secondaryClipReader.lastDeliveredBuffer — NOT caller-owned;
  //     we temporarily retain it around the composition call for safety.
  //   - On success: release pb (+1), replace _lastDeliveredBuffer with compositedPB.
  //   - On failure: leave pb / _lastDeliveredBuffer unchanged (primary-only fallback).
  //   - Do NOT double-release secondaryPB.
  //
  // No per-frame NSDictionary parsing: layout config was parsed at init and
  // stored in _dualCameraLayoutConfigs.
  if (_activeReader.secondaryClipReader != nil
      && activeClipIndex < _dualCameraLayoutConfigs.count) {
    CVPixelBufferRef secondaryPB =
        _activeReader.secondaryClipReader.lastDeliveredBuffer;
    if (secondaryPB != NULL) {
      // Read the pre-parsed layout config (no dict overhead).
      NSValue *cfgValue = _dualCameraLayoutConfigs[activeClipIndex];
      _VGTCNDualCameraLayoutConfig layoutCfg;
      [cfgValue getValue:&layoutCfg];

      if (layoutCfg.enabled) {
        // Temporarily retain secondary around the render call.
        CVPixelBufferRetain(secondaryPB);

        CVPixelBufferRef compositedPB = NULL;
        if (layoutCfg.mode == _VGTCNDualCameraLayoutModeSplitScreen) {
          compositedPB = _VGTCNCompositeSplitScreen(
              pb, secondaryPB, layoutCfg.split, _targetRenderSize);
        } else {
          // PiP (default).
          compositedPB = _VGTCNCompositePiP(
              pb, secondaryPB, layoutCfg.pip, _targetRenderSize);
        }

        CVPixelBufferRelease(secondaryPB); // release temporary retain

        if (compositedPB != NULL) {
          // Success: swap primary buffer for composed buffer.
          // pb (+1) held by _lastDeliveredBuffer — release it now.
          CVPixelBufferRelease(pb);
          pb = NULL; // defensive nil — not used after this point
          _lastDeliveredBuffer = compositedPB; // node owns +1 from composite helper
          os_log_debug(sTimelineLog,
                       "[VGTCNode-Q3B] composed frame delivered: clip=%lu mode=%ld",
                       (unsigned long)activeClipIndex, (long)layoutCfg.mode);
        } else {
          // Composition failed: fall through with primary buffer unchanged.
          os_log_error(sTimelineLog,
                       "[VGTCNode-Q3B] composition failed clip=%lu mode=%ld — "
                       "falling back to primary-only.",
                       (unsigned long)activeClipIndex, (long)layoutCfg.mode);
        }
      }
    }
  }
  // ── End Phase 7.x-Q3B composition ───────────────────────────────────────────

  // Use asset-local duration from per-reader cache for the output envelope.
  double sDur = _activeReader.lastDeliveredAssetDuration;
  CMTime outputDur = (sDur > 0.0)
      ? CMTimeMakeWithSeconds(sDur, 600)
      : CMTimeMakeWithSeconds(1.0 / _activeReader.sourceFPS, 600);

  // _lastDeliveredBuffer is the final output (primary or composited).
  // VGFrameEnvelope carries +0; node holds the +1 in _lastDeliveredBuffer.
  VGFrameEnvelope env;
  memset(&env, 0, sizeof(env));
  env.mediaType = VGMediaTypeVideo;
  env.payload.videoBuffer = (void *)_lastDeliveredBuffer; // +0 in envelope
  env.pts = request.requestedPTS;
  env.dts = kCMTimeInvalid;
  env.duration = outputDur;
  env.generation = request.generation;
  env.metadata = NULL;

  os_log_debug(sTimelineLog,
               "[VGTCNode] delivered frame: clip=%lu tAsset=%.3fs genMatch=%d",
               (unsigned long)activeClipIndex, tAsset,
               (int)(atomic_load(&_generation) == capturedGeneration));

  return [VGFrameResult deliveredWithEnvelope:env
                                   generation:request.generation];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Private helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 7.11 RR-146: Per-reader frame pull with reuse guard, transform, and cache update.
///
/// This helper replaces the inline copyNextSampleBuffer + Phase 7.11 transform
/// blocks that previously appeared in both the normal and transition paths of
/// pullFrame:. By moving the reuse guard into the reader, the 60/120 Hz
/// CADisplayLink no longer consumes frames faster than the source clip's frame
/// rate, fixing the premature AVAssetReader exhaustion bug.
///
/// Ownership contract (caller must release the returned buffer):
///   Returns a retained CVPixelBufferRef (+1) on success.
///   Returns NULL with *outError set on error (transform or reader error).
///   Returns NULL with *outError = nil when reader completed (EOS/exhausted).
///     In the EOS case, the caller must check reader.status to distinguish
///     AVAssetReaderStatusCompleted from AVAssetReaderStatusFailed.
///
/// Per-reader cache behavior:
///   If reader.lastDeliveredBuffer is non-NULL and tAsset falls within
///   [reader.lastDeliveredAssetPTS, reader.lastDeliveredAssetPTS + reader.lastDeliveredAssetDuration),
///   the cached buffer is returned (retained +1) WITHOUT calling copyNextSampleBuffer.
///   Otherwise, the previous cache is released, copyNextSampleBuffer is called,
///   Phase 7.11 transform is applied if non-identity, and the cache is updated.
///
/// Thread safety: must be called on the serial pull queue (_VGTimelinePullQueue).
- (CVPixelBufferRef)_pullBufferFromReader:(_VGClipReader *)reader
                               atAssetTime:(double)tAsset
                                     error:(NSError **)outError {
  NSParameterAssert(reader != nil);

  // ── Phase 7.12: Static source path ────────────────────────────────────────
  // Phase 7.12: static image transforms are baked into the cached buffer.
  // Phase 7.17: freeze-frame clips also use isStaticSource=YES and share
  //             this path; the frame is extracted via AVAssetImageGenerator
  //             when freezePTS is non-nil.
  // Transform changes require reader/draft rebuild; no dynamic per-frame image transform update in this slice.
  if (reader.isStaticSource) {
    // Phase 7.x-Q3A: Use resolvedClip so secondary static-source readers
    // decode from their own sourceURL, not the primary timeline clip's URL.
    VGClipDescriptor *clip = reader.resolvedClip ?: _clips[reader.clipIndex];

    // ── Phase 7.18A: Compositor-level frame cache lookup ──────────────────
    // Check the shared frame cache before the per-reader buffer and before
    // any expensive decode/extraction work. The cache key for freeze clips
    // uses freezePTS as assetPTS; for still-image clips it uses 0.0.
    {
      double cachePTS = (reader.freezePTS != nil) ? reader.freezePTS.doubleValue : 0.0;
      uint64_t currentGen = atomic_load(&_generation);
      CVPixelBufferRef cachedBuf =
          [_frameCache lookupWithClipIndex:reader.clipIndex
                                 sourceURL:clip.sourceURL
                                  assetPTS:cachePTS
                                renderSize:_targetRenderSize
                                generation:currentGen];
      if (cachedBuf) {
        os_log_debug(sTimelineLog,
                     "[VGTCNode] frame-cache hit: clip=%lu pts=%.3fs bytes=%zu",
                     (unsigned long)reader.clipIndex, cachePTS,
                     _frameCache.currentBytes);
        // Warm the per-reader buffer so the hot path (next call) short-circuits
        // without hitting the shared cache. Transfer the +1 from lookupWith… into
        // lastDeliveredBuffer; reader takes a new +1 for its own slot.
        if (reader.lastDeliveredBuffer == NULL) {
          reader.lastDeliveredBuffer = cachedBuf;     // adopt lookup +1
          reader.lastDeliveredAssetPTS = 0.0;
          reader.lastDeliveredAssetDuration = 1e9;    // static: never expires
          CVPixelBufferRetain(reader.lastDeliveredBuffer); // reader's own +1
        }
        return cachedBuf; // caller owns the +1 from lookupWith…
      }
      os_log_debug(sTimelineLog,
                   "[VGTCNode] frame-cache miss: clip=%lu pts=%.3fs",
                   (unsigned long)reader.clipIndex, cachePTS);
    }

    if (reader.lastDeliveredBuffer != NULL) {
      // Per-reader cache hit: retain and return the static buffer directly.
      CVPixelBufferRetain(reader.lastDeliveredBuffer);
      os_log_debug(sTimelineLog,
                   "[VGTCNode] static cache hit: clip=%lu",
                   (unsigned long)reader.clipIndex);
      return reader.lastDeliveredBuffer; // caller owns +1
    }

    // ── Phase 7.17: Freeze-frame path ──────────────────────────────────────
    // When freezePTS is non-nil this is a video-derived freeze clip.
    // Use AVAssetImageGenerator to extract the exact frame at the requested
    // source-local PTS. Zero tolerances ensure exact frame accuracy (same
    // as Opus-approved contract; see DEC-150 / RR-154).
    if (reader.freezePTS != nil) {
      NSURL *assetURL = [NSURL fileURLWithPath:clip.sourceURL];
      if (!assetURL) {
        if (outError) {
          *outError = _VGTCNError(
              30, ([NSString stringWithFormat:
                       @"VGTimelineCompositorNode (Phase 7.17): invalid sourceURL "
                        "for freeze-frame clip %@.",
                       clip.clipId]));
        }
        return NULL;
      }

      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
      AVAssetImageGenerator *gen =
          [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
      // kCMTimeZero tolerances: exact frame accuracy as specified in DEC-150 / RR-154.
      gen.requestedTimeToleranceBefore = kCMTimeZero;
      gen.requestedTimeToleranceAfter  = kCMTimeZero;
      // Apply maximum size to avoid excess memory; canvas size is sufficient.
      gen.maximumSize = CGSizeMake(_targetRenderSize.width * 2.0,
                                   _targetRenderSize.height * 2.0);
      // Phase 7.17 orientation fix (RR-154): AVAssetImageGenerator defaults
      // appliesPreferredTrackTransform to NO, returning raw track-coordinate
      // pixels that are unrotated.  Normal video playback is already
      // orientation-normalised by AVPlayer; setting YES here aligns the
      // freeze path with that behaviour so the frozen frame is never sideways.
      gen.appliesPreferredTrackTransform = YES;

      // Convert source-local seconds to CMTime (timescale 600 for sub-frame precision).
      double pts = reader.freezePTS.doubleValue;
      CMTime requestTime = CMTimeMakeWithSeconds(pts, 600);

      NSError *genErr = nil;
      CMTime actualTime;
      CGImageRef cgFrame = [gen copyCGImageAtTime:requestTime
                                       actualTime:&actualTime
                                            error:&genErr];
      if (!cgFrame) {
        if (outError) {
          *outError = _VGTCNError(
              31, ([NSString stringWithFormat:
                       @"VGTimelineCompositorNode (Phase 7.17): "
                        "AVAssetImageGenerator failed for clip %@ at PTS %.3fs: %@",
                       clip.clipId, pts,
                       genErr.localizedDescription ?: @"unknown"])); 
        }
        os_log_error(sTimelineLog,
                     "[VGTCNode] freeze-frame extract failed clip=%lu pts=%.3fs: %{public}@",
                     (unsigned long)reader.clipIndex, pts,
                     genErr.localizedDescription);
        return NULL;
      }

      os_log(sTimelineLog,
             "[VGTCNode] freeze-frame extracted: clip=%lu reqPTS=%.3fs actualPTS=%.3fs",
             (unsigned long)reader.clipIndex, pts,
             CMTimeGetSeconds(actualTime));

      // Convert CGImage → CVPixelBufferRef via CIImage + CIContext.
      // Use the Phase 7.12 still-image helper with no crop/fitMode (video frame
      // is already correctly sized; fitMode=fit, cropRect=nil).
      // The helper scales to targetRenderSize using fit mode.
      CGRelease_cleanup:
      {
        CIImage *ciFrame = [CIImage imageWithCGImage:cgFrame];
        CGImageRelease(cgFrame);

        CGSize imgSize = ciFrame.extent.size;
        if (imgSize.width <= 0 || imgSize.height <= 0) {
          if (outError) {
            *outError = _VGTCNError(
                32, ([NSString stringWithFormat:
                         @"VGTimelineCompositorNode (Phase 7.17): "
                          "extracted frame has zero size for clip %@.",
                         clip.clipId]));
          }
          return NULL;
        }

        // Scale to canvas using fit mode (letterbox — same as image clips default).
        CGFloat scaleX = _targetRenderSize.width  / imgSize.width;
        CGFloat scaleY = _targetRenderSize.height / imgSize.height;
        CGFloat scale  = MIN(scaleX, scaleY); // fit mode: no black-bar fill
        CGSize  drawSize = CGSizeMake(imgSize.width * scale, imgSize.height * scale);
        CGFloat offsetX  = (_targetRenderSize.width  - drawSize.width)  / 2.0;
        CGFloat offsetY  = (_targetRenderSize.height - drawSize.height) / 2.0;

        // Create a black-filled BGRA pixel buffer at canvas size.
        NSDictionary *pbAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey:  @((int)_targetRenderSize.width),
            (id)kCVPixelBufferHeightKey: @((int)_targetRenderSize.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferRef pb = NULL;
        CVReturn pbRet = CVPixelBufferCreate(
            kCFAllocatorDefault,
            (size_t)_targetRenderSize.width,
            (size_t)_targetRenderSize.height,
            kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)pbAttrs,
            &pb);
        if (pbRet != kCVReturnSuccess || !pb) {
          if (outError) {
            *outError = _VGTCNError(
                33, ([NSString stringWithFormat:
                         @"VGTimelineCompositorNode (Phase 7.17): "
                          "CVPixelBufferCreate failed for clip %@.",
                         clip.clipId]));
          }
          return NULL;
        }

        // Clear to black.
        CVPixelBufferLockBaseAddress(pb, 0);
        void *baseAddr = CVPixelBufferGetBaseAddress(pb);
        size_t byteCount = CVPixelBufferGetBytesPerRow(pb)
                           * CVPixelBufferGetHeight(pb);
        memset(baseAddr, 0, byteCount);
        CVPixelBufferUnlockBaseAddress(pb, 0);

        // Render scaled CIImage into the pixel buffer.
        CGAffineTransform tx = CGAffineTransformTranslate(
            CGAffineTransformMakeScale(scale, scale), 0, 0);
        CIImage *scaled = [ciFrame imageByApplyingTransform:
            CGAffineTransformMakeScale(scale, scale)];
        // Translate to center within canvas (CI origin = bottom-left).
        CIImage *centered = [scaled imageByApplyingTransform:
            CGAffineTransformMakeTranslation(offsetX, offsetY)];

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        [_VGTCNSharedCIContext() render:centered
                          toCVPixelBuffer:pb
                                    bounds:CGRectMake(0, 0,
                                                      _targetRenderSize.width,
                                                      _targetRenderSize.height)
                                colorSpace:cs];
        CGColorSpaceRelease(cs);
        (void)tx; // suppress unused warning

        // Apply Phase 7.11 transform if non-identity (freeze clips default to nil).
        VGClipTransformDescriptor *td = clip.transform;
        if (td && !td.isIdentity) {
          NSError *tfErr = nil;
          CVPixelBufferRef tfPB = _VGTCNApplyTransformAndOpacity(pb, td, &tfErr);
          CVPixelBufferRelease(pb);
          if (!tfPB) {
            if (outError) *outError = tfErr;
            os_log_error(sTimelineLog,
                         "[VGTCNode] freeze-frame transform failed clip=%lu: %{public}@",
                         (unsigned long)reader.clipIndex,
                         tfErr.localizedDescription);
            return NULL;
          }
          pb = tfPB;
        }

        // Cache the decoded+transformed buffer. Cache takes its own +1.
        reader.lastDeliveredBuffer = pb;
        reader.lastDeliveredAssetPTS = 0.0;
        reader.lastDeliveredAssetDuration = 1e9; // static: never expires
        CVPixelBufferRetain(pb); // per-reader cache retain

        // Phase 7.18A: also insert into the compositor-level frame cache so
        // future scrubs and prefetch hits can serve this buffer without
        // re-invoking AVAssetImageGenerator.
        [_frameCache insertWithClipIndex:reader.clipIndex
                               sourceURL:clip.sourceURL
                                assetPTS:reader.freezePTS.doubleValue
                              renderSize:_targetRenderSize
                              generation:atomic_load(&_generation)
                                  buffer:pb];
        os_log(sTimelineLog,
               "[VGTCNode] freeze-frame decoded+cached (sync+framecache): "
               "clip=%lu canvas=%.0fx%.0f cacheBytes=%zu",
               (unsigned long)reader.clipIndex,
               _targetRenderSize.width, _targetRenderSize.height,
               _frameCache.currentBytes);

        return pb; // caller owns +1 from CVPixelBufferCreate
      } // CGRelease_cleanup
    }
    // ── End Phase 7.17 freeze-frame path ───────────────────────────────────

    // ── Phase 7.12: Still-image path (non-freeze) ──────────────────────────
    // First pull: decode still image.
    NSURL *imageURL = [NSURL fileURLWithPath:clip.sourceURL];
    if (!imageURL) {
      if (outError) {
        *outError = _VGTCNError(
            23, ([NSString stringWithFormat:
                     @"VGTimelineCompositorNode (Phase 7.12): invalid sourceURL "
                      "for still-image clip %@.",
                     clip.clipId]));
      }
      return NULL;
    }

    // Phase 7.16 (DEC-148): pass fitMode and cropRect to bake crop/fit/fill
    // at decode time into the static buffer cache. Zero per-frame overhead.
    NSError *decErr = nil;
    CVPixelBufferRef pb = _VGTCNCreatePixelBufferFromStillImage(
        imageURL, _targetRenderSize, clip.fitMode, clip.cropRect, &decErr);
    if (!pb) {
      if (outError) *outError = decErr;
      os_log_error(sTimelineLog,
                   "[VGTCNode] still-image decode failed clip=%lu: %{public}@",
                   (unsigned long)reader.clipIndex,
                   decErr.localizedDescription);
      return NULL;
    }

    // Apply Phase 7.11 static transform + opacity if non-identity.
    // Transform is baked into the cached buffer here; no per-frame re-apply.
    VGClipTransformDescriptor *td = clip.transform;
    if (td && !td.isIdentity) {
      NSError *tfErr = nil;
      CVPixelBufferRef tfPB = _VGTCNApplyTransformAndOpacity(pb, td, &tfErr);
      CVPixelBufferRelease(pb); // release un-transformed decode
      if (!tfPB) {
        if (outError) *outError = tfErr;
        os_log_error(sTimelineLog,
                     "[VGTCNode] still-image transform failed clip=%lu: %{public}@",
                     (unsigned long)reader.clipIndex,
                     tfErr.localizedDescription);
        return NULL;
      }
      pb = tfPB; // +1 owned by this scope
    }

    // Cache the decoded+transformed buffer. Cache takes its own +1.
    reader.lastDeliveredBuffer = pb;
    reader.lastDeliveredAssetPTS = 0.0;
    reader.lastDeliveredAssetDuration = 1e9; // large window: static buffer never expires
    CVPixelBufferRetain(pb); // per-reader cache retain

    // Phase 7.18A: also insert into the compositor-level frame cache.
    // assetPTS = 0.0 for still-image clips (single static frame).
    [_frameCache insertWithClipIndex:reader.clipIndex
                           sourceURL:clip.sourceURL
                            assetPTS:0.0
                          renderSize:_targetRenderSize
                          generation:atomic_load(&_generation)
                              buffer:pb];
    os_log(sTimelineLog,
           "[VGTCNode] still-image decoded+cached (framecache): "
           "clip=%lu canvas=%.0fx%.0f cacheBytes=%zu",
           (unsigned long)reader.clipIndex,
           _targetRenderSize.width, _targetRenderSize.height,
           _frameCache.currentBytes);

    return pb; // caller owns +1 from decode
  }

  // ── Phase 7.19 (DEC-154): Reverse video path ────────────────────────────────
  // AVAssetReader is forward-only (copyNextSampleBuffer sequential contract).
  // For reversed video clips, bypass the reader and extract each frame via
  // AVAssetImageGenerator at the computed tAsset (reverse time-mapped PTS).
  // The compositor-level _frameCache absorbs duplicate requests within a
  // display-refresh cycle (60 Hz display vs 30 fps source).
  // Error codes 40-49 are reserved for Phase 7.19 reverse extraction.
  if (reader.isReversed && !reader.isStaticSource) {
    // Phase 7.x-Q3A: Use resolvedClip so secondary reversed readers
    // decode from their own sourceURL.
    VGClipDescriptor *clip = reader.resolvedClip ?: _clips[reader.clipIndex];
    uint64_t currentGen = atomic_load(&_generation);

    // ── 1. Check compositor-level frame cache ──────────────────────────────
    // Same cache keying as the freeze-frame path. PTS-quantized keys
    // (0.001 s granularity in _VGTimelineFrameCache) naturally differentiate
    // each unique reverse-playback frame.
    CVPixelBufferRef cachedBuf =
        [_frameCache lookupWithClipIndex:reader.clipIndex
                               sourceURL:clip.sourceURL
                                assetPTS:tAsset
                              renderSize:_targetRenderSize
                              generation:currentGen];
    if (cachedBuf) {
      // Cache hit: update per-reader last-delivered fields so that
      // display-refresh re-requests within the same frame window short-circuit.
      reader.lastDeliveredAssetPTS      = tAsset;
      reader.lastDeliveredAssetDuration = 1.0 / MAX(reader.sourceFPS, 1.0);
      if (reader.lastDeliveredBuffer) CVPixelBufferRelease(reader.lastDeliveredBuffer);
      reader.lastDeliveredBuffer = cachedBuf; // adopt the +1 from lookupWith...
      CVPixelBufferRetain(cachedBuf);          // reader's own cache +1
      os_log_debug(sTimelineLog,
                   "[VGTCNode] reverse cache hit: clip=%lu tAsset=%.3fs",
                   (unsigned long)reader.clipIndex, tAsset);
      return cachedBuf; // caller owns the +1 from lookupWith...
    }

    // ── 2. Cache miss: extract via AVAssetImageGenerator (inline) ────────
    // Create inline — stateless; alloc cost (~30 μs) is negligible vs
    // extraction I/O cost (~5-15 ms). No persistent generator on _VGClipReader.
    // Configuration exactly matches the Phase 7.17 freeze-frame path (DEC-150).

    // ── Phase 7.24A (RR-157): Long-reverse inline guard ──────────────────
    // The inline AVAssetImageGenerator path is safe only for short clips.
    // For clips > 10 s, per-frame CGImage/CIImage allocations accumulate
    // faster than ARC drains them, causing multi-GB memory growth and
    // Jetsam termination. Reject early; caller must prepare a reverse sidecar.
    double clipDuration = MAX(0.0, clip.trimEndSeconds - clip.trimStartSeconds);
    if (clipDuration > 10.0) {
      if (outError) {
        *outError = _VGTCNError(
            44, ([NSString stringWithFormat:
                     @"VGTimelineCompositorNode (Phase 7.24A): reversed clip "
                      "exceeds 10s inline extraction limit. "
                      "Prepare a reverse sidecar first. "
                      "clip=%@, duration=%.1fs",
                     clip.clipId, clipDuration]));
      }
      os_log_error(sTimelineLog,
                   "[VGTCNode] Phase 7.24A: long-reverse guard fired clip=%lu "
                   "duration=%.1fs — refusing inline extraction to prevent Jetsam",
                   (unsigned long)reader.clipIndex, clipDuration);
      return NULL;
    }

    // ── Phase 7.24A (RR-157): Autoreleasepool for per-frame intermediates ─
    // Wrap the entire extraction in a local @autoreleasepool so that
    // AVURLAsset, AVAssetImageGenerator, CGImage, and CIImage intermediates
    // are drained immediately after each frame rather than accumulating in
    // the enclosing pool. This keeps per-frame memory footprint bounded for
    // short (≤ 10 s) reversed clips.
    @autoreleasepool {
    NSURL *assetURL = [NSURL fileURLWithPath:clip.sourceURL];
    if (!assetURL) {
      if (outError) {
        *outError = _VGTCNError(
            40, ([NSString stringWithFormat:
                     @"VGTimelineCompositorNode (Phase 7.19): invalid sourceURL "
                      "for reversed clip %@.",
                     clip.clipId]));
      }
      return NULL;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
    AVAssetImageGenerator *gen =
        [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    // kCMTimeZero tolerances: exact frame accuracy (same as Phase 7.17 freeze path).
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter  = kCMTimeZero;
    // 2× canvas size: avoid excess memory while supporting HiDPI sources.
    gen.maximumSize = CGSizeMake(_targetRenderSize.width * 2.0,
                                 _targetRenderSize.height * 2.0);
    // appliesPreferredTrackTransform=YES: orientation-normalize the extracted
    // frame (same as Phase 7.17 fix — see RR-154).
    gen.appliesPreferredTrackTransform = YES;

    CMTime requestTime = CMTimeMakeWithSeconds(tAsset, 600);
    NSError *genErr = nil;
    CMTime actualTime;
    CGImageRef cgFrame = [gen copyCGImageAtTime:requestTime
                                     actualTime:&actualTime
                                          error:&genErr];
    if (!cgFrame) {
      if (outError) {
        *outError = _VGTCNError(
            41, ([NSString stringWithFormat:
                     @"VGTimelineCompositorNode (Phase 7.19): "
                      "AVAssetImageGenerator failed for reversed clip %@ "
                      "at tAsset=%.3fs: %@",
                     clip.clipId, tAsset,
                     genErr.localizedDescription ?: @"unknown"]));
      }
      os_log_error(sTimelineLog,
                   "[VGTCNode] reverse extract failed clip=%lu tAsset=%.3fs: %{public}@",
                   (unsigned long)reader.clipIndex, tAsset,
                   genErr.localizedDescription);
      return NULL;
    }

    os_log(sTimelineLog,
           "[VGTCNode] reverse frame extracted: clip=%lu tAsset=%.3fs actualPTS=%.3fs",
           (unsigned long)reader.clipIndex, tAsset, CMTimeGetSeconds(actualTime));

    // ── 3. Convert CGImage → CVPixelBufferRef ───────────────────────────────
    // Exact same CGImage→CIImage→CVPixelBuffer pipeline as Phase 7.17 (lines
    // 2066–2188). Fit-mode center-scaled letterbox. Black bars on AR mismatch.
    {
      CIImage *ciFrame = [CIImage imageWithCGImage:cgFrame];
      CGImageRelease(cgFrame); // CIImage retains internally; release CGImage.
      cgFrame = NULL;          // prevent double-release.

      CGSize imgSize = ciFrame.extent.size;
      if (imgSize.width <= 0 || imgSize.height <= 0) {
        if (outError) {
          *outError = _VGTCNError(
              42, ([NSString stringWithFormat:
                       @"VGTimelineCompositorNode (Phase 7.19): "
                        "extracted reverse frame has zero size for clip %@.",
                       clip.clipId]));
        }
        return NULL;
      }

      // Aspect-fit scale (letterbox — same as Phase 7.17 freeze path).
      CGFloat scaleX = _targetRenderSize.width  / imgSize.width;
      CGFloat scaleY = _targetRenderSize.height / imgSize.height;
      CGFloat scale  = MIN(scaleX, scaleY);
      CGSize  drawSize = CGSizeMake(imgSize.width * scale, imgSize.height * scale);
      CGFloat offsetX  = (_targetRenderSize.width  - drawSize.width)  / 2.0;
      CGFloat offsetY  = (_targetRenderSize.height - drawSize.height) / 2.0;

      // Create black-filled BGRA canvas buffer.
      NSDictionary *pbAttrs = @{
          (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
          (id)kCVPixelBufferWidthKey:  @((int)_targetRenderSize.width),
          (id)kCVPixelBufferHeightKey: @((int)_targetRenderSize.height),
          (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVPixelBufferRef pb = NULL;
      CVReturn pbRet = CVPixelBufferCreate(
          kCFAllocatorDefault,
          (size_t)_targetRenderSize.width,
          (size_t)_targetRenderSize.height,
          kCVPixelFormatType_32BGRA,
          (__bridge CFDictionaryRef)pbAttrs,
          &pb);
      if (pbRet != kCVReturnSuccess || !pb) {
        if (outError) {
          *outError = _VGTCNError(
              43, ([NSString stringWithFormat:
                       @"VGTimelineCompositorNode (Phase 7.19): "
                        "CVPixelBufferCreate failed for reversed clip %@.",
                       clip.clipId]));
        }
        return NULL;
      }

      // Clear to black.
      CVPixelBufferLockBaseAddress(pb, 0);
      void *baseAddr = CVPixelBufferGetBaseAddress(pb);
      size_t byteCount = CVPixelBufferGetBytesPerRow(pb)
                         * CVPixelBufferGetHeight(pb);
      memset(baseAddr, 0, byteCount);
      CVPixelBufferUnlockBaseAddress(pb, 0);

      // Render scaled CIImage into pixel buffer (CI origin = bottom-left).
      CIImage *scaled = [ciFrame imageByApplyingTransform:
          CGAffineTransformMakeScale(scale, scale)];
      CIImage *centered = [scaled imageByApplyingTransform:
          CGAffineTransformMakeTranslation(offsetX, offsetY)];

      CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
      [_VGTCNSharedCIContext() render:centered
                        toCVPixelBuffer:pb
                                  bounds:CGRectMake(0, 0,
                                                    _targetRenderSize.width,
                                                    _targetRenderSize.height)
                              colorSpace:cs];
      CGColorSpaceRelease(cs);

      // Apply Phase 7.11 per-clip transform if non-identity.
      VGClipTransformDescriptor *td = clip.transform;
      if (td && !td.isIdentity) {
        NSError *tfErr = nil;
        CVPixelBufferRef tfPB = _VGTCNApplyTransformAndOpacity(pb, td, &tfErr);
        CVPixelBufferRelease(pb);
        if (!tfPB) {
          if (outError) *outError = tfErr;
          os_log_error(sTimelineLog,
                       "[VGTCNode] reverse transform failed clip=%lu: %{public}@",
                       (unsigned long)reader.clipIndex,
                       tfErr.localizedDescription);
          return NULL;
        }
        pb = tfPB;
      }

      // ── 4. Insert into compositor-level frame cache ──────────────────────
      [_frameCache insertWithClipIndex:reader.clipIndex
                             sourceURL:clip.sourceURL
                              assetPTS:tAsset
                            renderSize:_targetRenderSize
                            generation:currentGen
                                buffer:pb];

      // ── 5. Update per-reader last-delivered fields ──────────────────────
      reader.lastDeliveredAssetPTS      = tAsset;
      reader.lastDeliveredAssetDuration = 1.0 / MAX(reader.sourceFPS, 1.0);
      if (reader.lastDeliveredBuffer) CVPixelBufferRelease(reader.lastDeliveredBuffer);
      reader.lastDeliveredBuffer = pb;
      CVPixelBufferRetain(pb); // per-reader cache +1

      os_log(sTimelineLog,
             "[VGTCNode] reverse decoded+cached: clip=%lu tAsset=%.3fs "
             "canvas=%.0fx%.0f cacheBytes=%zu",
             (unsigned long)reader.clipIndex, tAsset,
             _targetRenderSize.width, _targetRenderSize.height,
             _frameCache.currentBytes);

      return pb; // caller owns +1 from CVPixelBufferCreate
    }
    } // @autoreleasepool — Phase 7.24A: drain per-frame reverse intermediates
  }
  // ── End Phase 7.19 reverse extraction ───────────────────────────────────

  // ── Phase 7.20: Sidecar reader time mapping ─────────────────────────────────
  // A forward sidecar reader is built for a reversed clip (clip.isReversed == YES,
  // reader.isReversed == NO). The sidecar file stores frames in forward order
  // (sidecar PTS increases 0 → duration). The compositor passes tAsset decreasing
  // from trimEnd to trimStart (reversed source formula). The per-reader reuse
  // guard and lastDeliveredAssetPTS tracking below are in sidecar-local forward
  // time, so remap here before the guard.
  //   sidecarT = clip.trimEndSeconds - tAsset
  // Identity for all non-sidecar readers (clip not reversed, or reader.isReversed YES,
  // or reader is a static source with reader.reader == nil).
  {
    // Phase 7.x-Q3A: Use resolvedClip for sidecar time-remap so that
    // a secondary reversed reader (if ever enabled) uses its own descriptor.
    VGClipDescriptor *scRemapClip = reader.resolvedClip ?: _clips[reader.clipIndex];
    if (scRemapClip.isReversed && !reader.isReversed && reader.reader != nil) {
      double sidecarT = scRemapClip.trimEndSeconds - tAsset;
      os_log_debug(sTimelineLog,
                   "[VGTCNode] sidecar time-remap: clip=%lu "
                   "tAsset(src)=%.3fs sidecarT=%.3fs",
                   (unsigned long)reader.clipIndex, tAsset, sidecarT);
      tAsset = sidecarT;
    }
  }
  // ── End Phase 7.20 sidecar time mapping ─────────────────────────────────────

  // ── 1. Per-reader reuse guard (video path) ────────────────────────────────
  if (reader.lastDeliveredBuffer != NULL) {
    if (tAsset >= reader.lastDeliveredAssetPTS &&
        tAsset <  reader.lastDeliveredAssetPTS + reader.lastDeliveredAssetDuration) {
      // Requested asset time is within the cached sample window.
      // Retain and return cached buffer without decoding a new sample.
      CVPixelBufferRetain(reader.lastDeliveredBuffer);
      os_log_debug(sTimelineLog,
                   "[VGTCNode] reader cache hit: clip=%lu tAsset=%.3fs "
                   "cacheWindow=[%.3f, %.3f)",
                   (unsigned long)reader.clipIndex, tAsset,
                   reader.lastDeliveredAssetPTS,
                   reader.lastDeliveredAssetPTS + reader.lastDeliveredAssetDuration);
      return reader.lastDeliveredBuffer; // caller owns +1
    }
    // Cache miss: release previous buffer before decoding a new sample.
    CVPixelBufferRelease(reader.lastDeliveredBuffer);
    reader.lastDeliveredBuffer = NULL;
    reader.lastDeliveredAssetPTS = -1.0;
    reader.lastDeliveredAssetDuration = 0.0;
  }

  // ── 2. Decode next sample ──────────────────────────────────────────────────
  // copyNextSampleBuffer returns +1 CMSampleBufferRef.
  // Returns NULL when exhausted (reader.status → Completed) or on error.
  CMSampleBufferRef sample = [reader.trackOutput copyNextSampleBuffer];
  if (!sample) {
    // NULL without error — caller inspects reader.reader.status for EOS/fail.
    if (outError) *outError = nil;
    return NULL;
  }

  // ── 3. Extract pixel buffer ────────────────────────────────────────────────
  // CMSampleBufferGetImageBuffer returns +0. Retain before releasing sample.
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
  if (!pb) {
    CFRelease(sample);
    if (outError) *outError = nil;
    return NULL; // timing-only sample — caller treats as skip
  }
  CVPixelBufferRetain(pb); // pb is now +1

  // ── 4. Apply transform (Phase 7.11 / Phase 7.23B) ────────────────────────────
  //
  // Phase 7.23B (DEC-167): Keyframe-interpolated transform path.
  // Eligibility guard: only forward-playing primary video clips with a
  // non-nil transformTrack. Still-image, freeze-frame, reverse, and
  // secondary dual-camera readers are excluded (cache coherency / bake
  // constraints — deferred). Uses _currentElapsedTimeline set by
  // pullFrame: immediately before this call.
  //
  // The outer condition mirrors the existing `if (td && !td.isIdentity)` guard:
  // if the resulting interpolated descriptor is identity, skip the pixel op.
  //
  // Phase 7.x-Q3A: resolvedClip governs which transform descriptor to use,
  // ensuring secondary readers apply their own clip's transform, not the
  // primary timeline clip's transform.
  VGClipDescriptor *resolvedClipDesc = (reader.resolvedClip ?: _clips[reader.clipIndex]);
  VGClipTransformDescriptor *td = nil;

  // Phase 7.23B: keyframe path (forward-play primary video only).
  //   - resolvedClip.transformTrack must be non-nil.
  //   - Not a static-source (still-image / freeze-frame) reader.
  //   - Not a reversed clip.
  //   - Not a secondary reader (resolvedClip and _clips[reader.clipIndex] must be the same).
  BOOL isSecondaryReader = (reader.resolvedClip != nil &&
                            reader.resolvedClip != _clips[reader.clipIndex]);
  VGTransformTrackDescriptor *transformTrack =
      (!isSecondaryReader && !reader.isStaticSource && !resolvedClipDesc.isReversed)
          ? resolvedClipDesc.transformTrack
          : nil;

  if (transformTrack != nil) {
    // Keyframe-interpolated transform: convert _currentElapsedTimeline to
    // microseconds using llround for accurate int64 conversion (DEC-167 / Opus).
    int64_t timeUs = llround(_currentElapsedTimeline * 1000000.0);
    td = [transformTrack interpolatedTransformAtTimeUs:timeUs];
  } else {
    // Static transform path: existing Phase 7.11 / Q3A behavior.
    td = resolvedClipDesc.transform;
  }

  if (td && !td.isIdentity) {
    NSError *tfErr = nil;
    CVPixelBufferRef transformedPB = _VGTCNApplyTransformAndOpacity(pb, td, &tfErr);
    CVPixelBufferRelease(pb); // release un-transformed original
    if (!transformedPB) {
      CFRelease(sample);
      os_log_error(sTimelineLog,
                   "[VGTCNode] _pullBufferFromReader: transform clip %lu: %{public}@",
                   (unsigned long)reader.clipIndex,
                   tfErr.localizedDescription);
      if (outError) *outError = tfErr;
      return NULL;
    }
    pb = transformedPB; // +1 owned by this scope
  }

  // ── 5. Read timing and update per-reader cache ────────────────────────────
  CMTime samplePTS = CMSampleBufferGetPresentationTimeStamp(sample);
  CMTime sampleDur = CMSampleBufferGetDuration(sample);
  double sPTS = CMTimeGetSeconds(samplePTS);
  double sDur = (CMTIME_IS_VALID(sampleDur) && !CMTIME_IS_INDEFINITE(sampleDur))
      ? CMTimeGetSeconds(sampleDur)
      : (1.0 / reader.sourceFPS);

  // Cache owns +1; returned pb also owns +1 — two independent retains.
  reader.lastDeliveredAssetPTS      = sPTS;
  reader.lastDeliveredAssetDuration = sDur;
  reader.lastDeliveredBuffer        = pb;
  CVPixelBufferRetain(pb); // cache takes its own +1

  CFRelease(sample); // done with sample; pb is independently retained

  return pb; // caller owns +1
}

/// Build an AVAssetReader and AVAssetReaderVideoCompositionOutput for the clip
/// at `clipIndex`, starting at asset-local time `startTimeSecs`.
///
/// Apple Framework Contract:
///   AVAssetReader is forward-only; timeRange is set BEFORE startReading.
///   alwaysCopiesSampleData = NO: returns original decoded buffers (read-only).
///   Output settings: 32BGRA + MetalCompatibility + IOSurface (same as export
///   path).
///   videoComposition must be assigned before startReading.
///
/// Phase 7.9 — Orientation normalization (DEC-142, RR-141):
///   Uses AVMutableVideoComposition videoCompositionWithPropertiesOfAsset: to
///   apply each track's preferredTransform at decode time. Camera-produced
///   clips (DEC-132) carry identity transform and pass through unchanged.
///   Imported portrait .mov/.mp4 files (RR-141) are normalized to correct
///   orientation. No manual CPU/GPU rotation is added.
///
/// @param clipIndex     Index into _clips.
/// @param startTimeSecs Asset-local time (trimStartSeconds + speed-adjusted
/// elapsed).
/// @param outError      Set on failure.
/// @return A populated _VGClipReader, or nil with outError on failure.
- (_VGClipReader *_Nullable)_buildReaderForClipIndex:(NSUInteger)clipIndex
                                         startAtTime:(double)startTimeSecs
                                               error:(NSError **)outError {
  VGClipDescriptor *clip = _clips[clipIndex];

  // ── Phase 7.12: Branch for still-image clips ──────────────────────────────
  // Still images do not use AVAssetReader. Build a minimal _VGClipReader
  // with isStaticSource = YES; decode happens lazily in _pullBufferFromReader:.
  if (clip.mediaKind == VGClipMediaKindImage) {
    _VGClipReader *clipReader = [[_VGClipReader alloc] init];
    clipReader.clipIndex = clipIndex;
    clipReader.reader = nil;        // No AVAssetReader for static sources.
    clipReader.trackOutput = nil;
    clipReader.sourceFPS = 1.0;     // Safe non-zero default; unused for frame timing.
    clipReader.isStaticSource = YES;
    clipReader.freezePTS = nil;     // Not a freeze clip; sourceURL decoded directly.
    clipReader.resolvedClip = clip; // Phase 7.x-Q3A: bind descriptor for pull path.
    os_log(sTimelineLog,
           "[VGTCNode] built static reader (still-image): clip=%lu",
           (unsigned long)clipIndex);
    return clipReader;
  }

  // ── Phase 7.17: Branch for video-derived freeze frame clips ──────────────
  // Freeze clips have mediaKind == VGClipMediaKindVideo and a non-nil freezePTS.
  // They do not use AVAssetReader. Build a minimal _VGClipReader with
  // isStaticSource = YES; AVAssetImageGenerator extraction happens lazily
  // in _pullBufferFromReader:.
  if (clip.mediaKind == VGClipMediaKindVideo && clip.freezePTS != nil) {
    _VGClipReader *clipReader = [[_VGClipReader alloc] init];
    clipReader.clipIndex = clipIndex;
    clipReader.reader = nil;
    clipReader.trackOutput = nil;
    clipReader.sourceFPS = 1.0;       // Unused for static path.
    clipReader.isStaticSource = YES;
    clipReader.freezePTS = clip.freezePTS; // Stored for lazy extraction.
    clipReader.resolvedClip = clip; // Phase 7.x-Q3A: bind descriptor for pull path.
    os_log(sTimelineLog,
           "[VGTCNode] built static reader (freeze-frame): clip=%lu freezePTS=%.3fs",
           (unsigned long)clipIndex,
           clip.freezePTS.doubleValue);

    // ── Phase 7.18A: Best-effort async freeze prefetch (DEC-151) ─────────
    //
    // Dispatch extraction of the frozen frame to the serial prefetch queue
    // so that the very first pullFrame: for this clip hits the compositor
    // frame cache rather than blocking on AVAssetImageGenerator.
    //
    // Safety guarantees:
    //   - Serial queue: at most one extraction in flight at a time.
    //   - Generation check before work and before insert: stale work is
    //     discarded without touching the cache.
    //   - Duplicate-key guard in _frameCache.insertWith…: if the synchronous
    //     path beats the prefetch, the insert is a no-op.
    //   - If prefetch beats the sync path, the cache hit in
    //     _pullBufferFromReader:atAssetTime: saves the AVAssetImageGenerator call.
    //   - This block holds only value-typed copies; no unsafe captures.
    uint64_t capturedGen       = atomic_load(&_generation);
    NSUInteger capturedIdx     = clipIndex;
    NSString *capturedSrcURL   = [clip.sourceURL copy];
    NSNumber *capturedFreezePTS = clip.freezePTS;
    CGSize capturedRenderSize  = _targetRenderSize;

    dispatch_async(_prefetchQueue, ^{
      // ── Guard 1: stale generation ────────────────────────────────────────
      if (atomic_load(&self->_generation) != capturedGen) {
        os_log_debug(sTimelineLog,
                     "[VGTCNode] prefetch stale (pre-work): clip=%lu gen=%llu",
                     (unsigned long)capturedIdx,
                     (unsigned long long)capturedGen);
        return;
      }

      // ── Guard 2: already cached ──────────────────────────────────────────
      double freezePTS = capturedFreezePTS.doubleValue;
      CVPixelBufferRef existing =
          [self->_frameCache lookupWithClipIndex:capturedIdx
                                       sourceURL:capturedSrcURL
                                        assetPTS:freezePTS
                                      renderSize:capturedRenderSize
                                      generation:capturedGen];
      if (existing) {
        CVPixelBufferRelease(existing);
        os_log_debug(sTimelineLog,
                     "[VGTCNode] prefetch skipped (already cached): clip=%lu",
                     (unsigned long)capturedIdx);
        return;
      }

      // ── Extract frame via AVAssetImageGenerator (same safe config as sync path)
      NSURL *assetURL = [NSURL fileURLWithPath:capturedSrcURL];
      if (!assetURL) {
        os_log_error(sTimelineLog,
                     "[VGTCNode] prefetch failed (invalid URL): clip=%lu",
                     (unsigned long)capturedIdx);
        return;
      }

      AVURLAsset *pAsset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
      AVAssetImageGenerator *pGen =
          [AVAssetImageGenerator assetImageGeneratorWithAsset:pAsset];
      pGen.requestedTimeToleranceBefore    = kCMTimeZero;
      pGen.requestedTimeToleranceAfter     = kCMTimeZero;
      if (capturedRenderSize.width > 0 && capturedRenderSize.height > 0) {
        pGen.maximumSize = CGSizeMake(capturedRenderSize.width  * 2.0,
                                     capturedRenderSize.height * 2.0);
      }
      // Orientation fix (RR-154): must match synchronous freeze path.
      pGen.appliesPreferredTrackTransform = YES;

      CMTime requestTime = CMTimeMakeWithSeconds(freezePTS, 600);
      NSError *pGenErr = nil;
      CMTime pActualTime;
      CGImageRef pCGFrame = [pGen copyCGImageAtTime:requestTime
                                         actualTime:&pActualTime
                                              error:&pGenErr];
      if (!pCGFrame) {
        os_log_error(sTimelineLog,
                     "[VGTCNode] prefetch extract failed: clip=%lu pts=%.3fs err=%{public}@",
                     (unsigned long)capturedIdx, freezePTS,
                     pGenErr.localizedDescription);
        return;
      }

      // ── Guard 3: stale generation after extraction ────────────────────────
      if (atomic_load(&self->_generation) != capturedGen) {
        CGImageRelease(pCGFrame);
        os_log_debug(sTimelineLog,
                     "[VGTCNode] prefetch stale (post-extract): clip=%lu gen=%llu",
                     (unsigned long)capturedIdx,
                     (unsigned long long)capturedGen);
        return;
      }

      // ── Convert CGImage → CVPixelBufferRef (same aspect-fit path as sync)
      CIImage *pCIFrame = [CIImage imageWithCGImage:pCGFrame];
      CGImageRelease(pCGFrame);

      CGSize pImgSize = pCIFrame.extent.size;
      if (pImgSize.width <= 0 || pImgSize.height <= 0) {
        os_log_error(sTimelineLog,
                     "[VGTCNode] prefetch: zero-size frame for clip=%lu",
                     (unsigned long)capturedIdx);
        return;
      }

      CGFloat pScaleX = 1.0, pScaleY = 1.0;
      if (capturedRenderSize.width > 0 && capturedRenderSize.height > 0) {
        pScaleX = capturedRenderSize.width  / pImgSize.width;
        pScaleY = capturedRenderSize.height / pImgSize.height;
      }
      CGFloat pScale   = MIN(pScaleX, pScaleY);
      CGFloat pOffsetX = (capturedRenderSize.width  - pImgSize.width  * pScale) / 2.0;
      CGFloat pOffsetY = (capturedRenderSize.height - pImgSize.height * pScale) / 2.0;

      size_t pW = (capturedRenderSize.width  > 0) ? (size_t)capturedRenderSize.width  : (size_t)pImgSize.width;
      size_t pH = (capturedRenderSize.height > 0) ? (size_t)capturedRenderSize.height : (size_t)pImgSize.height;

      NSDictionary *pPBAttrs = @{
          (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
          (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVPixelBufferRef pPB = NULL;
      CVReturn pPBRet = CVPixelBufferCreate(kCFAllocatorDefault, pW, pH,
                                            kCVPixelFormatType_32BGRA,
                                            (__bridge CFDictionaryRef)pPBAttrs,
                                            &pPB);
      if (pPBRet != kCVReturnSuccess || !pPB) {
        os_log_error(sTimelineLog,
                     "[VGTCNode] prefetch CVPixelBufferCreate failed: clip=%lu",
                     (unsigned long)capturedIdx);
        return;
      }

      // Clear to black.
      CVPixelBufferLockBaseAddress(pPB, 0);
      memset(CVPixelBufferGetBaseAddress(pPB), 0,
             CVPixelBufferGetBytesPerRow(pPB) * pH);
      CVPixelBufferUnlockBaseAddress(pPB, 0);

      CIImage *pScaled   = [pCIFrame imageByApplyingTransform:
                                CGAffineTransformMakeScale(pScale, pScale)];
      CIImage *pCentered = [pScaled imageByApplyingTransform:
                                CGAffineTransformMakeTranslation(pOffsetX, pOffsetY)];
      CGColorSpaceRef pCS = CGColorSpaceCreateDeviceRGB();
      [_VGTCNSharedCIContext() render:pCentered
                        toCVPixelBuffer:pPB
                                  bounds:CGRectMake(0, 0, (CGFloat)pW, (CGFloat)pH)
                              colorSpace:pCS];
      CGColorSpaceRelease(pCS);

      // ── Guard 4: stale generation before insert ───────────────────────────
      if (atomic_load(&self->_generation) != capturedGen) {
        CVPixelBufferRelease(pPB);
        os_log_debug(sTimelineLog,
                     "[VGTCNode] prefetch stale (pre-insert): clip=%lu gen=%llu",
                     (unsigned long)capturedIdx,
                     (unsigned long long)capturedGen);
        return;
      }

      [self->_frameCache insertWithClipIndex:capturedIdx
                                   sourceURL:capturedSrcURL
                                    assetPTS:freezePTS
                                  renderSize:capturedRenderSize
                                  generation:capturedGen
                                      buffer:pPB];
      CVPixelBufferRelease(pPB); // cache has its own +1; release local ref

      os_log(sTimelineLog,
             "[VGTCNode] prefetch complete: clip=%lu pts=%.3fs actualPTS=%.3fs "
             "cacheBytes=%zu",
             (unsigned long)capturedIdx, freezePTS,
             CMTimeGetSeconds(pActualTime),
             self->_frameCache.currentBytes);
    }); // dispatch_async _prefetchQueue
    // ── End Phase 7.18A prefetch ─────────────────────────────────────────────

    return clipReader;
  }

  // ── Phase 7.20C: Preview sidecar reader swap ─────────────────────────────
  //
  // Condition: preview mode + clip.isReversed + sidecar state == ready.
  //
  // Strategy A (Phase 7.20): instead of invoking AVAssetImageGenerator
  // synchronously on the pull queue for every frame (5–150 ms per call,
  // Phase 7.19 pain point), redirect to a forward AVAssetReader on the
  // All-Intra sidecar that was pre-transcoded in reverse order by
  // VGReverseSidecarManager. This yields the same optimized forward-sequential
  // AVAssetReader path used for all forward clips.
  //
  // Export guard: _currentRenderMode == VGRenderModeExport skips this block.
  // The export compositor (VGTimelineExportHelper) is a fully independent node
  // instance that never touches VGReverseSidecarManager. It uses the Phase 7.19
  // AVAssetImageGenerator path for per-frame exact frame accuracy — correct for
  // export quality. The sidecar is Preview-only (All-Intra, preview bitrate).
  //
  // Orientation: the sidecar transcoder bakes preferredTransform into the pixel
  // data. The sidecar track's preferredTransform is identity. The reader built
  // here must NOT re-apply orientation (no layer instruction with the source
  // clip's preferredTransform). The auto-generated videoComposition from
  // videoCompositionWithPropertiesOfAsset: on the identity-transform sidecar
  // track is a pass-through — correct behavior.
  //
  // Fall-through: any failure in _buildSidecarReaderForClipIndex:... returns nil,
  // and this block falls through to the Phase 7.19 AVAssetImageGenerator path.
  // The sidecar is therefore a pure acceleration: correctness is preserved when
  // it is unavailable.
  if (clip.isReversed && _currentRenderMode == VGRenderModePreview) {
    VGReverseSidecarStatus *sidecarStatus =
        [[VGReverseSidecarManager sharedManager] statusForClipId:clip.clipId];
    if (sidecarStatus.state == VGReverseSidecarStateReady &&
        sidecarStatus.sidecarPath.length > 0) {
      _VGClipReader *sidecarClipReader =
          [self _buildSidecarReaderForClipIndex:clipIndex
                                    startAtTime:startTimeSecs
                                    sidecarPath:sidecarStatus.sidecarPath];
      if (sidecarClipReader) {
        return sidecarClipReader;
      }
      // Reader build failed — fall through to Phase 7.19 generator path.
      os_log_error(
          sTimelineLog,
          "[VGTCNode] 7.20C sidecar reader build failed, falling back to "
          "AVAssetImageGenerator path: clip=%lu src=%{public}@",
          (unsigned long)clipIndex, clip.sourceURL.lastPathComponent);
    }
  }
  // ── End Phase 7.20C sidecar swap ─────────────────────────────────────────

  // ── Build AVURLAsset ──────────────────────────────────────────────────────
  NSURL *assetURL = [NSURL fileURLWithPath:clip.sourceURL];
  if (!assetURL) {
    if (outError) {
      *outError = _VGTCNError(
          12, ([NSString stringWithFormat:@"VGTimelineCompositorNode: invalid "
                                          @"sourceURL for clip %@: %@",
                                          clip.clipId, clip.sourceURL]));
    }
    return nil;
  }

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];

  // ── Find first video track ────────────────────────────────────────────────
  NSArray<AVAssetTrack *> *tracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  AVAssetTrack *videoTrack = tracks.firstObject;
  if (!videoTrack) {
    if (outError) {
      *outError = _VGTCNError(
          13, ([NSString stringWithFormat:@"VGTimelineCompositorNode: no video "
                                          @"track found in asset for "
                                           "clip %@ at %@",
                                          clip.clipId, clip.sourceURL]));
    }
    return nil;
  }

  // ── Create AVAssetReader ──────────────────────────────────────────────────
  NSError *readerError = nil;
  AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset
                                                        error:&readerError];
  if (!reader) {
    if (outError)
      *outError = readerError;
    return nil;
  }

  // ── Set timeRange (starting at asset-local time) ──────────────────────────
  // For non-zero start: set timeRange so the reader begins at the requested
  // asset time. This is the canonical "seek" pattern for AVAssetReader.
  // timeRange must be set BEFORE startReading (Apple requirement).
  CMTime assetStart = CMTimeMakeWithSeconds(startTimeSecs, 600);
  CMTime assetEnd = CMTimeMakeWithSeconds(clip.trimEndSeconds, 600);
  CMTime assetDuration = asset.duration;

  // Clamp assetStart to [0, assetDuration) to avoid invalid range.
  if (CMTIME_IS_VALID(assetDuration) &&
      CMTimeCompare(assetStart, assetDuration) >= 0) {
    // Start is beyond asset duration; EOS immediately.
    // Return a sentinel reader that will produce no samples.
    // Handled below via startReading + no samples.
    assetStart = assetDuration;
  }

  // Build timeRange from assetStart to the lesser of assetEnd and
  // assetDuration.
  CMTime readEnd = assetEnd;
  if (CMTIME_IS_VALID(assetDuration) &&
      CMTimeCompare(assetEnd, assetDuration) > 0) {
    readEnd = assetDuration;
  }

  if (CMTimeCompare(assetStart, readEnd) < 0) {
    CMTime readDuration = CMTimeSubtract(readEnd, assetStart);
    reader.timeRange = CMTimeRangeMake(assetStart, readDuration);
  }
  // else: zero-length range → reader will complete immediately (EOS).

  // ── Phase 7.9: AVMutableVideoComposition for orientation normalization ───────
  //
  // AVAssetReaderTrackOutput vends raw encoded-orientation pixel buffers and
  // ignores AVAssetTrack.preferredTransform. Imported portrait .mov/.mp4 files
  // carry a 90°/270° preferredTransform and rendered sideways before this fix.
  //
  // AVAssetReaderVideoCompositionOutput applies the video composition
  // instructions (which include preferredTransform) at decode time, producing
  // orientation-normalized BGRA pixel buffers.
  //
  // Camera-produced clips (DEC-132) carry identity preferredTransform. The
  // video composition applies no rotation; decoded frames are unchanged. No
  // double rotation occurs.
  //
  // DEADLOCK NOTE (ref: VanguardFileMediaSource.m G-02-T3):
  // AVAssetReaderVideoCompositionOutput.copyNextSampleBuffer dispatches to
  // main for each frame composition. This caused deadlocks in
  // VanguardFileMediaSource because it used a fast-forward discard loop
  // (60+ copyNextSampleBuffer calls during seek storms). That pattern does
  // NOT apply here: VGTimelineCompositorNode sets AVAssetReader.timeRange
  // before startReading to position the reader at the correct start time.
  // pullFrame: calls copyNextSampleBuffer at most once per frame. The
  // deadlock prerequisite (tight discard loop on background queue) is absent.
  //
  // ── Phase 7.9 Aspect-Fit Normalization ──────────────────────────────────────
  //
  // When _targetRenderSize is non-zero (canvasWidth/canvasHeight supplied via
  // parameters), we override the auto-generated video composition with manual
  // instructions that:
  //   1. Set renderSize to _targetRenderSize (the draft canvas, e.g. 640×360).
  //   2. Compute an aspect-fit affine transform that maps the source frame
  //      (after preferredTransform rotation) into the canvas rectangle.
  //   3. Apply this transform via AVMutableVideoCompositionLayerInstruction.
  //
  // This produces pixel buffers at the canvas size with the source frame
  // aspect-fit centered (letterbox for landscape-in-portrait, pillarbox for
  // portrait-in-landscape). No cropping, no stretching.
  //
  // When _targetRenderSize is CGSizeZero (legacy/smoke-test paths), the
  // auto-generated composition from videoCompositionWithPropertiesOfAsset:
  // is used unchanged, preserving backward compatibility.
  //
  // API deprecation: videoCompositionWithPropertiesOfAsset: is deprecated in
  // iOS 18.0 (async completionHandler: variant is preferred). The synchronous
  // variant (iOS 6.0+) is used here because _buildReaderForClipIndex: is
  // called synchronously from the pull queue. Migrating to the async API
  // would require significant restructuring of the reader build path and is
  // deferred. The deprecated API remains fully functional through current iOS.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  AVMutableVideoComposition *videoComposition =
      [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset];
#pragma clang diagnostic pop

  // ── Apply aspect-fit canvas normalization when _targetRenderSize is set ──────
  if (_targetRenderSize.width > 0 && _targetRenderSize.height > 0) {
    // Step 1: Compute display dimensions after applying preferredTransform.
    CGAffineTransform preferredTx = videoTrack.preferredTransform;
    CGSize naturalSize = videoTrack.naturalSize;
    CGRect displayRect =
        CGRectApplyAffineTransform(CGRectMake(0, 0, naturalSize.width,
                                              naturalSize.height),
                                  preferredTx);
    CGFloat displayW = fabs(displayRect.size.width);
    CGFloat displayH = fabs(displayRect.size.height);

    // Step 2: Compute aspect-fit scale (min, not max — no cropping).
    CGFloat canvasW = _targetRenderSize.width;
    CGFloat canvasH = _targetRenderSize.height;
    CGFloat fitScale = 1.0;
    if (displayW > 0 && displayH > 0) {
      fitScale = MIN(canvasW / displayW, canvasH / displayH);
    }

    // Step 3: Center-translate the scaled frame within the canvas.
    CGFloat tx = (canvasW - displayW * fitScale) / 2.0;
    CGFloat ty = (canvasH - displayH * fitScale) / 2.0;

    // Step 4: Compose: preferredTransform → uniform scale → center translate.
    CGAffineTransform fitTransform =
        CGAffineTransformConcat(
            preferredTx,
            CGAffineTransformConcat(
                CGAffineTransformMakeScale(fitScale, fitScale),
                CGAffineTransformMakeTranslation(tx, ty)));

    // Step 5: Build layer instruction with the computed transform.
    AVMutableVideoCompositionLayerInstruction *layerInstruction =
        [AVMutableVideoCompositionLayerInstruction
            videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layerInstruction setTransform:fitTransform atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *instruction =
        [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange =
        CMTimeRangeMake(kCMTimeZero, asset.duration);
    instruction.layerInstructions = @[layerInstruction];

    // Step 6: Override composition renderSize and instructions.
    videoComposition.renderSize = _targetRenderSize;
    videoComposition.instructions = @[instruction];

    // Phase 7.x-Q3D: Store primary source display dimensions in the layout config
    // so _VGTCNCompositePiP can compute the visible primary rect at composition
    // time and anchor the PiP over the actual video content (not black bars).
    if (clipIndex < _dualCameraLayoutConfigs.count) {
      NSValue *cfgValue = _dualCameraLayoutConfigs[clipIndex];
      _VGTCNDualCameraLayoutConfig cfg;
      [cfgValue getValue:&cfg];
      if (cfg.enabled) {
        cfg.pip.primarySourceSize = CGSizeMake(displayW, displayH);
        NSMutableArray *mutableConfigs =
            [NSMutableArray arrayWithArray:_dualCameraLayoutConfigs];
        mutableConfigs[clipIndex] =
            [NSValue value:&cfg withObjCType:@encode(_VGTCNDualCameraLayoutConfig)];
        _dualCameraLayoutConfigs = [mutableConfigs copy];
        os_log(sTimelineLog,
               "[VGTCNode-Q3D] stored primarySourceSize=%.0fx%.0f for clip=%lu",
               displayW, displayH, (unsigned long)clipIndex);
      }
    }

    os_log(sTimelineLog,
           "[VGTCNode] aspect-fit: clip=%lu display=%.0fx%.0f "
           "canvas=%.0fx%.0f scale=%.4f tx=%.1f ty=%.1f",
           (unsigned long)clipIndex, displayW, displayH,
           canvasW, canvasH, fitScale, tx, ty);
  }

  NSDictionary *outputSettings = _VGTCNOutputSettings();
  AVAssetReaderVideoCompositionOutput *output =
      [[AVAssetReaderVideoCompositionOutput alloc]
          initWithVideoTracks:@[videoTrack]
               videoSettings:outputSettings];

  // videoComposition must be set BEFORE startReading (Apple requirement).
  output.videoComposition = videoComposition;

  // alwaysCopiesSampleData = NO: vend original decoded buffers (read-only).
  // Avoids per-frame allocation. Matches VGExportFileSourceNode pattern.
  // (Property is declared on AVAssetReaderOutput base class.)
  output.alwaysCopiesSampleData = NO;

  if (![reader canAddOutput:output]) {
    if (outError) {
      *outError = _VGTCNError(
          14, ([NSString stringWithFormat:@"VGTimelineCompositorNode: cannot "
                                          @"add AVAssetReaderVideoCompositionOutput "
                                           "for clip %@.",
                                          clip.clipId]));
    }
    return nil;
  }

  [reader addOutput:output];

  // ── Start reading ─────────────────────────────────────────────────────────
  if (![reader startReading]) {
    if (outError)
      *outError = reader.error;
    return nil;
  }

  // ── Compute source FPS ────────────────────────────────────────────────────
  // Phase 7.9: prefer videoComposition.frameDuration when valid (it is set
  // by videoCompositionWithPropertiesOfAsset: based on track properties).
  // Fall back to track nominalFrameRate, then 30.0 fps.
  double sourceFPS = 30.0;
  if (videoComposition &&
      CMTIME_IS_VALID(videoComposition.frameDuration) &&
      CMTimeGetSeconds(videoComposition.frameDuration) > 0.0) {
    sourceFPS = 1.0 / CMTimeGetSeconds(videoComposition.frameDuration);
  } else if (videoTrack.nominalFrameRate > 0.0f) {
    sourceFPS = videoTrack.nominalFrameRate;
  }

  _VGClipReader *clipReader = [[_VGClipReader alloc] init];
  clipReader.clipIndex = clipIndex;
  clipReader.reader = reader;
  clipReader.trackOutput = output;
  clipReader.sourceFPS = sourceFPS;
  // Phase 7.19 (DEC-154): propagate reverse direction flag from descriptor.
  // Still-image and freeze clips already short-circuit before this point
  // (they return from the mediaKindImage and freezePTS branches above).
  clipReader.isReversed = clip.isReversed;
  clipReader.resolvedClip = clip; // Phase 7.x-Q3A: bind descriptor for pull path.

  os_log(sTimelineLog,
         "[VGTCNode] built reader: clip=%lu startAt=%.3fs fps=%.1f isReversed=%d",
         (unsigned long)clipIndex, startTimeSecs, sourceFPS, (int)clip.isReversed);

  // ── Phase 7.x-Q2: Build secondary reader for dual-camera clips ───────────
  //
  // If this clip carries a valid dualCamera payload (stored in
  // _dualCameraDescDicts at the corresponding index), build the secondary
  // reader now and nest it inside the primary reader.
  //
  // startAtTime for the secondary is computed using the same elapsed_timeline
  // value that was used to compute the primary startTimeSecs, but applying
  // the secondary clip's own speed (see §Opus Q2 time-mapping correction).
  //
  // Safety: failure to build the secondary reader is non-fatal. Primary
  // playback continues unchanged. secondaryEOSReached is left NO so the
  // first pullFrame: attempt will re-check _secondaryClipReader (nil) and
  // skip cleanly without retry.
  if (clipIndex < _dualCameraDescDicts.count) {
    id rawDualCamera = _dualCameraDescDicts[clipIndex];
    if ([rawDualCamera isKindOfClass:[NSDictionary class]]) {
      NSError *secBuildErr = nil;
      _VGClipReader *secondaryReader =
          [self _buildSecondaryReaderForDualCamera:(NSDictionary *)rawDualCamera
                                        clipIndex:clipIndex
                                      startAtTime:startTimeSecs
                                            error:&secBuildErr];
      if (secondaryReader) {
        clipReader.secondaryClipReader = secondaryReader;
        os_log(sTimelineLog,
               "[VGTCNode-Q2] secondary reader built for clip=%lu",
               (unsigned long)clipIndex);
      } else {
        // Non-fatal: secondary reader build failed. Primary continues.
        os_log(sTimelineLog,
               "[VGTCNode-Q2] secondary reader build skipped/failed for clip=%lu: %{public}@",
               (unsigned long)clipIndex,
               secBuildErr.localizedDescription ?: @"unsupported secondary shape");
      }
    }
  }

  return clipReader;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.x-Q2: Secondary reader builder
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 7.x-Q2: Build an AVAssetReader (or static-source _VGClipReader) for
/// the secondary clip embedded in a dual-camera timeline clip's `dualCamera`
/// dictionary.
///
/// The `dualCamera` dictionary is produced by VGDualCameraDescriptor.toTimelineMap()
/// and contains:
///   - @"secondaryClip": NSDictionary (a VGClipDescriptor wire map)
///   - @"layoutMode":   NSString (ignored in Q2; consumed by Q3 compositor)
///   - @"pipLayout":    NSDictionary (ignored in Q2)
///   - @"splitLayout":  NSDictionary (ignored in Q2)
///
/// Supported secondary shapes in Q2:
///   • Video (normal, non-frozen, non-reversed): full AVAssetReader path.
///   • Still image:  isStaticSource = YES; existing static-source pull path.
///
/// Unsupported secondary shapes (deferred to Q3+):
///   • Freeze-frame video (freezePTS != nil): rejected, returns nil (non-fatal).
///   • Reversed video (isReversed == YES):    rejected, returns nil (non-fatal).
///
/// @param dualCameraDict  The `dualCamera` NSDictionary from the clip parameters.
/// @param clipIndex       Index of the primary clip in _clips (for logging).
/// @param startTimeSecs   Asset-local start time for the secondary reader.
///                        This is the t_sec_asset at reader build time:
///                          t_sec_asset = secondary.trimStart + elapsedTimeline * secSpeed
/// @param outError        Optional; set on hard failure. nil on supported-shape skip.
/// @return                A populated _VGClipReader on success, nil otherwise.
- (_VGClipReader *_Nullable)
    _buildSecondaryReaderForDualCamera:(NSDictionary *)dualCameraDict
                             clipIndex:(NSUInteger)clipIndex
                           startAtTime:(double)startTimeSecs
                                 error:(NSError **)outError {
  // ── 1. Extract and parse secondary clip descriptor ───────────────────────
  id rawSecClip = dualCameraDict[@"secondaryClip"];
  if (![rawSecClip isKindOfClass:[NSDictionary class]]) {
    os_log_error(sTimelineLog,
                 "[VGTCNode-Q2] dualCamera dict missing 'secondaryClip' key "
                 "for primary clip=%lu. Secondary skipped.",
                 (unsigned long)clipIndex);
    return nil;
  }

  VGClipDescriptor *secClip =
      [VGClipDescriptor fromDictionary:(NSDictionary *)rawSecClip];
  if (!secClip) {
    os_log_error(sTimelineLog,
                 "[VGTCNode-Q2] fromDictionary failed for secondaryClip "
                 "(primary clip=%lu). Secondary skipped.",
                 (unsigned long)clipIndex);
    return nil;
  }

  // ── 2. Shape guard: reject unsupported secondary shapes ─────────────────
  //
  // Freeze-frame and reversed clips require separate reader infrastructure
  // (AVAssetImageGenerator / sidecar swap) that is deferred to Q3+.
  // These are non-fatal: primary playback continues; secondary is simply absent.
  if (secClip.freezePTS != nil) {
    os_log(sTimelineLog,
           "[VGTCNode-Q3A] secondary clip (primary=%lu) is freeze-frame — "
           "unsupported in Q3A. Secondary skipped.",
           (unsigned long)clipIndex);
    return nil; // Not an error; outError left nil.
  }
  if (secClip.isReversed) {
    os_log(sTimelineLog,
           "[VGTCNode-Q3A] secondary clip (primary=%lu) is reversed — "
           "unsupported in Q3A. Secondary skipped.",
           (unsigned long)clipIndex);
    return nil; // Not an error; outError left nil.
  }

  // ── 3a. Branch: still-image secondary ───────────────────────────────────
  //
  // Phase 7.x-Q3A: Still-image secondaries are now supported. The resolvedClip
  // property on _VGClipReader carries the secondary's VGClipDescriptor, so
  // _pullBufferFromReader:'s static-source path will decode from the correct
  // secondaryClip.sourceURL instead of the primary timeline clip's URL.
  if (secClip.mediaKind == VGClipMediaKindImage) {
    if (secClip.sourceURL.length == 0) {
      os_log_error(sTimelineLog,
                   "[VGTCNode-Q3A] still-image secondary (primary=%lu) has empty "
                   "sourceURL. Secondary skipped.",
                   (unsigned long)clipIndex);
      return nil;
    }
    _VGClipReader *secImgReader = [[_VGClipReader alloc] init];
    secImgReader.clipIndex      = clipIndex; // primary timeline index (for logging/cache keying)
    secImgReader.reader         = nil;
    secImgReader.trackOutput    = nil;
    secImgReader.sourceFPS      = 1.0;       // Unused for static path.
    secImgReader.isStaticSource = YES;
    secImgReader.freezePTS      = nil;       // Not a freeze clip.
    secImgReader.isReversed     = NO;
    secImgReader.resolvedClip   = secClip;   // Phase 7.x-Q3A: secondary descriptor.
    os_log(sTimelineLog,
           "[VGTCNode-Q3A] built static secondary reader (still-image): primary=%lu",
           (unsigned long)clipIndex);
    return secImgReader;
  }

  // ── 3b. Branch: video secondary (normal forward, non-frozen) ────────────
  if (secClip.mediaKind != VGClipMediaKindVideo) {
    os_log(sTimelineLog,
           "[VGTCNode-Q3A] secondary clip (primary=%lu) has unsupported "
           "mediaKind=%ld. Secondary skipped.",
           (unsigned long)clipIndex, (long)secClip.mediaKind);
    return nil;
  }
  if (secClip.sourceURL.length == 0) {
    os_log_error(sTimelineLog,
                 "[VGTCNode-Q3A] video secondary (primary=%lu) has empty "
                 "sourceURL. Secondary skipped.",
                 (unsigned long)clipIndex);
    return nil;
  }

  // ── 4. Build AVURLAsset for secondary clip ───────────────────────────────
  NSURL *secURL = [NSURL fileURLWithPath:secClip.sourceURL];
  if (!secURL) {
    if (outError) {
      *outError = _VGTCNError(
          31, ([NSString stringWithFormat:
                   @"VGTimelineCompositorNode (Q2): invalid sourceURL for "
                    "secondary clip (primary=%lu): %@",
                   (unsigned long)clipIndex, secClip.sourceURL]));
    }
    return nil;
  }

  AVURLAsset *secAsset = [AVURLAsset URLAssetWithURL:secURL options:nil];

  // ── 5. Find first video track ────────────────────────────────────────────
  NSArray<AVAssetTrack *> *secTracks =
      [secAsset tracksWithMediaType:AVMediaTypeVideo];
  AVAssetTrack *secVideoTrack = secTracks.firstObject;
  if (!secVideoTrack) {
    if (outError) {
      *outError = _VGTCNError(
          32, ([NSString stringWithFormat:
                   @"VGTimelineCompositorNode (Q2): no video track in "
                    "secondary asset (primary=%lu) at %@",
                   (unsigned long)clipIndex, secClip.sourceURL]));
    }
    return nil;
  }

  // ── 6. Create AVAssetReader for secondary ────────────────────────────────
  NSError *secReaderErr = nil;
  AVAssetReader *secReader = [AVAssetReader assetReaderWithAsset:secAsset
                                                           error:&secReaderErr];
  if (!secReader) {
    if (outError) *outError = secReaderErr;
    return nil;
  }

  // ── 7. Set timeRange (starting at secondary asset-local time) ────────────
  // Mirrors the primary reader timeRange logic in _buildReaderForClipIndex:.
  CMTime secAssetStart = CMTimeMakeWithSeconds(startTimeSecs, 600);
  CMTime secAssetEnd   = CMTimeMakeWithSeconds(secClip.trimEndSeconds, 600);
  CMTime secAssetDur   = secAsset.duration;

  if (CMTIME_IS_VALID(secAssetDur) &&
      CMTimeCompare(secAssetStart, secAssetDur) >= 0) {
    secAssetStart = secAssetDur; // start beyond end → immediate EOS
  }
  CMTime secReadEnd = secAssetEnd;
  if (CMTIME_IS_VALID(secAssetDur) &&
      CMTimeCompare(secAssetEnd, secAssetDur) > 0) {
    secReadEnd = secAssetDur;
  }
  if (CMTimeCompare(secAssetStart, secReadEnd) < 0) {
    CMTime secReadDuration = CMTimeSubtract(secReadEnd, secAssetStart);
    secReader.timeRange = CMTimeRangeMake(secAssetStart, secReadDuration);
  }

  // ── 8. Build video composition for orientation normalization (Phase 7.9) ──
  // Apply preferredTransform at decode time, matching the primary reader path.
  // See _buildReaderForClipIndex: § Phase 7.9 for the deprecation note on
  // videoCompositionWithPropertiesOfAsset: (deprecated iOS 18 but functional).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  AVMutableVideoComposition *secVideoComposition =
      [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:secAsset];
#pragma clang diagnostic pop

  // Apply canvas normalization when _targetRenderSize is set, mirroring the
  // primary path in _buildReaderForClipIndex: §Phase 7.9 aspect-fit.
  if (_targetRenderSize.width > 0 && _targetRenderSize.height > 0) {
    CGAffineTransform secPrefTx = secVideoTrack.preferredTransform;
    CGSize secNaturalSize = secVideoTrack.naturalSize;
    CGRect secDisplayRect =
        CGRectApplyAffineTransform(
            CGRectMake(0, 0, secNaturalSize.width, secNaturalSize.height),
            secPrefTx);
    CGFloat secDisplayW = fabs(secDisplayRect.size.width);
    CGFloat secDisplayH = fabs(secDisplayRect.size.height);

    CGFloat canvasW = _targetRenderSize.width;
    CGFloat canvasH = _targetRenderSize.height;
    CGFloat secFitScale = 1.0;
    if (secDisplayW > 0 && secDisplayH > 0) {
      secFitScale = MIN(canvasW / secDisplayW, canvasH / secDisplayH);
    }
    CGFloat secTx = (canvasW - secDisplayW * secFitScale) / 2.0;
    CGFloat secTy = (canvasH - secDisplayH * secFitScale) / 2.0;

    CGAffineTransform secFitTransform =
        CGAffineTransformConcat(
            secPrefTx,
            CGAffineTransformConcat(
                CGAffineTransformMakeScale(secFitScale, secFitScale),
                CGAffineTransformMakeTranslation(secTx, secTy)));

    AVMutableVideoCompositionLayerInstruction *secLayerInst =
        [AVMutableVideoCompositionLayerInstruction
            videoCompositionLayerInstructionWithAssetTrack:secVideoTrack];
    [secLayerInst setTransform:secFitTransform atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *secInstruction =
        [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    secInstruction.timeRange =
        CMTimeRangeMake(kCMTimeZero, secAsset.duration);
    secInstruction.layerInstructions = @[secLayerInst];

    secVideoComposition.renderSize = _targetRenderSize;
    secVideoComposition.instructions = @[secInstruction];

    // Phase 7.x-Q3E: Store secondary source display dimensions in the layout
    // config so _VGTCNCompositePiP can aspect-fill the visible secondary content
    // into the PiP rect (removing black bars from the secondary canvas aspect-fit).
    if (clipIndex < _dualCameraLayoutConfigs.count) {
      NSValue *cfgValue = _dualCameraLayoutConfigs[clipIndex];
      _VGTCNDualCameraLayoutConfig cfg;
      [cfgValue getValue:&cfg];
      if (cfg.enabled && cfg.mode == _VGTCNDualCameraLayoutModePiP) {
        cfg.pip.secondarySourceSize = CGSizeMake(secDisplayW, secDisplayH);
        NSMutableArray *mutableConfigs =
            [NSMutableArray arrayWithArray:_dualCameraLayoutConfigs];
        mutableConfigs[clipIndex] =
            [NSValue value:&cfg withObjCType:@encode(_VGTCNDualCameraLayoutConfig)];
        _dualCameraLayoutConfigs = [mutableConfigs copy];
        os_log(sTimelineLog,
               "[VGTCNode-Q3E] stored secondarySourceSize=%.0fx%.0f for clip=%lu",
               secDisplayW, secDisplayH, (unsigned long)clipIndex);
      }
    }
  }

  // ── 9. Create and configure output ──────────────────────────────────────
  NSDictionary *secOutputSettings = _VGTCNOutputSettings();
  AVAssetReaderVideoCompositionOutput *secOutput =
      [[AVAssetReaderVideoCompositionOutput alloc]
          initWithVideoTracks:@[secVideoTrack]
               videoSettings:secOutputSettings];
  secOutput.videoComposition = secVideoComposition;
  secOutput.alwaysCopiesSampleData = NO;

  if (![secReader canAddOutput:secOutput]) {
    if (outError) {
      *outError = _VGTCNError(
          33, ([NSString stringWithFormat:
                   @"VGTimelineCompositorNode (Q2): cannot add output for "
                    "secondary clip (primary=%lu).",
                   (unsigned long)clipIndex]));
    }
    return nil;
  }
  [secReader addOutput:secOutput];

  // ── 10. Start reading ────────────────────────────────────────────────────
  if (![secReader startReading]) {
    if (outError) *outError = secReader.error;
    return nil;
  }

  // ── 11. Compute secondary source FPS ────────────────────────────────────
  double secSourceFPS = 30.0;
  if (secVideoComposition &&
      CMTIME_IS_VALID(secVideoComposition.frameDuration) &&
      CMTimeGetSeconds(secVideoComposition.frameDuration) > 0.0) {
    secSourceFPS = 1.0 / CMTimeGetSeconds(secVideoComposition.frameDuration);
  } else if (secVideoTrack.nominalFrameRate > 0.0f) {
    secSourceFPS = secVideoTrack.nominalFrameRate;
  }

  // ── 12. Build and return secondary _VGClipReader ─────────────────────────
  _VGClipReader *secClipReader = [[_VGClipReader alloc] init];
  secClipReader.clipIndex      = clipIndex; // primary timeline index (for logging/cache keying)
  secClipReader.reader         = secReader;
  secClipReader.trackOutput    = secOutput;
  secClipReader.sourceFPS      = secSourceFPS;
  secClipReader.isStaticSource = NO;
  secClipReader.isReversed     = NO; // reversed guard above ensures this is NO
  secClipReader.resolvedClip   = secClip; // Phase 7.x-Q3A: bind secondary descriptor.

  os_log(sTimelineLog,
         "[VGTCNode-Q3A] secondary video reader built: primary clip=%lu "
         "secStart=%.3fs fps=%.1f",
         (unsigned long)clipIndex, startTimeSecs, secSourceFPS);

  return secClipReader;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.20C: Sidecar reader builder
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 7.20C: Build a forward AVAssetReader from the pre-transcoded reverse
/// sidecar file for a reversed clip in preview mode.
///
/// The sidecar is an All-Intra H.264 .mov that contains the reversed clip's
/// frames encoded in forward sequential order (frame 0 = original trimEnd,
/// frame N = original trimStart). The sidecar track has identity
/// preferredTransform (orientation is pre-baked into pixel data by the
/// transcoder). No orientation layer instruction is applied here.
///
/// Time mapping (sidecar_t = trimEnd − tAsset):
///
///   The caller passes startAtTime = tAsset (original source-local PTS,
///   computed by the reverse formula: tAsset = trimEnd − elapsedAsset).
///
///   Sidecar_t = trimEnd − tAsset = elapsedAsset
///
///   At clip start (elapsedTimeline=0): tAsset=trimEnd → sidecar_t=0     ✓
///   At clip end:   tAsset≈trimStart   → sidecar_t≈trimEnd−trimStart     ✓
///
/// This mapping correctly positions the forward sidecar reader at the seek
/// point corresponding to the original reverse-playback position.
///
/// @param clipIndex   Index into _clips.
/// @param startAtTime Original source-local tAsset seconds (reverse formula).
/// @param sidecarPath Absolute path to the ready sidecar .mov file.
/// @return A populated _VGClipReader with isReversed=NO, or nil on any
///         failure (caller falls through to Phase 7.19 generator path).
- (_VGClipReader *_Nullable)
    _buildSidecarReaderForClipIndex:(NSUInteger)clipIndex
                         startAtTime:(double)startAtTime
                         sidecarPath:(NSString *)sidecarPath {
  VGClipDescriptor *clip = _clips[clipIndex];

  // ── Map original source tAsset → sidecar time ────────────────────────────
  // sidecar_t = trimEnd − tAsset  (see header comment for derivation)
  double sidecarStart = clip.trimEndSeconds - startAtTime;
  sidecarStart = MAX(0.0, sidecarStart);

  // ── Build AVURLAsset from sidecar path ────────────────────────────────────
  NSURL *sidecarURL = [NSURL fileURLWithPath:sidecarPath];
  if (!sidecarURL) {
    os_log_error(sTimelineLog,
                 "[VGTCNode] 7.20C sidecar: invalid path clip=%lu path=%{public}@",
                 (unsigned long)clipIndex, sidecarPath);
    return nil;
  }

  AVURLAsset *sidecarAsset = [AVURLAsset URLAssetWithURL:sidecarURL options:nil];
  NSArray<AVAssetTrack *> *scTracks =
      [sidecarAsset tracksWithMediaType:AVMediaTypeVideo];
  AVAssetTrack *scTrack = scTracks.firstObject;
  if (!scTrack) {
    os_log_error(sTimelineLog,
                 "[VGTCNode] 7.20C sidecar: no video track clip=%lu",
                 (unsigned long)clipIndex);
    return nil;
  }

  // ── Create AVAssetReader ──────────────────────────────────────────────────
  NSError *scReaderErr = nil;
  AVAssetReader *scReader =
      [AVAssetReader assetReaderWithAsset:sidecarAsset error:&scReaderErr];
  if (!scReader) {
    os_log_error(
        sTimelineLog,
        "[VGTCNode] 7.20C sidecar: reader create failed clip=%lu: %{public}@",
        (unsigned long)clipIndex, scReaderErr.localizedDescription);
    return nil;
  }

  // ── Set timeRange from sidecarStart to end of sidecar ────────────────────
  // The sidecar covers the full reversed clip segment. Seek to the correct
  // forward offset within it. Same pattern as the main _buildReaderForClipIndex:.
  CMTime scAssetStart = CMTimeMakeWithSeconds(sidecarStart, 600);
  CMTime scAssetDur   = sidecarAsset.duration;
  if (CMTIME_IS_VALID(scAssetDur) &&
      CMTimeCompare(scAssetStart, scAssetDur) < 0) {
    CMTime scRemaining = CMTimeSubtract(scAssetDur, scAssetStart);
    scReader.timeRange = CMTimeRangeMake(scAssetStart, scRemaining);
  }
  // else: sidecarStart >= duration → reader produces no samples (EOS immediately).
  //   Caller's pullFrame: will handle this as a normal EOS from the completed reader.

  // ── Build video composition with aspect-fit centering ────────────────────
  // The sidecar track has identity preferredTransform (orientation pre-baked by
  // the transcoder). However, the sidecar file encodes the CONTENT pixels only
  // (tight portrait rectangle, e.g. 202×360), NOT a full canvas-sized frame.
  // To correctly place the portrait content centered in the landscape canvas
  // (e.g. 640×360), we must add an explicit layer instruction that:
  //   1. Scales the content to aspect-fit within _targetRenderSize.
  //   2. Translates it to the centered position.
  // This mirrors the Phase 7.9 aspect-fit logic in _buildReaderForClipIndex:
  // for normal clips (Steps 2–6), but uses the sidecar track's natural size
  // instead of applying preferredTransform (which is identity here).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  AVMutableVideoComposition *scComposition =
      [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:sidecarAsset];
#pragma clang diagnostic pop

  if (_targetRenderSize.width > 0 && _targetRenderSize.height > 0) {
    // ── Phase 7.20 sidecar centering ──────────────────────────────────────────
    // Step 1: Read sidecar natural size. preferredTransform is identity, so
    // naturalSize IS the display size. Use fabs for defensive correctness.
    CGSize scNatural = scTrack.naturalSize;
    CGFloat naturalW = fabs(scNatural.width);
    CGFloat naturalH = fabs(scNatural.height);
    CGFloat canvasW  = _targetRenderSize.width;
    CGFloat canvasH  = _targetRenderSize.height;

    if (naturalW > 0 && naturalH > 0) {
      // Step 2: Compute aspect-fit scale (min, not max — no cropping).
      CGFloat fitScale = MIN(canvasW / naturalW, canvasH / naturalH);

      // Step 3: Center-translate the scaled content within the canvas.
      CGFloat tx = (canvasW - naturalW * fitScale) / 2.0;
      CGFloat ty = (canvasH - naturalH * fitScale) / 2.0;

      // Step 4: Build the fit transform. Convention matches Phase 7.9:
      //   preferredTransform (identity) → scale → center translate.
      //   Result: x' = x * fitScale + tx, y' = y * fitScale + ty.
      CGAffineTransform scFitTransform =
          CGAffineTransformConcat(
              CGAffineTransformIdentity,
              CGAffineTransformConcat(
                  CGAffineTransformMakeScale(fitScale, fitScale),
                  CGAffineTransformMakeTranslation(tx, ty)));

      // Step 5: Build layer instruction with the computed transform.
      AVMutableVideoCompositionLayerInstruction *scLayerInstr =
          [AVMutableVideoCompositionLayerInstruction
              videoCompositionLayerInstructionWithAssetTrack:scTrack];
      [scLayerInstr setTransform:scFitTransform atTime:kCMTimeZero];

      // Step 6: Wire instruction into composition.
      AVMutableVideoCompositionInstruction *scInstruction =
          [AVMutableVideoCompositionInstruction videoCompositionInstruction];
      scInstruction.timeRange =
          CMTimeRangeMake(kCMTimeZero, sidecarAsset.duration);
      scInstruction.layerInstructions = @[scLayerInstr];
      scComposition.instructions = @[scInstruction];

      os_log(sTimelineLog,
             "[VGTCNode] 7.20 sidecar centering: clip=%lu natural=%.0fx%.0f "
             "canvas=%.0fx%.0f scale=%.4f tx=%.1f ty=%.1f",
             (unsigned long)clipIndex, naturalW, naturalH,
             canvasW, canvasH, fitScale, tx, ty);
    }

    // Step 7: Set output buffer dimensions to canvas size.
    scComposition.renderSize = _targetRenderSize;
  }

  // ── Configure output ──────────────────────────────────────────────────────
  NSDictionary *outputSettings = _VGTCNOutputSettings();
  AVAssetReaderVideoCompositionOutput *scOutput =
      [[AVAssetReaderVideoCompositionOutput alloc]
          initWithVideoTracks:@[scTrack]
                 videoSettings:outputSettings];
  scOutput.videoComposition        = scComposition;
  scOutput.alwaysCopiesSampleData  = NO;

  if (![scReader canAddOutput:scOutput]) {
    os_log_error(sTimelineLog,
                 "[VGTCNode] 7.20C sidecar: canAddOutput failed clip=%lu",
                 (unsigned long)clipIndex);
    return nil;
  }
  [scReader addOutput:scOutput];

  if (![scReader startReading]) {
    os_log_error(
        sTimelineLog,
        "[VGTCNode] 7.20C sidecar: startReading failed clip=%lu: %{public}@",
        (unsigned long)clipIndex, scReader.error.localizedDescription);
    return nil;
  }

  // ── Compute source FPS (same logic as main reader build) ──────────────────
  double scFPS = 30.0;
  if (scComposition &&
      CMTIME_IS_VALID(scComposition.frameDuration) &&
      CMTimeGetSeconds(scComposition.frameDuration) > 0.0) {
    scFPS = 1.0 / CMTimeGetSeconds(scComposition.frameDuration);
  } else if (scTrack.nominalFrameRate > 0.0f) {
    scFPS = scTrack.nominalFrameRate;
  }

  // ── Populate reader ───────────────────────────────────────────────────────
  _VGClipReader *clipReader     = [[_VGClipReader alloc] init];
  clipReader.clipIndex          = clipIndex;
  clipReader.reader             = scReader;
  clipReader.trackOutput        = scOutput;
  clipReader.sourceFPS          = scFPS;
  clipReader.isReversed         = NO;  // ← sidecar is forward-playable
  clipReader.isStaticSource     = NO;
  clipReader.freezePTS          = nil;
  clipReader.resolvedClip       = _clips[clipIndex]; // Phase 7.x-Q3A: sidecar is always a primary reader.

  os_log(sTimelineLog,
         "[VGTCNode] 7.20C sidecar reader built: clip=%lu sidecarStart=%.3fs "
         "fps=%.1f sidecar=%{public}@",
         (unsigned long)clipIndex, sidecarStart, scFPS,
         sidecarPath.lastPathComponent);

  return clipReader;
}

/// Cancel and nil the active reader, safely releasing AVFoundation resources.
- (void)_tearDownActiveReader {
  if (_activeReader) {
    // Static image readers have reader == nil; nil guard documents intentional no-op.
    if (_activeReader.reader) {
      [_activeReader.reader cancelReading];
    }
    _activeReader = nil;
  }
}

/// Phase 7.10: Cancel and nil the outgoing reader (RR-142).
/// Called when exiting a transition window, on seek, and on invalidate.
/// Idempotent: safe to call when _outgoingReader is already nil.
- (void)_tearDownOutgoingReader {
  if (_outgoingReader) {
    // Static image readers have reader == nil; nil guard documents intentional no-op.
    if (_outgoingReader.reader) {
      [_outgoingReader.reader cancelReading];
    }
    _outgoingReader = nil;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.18B1: Cache metrics and flush
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a snapshot of the compositor-level frame cache metrics.
///
/// Thread-safe: delegates to _VGTimelineFrameCache.statistics which acquires
/// its own os_unfair_lock internally.
///
/// Dictionary keys (all NSNumber/uint64):
///   frameCacheBytes     — current byte usage
///   frameCacheHits      — total cache hits since last flushAll
///   frameCacheMisses    — total cache misses since last flushAll
///   frameCacheEvictions — total LRU evictions since last flushAll
///   frameCacheInserts   — total successful inserts since last flushAll
///   frameCacheEntries   — current number of cached entries
- (NSDictionary<NSString *, NSNumber *> *)cacheStatistics {
  NSDictionary<NSString *, NSNumber *> *inner = [_frameCache statistics];
  return @{
    @"frameCacheBytes":     @(_frameCache.currentBytes),
    @"frameCacheHits":      inner[@"hits"]      ?: @0,
    @"frameCacheMisses":    inner[@"misses"]    ?: @0,
    @"frameCacheEvictions": inner[@"evictions"] ?: @0,
    @"frameCacheInserts":   inner[@"inserts"]   ?: @0,
    @"frameCacheEntries":   inner[@"entries"]   ?: @0,
  };
}

/// Immediately evicts all entries from the compositor-level frame cache and
/// resets all metrics counters.
///
/// Thread-safe: delegates to _VGTimelineFrameCache.flushAll which acquires
/// its own os_unfair_lock internally.
///
/// Use this from the MethodChannel `clearTimelineCache` route to force a cold
/// decode on the next scrub, enabling manual benchmark comparisons.
- (void)flushFrameCache {
  [_frameCache flushAll];
  os_log(sTimelineLog,
         "[VGTCNode] flushFrameCache: frame cache cleared (Phase 7.18B1)");
}

@end
