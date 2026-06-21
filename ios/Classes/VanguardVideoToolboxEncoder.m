// VanguardVideoToolboxEncoder.m
// Phase 5B: iOS Hardware Encoder — Dual-Mode Hardening
//
// Implements 12 VT properties per 01_encoder_export_foundation.md §A.1,
// usage-conditional session setup, idempotent invalidation via atomic CAS,
// and handler bridge for Phase 5C sink integration.

#import "VanguardVideoToolboxEncoder.h"
#include <stdatomic.h>

// Forward-declare private methods so the C vtOutputCallback can call them.
@interface VanguardVideoToolboxEncoder (P5Private)
- (void)_incrementCallbackCount;
- (void)_incrementCallbackBodiesReturned;
- (void)_handleEncodedSample:(CMSampleBufferRef)sampleBuffer;
@end

// ─────────────────────────────────────────────────────────────────────────────
// VTCompressionOutputCallback (C function — required by VideoToolbox API)
// ─────────────────────────────────────────────────────────────────────────────
//
// Phase 5B rewrite: frameCompletionHandler fires UNCONDITIONALLY first (for
// every callback: success, drop, or error). encodedSampleHandler fires only
// on success. callbackBodiesReturned incremented LAST. No early return before
// frameCompletionHandler invocation.

static void vtOutputCallback(void *outputCallbackRefCon,
                             void *sourceFrameRefCon, OSStatus status,
                             VTEncodeInfoFlags infoFlags,
                             CMSampleBufferRef sampleBuffer) {
    __unsafe_unretained VanguardVideoToolboxEncoder *enc =
        (__bridge VanguardVideoToolboxEncoder *)outputCallbackRefCon;

    // P5-C: monotonic callback counter (diagnostic).
    [enc _incrementCallbackCount];

    // 1. frameCompletionHandler — UNCONDITIONAL, FIRST.
    //    Local strong copy ensures safety if handler is nil'd concurrently.
    //    This must fire for drops and errors too — 5C sink signals semaphore here.
    void (^completion)(OSStatus, VTEncodeInfoFlags) = enc.frameCompletionHandler;
    if (completion) {
        completion(status, infoFlags);
    }

    // 2. On success: camera NAL path + export sample handler.
    if (status == noErr && sampleBuffer) {
        // Camera/realtime NAL extraction path (unchanged from Phase 4).
        [enc _handleEncodedSample:sampleBuffer];

        // 3. encodedSampleHandler — success only.
        //    Local strong copy for thread safety.
        //    Caller (5C sink) is responsible for CFRetain before dispatch_async.
        void (^sampleHandler)(CMSampleBufferRef) = enc.encodedSampleHandler;
        if (sampleHandler) {
            sampleHandler(sampleBuffer);
        }
    }

    // 4. callbackBodiesReturned — LAST LINE, after all handlers returned.
    //    Enables 5C sink callback body drain verification.
    [enc _incrementCallbackBodiesReturned];
}

// ─────────────────────────────────────────────────────────────────────────────
// @implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardVideoToolboxEncoder {
    VTCompressionSessionRef _session;
    VanguardEncodedPacketHandler _packetHandler;
    int _width, _height, _bitrate, _fps;
    // Phase 5B: codec/profile/usage parameters.
    CMVideoCodecType _codecType;
    NSString *_profileLevel;        // ARC-managed; bridged to CFStringRef at VT call site.
    VGEncoderUsage _usage;
    // Readiness and prewarm state.
    BOOL _isReady;
    BOOL _prewarming;
    int _prewarmFrameCount;
    // P5-C: monotonic VT callback counter (diagnostic).
    _Atomic(int64_t) _vtCallbackCount;
    // Phase 5B: atomic invalidation gate (CAS: 0 → 1).
    _Atomic(int32_t) _sessionInvalidated;
    // Phase 5B: callback body return counter for drain verification.
    _Atomic(int64_t) _callbackBodiesReturned;
}

@synthesize isReady = _isReady;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Atomic getters (manual for _Atomic ivars)
// ─────────────────────────────────────────────────────────────────────────────

- (int64_t)vtCallbackCount {
    return atomic_load_explicit(&_vtCallbackCount, memory_order_relaxed);
}

- (int64_t)callbackBodiesReturned {
    return atomic_load_explicit(&_callbackBodiesReturned, memory_order_relaxed);
}

- (void)_incrementCallbackCount {
    atomic_fetch_add_explicit(&_vtCallbackCount, 1, memory_order_relaxed);
}

