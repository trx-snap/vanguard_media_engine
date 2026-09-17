// VGLiveGreenScreenMaskProviderAdapter.m
// Generic live green-screen: Vision-Fast-backed (iOS production default),
// selectable LiteRT-backed, or diagnostic Vision-balanced/accurate or
// small-selfie-model LiteRT-backed person-matte source. See header.
//
// This translation unit also carries the VGLiveGreenScreenVisionMaskProvider
// implementation (declared in VGLiveGreenScreenVisionMaskProvider.h); see the
// note at the head of that section below.

#import "VGLiveGreenScreenMaskProviderAdapter.h"
#import "VGLiteRTMaskProvider.h"
#import "VGLiveGreenScreenVisionMaskProvider.h"
#import "VGHeuristicMaskProvider.h"
#import "VGMLModelBundle.h"
#import "VGMaskProvider.h"
#import "VGSkinMaskGenerator.h"   // VGSkinMask definition
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime
#import <Vision/Vision.h>         // VGLiveGreenScreenVisionMaskProvider (implemented below)
#import <os/lock.h>
#import <math.h>
#include <stdatomic.h>            // VGLiveGreenScreenVisionMaskProvider _invalidated

// ─── VGSkinMask private creation category ────────────────────────────────────
// Same pattern as VGFaceNeckBeautyMaskPolicy.m and VGLiteRTMaskProvider.m:
// VGSkinMask's designated initializer is file-private to VGSkinMaskGenerator.m.
// The selector MUST match that implementation exactly.

@interface VGSkinMask (VGLiveGreenScreenMatteCreation)
- (instancetype)_initWithData:(NSData *)data
                        width:(size_t)width
                       height:(size_t)height
                    sourcePTS:(CMTime)pts
                    faceCount:(NSInteger)faceCount;
@end

// ─── Model tensor constants (selfie_multiclass_256x256.tflite) ───────────────

static const size_t kMatteModelW      = 256;
static const size_t kMatteModelH      = 256;
static const size_t kMatteModelC      = 6;
static const size_t kMatteModelPixels = kMatteModelW * kMatteModelH;   // 65 536
static const int    kMatteClassBackground = 0;

/// Fraction of model pixels that flipped side between frames at which the
/// temporal EMA stops smoothing entirely (alpha → 1.0).
static const float  kMatteMotionReference = 0.02f;

/// Output short side. Long side follows the source aspect ratio.
static const size_t kMatteOutputShortSide = 256;
/// Hard cap on either output dimension (guards absurd source dimensions).
static const size_t kMatteOutputMaxSide   = 1024;

