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
//   TfLiteInterpreterGetInputTensorCount / GetOutputTensorCount
//   TfLiteInterpreterGetInputTensor / GetOutputTensor
//   TfLiteTensorType / TfLiteTensorNumDims / TfLiteTensorDim / TfLiteTensorByteSize
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
//   Output: float RGB [0,1] at the model input size (read from the input
//   tensor), sampled nearest-neighbour through per-column / per-row lookup
//   tables built once per source size (VGLiteRTInputGeometry decides whether
//   the frame is stretched or aspect-fitted with a zero border).
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
#import <os/lock.h>
#include <math.h>
#include <stdatomic.h>

// ─── Constants ────────────────────────────────────────────────────────────────

/// Input tensor channel contract (RGB, [0,1]).
static const int kInputC = 3;
/// MediaPipe Selfie Multiclass class count: selects the policy matte path.
static const int kMulticlassOutputC = 6;
/// Spatial size the multiclass policies hard-code (VGFaceNeckBeautyMaskPolicy /
/// VGLiveGreenScreenPersonMattePolicy): a 6-channel model must be 256×256.
static const int kMulticlassSide = 256;
/// Sanity cap on any model tensor side (bounds the init-time scratch allocation).
static const int kMaxTensorSide = 2048;

static os_log_t VGLiteRTLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.vanguard", "VGLiteRTMaskProvider"); });
    return log;
}

static NSString *VGLiteRTInputGeometryName(VGLiteRTInputGeometry geometry) {
    return geometry == VGLiteRTInputGeometryAspectFit ? @"aspectFit" : @"stretch";
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
    // Used only on the multiclass (6-channel) matte path.
    VGFaceNeckBeautyMaskPolicy *_policy;

    // ── Fallback provider ─────────────────────────────────────────────────────
    id<VGMaskProvider> _Nullable _fallback;

    // ── Metal delegate precision option (fixed at init) ──────────────────────
    BOOL      _metalAllowPrecisionLoss;   // TFLGpuDelegateOptions.allow_precision_loss
    NSString *_inferenceBackend;          // see header: metal_fp32 | metal_fp16 | cpu_simulator | unavailable

    // ── Input geometry + setup options (fixed at init) ───────────────────────
    VGLiteRTInputGeometry _inputGeometry;
    BOOL                  _warmUpInvokeAtSetup;

    // ── Tensor contract (read from the allocated tensors at setup) ───────────
    int       _inputW, _inputH, _inputC;      // 0 until validated
    int       _outputW, _outputH, _outputC;   // 0 until validated
    size_t    _inputFloats;                   // _inputH * _inputW * _inputC
    NSString *_mattePath;                     // see header

    // ── State ─────────────────────────────────────────────────────────────────
    dispatch_queue_t _mlQueue;
    BOOL _invalidated;      // written on _mlQueue; read via _invalidated flag

    // Current seek generation — detects resets.
    uint64_t _currentGeneration;

    // Float input scratch buffer — allocated once at setup (_inputFloats floats),
    // reused every frame.
    float *_inputScratch;

    // Nearest-neighbour sample maps (allocated at setup, _inputW / _inputH
    // entries; rebuilt only when the source frame size changes — never per
    // frame). Entry = source column/row, or -1 for the zero border of the
    // aspect-fit geometry.
    int32_t *_mapCols;
    int32_t *_mapRows;
    size_t   _mapSrcW, _mapSrcH;   // source size the maps were built for (0 = none)

    // ── Phase 9B-6A: diagnostic timing state (mlQueue only) ──────────────────
    // _diagFrameCount: total number of frames that entered _processPixelBuffer.
    // Throttle: log when (_diagFrameCount % kVGDiagLogInterval == 1).
    NSUInteger       _diagFrameCount;
    CFAbsoluteTime   _diagLastSuccessTime;  // time of last mask publication

    // ── Phase 9B-6B.1: latest-pending-frame guard ────────────────────────────
    // At most one inference runs at a time (_mlInFlight=1 while running).
    // At most one pending frame is held (_pendingPixelBuffer) — newer arrivals
    // replace older ones. When inference completes, _mlQueue immediately drains
    // the pending frame (no idle gap waiting for the next camera frame arrival).
    // Eliminates the 20ms camera-arrival gap that caused 166ms ageMs peaks.
    _Atomic(int32_t) _mlInFlight;       // 0=idle, 1=inference running
    CVPixelBufferRef _pendingPixelBuffer; // retained; nil if no pending frame
    CMTime           _pendingPTS;
    uint64_t         _pendingGeneration;
    os_unfair_lock   _pendingLock;      // protects the pending slot
    // Diagnostics (not on any specific queue — used with interlocked access).
    NSUInteger       _diagDropCount;    // frames that arrived while busy (went to pending)
    NSUInteger       _diagPendingFired; // times a pending frame was immediately processed
}

@synthesize latestMask              = _latestMask;
@synthesize usingFallback           = _usingFallback;
@synthesize ready                   = _ready;
@synthesize onTimingSample          = _onTimingSample;
@synthesize metalAllowPrecisionLoss = _metalAllowPrecisionLoss;
@synthesize inferenceBackend        = _inferenceBackend;
@synthesize inputGeometry           = _inputGeometry;
@synthesize mattePath               = _mattePath;