- (void)_incrementCallbackBodiesReturned {
    atomic_fetch_add_explicit(&_callbackBodiesReturned, 1, memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Init
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      bitrate:(int)bitrate
                          fps:(int)fps
                    codecType:(CMVideoCodecType)codecType
                 profileLevel:(NSString *)profileLevel
                        usage:(VGEncoderUsage)usage
                packetHandler:(nullable VanguardEncodedPacketHandler)handler {
    NSParameterAssert(width > 0);
    NSParameterAssert(height > 0);
    NSParameterAssert(bitrate > 0);
    NSParameterAssert(fps > 0);
    NSParameterAssert(profileLevel != nil);

    self = [super init];
    if (!self) return nil;

    _width   = width;
    _height  = height;
    _bitrate = bitrate;
    _fps     = fps;
    _codecType     = codecType;
    _profileLevel  = [profileLevel copy];
    _usage         = usage;
    _packetHandler = [handler copy];

    _isReady         = NO;
    _prewarming      = NO;
    _prewarmFrameCount = 0;

    atomic_store_explicit(&_vtCallbackCount,        0, memory_order_relaxed);
    atomic_store_explicit(&_sessionInvalidated,     0, memory_order_relaxed);
    atomic_store_explicit(&_callbackBodiesReturned, 0, memory_order_relaxed);

    OSStatus err = [self _createSession];
    _isReady = (err == noErr);
    return self;
}

/// Phase 4 backward-compatible convenience initializer.
/// Calls the 8-arg designated init with H.264 / Baseline 4.0 / Realtime defaults.
/// All existing Swift call sites remain unmodified.
- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      bitrate:(int)bitrate
                          fps:(int)fps
                packetHandler:(VanguardEncodedPacketHandler)handler {
    return [self initWithWidth:width
                        height:height
                       bitrate:bitrate
                           fps:fps
                     codecType:kCMVideoCodecType_H264
                  profileLevel:(__bridge NSString *)kVTProfileLevel_H264_Baseline_4_0
                         usage:VGEncoderUsageRealtime
                 packetHandler:handler];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Session creation
// ─────────────────────────────────────────────────────────────────────────────

- (OSStatus)_createSession {
    // Pixel format: kCVPixelFormatType_32BGRA matches Metal render target.
    OSStatus err = VTCompressionSessionCreate(
        kCFAllocatorDefault, _width, _height,
        _codecType,           // Phase 5B: parameterized (not hardcoded H264)
        nil,                  // encoderSpecification — let VT choose HW encoder
        nil,                  // sourceImageBufferAttributes
        nil,                  // compressedDataAllocator
        vtOutputCallback,
        (__bridge void *)self,
        &_session);

    if (err != noErr) {
        NSLog(@"[VanguardEncoder] VTCompressionSessionCreate failed: %d", (int)err);
        return err;
    }

    // ── §A.1 Property #2: ProfileLevel ──────────────────────────────────────
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         (__bridge CFStringRef)_profileLevel);

    // ── §A.1 Property #3: AverageBitRate (bits/sec) ─────────────────────────
    int32_t br = _bitrate;
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &br);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    // ── §A.1 Property #4: ExpectedFrameRate ─────────────────────────────────
    int32_t fpsVal = _fps;
    CFNumberRef fpsRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fpsVal);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    // ── §A.1 Property #5: MaxKeyFrameInterval ───────────────────────────────
    int32_t gop = _fps;  // 1 key-frame per second
    CFNumberRef gopRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &gop);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, gopRef);
    CFRelease(gopRef);

    // ── §A.1 Properties #6–#12: Usage-conditional ───────────────────────────
    if (_usage == VGEncoderUsageOffline) {
        // #6: MaxKeyFrameIntervalDuration (offline only) = 2.0 seconds
        Float32 kfDurVal = 2.0f;
        CFNumberRef kfDurRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &kfDurVal);
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, kfDurRef);
        CFRelease(kfDurRef);

        // #8: Quality (offline only) = 1.0
        Float32 qualityVal = 1.0f;
        CFNumberRef qualityRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &qualityVal);
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_Quality, qualityRef);
        CFRelease(qualityRef);

        // #9: AllowFrameReordering = YES (B-frames for offline)
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue);

        // #10: RealTime = NO (offline: maximize quality)
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);

        // #12: AllowOpenGOP = YES (iOS 12+; podspec min is 14.0 so no @available guard needed)
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanTrue);

        // #11: PrioritizeEncodingSpeedOverQuality = NO (iOS 14.0+)
        if (@available(iOS 14.0, *)) {
            VTSessionSetProperty(_session,
                                 kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                                 kCFBooleanFalse);
        }
    } else {
        // Realtime defaults (same behavioral outcome as Phase 4):
        // #9: AllowFrameReordering = NO (no B-frames — camera latency)
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

        // #10: RealTime = YES (minimize latency for live preview)
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);

        // #6, #8, #11, #12 NOT SET — VT defaults are correct for realtime.
        // "Not set" is intentional per §A.1.
    }

    // ── §A.1 Property #7: DataRateLimits ───────────────────────────────────
    // §A.1: [(_bitrate * multiplier) / 8, 1] — bytes/sec (not bits/sec).
    // Phase 5B fix: previous code used _bitrate * 1.5 without /8 (passed bits as bytes).
    // Multiplier: 1.5× realtime, 2.5× offline.
    double multiplier = (_usage == VGEncoderUsageOffline) ? 2.5 : 1.5;
    int64_t byteVal = (int64_t)((_bitrate * multiplier) / 8.0);
    int32_t secVal  = 1;
    CFNumberRef byteLimit = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &byteVal);
    CFNumberRef secLimit  = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &secVal);
    const void *limitValues[2] = {byteLimit, secLimit};
    CFArrayRef dataRateLimits = CFArrayCreate(kCFAllocatorDefault, limitValues, 2,
                                              &kCFTypeArrayCallBacks);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits, dataRateLimits);
    CFRelease(byteLimit);
    CFRelease(secLimit);
    CFRelease(dataRateLimits);

    // ── Phase 10-C C1E: Rec.709 / sRGB colour properties ────────────────────
    // Set BT.709 colour metadata on the VTCompressionSession so that the encoded
    // H.264 bitstream carries a valid colr atom (colour_primaries=1,
    // transfer_characteristics=1, matrix_coefficients=1).  Without these, players
    // default to BT.601 or make no assumption, producing washed / incorrect colour
    // when viewing SDR Rec.709 output.
    //
    // These constants are CFStringRef and require no CFRelease — they are static
    // system-owned strings obtained from VideoToolbox / CoreMedia headers.
    //
    // Applied unconditionally: both realtime (camera) and offline (export) paths
    // produce BT.709 content.  The compositor fix (C1E VGTimelineCompositorNode.m)
    // ensures export frames are rendered into sRGB/BT.709 BGRA buffers before
    // reaching this encoder.
    VTSessionSetProperty(_session,
                         kVTCompressionPropertyKey_ColorPrimaries,
                         kCMFormatDescriptionColorPrimaries_ITU_R_709_2);

    VTSessionSetProperty(_session,
                         kVTCompressionPropertyKey_TransferFunction,
                         kCMFormatDescriptionTransferFunction_ITU_R_709_2);

    VTSessionSetProperty(_session,
                         kVTCompressionPropertyKey_YCbCrMatrix,
                         kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);

    OSStatus prepErr = VTCompressionSessionPrepareToEncodeFrames(_session);
    if (prepErr != noErr) {
        NSLog(@"[VanguardEncoder] VTCompressionSessionPrepareToEncodeFrames failed: %d (dims=%dx%d)",
              (int)prepErr, _width, _height);
        return prepErr;
    }
    return noErr;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Prewarm (unchanged from Phase 4)