static inline float VGMatteClamp01(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

/// Percentage of non-zero (subject) bytes in a valid matte, 0…100.
static double VGLiveGSMatteCoveragePercent(VGSkinMask *mask) {
    size_t w = mask.width, h = mask.height;
    size_t bpr = mask.bytesPerRow > 0 ? mask.bytesPerRow : w;
    const uint8_t *bytes = mask.data;
    if (!bytes || w == 0 || h == 0) return 0.0;
    size_t nonZero = 0;
    for (size_t y = 0; y < h; y++) {
        const uint8_t *row = bytes + y * bpr;
        for (size_t x = 0; x < w; x++) { nonZero += (row[x] != 0); }
    }
    return (double)nonZero * 100.0 / (double)(w * h);
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - VGLiveGreenScreenPersonMattePolicy
// ═════════════════════════════════════════════════════════════════════════════

@implementation VGLiveGreenScreenPersonMattePolicy {
    float *_matteCurrent;   // kMatteModelPixels — this frame's subject probability
    float *_matteHistory;   // kMatteModelPixels — EMA state
    BOOL   _matteHasHistory;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _edgeLow           = 0.35f;
    _edgeHigh          = 0.65f;
    _baseTemporalAlpha = 0.5f;
    _matteCurrent      = (float *)malloc(kMatteModelPixels * sizeof(float));
    _matteHistory      = (float *)calloc(kMatteModelPixels, sizeof(float));
    _matteHasHistory   = NO;
    return self;
}

- (void)dealloc {
    free(_matteCurrent);
    free(_matteHistory);
}

- (void)resetTemporalState {
    [super resetTemporalState];
    if (_matteHistory) {
        memset(_matteHistory, 0, kMatteModelPixels * sizeof(float));
    }
    _matteHasHistory = NO;
}

/// 1×1 zero matte flagged invalid (faceCount 0). The adapter maps it to NULL
/// so the compositor shows the unkeyed camera rather than an all-background
/// frame produced by a processing failure.
- (VGSkinMask *)_invalidMatteForPTS:(CMTime)pts {
    const uint8_t zeroByte = 0;
    NSData *zero = [NSData dataWithBytes:&zeroByte length:1];
    return [[VGSkinMask alloc] _initWithData:zero width:1 height:1 sourcePTS:pts faceCount:0];
}

- (VGSkinMask *)processTensor:(const float *)outputTensor
                  sourceWidth:(size_t)sourceWidth
                 sourceHeight:(size_t)sourceHeight
                          pts:(CMTime)pts
              generationReset:(BOOL)generationReset {

    if (generationReset) {
        [self resetTemporalState];
    }
    if (!outputTensor || !_matteCurrent || !_matteHistory) {
        return [self _invalidMatteForPTS:pts];
    }

    // ── 1. Subject probability = 1 − P(background), plus motion estimate ─────
    size_t flipped = 0;
    for (size_t i = 0; i < kMatteModelPixels; i++) {
        float fg = VGMatteClamp01(1.0f - outputTensor[i * kMatteModelC + kMatteClassBackground]);
        _matteCurrent[i] = fg;
        if (_matteHasHistory && fabsf(fg - _matteHistory[i]) > 0.5f) {
            flipped++;
        }
    }

    // ── 2. Motion-adaptive temporal EMA at model resolution ──────────────────
    if (_matteHasHistory) {
        float motion = (float)flipped / (float)kMatteModelPixels;
        float t      = VGMatteClamp01(motion / kMatteMotionReference);
        float alpha  = VGMatteClamp01(_baseTemporalAlpha + (1.0f - _baseTemporalAlpha) * t);
        float keep   = 1.0f - alpha;
        for (size_t i = 0; i < kMatteModelPixels; i++) {
            _matteHistory[i] = alpha * _matteCurrent[i] + keep * _matteHistory[i];
        }
    } else {
        memcpy(_matteHistory, _matteCurrent, kMatteModelPixels * sizeof(float));
        _matteHasHistory = YES;
    }

    // ── 3. Output dimensions: source aspect ratio, short side = 256 ──────────
    size_t outW = kMatteModelW, outH = kMatteModelH;
    if (sourceWidth > 0 && sourceHeight > 0) {
        double shortSide = (double)(sourceWidth < sourceHeight ? sourceWidth : sourceHeight);
        double scale     = (double)kMatteOutputShortSide / shortSide;
        outW = (size_t)lround((double)sourceWidth  * scale);
        outH = (size_t)lround((double)sourceHeight * scale);
        if (outW < 1) outW = 1;
        if (outH < 1) outH = 1;
        if (outW > kMatteOutputMaxSide) outW = kMatteOutputMaxSide;
        if (outH > kMatteOutputMaxSide) outH = kMatteOutputMaxSide;
    }
    size_t outPixels = outW * outH;

    uint8_t *outBuf = (uint8_t *)malloc(outPixels);
    // Per-column bilinear lookup tables (x0, x1, tx) — computed once per call.
    size_t *colX0 = (size_t *)malloc(outW * sizeof(size_t));
    size_t *colX1 = (size_t *)malloc(outW * sizeof(size_t));
    float  *colTX = (float  *)malloc(outW * sizeof(float));
    if (!outBuf || !colX0 || !colX1 || !colTX) {
        free(outBuf); free(colX0); free(colX1); free(colTX);
        return [self _invalidMatteForPTS:pts];
    }

    const float sx = (float)kMatteModelW / (float)outW;
    const float sy = (float)kMatteModelH / (float)outH;
    for (size_t ox = 0; ox < outW; ox++) {
        float fx = ((float)ox + 0.5f) * sx - 0.5f;
        if (fx < 0.0f) fx = 0.0f;
        size_t x0 = (size_t)fx;
        if (x0 > kMatteModelW - 1) x0 = kMatteModelW - 1;
        size_t x1 = (x0 + 1 < kMatteModelW) ? x0 + 1 : x0;
        colX0[ox] = x0;
        colX1[ox] = x1;
        colTX[ox] = VGMatteClamp01(fx - (float)x0);
    }

    // ── 4. Bilinear resample + soft edge remap → 0…255 ───────────────────────
    const float lo    = _edgeLow;
    const float hi    = (_edgeHigh > _edgeLow + 1e-4f) ? _edgeHigh : _edgeLow + 1e-4f;
    const float invBW = 1.0f / (hi - lo);

    for (size_t oy = 0; oy < outH; oy++) {
        float fy = ((float)oy + 0.5f) * sy - 0.5f;
        if (fy < 0.0f) fy = 0.0f;
        size_t y0 = (size_t)fy;
        if (y0 > kMatteModelH - 1) y0 = kMatteModelH - 1;
        size_t y1 = (y0 + 1 < kMatteModelH) ? y0 + 1 : y0;
        float  ty = VGMatteClamp01(fy - (float)y0);

        const float *row0 = _matteHistory + y0 * kMatteModelW;
        const float *row1 = _matteHistory + y1 * kMatteModelW;
        uint8_t     *dst  = outBuf + oy * outW;

        for (size_t ox = 0; ox < outW; ox++) {
            size_t x0 = colX0[ox], x1 = colX1[ox];
            float  tx = colTX[ox];
            float  top    = row0[x0] + (row0[x1] - row0[x0]) * tx;
            float  bottom = row1[x0] + (row1[x1] - row1[x0]) * tx;
            float  p      = top + (bottom - top) * ty;

            // Soft edge band: linear ramp across [lo, hi], then smoothstep.
            float v = VGMatteClamp01((p - lo) * invBW);
            v = v * v * (3.0f - 2.0f * v);
            dst[ox] = (uint8_t)(v * 255.0f + 0.5f);
        }
    }
    free(colX0); free(colX1); free(colTX);

    // ── 5. Build VGSkinMask (faceCount 1 = valid person matte) ───────────────
    NSData *maskData = [NSData dataWithBytesNoCopy:outBuf length:outPixels freeWhenDone:YES];
    return [[VGSkinMask alloc] _initWithData:maskData
                                       width:outW
                                      height:outH
                                   sourcePTS:pts
                                   faceCount:1];
}

@end

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - VGLiveGreenScreenVisionMaskProvider (implementation)
// ═════════════════════════════════════════════════════════════════════════════
// Declared in VGLiveGreenScreenVisionMaskProvider.h. The implementation lives
// here, not in VGLiveGreenScreenVisionMaskProvider.m (a deliberate comment-only
// placeholder): the generated example Pods project enumerates dev-pod sources
// explicitly and predates that file, so this adapter .m is the compiled unit
// that must carry it until the Pods project is regenerated. Keeping the
// placeholder free of code means a later regeneration (podspec source_files =
// Classes/**/*.{swift,h,m,mm}) cannot produce duplicate symbols.
//
// The VGSkinMask private creation selector used below is the one declared in
// the VGLiveGreenScreenMatteCreation category at the top of this file.

// ─── Constants ────────────────────────────────────────────────────────────────

/// Throttled per-frame diagnostic log: first 3 frames, then every N (~1 s at 30 fps).
static const NSUInteger kVGVisionDiagLogInterval = 30;
/// Sanity cap on either Vision mask dimension (balanced ≈ 512-side, fast ≈ 256-side,
/// accurate up to source resolution). Unchanged for the accurate level.
static const size_t     kVGVisionMaskMaxSide     = 4096;

// ─── Vision matte tighten (RND, Vision provider copy path only) ──────────────
// Vision's OneComponent8 person matte carries a broad low-confidence skirt
// around head/shoulders. The compositor aspect-fills the published mask
// straight into CIBlendWithMask with no threshold/cleanup, so that skirt
// renders as a wide grey halo of retained camera background. Each byte is
// tightened while the raw Vision mask is resampled into the camera-aspect
// output matte in _copyMaskFromVisionBuffer:…sourceWidth:sourceHeight:…:
//   v <= kVGVisionMatteTightenLow   → 0    (background)
//   v >= kVGVisionMatteTightenHigh  → 255  (subject)
//   otherwise                        → smoothstep ramp between the cutoffs, so
//                                      real subject edges keep a soft band.
// This touches ONLY the Vision provider path; the LiteRT model policy above
// (VGLiveGreenScreenPersonMattePolicy) is unchanged.
//
// Soft-ramp A/B (Vision provider only): with the camera-aspect 384 matte the
// border still read as coarse, so the low cutoff is widened from 176 to 144
// while the high cutoff stays at 244. That stretches the smoothstep ramp over
// a wider confidence band (100 levels instead of 68) without touching the
// interior subject strength (>= 244 is still hard 255) and without adding a
// blur or changing the model/geometry. Per-byte cost is unchanged, so latency
// is expected to be flat. The CREATED log below prints both cutoffs.
// Both cutoffs (144/244) are deliberately frozen for the 512 publish-
// resolution A/B recorded below so that A/B changes exactly one variable.
static const uint8_t kVGVisionMatteTightenLow  = 144;
static const uint8_t kVGVisionMatteTightenHigh = 244;

static inline uint8_t VGVisionMatteTightenByte(uint8_t v) {
    if (v <= kVGVisionMatteTightenLow)  return 0;
    if (v >= kVGVisionMatteTightenHigh) return 255;
    float t = (float)(v - kVGVisionMatteTightenLow) /
              (float)(kVGVisionMatteTightenHigh - kVGVisionMatteTightenLow);
    t = t * t * (3.0f - 2.0f * t);          // smoothstep
    return (uint8_t)roundf(t * 255.0f);      // t ∈ (0,1) → 0…255, no overflow
}

// ─── Vision matte publish geometry (Vision provider copy path only) ─────────
// Vision's observation mask is a normalized matte over the WHOLE camera frame,
// but its pixel dimensions do not preserve the camera aspect: fast/balanced on
// a 1080×1920 (9:16) portrait frame yield e.g. 192×256 (3:4). The compositor
// (VGDuetPreviewCompositor) aspect-fills camera and mask into the same rect, so
// a mask of a different aspect is cropped differently from the camera and the
// matte lands offset/stretched against the subject — the large retained-
// background void seen identically on every Vision quality level. The published
// VGSkinMask is therefore resampled into the SAME camera-aspect output shape
// the LiteRT person-matte policy uses (VGLiveGreenScreenPersonMattePolicy step
// 3): short side = kVGVisionMatteOutputShortSide, long side from the camera
// aspect, each side capped at kMatteOutputMaxSide (a 1080×1920 9:16 frame
// publishes 512×910 at the current 512 short side; it published 384×683 at
// the previous 384 short side).
//
// Edge-resolution RND record (Vision provider only). The compositor enlarges
// the published matte to the full preview, so the published short side sets
// how coarse the subject border can look:
//   • 256 short side (256×455 on 9:16): read as a coarse, stair-stepped
//     subject border. Superseded.
//   • 384 short side (384×683 on 9:16, ≈2.25× the pixels of 256×455): together
//     with the stateless per-frame Vision request and the camera-aspect
//     publish geometry this solved the broad geometry / trailing-void class.
//     User ReplayKit evidence confirmed geometry, aspect and orientation are
//     correct and the broad void/trailing is gone, but the SAME evidence still
//     showed a stair-stepped / pixelated matte contour around hair and
//     shoulders, i.e. contour quantization from upscaling the matte rather
//     than a geometry defect.
//   • 512 short side (512×910 on 9:16, ≈1.78× the pixels of 384×683): the
//     CURRENT fast-fail A/B, aimed only at that pixelation / contour
//     quantization. It raises the published matte resolution and nothing
//     else: the stateless VNImageRequestHandler / per-frame
//     VNGeneratePersonSegmentationRequest mode, the 144/244 tighten cutoffs,
//     the camera-aspect publish geometry, the kMatteOutputMaxSide cap, camera
//     orientation, source/camera rect mapping, frame pairing and the
//     compositor feather (1.25 px, owned by VGDuetPreviewCompositor) are all
//     unchanged. The per-frame resample + tighten cost scales with the pixel
//     count, so latency is NOT assumed flat and must be re-measured.
// Production promotion of 512 (or any later value) requires ALL of the
// following on a physical device: acceptable measured latency (CREATED /
// PUBLISH_GEOMETRY plus the per-frame diagnostic log), no
// green_screen_degraded events, visual acceptance on a high-contrast image
// background, and no regression to the geometry / trailing-void class that
// 384 already fixed. Until that proof exists 512 is an RND value only.
// kMatteOutputShortSide (256) belongs to the LiteRT policy and is deliberately
// NOT changed; kMatteOutputMaxSide remains the shared cap. This pass changes
// only the published resolution; the threshold/feather is owned by the
// Vision-only soft-ramp A/B on the tighten cutoffs above.
// That keeps the adapter's header contract ("aspect ratio matches the camera
// frame") true for the Vision backend without touching the camera frame, its
// orientation, or the compositor. Non-uniform x/y scaling is intended: the
// observation is a normalized matte, not a texture with its own pixel aspect.
// No usable source size (0×0) publishes the raw Vision dimensions unchanged.

/// Vision-only publish short side (history: 256 → 384 → 512, see the
/// record above). Long side follows the camera aspect and both sides stay
/// capped at kMatteOutputMaxSide. Kept separate from kMatteOutputShortSide
/// (LiteRT policy, 256) on purpose. The CREATED and PUBLISH_GEOMETRY logs
/// print this value as publishShortSide so physical evidence can distinguish
/// a 384 run from a 512 run.
static const size_t kVGVisionMatteOutputShortSide = 512;

static void VGVisionMattePublishSizeForSource(size_t sourceW, size_t sourceH,
                                              size_t rawW, size_t rawH,
                                              size_t *outW, size_t *outH) {
    size_t w = rawW, h = rawH;
    if (sourceW > 0 && sourceH > 0) {
        double shortSide = (double)(sourceW < sourceH ? sourceW : sourceH);
        double scale     = (double)kVGVisionMatteOutputShortSide / shortSide;
        w = (size_t)lround((double)sourceW * scale);
        h = (size_t)lround((double)sourceH * scale);
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        if (w > kMatteOutputMaxSide) w = kMatteOutputMaxSide;
        if (h > kMatteOutputMaxSide) h = kMatteOutputMaxSide;
    }
    *outW = w;
    *outH = h;
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - VGLiveGreenScreenVisionMaskProvider
// ═════════════════════════════════════════════════════════════════════════════

@implementation VGLiveGreenScreenVisionMaskProvider {
    dispatch_queue_t _visionQueue;   // serial; every Vision call and every publish runs here
    atomic_bool      _invalidated;   // terminal; read on the capture queue and the Vision queue

    // Vision invocation state: NONE (invocationMode=statelessImageRequest).
    // Stateless A/B: every processed frame builds its own
    // VNGeneratePersonSegmentationRequest and its own VNImageRequestHandler
    // bound to that frame's camera pixel buffer. Both are locals of
    // _processPixelBuffer:pts:generation: and are released when it returns.
    // No request object and no VNSequenceRequestHandler is kept on the
    // provider, so Vision cannot carry temporal state from one frame into the
    // next (the reused sequence-handler path is what this A/B tests as the
    // source of the movement voids).

    // ── In-flight flag + single pending slot (all under _slotLock) ───────────
    os_unfair_lock   _slotLock;
    BOOL             _inFlight;             // YES while a frame is being processed / drained
    CVPixelBufferRef _pendingPixelBuffer;   // +1 retained; NULL when the slot is empty
    CMTime           _pendingPTS;
    uint64_t         _pendingGeneration;
    NSUInteger       _diagPendingStored;    // arrivals parked in the slot (under _slotLock)
    NSUInteger       _diagPendingDrained;   // slot frames processed back-to-back (under _slotLock)

    // ── Diagnostics (Vision queue only) ──────────────────────────────────────
    NSUInteger       _diagFrameCount;       // frames that entered processing (incl. failed)
    CFAbsoluteTime   _diagLastSuccessTime;  // last publish (cadence base); 0 before the first
    uint64_t         _currentGeneration;    // last seen seek-generation stamp (log only)
    BOOL             _loggedNoObservation;
    BOOL             _loggedUnsupportedFormat;
    BOOL             _loggedPublishGeometry;   // IOS_LIVE_GREENSCREEN_VISION_MASK_PUBLISH_GEOMETRY once
}

@synthesize latestMask     = _latestMask;
@synthesize quality        = _quality;
@synthesize qualityName    = _qualityName;
@synthesize ready          = _ready;
@synthesize onTimingSample = _onTimingSample;

// ─── Init ─────────────────────────────────────────────────────────────────────

- (nullable instancetype)initWithQuality:(VGLiveGreenScreenVisionMaskQuality)quality {
    self = [super init];
    if (!self) return nil;

    if (@available(iOS 15.0, *)) {
        // VNGeneratePersonSegmentationRequest is available on this system.
    } else {
        NSLog(@"[VGLiveGreenScreenVisionMaskProvider] IOS_LIVE_GREENSCREEN_VISION_MASK_PROVIDER_UNAVAILABLE reason=requires_ios15");
        return nil;
    }

    _quality     = quality;
    _qualityName = (quality == VGLiveGreenScreenVisionMaskQualityAccurate) ? @"accurate"
                 : (quality == VGLiveGreenScreenVisionMaskQualityBalanced) ? @"balanced"
                                                                            : @"fast";
    atomic_store(&_invalidated, false);
    _slotLock           = OS_UNFAIR_LOCK_INIT;
    _inFlight           = NO;
    _pendingPixelBuffer = NULL;
    _pendingPTS         = kCMTimeInvalid;
    _pendingGeneration  = 0;
    _diagPendingStored  = 0;
    _diagPendingDrained = 0;
    _diagFrameCount     = 0;
    _diagLastSuccessTime = 0;
    _currentGeneration  = UINT64_MAX;
    _loggedNoObservation      = NO;
    _loggedUnsupportedFormat  = NO;
    _loggedPublishGeometry    = NO;
    _latestMask         = nil;
    _onTimingSample     = nil;
    // Plain serial queue, exactly like VGLiteRTMaskProvider's ML queue, so the
    // A/B does not also change dispatch QoS.
    _visionQueue = dispatch_queue_create("com.connects.vanguard.livegreenscreen.vision",
                                         DISPATCH_QUEUE_SERIAL);
    _ready = YES;
    NSLog(@"[VGLiveGreenScreenVisionMaskProvider] IOS_LIVE_GREENSCREEN_VISION_MASK_PROVIDER_CREATED quality=%@ invocationMode=statelessImageRequest outputPixelFormat=OneComponent8 matteTighten=enabled matteTightenLow=%u matteTightenHigh=%u publishGeometry=cameraAspect publishShortSide=%zu publishMaxSide=%zu publishShortSidePolicy=visionOnly",
          _qualityName, (unsigned)kVGVisionMatteTightenLow, (unsigned)kVGVisionMatteTightenHigh,
          kVGVisionMatteOutputShortSide, kMatteOutputMaxSide);
    return self;
}

- (void)dealloc {
    // No concurrent submitFrame can reach a deallocating object (ARC count 0);
    // the Vision queue block holds only a weak reference. Release the slot.
    CVPixelBufferRef pending = _pendingPixelBuffer;
    _pendingPixelBuffer = NULL;
    if (pending) CVPixelBufferRelease(pending);
}

// ─── VGMaskProvider: submitFrame (capture queue; non-blocking) ───────────────

- (void)submitFrame:(CVPixelBufferRef)pixelBuffer
                pts:(CMTime)pts
         generation:(uint64_t)generation {
    if (!pixelBuffer || atomic_load(&_invalidated)) return;

    // +1 for whichever path keeps the frame (dispatch or pending slot).
    CVPixelBufferRetain(pixelBuffer);

    BOOL             dispatchNow = NO;
    CVPixelBufferRef replaced    = NULL;
    os_unfair_lock_lock(&_slotLock);
    if (_inFlight) {
        // A frame is being processed: park this one as the single pending
        // frame (newest wins). Drained by the Vision queue right after the
        // in-flight frame, before _inFlight is cleared — never orphaned.
        replaced            = _pendingPixelBuffer;
        _pendingPixelBuffer = pixelBuffer;
        _pendingPTS         = pts;
        _pendingGeneration  = generation;
        _diagPendingStored++;
    } else {
        _inFlight   = YES;
        dispatchNow = YES;
    }
    os_unfair_lock_unlock(&_slotLock);

    if (replaced) CVPixelBufferRelease(replaced);   // older pending frame dropped
    if (!dispatchNow) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(_visionQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            CVPixelBufferRelease(pixelBuffer);   // provider gone: drop the frame
            return;
        }
        [strongSelf _runFrame:pixelBuffer pts:pts generation:generation];
    });
}

/// Vision queue. Owns +1 on `first`. Processes it, then drains the pending
/// slot back-to-back until it is empty, and only then clears _inFlight under
/// the same lock the submit path uses — so a frame can never land in the slot
/// with nobody left to drain it.
- (void)_runFrame:(CVPixelBufferRef)first pts:(CMTime)pts generation:(uint64_t)generation {
    CVPixelBufferRef current = first;
    CMTime           curPTS  = pts;
    uint64_t         curGen  = generation;

    for (;;) {
        if (!atomic_load(&_invalidated)) {
            [self _processPixelBuffer:current pts:curPTS generation:curGen];
        }
        CVPixelBufferRelease(current);

        os_unfair_lock_lock(&_slotLock);
        CVPixelBufferRef next = _pendingPixelBuffer;
        if (next) {
            curPTS = _pendingPTS;
            curGen = _pendingGeneration;
            _pendingPixelBuffer = NULL;
            _diagPendingDrained++;
        } else {
            _inFlight = NO;
        }
        os_unfair_lock_unlock(&_slotLock);

        if (!next) break;
        current = next;   // +1 moved from the slot to this loop
    }
}

// ─── VGMaskProvider: invalidate (terminal, idempotent) ───────────────────────

- (void)invalidate {
    if (atomic_exchange(&_invalidated, true)) return;   // already terminal
    _ready = NO;
    // A frame already inside _processPixelBuffer holds its own copy of the
    // timing handler and may deliver one final sample; nothing after that.
    self.onTimingSample = nil;

    os_unfair_lock_lock(&_slotLock);
    CVPixelBufferRef stale = _pendingPixelBuffer;
    _pendingPixelBuffer = NULL;
    NSUInteger stored  = _diagPendingStored;
    NSUInteger drained = _diagPendingDrained;
    os_unfair_lock_unlock(&_slotLock);
    if (stale) CVPixelBufferRelease(stale);

    // Nothing Vision-side to release: the request and the VNImageRequestHandler
    // are per-frame locals of _processPixelBuffer (invocationMode=
    // statelessImageRequest) and are gone as soon as that frame returns.
    NSLog(@"[VGLiveGreenScreenVisionMaskProvider] invalidate quality=%@ invocationMode=statelessImageRequest pendingStored=%lu pendingDrained=%lu",
          _qualityName, (unsigned long)stored, (unsigned long)drained);
}

// ─── Private: one frame (Vision queue) ───────────────────────────────────────

- (void)_processPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        pts:(CMTime)pts
                 generation:(uint64_t)generation {
    if (@available(iOS 15.0, *)) {
        _diagFrameCount++;
        if (generation != _currentGeneration) {
            // No temporal state of our own to reset; recorded for the log/sample only.
            _currentGeneration = generation;
        }
        // Camera frame size: the published matte is resampled to THIS aspect
        // (see VGVisionMattePublishSizeForSource). Read only; the frame itself
        // is never rotated, mirrored, or otherwise altered here.
        const size_t sourceW = CVPixelBufferGetWidth(pixelBuffer);
        const size_t sourceH = CVPixelBufferGetHeight(pixelBuffer);
        const BOOL shouldLog = (_diagFrameCount <= 3) || (_diagFrameCount % kVGVisionDiagLogInterval == 1);
        // Atomic copy read once per frame; nil → throttled log path only.
        VGLiteRTMaskProviderTimingHandler timingHandler = self.onTimingSample;
        const BOOL measure = shouldLog || (timingHandler != nil);
        CFAbsoluteTime t0 = measure ? CFAbsoluteTimeGetCurrent() : 0;

        // ── pre: fresh request + fresh image handler for THIS frame ──────────
        // invocationMode=statelessImageRequest. Both objects are locals of this
        // method: a new VNGeneratePersonSegmentationRequest (same quality
        // mapping, output format and execution intent as before) and a new
        // VNImageRequestHandler bound to this camera pixel buffer. Nothing is
        // stored on the provider, so no Vision temporal state can survive from
        // one frame to the next. The per-frame allocation + configuration is
        // charged to preMs on purpose: the A/B measures it.
        VNGeneratePersonSegmentationRequest *request = [[VNGeneratePersonSegmentationRequest alloc] init];
        request.qualityLevel = (_quality == VGLiveGreenScreenVisionMaskQualityAccurate)
            ? VNGeneratePersonSegmentationRequestQualityLevelAccurate
            : (_quality == VGLiveGreenScreenVisionMaskQualityBalanced)
                ? VNGeneratePersonSegmentationRequestQualityLevelBalanced
                : VNGeneratePersonSegmentationRequestQualityLevelFast;
        // OneComponent8 (255 = person) is what the adapter's matte cache
        // and compositor consume; the extraction below rejects anything else.
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8;
        // Explicit low-latency execution intent for the Vision RND backend:
        // foreground scheduling, GPU/ANE permitted. The defaults may already
        // match; the physical timing run is the proof, not these lines.
        request.preferBackgroundProcessing = NO;
        request.usesCPUOnly = NO;
        // No orientation is passed (initWithCVPixelBuffer:options:, not the
        // orientation: variant): the camera pixel buffer is consumed as-is, so
        // the mask keeps the buffer's own orientation for the compositor. The
        // handler retains the pixel buffer only for its own lifetime, which
        // ends when this method returns.
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
                                                                                       options:@{}];
        CFAbsoluteTime t1 = measure ? CFAbsoluteTimeGetCurrent() : 0;

        // ── invoke: the Vision request on the stateless single-image path ────
        NSError *error = nil;
        BOOL performed = [handler performRequests:@[request] error:&error];
        CFAbsoluteTime t2 = measure ? CFAbsoluteTimeGetCurrent() : 0;
        if (!performed || error) {
            if (_diagFrameCount <= 3 || shouldLog) {
                NSLog(@"[VGLiveGreenScreenVisionMaskProvider] performRequests failed frame=%lu error=%@",
                      (unsigned long)_diagFrameCount, error.localizedDescription ?: @"unknown");
            }
            return;   // nothing published for this frame
        }

        // ── outputAccess: observation → pixel buffer + format check ─────────
        VNPixelBufferObservation *observation = request.results.firstObject;
        CVPixelBufferRef maskBuffer = observation ? observation.pixelBuffer : NULL;
        size_t maskW = 0, maskH = 0;
        BOOL   supported = NO;
        if (!maskBuffer) {
            if (!_loggedNoObservation) {
                _loggedNoObservation = YES;
                NSLog(@"[VGLiveGreenScreenVisionMaskProvider] no VNPixelBufferObservation for frame=%lu — nothing published (logged once)",
                      (unsigned long)_diagFrameCount);
            }
        } else {
            OSType fmt = CVPixelBufferGetPixelFormatType(maskBuffer);
            maskW = CVPixelBufferGetWidth(maskBuffer);
            maskH = CVPixelBufferGetHeight(maskBuffer);
            supported = (fmt == kCVPixelFormatType_OneComponent8 &&
                         maskW > 0 && maskH > 0 &&
                         maskW <= kVGVisionMaskMaxSide && maskH <= kVGVisionMaskMaxSide);
            if (!supported && !_loggedUnsupportedFormat) {
                _loggedUnsupportedFormat = YES;
                NSLog(@"[VGLiveGreenScreenVisionMaskProvider] unsupported Vision mask format=0x%08X size=%zux%zu (expected OneComponent8) — nothing published (logged once)",
                      (unsigned int)fmt, maskW, maskH);
            }
        }
        CFAbsoluteTime t2o = measure ? CFAbsoluteTimeGetCurrent() : 0;
        if (!supported) return;

        // ── policy: raw OneComponent8 mask → camera-aspect resample + tighten →
        //    immutable VGSkinMask ────────────────────────────────────────────
        VGSkinMask *mask = [self _copyMaskFromVisionBuffer:maskBuffer
                                                     width:maskW
                                                    height:maskH
                                               sourceWidth:sourceW
                                              sourceHeight:sourceH
                                                       pts:pts];
        CFAbsoluteTime t3 = measure ? CFAbsoluteTimeGetCurrent() : 0;
        if (!mask) return;

        // ── publish ──────────────────────────────────────────────────────────
        CFAbsoluteTime now = (t3 > 0) ? t3 : CFAbsoluteTimeGetCurrent();
        double cadenceMs = (_diagLastSuccessTime > 0) ? (now - _diagLastSuccessTime) * 1000.0 : -1.0;
        double preMs = 0, invokeMs = 0, outputAccessMs = 0, policyMs = 0;
        double inferMs = 0, postMs = 0, totalMs = 0;
        if (measure) {
            // Mapping (see header): pre = per-frame request + image-handler
            // allocation/configuration, inputCopy = 0, invoke = perform span,
            // outputAccess = observation lookup, policy = camera-aspect
            // resample + tighten of the raw mask into the VGSkinMask.
            preMs          = (t1  - t0)  * 1000.0;
            invokeMs       = (t2  - t1)  * 1000.0;
            outputAccessMs = (t2o - t2)  * 1000.0;
            policyMs       = (t3  - t2o) * 1000.0;
            inferMs        = invokeMs;                    // inputCopyMs (0) + invokeMs
            postMs         = (t3  - t2)  * 1000.0;        // outputAccessMs + policyMs
            totalMs        = (t3  - t0)  * 1000.0;        // preMs + inferMs + postMs
        }
        if (!_loggedPublishGeometry) {
            _loggedPublishGeometry = YES;
            NSLog(@"[VGLiveGreenScreenVisionMaskProvider] IOS_LIVE_GREENSCREEN_VISION_MASK_PUBLISH_GEOMETRY quality=%@ invocationMode=statelessImageRequest rawMask=%zux%zu publishedMask=%zux%zu source=%zux%zu resampled=%@ publishShortSide=%zu publishMaxSide=%zu publishShortSidePolicy=visionOnly",
                  _qualityName, maskW, maskH, mask.width, mask.height, sourceW, sourceH,
                  (mask.width == maskW && mask.height == maskH) ? @"NO" : @"YES",
                  kVGVisionMatteOutputShortSide, kMatteOutputMaxSide);
        }
        if (shouldLog) {
            NSLog(@"[VGLiveGreenScreenVisionMaskProvider diagnostic] pre=%.1fms invoke=%.1fms out=%.1fms copy=%.1fms total=%.1fms cadence=%.1fms quality=%@ invocationMode=statelessImageRequest rawMask=%zux%zu publishedMask=%zux%zu source=%zux%zu pts=%.3fs gen=%llu frame=%lu",
                  preMs, invokeMs, outputAccessMs, policyMs, totalMs, cadenceMs,
                  _qualityName, maskW, maskH, mask.width, mask.height, sourceW, sourceH,
                  CMTimeGetSeconds(pts),
                  (unsigned long long)generation, (unsigned long)_diagFrameCount);
        }
        _diagLastSuccessTime = now;
        _latestMask = mask;   // atomic publish

        // Sample after the publish so a handler reading latestMask sees this mask.
        if (timingHandler) {
            VGLiteRTMaskProviderTimingSample sample;
            sample.preMs          = preMs;
            sample.inferMs        = inferMs;
            sample.postMs         = postMs;
            sample.totalMs        = totalMs;
            sample.inputCopyMs    = 0.0;            // no host → tensor copy in the Vision path
            sample.invokeMs       = invokeMs;       // per-frame VNImageRequestHandler performRequests: (stateless)
            sample.outputAccessMs = outputAccessMs; // observation / pixel-buffer lookup
            sample.policyMs       = policyMs;       // camera-aspect resample + matte tighten into VGSkinMask
            sample.cadenceMs      = cadenceMs;
            sample.ptsSeconds     = CMTimeGetSeconds(pts);
            sample.generation     = generation;
            sample.frameIndex     = _diagFrameCount;
            timingHandler(sample);
        }
    } else {
        // Unreachable: init returns nil below iOS 15. Kept so the @available
        // guard fully covers every Vision symbol in this file.
        (void)pixelBuffer; (void)pts; (void)generation;
    }
}