// Tensor contract accessors (written once at setup, before `ready` is published).
- (NSInteger)inputWidth     { return _inputW; }
- (NSInteger)inputHeight    { return _inputH; }
- (NSInteger)inputChannels  { return _inputC; }
- (NSInteger)outputWidth    { return _outputW; }
- (NSInteger)outputHeight   { return _outputH; }
- (NSInteger)outputChannels { return _outputC; }

// ─── Init ─────────────────────────────────────────────────────────────────────

- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback {
    return [self initWithModelURL:modelURL fallback:fallback policy:nil];
}

- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy {
    // Pre-existing callers: full float32 precision, unchanged behaviour.
    return [self initWithModelURL:modelURL
                         fallback:fallback
                           policy:policy
          metalAllowPrecisionLoss:NO];
}

- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy
                  metalAllowPrecisionLoss:(BOOL)metalAllowPrecisionLoss {
    // Pre-existing production path: stretch geometry, no warm-up invoke.
    return [self initWithModelURL:modelURL
                         fallback:fallback
                           policy:policy
          metalAllowPrecisionLoss:metalAllowPrecisionLoss
                    inputGeometry:VGLiteRTInputGeometryStretch
              warmUpInvokeAtSetup:NO];
}

- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy
                  metalAllowPrecisionLoss:(BOOL)metalAllowPrecisionLoss
                            inputGeometry:(VGLiteRTInputGeometry)inputGeometry
                      warmUpInvokeAtSetup:(BOOL)warmUpInvokeAtSetup {
    self = [super init];
    if (!self) return nil;

    _fallback                = fallback;
    _policy                  = policy;   // default instance created at setup for a 6-channel model
    _metalAllowPrecisionLoss = metalAllowPrecisionLoss;
    _inputGeometry           = inputGeometry;
    _warmUpInvokeAtSetup     = warmUpInvokeAtSetup;
    _inferenceBackend        = @"unavailable";   // replaced once an interpreter is READY
    _mattePath               = @"none";          // replaced once the contract is validated
    _inputW = _inputH = _inputC = 0;
    _outputW = _outputH = _outputC = 0;
    _inputFloats             = 0;
    _inputScratch            = NULL;
    _mapCols                 = NULL;
    _mapRows                 = NULL;
    _mapSrcW = _mapSrcH      = 0;
    _usingFallback           = NO;
    _ready                   = NO;
    _invalidated             = NO;
    _currentGeneration    = UINT64_MAX;
    _latestMask           = nil;
    _pendingPixelBuffer   = nil;
    _pendingPTS           = kCMTimeInvalid;
    _pendingGeneration    = 0;
    _pendingLock          = OS_UNFAIR_LOCK_INIT;
    _onTimingSample       = nil;
    atomic_store(&_mlInFlight, 0);

    _mlQueue = dispatch_queue_create("com.vanguard.litert", DISPATCH_QUEUE_SERIAL);

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
    os_log_info(VGLiteRTLog(),
        "[VGLiteRTMaskProvider lifecycle] metalDelegate=attempting allowPrecisionLoss=%{public}s",
        _metalAllowPrecisionLoss ? "true" : "false");
    TFLGpuDelegateOptions gpuOpts = TFLGpuDelegateOptionsDefault();
    // Default NO: full float32 precision (pre-existing behaviour).
    // YES ("fast Metal"): the delegate may compute in float16.
    gpuOpts.allow_precision_loss = _metalAllowPrecisionLoss ? true : false;
    gpuOpts.enable_quantization  = true;
    _metalDelegate = TFLGpuDelegateCreate(&gpuOpts);
    if (_metalDelegate) {
        TfLiteInterpreterOptionsAddDelegate(opts, _metalDelegate);
        os_log_info(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] metalDelegate=attached precision=%{public}s",
            _metalAllowPrecisionLoss ? "fp16_allowed" : "fp32");
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

    // 6. Read + validate the tensor contract from the allocated tensors
    //    (input [1,H,W,3] float32; output [1,H',W',C] float32, C ∈ {1,2,6}).
    if (![self _readAndValidateTensorContract]) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] tensors=contractMismatch — entering fallback");
        [self _teardownInterpreter];
        _usingFallback = YES;
        return;
    }

    // 7. Input scratch + sample maps sized from the input tensor (setup only —
    //    never reallocated per frame).
    if (![self _allocateInputScratchAndMaps]) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] scratch=allocFailed — entering fallback");
        [self _teardownInterpreter];
        _usingFallback = YES;
        return;
    }

    // 8. Matte path from the output contract.
    if (_outputC == kMulticlassOutputC) {
        if (!_policy) _policy = [[VGFaceNeckBeautyMaskPolicy alloc] init];
        _mattePath = @"multiclass_policy";
    } else {
        _mattePath = @"person_confidence_direct";
    }

    // 9. Optional warm-up invoke: fail closed at setup if the runtime/delegate
    //    cannot execute this model (e.g. an unresolved custom op left on CPU).
    if (_warmUpInvokeAtSetup && ![self _warmUpInvoke]) {
        os_log_error(VGLiteRTLog(),
            "[VGLiteRTMaskProvider lifecycle] warmUpInvoke=failed — entering fallback");
        [self _teardownInterpreter];
        _mattePath = @"none";
        _usingFallback = YES;
        return;
    }

