// VGFaceNeckBeautyMaskPolicy.m
// Phase 9B-1 — Deterministic post-processing policy.
//
// Algorithm:
//   1. Confidence competition across the 6 MediaPipe Selfie Multiclass classes.
//   2. Face bounding box derived from class-3 (face-skin) pixels above threshold.
//   3. Neck ROI rectangle projected downward from face box.
//   4. Eligible skin = competition result ∩ (face box ∪ neck ROI).
//   5. Per-column forehead trim (fraction of faceHeight from topmost face pixel).
//   6. Gated forehead expansion upward (blocked by high hair/clothes confidence).
//   7. Morphological open then close (simple 2-pass box erosion/dilation, CPU).
//   8. Motion-adaptive temporal EMA on a float[256*256] history buffer.
//   9. Threshold final float buffer at ≥ 0.5 → uint8 (0 or 255).
//  10. Downscale binary mask to quarter-resolution for VGSkinMask output.
//
// Tensor input constants (selfie_multiclass_256x256.tflite):
//   kModelW = 256, kModelH = 256, kModelC = 6
//   Class indices: 0=background 1=hair 2=body-skin 3=face-skin 4=clothes 5=others

#import "VGFaceNeckBeautyMaskPolicy.h"
#import "VGSkinMaskGenerator.h"   // VGSkinMask definition
#import <os/log.h>

// ─── Private VGSkinMask category ────────────────────────────────────────────
// VGSkinMask._initWithData:width:height:sourcePTS:faceCount: is a file-private
// designated initializer in VGSkinMaskGenerator.m.  Because VGFaceNeckBeautyMaskPolicy
// must also create VGSkinMask instances (not via the generator), we forward-declare
// the private initializer here using an Objective-C category so ARC can call it
// without requiring any modification to VGSkinMaskGenerator.
// The method MUST match the implementation in VGSkinMaskGenerator.m exactly.

@interface VGSkinMask (VGMLPolicyCreation)
- (instancetype)_initWithData:(NSData *)data
                        width:(size_t)width
                       height:(size_t)height
                    sourcePTS:(CMTime)pts
                    faceCount:(NSInteger)faceCount;
@end

// ─── Model tensor constants ──────────────────────────────────────────────────
static const size_t kModelW = 256;
static const size_t kModelH = 256;
static const size_t kModelC = 6;
static const size_t kModelPixels = kModelW * kModelH; // 65 536

// Class channel offsets within a pixel (layout: [H][W][C])
// kClassBackground (0) is implicit — skin must beat all others above threshold.
static const int kClassHair        = 1;
static const int kClassBodySkin    = 2;
static const int kClassFaceSkin    = 3;
static const int kClassClothes     = 4;
static const int kClassOthers      = 5;

static os_log_t VGPolicyLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.vanguard", "VGFaceNeckBeautyMaskPolicy"); });
    return log;
}

// ── Phase 9B-6A: diagnostic throttle interval ───────────────────────────────
// Log once every kVGPolicyDiagLogInterval processed frames (~1s at 30fps).
static const NSUInteger kVGPolicyDiagLogInterval = 30;

// ─── Inline helpers ─────────────────────────────────────────────────────────