/// Builds the published VGSkinMask (faceCount 1 = valid person matte) from a
/// raw OneComponent8 Vision mask of `w`×`h`:
///   1. the output size is the camera-aspect policy size for
///      (sourceWidth, sourceHeight) — VGVisionMattePublishSizeForSource;
///   2. the raw Vision bytes (rows addressed by the buffer's own bytesPerRow,
///      so row padding is dropped) are bilinearly resampled over normalized
///      coordinates into that tightly packed output. x and y scale
///      independently on purpose: the observation is a normalized matte of the
///      whole camera frame, not a texture whose pixel aspect must survive;
///   3. VGVisionMatteTightenByte is applied to every byte as it is written
///      (see the Vision matte tighten constants above).
/// When the output size equals the raw size the resample degenerates to the
/// plain row copy + tighten. Same single malloc(outW * outH) + NSData ownership
/// pattern as before; the Vision buffer is only read under a read-only lock and
/// never retained. Returns nil on any lock/allocation failure (nothing is
/// published for that frame).
- (nullable VGSkinMask *)_copyMaskFromVisionBuffer:(CVPixelBufferRef)maskBuffer
                                             width:(size_t)w
                                            height:(size_t)h
                                       sourceWidth:(size_t)sourceWidth
                                      sourceHeight:(size_t)sourceHeight
                                               pts:(CMTime)pts {
    size_t outW = 0, outH = 0;
    VGVisionMattePublishSizeForSource(sourceWidth, sourceHeight, w, h, &outW, &outH);
    if (outW == 0 || outH == 0) return nil;

    if (CVPixelBufferLockBaseAddress(maskBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return nil;
    }
    const uint8_t *src       = (const uint8_t *)CVPixelBufferGetBaseAddress(maskBuffer);
    size_t         srcBPR    = CVPixelBufferGetBytesPerRow(maskBuffer);
    const size_t   outPixels = outW * outH;
    uint8_t       *dst       = (src && srcBPR >= w) ? (uint8_t *)malloc(outPixels) : NULL;
    if (!dst) {
        CVPixelBufferUnlockBaseAddress(maskBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }

    if (outW == w && outH == h) {
        // Identity geometry: per-byte tighten while copying. Source rows are
        // addressed by srcBPR (row padding dropped); destination tightly packed.
        for (size_t y = 0; y < h; y++) {
            const uint8_t *srcRow = src + y * srcBPR;
            uint8_t       *dstRow = dst + y * outW;
            for (size_t x = 0; x < w; x++) {
                dstRow[x] = VGVisionMatteTightenByte(srcRow[x]);
            }
        }
    } else {
        // Camera-aspect resample: per-column bilinear lookup tables (x0, x1, tx)
        // built once per frame, rows computed inline. Same centre-aligned
        // sample mapping as VGLiveGreenScreenPersonMattePolicy.
        size_t *colX0 = (size_t *)malloc(outW * sizeof(size_t));
        size_t *colX1 = (size_t *)malloc(outW * sizeof(size_t));
        float  *colTX = (float  *)malloc(outW * sizeof(float));
        if (!colX0 || !colX1 || !colTX) {
            free(colX0); free(colX1); free(colTX); free(dst);
            CVPixelBufferUnlockBaseAddress(maskBuffer, kCVPixelBufferLock_ReadOnly);
            return nil;
        }
        const float sx = (float)w / (float)outW;
        const float sy = (float)h / (float)outH;
        for (size_t ox = 0; ox < outW; ox++) {
            float fx = ((float)ox + 0.5f) * sx - 0.5f;
            if (fx < 0.0f) fx = 0.0f;
            size_t x0 = (size_t)fx;
            if (x0 > w - 1) x0 = w - 1;
            size_t x1 = (x0 + 1 < w) ? x0 + 1 : x0;
            colX0[ox] = x0;
            colX1[ox] = x1;
            colTX[ox] = VGMatteClamp01(fx - (float)x0);
        }
        for (size_t oy = 0; oy < outH; oy++) {
            float fy = ((float)oy + 0.5f) * sy - 0.5f;
            if (fy < 0.0f) fy = 0.0f;
            size_t y0 = (size_t)fy;
            if (y0 > h - 1) y0 = h - 1;
            size_t y1 = (y0 + 1 < h) ? y0 + 1 : y0;
            float  ty = VGMatteClamp01(fy - (float)y0);

            const uint8_t *row0   = src + y0 * srcBPR;
            const uint8_t *row1   = src + y1 * srcBPR;
            uint8_t       *dstRow = dst + oy * outW;
            for (size_t ox = 0; ox < outW; ox++) {
                size_t x0 = colX0[ox], x1 = colX1[ox];
                float  tx = colTX[ox];
                float  a  = (float)row0[x0], b = (float)row0[x1];
                float  c  = (float)row1[x0], d = (float)row1[x1];
                float  top    = a + (b - a) * tx;
                float  bottom = c + (d - c) * tx;
                float  p      = top + (bottom - top) * ty;   // 0…255 (convex combination)
                dstRow[ox] = VGVisionMatteTightenByte((uint8_t)(p + 0.5f));
            }
        }
        free(colX0); free(colX1); free(colTX);
    }
    CVPixelBufferUnlockBaseAddress(maskBuffer, kCVPixelBufferLock_ReadOnly);

    // dataWithBytesNoCopy → VGSkinMask's `[data copy]` on an immutable NSData
    // is a retain, not a second copy (same trick as the LiteRT matte policy).
    NSData *maskData = [NSData dataWithBytesNoCopy:dst length:outPixels freeWhenDone:YES];
    return [[VGSkinMask alloc] _initWithData:maskData
                                       width:outW
                                      height:outH
                                   sourcePTS:pts
                                   faceCount:1];
}

@end

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - VGLiveGreenScreenMaskProviderAdapter
// ═════════════════════════════════════════════════════════════════════════════

static NSString * const kVGLiveGSModelName          = @"selfie_multiclass_256x256";
/// RND backend "litertSelfie": the Android production MediaPipe CPU model
/// (single-channel person confidence; 256×144 landscape input and output).
static NSString * const kVGLiveGSSelfieModelName    = @"selfie_segmentation_landscape";
static const NSTimeInterval kVGLiveGSDefaultMaxAge  = 0.25;
/// Upper bound on live pooled matte buffers (cache + in-flight composite + slack).
static const int kVGLiveGSMaxPooledMatteBuffers     = 4;
/// Stable generation stamp for the whole live session (no seeks in live camera).
static const uint64_t kVGLiveGSGeneration           = 1;

// Segmentation backend selector strings (declared in the header).
NSString * const VGLiveGreenScreenSegmentationBackendLiteRT         = @"litert";
NSString * const VGLiveGreenScreenSegmentationBackendVisionFast     = @"visionFast";
NSString * const VGLiveGreenScreenSegmentationBackendVisionBalanced = @"visionBalanced";
NSString * const VGLiveGreenScreenSegmentationBackendVisionAccurate = @"visionAccurate";
NSString * const VGLiveGreenScreenSegmentationBackendLiteRTSelfie   = @"litertSelfie";

/// Parsed form of the backend string, resolved once at init.
typedef NS_ENUM(NSInteger, VGLiveGSBackendSelection) {
    VGLiveGSBackendSelectionUnknown        = 0,
    VGLiveGSBackendSelectionLiteRT         = 1,
    VGLiveGSBackendSelectionVisionFast     = 2,
    VGLiveGSBackendSelectionVisionBalanced = 3,
    VGLiveGSBackendSelectionVisionAccurate = 4,
    VGLiveGSBackendSelectionLiteRTSelfie   = 5,
};

static VGLiveGSBackendSelection VGLiveGSParseBackend(NSString *backend) {
    if ([backend isEqualToString:VGLiveGreenScreenSegmentationBackendLiteRT])         return VGLiveGSBackendSelectionLiteRT;
    if ([backend isEqualToString:VGLiveGreenScreenSegmentationBackendVisionFast])     return VGLiveGSBackendSelectionVisionFast;
    if ([backend isEqualToString:VGLiveGreenScreenSegmentationBackendVisionBalanced]) return VGLiveGSBackendSelectionVisionBalanced;
    if ([backend isEqualToString:VGLiveGreenScreenSegmentationBackendVisionAccurate]) return VGLiveGSBackendSelectionVisionAccurate;
    if ([backend isEqualToString:VGLiveGreenScreenSegmentationBackendLiteRTSelfie])   return VGLiveGSBackendSelectionLiteRTSelfie;
    return VGLiveGSBackendSelectionUnknown;
}

static NSString *VGLiveGSInputGeometryName(VGLiteRTInputGeometry geometry) {
    return geometry == VGLiteRTInputGeometryAspectFit ? @"aspectFit" : @"stretch";
}

@interface VGLiveGreenScreenMaskProviderAdapter ()
@property (atomic, readwrite) VGLiveGreenScreenMaskProviderKind providerKind;
@end

@implementation VGLiveGreenScreenMaskProviderAdapter {
    os_unfair_lock _lock;

    // ── Lifecycle (under _lock) ───────────────────────────────────────────────
    BOOL _active;        // start() ran and invalidate() has not
    BOOL _invalidated;   // terminal

    // ── Backend request (fixed at init; read without the lock) ───────────────
    VGLiveGSBackendSelection _backendSelection;

    // ── Providers (under _lock) ───────────────────────────────────────────────
    id<VGMaskProvider>                   _provider;   // active submit/read target
    VGLiteRTMaskProvider                *_liteRT;     // non-nil only when kind == LiteRT
    VGLiveGreenScreenVisionMaskProvider *_vision;     // non-nil only when kind == Vision
    VGHeuristicMaskProvider             *_heuristic;  // non-nil only when kind == HeuristicFallback
    CMTime                               _lastSubmittedPTS;

    // ── Matte cache (under _lock) ─────────────────────────────────────────────
    VGSkinMask          *_cachedMask;       // provider object the buffer was copied from
    CVPixelBufferRef     _cachedBuffer;     // +1 owned by the cache
    CFTimeInterval       _cachedObservedAt; // CACurrentMediaTime when first observed
    CVPixelBufferPoolRef _pool;
    size_t               _poolW, _poolH;
    BOOL                 _loggedFirstMask;

    dispatch_queue_t _setupQueue;

    // ── Diagnostics (under _diagLock; independent of _lock) ──────────────────
    // Fed by VGLiteRTMaskProvider.onTimingSample on the provider's ML queue
    // and by the cache-copy path in latestMaskRetained (which already holds
    // _lock and takes _diagLock nested: lock order is _lock → _diagLock only).
    os_unfair_lock _diagLock;
    CFAbsoluteTime _diagStartedAt;            // start() wall time
    double         _diagProviderSetupMs;      // -1 until a provider is selected
    // Metal precision option: requested (captured by start) / applied (provider).
    BOOL           _diagMetalPrecisionLossRequested;
    BOOL           _diagMetalPrecisionLossApplied;
    NSString      *_diagInferenceBackend;     // LiteRT: VGLiteRTMaskProvider.inferenceBackend; Vision: qualityName; nil otherwise
    // Terminal provider setup failure reason (kind == Unavailable only). Set
    // once by _setupProvidersStartedAt: and NEVER cleared — not even by
    // invalidate — so the owner can still read why keying failed after it
    // released the adapter. nil while no failure exists.
    NSString      *_diagFailureReason;
    // Model / matte-path echo of the running LiteRT provider (nil / 0 for every other kind).
    NSString      *_diagModelName;            // asset base name, e.g. selfie_multiclass_256x256
    NSString      *_diagMattePath;            // VGLiteRTMaskProvider.mattePath
    NSString      *_diagInputGeometry;        // "stretch" | "aspectFit"
    NSInteger      _diagModelInputW,  _diagModelInputH,  _diagModelInputC;
    NSInteger      _diagModelOutputW, _diagModelOutputH, _diagModelOutputC;
    // LiteRT per-frame timing samples.
    NSUInteger     _diagSampleCount;
    double         _diagSumTotalMs,   _diagMaxTotalMs,   _diagMinTotalMs;
    double         _diagSumInferMs,   _diagMaxInferMs,   _diagMinInferMs;
    double         _diagSumCopyMs,    _diagMaxCopyMs,    _diagMinCopyMs;
    double         _diagSumInvokeMs,  _diagMaxInvokeMs,  _diagMinInvokeMs;
    double         _diagSumOutMs,     _diagMaxOutMs,     _diagMinOutMs;
    double         _diagSumPolicyMs;
    double         _diagSumPreMs,     _diagSumPostMs;
    NSUInteger     _diagCadenceCount;         // positive-cadence samples only
    double         _diagSumCadenceMs, _diagMaxCadenceMs;
    double         _diagFirstTotalMs, _diagLastTotalMs;
    double         _diagLastInferMs,  _diagLastCadenceMs;
    double         _diagLastCopyMs,   _diagLastInvokeMs, _diagLastOutMs;
    double         _diagLastPtsSeconds;
    NSUInteger     _diagLastFrameIndex;
    double         _diagFirstPublishLatencyMs; // start() → first LiteRT sample
    // Matte publication into the compositor-facing cache.
    NSUInteger     _diagMaskPublishCount;
    double         _diagFirstMaskLatencyMs;    // start() → first cached matte
    double         _diagLastMaskCoveragePercent;
    size_t         _diagLastMaskW, _diagLastMaskH;
}

@synthesize providerKind        = _providerKind;
@synthesize fastMetalPrecision  = _fastMetalPrecision;
@synthesize segmentationBackend = _segmentationBackend;
@dynamic    failureReason;   // getter below reads _diagFailureReason under _diagLock

+ (NSTimeInterval)defaultMaxMaskAgeSeconds {
    return kVGLiveGSDefaultMaxAge;
}

- (instancetype)init {
    // Production path: Vision Fast, full float32 Metal precision.
    return [self initWithFastMetalPrecision:NO];
}

- (instancetype)initWithFastMetalPrecision:(BOOL)fastMetalPrecision {
    // Production default: Vision Fast backend.
    return [self initWithFastMetalPrecision:fastMetalPrecision
                        segmentationBackend:VGLiveGreenScreenSegmentationBackendVisionFast];
}

- (instancetype)initWithFastMetalPrecision:(BOOL)fastMetalPrecision
                       segmentationBackend:(NSString *)segmentationBackend {
    self = [super init];
    if (!self) return nil;
    _lock                    = OS_UNFAIR_LOCK_INIT;
    _active                  = NO;
    _invalidated             = NO;
    _lastSubmittedPTS        = kCMTimeInvalid;
    _providerKind            = VGLiveGreenScreenMaskProviderKindPending;
    _fastMetalPrecision      = fastMetalPrecision;   // fixed for this adapter's lifetime; forwarded by start()
    _segmentationBackend     = [segmentationBackend copy] ?: VGLiveGreenScreenSegmentationBackendVisionFast;
    _backendSelection        = VGLiveGSParseBackend(_segmentationBackend);   // Unknown → Unavailable at setup
    _setupQueue              = dispatch_queue_create("com.connects.vanguard.livegreenscreen.masksetup",
                                                     DISPATCH_QUEUE_SERIAL);

    _diagLock                   = OS_UNFAIR_LOCK_INIT;
    _diagStartedAt              = 0;
    _diagProviderSetupMs        = -1.0;
    _diagMetalPrecisionLossRequested = NO;
    _diagMetalPrecisionLossApplied   = NO;
    _diagInferenceBackend       = nil;
    _diagFailureReason          = nil;
    _diagModelName              = nil;
    _diagMattePath              = nil;
    _diagInputGeometry          = nil;
    _diagModelInputW  = _diagModelInputH  = _diagModelInputC  = 0;
    _diagModelOutputW = _diagModelOutputH = _diagModelOutputC = 0;
    _diagSampleCount            = 0;
    _diagSumTotalMs = _diagMaxTotalMs = _diagMinTotalMs = 0;
    _diagSumInferMs = _diagMaxInferMs = _diagMinInferMs = 0;
    _diagSumCopyMs   = _diagMaxCopyMs   = _diagMinCopyMs   = 0;
    _diagSumInvokeMs = _diagMaxInvokeMs = _diagMinInvokeMs = 0;
    _diagSumOutMs    = _diagMaxOutMs    = _diagMinOutMs    = 0;
    _diagSumPolicyMs            = 0;
    _diagSumPreMs   = _diagSumPostMs  = 0;
    _diagCadenceCount           = 0;
    _diagSumCadenceMs = _diagMaxCadenceMs = 0;
    _diagFirstTotalMs = _diagLastTotalMs = -1.0;
    _diagLastInferMs  = _diagLastCadenceMs = -1.0;
    _diagLastCopyMs = _diagLastInvokeMs = _diagLastOutMs = -1.0;
    _diagLastPtsSeconds         = -1.0;
    _diagLastFrameIndex         = 0;
    _diagFirstPublishLatencyMs  = -1.0;
    _diagMaskPublishCount       = 0;
    _diagFirstMaskLatencyMs     = -1.0;
    _diagLastMaskCoveragePercent = -1.0;
    _diagLastMaskW = _diagLastMaskH = 0;
    return self;
}

- (void)dealloc {
    [self _invalidateInternal];
}

// ─── start (main) ────────────────────────────────────────────────────────────

- (void)start {
    NSAssert([NSThread isMainThread], @"VGLiveGreenScreenMaskProviderAdapter.start must run on main");
    os_unfair_lock_lock(&_lock);
    if (_active || _invalidated) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _active = YES;
    os_unfair_lock_unlock(&_lock);

    // Precision option fixed at init (fastMetalPrecision) and forwarded to the
    // provider exactly once, here: the Metal delegate is configured at creation.
    const BOOL allowPrecisionLoss = self.fastMetalPrecision;

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&_diagLock);
    _diagStartedAt = t0;
    _diagMetalPrecisionLossRequested = allowPrecisionLoss;
    os_unfair_lock_unlock(&_diagLock);

    __weak typeof(self) weakSelf = self;
    dispatch_async(_setupQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf _isActive]) return;
        [strongSelf _setupProvidersStartedAt:t0 metalAllowPrecisionLoss:allowPrecisionLoss];
    });
}