// ─────────────────────────────────────────────────────────────────────────────

/// Creates the VTCompressionSession without submitting any frames.
/// Called at startCamera — ensures the hardware encoder is warm before the user
/// taps Record. Idempotent: calling prewarm a second time is a no-op.
- (void)prewarm {
    if (_session) return;  // already warm
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Encoding
// ─────────────────────────────────────────────────────────────────────────────

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
         presentationTime:(CMTime)pts {
    if (!_isReady || !_session) return;

    // Phase 5B: reject if invalidated (sink-path safety gate).
    if (atomic_load_explicit(&_sessionInvalidated, memory_order_relaxed) == 1) return;

    // Discard first 5 frames during prewarm: encoder initialises over first few
    // frames; these produce anomalous I-frame sizes and timings.
    if (_prewarming) {
        if (++_prewarmFrameCount >= 5) _prewarming = NO;
        return;  // discard — not written to any muxer
    }

    VTEncodeInfoFlags infoFlags;
    OSStatus err = VTCompressionSessionEncodeFrame(
        _session, pixelBuffer, pts,
        CMTimeMake(1, _fps),  // §A.3: explicit frame duration (was kCMTimeInvalid)
        nil,                  // frameProperties
        nil,                  // sourceFrameRefCon
        &infoFlags);
    if (err != noErr) {
        NSLog(@"[VanguardEncoder] VTCompressionSessionEncodeFrame error: %d", (int)err);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Camera / NAL Output Handler (unchanged from Phase 4)
// ─────────────────────────────────────────────────────────────────────────────

- (void)_handleEncodedSample:(CMSampleBufferRef)sampleBuffer {
    if (!CMSampleBufferDataIsReady(sampleBuffer)) return;

    // Check for key-frame.
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    BOOL isKeyFrame = NO;
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        isKeyFrame = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    // Extract raw NAL data and prepend Annex-B start code so muxers can parse.
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t totalLength = 0;
    char *dataPointer  = NULL;
    CMBlockBufferGetDataPointer(blockBuffer, 0, nil, &totalLength, &dataPointer);

    // Convert AVCC length-prefixed NALUs → Annex-B.
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

    // Invoke camera/realtime packet handler (nil-safe; camera path only).
    if (_packetHandler) {
        _packetHandler(annexBData, pts, isKeyFrame, nil);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Flush and Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)finish {
    // Phase 5B: discard return value for backward compat.
    [self completeFrames];
}

- (void)invalidate {
    // Phase 5B: backward-compatible wrapper — now delegates to idempotent invalidateOnce.
    // CFRelease moved to dealloc to prevent double-release on repeated invalidate calls.
    [self invalidateOnce];
}

- (void)invalidateOnce {
    // Atomic CAS 0 → 1. If already invalidated, this is a no-op.
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &_sessionInvalidated, &expected, 1,
            memory_order_acq_rel, memory_order_relaxed)) {
        return;
    }
    // VTCompressionSessionInvalidate is thread-safe per Apple documentation.
    if (_session) {
        VTCompressionSessionInvalidate(_session);
    }
    // §A.5: No CFRelease here. No _session = NULL here.
    // CFRelease is dealloc's responsibility only.
    _isReady = NO;
}

- (BOOL)completeFrames {
    if (!_session) return NO;

    // §A.5: pre-call check — already invalidated.
    if (atomic_load_explicit(&_sessionInvalidated, memory_order_acquire) == 1) return NO;

    // §A.5: capture OSStatus — return NO if VT reports an error.
    OSStatus status = VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
    if (status != noErr) {
        NSLog(@"[VanguardEncoder] VTCompressionSessionCompleteFrames error: %d", (int)status);
        return NO;
    }

    // §A.5: post-call check — session may have been invalidated while blocking.
    if (atomic_load_explicit(&_sessionInvalidated, memory_order_acquire) == 1) return NO;

    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - dealloc
// ─────────────────────────────────────────────────────────────────────────────

- (void)dealloc {
    // §A.5: _session guard covers the case where _createSession failed and _session is NULL.
    // VTCompressionSessionInvalidate(NULL) is unsafe — must not be called.
    if (_session) {
        if (atomic_load_explicit(&_sessionInvalidated, memory_order_relaxed) == 0) {
            VTCompressionSessionInvalidate(_session);
        }
        CFRelease(_session);
        _session = NULL;
    }
    // _profileLevel is NSString * — released by ARC.
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - G-04: Runtime Bitrate (Phase 5B: usage-conditional)
// ─────────────────────────────────────────────────────────────────────────────

- (void)setBitrateKbps:(int)kbps {
    int bps = kbps * 1000;
    _bitrate = bps;
    if (!_session) return;  // will take effect when session is created

    // AverageBitRate.
    int32_t br = bps;
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &br);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    // DataRateLimits: usage-conditional multiplier, bytes not bits.
    double multiplier = (_usage == VGEncoderUsageOffline) ? 2.5 : 1.5;
    int64_t byteVal = (int64_t)((bps * multiplier) / 8.0);
    int32_t secVal  = 1;
    CFNumberRef byteLimit = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &byteVal);
    CFNumberRef secLimit  = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &secVal);
    const void *limitValues[2] = {byteLimit, secLimit};
    CFArrayRef limits = CFArrayCreate(kCFAllocatorDefault, limitValues, 2, &kCFTypeArrayCallBacks);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits, limits);
    CFRelease(byteLimit);
    CFRelease(secLimit);
    CFRelease(limits);

    NSLog(@"[VanguardEncoder] Bitrate updated → %dkbps", kbps);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - P5-C: Callback counter reset
// ─────────────────────────────────────────────────────────────────────────────

- (void)resetCallbackCount {
    atomic_store_explicit(&_vtCallbackCount, 0, memory_order_release);
}

@end
