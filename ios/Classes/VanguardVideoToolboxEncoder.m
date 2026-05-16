// VanguardVideoToolboxEncoder.m
// Phase 4: iOS Hardware H.264 Encoder implementation

#import "VanguardVideoToolboxEncoder.h"
#include <stdatomic.h> // atomic_fetch_add_explicit, atomic_store_explicit, memory_order_* — P5-C

// Forward-declare private methods so the C vtOutputCallback can call them.
// The actual implementations are below in @implementation.
@interface VanguardVideoToolboxEncoder (P5Private)
- (void)_incrementCallbackCount;
- (void)_handleEncodedSample:(CMSampleBufferRef)sampleBuffer;
@end

// ─────────────────────────────────────────────────────────────────────────────
// VTCompressionOutputCallback (C function — required by VideoToolbox API)
// ─────────────────────────────────────────────────────────────────────────────

static void vtOutputCallback(void *outputCallbackRefCon,
                             void *sourceFrameRefCon, OSStatus status,
                             VTEncodeInfoFlags infoFlags,
                             CMSampleBufferRef sampleBuffer) {
  if (status != noErr || !sampleBuffer)
    return;

  __unsafe_unretained VanguardVideoToolboxEncoder *enc =
      (__bridge VanguardVideoToolboxEncoder *)outputCallbackRefCon;
  // P5-C: increment via ObjC method (C functions cannot access @implementation
  // ivars).
  [enc _incrementCallbackCount];
  [enc _handleEncodedSample:sampleBuffer];
}

@implementation VanguardVideoToolboxEncoder {
  VTCompressionSessionRef _session;
  VanguardEncodedPacketHandler _packetHandler;
  int _width, _height, _bitrate, _fps;
  BOOL _isReady;
  // P3-T3: prewarm state
  BOOL _prewarming;
  int _prewarmFrameCount;
  // P5-C: monotonic counter of frames that completed
  // VTCompressionOutputCallback. Ground truth for encoder flush completeness
  // test.
  _Atomic(int64_t) _vtCallbackCount;
}

@synthesize isReady = _isReady;

/// P5-C: Manual getter so _Atomic(int64_t) ivar satisfies int64_t property
/// type.
- (int64_t)vtCallbackCount {
  return atomic_load_explicit(&_vtCallbackCount, memory_order_relaxed);
}

/// P5-C: Called from the C vtOutputCallback — ObjC method has ivar access.
- (void)_incrementCallbackCount {
  atomic_fetch_add_explicit(&_vtCallbackCount, 1, memory_order_relaxed);
}

#pragma mark - Init

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      bitrate:(int)bitrate
                          fps:(int)fps
                packetHandler:(VanguardEncodedPacketHandler)handler {
  self = [super init];
  if (!self)
    return nil;

  _width = width;
  _height = height;
  _bitrate = bitrate;
  _fps = fps;
  _packetHandler = [handler copy];
  // NOTE: do NOT call _createSession here when used with prewarm.
  // initWithWidth:... creates the session eagerly for backward compatibility.
  // For camera use, call prewarm instead.
  OSStatus err = [self _createSession];
  _isReady = (err == noErr);
  return self;
}

- (OSStatus)_createSession {
  // Pixel format must match AVAssetReader output and Metal render target:
  // kCVPixelFormatType_32BGRA is what Metal renders into our output texture.
  OSStatus err = VTCompressionSessionCreate(
      kCFAllocatorDefault, _width, _height, kCMVideoCodecType_H264,
      nil, // encoderSpecification — let VT choose HW encoder
      nil, // sourceImageBufferAttributes
      nil, // compressedDataAllocator
      vtOutputCallback, (__bridge void *)self, &_session);
  if (err != noErr) {
    NSLog(@"[Vanguard] VTCompressionSessionCreate failed: %d", (int)err);
    return err;
  }

  // ── Encoding properties ────────────────────────────────────────────────
  // Profile: Constrained Baseline Level 4.0 for widest device compatibility
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                       kVTProfileLevel_H264_Baseline_4_0);

  // Target average bitrate (bits/second)
  int32_t br = _bitrate;
  CFNumberRef bitrateRef = CFNumberCreate(nil, kCFNumberSInt32Type, &br);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate,
                       bitrateRef);
  CFRelease(bitrateRef);

  // Bitrate data rate limit: 150% of target over 1-second window.
  // DataRateLimits requires a CFArray of two CFNumbers: [maxBytes,
  // intervalSecs]. Passing raw int64_t pointers to CFArrayCreate crashes
  // because VideoToolbox calls CFGetTypeID on each element to verify they are
  // CFNumbers.
  int64_t byteVal = (int64_t)(_bitrate * 1.5);
  int32_t secVal = 1;
  CFNumberRef byteLimit =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &byteVal);
  CFNumberRef secLimit =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &secVal);
  const void *limitValues[2] = {byteLimit, secLimit};
  CFArrayRef dataRateLimits = CFArrayCreate(kCFAllocatorDefault, limitValues, 2,
                                            &kCFTypeArrayCallBacks);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits,
                       dataRateLimits);
  CFRelease(byteLimit);
  CFRelease(secLimit);
  CFRelease(dataRateLimits);

  // Key-frame interval: 1 key-frame per second
  int32_t gop = _fps;
  CFNumberRef gopRef = CFNumberCreate(nil, kCFNumberSInt32Type, &gop);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                       gopRef);
  CFRelease(gopRef);

  // Frame rate hint (not enforced, but helps the rate controller)
  int32_t fps = _fps;
  CFNumberRef fpsRef = CFNumberCreate(nil, kCFNumberSInt32Type, &fps);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate,
                       fpsRef);
  CFRelease(fpsRef);

  // Real-time encoding — minimise latency for live preview
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime,
                       kCFBooleanTrue);

  // Allow frame reordering (B-frames) for better compression
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering,
                       kCFBooleanFalse);

  VTCompressionSessionPrepareToEncodeFrames(_session);
  return noErr;
}