- (BOOL)_isActive {
    os_unfair_lock_lock(&_lock);
    BOOL active = _active && !_invalidated;
    os_unfair_lock_unlock(&_lock);
    return active;
}

/// Runs on _setupQueue. Builds the provider for the requested backend —
/// "litert": LiteRT (preferred) or the heuristic fallback; "visionFast" /
/// "visionBalanced" / "visionAccurate": the Vision provider with NO fallback;
/// "litertSelfie": LiteRT on the small selfie model with NO fallback — then
/// installs whichever exists, unless invalidate() won the race, in which case
/// the freshly built provider is torn down immediately.
- (void)_setupProvidersStartedAt:(CFAbsoluteTime)t0
         metalAllowPrecisionLoss:(BOOL)allowPrecisionLoss {
    NSString                            *fallbackReason = nil;
    NSString                            *modelName = nil;   // LiteRT backends only
    VGLiteRTMaskProvider                *liteRT    = nil;
    VGLiveGreenScreenVisionMaskProvider *vision    = nil;
    VGHeuristicMaskProvider             *heuristic = nil;

    switch (_backendSelection) {
        case VGLiveGSBackendSelectionLiteRT: {
            modelName = kVGLiveGSModelName;
            NSURL *modelURL = [VGMLModelBundle URLForModelNamed:modelName];
            if (!modelURL) {
                fallbackReason = @"model_asset_missing";
            } else {
                VGLiveGreenScreenPersonMattePolicy *policy = [[VGLiveGreenScreenPersonMattePolicy alloc] init];
                // fallback:nil on purpose — see header (no dual-feeding of dropped frames).
                // metalAllowPrecisionLoss:NO is the pre-existing full-precision path.
                liteRT = [[VGLiteRTMaskProvider alloc] initWithModelURL:modelURL
                                                               fallback:nil
                                                                 policy:policy
                                                metalAllowPrecisionLoss:allowPrecisionLoss];
                if (!liteRT) {
                    fallbackReason = @"litert_init_returned_nil";
                } else if (liteRT.isUsingFallback || !liteRT.isReady) {
                    fallbackReason = liteRT.isUsingFallback ? @"litert_entered_fallback_mode"
                                                            : @"litert_not_ready";
                    [liteRT invalidate];
                    liteRT = nil;
                }
            }
            // Heuristic fallback exists for the LiteRT backend only (unchanged).
            if (!liteRT) heuristic = [[VGHeuristicMaskProvider alloc] init];
            break;
        }
        case VGLiveGSBackendSelectionLiteRTSelfie: {
            // RND: the small single-channel selfie segmenter (Android's
            // production MediaPipe CPU model) on the same LiteRT/Metal runtime.
            //   policy:nil            — the provider publishes the person-confidence
            //                           channel directly at the model output size.
            //   aspect-fit geometry   — aspect-preserving input; the compositor's
            //                           scale-to-fill of the model-aspect matte
            //                           crops exactly the zero border.
            //   warm-up invoke        — the model carries a MediaPipe custom op
            //                           (Convolution2DTransposeBias) only the
            //                           Metal delegate can run: fail closed at
            //                           setup, not on every frame.
            // Deliberately NO heuristic fallback: an RND run must never report
            // numbers produced by a different provider than requested.
            modelName = kVGLiveGSSelfieModelName;
            NSURL *modelURL = [VGMLModelBundle URLForModelNamed:modelName];
            if (!modelURL) {
                fallbackReason = @"selfie_model_asset_missing";
            } else {
                liteRT = [[VGLiteRTMaskProvider alloc] initWithModelURL:modelURL
                                                               fallback:nil
                                                                 policy:nil
                                                metalAllowPrecisionLoss:allowPrecisionLoss
                                                          inputGeometry:VGLiteRTInputGeometryAspectFit
                                                    warmUpInvokeAtSetup:YES];
                if (!liteRT) {
                    fallbackReason = @"litert_selfie_init_returned_nil";
                } else if (liteRT.isUsingFallback || !liteRT.isReady) {
                    fallbackReason = liteRT.isUsingFallback ? @"litert_selfie_entered_fallback_mode"
                                                            : @"litert_selfie_not_ready";
                    [liteRT invalidate];
                    liteRT = nil;
                } else if (liteRT.outputChannels != 1 && liteRT.outputChannels != 2) {
                    // A multiclass asset under this name would run the default
                    // face/neck beauty policy — not a person matte. Fail closed.
                    fallbackReason = [NSString stringWithFormat:@"litert_selfie_unexpected_output_channels(%ld)",
                                      (long)liteRT.outputChannels];
                    [liteRT invalidate];
                    liteRT = nil;
                }
            }
            break;
        }
        case VGLiveGSBackendSelectionVisionFast:
        case VGLiveGSBackendSelectionVisionBalanced:
        case VGLiveGSBackendSelectionVisionAccurate: {
            VGLiveGreenScreenVisionMaskQuality quality =
                (_backendSelection == VGLiveGSBackendSelectionVisionAccurate)
                    ? VGLiveGreenScreenVisionMaskQualityAccurate
                    : (_backendSelection == VGLiveGSBackendSelectionVisionBalanced)
                        ? VGLiveGreenScreenVisionMaskQualityBalanced
                        : VGLiveGreenScreenVisionMaskQualityFast;
            vision = [[VGLiveGreenScreenVisionMaskProvider alloc] initWithQuality:quality];
            if (!vision) {
                fallbackReason = @"vision_person_segmentation_unavailable";
            } else if (!vision.isReady) {
                fallbackReason = @"vision_not_ready";
                [vision invalidate];
                vision = nil;
            }
            // Deliberately no heuristic fallback: a Vision A/B run must never
            // report numbers produced by a different provider than requested.
            break;
        }
        default: {
            fallbackReason = [NSString stringWithFormat:@"unknown_segmentation_backend(%@)", _segmentationBackend];
            break;
        }
    }

    id<VGMaskProvider> chosen = liteRT ? (id<VGMaskProvider>)liteRT
                              : vision ? (id<VGMaskProvider>)vision
                                       : (id<VGMaskProvider>)heuristic;

    VGLiveGreenScreenMaskProviderKind kind;
    if (liteRT)         kind = VGLiveGreenScreenMaskProviderKindLiteRT;
    else if (vision)    kind = VGLiveGreenScreenMaskProviderKindVision;
    else if (heuristic) kind = VGLiveGreenScreenMaskProviderKindHeuristicFallback;
    else                kind = VGLiveGreenScreenMaskProviderKindUnavailable;

    double setupMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;

    if (liteRT || vision) {
        // Diagnostic hook: runs on the provider's serial queue after each publish.
        // Installed before the provider becomes reachable through _provider,
        // so every publish of this session is sampled. Weak self: the provider
        // owns the block and the adapter owns the provider. Both providers
        // deliver the same VGLiteRTMaskProviderTimingSample (the Vision field
        // mapping is documented in VGLiveGreenScreenVisionMaskProvider.h).
        __weak typeof(self) weakSelf = self;
        VGLiteRTMaskProviderTimingHandler hook = ^(VGLiteRTMaskProviderTimingSample sample) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf _recordTimingSample:sample];
        };
        if (liteRT) liteRT.onTimingSample = hook;
        if (vision) vision.onTimingSample = hook;
    }

    os_unfair_lock_lock(&_lock);
    if (!_active || _invalidated) {
        os_unfair_lock_unlock(&_lock);
        [liteRT invalidate];
        [vision invalidate];
        [heuristic invalidate];
        NSLog(@"[VGLiveGreenScreenMaskProviderAdapter] provider setup finished after invalidate — discarded (setupMs=%.0f)", setupMs);
        return;
    }
    _liteRT    = liteRT;
    _vision    = vision;
    _heuristic = heuristic;
    _provider  = chosen;
    os_unfair_lock_unlock(&_lock);

    if (kind == VGLiveGreenScreenMaskProviderKindUnavailable) {
        // Persist the terminal failure reason BEFORE the kind flips to
        // Unavailable and before onProviderUnavailable fires, so any
        // diagnosticsSnapshot taken from that point on carries it. The
        // heuristic-fallback case is not a failure and leaves this nil.
        NSString *terminalReason = [fallbackReason copy] ?: @"unknown";
        os_unfair_lock_lock(&_diagLock);
        _diagFailureReason = terminalReason;
        os_unfair_lock_unlock(&_diagLock);
    }
    self.providerKind = kind;

    // Precision actually applied: only meaningful for a READY LiteRT provider
    // (always NO for Vision — the request is echoed, never applied).
    BOOL      appliedPrecisionLoss = liteRT ? liteRT.metalAllowPrecisionLoss : NO;
    NSString *backend              = liteRT ? liteRT.inferenceBackend
                                   : vision ? vision.qualityName : nil;

    // Model / matte-path echo (LiteRT kinds only; nil / 0 otherwise).
    NSString *readyModelName    = liteRT ? modelName : nil;
    NSString *readyMattePath    = liteRT ? liteRT.mattePath : nil;
    NSString *readyGeometryName = liteRT ? VGLiveGSInputGeometryName(liteRT.inputGeometry) : nil;

    os_unfair_lock_lock(&_diagLock);
    _diagProviderSetupMs             = setupMs;
    _diagMetalPrecisionLossApplied   = appliedPrecisionLoss;
    _diagInferenceBackend            = [backend copy];
    _diagModelName                   = [readyModelName copy];
    _diagMattePath                   = [readyMattePath copy];
    _diagInputGeometry               = [readyGeometryName copy];
    _diagModelInputW  = liteRT ? liteRT.inputWidth     : 0;
    _diagModelInputH  = liteRT ? liteRT.inputHeight    : 0;
    _diagModelInputC  = liteRT ? liteRT.inputChannels  : 0;
    _diagModelOutputW = liteRT ? liteRT.outputWidth    : 0;
    _diagModelOutputH = liteRT ? liteRT.outputHeight   : 0;
    _diagModelOutputC = liteRT ? liteRT.outputChannels : 0;
    os_unfair_lock_unlock(&_diagLock);

