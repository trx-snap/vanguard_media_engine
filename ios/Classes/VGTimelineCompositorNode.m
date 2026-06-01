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
    VGClipDescriptor *outgoingClipDesc = _clips[outgoingClipIndex];
    double elapsedOut = requestedPTSSecs - outgoingClipDesc.startTimeSeconds;
    double tAssetOut = outgoingClipDesc.trimStartSeconds +
                       elapsedOut * outgoingClipDesc.speed;
    tAssetOut = MAX(tAssetOut, outgoingClipDesc.trimStartSeconds);
    tAssetOut = MIN(tAssetOut, outgoingClipDesc.trimEndSeconds);

    // Pull outgoing frame with per-reader reuse guard + Phase 7.11 transform.
    NSError *outErr = nil;
    CVPixelBufferRef outPB = [self _pullBufferFromReader:_outgoingReader
                                             atAssetTime:tAssetOut
                                                   error:&outErr];

    // Pull incoming frame with per-reader reuse guard + Phase 7.11 transform.
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

  // Use asset-local duration from per-reader cache for the output envelope.
  double sDur = _activeReader.lastDeliveredAssetDuration;
  CMTime outputDur = (sDur > 0.0)
      ? CMTimeMakeWithSeconds(sDur, 600)
      : CMTimeMakeWithSeconds(1.0 / _activeReader.sourceFPS, 600);

  VGFrameEnvelope env;
  memset(&env, 0, sizeof(env));
  env.mediaType = VGMediaTypeVideo;
  env.payload.videoBuffer = (void *)pb; // +0 in envelope; node holds +1
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
    VGClipDescriptor *clip = _clips[reader.clipIndex];

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

  // ── 4. Apply Phase 7.11 per-clip transform (identity optimization: skip if identity) ──
  VGClipTransformDescriptor *td = _clips[reader.clipIndex].transform;
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
