// VGLiteRTMaskProvider.m
// Phase 9B-2 — TFLite/LiteRT-backed VGMaskProvider conformer.
//
// TFLite C API used (from TensorFlowLiteC.xcframework):
//   TfLiteModelCreateFromFile   — load model from filesystem path
//   TfLiteInterpreterOptionsCreate/Delete
//   TfLiteInterpreterOptionsSetNumThreads
//   TfLiteInterpreterOptionsAddDelegate — used with Metal delegate
//   TfLiteInterpreterCreate/Delete
//   TfLiteInterpreterAllocateTensors
//   TfLiteInterpreterGetInputTensor / GetOutputTensor
//   TfLiteTensorType / TfLiteTensorNumDims / TfLiteTensorDim
//   TfLiteTensorCopyFromBuffer
//   TfLiteInterpreterInvoke
//   TfLiteTensorData
//   TfLiteModelDelete
//
// Metal delegate API (from TensorFlowLiteCMetal.xcframework):
//   TFLGpuDelegateOptionsDefault
//   TFLGpuDelegateCreate / TFLGpuDelegateDelete
//
// Threading:
//   _mlQueue: private serial queue — all TFLite + policy calls serialized here.
//   _invalidated: atomic BOOL — safe cross-queue read.
//   latestMask: assigned via atomic property.
//
// Frame preprocessing:
//   Accepts kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, and
//   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange / FullRange (NV12/NV21).
//   Output: float RGB [0,1] at 256×256 (strided nearest-neighbour).
//   No Metal shaders — deterministic CPU path for this slice.

#import "VGLiteRTMaskProvider.h"
#import "VGFaceNeckBeautyMaskPolicy.h"
#import "VGSkinMaskGenerator.h"   // VGSkinMask definition

// TFLite C API.
#import <TensorFlowLiteC/TensorFlowLiteC.h>

// Metal GPU delegate (weak-linked — only available on device, not sim).
// We use a runtime dlopen/dlsym approach to avoid hard-linking the Metal
// delegate on simulator builds where Metal is unavailable.
// Instead: just import the header and guard creation with TARGET_OS_SIMULATOR.
#if !TARGET_OS_SIMULATOR
#import <TensorFlowLiteCMetal/TensorFlowLiteCMetal.h>
#endif

#import <Accelerate/Accelerate.h>
#import <os/log.h>

// ─── Constants ────────────────────────────────────────────────────────────────

static const int kInputH  = 256;
static const int kInputW  = 256;
static const int kInputC  = 3;   // RGB
static const int kOutputC = 6;   // MediaPipe Selfie Multiclass classes

static const size_t kInputFloats  = (size_t)(kInputH * kInputW * kInputC);
// kOutputFloats = 256*256*6 — not needed; output is read via TfLiteTensorData pointer.

static os_log_t VGLiteRTLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.vanguard", "VGLiteRTMaskProvider"); });
    return log;
}

// ─── VGSkinMask private category (same pattern as VGFaceNeckBeautyMaskPolicy) ─

@interface VGSkinMask (VGLiteRTProviderCreation)
- (instancetype)_initWithData:(NSData *)data
                        width:(size_t)width
                       height:(size_t)height
                    sourcePTS:(CMTime)pts
                    faceCount:(NSInteger)faceCount;
@end

// ─── Implementation ──────────────────────────────────────────────────────────

@implementation VGLiteRTMaskProvider {
    // ── TFLite C objects (accessed only on _mlQueue) ─────────────────────────
    TfLiteModel       *_tflModel;
    TfLiteInterpreter *_tflInterpreter;
#if !TARGET_OS_SIMULATOR
    TfLiteDelegate    *_metalDelegate;
#endif

    // ── Policy (serialized by _mlQueue — not thread-safe on its own) ─────────
    VGFaceNeckBeautyMaskPolicy *_policy;

    // ── Fallback provider ─────────────────────────────────────────────────────
    id<VGMaskProvider> _Nullable _fallback;

    // ── State ─────────────────────────────────────────────────────────────────
    dispatch_queue_t _mlQueue;
    BOOL _invalidated;      // written on _mlQueue; read via _invalidated flag

    // Current seek generation — detects resets.
    uint64_t _currentGeneration;

    // Float input scratch buffer — reused each frame (kInputH * kInputW * kInputC floats).
    float *_inputScratch;  // kInputFloats

    // ── Phase 9B-6A: diagnostic timing state (mlQueue only) ──────────────────
    // _diagFrameCount: total number of frames that entered _processPixelBuffer.
    // Throttle: log when (_diagFrameCount % kVGDiagLogInterval == 1).
    NSUInteger       _diagFrameCount;
    CFAbsoluteTime   _diagLastSuccessTime;  // time of last mask publication
}