#if !TARGET_OS_SIMULATOR
    _inferenceBackend = _metalAllowPrecisionLoss ? @"metal_fp16" : @"metal_fp32";
#else
    _inferenceBackend = @"cpu_simulator";
#endif
    _ready         = YES;
    _usingFallback = NO;
    os_log_info(VGLiteRTLog(),
        "[VGLiteRTMaskProvider lifecycle] model=found interpreter=created tensors=allocated "
#if !TARGET_OS_SIMULATOR
        "metalDelegate=attached"
#else
        "metalDelegate=skipped(sim)"
#endif
        " backend=%{public}@ input=%dx%dx%d output=%dx%dx%d mattePath=%{public}@ "
        "inputGeometry=%{public}@ warmUpInvoke=%{public}s status=READY",
        _inferenceBackend, _inputW, _inputH, _inputC, _outputW, _outputH, _outputC,
        _mattePath, VGLiteRTInputGeometryName(_inputGeometry),
        _warmUpInvokeAtSetup ? "ok" : "skipped");
}

/// Reads the input/output tensor dimensions after allocation into _input*/
/// _output* and returns YES only for the supported contract:
///   exactly one input,  float32, [1, H, W, 3], 1 ≤ H,W ≤ kMaxTensorSide
///   exactly one output, float32, [1, H', W', C], 1 ≤ H',W' ≤ kMaxTensorSide,
///                       C ∈ {1, 2, 6}; C == 6 additionally requires 256×256
///                       (the multiclass policies hard-code that size).
- (BOOL)_readAndValidateTensorContract {
    if (!_tflInterpreter) return NO;

    if (TfLiteInterpreterGetInputTensorCount(_tflInterpreter) != 1 ||
        TfLiteInterpreterGetOutputTensorCount(_tflInterpreter) != 1) {
        os_log_error(VGLiteRTLog(), "Tensor count mismatch: inputs=%d outputs=%d (expected 1/1)",
                     (int)TfLiteInterpreterGetInputTensorCount(_tflInterpreter),
                     (int)TfLiteInterpreterGetOutputTensorCount(_tflInterpreter));
        return NO;
    }

    // Input tensor.
    const TfLiteTensor *inputTensor = TfLiteInterpreterGetInputTensor(_tflInterpreter, 0);
    if (!inputTensor) { os_log_error(VGLiteRTLog(), "Input tensor is nil"); return NO; }

    if (TfLiteTensorType(inputTensor) != kTfLiteFloat32) {
        os_log_error(VGLiteRTLog(), "Input tensor type is not float32");
        return NO;
    }
    if (TfLiteTensorNumDims(inputTensor) != 4) {
        os_log_error(VGLiteRTLog(), "Input tensor rank %d (expected 4)", (int)TfLiteTensorNumDims(inputTensor));
        return NO;
    }
    const int inN = TfLiteTensorDim(inputTensor, 0);
    const int inH = TfLiteTensorDim(inputTensor, 1);
    const int inW = TfLiteTensorDim(inputTensor, 2);
    const int inC = TfLiteTensorDim(inputTensor, 3);
    if (inN != 1 || inC != kInputC ||
        inH < 1 || inH > kMaxTensorSide || inW < 1 || inW > kMaxTensorSide) {
        os_log_error(VGLiteRTLog(), "Input tensor shape [%d,%d,%d,%d] unsupported (expected [1,H,W,3])",
                     inN, inH, inW, inC);
        return NO;
    }
    const size_t inputFloats = (size_t)inH * (size_t)inW * (size_t)inC;
    if (TfLiteTensorByteSize(inputTensor) != inputFloats * sizeof(float)) {
        os_log_error(VGLiteRTLog(), "Input tensor byte size %zu != %zu",
                     TfLiteTensorByteSize(inputTensor), inputFloats * sizeof(float));
        return NO;
    }

    // Output tensor.
    const TfLiteTensor *outputTensor = TfLiteInterpreterGetOutputTensor(_tflInterpreter, 0);
    if (!outputTensor) { os_log_error(VGLiteRTLog(), "Output tensor is nil"); return NO; }

    if (TfLiteTensorType(outputTensor) != kTfLiteFloat32) {
        os_log_error(VGLiteRTLog(), "Output tensor type is not float32");
        return NO;
    }
    if (TfLiteTensorNumDims(outputTensor) != 4) {
        os_log_error(VGLiteRTLog(), "Output tensor rank %d (expected 4)", (int)TfLiteTensorNumDims(outputTensor));
        return NO;
    }
    const int outN = TfLiteTensorDim(outputTensor, 0);
    const int outH = TfLiteTensorDim(outputTensor, 1);
    const int outW = TfLiteTensorDim(outputTensor, 2);
    const int outC = TfLiteTensorDim(outputTensor, 3);
    const BOOL channelsOK = (outC == 1 || outC == 2 || outC == kMulticlassOutputC);
    if (outN != 1 || !channelsOK ||
        outH < 1 || outH > kMaxTensorSide || outW < 1 || outW > kMaxTensorSide) {
        os_log_error(VGLiteRTLog(), "Output tensor shape [%d,%d,%d,%d] unsupported (expected [1,H,W,{1,2,6}])",
                     outN, outH, outW, outC);
        return NO;
    }
    if (outC == kMulticlassOutputC && (outH != kMulticlassSide || outW != kMulticlassSide)) {
        os_log_error(VGLiteRTLog(), "6-channel output must be %dx%d for the multiclass policy (got %dx%d)",
                     kMulticlassSide, kMulticlassSide, outW, outH);
        return NO;
    }
    const size_t outputFloats = (size_t)outH * (size_t)outW * (size_t)outC;
    if (TfLiteTensorByteSize(outputTensor) != outputFloats * sizeof(float)) {
        os_log_error(VGLiteRTLog(), "Output tensor byte size %zu != %zu",
                     TfLiteTensorByteSize(outputTensor), outputFloats * sizeof(float));
        return NO;
    }

    _inputW = inW;  _inputH = inH;  _inputC = inC;
    _outputW = outW; _outputH = outH; _outputC = outC;
    _inputFloats = inputFloats;
    os_log_info(VGLiteRTLog(),
        "[VGLiteRTMaskProvider lifecycle] tensors=contractOK input=[1,%d,%d,%d] output=[1,%d,%d,%d]",
        inH, inW, inC, outH, outW, outC);
    return YES;
}