#if TARGET_OS_SIMULATOR
    NSString *delegateName = @"cpu_simulator";
#else
    NSString *delegateName = @"metal";   // on device VGLiteRTMaskProvider is ready only with the Metal delegate attached
#endif

    switch (kind) {
        case VGLiveGreenScreenMaskProviderKindLiteRT: {
            NSString *policyName = (_backendSelection == VGLiveGSBackendSelectionLiteRTSelfie)
                ? @"none(direct_person_confidence,no_temporal_smoothing)"
                : @"VGLiveGreenScreenPersonMattePolicy";
            NSLog(@"[VGLiveGreenScreenMaskProviderAdapter] IOS_LIVE_GREENSCREEN_MASK_PROVIDER_LITERT_READY model=%@ delegate=%@ backend=%@ metalAllowPrecisionLoss=%@ policy=%@ mattePath=%@ inputGeometry=%@ inputTensor=%ldx%ldx%ld outputTensor=%ldx%ldx%ld segmentationBackend=%@ setupMs=%.0f",
                  readyModelName ?: @"unknown", delegateName, backend ?: @"unknown",
                  appliedPrecisionLoss ? @"true" : @"false", policyName,
                  readyMattePath ?: @"unknown", readyGeometryName ?: @"unknown",
                  (long)liteRT.inputWidth, (long)liteRT.inputHeight, (long)liteRT.inputChannels,
                  (long)liteRT.outputWidth, (long)liteRT.outputHeight, (long)liteRT.outputChannels,
                  _segmentationBackend, setupMs);
            break;
        }
        case VGLiveGreenScreenMaskProviderKindVision: {
            NSLog(@"[VGLiveGreenScreenMaskProviderAdapter] IOS_LIVE_GREENSCREEN_MASK_PROVIDER_VISION_READY provider=VGLiveGreenScreenVisionMaskProvider quality=%@ outputPixelFormat=OneComponent8 segmentationBackend=%@ fastMetalPrecisionRequested=%@(not_applicable) setupMs=%.0f",
                  backend ?: @"unknown", _segmentationBackend,
                  allowPrecisionLoss ? @"true" : @"false", setupMs);
            break;
        }
        case VGLiveGreenScreenMaskProviderKindHeuristicFallback: {
            NSLog(@"[VGLiveGreenScreenMaskProviderAdapter] IOS_LIVE_GREENSCREEN_MASK_PROVIDER_FALLBACK provider=VGHeuristicMaskProvider(face_region_only) reason=%@ segmentationBackend=%@ setupMs=%.0f",
                  fallbackReason ?: @"unknown", _segmentationBackend, setupMs);
            break;
        }
        default: {
            NSLog(@"[VGLiveGreenScreenMaskProviderAdapter] IOS_LIVE_GREENSCREEN_MASK_PROVIDER_UNAVAILABLE reason=%@ segmentationBackend=%@ setupMs=%.0f",
                  fallbackReason ?: @"unknown", _segmentationBackend, setupMs);
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf _isActive]) return;
                void (^cb)(NSDictionary<NSString *, id> *) = strongSelf.onProviderUnavailable;
                if (!cb) return;
                // Snapshot taken while the adapter is still alive: the owner
                // is expected to invalidate it from inside the callback, and
                // this dictionary (providerKind=unavailable, failureReason,
                // segmentationBackend, sampleCount, maskPublishCount, …) is
                // what it caches so the failure reason survives the release.
                cb([strongSelf diagnosticsSnapshot]);
            });
            break;
        }
    }
}