static inline float _clamp01(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

static inline float _confidence(const float *tensor, int y, int x, int c) {
    // tensor layout: [H][W][C], H=W=256, C=6
    return tensor[(y * (int)kModelW + x) * (int)kModelC + c];
}

// ─── Separable box blur (feather/soft-edge helper) ───────────────────────────
//
// Converts a hard binary uint8 mask (0 or 255) into a soft-edge float mask
// by applying a 1D box blur horizontally then vertically. The result is a
// float buffer in [0, 1] at the same resolution. Used between step 9 (binary
// threshold) and step 10 (downscale) to produce a smooth 0–255 feather ramp
// instead of a hard staircase boundary.
//
// radius: box half-width in pixels (kernel size = 2*radius+1).
// outFloat: caller-allocated float buffer of size w*h.
static void _boxBlurToFloat(const uint8_t *src, float *outFloat,
                             size_t w, size_t h, int radius) {
    if (radius <= 0) {
        for (size_t i = 0; i < w * h; i++) {
            outFloat[i] = src[i] / 255.0f;
        }
        return;
    }
    // Horizontal pass: src (uint8) → tmp (float)
    float *tmp = (float *)malloc(w * h * sizeof(float));
    if (!tmp) {
        for (size_t i = 0; i < w * h; i++) outFloat[i] = src[i] / 255.0f;
        return;
    }
    float kernelW = (float)(2 * radius + 1);
    for (int y = 0; y < (int)h; y++) {
        // Sliding-window accumulation.
        float acc = 0.0f;
        // Initialise window for x=-radius..0 (clamped at left edge).
        for (int k = -radius; k <= radius; k++) {
            int kx = k < 0 ? 0 : k;
            acc += src[y * w + (size_t)kx] / 255.0f;
        }
        for (int x = 0; x < (int)w; x++) {
            tmp[y * w + x] = acc / kernelW;
            // Slide: remove left, add right.
            int removeX = x - radius;     if (removeX < 0)       removeX = 0;
            int addX    = x + radius + 1; if (addX >= (int)w)    addX    = (int)w - 1;
            acc -= src[y * w + removeX] / 255.0f;
            acc += src[y * w + addX]    / 255.0f;
        }
    }
    // Vertical pass: tmp (float) → outFloat (float)
    for (int x = 0; x < (int)w; x++) {
        float acc = 0.0f;
        for (int k = -radius; k <= radius; k++) {
            int ky = k < 0 ? 0 : k;
            acc += tmp[(size_t)ky * w + x];
        }
        for (int y = 0; y < (int)h; y++) {
            outFloat[y * w + x] = acc / kernelW;
            int removeY = y - radius;     if (removeY < 0)       removeY = 0;
            int addY    = y + radius + 1; if (addY >= (int)h)    addY    = (int)h - 1;
            acc -= tmp[removeY * w + x];
            acc += tmp[addY    * w + x];
        }
    }
    free(tmp);
}

// ─── Morphological helpers (box kernel, square neighbourhood) ───────────────

/// In-place binary erosion of a uint8 mask (value 1 = foreground, 0 = background).
/// radius = (kernelSize - 1) / 2.
static void _morphErode(uint8_t *buf, size_t w, size_t h, int radius) {
    if (radius <= 0) return;
    uint8_t *tmp = (uint8_t *)malloc(w * h);
    if (!tmp) return;
    for (int y = 0; y < (int)h; y++) {
        for (int x = 0; x < (int)w; x++) {
            uint8_t minVal = 1;
            for (int ky = y - radius; ky <= y + radius && minVal; ky++) {
                if (ky < 0 || ky >= (int)h) { minVal = 0; break; }
                for (int kx = x - radius; kx <= x + radius; kx++) {
                    if (kx < 0 || kx >= (int)w) { minVal = 0; break; }
                    if (!buf[ky * w + kx]) { minVal = 0; break; }
                }
            }
            tmp[y * w + x] = minVal;
        }
    }
    memcpy(buf, tmp, w * h);
    free(tmp);
}

/// In-place binary dilation of a uint8 mask.
static void _morphDilate(uint8_t *buf, size_t w, size_t h, int radius) {
    if (radius <= 0) return;
    uint8_t *tmp = (uint8_t *)calloc(w * h, 1);
    if (!tmp) return;
    for (int y = 0; y < (int)h; y++) {
        for (int x = 0; x < (int)w; x++) {
            if (!buf[y * w + x]) continue;
            // Dilate: set neighbourhood to 1.
            int y0 = y - radius < 0 ? 0 : y - radius;
            int y1 = y + radius >= (int)h ? (int)h - 1 : y + radius;
            int x0 = x - radius < 0 ? 0 : x - radius;
            int x1 = x + radius >= (int)w ? (int)w - 1 : x + radius;
            for (int ky = y0; ky <= y1; ky++)
                for (int kx = x0; kx <= x1; kx++)
                    tmp[ky * w + kx] = 1;
        }
    }
    memcpy(buf, tmp, w * h);
    free(tmp);
}

/// Morphological open (erode then dilate) — removes small noise blobs.
static void _morphOpen(uint8_t *buf, size_t w, size_t h, int radius) {
    _morphErode(buf, w, h, radius);
    _morphDilate(buf, w, h, radius);
}

/// Morphological close (dilate then erode) — fills small holes.
static void _morphClose(uint8_t *buf, size_t w, size_t h, int radius) {
    _morphDilate(buf, w, h, radius);
    _morphErode(buf, w, h, radius);
}

// ─── Implementation ─────────────────────────────────────────────────────────

@implementation VGFaceNeckBeautyMaskPolicy {
    // Temporal EMA — float history buffer at model resolution (256×256).
    // Stores the blended mask probability for each pixel.
    float   *_historyBuffer;   // length = kModelPixels
    BOOL     _hasHistory;      // NO until first frame

    // ── Phase 9B-6A: diagnostic stats frame counter ──────────────────────
    // Throttle to one stats tally every kVGPolicyDiagLogInterval calls.
    NSUInteger _diagStatsFrameCount;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // Phase 9B-1 defaults (match prototype FaceNeckBeautyMaskPolicy.py).
    _skinThreshold  = 0.60f;
    _hairMargin     = 0.10f;
    _clothMargin    = 0.05f;
    _neckDepth      = 0.40f;
    _neckWidth      = 0.65f;
    // Phase 9B-6C: reduce forehead trim from 0.10 to 0.0.
    // Root cause: trim was the primary direct cause of the forehead gap.
    // The existing gated forehead expansion (step 6) guards against hair-spill
    // independently. Setting trim to 0 allows the full detected face-skin
    // region to reach its natural top boundary.
    _foreheadTrim   = 0.0f;
    // Phase 9B-6C: increase forehead expand from 4 to 8.
    // More recovery pixels above the detected face bbox top, for cases where
    // face-skin confidence drops below threshold near the hairline but the
    // region is still genuine forehead (not hair). Still gated by
    // hair/clothes/others >= skinThreshold.
    _foreheadExpand = 8;
    _morphKernelSize = 3;
    _temporalAlpha  = 0.60f;

    _historyBuffer = (float *)calloc(kModelPixels, sizeof(float));
    _hasHistory    = NO;

    return self;
}

- (void)dealloc {
    free(_historyBuffer);
}

- (void)resetTemporalState {
    if (_historyBuffer) {
        memset(_historyBuffer, 0, kModelPixels * sizeof(float));
    }
    _hasHistory = NO;
}

// ─── Main processing entry point ─────────────────────────────────────────────

- (VGSkinMask *)processTensor:(const float *)outputTensor
                  sourceWidth:(size_t)sourceWidth
                 sourceHeight:(size_t)sourceHeight
                          pts:(CMTime)pts
              generationReset:(BOOL)generationReset {

    if (generationReset) {
        [self resetTemporalState];
    }

    // ── 1. Confidence competition → binary candidate mask (1=eligible, 0=not) ──
    //
    // skin = max(face_skin, body_skin)
    // include if:
    //   skin >= skinThreshold
    //   skin > hair + hairMargin
    //   skin > clothes + clothMargin
    //   skin > others + clothMargin

    uint8_t *candidateMask = (uint8_t *)calloc(kModelPixels, 1);
    if (!candidateMask) return [self _emptyMaskForPTS:pts sourceWidth:sourceWidth sourceHeight:sourceHeight];

    float thr    = _skinThreshold;
    float hairMg = _hairMargin;
    float clMg   = _clothMargin;

    // Also track face-skin confidence to derive face bounding box.
    // We need the raw face-skin confidence per pixel for step 2.

    // Find face bounding box from face-skin class (class 3).
    int faceMinY = (int)kModelH, faceMaxY = -1;
    int faceMinX = (int)kModelW, faceMaxX = -1;

    for (int y = 0; y < (int)kModelH; y++) {
        for (int x = 0; x < (int)kModelW; x++) {
            float faceSkin  = _confidence(outputTensor, y, x, kClassFaceSkin);
            float bodySkin  = _confidence(outputTensor, y, x, kClassBodySkin);
            float hair      = _confidence(outputTensor, y, x, kClassHair);
            float clothes   = _confidence(outputTensor, y, x, kClassClothes);
            float others    = _confidence(outputTensor, y, x, kClassOthers);
            float skin      = faceSkin > bodySkin ? faceSkin : bodySkin;

            BOOL passes = (skin >= thr)
                       && (skin > hair + hairMg)
                       && (skin > clothes + clMg)
                       && (skin > others + clMg);

            candidateMask[y * kModelW + x] = passes ? 1 : 0;

            // Track face bounding box using face-skin class only.
            if (faceSkin >= thr) {
                if (y < faceMinY) faceMinY = y;
                if (y > faceMaxY) faceMaxY = y;
                if (x < faceMinX) faceMinX = x;
                if (x > faceMaxX) faceMaxX = x;
            }
        }
    }

    // ── 2. No face detected → return empty mask ──────────────────────────────
    if (faceMaxY < faceMinY || faceMaxX < faceMinX) {
        free(candidateMask);
        return [self _emptyMaskForPTS:pts sourceWidth:sourceWidth sourceHeight:sourceHeight];
    }

    int faceW = faceMaxX - faceMinX + 1;
    int faceH = faceMaxY - faceMinY + 1;

    // ── 3. Neck ROI ──────────────────────────────────────────────────────────
    //
    // Width  = neckWidth  * faceW   (centred on face)
    // Height = neckDepth  * faceH   (extends downward from faceMaxY)
    int neckW = (int)(_neckWidth  * (float)faceW + 0.5f);
    int neckH = (int)(_neckDepth  * (float)faceH + 0.5f);
    int neckMidX = faceMinX + faceW / 2;
    int neckX0 = neckMidX - neckW / 2;
    int neckX1 = neckMidX + neckW / 2;
    int neckY0 = faceMaxY + 1;
    int neckY1 = faceMaxY + neckH;

    // Clamp to 256×256.
    if (neckX0 < 0)              neckX0 = 0;
    if (neckX1 >= (int)kModelW)  neckX1 = (int)kModelW - 1;
    if (neckY0 < 0)              neckY0 = 0;
    if (neckY1 >= (int)kModelH)  neckY1 = (int)kModelH - 1;

    // ── 4. Restrict candidate to face box ∪ neck ROI ─────────────────────────
    uint8_t *roiMask = (uint8_t *)calloc(kModelPixels, 1);
    if (!roiMask) { free(candidateMask); return [self _emptyMaskForPTS:pts sourceWidth:sourceWidth sourceHeight:sourceHeight]; }

    for (int y = 0; y < (int)kModelH; y++) {
        for (int x = 0; x < (int)kModelW; x++) {
            if (!candidateMask[y * kModelW + x]) continue;

            BOOL inFace = (y >= faceMinY && y <= faceMaxY && x >= faceMinX && x <= faceMaxX);
            BOOL inNeck = (y >= neckY0   && y <= neckY1   && x >= neckX0   && x <= neckX1);

            if (inFace || inNeck) {
                roiMask[y * kModelW + x] = 1;
            }
        }
    }
    free(candidateMask);

    // ── Phase 9B-6A: class coverage stats (on diagnostic frames only) ──────────
    //
    // Only computed on throttled frames — not every frame — to avoid distorting
    // normal provider timing. The argmax loop runs once here, before any ROI
    // masking, and never mutates candidateMask, roiMask, EMA, or output.
    _diagStatsFrameCount++;
    // Log on first 3 frames for immediate physical smoke visibility,
    // then every kVGPolicyDiagLogInterval frames thereafter.
    BOOL shouldLogStats = (_diagStatsFrameCount <= 3) || (_diagStatsFrameCount % kVGPolicyDiagLogInterval == 1);

    if (_diagStatsFrameCount == 1) {
        os_log_info(VGPolicyLog(),
            "[VGFaceNeckBeautyMaskPolicy diagnostic] processTensor reached frame=1 "
            "throttleInterval=%lu firstLogFrames=3 threshold=%.2f",
            (unsigned long)kVGPolicyDiagLogInterval, _skinThreshold);
    }

    if (shouldLogStats && faceMaxY >= faceMinY && faceMaxX >= faceMinX) {
        // Argmax tally: count pixels where each class has the highest confidence.
        size_t countBG = 0, countHair = 0, countBody = 0;
        size_t countFace = 0, countClothes = 0, countOthers = 0;

        // Phase 9B-6C: also tally top-face band (forehead region) separately.
        // Top band = top 25% of the detected face bbox rows.
        int topBandEndY = faceMinY + faceH / 4;
        size_t topBandFace = 0, topBandHair = 0, topBandBG = 0, topBandOther = 0;

        for (int y = 0; y < (int)kModelH; y++) {
            for (int x = 0; x < (int)kModelW; x++) {
                // Find the class with maximum confidence at this pixel.
                float maxConf = -1.0f;
                int   maxCls  = 0;
                for (int c = 0; c < (int)kModelC; c++) {
                    float v = _confidence(outputTensor, y, x, c);
                    if (v > maxConf) { maxConf = v; maxCls = c; }
                }
                switch (maxCls) {
                    case 0: countBG++;      break;
                    case 1: countHair++;    break;
                    case 2: countBody++;    break;
                    case 3: countFace++;    break;
                    case 4: countClothes++; break;
                    case 5: countOthers++;  break;
                }
                // Top-band tally (forehead zone only).
                if (y >= faceMinY && y <= topBandEndY && x >= faceMinX && x <= faceMaxX) {
                    if (maxCls == 3 || maxCls == 2)      topBandFace++;
                    else if (maxCls == 1)                 topBandHair++;
                    else if (maxCls == 0)                 topBandBG++;
                    else                                  topBandOther++;
                }
            }
        }
        os_log_info(VGPolicyLog(),
            "[VGFaceNeckBeautyMaskPolicy diagnostic] "
            "bg=%.1f%% hair=%.1f%% bodySkin=%.1f%% faceSkin=%.1f%% "
            "clothes=%.1f%% other=%.1f%% frame=%lu",
            countBG     * 100.0 / kModelPixels,
            countHair   * 100.0 / kModelPixels,
            countBody   * 100.0 / kModelPixels,
            countFace   * 100.0 / kModelPixels,
            countClothes* 100.0 / kModelPixels,
            countOthers * 100.0 / kModelPixels,
            (unsigned long)_diagStatsFrameCount);
        // Phase 9B-6C: top-face band diagnostic.
        size_t topBandTotal = topBandFace + topBandHair + topBandBG + topBandOther;
        if (topBandTotal > 0) {
            os_log_info(VGPolicyLog(),
                "[VGFaceNeckBeautyMaskPolicy diagnostic] "
                "topFaceBand(face/hair/bg/other)=%.0f%%/%.0f%%/%.0f%%/%.0f%% "
                "faceBox=(%d,%d)-(%d,%d) frame=%lu",
                topBandFace  * 100.0 / topBandTotal,
                topBandHair  * 100.0 / topBandTotal,
                topBandBG    * 100.0 / topBandTotal,
                topBandOther * 100.0 / topBandTotal,
                faceMinX, faceMinY, faceMaxX, faceMaxY,
                (unsigned long)_diagStatsFrameCount);
        }
    }
    // ── No-face diagnostic: log when a diagnostic frame finds no face pixels ──
    if (shouldLogStats && (faceMaxY < faceMinY || faceMaxX < faceMinX)) {
        os_log_info(VGPolicyLog(),
            "[VGFaceNeckBeautyMaskPolicy diagnostic] no face pixels detected above "
            "threshold=%.2f frame=%lu — empty mask will be returned",
            _skinThreshold, (unsigned long)_diagStatsFrameCount);
    }

    // ── 5. Forehead trim ─────────────────────────────────────────────────────
    //
    // For each column x within [faceMinX, faceMaxX], find the topmost ROI
    // pixel and trim foreheadTrim * faceH pixels downward from it.
    int trimRows = (int)(_foreheadTrim * (float)faceH + 0.5f);
    if (trimRows < 0) trimRows = 0;

    if (trimRows > 0) {
        for (int x = faceMinX; x <= faceMaxX; x++) {
            // Find topmost ROI pixel in this column within the face box rows.
            int topY = -1;
            for (int y = faceMinY; y <= faceMaxY; y++) {
                if (roiMask[y * kModelW + x]) { topY = y; break; }
            }
            if (topY < 0) continue;

            int trimEnd = topY + trimRows - 1;
            if (trimEnd > faceMaxY) trimEnd = faceMaxY;
            for (int y = topY; y <= trimEnd; y++) {
                roiMask[y * kModelW + x] = 0;
            }
        }
    }

    // ── 6. Gated forehead expansion ──────────────────────────────────────────
    //
    // After trim, expand upward by foreheadExpand pixels per column — but only
    // if hair/clothes/others confidence is low (below skinThreshold).
    // This recovers legitimate forehead skin trimmed by step 5.
    if (_foreheadExpand > 0) {
        for (int x = faceMinX; x <= faceMaxX; x++) {
            // Find the new topmost ROI pixel in column after trim.
            int topY = -1;
            for (int y = faceMinY; y <= faceMaxY; y++) {
                if (roiMask[y * kModelW + x]) { topY = y; break; }
            }
            if (topY < 0) continue;

            // Expand upward from (topY - 1).
            for (int step = 1; step <= (int)_foreheadExpand; step++) {
                int ey = topY - step;
                if (ey < 0) break;

                float hair    = _confidence(outputTensor, ey, x, kClassHair);
                float clothes = _confidence(outputTensor, ey, x, kClassClothes);
                float others  = _confidence(outputTensor, ey, x, kClassOthers);

                // Gate: stop expansion if any blocking class is too confident.
                if (hair >= _skinThreshold || clothes >= _skinThreshold || others >= _skinThreshold) break;

                roiMask[ey * kModelW + x] = 1;
            }
        }
    }

    // ── 7. Morphological cleanup ─────────────────────────────────────────────
    //
    // Open (erode→dilate): removes isolated noise pixels.
    // Close (dilate→erode): fills small interior holes.
    int kernelRadius = (int)(_morphKernelSize - 1) / 2;
    if (kernelRadius > 0) {
        _morphOpen(roiMask, kModelW, kModelH, kernelRadius);
        _morphClose(roiMask, kModelW, kModelH, kernelRadius);
    }

    // ── 8. Temporal EMA ──────────────────────────────────────────────────────
    //
    // Motion = fraction of pixels that changed between current binary mask and
    //          the thresholded history (|current - (history >= 0.5)|).
    // alphaEff = temporalAlpha * max(0, 1 - motion / 0.08)
    //
    // First frame (no history): seed directly, alpha irrelevant.

    if (!_hasHistory || !_historyBuffer) {
        // Seed history with the current binary mask.
        for (size_t i = 0; i < kModelPixels; i++) {
            _historyBuffer[i] = roiMask[i] ? 1.0f : 0.0f;
        }
        _hasHistory = YES;
    } else {
        // Compute motion: changed-pixel fraction.
        size_t changed = 0;
        for (size_t i = 0; i < kModelPixels; i++) {
            uint8_t prevBin = (_historyBuffer[i] >= 0.5f) ? 1 : 0;
            if (roiMask[i] != prevBin) changed++;
        }
        float motion = (float)changed / (float)kModelPixels;

        // Motion-adaptive alpha: high motion → lower alpha (less smoothing lag).
        // alphaEff = temporalAlpha * max(0, 1 - motion / 0.08)
        float motionFactor = 1.0f - motion / 0.08f;
        if (motionFactor < 0.0f) motionFactor = 0.0f;
        float alphaEff = _clamp01(_temporalAlpha * motionFactor);

        // EMA blend: history = alphaEff * history + (1 - alphaEff) * current.
        for (size_t i = 0; i < kModelPixels; i++) {
            float cur = roiMask[i] ? 1.0f : 0.0f;
            _historyBuffer[i] = alphaEff * _historyBuffer[i] + (1.0f - alphaEff) * cur;
        }
    }
    free(roiMask);

    // ── 9. Threshold history → binary uint8 at model resolution ─────────────
    //
    // Pixel is foreground if history >= 0.5 → value 255.
    uint8_t *modelMask = (uint8_t *)malloc(kModelPixels);
    if (!modelMask) return [self _emptyMaskForPTS:pts sourceWidth:sourceWidth sourceHeight:sourceHeight];

    for (size_t i = 0; i < kModelPixels; i++) {
        modelMask[i] = (_historyBuffer[i] >= 0.5f) ? 255 : 0;
    }

    // ── 9B. Soft-edge feathering (Phase 9B-6C) ──────────────────────────────
    //
    // Apply a separable box blur to the binary modelMask to produce a soft
    // 0–255 feather ramp at boundaries. This eliminates the hard staircase
    // edge that was making the mask boundary jagged/polygonal when BeautyV2
    // sampled it at render resolution.
    //
    // Blur radius 3 at 256×256 → ~3-pixel wide gradient at model resolution
    // (~12px at full 1080p render resolution). Wide enough to smooth, narrow
    // enough not to bleed significantly into hair/background.
    //
    // The blurred float values replace the binary modelMask bytes for downscale.
    static const int kFeatherRadius = 3;
    float *featherBuf = (float *)malloc(kModelPixels * sizeof(float));
    if (featherBuf) {
        _boxBlurToFloat(modelMask, featherBuf, kModelW, kModelH, kFeatherRadius);
        // Inward-only masked feather: only apply soft values where the original
        // binary mask was foreground (non-zero). Background pixels stay exactly 0
        // — no outward bleed into hair, clothes, or background regions.
        // The interior boundary pixels receive the blur-attenuated value
        // (e.g. ~145 at the outermost foreground row), creating a smooth
        // 0→145→255 gradient inside the face region that BeautyV2 blends
        // bilinearly at render resolution, eliminating the staircase edge.
        for (size_t i = 0; i < kModelPixels; i++) {
            if (modelMask[i] != 0) {
                float v = featherBuf[i];
                if (v < 0.0f) v = 0.0f;
                if (v > 1.0f) v = 1.0f;
                modelMask[i] = (uint8_t)(v * 255.0f + 0.5f);
            }
            // else: background stays 0 — no outward bleed
        }
        free(featherBuf);
    }
    // (If allocation fails, modelMask retains hard binary 0/255 — safe fallback.)

    // ── 10. Downscale to quarter-resolution ──────────────────────────────────
    //
    // Output mask dimensions match existing pipeline expectation:
    //   qw = sourceWidth / 4, qh = sourceHeight / 4.
    // Model operates at 256×256.  To produce the quarter-res mask we:
    //   - Compute the scale from 256×256 to sourceW/4 × sourceH/4.
    //   - Use nearest-neighbour mapping from model space to output space.
    // If sourceWidth == 0 or sourceHeight == 0, fall back to 64×64.

    size_t qw = sourceWidth  > 0 ? sourceWidth  / 4 : 64;
    size_t qh = sourceHeight > 0 ? sourceHeight / 4 : 64;
    if (qw < 1) qw = 1;
    if (qh < 1) qh = 1;

    size_t outPixels = qw * qh;
    uint8_t *outBuf = (uint8_t *)calloc(outPixels, 1);
    if (!outBuf) { free(modelMask); return [self _emptyMaskForPTS:pts sourceWidth:sourceWidth sourceHeight:sourceHeight]; }

    for (size_t oy = 0; oy < qh; oy++) {
        for (size_t ox = 0; ox < qw; ox++) {
            // Map from output pixel (ox, oy) to model pixel (my, mx).
            size_t my = (oy * kModelH + kModelH / 2) / qh;  // round to nearest
            size_t mx = (ox * kModelW + kModelW / 2) / qw;
            if (my >= kModelH) my = kModelH - 1;
            if (mx >= kModelW) mx = kModelW - 1;
            outBuf[oy * qw + ox] = modelMask[my * kModelW + mx];
        }
    }
    free(modelMask);

    // ── 11. Build and return VGSkinMask ──────────────────────────────────────
    NSData *maskData = [NSData dataWithBytesNoCopy:outBuf length:outPixels freeWhenDone:YES];
    VGSkinMask *mask = [[VGSkinMask alloc] _initWithData:maskData
                                                   width:qw
                                                  height:qh
                                               sourcePTS:pts
                                               faceCount:1];

    // ── Phase 9B-6A: final derived mask coverage stat (on same throttled frames) ──
    if (shouldLogStats) {
        size_t nonZero = 0;
        const uint8_t *finalBytes = mask.data;
        if (finalBytes) {
            for (size_t i = 0; i < outPixels; i++) {
                if (finalBytes[i] > 0) nonZero++;
            }
        }
        os_log_info(VGPolicyLog(),
            "[VGFaceNeckBeautyMaskPolicy diagnostic] "
            "finalMask=%.1f%% (%zu/%zu px at %zux%zu) frame=%lu",
            outPixels > 0 ? nonZero * 100.0 / outPixels : 0.0,
            nonZero, outPixels, qw, qh, (unsigned long)_diagStatsFrameCount);
    }

    return mask;
}

// ─── Private ─────────────────────────────────────────────────────────────────

/// Builds an empty (all-zero) VGSkinMask at quarter-resolution.
- (VGSkinMask *)_emptyMaskForPTS:(CMTime)pts
                      sourceWidth:(size_t)sourceWidth
                     sourceHeight:(size_t)sourceHeight {
    size_t qw = sourceWidth  > 0 ? sourceWidth  / 4 : 64;
    size_t qh = sourceHeight > 0 ? sourceHeight / 4 : 64;
    if (qw < 1) qw = 1;
    if (qh < 1) qh = 1;

    size_t outPixels = qw * qh;
    NSData *emptyData = [NSData dataWithBytesNoCopy:calloc(outPixels, 1)
                                             length:outPixels
                                       freeWhenDone:YES];
    return [[VGSkinMask alloc] _initWithData:emptyData
                                       width:qw
                                      height:qh
                                   sourcePTS:pts
                                   faceCount:0];
}

@end