/// Allocates the float input scratch and the nearest-neighbour sample maps
/// for the validated input size. Setup only.
- (BOOL)_allocateInputScratchAndMaps {
    free(_inputScratch); _inputScratch = NULL;
    free(_mapCols);      _mapCols      = NULL;
    free(_mapRows);      _mapRows      = NULL;
    _mapSrcW = _mapSrcH = 0;

    _inputScratch = (float *)malloc(_inputFloats * sizeof(float));
    _mapCols      = (int32_t *)malloc((size_t)_inputW * sizeof(int32_t));
    _mapRows      = (int32_t *)malloc((size_t)_inputH * sizeof(int32_t));
    if (!_inputScratch || !_mapCols || !_mapRows) {
        os_log_error(VGLiteRTLog(), "Failed to allocate input scratch / sample maps (%dx%dx%d)",
                     _inputW, _inputH, _inputC);
        return NO;
    }
    return YES;
}

/// One TfLiteInterpreterInvoke with a zero input. YES when the invoke ran and
/// the output tensor is readable with the validated shape. Setup only.
- (BOOL)_warmUpInvoke {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    memset(_inputScratch, 0, _inputFloats * sizeof(float));

    TfLiteTensor *inputTensor = TfLiteInterpreterGetInputTensor(_tflInterpreter, 0);
    if (!inputTensor ||
        TfLiteTensorCopyFromBuffer(inputTensor, _inputScratch, _inputFloats * sizeof(float)) != kTfLiteOk) {
        os_log_error(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] warmUpInvoke=failed reason=inputCopy");
        return NO;
    }
    if (TfLiteInterpreterInvoke(_tflInterpreter) != kTfLiteOk) {
        os_log_error(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] warmUpInvoke=failed reason=invoke");
        return NO;
    }
    const TfLiteTensor *outputTensor = TfLiteInterpreterGetOutputTensor(_tflInterpreter, 0);
    if (!outputTensor || !TfLiteTensorData(outputTensor)) {
        os_log_error(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] warmUpInvoke=failed reason=outputData");
        return NO;
    }
    // A model with dynamic output shapes would change the contract on invoke:
    // treat that as unsupported (the per-frame matte build trusts _output*).
    if (TfLiteTensorNumDims(outputTensor) != 4 ||
        TfLiteTensorDim(outputTensor, 0) != 1 ||
        TfLiteTensorDim(outputTensor, 1) != _outputH ||
        TfLiteTensorDim(outputTensor, 2) != _outputW ||
        TfLiteTensorDim(outputTensor, 3) != _outputC) {
        os_log_error(VGLiteRTLog(), "[VGLiteRTMaskProvider lifecycle] warmUpInvoke=failed reason=outputShapeChanged");
        return NO;
    }
    os_log_info(VGLiteRTLog(),
        "[VGLiteRTMaskProvider lifecycle] warmUpInvoke=ok durationMs=%.1f",
        (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
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

    // ── Phase 9B-6B.1: latest-pending-frame guard ────────────────────────────
    // If an inference is already running, store this frame as the pending frame
    // (replacing any older pending). When the running inference completes it
    // immediately drains the pending slot — no idle gap, no queue backlog.
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_mlInFlight, &expected, 1)) {
        // Already in-flight — store as pending (replace any older pending).
        _diagDropCount++;
        os_unfair_lock_lock(&_pendingLock);
        CVPixelBufferRef oldPending = _pendingPixelBuffer;
        CVPixelBufferRetain(pixelBuffer);
        _pendingPixelBuffer = pixelBuffer;
        _pendingPTS         = pts;
        _pendingGeneration  = generation;
        os_unfair_lock_unlock(&_pendingLock);
        if (oldPending) { CVPixelBufferRelease(oldPending); } // release replaced older frame
        if (_diagDropCount == 1) {
            os_log_info(VGLiteRTLog(),
                "[VGLiteRTMaskProvider diagnostic] pending-frame slot active — "
                "first frame stored as pending (inference in-flight).");
        }
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
            // Release any pending buffer we can no longer use.
            if (strongSelf) {
                os_unfair_lock_lock(&strongSelf->_pendingLock);
                CVPixelBufferRef stale = strongSelf->_pendingPixelBuffer;
                strongSelf->_pendingPixelBuffer = nil;
                os_unfair_lock_unlock(&strongSelf->_pendingLock);
                if (stale) { CVPixelBufferRelease(stale); }
                atomic_store(&strongSelf->_mlInFlight, 0);
            }
            return;
        }
        [strongSelf _processPixelBuffer:pixelBuffer pts:pts generation:generation];
        CVPixelBufferRelease(pixelBuffer);

        // ── Drain pending: if a newer frame arrived while we were running,
        // process it immediately without waiting for the next camera frame.
        // _mlInFlight stays 1 during pending processing — no concurrent submit.
        os_unfair_lock_lock(&strongSelf->_pendingLock);
        CVPixelBufferRef pendingBuf = strongSelf->_pendingPixelBuffer;
        CMTime           pendingPTS = strongSelf->_pendingPTS;
        uint64_t         pendingGen = strongSelf->_pendingGeneration;
        strongSelf->_pendingPixelBuffer = nil;
        os_unfair_lock_unlock(&strongSelf->_pendingLock);

        if (pendingBuf && !strongSelf->_invalidated) {
            strongSelf->_diagPendingFired++;
            if (strongSelf->_diagPendingFired == 1) {
                os_log_info(VGLiteRTLog(),
                    "[VGLiteRTMaskProvider diagnostic] pending-frame drain fired — "
                    "first immediate back-to-back inference.");
            }
            [strongSelf _processPixelBuffer:pendingBuf pts:pendingPTS generation:pendingGen];
            CVPixelBufferRelease(pendingBuf);
        } else if (pendingBuf) {
            CVPixelBufferRelease(pendingBuf); // invalidated — just release
        }

        atomic_store(&strongSelf->_mlInFlight, 0);
    });
}