// ─── invalidate (main) ───────────────────────────────────────────────────────

- (void)invalidate {
    NSAssert([NSThread isMainThread], @"VGLiveGreenScreenMaskProviderAdapter.invalidate must run on main");
    [self _invalidateInternal];
}

- (void)_invalidateInternal {
    os_unfair_lock_lock(&_lock);
    if (_invalidated) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _invalidated = YES;
    _active      = NO;

    VGLiteRTMaskProvider                *liteRT    = _liteRT;
    VGLiveGreenScreenVisionMaskProvider *vision    = _vision;
    VGHeuristicMaskProvider             *heuristic = _heuristic;
    _liteRT    = nil;
    _vision    = nil;
    _heuristic = nil;
    _provider  = nil;

    CVPixelBufferRef     cachedBuffer = _cachedBuffer;
    CVPixelBufferPoolRef pool         = _pool;
    _cachedMask   = nil;
    _cachedBuffer = NULL;
    _pool         = NULL;
    _poolW = _poolH = 0;

    // Under the lock so a capture-queue submitFrame can never be mid-call on a
    // provider while it is torn down (heuristic frees scratch on invalidate).
    [liteRT invalidate];
    [vision invalidate];
    [heuristic invalidate];
    os_unfair_lock_unlock(&_lock);

    self.onProviderUnavailable = nil;
    if (cachedBuffer) CVPixelBufferRelease(cachedBuffer);
    if (pool) {
        CVPixelBufferPoolFlush(pool, kCVPixelBufferPoolFlushExcessBuffers);
        CVPixelBufferPoolRelease(pool);
    }
}