@synthesize latestMask      = _latestMask;
@synthesize usingFallback   = _usingFallback;
@synthesize ready           = _ready;

// ─── Init ─────────────────────────────────────────────────────────────────────

- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback {
    return [self initWithModelURL:modelURL fallback:fallback policy:nil];
}

- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy {
    self = [super init];
    if (!self) return nil;

    _fallback          = fallback;
    _policy            = policy ?: [[VGFaceNeckBeautyMaskPolicy alloc] init];
    _usingFallback     = NO;
    _ready             = NO;
    _invalidated       = NO;
    _currentGeneration = UINT64_MAX;
    _latestMask        = nil;

    _mlQueue = dispatch_queue_create("com.vanguard.litert", DISPATCH_QUEUE_SERIAL);

    // Allocate input scratch buffer.
    _inputScratch = (float *)malloc(kInputFloats * sizeof(float));
    if (!_inputScratch) {
        os_log_error(VGLiteRTLog(), "Failed to allocate input scratch buffer");
        _usingFallback = YES;
        return self;
    }

    if (!modelURL) {
        os_log_error(VGLiteRTLog(), "nil modelURL — entering fallback mode");
        _usingFallback = YES;
        return self;
    }

    // Load and validate synchronously on init so callers can inspect -ready immediately.
    // Initialization is typically done off the main thread by the factory.
    [self _setupInterpreterFromURL:modelURL];

    return self;
}

// ─── Interpreter lifecycle (called once during init, not on _mlQueue) ─────────

// ── Phase 9B-6A: diagnostic throttle interval ────────────────────────────────
// Log once every kVGDiagLogInterval processed frames (~1s at 30fps).
static const NSUInteger kVGDiagLogInterval = 30;

- (void)_setupInterpreterFromURL:(NSURL *)modelURL {
    // 1. Load model from file path.
    const char *path = modelURL.fileSystemRepresentation;
    if (!path) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] model=MISSING reason=noFileSystemRepresentation");
        _usingFallback = YES;
        return;
    }

    os_log_info(VGLiteRTLog(),
        "[VGLiteRTMaskProvider lifecycle] model=found path=%{public}s", path);

    _tflModel = TfLiteModelCreateFromFile(path);
    if (!_tflModel) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] model=loadFailed path=%{public}s", path);
        _usingFallback = YES;
        return;
    }
    os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] model=loaded");

    // 2. Create interpreter options.
    TfLiteInterpreterOptions *opts = TfLiteInterpreterOptionsCreate();
    if (!opts) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] TfLiteInterpreterOptionsCreate failed");
        TfLiteModelDelete(_tflModel); _tflModel = nil;
        _usingFallback = YES;
        return;
    }
    TfLiteInterpreterOptionsSetNumThreads(opts, 2);

    // 3. Attempt Metal GPU delegate (device only — simulator has no Metal GPU).
#if !TARGET_OS_SIMULATOR
    os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] metalDelegate=attempting");
    TFLGpuDelegateOptions gpuOpts = TFLGpuDelegateOptionsDefault();
    gpuOpts.allow_precision_loss = false;  // full float32 precision
    gpuOpts.enable_quantization  = true;
    _metalDelegate = TFLGpuDelegateCreate(&gpuOpts);
    if (_metalDelegate) {
        TfLiteInterpreterOptionsAddDelegate(opts, _metalDelegate);
        os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] metalDelegate=attached");
    } else {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] metalDelegate=failed reason=TFLGpuDelegateCreate returned nil");
        TfLiteInterpreterOptionsDelete(opts);
        TfLiteModelDelete(_tflModel); _tflModel = nil;
        _usingFallback = YES;
        return;
    }
#else
    os_log_info(VGLiteRTLog(),
        "[VGLiteRTMaskProvider lifecycle] metalDelegate=skipped reason=simulator");
