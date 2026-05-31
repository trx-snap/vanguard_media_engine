// VGTimelineCompositorNode.m
// vanguard_media_engine — Phase 7 Stage 7.5 / Stage 7.10
//
// Phase 7 Stage 7.5:  First executable multi-clip video timeline compositor.
// Phase 7 Stage 7.10: Native crossfade/dissolve and fade transition execution.
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
// ── STAGE 7.5 LIMITATIONS (DOCUMENTED — partially resolved in Phase 7.10) ───
//
//   Image clips:       Rejected at init. Returns nil with error.
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

// ─── Canvas dimension keys (Phase 7.9 aspect-fit normalization) ──────────────
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
@interface _VGClipReader : NSObject
@property(nonatomic) NSUInteger clipIndex; // index in _clips
@property(nonatomic) AVAssetReader *reader;
@property(nonatomic) AVAssetReaderOutput *trackOutput; // Phase 7.9: base type
@property(nonatomic) double sourceFPS;                 // nominal frame rate
@end

@implementation _VGClipReader
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

  // ── Active / outgoing reader state ─────────────────────────────────────────
  // _activeReader:  the incoming (or sole) clip reader. Never nil during decode.
  // _outgoingReader: the outgoing clip reader during a non-hard-cut transition
  //   window. Non-nil only while requestedPTSSecs is within the overlap window
  //   [incomingClip.startTimeSeconds, incomingClip.startTimeSeconds + T].
  //   Torn down when the window ends, on seek, or on invalidate (RR-142).
  _VGClipReader *_activeReader;   // nullable
  _VGClipReader *_outgoingReader; // nullable; non-nil during transition window

  // ── Buffer ownership (RR-36) ──────────────────────────────────────────────
  // Retained +1 by this node. Released before each new pullFrame: decode
  // and on seek/invalidate. VGFrameEnvelope carries +0.
  CVPixelBufferRef _lastDeliveredBuffer; // nullable; +1

  // [7.5C] Frame reuse: asset-local PTS and duration of the last decoded frame.
  // Used to skip copyNextSampleBuffer when tAsset is within the cached window.
  // Reset on seek, clip switch, init, and invalidate.
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

  // ── (c) Stage 7.5: reject non-video clips ─────────────────────────────────
  // Image clips and audio clips are not supported in this first executable
  // slice. Rejection here means the graph will not prepare rather than silently
  // delivering garbage frames.
  for (NSUInteger i = 0; i < clips.count; i++) {
    VGClipDescriptor *clip = clips[i];
    if (clip.mediaKind != VGClipMediaKindVideo) {
      NSString *kindDesc;
      switch (clip.mediaKind) {
      case VGClipMediaKindImage:
        kindDesc = @"image";
        break;
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
                       @"unsupported "
                        "mediaKind \"%@\" for Stage 7.5. "
                        "Only VGClipMediaKindVideo is supported in this slice. "
                        "Image clips are Stage 7.5B+. Audio timelines are "
                        "Phase 8+.",
                       (unsigned long)i, clip.clipId, kindDesc]));
      }
      return nil;
    }
  }

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

  _lastDeliveredBuffer = NULL;
  _activeReader = nil;
  _outgoingReader = nil;              // Phase 7.10: non-nil only in transition windows
  // [7.5C] Frame reuse tracking: -1 signals "no cached frame".
  _lastDeliveredAssetPTS = -1.0;
  _lastDeliveredAssetDuration = 0.0;
  atomic_store(&_generation, 0);
  atomic_store(&_invalidated, 0);

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
  // elapsed_timeline = requestedPTSSecs - clip.startTimeSeconds
  // elapsed_asset    = elapsed_timeline * clip.speed
  // t_asset          = clip.trimStartSeconds + elapsed_asset
  // Clamped to [trimStartSeconds, trimEndSeconds] for float safety.
  double elapsedTimeline = requestedPTSSecs - activeClip.startTimeSeconds;
  double elapsedAsset = elapsedTimeline * activeClip.speed;
  double tAsset = activeClip.trimStartSeconds + elapsedAsset;
  tAsset = MAX(tAsset, activeClip.trimStartSeconds);
  tAsset = MIN(tAsset, activeClip.trimEndSeconds);

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
      double tAssetOut =
          outgoingClip.trimStartSeconds + elapsedOut * outgoingClip.speed;
      tAssetOut = MAX(tAssetOut, outgoingClip.trimStartSeconds);
      tAssetOut = MIN(tAssetOut, outgoingClip.trimEndSeconds);
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
  // Blend failure returns errorResult — no silent masking (DEC-143).
  if (inTransitionWindow) {
    // Release last delivered buffer; the blend will produce a new one.
    if (_lastDeliveredBuffer) {
      CVPixelBufferRelease(_lastDeliveredBuffer);
      _lastDeliveredBuffer = NULL;
    }

    float blendAlpha = (transitionDuration > 0.0)
        ? (float)(transitionElapsed / transitionDuration)
        : 1.0f;

    // Pull incoming frame (_activeReader — incoming clip).
    CMSampleBufferRef inSample =
        [_activeReader.trackOutput copyNextSampleBuffer];
    CVPixelBufferRef inPB =
        inSample ? CMSampleBufferGetImageBuffer(inSample) : NULL;
    if (inPB) CVPixelBufferRetain(inPB);
    if (inSample) CFRelease(inSample);

    // Pull outgoing frame (_outgoingReader — outgoing clip).
    CMSampleBufferRef outSample =
        [_outgoingReader.trackOutput copyNextSampleBuffer];
    CVPixelBufferRef outPB =
        outSample ? CMSampleBufferGetImageBuffer(outSample) : NULL;
    if (outPB) CVPixelBufferRetain(outPB);
    if (outSample) CFRelease(outSample);

    CVPixelBufferRef blendedPB = NULL;

    if (inPB && outPB) {
      // Both readers delivered: perform CoreImage blend.
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
    } else if (inPB) {
      // Outgoing reader exhausted early — deliver incoming frame unblended.
      [self _tearDownOutgoingReader];
      blendedPB = inPB;
      inPB = NULL; // ownership transferred
    } else if (outPB) {
      // Incoming reader not yet ready — deliver outgoing frame unblended.
      blendedPB = outPB;
      outPB = NULL;
    } else {
      // Both readers exhausted — skip this frame.
      return [VGFrameResult skippedWithGeneration:request.generation];
    }

    if (inPB)  CVPixelBufferRelease(inPB);
    if (outPB) CVPixelBufferRelease(outPB);

    // Store blended buffer (node holds +1). Disable frame-reuse for transition
    // frames — each blend output is unique.
    _lastDeliveredBuffer = blendedPB;
    _lastDeliveredAssetPTS = -1.0;
    _lastDeliveredAssetDuration = 0.0;

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

  // [7.5C] Frame reuse guard: if the requested asset time falls within the
  // window of the already-decoded frame, return the cached buffer directly
  // without calling copyNextSampleBuffer. This prevents exhausting clip A's
  // AVAssetReader during the paused pre-play period and prevents clip B from
  // being decoded too fast during play.
  if (_lastDeliveredBuffer != NULL && _activeReader != nil) {
    if (tAsset >= _lastDeliveredAssetPTS &&
        tAsset < _lastDeliveredAssetPTS + _lastDeliveredAssetDuration) {
      VGFrameEnvelope env;
      memset(&env, 0, sizeof(env));
      env.mediaType = VGMediaTypeVideo;
      env.payload.videoBuffer = (void *)_lastDeliveredBuffer; // +0; node holds +1
      env.pts = request.requestedPTS;
      env.dts = kCMTimeInvalid;
      env.duration = CMTimeMakeWithSeconds(_lastDeliveredAssetDuration, 600);
      env.generation = request.generation;
      env.metadata = NULL;
      return [VGFrameResult deliveredWithEnvelope:env generation:request.generation];
    }
  }

  // ── Release last delivered buffer before next decode (RR-36) ─────────────
  if (_lastDeliveredBuffer) {
    CVPixelBufferRelease(_lastDeliveredBuffer);
    _lastDeliveredBuffer = NULL;
  }

  // ── Pull next sample from AVAssetReaderOutput (Phase 7.9: VideoCompositionOutput) ──
  // copyNextSampleBuffer returns +1 CMSampleBufferRef.
  // Returns NULL when exhausted (reader.status → Completed) or on error.
  CMSampleBufferRef sample = [_activeReader.trackOutput copyNextSampleBuffer];

  if (!sample) {
    AVAssetReaderStatus status = _activeReader.reader.status;
    if (status == AVAssetReaderStatusCompleted) {
      // This clip is exhausted. If it's the last clip → EOS.
      // If not the last clip, the next pullFrame: will switch to the next
      // clip's reader (activeClipIndex will advance naturally).
      os_log(sTimelineLog,
             "[VGTCNode] clip %lu reader completed at requestedPTS=%.3fs",
             (unsigned long)activeClipIndex, requestedPTSSecs);
      if (activeClipIndex >= _clips.count - 1) {
        return [VGFrameResult endOfStreamWithGeneration:request.generation];
      }
      // Not last clip — return skip. Scheduler will request the next PTS,
      // which will fall in the next clip and build a new reader.
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

  // ── Extract pixel buffer from sample ─────────────────────────────────────
  // CMSampleBufferGetImageBuffer returns +0 CVPixelBufferRef.
  // Must retain before releasing the sample.
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
  if (!pb) {
    // Timing-only or non-image sample — skip.
    CFRelease(sample);
    return [VGFrameResult skippedWithGeneration:request.generation];
  }

  // Retain the pixel buffer BEFORE releasing the sample (Apple Framework
  // Check). After CFRelease(sample), the CVPixelBuffer may be freed if not
  // retained.
  CVPixelBufferRetain(pb); // source now owns +1

  // Extract timing from the sample.
  CMTime samplePTS = CMSampleBufferGetPresentationTimeStamp(sample);
  CMTime sampleDur = CMSampleBufferGetDuration(sample);

  // [7.5C] Update frame reuse cache with asset-local PTS and duration.
  // _lastDeliveredAssetPTS/Duration are used in the reuse guard above on
  // subsequent pulls for the same decoded frame.
  double sPTS = CMTimeGetSeconds(samplePTS);
  double sDur = (CMTIME_IS_VALID(sampleDur) && !CMTIME_IS_INDEFINITE(sampleDur))
      ? CMTimeGetSeconds(sampleDur)
      : (1.0 / _activeReader.sourceFPS);
  _lastDeliveredAssetPTS = sPTS;
  _lastDeliveredAssetDuration = sDur;

  // Release the sample buffer; pixel buffer is now independently retained.
  CFRelease(sample);

  // Compute output PTS: use the global timeline PTS from the request,
  // not the asset-local sample PTS. This ensures downstream nodes
  // (renderer, encoder) see monotonically increasing timeline timestamps.
  CMTime outputPTS = request.requestedPTS;
  CMTime outputDur =
      CMTIME_IS_VALID(sampleDur) && !CMTIME_IS_INDEFINITE(sampleDur)
          ? sampleDur
          : CMTimeMakeWithSeconds(1.0 / _activeReader.sourceFPS, 600);

  // ── Store retained buffer (RR-36: source owns +1) ─────────────────────────
  _lastDeliveredBuffer = pb;

  // ── Build VGFrameEnvelope ─────────────────────────────────────────────────
  // payload.videoBuffer is +0 per VGFrameEnvelope.h contract.
  // The buffer is valid until the next pullFrame: or invalidate.
  VGFrameEnvelope env;
  memset(&env, 0, sizeof(env));
  env.mediaType = VGMediaTypeVideo;
  env.payload.videoBuffer = (void *)pb; // +0 in envelope; node holds +1
  env.pts = outputPTS;
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

  os_log(sTimelineLog,
         "[VGTCNode] built reader: clip=%lu startAt=%.3fs fps=%.1f",
         (unsigned long)clipIndex, startTimeSecs, sourceFPS);

  return clipReader;
}

/// Cancel and nil the active reader, safely releasing AVFoundation resources.
- (void)_tearDownActiveReader {
  if (_activeReader) {
    [_activeReader.reader cancelReading];
    _activeReader = nil;
  }
}

/// Phase 7.10: Cancel and nil the outgoing reader (RR-142).
/// Called when exiting a transition window, on seek, and on invalidate.
/// Idempotent: safe to call when _outgoingReader is already nil.
- (void)_tearDownOutgoingReader {
  if (_outgoingReader) {
    [_outgoingReader.reader cancelReading];
    _outgoingReader = nil;
  }
}

@end
