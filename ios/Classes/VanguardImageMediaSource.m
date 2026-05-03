// VanguardImageMediaSource.m
// Phase 2 — P2-T5: Static image timeline node implementation

#import "VanguardImageMediaSource.h"
#import <ImageIO/ImageIO.h> // CGImageSourceRef, CGImageSourceCreateWithURL
#include <stdatomic.h>      // atomic_store/load/compare_exchange_explicit

@implementation VanguardImageMediaSource {
  NSURL *_imageURL;
  VanguardImageProcessor *_processor;
  CVPixelBufferRef _buffer;    // retained; released in dealloc; used for display callbacks
  CVPixelBufferRef _rawBuffer; // independent +1 retain of the original decoded image;
                               // used ONLY by copyRawBuffer; never handed to the renderer
  VanguardVideoFrameCallback _videoCallback;
  VanguardPlaybackRate _playbackRate; // always 1.0 — images have no rate

  // Display-correct image dimensions set in prepareWithCompletion: after UIImage
  // decode. UIImage.size already accounts for EXIF orientation, so for a portrait
  // photo captured in landscape orientation this is {w, h} with w < h.
  // Read by VanguardGraphRuntime.prepareWithURL after the semaphore wait to size
  // the session pixel buffer pool at the correct aspect ratio.
  CGSize _renderSize;

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
@synthesize renderSize = _renderSize;

// P4-2: VGMediaNode topology role — frame source.
- (VGNodeRole)nodeRole { return VGNodeRoleSource; }

- (instancetype)initWithURL:(NSURL *)imageURL
                  processor:(VanguardImageProcessor *)processor {
  self = [super init];
  if (!self)
    return nil;
  _imageURL = imageURL;
  _processor = processor;
  _playbackRate = 1.0;
  // P1A-07: VGMediaNode identity and invalidation flag.
  atomic_store_explicit(&_invalidated, NO, memory_order_relaxed);
  _nodeId = [NSUUID UUID].UUIDString;
  _nodeType = @"VanguardImageMediaSource";
  return self;
}

- (void)dealloc {
  if (_rawBuffer) {
    CVPixelBufferRelease(_rawBuffer);
    _rawBuffer = NULL;
  }
  if (_buffer) {
    CVPixelBufferRelease(_buffer);
    _buffer = NULL;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)start {
  // Preflight H2: decode is always dispatched off the calling thread.
  // Caller context (main, channel, or background) is irrelevant —
  // the dispatch is unconditional. Guards RR-08.
  __weak __typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s)
      return;

    // Guard 1 — pre-decode: abort if invalidated before we begin.
    if (atomic_load_explicit(&s->_invalidated, memory_order_acquire)) {
      return;
    }

    // UIImage respects EXIF imageOrientation; CGImageSourceCreateImageAtIndex
    // does NOT. Using UIImage + pixelBufferFromUIImage: ensures gallery photos
    // (which carry EXIF orientation 6 for back-camera portrait) are drawn
    // upright instead of appearing rotated 90°.
    NSData *imgData = [NSData dataWithContentsOfURL:s->_imageURL];
    if (!imgData) {
      NSLog(@"[VanguardImageSource] Cannot read data: %@",
            s->_imageURL.lastPathComponent);
      return;
    }
    UIImage *uiImg = [UIImage imageWithData:imgData];
    if (!uiImg) {
      NSLog(@"[VanguardImageSource] Cannot decode UIImage: %@",
            s->_imageURL.lastPathComponent);
      return;
    }

    if (s->_buffer) {
      CVPixelBufferRelease(s->_buffer);
      s->_buffer = NULL;
    }
    s->_buffer = [s->_processor pixelBufferFromUIImage:uiImg];

    // Set _rawBuffer as an independent retain of the original decoded image.
    // _rawBuffer is used exclusively by copyRawBuffer and is never handed to
    // the renderer, ensuring it cannot be freed when the renderer swaps its
    // _latestPixelBuffer on a subsequent filter tap.
    if (s->_rawBuffer) {
      CVPixelBufferRelease(s->_rawBuffer);
      s->_rawBuffer = NULL;
    }
    if (s->_buffer) {
      s->_rawBuffer = CVPixelBufferRetain(s->_buffer);
    }

    // Guard 2 — pre-callback: if invalidated during decode, discard and return.
    if (atomic_load_explicit(&s->_invalidated, memory_order_acquire)) {
      if (s->_rawBuffer) {
        CVPixelBufferRelease(s->_rawBuffer);
        s->_rawBuffer = NULL;
      }
      if (s->_buffer) {
        CVPixelBufferRelease(s->_buffer);
        s->_buffer = NULL;
      }
      return;
    }

    // Fire immediately — renderer displays the image as soon as start is
    // called.
    if (s->_videoCallback && s->_buffer) {
      s->_videoCallback(CVPixelBufferRetain(s->_buffer), kCMTimeZero);
      CVPixelBufferRelease(s->_buffer); // balance the retain above
    }
  });
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
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))completion {
  // Guard: already invalidated.
  if (atomic_load_explicit(&_invalidated, memory_order_acquire)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      completion([NSError
          errorWithDomain:@"VGMediaNode"
                     code:-1
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"prepareWithCompletion: called after invalidate"
                 }]);
    });
    return;
  }

  NSLog(@"[TRACE][IMS1] prepareWithCompletion entered url=%@",
        _imageURL.lastPathComponent);
  __weak __typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s || atomic_load_explicit(&s->_invalidated, memory_order_acquire)) {
      completion([NSError
          errorWithDomain:@"VGMediaNode"
                     code:-2
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"prepareWithCompletion: invalidated before execution"
                 }]);
      return;
    }

    // Decode via UIImage so EXIF imageOrientation is respected (same rationale
    // as start() — gallery JPEG pixels are raw sensor orientation; UIImage
    // applies the EXIF transform via drawInRect: / UIGraphicsPushContext).
    NSData *imgData = [NSData dataWithContentsOfURL:s->_imageURL];
    if (!imgData) {
      completion([NSError
          errorWithDomain:@"VGMediaNode"
                     code:-3
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"prepareWithCompletion: cannot read image data"
                 }]);
      return;
    }
    UIImage *uiImg = [UIImage imageWithData:imgData];
    if (!uiImg) {
      completion([NSError
          errorWithDomain:@"VGMediaNode"
                     code:-4
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"prepareWithCompletion: cannot decode UIImage"
                 }]);
      return;
    }

    // Capture display-correct dimensions before any further async work.
    // UIImage.size is already orientation-adjusted (e.g. a 4032×3024 sensor photo
    // picked in portrait returns size = {3024, 4032}). This value is read by
    // VanguardGraphRuntime after the semaphore wait to size the session pool.
    s->_renderSize = CGSizeMake(uiImg.size.width, uiImg.size.height);
    NSLog(@"[VanguardImageSource] renderSize=%.0fx%.0f url=%@",
          s->_renderSize.width, s->_renderSize.height, s->_imageURL.lastPathComponent);

    CVPixelBufferRef newBuf = [s->_processor pixelBufferFromUIImage:uiImg];
    NSLog(@"[VanguardImageSource] prepare done url=%@ buf=%@",
          s->_imageURL.lastPathComponent, newBuf ? @"ok" : @"nil");

    if (atomic_load_explicit(&s->_invalidated, memory_order_acquire)) {
      // Invalidated during decode — discard decoded buffer, do not store.
      if (newBuf)
        CVPixelBufferRelease(newBuf);
      completion([NSError
          errorWithDomain:@"VGMediaNode"
                     code:-5
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"prepareWithCompletion: invalidated during decode"
                 }]);
      return;
    }

    // Swap into _buffer (release the old one if present).
    // Also update _rawBuffer to the new decoded image so copyRawBuffer stays
    // in sync with the most recently prepared picture.
    if (s->_rawBuffer) {
      CVPixelBufferRelease(s->_rawBuffer);
      s->_rawBuffer = NULL;
    }
    if (s->_buffer)
      CVPixelBufferRelease(s->_buffer);
    s->_buffer = newBuf; // takes ownership
    if (s->_buffer) {
      s->_rawBuffer = CVPixelBufferRetain(s->_buffer);
    }
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
  if (!atomic_compare_exchange_strong_explicit(&_invalidated, &expected, YES,
                                               memory_order_acq_rel,
                                               memory_order_acquire)) {
    return; // already invalidated
  }
  // INTENTIONAL: Do NOT call CVPixelBufferRelease(_buffer) here.
  // _buffer is an IOSurface-backed CVPixelBuffer. CVPixelBufferRelease
  // triggers an IOSurface fence wait in the kernel. If the next session
  // (TC-04) is concurrently executing prepareWithCompletion: on a
  // USER_INITIATED queue — allocating a new IOSurface buffer from the pool
  // via CVPixelBufferPoolCreatePixelBuffer — the kernel serializes the
  // IOSurface operations, creating a permanent wait that freezes _prepareQueue.
  // Same root cause as the renderer's _latestPixelBuffer/pool release fix.
  // The OS reclaims the IOSurface memory at process exit.
  _rawBuffer = NULL; // matches _buffer intentional-leak policy
  _buffer = NULL;    // intentional leak — OS reclaims on process exit
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

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Raw buffer access
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a +1 retained copy of the original unfiltered image buffer.
/// Uses _rawBuffer — an independent retain that is never handed to the renderer
/// and cannot be freed when presentEnvelope: swaps _latestPixelBuffer.
/// The caller MUST CVPixelBufferRelease the returned buffer when done.
/// Returns NULL before start is called or after invalidation.
- (nullable CVPixelBufferRef)copyRawBuffer {
  if (!_rawBuffer) return NULL;
  return CVPixelBufferRetain(_rawBuffer);
}

@end