#endif

    // 4. Create interpreter.
    _tflInterpreter = TfLiteInterpreterCreate(_tflModel, opts);
    TfLiteInterpreterOptionsDelete(opts);
    // Model can be deleted after interpreter is created.
    TfLiteModelDelete(_tflModel);
    _tflModel = nil;

    if (!_tflInterpreter) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] interpreter=createFailed");
#if !TARGET_OS_SIMULATOR
        if (_metalDelegate) { TFLGpuDelegateDelete(_metalDelegate); _metalDelegate = nil; }
#endif
        _usingFallback = YES;
        return;
    }
    os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] interpreter=created");

    // 5. Allocate tensors.
    if (TfLiteInterpreterAllocateTensors(_tflInterpreter) != kTfLiteOk) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] tensors=allocFailed");
        [self _teardownInterpreter];
        _usingFallback = YES;
        return;
    }
    os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] tensors=allocated");

    // 6. Validate tensor contract: input [1,256,256,3] float32, output [1,256,256,6] float32.
    if (![self _validateTensorContract]) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] tensors=contractMismatch — entering fallback");
        [self _teardownInterpreter];
        _usingFallback = YES;
        return;
    }

    _ready         = YES;
    _usingFallback = NO;
    os_log_info(VGLiteRTLog(),
        "[VGLiteRTMaskProvider lifecycle] model=found interpreter=created tensors=allocated "
#if !TARGET_OS_SIMULATOR
        "metalDelegate=attached"
#else
        "metalDelegate=skipped(sim)"
#endif
        " status=READY");
}

/// Returns YES if input [1,256,256,3] float32 and output [1,256,256,6] float32.
- (BOOL)_validateTensorContract {
    if (!_tflInterpreter) return NO;

    // Input tensor.
    TfLiteTensor *inputTensor = TfLiteInterpreterGetInputTensor(_tflInterpreter, 0);
    if (!inputTensor) { os_log_error(VGLiteRTLog(), "Input tensor is nil"); return NO; }

    if (TfLiteTensorType(inputTensor) != kTfLiteFloat32) {
        os_log_error(VGLiteRTLog(), "Input tensor type is not float32");
        return NO;
    }
    if (TfLiteTensorNumDims(inputTensor) != 4 ||
        TfLiteTensorDim(inputTensor, 0) != 1 ||
        TfLiteTensorDim(inputTensor, 1) != kInputH ||
        TfLiteTensorDim(inputTensor, 2) != kInputW ||
        TfLiteTensorDim(inputTensor, 3) != kInputC) {
        os_log_error(VGLiteRTLog(), "Input tensor shape mismatch");
        return NO;
    }

    // Output tensor.
    const TfLiteTensor *outputTensor = TfLiteInterpreterGetOutputTensor(_tflInterpreter, 0);
    if (!outputTensor) { os_log_error(VGLiteRTLog(), "Output tensor is nil"); return NO; }

    if (TfLiteTensorType(outputTensor) != kTfLiteFloat32) {
        os_log_error(VGLiteRTLog(), "Output tensor type is not float32");
        return NO;
    }
    if (TfLiteTensorNumDims(outputTensor) != 4 ||
        TfLiteTensorDim(outputTensor, 0) != 1 ||
        TfLiteTensorDim(outputTensor, 1) != kInputH ||
        TfLiteTensorDim(outputTensor, 2) != kInputW ||
        TfLiteTensorDim(outputTensor, 3) != kOutputC) {
        os_log_error(VGLiteRTLog(), "Output tensor shape mismatch");
        return NO;
    }

    return YES;
}

// ─── VGMaskProvider protocol ──────────────────────────────────────────────────

- (void)submitFrame:(CVPixelBufferRef)pixelBuffer
                pts:(CMTime)pts
         generation:(uint64_t)generation {

    if (_invalidated) {
        // Already invalidated — forward to fallback (if any) and return.
        [_fallback submitFrame:pixelBuffer pts:pts generation:generation];
        return;
    }

    if (_usingFallback) {
        [_fallback submitFrame:pixelBuffer pts:pts generation:generation];
        return;
    }

    // Retain pixel buffer for async dispatch.
    CVPixelBufferRetain(pixelBuffer);
    __weak typeof(self) weakSelf = self;

    dispatch_async(_mlQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_invalidated) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        [strongSelf _processPixelBuffer:pixelBuffer pts:pts generation:generation];
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)invalidate {
    os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider] invalidate");
    // Mark invalidated atomically before dispatching teardown.
    _invalidated = YES;
    _ready       = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_async(_mlQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf _teardownInterpreter];
    });

    [_fallback invalidate];
}