- (void)invalidate {
    os_log_info(VGLiteRTLog(), "[VGLiteRTMaskProvider] invalidate");
    // Mark invalidated atomically before dispatching teardown.
    _invalidated = YES;
    _ready       = NO;
    // Drop the diagnostic hook: a frame already inside _processPixelBuffer
    // holds its own copy and may deliver one final sample; nothing after that.
    self.onTimingSample = nil;

    // Release any pending buffer immediately — it can no longer be processed.
    os_unfair_lock_lock(&_pendingLock);
    CVPixelBufferRef stalePending = _pendingPixelBuffer;
    _pendingPixelBuffer = nil;
    os_unfair_lock_unlock(&_pendingLock);
    if (stalePending) { CVPixelBufferRelease(stalePending); }

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
    // Log on first 3 frames for immediate physical smoke visibility,
    // then every kVGDiagLogInterval frames thereafter.
    BOOL shouldLog = (_diagFrameCount <= 3) || (_diagFrameCount % kVGDiagLogInterval == 1);
    if (_diagFrameCount == 1) {
        os_log_info(VGLiteRTLog(),
            "[VGLiteRTMaskProvider diagnostic] processing path reached frame=1 "
            "throttleInterval=%lu firstLogFrames=3",
            (unsigned long)kVGDiagLogInterval);
    }
    // Diagnostic handler (atomic copy read, once per frame). When nil the
    // timing path below is exactly the pre-existing throttled-log behaviour.
    VGLiteRTMaskProviderTimingHandler timingHandler = self.onTimingSample;
    const BOOL measure = shouldLog || (timingHandler != nil);
    CFAbsoluteTime t0 = measure ? CFAbsoluteTimeGetCurrent() : 0;

    // 1. Preprocess pixel buffer → float RGB [0,1] at the model input size.
    if (![self _preprocessPixelBuffer:pixelBuffer intoScratch:_inputScratch]) {
        os_log_error(VGLiteRTLog(), "Pixel buffer preprocessing failed — skipping frame");
        return;
    }

    CFAbsoluteTime t1 = measure ? CFAbsoluteTimeGetCurrent() : 0;

    // 2. Copy into input tensor.
    TfLiteTensor *inputTensor = TfLiteInterpreterGetInputTensor(_tflInterpreter, 0);
    if (!inputTensor) { return; }

    TfLiteStatus copyStatus = TfLiteTensorCopyFromBuffer(inputTensor,
                                                          _inputScratch,
                                                          _inputFloats * sizeof(float));
    if (copyStatus != kTfLiteOk) {
        os_log_error(VGLiteRTLog(), "TfLiteTensorCopyFromBuffer failed");
        return;
    }

    // t1c: end of input copy — inputCopyMs = t1c − t1 (includes the cheap
    // GetInputTensor lookup so that inputCopyMs + invokeMs == t2 − t1 == inferMs).
    CFAbsoluteTime t1c = measure ? CFAbsoluteTimeGetCurrent() : 0;

    // 3. Run inference.
    if (TfLiteInterpreterInvoke(_tflInterpreter) != kTfLiteOk) {
        os_log_error(VGLiteRTLog(), "TfLiteInterpreterInvoke failed");
        return;
    }

    CFAbsoluteTime t2 = measure ? CFAbsoluteTimeGetCurrent() : 0;

    // 4. Read output tensor data pointer.
    const TfLiteTensor *outputTensor = TfLiteInterpreterGetOutputTensor(_tflInterpreter, 0);
    if (!outputTensor) { return; }

    const float *outputData = (const float *)TfLiteTensorData(outputTensor);
    if (!outputData) {
        os_log_error(VGLiteRTLog(), "Output tensor data pointer is nil after invoke");
        return;
    }

    // t2o: end of output tensor access — outputAccessMs = t2o − t2. Any
    // delegate-side GPU → host readback that is not paid inside Invoke lands here.
    CFAbsoluteTime t2o = measure ? CFAbsoluteTimeGetCurrent() : 0;

    // 5. Matte build.
    VGSkinMask *mask = nil;
    if (_outputC == kMulticlassOutputC) {
        // Multiclass policy path (6 channels, 256×256).
        // Note: pixelBuffer sourceWidth/Height are the original frame dimensions.
        size_t sourceW = (size_t)CVPixelBufferGetWidth(pixelBuffer);
        size_t sourceH = (size_t)CVPixelBufferGetHeight(pixelBuffer);
        mask = [_policy processTensor:outputData
                          sourceWidth:sourceW
                         sourceHeight:sourceH
                                  pts:pts
                      generationReset:generationReset];
    } else {
        // Direct person-confidence path (1 or 2 channels): no temporal state,
        // so a generation reset has nothing to clear.
        mask = [self _buildPersonConfidenceMatte:outputData pts:pts];
    }

    CFAbsoluteTime t3 = measure ? CFAbsoluteTimeGetCurrent() : 0;

    // 6. Publish.
    if (mask) {
        // ── Phase 9B-6A: cadence measurement ─────────────────────────────────
        CFAbsoluteTime now = (t3 > 0) ? t3 : CFAbsoluteTimeGetCurrent();
        double cadenceMs = (_diagLastSuccessTime > 0)
            ? (now - _diagLastSuccessTime) * 1000.0
            : -1.0;
        double preMs = 0, inferMs = 0, postMs = 0, totalMs = 0;
        double inputCopyMs = 0, invokeMs = 0, outputAccessMs = 0, policyMs = 0;
        if (measure) {
            preMs          = (t1  - t0)  * 1000.0;
            inputCopyMs    = (t1c - t1)  * 1000.0;
            invokeMs       = (t2  - t1c) * 1000.0;
            outputAccessMs = (t2o - t2)  * 1000.0;
            policyMs       = (t3  - t2o) * 1000.0;
            // Backward-compatible combined spans (see header):
            //   inferMs = inputCopyMs + invokeMs, postMs = outputAccessMs + policyMs.
            inferMs = (t2 - t1) * 1000.0;
            postMs  = (t3 - t2) * 1000.0;
            totalMs = (t3 - t0) * 1000.0;
        }
        if (shouldLog) {
            os_log_info(VGLiteRTLog(),
                "[VGLiteRTMaskProvider diagnostic] pre=%.1fms infer=%.1fms "
                "(copy=%.1fms invoke=%.1fms) post=%.1fms (out=%.1fms policy=%.1fms) "
                "total=%.1fms cadence=%.1fms backend=%{public}@ mattePath=%{public}@ "
                "pts=%.3fs gen=%llu frame=%lu",
                preMs, inferMs, inputCopyMs, invokeMs, postMs, outputAccessMs, policyMs,
                totalMs, cadenceMs, _inferenceBackend, _mattePath,
                CMTimeGetSeconds(pts), (unsigned long long)generation,
                (unsigned long)_diagFrameCount);
        }
        _diagLastSuccessTime = now;
        _latestMask = mask;

        // Diagnostic sample — after the publish so a handler that reads
        // latestMask observes the mask this sample describes.
        if (timingHandler) {
            VGLiteRTMaskProviderTimingSample sample;
            sample.preMs          = preMs;
            sample.inferMs        = inferMs;
            sample.postMs         = postMs;
            sample.totalMs        = totalMs;
            sample.inputCopyMs    = inputCopyMs;
            sample.invokeMs       = invokeMs;
            sample.outputAccessMs = outputAccessMs;
            sample.policyMs       = policyMs;
            sample.cadenceMs      = cadenceMs;
            sample.ptsSeconds     = CMTimeGetSeconds(pts);
            sample.generation     = generation;
            sample.frameIndex     = _diagFrameCount;
            timingHandler(sample);
        }
    }
}