// ─── submitFrame (capture queue) ─────────────────────────────────────────────

- (void)submitFrame:(CVPixelBufferRef)pixelBuffer presentationTime:(CMTime)pts {
    if (!pixelBuffer) return;
    os_unfair_lock_lock(&_lock);
    if (!_active || _invalidated || !_provider) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _lastSubmittedPTS = pts;
    // Provider call under the lock: mutually exclusive with invalidate.
    // LiteRT / Vision: retain + dispatch (or pending-slot swap) — returns immediately.
    // Heuristic: async Vision-landmark submit + short synchronous bookkeeping.
    [_provider submitFrame:pixelBuffer pts:pts generation:kVGLiveGSGeneration];
    os_unfair_lock_unlock(&_lock);
}

// ─── latestMaskRetained (render loop snapshot) ───────────────────────────────

- (nullable CVPixelBufferRef)latestMaskRetainedWithMaxAgeSeconds:(NSTimeInterval)maxAgeSeconds {
    return [self latestMaskRetainedWithMaxAgeSeconds:maxAgeSeconds sourcePTSOut:NULL];
}

- (nullable CVPixelBufferRef)latestMaskRetainedWithMaxAgeSeconds:(NSTimeInterval)maxAgeSeconds
                                                    sourcePTSOut:(nullable CMTime *)sourcePTSOut {
    os_unfair_lock_lock(&_lock);
    if (!_active || _invalidated || !_provider) {
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }

    VGSkinMask *mask = _provider.latestMask;   // atomic on every provider
    BOOL valid = (mask != nil &&
                  mask.width  > 0 &&
                  mask.height > 0 &&
                  mask.data   != NULL &&
                  mask.faceCount > 0);
    if (!valid) {
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }

    CFTimeInterval now = CACurrentMediaTime();

    if (mask != _cachedMask) {
        // New matte published since the last copy: copy once into a pooled buffer.
        CVPixelBufferRef fresh = [self _copyMatteToPooledBufferLocked:mask];
        if (fresh) {
            if (_cachedBuffer) CVPixelBufferRelease(_cachedBuffer);
            _cachedBuffer     = fresh;
            _cachedMask       = mask;
            _cachedObservedAt = now;
            // Coverage: one pass over the matte bytes (≤ 1024-side, typically
            // 256×455) — microseconds next to the copy that just ran.
            double coverage = VGLiveGSMatteCoveragePercent(mask);
            [self _recordMaskPublishedWithCoverage:coverage width:mask.width height:mask.height];
            if (!_loggedFirstMask) {
                _loggedFirstMask = YES;
                NSLog(@"[VGLiveGreenScreenMaskProviderAdapter] IOS_LIVE_GREENSCREEN_MASK_FIRST_PUBLISHED provider=%@ size=%zux%zu format=OneComponent8 coverage=%.1f%%",
                      [self _providerKindName], mask.width, mask.height, coverage);
            }
        }
        // Pool exhausted / copy failed: keep serving the previous cache if fresh.
    }

    if (!_cachedBuffer) {
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }

    // Staleness: camera-clock lag when possible, otherwise wall-clock.
    BOOL   stale   = NO;
    CMTime srcPTS  = _cachedMask.sourcePTS;
    CMTime lastPTS = _lastSubmittedPTS;
    if (CMTIME_IS_NUMERIC(srcPTS) && CMTIME_IS_NUMERIC(lastPTS)) {
        double lag = CMTimeGetSeconds(CMTimeSubtract(lastPTS, srcPTS));
        stale = (lag > maxAgeSeconds);
    } else {
        stale = ((now - _cachedObservedAt) > maxAgeSeconds);
    }
    if (stale) {
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }

    CVPixelBufferRef result = _cachedBuffer;
    CVPixelBufferRetain(result);   // +1 for the caller; cache keeps its own
    // Report the matte's source PTS only alongside a returned buffer so the
    // caller can pair it with the camera frame of the same instant.
    if (sourcePTSOut) {
        *sourcePTSOut = _cachedMask.sourcePTS;
    }
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (nullable NSString *)failureReason {
    os_unfair_lock_lock(&_diagLock);
    NSString *reason = _diagFailureReason;
    os_unfair_lock_unlock(&_diagLock);
    return reason;
}

- (NSString *)_providerKindName {
    switch (self.providerKind) {
        case VGLiveGreenScreenMaskProviderKindLiteRT:            return @"litert";
        case VGLiveGreenScreenMaskProviderKindVision:            return @"vision";
        case VGLiveGreenScreenMaskProviderKindHeuristicFallback: return @"heuristic_fallback";
        case VGLiveGreenScreenMaskProviderKindUnavailable:       return @"unavailable";
        default:                                                 return @"pending";
    }
}

// ─── Diagnostics ─────────────────────────────────────────────────────────────

/// Provider serial queue (LiteRT ML queue or Vision queue). Takes only _diagLock.
- (void)_recordTimingSample:(VGLiteRTMaskProviderTimingSample)sample {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&_diagLock);
    if (_diagSampleCount == 0) {
        _diagFirstTotalMs = sample.totalMs;
        _diagMaxTotalMs  = _diagMinTotalMs  = sample.totalMs;
        _diagMaxInferMs  = _diagMinInferMs  = sample.inferMs;
        _diagMaxCopyMs   = _diagMinCopyMs   = sample.inputCopyMs;
        _diagMaxInvokeMs = _diagMinInvokeMs = sample.invokeMs;
        _diagMaxOutMs    = _diagMinOutMs    = sample.outputAccessMs;
        if (_diagStartedAt > 0) {
            _diagFirstPublishLatencyMs = (now - _diagStartedAt) * 1000.0;
        }
    } else {
        if (sample.totalMs        > _diagMaxTotalMs)  _diagMaxTotalMs  = sample.totalMs;
        if (sample.totalMs        < _diagMinTotalMs)  _diagMinTotalMs  = sample.totalMs;
        if (sample.inferMs        > _diagMaxInferMs)  _diagMaxInferMs  = sample.inferMs;
        if (sample.inferMs        < _diagMinInferMs)  _diagMinInferMs  = sample.inferMs;
        if (sample.inputCopyMs    > _diagMaxCopyMs)   _diagMaxCopyMs   = sample.inputCopyMs;
        if (sample.inputCopyMs    < _diagMinCopyMs)   _diagMinCopyMs   = sample.inputCopyMs;
        if (sample.invokeMs       > _diagMaxInvokeMs) _diagMaxInvokeMs = sample.invokeMs;
        if (sample.invokeMs       < _diagMinInvokeMs) _diagMinInvokeMs = sample.invokeMs;
        if (sample.outputAccessMs > _diagMaxOutMs)    _diagMaxOutMs    = sample.outputAccessMs;
        if (sample.outputAccessMs < _diagMinOutMs)    _diagMinOutMs    = sample.outputAccessMs;
    }
    _diagSampleCount++;
    _diagSumTotalMs  += sample.totalMs;
    _diagSumInferMs  += sample.inferMs;
    _diagSumCopyMs   += sample.inputCopyMs;
    _diagSumInvokeMs += sample.invokeMs;
    _diagSumOutMs    += sample.outputAccessMs;
    _diagSumPolicyMs += sample.policyMs;
    _diagSumPreMs    += sample.preMs;
    _diagSumPostMs   += sample.postMs;
    if (sample.cadenceMs > 0) {
        _diagCadenceCount++;
        _diagSumCadenceMs += sample.cadenceMs;
        if (sample.cadenceMs > _diagMaxCadenceMs) _diagMaxCadenceMs = sample.cadenceMs;
    }
    _diagLastTotalMs    = sample.totalMs;
    _diagLastInferMs    = sample.inferMs;
    _diagLastCopyMs     = sample.inputCopyMs;
    _diagLastInvokeMs   = sample.invokeMs;
    _diagLastOutMs      = sample.outputAccessMs;
    _diagLastCadenceMs  = sample.cadenceMs;
    _diagLastPtsSeconds = sample.ptsSeconds;
    _diagLastFrameIndex = sample.frameIndex;
    os_unfair_lock_unlock(&_diagLock);
}