// ─── Private: frame processing (on _mlQueue) ─────────────────────────────────

- (void)_processPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        pts:(CMTime)pts
                 generation:(uint64_t)generation {

    if (_invalidated || !_tflInterpreter || !_ready) {
        return;
    }

    // Detect generation change → reset temporal state.
    BOOL generationReset = NO;
    if (generation != _currentGeneration) {
        _currentGeneration = generation;
        generationReset    = YES;
    }

    // ── Phase 9B-6A: diagnostic frame counter ────────────────────────────────
    _diagFrameCount++;
    BOOL shouldLog = (_diagFrameCount % kVGDiagLogInterval == 1);
    CFAbsoluteTime t0 = shouldLog ? CFAbsoluteTimeGetCurrent() : 0;

    // 1. Preprocess pixel buffer → float RGB [0,1] at 256×256.
    if (![self _preprocessPixelBuffer:pixelBuffer intoScratch:_inputScratch]) {
        os_log_error(VGLiteRTLog(), "Pixel buffer preprocessing failed — skipping frame");
        return;
    }

    CFAbsoluteTime t1 = shouldLog ? CFAbsoluteTimeGetCurrent() : 0;

    // 2. Copy into input tensor.
    TfLiteTensor *inputTensor = TfLiteInterpreterGetInputTensor(_tflInterpreter, 0);
    if (!inputTensor) { return; }

    TfLiteStatus copyStatus = TfLiteTensorCopyFromBuffer(inputTensor,
                                                          _inputScratch,
                                                          kInputFloats * sizeof(float));
    if (copyStatus != kTfLiteOk) {
        os_log_error(VGLiteRTLog(), "TfLiteTensorCopyFromBuffer failed");
        return;
    }

    // 3. Run inference.
    if (TfLiteInterpreterInvoke(_tflInterpreter) != kTfLiteOk) {
        os_log_error(VGLiteRTLog(), "TfLiteInterpreterInvoke failed");
        return;
    }

    CFAbsoluteTime t2 = shouldLog ? CFAbsoluteTimeGetCurrent() : 0;

    // 4. Read output tensor data pointer.
    const TfLiteTensor *outputTensor = TfLiteInterpreterGetOutputTensor(_tflInterpreter, 0);
    if (!outputTensor) { return; }

    const float *outputData = (const float *)TfLiteTensorData(outputTensor);
    if (!outputData) {
        os_log_error(VGLiteRTLog(), "Output tensor data pointer is nil after invoke");
        return;
    }

    // 5. Pass output tensor to policy.
    // Note: pixelBuffer sourceWidth/Height are the original frame dimensions.
    size_t sourceW = (size_t)CVPixelBufferGetWidth(pixelBuffer);
    size_t sourceH = (size_t)CVPixelBufferGetHeight(pixelBuffer);

    VGSkinMask *mask = [_policy processTensor:outputData
                                  sourceWidth:sourceW
                                 sourceHeight:sourceH
                                          pts:pts
                              generationReset:generationReset];

    CFAbsoluteTime t3 = shouldLog ? CFAbsoluteTimeGetCurrent() : 0;

    // 6. Publish.
    if (mask) {
        // ── Phase 9B-6A: cadence measurement ─────────────────────────────────
        if (shouldLog) {
            CFAbsoluteTime now = (t3 > 0) ? t3 : CFAbsoluteTimeGetCurrent();
            double cadenceMs = (_diagLastSuccessTime > 0)
                ? (now - _diagLastSuccessTime) * 1000.0
                : -1.0;
            double preMs   = (t1 - t0) * 1000.0;
            double inferMs = (t2 - t1) * 1000.0;
            double postMs  = (t3 - t2) * 1000.0;
            double totalMs = (t3 - t0) * 1000.0;
            os_log_debug(VGLiteRTLog(),
                "[VGLiteRTMaskProvider timing] pre=%.1fms infer=%.1fms post=%.1fms "
                "total=%.1fms cadence=%.1fms pts=%.3fs gen=%llu",
                preMs, inferMs, postMs, totalMs, cadenceMs,
                CMTimeGetSeconds(pts), (unsigned long long)generation);
        }
        _diagLastSuccessTime = (t3 > 0) ? t3 : CFAbsoluteTimeGetCurrent();
        _latestMask = mask;
    }
}

