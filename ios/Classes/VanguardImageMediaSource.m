// VanguardImageMediaSource.m
// Phase 2 — P2-T5: Static image timeline node implementation

#import "VanguardImageMediaSource.h"
#include <stdatomic.h>        // atomic_store/load/compare_exchange_explicit
#import <ImageIO/ImageIO.h>   // CGImageSourceRef, CGImageSourceCreateWithURL


@implementation VanguardImageMediaSource {
    NSURL*                   _imageURL;
    VanguardImageProcessor*  _processor;
    CVPixelBufferRef         _buffer;       // retained; released in dealloc
    VanguardVideoFrameCallback _videoCallback;
    VanguardPlaybackRate     _playbackRate; // always 1.0 — images have no rate

    // P1A-07: VGMediaNode protocol state.
    // _Atomic so any thread can safely read without a lock (guards RR-3).
    // Set to YES BEFORE releasing _buffer (prevents double-free).
    _Atomic(BOOL) _invalidated;
    NSString *_nodeId;   // NSUUID assigned at init; immutable
    NSString *_nodeType; // always @"VanguardImageMediaSource"
}

@synthesize playbackRate = _playbackRate;
@synthesize nodeId = _nodeId;
@synthesize nodeType = _nodeType;

- (instancetype)initWithURL:(NSURL *)imageURL processor:(VanguardImageProcessor *)processor {
    self = [super init];
    if (!self) return nil;
    _imageURL     = imageURL;
    _processor    = processor;
    _playbackRate = 1.0;
    // P1A-07: VGMediaNode identity and invalidation flag.
    atomic_store_explicit(&_invalidated, NO, memory_order_relaxed);
    _nodeId   = [NSUUID UUID].UUIDString;
    _nodeType = @"VanguardImageMediaSource";
    return self;
}

- (void)dealloc {
    if (_buffer) {
        CVPixelBufferRelease(_buffer);
        _buffer = NULL;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)start {
    // Decode the image synchronously (images are small; acceptable on init path).
    // Phase 4: move to background dispatch if images are HEIC > 12MP.
    CGImageSourceRef src = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)_imageURL, nil);
    if (!src) {
        NSLog(@"[VanguardImageSource] Cannot open: %@", _imageURL.lastPathComponent);
        return;
    }
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nil);
    CFRelease(src);
    if (!img) return;

    if (_buffer) { CVPixelBufferRelease(_buffer); _buffer = NULL; }
    _buffer = [_processor pixelBufferFromCGImage:img];
    CGImageRelease(img);

    // Fire immediately — renderer displays the image as soon as start is called.
    if (_videoCallback && _buffer) {
        _videoCallback(CVPixelBufferRetain(_buffer), kCMTimeZero);
        CVPixelBufferRelease(_buffer); // balance the retain above
    }
}

- (void)stop {
    // Buffer is kept alive (images hold indefinitely until explicitly replaced).
    // Do NOT release _buffer here; it may be displayed again on resume.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMediaNode (P1A-07)
// ─────────────────────────────────────────────────────────────────────────────
// prepareWithCompletion: and invalidate are additive. They do not alter
// start()/stop() or any other production path (C-1).
// Neither method is called anywhere in production code.

/// Asynchronously decodes the image on a USER_INITIATED background queue.
/// Does NOT modify start()/stop() (C-1). Completion fires on the background
/// queue, never synchronously on the caller's thread (guards RR-6).
- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    // Guard: already invalidated.
    if (atomic_load_explicit(&_invalidated, memory_order_acquire)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            completion([NSError
                errorWithDomain:@"VGMediaNode" code:-1
                userInfo:@{NSLocalizedDescriptionKey:
                    @"prepareWithCompletion: called after invalidate"}]);
        });
        return;
    }

    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (!s || atomic_load_explicit(&s->_invalidated, memory_order_acquire)) {
            completion([NSError
                errorWithDomain:@"VGMediaNode" code:-2
                userInfo:@{NSLocalizedDescriptionKey:
                    @"prepareWithCompletion: invalidated before execution"}]);
            return;
        }

        // Decode the image to a CVPixelBuffer and cache it in _buffer.
        // Mirrors the synchronous decode in start(), but on a background queue.
        CGImageSourceRef src = CGImageSourceCreateWithURL(
            (__bridge CFURLRef)s->_imageURL, nil);
        if (!src) {
            completion([NSError
                errorWithDomain:@"VGMediaNode" code:-3
                userInfo:@{NSLocalizedDescriptionKey:
                    @"prepareWithCompletion: cannot open image URL"}]);
            return;
        }
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nil);
        CFRelease(src);
        if (!img) {
            completion([NSError
                errorWithDomain:@"VGMediaNode" code:-4
                userInfo:@{NSLocalizedDescriptionKey:
                    @"prepareWithCompletion: cannot decode image"}]);
            return;
        }

        CVPixelBufferRef newBuf = [s->_processor pixelBufferFromCGImage:img];
        CGImageRelease(img);

        if (atomic_load_explicit(&s->_invalidated, memory_order_acquire)) {
            // Invalidated during decode — discard decoded buffer, do not store.
            if (newBuf) CVPixelBufferRelease(newBuf);
            completion([NSError
                errorWithDomain:@"VGMediaNode" code:-5
                userInfo:@{NSLocalizedDescriptionKey:
                    @"prepareWithCompletion: invalidated during decode"}]);
            return;
        }

        // Swap into _buffer (release the old one if present).
        if (s->_buffer) CVPixelBufferRelease(s->_buffer);
        s->_buffer = newBuf; // takes ownership
        completion(nil);
    });
}

/// Releases the pre-decoded buffer and prevents future work.
/// Sets _invalidated = YES BEFORE releasing _buffer (guards RR-3, double-free).
/// Idempotent: second call is a no-op (CAS NO→YES).
/// Does NOT alter start()/stop() or any other production path (C-1).
- (void)invalidate {
    // CAS: only the first caller transitions NO → YES.
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong_explicit(
            &_invalidated, &expected, YES,
            memory_order_acq_rel, memory_order_acquire)) {
        return; // already invalidated
    }
    // Flag is now YES. Safe to release the pre-decoded buffer.
    if (_buffer) {
        CVPixelBufferRelease(_buffer);
        _buffer = NULL;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — State
// ─────────────────────────────────────────────────────────────────────────────

- (CMTime)currentTime {
    // Static image: always at time zero on the output timeline.
    return kCMTimeZero;
}

- (CMTime)duration {
    // Static images are held indefinitely.
    return kCMTimeIndefinite;
}

- (void)seekTo:(CMTime)time {
    // No-op. Static images do not have a time axis.
    // Re-fire the callback in case the renderer dropped the first frame
    // during a rapid seek sequence.
    if (_videoCallback && _buffer) {
        _videoCallback(CVPixelBufferRetain(_buffer), kCMTimeZero);
        CVPixelBufferRelease(_buffer);
    }
}

- (void)setPlaybackRate:(VanguardPlaybackRate)rate {
    _playbackRate = rate; // stored but unused; images have no rate
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — Callbacks
// ─────────────────────────────────────────────────────────────────────────────

- (void)setVideoCallback:(VanguardVideoFrameCallback)callback {
    _videoCallback = [callback copy];
}

- (void)setAudioCallback:(nullable VanguardAudioBufferCallback)callback {
    // Static images have no audio.
    (void)callback;
}

@end