/// Render path; caller holds _lock. Takes _diagLock nested (order _lock → _diagLock).
- (void)_recordMaskPublishedWithCoverage:(double)coverage width:(size_t)w height:(size_t)h {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&_diagLock);
    if (_diagMaskPublishCount == 0 && _diagStartedAt > 0) {
        _diagFirstMaskLatencyMs = (now - _diagStartedAt) * 1000.0;
    }
    _diagMaskPublishCount++;
    _diagLastMaskCoveragePercent = coverage;
    _diagLastMaskW = w;
    _diagLastMaskH = h;
    os_unfair_lock_unlock(&_diagLock);
}

- (NSDictionary<NSString *, id> *)diagnosticsSnapshot {
    NSString *kindName = [self _providerKindName];   // atomic property read
    BOOL active = [self _isActive];                  // _lock, released before _diagLock

    os_unfair_lock_lock(&_diagLock);
    NSUInteger n  = _diagSampleCount;
    NSUInteger nc = _diagCadenceCount;
    double avgTotal   = n  > 0 ? _diagSumTotalMs   / (double)n  : -1.0;
    double avgInfer   = n  > 0 ? _diagSumInferMs   / (double)n  : -1.0;
    double avgCopy    = n  > 0 ? _diagSumCopyMs    / (double)n  : -1.0;
    double avgInvoke  = n  > 0 ? _diagSumInvokeMs  / (double)n  : -1.0;
    double avgOut     = n  > 0 ? _diagSumOutMs     / (double)n  : -1.0;
    double avgPolicy  = n  > 0 ? _diagSumPolicyMs  / (double)n  : -1.0;
    double avgPre     = n  > 0 ? _diagSumPreMs     / (double)n  : -1.0;
    double avgPost    = n  > 0 ? _diagSumPostMs    / (double)n  : -1.0;
    double avgCadence = nc > 0 ? _diagSumCadenceMs / (double)nc : -1.0;
    double maxTotal   = n  > 0 ? _diagMaxTotalMs   : -1.0;
    double minTotal   = n  > 0 ? _diagMinTotalMs   : -1.0;
    double maxInfer   = n  > 0 ? _diagMaxInferMs   : -1.0;
    double minInfer   = n  > 0 ? _diagMinInferMs   : -1.0;
    double maxCopy    = n  > 0 ? _diagMaxCopyMs    : -1.0;
    double minCopy    = n  > 0 ? _diagMinCopyMs    : -1.0;
    double maxInvoke  = n  > 0 ? _diagMaxInvokeMs  : -1.0;
    double minInvoke  = n  > 0 ? _diagMinInvokeMs  : -1.0;
    double maxOut     = n  > 0 ? _diagMaxOutMs     : -1.0;
    double minOut     = n  > 0 ? _diagMinOutMs     : -1.0;
    double maxCadence = nc > 0 ? _diagMaxCadenceMs : -1.0;
    // providerMode: providerKind refined by the attached inference backend
    // (LiteRT: metal_fp32 | metal_fp16 | cpu_simulator, prefixed litert_selfie
    // for the "litertSelfie" backend; Vision: fast | balanced | accurate).
    // timingSemantics: what the span keys measure for the running provider.
    VGLiveGreenScreenMaskProviderKind kind = self.providerKind;
    NSString *providerMode    = kindName;
    NSString *timingSemantics = @"none";
    if (kind == VGLiveGreenScreenMaskProviderKindLiteRT) {
        NSString *prefix = (_backendSelection == VGLiveGSBackendSelectionLiteRTSelfie)
            ? @"litert_selfie" : @"litert";
        providerMode = (_diagInferenceBackend.length > 0)
            ? [NSString stringWithFormat:@"%@_%@", prefix, _diagInferenceBackend]
            : prefix;
        timingSemantics = @"litert_tflite_spans";
    } else if (kind == VGLiveGreenScreenMaskProviderKindVision) {
        if (_diagInferenceBackend.length > 0) {
            providerMode = [NSString stringWithFormat:@"vision_%@", _diagInferenceBackend];
        }
        timingSemantics = @"vision_request_spans";
    }
    NSDictionary<NSString *, id> *snapshot = @{
        @"providerKind":            kindName,
        @"providerMode":            providerMode,
        @"segmentationBackend":     _segmentationBackend,
        @"failureReason":           _diagFailureReason ?: @"none",
        @"timingSemantics":         timingSemantics,
        @"modelName":               _diagModelName ?: @"none",
        @"mattePath":               _diagMattePath ?: @"none",
        @"inputGeometry":           _diagInputGeometry ?: @"none",
        @"modelInputWidth":         @(_diagModelInputW),
        @"modelInputHeight":        @(_diagModelInputH),
        @"modelInputChannels":      @(_diagModelInputC),
        @"modelOutputWidth":        @(_diagModelOutputW),
        @"modelOutputHeight":       @(_diagModelOutputH),
        @"modelOutputChannels":     @(_diagModelOutputC),
        @"fastMetalPrecision":      @(_diagMetalPrecisionLossRequested),
        @"metalAllowPrecisionLossRequested": @(_diagMetalPrecisionLossRequested),
        @"metalAllowPrecisionLoss": @(_diagMetalPrecisionLossApplied),
        @"active":                  @(active),
        @"providerSetupMs":         @(_diagProviderSetupMs),
        @"sampleCount":             @(n),
        @"avgTotalMs":              @(avgTotal),
        @"maxTotalMs":              @(maxTotal),
        @"minTotalMs":              @(minTotal),
        @"avgInferenceMs":          @(avgInfer),
        @"maxInferenceMs":          @(maxInfer),
        @"minInferenceMs":          @(minInfer),
        @"avgInputCopyMs":          @(avgCopy),
        @"maxInputCopyMs":          @(maxCopy),
        @"minInputCopyMs":          @(minCopy),
        @"avgInvokeMs":             @(avgInvoke),
        @"maxInvokeMs":             @(maxInvoke),
        @"minInvokeMs":             @(minInvoke),
        @"avgOutputAccessMs":       @(avgOut),
        @"maxOutputAccessMs":       @(maxOut),
        @"minOutputAccessMs":       @(minOut),
        @"avgPolicyMs":             @(avgPolicy),
        @"avgPreMs":                @(avgPre),
        @"avgPostMs":               @(avgPost),
        @"avgCadenceMs":            @(avgCadence),
        @"maxCadenceMs":            @(maxCadence),
        @"cadenceSampleCount":      @(nc),
        @"firstTotalMs":            @(_diagFirstTotalMs),
        @"lastTotalMs":             @(_diagLastTotalMs),
        @"lastInferenceMs":         @(_diagLastInferMs),
        @"lastInputCopyMs":         @(_diagLastCopyMs),
        @"lastInvokeMs":            @(_diagLastInvokeMs),
        @"lastOutputAccessMs":      @(_diagLastOutMs),
        @"lastCadenceMs":           @(_diagLastCadenceMs),
        @"lastPtsSeconds":          @(_diagLastPtsSeconds),
        @"lastFrameIndex":          @(_diagLastFrameIndex),
        @"firstPublishLatencyMs":   @(_diagFirstPublishLatencyMs),
        @"firstMaskLatencyMs":      @(_diagFirstMaskLatencyMs),
        @"maskPublishCount":        @(_diagMaskPublishCount),
        @"lastMaskCoveragePercent": @(_diagLastMaskCoveragePercent),
        @"lastMaskWidth":           @(_diagLastMaskW),
        @"lastMaskHeight":          @(_diagLastMaskH),
    };
    os_unfair_lock_unlock(&_diagLock);
    return snapshot;
}

// ─── Pooled matte buffer (caller holds _lock) ────────────────────────────────

- (BOOL)_ensurePoolLockedForWidth:(size_t)w height:(size_t)h {
    if (_pool && _poolW == w && _poolH == h) return YES;
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
        _poolW = _poolH = 0;
    }
    NSDictionary *poolAttrs = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey: @(2) };
    NSDictionary *ioSurfaceAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:  @(kCVPixelFormatType_OneComponent8),
        (id)kCVPixelBufferWidthKey:            @(w),
        (id)kCVPixelBufferHeightKey:           @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn r = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                         (__bridge CFDictionaryRef)poolAttrs,
                                         (__bridge CFDictionaryRef)ioSurfaceAttrs,
                                         &_pool);
    if (r != kCVReturnSuccess || !_pool) {
        // Retry without IOSurface backing (CoreImage still accepts plain buffers).
        _pool = NULL;
        NSDictionary *plainAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_OneComponent8),
            (id)kCVPixelBufferWidthKey:           @(w),
            (id)kCVPixelBufferHeightKey:          @(h),
        };
        r = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    (__bridge CFDictionaryRef)poolAttrs,
                                    (__bridge CFDictionaryRef)plainAttrs,
                                    &_pool);
        if (r != kCVReturnSuccess || !_pool) {
            _pool = NULL;
            NSLog(@"[VGLiveGreenScreenMaskProviderAdapter] matte pool creation failed (%d) for %zux%zu", (int)r, w, h);
            return NO;
        }
    }
    _poolW = w;
    _poolH = h;
    return YES;
}

/// Returns a +1 OneComponent8 buffer holding a copy of the matte bytes, or NULL.
- (nullable CVPixelBufferRef)_copyMatteToPooledBufferLocked:(VGSkinMask *)mask {
    size_t w = mask.width, h = mask.height;
    if (![self _ensurePoolLockedForWidth:w height:h]) return NULL;

    NSDictionary *aux = @{ (id)kCVPixelBufferPoolAllocationThresholdKey: @(kVGLiveGSMaxPooledMatteBuffers) };
    CVPixelBufferRef buf = NULL;
    CVReturn r = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _pool,
                                                                     (__bridge CFDictionaryRef)aux, &buf);
    if (r != kCVReturnSuccess || !buf) return NULL;

    if (CVPixelBufferLockBaseAddress(buf, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(buf);
        return NULL;
    }
    uint8_t       *dst    = (uint8_t *)CVPixelBufferGetBaseAddress(buf);
    size_t         dstBPR = CVPixelBufferGetBytesPerRow(buf);
    const uint8_t *src    = mask.data;
    size_t         srcBPR = mask.bytesPerRow > 0 ? mask.bytesPerRow : w;
    if (!dst) {
        CVPixelBufferUnlockBaseAddress(buf, 0);
        CVPixelBufferRelease(buf);
        return NULL;
    }
    if (dstBPR == srcBPR) {
        memcpy(dst, src, srcBPR * h);
    } else {
        for (size_t y = 0; y < h; y++) {
            memcpy(dst + y * dstBPR, src + y * srcBPR, w);
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, 0);
    return buf;
}

@end
