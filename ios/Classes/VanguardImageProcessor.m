// VanguardImageProcessor.m
// Phase 2 — P2-T4: CGImage → CVPixelBuffer processing implementation

#import "VanguardImageProcessor.h"
#import <UMF/VGMetalFilterNode.h>  // Phase 4: processEnvelope:device:
#import <UMF/VGFrameEnvelope.h>    // Phase 4: VGFrameEnvelope, VGMediaTypeVideo

@implementation VanguardImageProcessor {
    id<MTLDevice>        _device;
    CVPixelBufferPoolRef _pool;   // borrowed reference — owned by VanguardMetalRenderer
    dispatch_queue_t     _batchQueue;
}

// Phase A1-S1: pool is a borrowed reference — owner (VanguardMetalRenderer)
// retains the CVPixelBufferPool for its lifetime. We store it as a plain
// pointer assignment; no CFRetain/CFRelease here.
@synthesize pool = _pool;

- (instancetype)initWithDevice:(id<MTLDevice>)device pool:(CVPixelBufferPoolRef)pool {
    self = [super init];
    if (!self) return nil;
    _device     = device;
    _pool       = pool;
    _batchQueue = dispatch_queue_create("com.vanguard.imageprocessor.batch",
                                        DISPATCH_QUEUE_SERIAL);
    return self;
}

// Custom setter — plain assignment; lifetime managed by the renderer.
- (void)setPool:(CVPixelBufferPoolRef)pool {
    _pool = pool;
}

// Custom getter — returns the current borrowed pool reference.
- (CVPixelBufferPoolRef)pool {
    return _pool;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Pool-backed CGImage → CVPixelBuffer
// ─────────────────────────────────────────────────────────────────────────────

- (nullable CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    if (!image) return NULL;

    size_t w = CGImageGetWidth(image);
    size_t h = CGImageGetHeight(image);

    CVPixelBufferRef pb = NULL;

    if (_pool) {
        // Zero-alloc path (after warmup) — pool produces IOSurface-backed buffer
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &pb);
        if (status != kCVReturnSuccess || !pb) {
            NSLog(@"[VanguardImageProc] Pool exhausted — dropping frame (status=%d)", status);
            return NULL;
        }
    } else {
        // Fallback: direct alloc (first call before pool is ready, or no pool provided)
        NSDictionary* attrs = @{
            (id)kCVPixelBufferMetalCompatibilityKey:           @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey:         @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        };
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)attrs, &pb);
        if (status != kCVReturnSuccess || !pb) return NULL;
    }

    // Draw into the pixel buffer.
    // CRITICAL: Use the pixel buffer's own dimensions (pbW × pbH) for both the
    // CGBitmapContext and the draw rect — NOT the CGImage's w × h.
    //
    // When a pool buffer is smaller than the source image (e.g. pool is 1080×1920
    // but gallery photo is 4032×3024), stride = CVPixelBufferGetBytesPerRow(pb)
    // is sized for pbW (≈4320 bytes/row for 1080px). Creating the context with
    // w=4032 requires 4032×4 = 16128 bytes/row > stride → CGBitmapContextCreate
    // returns NULL → CGContextDrawImage is a no-op → all pixels stay zero → black.
    //
    // Using pbW/pbH lets CGContextDrawImage scale the source image to fit the
    // buffer dimensions, which is the correct display behaviour (scale-to-fill).
    // For the direct-alloc path (no pool), pb was created at w×h so pbW==w and
    // pbH==h — behaviour is identical to before.
    CVPixelBufferLockBaseAddress(pb, 0);
    void*  data   = CVPixelBufferGetBaseAddress(pb);
    size_t pbW    = CVPixelBufferGetWidth(pb);
    size_t pbH    = CVPixelBufferGetHeight(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        data, pbW, pbH, 8, stride, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)pbW, (CGFloat)pbH), image);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    return pb; // caller must CVPixelBufferRelease
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - UIImage → CVPixelBuffer (orientation-aware)
// ─────────────────────────────────────────────────────────────────────────────

- (nullable CVPixelBufferRef)pixelBufferFromUIImage:(UIImage *)image {
    if (!image || !image.CGImage) return NULL;

    // UIImage.size is already display-correct (EXIF orientation applied by UIKit).
    // Use these dimensions for the direct-alloc path.
    size_t displayW = (size_t)image.size.width;
    size_t displayH = (size_t)image.size.height;
    if (displayW == 0 || displayH == 0) return NULL;

    CVPixelBufferRef pb = NULL;

    if (_pool) {
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &pb);
        if (status != kCVReturnSuccess || !pb) {
            NSLog(@"[VanguardImageProc] pixelBufferFromUIImage: pool exhausted (status=%d)", status);
            return NULL;
        }
    } else {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferMetalCompatibilityKey:           @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey:         @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        };
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, displayW, displayH,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)attrs, &pb);
        if (status != kCVReturnSuccess || !pb) return NULL;
    }

    size_t pbW    = CVPixelBufferGetWidth(pb);
    size_t pbH    = CVPixelBufferGetHeight(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);

    CVPixelBufferLockBaseAddress(pb, 0);
    void *data = CVPixelBufferGetBaseAddress(pb);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        data, pbW, pbH, 8, stride, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGContextTranslateCTM(ctx, 0, (CGFloat)pbH);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        UIGraphicsPushContext(ctx);
        [image drawInRect:CGRectMake(0, 0, (CGFloat)pbW, (CGFloat)pbH)];
        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    NSLog(@"[VanguardImageProc] draw: uiImg=%.0fx%.0f orient=%ld cgImg=%zux%zu pb=%zux%zu stride=%zu",
          image.size.width, image.size.height, (long)image.imageOrientation,
          CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage),
          pbW, pbH, stride);

    return pb; // caller must CVPixelBufferRelease
}