// ─── Private: direct person-confidence matte (1/2-channel models) ────────────

/// Builds a OneComponent8 VGSkinMask (255 = person) at the model output size
/// from the person-confidence channel: channel 0 for a 1-channel output, the
/// last channel for a 2-channel (background, person) output — the same choice
/// as the Android MediaPipe rung. Float [0,1] → uint8 uses the same truncating
/// quantisation as that rung (NaN / ≤ 0 → 0, ≥ 1 → 255) so both key alike.
/// No temporal smoothing: the current frame's confidence is published as is.
/// faceCount 1 marks the matte valid for the adapter. Nil on allocation failure.
- (nullable VGSkinMask *)_buildPersonConfidenceMatte:(const float *)outputData pts:(CMTime)pts {
    const size_t w      = (size_t)_outputW;
    const size_t h      = (size_t)_outputH;
    const size_t c      = (size_t)_outputC;
    const size_t pixels = w * h;
    const float *person = outputData + (c - 1);   // channel 0 (C=1) or last (C=2)

    uint8_t *buf = (uint8_t *)malloc(pixels);
    if (!buf) return nil;
    for (size_t i = 0; i < pixels; i++) {
        const float f = person[i * c];
        buf[i] = (isnan(f) || f <= 0.0f) ? 0
               : (f >= 1.0f)             ? 255
               : (uint8_t)(f * 255.0f);
    }
    // dataWithBytesNoCopy → VGSkinMask's `[data copy]` on an immutable NSData
    // is a retain, not a second copy (same trick as the matte policies).
    NSData *maskData = [NSData dataWithBytesNoCopy:buf length:pixels freeWhenDone:YES];
    return [[VGSkinMask alloc] _initWithData:maskData
                                       width:w
                                      height:h
                                   sourcePTS:pts
                                   faceCount:1];
}