#pragma mark - Prewarm

/// Creates the VTCompressionSession without submitting any frames.
/// Called at startCamera — ensures the hardware encoder is warm before the user
/// taps Record. Idempotent: calling prewarm a second time is a no-op.
- (void)prewarm {
  if (_session)
    return; // already warm
  OSStatus err = [self _createSession];
  if (err == noErr) {
    _prewarming = YES;
    _prewarmFrameCount = 0;
    _isReady = YES;
    NSLog(@"[VanguardEncoder] prewarm ✓ — VTCompressionSession ready");
  } else {
    NSLog(@"[VanguardEncoder] prewarm failed: %d", (int)err);
  }
}

/// G-04: Update target bitrate at runtime for thermal degradation.
/// If the session is active, applies immediately via VTSessionSetProperty.
/// If not yet created, stores the value so _createSession picks it up.
- (void)setBitrateKbps:(int)kbps {
  int bps = kbps * 1000;
  _bitrate = bps;
  if (!_session)
    return; // will take effect when session is created
  // Update average bitrate
  int32_t br = bps;
  CFNumberRef bitrateRef = CFNumberCreate(nil, kCFNumberSInt32Type, &br);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate,
                       bitrateRef);
  CFRelease(bitrateRef);
  // Update data rate limit: 150% of new target (same CFNumber pattern as
  // _createSession).
  int64_t byteVal2 = (int64_t)(bps * 1.5);
  int32_t secVal2 = 1;
  CFNumberRef byteLimit2 =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &byteVal2);
  CFNumberRef secLimit2 =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &secVal2);
  const void *limitValues2[2] = {byteLimit2, secLimit2};
  CFArrayRef limits = CFArrayCreate(kCFAllocatorDefault, limitValues2, 2,
                                    &kCFTypeArrayCallBacks);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits,
                       limits);
  CFRelease(byteLimit2);
  CFRelease(secLimit2);
  CFRelease(limits);
  NSLog(@"[VanguardEncoder] Bitrate updated → %dkbps", kbps);
}

#pragma mark - Encoding

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
         presentationTime:(CMTime)pts {
  if (!_isReady || !_session)
    return;

  // Discard first 5 frames during prewarm: encoder state machine initialises
  // over the first few frames; these produce anomalous I-frame sizes and
  // timings.
  if (_prewarming) {
    if (++_prewarmFrameCount >= 5)
      _prewarming = NO;
    return; // discard — not written to any muxer
  }
  VTEncodeInfoFlags infoFlags;
  OSStatus err = VTCompressionSessionEncodeFrame(
      _session, pixelBuffer, pts,
      kCMTimeInvalid, // duration — let VT derive from PTS stream
      nil,            // frameProperties
      nil,            // sourceFrameRefCon
      &infoFlags);
  if (err != noErr) {
    NSLog(@"[Vanguard] VTCompressionSessionEncodeFrame error: %d", (int)err);
  }
}

#pragma mark - Encoded Output Handler

- (void)_handleEncodedSample:(CMSampleBufferRef)sampleBuffer {
  if (!CMSampleBufferDataIsReady(sampleBuffer))
    return;

  // Check for key-frame
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  BOOL isKeyFrame = NO;
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
    isKeyFrame = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
  }

  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

  // Extract the raw NAL unit data and prepend Annex-B start code [0x00 0x00
  // 0x00 0x01] so MP4 muxers and HLS streams can parse the bitstream correctly.
  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t totalLength = 0;
  char *dataPointer = NULL;
  CMBlockBufferGetDataPointer(blockBuffer, 0, nil, &totalLength, &dataPointer);

  // Convert AVCC length-prefixed NALUs → Annex-B
  NSMutableData *annexBData = [NSMutableData data];
  size_t offset = 0;
  while (offset < totalLength) {
    uint32_t naluLength = 0;
    memcpy(&naluLength, dataPointer + offset, 4);
    naluLength = CFSwapInt32BigToHost(naluLength);
    offset += 4;

    static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
    [annexBData appendBytes:startCode length:4];
    [annexBData appendBytes:dataPointer + offset length:naluLength];
    offset += naluLength;
  }

  if (_packetHandler) {
    _packetHandler(annexBData, pts, isKeyFrame, nil);
  }
}

#pragma mark - Finalise & Cleanup

- (void)finish {
  if (_session) {
    VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
  }
}

- (void)invalidate {
  if (_session) {
    VTCompressionSessionInvalidate(_session);
    CFRelease(_session);
    _session = NULL;
  }
  _isReady = NO;
}

// P5-C: Reset the per-session frame counter before starting a flush test.
- (void)resetCallbackCount {
  atomic_store_explicit(&_vtCallbackCount, 0, memory_order_release);
}

@end