// ─── Private: pixel buffer → float RGB [0,1] 256×256 ─────────────────────────

/// Returns YES on success. Writes kInputFloats floats into outBuf.
/// outBuf must be pre-allocated with kInputFloats * sizeof(float) bytes.
- (BOOL)_preprocessPixelBuffer:(CVPixelBufferRef)pixelBuffer
                  intoScratch:(float *)outBuf {

    OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    BOOL ok = NO;

    if (fmt == kCVPixelFormatType_32BGRA) {
        ok = [self _convertBGRA:pixelBuffer into:outBuf];
    } else if (fmt == kCVPixelFormatType_32RGBA) {
        ok = [self _convertRGBA:pixelBuffer into:outBuf];
    } else if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
               fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        ok = [self _convertNV12:pixelBuffer into:outBuf fullRange:(fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)];
    } else {
        os_log_error(VGLiteRTLog(), "Unsupported pixel format: 0x%08X", (unsigned int)fmt);
        ok = NO;
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return ok;
}

/// BGRA → float RGB [0,1] with nearest-neighbour resize to 256×256.
- (BOOL)_convertBGRA:(CVPixelBufferRef)pb into:(float *)out {
    size_t srcW      = CVPixelBufferGetWidth(pb);
    size_t srcH      = CVPixelBufferGetHeight(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    if (!src || srcW == 0 || srcH == 0) return NO;

    for (int oy = 0; oy < kInputH; oy++) {
        size_t sy = (size_t)((oy * srcH + srcH / 2) / (size_t)kInputH);
        if (sy >= srcH) sy = srcH - 1;
        const uint8_t *row = src + sy * bytesPerRow;
        for (int ox = 0; ox < kInputW; ox++) {
            size_t sx = (size_t)((ox * srcW + srcW / 2) / (size_t)kInputW);
            if (sx >= srcW) sx = srcW - 1;
            const uint8_t *px = row + sx * 4; // BGRA
            int base = (oy * kInputW + ox) * kInputC;
            out[base + 0] = px[2] / 255.0f;  // R
            out[base + 1] = px[1] / 255.0f;  // G
            out[base + 2] = px[0] / 255.0f;  // B
        }
    }
    return YES;
}

/// RGBA → float RGB [0,1] with nearest-neighbour resize to 256×256.
- (BOOL)_convertRGBA:(CVPixelBufferRef)pb into:(float *)out {
    size_t srcW        = CVPixelBufferGetWidth(pb);
    size_t srcH        = CVPixelBufferGetHeight(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    if (!src || srcW == 0 || srcH == 0) return NO;

    for (int oy = 0; oy < kInputH; oy++) {
        size_t sy = (size_t)((oy * srcH + srcH / 2) / (size_t)kInputH);
        if (sy >= srcH) sy = srcH - 1;
        const uint8_t *row = src + sy * bytesPerRow;
        for (int ox = 0; ox < kInputW; ox++) {
            size_t sx = (size_t)((ox * srcW + srcW / 2) / (size_t)kInputW);
            if (sx >= srcW) sx = srcW - 1;
            const uint8_t *px = row + sx * 4; // RGBA
            int base = (oy * kInputW + ox) * kInputC;
            out[base + 0] = px[0] / 255.0f;  // R
            out[base + 1] = px[1] / 255.0f;  // G
            out[base + 2] = px[2] / 255.0f;  // B
        }
    }
    return YES;
}

/// NV12/NV21 (YUV 420 biplanar) → float RGB [0,1] with resize to 256×256.
/// Uses BT.601 limited/full range YUV → RGB conversion.
- (BOOL)_convertNV12:(CVPixelBufferRef)pb into:(float *)out fullRange:(BOOL)fullRange {
    size_t srcW = CVPixelBufferGetWidth(pb);
    size_t srcH = CVPixelBufferGetHeight(pb);
    if (srcW == 0 || srcH == 0) return NO;

    const uint8_t *yPlane  = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    const uint8_t *uvPlane = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    if (!yPlane || !uvPlane) return NO;

    size_t yStride  = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);

    // BT.601 coefficients.
    // Limited range: Y ∈ [16,235], UV ∈ [16,240].
    // Full range:    Y ∈ [0,255],  UV ∈ [0,255].
    const float yScale  = fullRange ? (1.0f / 255.0f) : (1.0f / 219.0f);
    const float yOffset = fullRange ? 0.0f : 16.0f;
    const float uvScale = fullRange ? (1.0f / 255.0f) : (1.0f / 224.0f);

    for (int oy = 0; oy < kInputH; oy++) {
        size_t sy = (size_t)((oy * srcH + srcH / 2) / (size_t)kInputH);
        if (sy >= srcH) sy = srcH - 1;

        // UV plane is half-resolution vertically.
        size_t uvy = sy / 2;

        const uint8_t *yRow  = yPlane  + sy  * yStride;
        const uint8_t *uvRow = uvPlane + uvy * uvStride;

        for (int ox = 0; ox < kInputW; ox++) {
            size_t sx = (size_t)((ox * srcW + srcW / 2) / (size_t)kInputW);
            if (sx >= srcW) sx = srcW - 1;

            float Y  = ((float)yRow[sx]     - yOffset) * yScale;
            // UV plane: interleaved Cb, Cr (NV12 layout).
            size_t uvx = (sx / 2) * 2;
            float Cb = ((float)uvRow[uvx]     - 128.0f) * uvScale;
            float Cr = ((float)uvRow[uvx + 1] - 128.0f) * uvScale;

            // BT.601 YCbCr → RGB.
            float R = Y + 1.402f * Cr;
            float G = Y - 0.344136f * Cb - 0.714136f * Cr;
            float B = Y + 1.772f * Cb;

            // Clamp to [0,1].
            R = R < 0.0f ? 0.0f : (R > 1.0f ? 1.0f : R);
            G = G < 0.0f ? 0.0f : (G > 1.0f ? 1.0f : G);
            B = B < 0.0f ? 0.0f : (B > 1.0f ? 1.0f : B);

            int base = (oy * kInputW + ox) * kInputC;
            out[base + 0] = R;
            out[base + 1] = G;
            out[base + 2] = B;
        }
    }
    return YES;
}

// ─── Private: teardown (safe to call multiple times, must run on _mlQueue) ───

- (void)_teardownInterpreter {
    if (_tflInterpreter) {
        TfLiteInterpreterDelete(_tflInterpreter);
        _tflInterpreter = nil;
    }
#if !TARGET_OS_SIMULATOR
    if (_metalDelegate) {
        TFLGpuDelegateDelete(_metalDelegate);
        _metalDelegate = nil;
    }
#endif
    // _tflModel already deleted after interpreter creation; guard anyway.
    if (_tflModel) {
        TfLiteModelDelete(_tflModel);
        _tflModel = nil;
    }
}

// ─── Dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider] dealloc");

    // Capture pointers locally to avoid self-deadlock if dealloc happens on _mlQueue.
    TfLiteInterpreter *interp  = _tflInterpreter;
#if !TARGET_OS_SIMULATOR
    TfLiteDelegate    *metal   = _metalDelegate;
    _metalDelegate  = nil;
#endif
    TfLiteModel       *model   = _tflModel;
    void              *scratch = _inputScratch;

    _tflInterpreter = nil;
    _tflModel       = nil;
    _inputScratch   = NULL;

    // Asynchronous teardown on _mlQueue. 'self' is deallocated immediately,
    // but the underlying C/C++ resources are cleaned up safely on the queue
    // that created/used them.
    dispatch_async(_mlQueue, ^{
        if (interp) {
            TfLiteInterpreterDelete(interp);
        }
#if !TARGET_OS_SIMULATOR
        if (metal) {
            TFLGpuDelegateDelete(metal);
        }
#endif
        if (model) {
            TfLiteModelDelete(model);
        }
        if (scratch) {
            free(scratch);
        }
    });
}

@end