// ─── Private: pixel buffer → float RGB [0,1] at the model input size ─────────

/// Returns YES on success. Writes _inputFloats floats into outBuf.
/// outBuf must be pre-allocated with _inputFloats * sizeof(float) bytes.
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

/// (Re)builds the per-column / per-row nearest-neighbour sample maps for a
/// source size. No-op while the source size is unchanged (the common case:
/// once per session). Runs on _mlQueue; no allocation.
///
///   stretch   — sx = (ox·srcW + srcW/2) / inputW (the pre-existing anamorphic
///               integer mapping), never a border entry.
///   aspectFit — s = min(inputW/srcW, inputH/srcH); the frame occupies a
///               centred srcW·s × srcH·s region; tensor pixels outside it map
///               to -1 (zero border). Pixel centres are used, so the region is
///               centred at sub-pixel precision — the compositor's centred
///               scale-to-fill of the model-aspect matte crops exactly that border.
- (void)_ensureSampleMapsForSourceWidth:(size_t)srcW height:(size_t)srcH {
    if (_mapSrcW == srcW && _mapSrcH == srcH) return;

    const int inW = _inputW, inH = _inputH;
    if (_inputGeometry == VGLiteRTInputGeometryAspectFit) {
        const double s    = fmin((double)inW / (double)srcW, (double)inH / (double)srcH);
        const double offX = ((double)inW - (double)srcW * s) * 0.5;
        const double offY = ((double)inH - (double)srcH * s) * 0.5;
        for (int ox = 0; ox < inW; ox++) {
            const double u = ((double)ox + 0.5 - offX) / s;   // continuous source x
            _mapCols[ox] = (u < 0.0 || u >= (double)srcW) ? -1 : (int32_t)u;   // trunc == floor for u ≥ 0
        }
        for (int oy = 0; oy < inH; oy++) {
            const double v = ((double)oy + 0.5 - offY) / s;   // continuous source y
            _mapRows[oy] = (v < 0.0 || v >= (double)srcH) ? -1 : (int32_t)v;
        }
        os_log_info(VGLiteRTLog(),
            "[VGLiteRTMaskProvider preprocess] inputGeometry=aspectFit source=%zux%zu input=%dx%d "
            "scale=%.4f content=%.1fx%.1f offset=(%.1f,%.1f) border=zero sampling=nearest",
            srcW, srcH, inW, inH, s, (double)srcW * s, (double)srcH * s, offX, offY);
    } else {
        for (int ox = 0; ox < inW; ox++) {
            size_t sx = ((size_t)ox * srcW + srcW / 2) / (size_t)inW;
            if (sx >= srcW) sx = srcW - 1;
            _mapCols[ox] = (int32_t)sx;
        }
        for (int oy = 0; oy < inH; oy++) {
            size_t sy = ((size_t)oy * srcH + srcH / 2) / (size_t)inH;
            if (sy >= srcH) sy = srcH - 1;
            _mapRows[oy] = (int32_t)sy;
        }
    }
    _mapSrcW = srcW;
    _mapSrcH = srcH;
}