// ─────────────────────────────────────────────────────────────────────────────

#pragma mark - Filter Chain (Phase 4 hook — passthrough in Phase 2)
// ─────────────────────────────────────────────────────────────────────────────

- (CVPixelBufferRef)applyFilterChain:(NSArray *)chain
                            toBuffer:(CVPixelBufferRef)input
                              atTime:(CMTime)t
                              device:(id<MTLDevice>)device {
  // Phase 4: iterate filter nodes sequentially via processEnvelope:device:
  // Empty chain or nil device → passthrough (no extra retain).
  if (!chain.count || !device || !input) {
    return input;
  }

  // current tracks the buffer flowing through the chain.
  // ownsCurrentBuffer: YES when a filter produced a NEW buffer (we must release it).
  // NO when current == input (caller owns, no extra retain).
  CVPixelBufferRef current = input;
  BOOL ownsCurrentBuffer = NO;

  // Phase 4F: track metadata from the last filter's output envelope so it can be
  // propagated to the next filter's input envelope. This allows VGSegmentationNode
  // to attach mask metadata that BeautyV2FilterGroup reads downstream.
  void *currentMetadata = NULL; // starts NULL — no metadata from source

  for (id node in chain) {
    if (![node conformsToProtocol:@protocol(VGMetalFilterNode)]) {
      continue;
    }
    id<VGMetalFilterNode> filterNode = (id<VGMetalFilterNode>)node;

    // Wrap current buffer in an envelope for the protocol API.
    VGFrameEnvelope inEnvelope;
    memset(&inEnvelope, 0, sizeof(inEnvelope));
    inEnvelope.mediaType         = VGMediaTypeVideo;
    inEnvelope.pts               = t;
    inEnvelope.payload.videoBuffer = (void *)current;
    // Phase 4F: carry forward metadata from previous filter's output.
    // This allows VGSegmentationNode → BeautyV2FilterGroup metadata flow.
    inEnvelope.metadata          = currentMetadata;

    // processEnvelope:device: returns either:
    //   - an envelope with a NEW videoBuffer (+1 owned by the scheduler contract), or
    //   - the same envelope/buffer (passthrough).
    VGFrameEnvelope outEnvelope = [filterNode processEnvelope:inEnvelope device:device];
    CVPixelBufferRef result = (CVPixelBufferRef)outEnvelope.payload.videoBuffer;

    if (!result) {
      continue; // filter signalled failure — keep current
    }

    if (result != current) {
      // Filter produced a new buffer. Release the previous intermediate if we own it.
      if (ownsCurrentBuffer) {
        CVPixelBufferRelease(current);
      }
      // processEnvelope: follows the scheduler ownership contract: the new buffer
      // has a +1 retain that the receiver (us) now owns.
      current = result;
      ownsCurrentBuffer = YES;
    }
    // If result == current, filter was a passthrough — no ownership change.

    // Phase 4F: capture metadata from this filter's output for the next filter.
    // Note: we do NOT retain/release here — the metadata lifetime is managed by
    // the producing filter (VGSegmentationNode retains it in CopyWithMetadata)
    // and we release it once at the end of the chain.
    currentMetadata = outEnvelope.metadata;
  }

  // Phase 4F (DEC-102): release any metadata that was attached to the final
  // envelope. The metadata NSDictionary was CFRetained by VGSegmentationNode's
  // VGFrameEnvelopeCopyWithMetadata; we release it here after all consumers
  // (BeautyV2FilterGroup) have read it.
  // NOTE: use a stack envelope wrapper so VGFrameEnvelopeReleaseMetadata can
  // NULL the pointer — mandatory per DEC-102 (no direct CFRelease).
  if (currentMetadata) {
    VGFrameEnvelope cleanupEnv;
    memset(&cleanupEnv, 0, sizeof(cleanupEnv));
    cleanupEnv.metadata = currentMetadata;
    VGFrameEnvelopeReleaseMetadata(&cleanupEnv);
    currentMetadata = NULL;
  }

  return current;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Batch Async Processing (filmstrip)
// ─────────────────────────────────────────────────────────────────────────────

- (void)processImages:(NSArray<NSURL *> *)urls
           completion:(void(^)(NSArray<NSValue *> *buffers))completion {
    if (!completion) return;

    __weak __typeof(self) weakSelf = self;
    dispatch_async(_batchQueue, ^{
        NSMutableArray<NSValue *>* results = [NSMutableArray arrayWithCapacity:urls.count];

        for (NSURL* url in urls) {
            __strong __typeof(weakSelf) s = weakSelf;
            if (!s) break;

            CGImageSourceRef src = CGImageSourceCreateWithURL(
                (__bridge CFURLRef)url, nil);
            if (!src) {
                [results addObject:[NSValue valueWithPointer:NULL]];
                continue;
            }

            CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nil);
            CFRelease(src);
            if (!img) {
                [results addObject:[NSValue valueWithPointer:NULL]];
                continue;
            }

            CVPixelBufferRef pb = [s pixelBufferFromCGImage:img];
            CGImageRelease(img);

            // Wrap as NSValue pointer — caller CVPixelBufferRelease each non-NULL
            [results addObject:[NSValue valueWithPointer:pb]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion([results copy]);
        });
    });
}

@end
