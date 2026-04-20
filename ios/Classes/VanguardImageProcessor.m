// VanguardImageProcessor.m
// Phase 2 — P2-T4: CGImage → CVPixelBuffer processing implementation

#import "VanguardImageProcessor.h"

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

    // Draw into the pixel buffer
    CVPixelBufferLockBaseAddress(pb, 0);
    void*  data   = CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        data, w, h, 8, stride, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), image);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    return pb; // caller must CVPixelBufferRelease
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Filter Chain (Phase 4 hook — passthrough in Phase 2)
// ─────────────────────────────────────────────────────────────────────────────

- (CVPixelBufferRef)applyFilterChain:(NSArray *)chain
                            toBuffer:(CVPixelBufferRef)input
                              atTime:(CMTime)t {
    // Phase 2: empty filter chain is the only case; return input unchanged.
    // Phase 4: iterate chain, pass through GPU Metal compute shaders.
    // No retain/release needed — caller owns the input buffer lifecycle.
    (void)chain; (void)t;
    return input;
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