/// BGRA → float RGB [0,1] through the sample maps (nearest-neighbour).
- (BOOL)_convertBGRA:(CVPixelBufferRef)pb into:(float *)out {
    size_t srcW      = CVPixelBufferGetWidth(pb);
    size_t srcH      = CVPixelBufferGetHeight(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    if (!src || srcW == 0 || srcH == 0) return NO;

    [self _ensureSampleMapsForSourceWidth:srcW height:srcH];
    const int    inW       = _inputW, inH = _inputH;
    const size_t rowFloats = (size_t)inW * kInputC;

    for (int oy = 0; oy < inH; oy++) {
        float        *dst = out + (size_t)oy * rowFloats;
        const int32_t sy  = _mapRows[oy];
        if (sy < 0) { memset(dst, 0, rowFloats * sizeof(float)); continue; }   // zero border row
        const uint8_t *row = src + (size_t)sy * bytesPerRow;
        for (int ox = 0; ox < inW; ox++, dst += kInputC) {
            const int32_t sx = _mapCols[ox];
            if (sx < 0) { dst[0] = 0.0f; dst[1] = 0.0f; dst[2] = 0.0f; continue; }   // zero border column
            const uint8_t *px = row + (size_t)sx * 4; // BGRA
            dst[0] = px[2] / 255.0f;  // R
            dst[1] = px[1] / 255.0f;  // G
            dst[2] = px[0] / 255.0f;  // B
        }
    }
    return YES;
}

/// RGBA → float RGB [0,1] through the sample maps (nearest-neighbour).
- (BOOL)_convertRGBA:(CVPixelBufferRef)pb into:(float *)out {
    size_t srcW        = CVPixelBufferGetWidth(pb);
    size_t srcH        = CVPixelBufferGetHeight(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    if (!src || srcW == 0 || srcH == 0) return NO;

    [self _ensureSampleMapsForSourceWidth:srcW height:srcH];
    const int    inW       = _inputW, inH = _inputH;
    const size_t rowFloats = (size_t)inW * kInputC;

    for (int oy = 0; oy < inH; oy++) {
        float        *dst = out + (size_t)oy * rowFloats;
        const int32_t sy  = _mapRows[oy];
        if (sy < 0) { memset(dst, 0, rowFloats * sizeof(float)); continue; }
        const uint8_t *row = src + (size_t)sy * bytesPerRow;
        for (int ox = 0; ox < inW; ox++, dst += kInputC) {
            const int32_t sx = _mapCols[ox];
            if (sx < 0) { dst[0] = 0.0f; dst[1] = 0.0f; dst[2] = 0.0f; continue; }
            const uint8_t *px = row + (size_t)sx * 4; // RGBA
            dst[0] = px[0] / 255.0f;  // R
            dst[1] = px[1] / 255.0f;  // G
            dst[2] = px[2] / 255.0f;  // B
        }
    }
    return YES;
}

/// NV12/NV21 (YUV 420 biplanar) → float RGB [0,1] through the sample maps.
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

    [self _ensureSampleMapsForSourceWidth:srcW height:srcH];
    const int    inW       = _inputW, inH = _inputH;
    const size_t rowFloats = (size_t)inW * kInputC;

    for (int oy = 0; oy < inH; oy++) {
        float        *dst = out + (size_t)oy * rowFloats;
        const int32_t sy  = _mapRows[oy];
        if (sy < 0) { memset(dst, 0, rowFloats * sizeof(float)); continue; }

        // UV plane is half-resolution vertically.
        size_t uvy = (size_t)sy / 2;

        const uint8_t *yRow  = yPlane  + (size_t)sy * yStride;
        const uint8_t *uvRow = uvPlane + uvy * uvStride;

        for (int ox = 0; ox < inW; ox++, dst += kInputC) {
            const int32_t sxi = _mapCols[ox];
            if (sxi < 0) { dst[0] = 0.0f; dst[1] = 0.0f; dst[2] = 0.0f; continue; }
            const size_t sx = (size_t)sxi;

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

            dst[0] = R;
            dst[1] = G;
            dst[2] = B;
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
    void              *mapCols = _mapCols;
    void              *mapRows = _mapRows;

    _tflInterpreter = nil;
    _tflModel       = nil;
    _inputScratch   = NULL;
    _mapCols        = NULL;
    _mapRows        = NULL;

    // Phase 9B-6B.1: capture and release pending buffer on _mlQueue.
    // _pendingLock is not needed here — dealloc is single-threaded and no
    // concurrent submitFrame: can reach this object (ARC retain count = 0).
    CVPixelBufferRef pendingCapture = _pendingPixelBuffer;
    _pendingPixelBuffer = nil;

    // Asynchronous teardown on _mlQueue. 'self' is deallocated immediately,
    // but the underlying C/C++ resources are cleaned up safely on the queue
    // that created/used them.
    dispatch_async(_mlQueue, ^{
        if (pendingCapture) { CVPixelBufferRelease(pendingCapture); }
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
        if (mapCols) {
            free(mapCols);
        }
        if (mapRows) {
            free(mapRows);
        }
    });
}

@end
