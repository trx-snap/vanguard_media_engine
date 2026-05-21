// BeautyV2FilterGroup.m
// Phase 4B — Beauty V2: VGFilterGroupNode (Step 3: full 4-pass execution).
//
// Step 3 adds to Step 1 skeleton:
//   - _compilePSOs        — creates 4 MTLComputePipelineState objects at init
//   - processEnvelope:    — 4-encoder single command buffer + waitUntilCompleted
//   - processBuffer:      — thin wrapper calling processEnvelope:
//
// GPU execution contract (DEC-57 / DEC-58):
//   Single MTLCommandBuffer, 4 sequential compute encoders:
//     [1] blur_h    original         → intermediateA  (_beautyPoolA)
//     [2] blur_v    intermediateA    → intermediateB  (_beautyPoolB)
//     [3] highpass  original+B       → intermediateC  (_beautyPoolC)
//     [4] composite original+B+C     → outputBuffer   (_pool)
//   [cmd commit]; [cmd waitUntilCompleted];
//   Intermediates released AFTER waitUntilCompleted — never before (RR-38/39).
//
// CPU parameter sanitization (Step 2 gates):
//   sigma  = max(sigma, 1.0f)     — prevents twoSig2=0 NaN (ISSUE-1)
//   theta  = max(theta, 0.001f)   — prevents 0/0 NaN (ISSUE-3)
//   radius = clamp(radius, 1, 8)  — bounds loop trip-count for video budget
//
// CF ownership discipline (mandatory — RR-43/DEC-58):
//   _beautyPoolA/B/C  — node-local. CFRelease on replace/nil.
//   _pool             — borrowed (no CFRetain). Caller (runtime) owns lifetime.

#import "BeautyV2FilterGroup.h"
#import "VGSegmentationNode.h"
#import "VGSkinMaskGenerator.h"  // Phase 4F: VGSkinMask type for metadata consumption
#import <os/lock.h>
#import <os/log.h>

// ---------------------------------------------------------------------------
// Pool creation helpers
// ---------------------------------------------------------------------------

/// Creates an IOSurface-backed CVPixelBufferPool with the given dimensions.
/// Returns NULL on failure. Caller owns the returned pool (+1 from Create).
static CVPixelBufferPoolRef _Nullable
_VGBeautyCreatePool(size_t width, size_t height) {
    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
    };
    NSDictionary *bufAttrs = @{
        (id)kCVPixelBufferWidthKey:                  @(width),
        (id)kCVPixelBufferHeightKey:                 @(height),
        (id)kCVPixelBufferPixelFormatTypeKey:        @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey:    @{},
        (id)kCVPixelBufferMetalCompatibilityKey:     @YES,
    };
    CVPixelBufferPoolRef pool = NULL;
    CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttrs,
        (__bridge CFDictionaryRef)bufAttrs,
        &pool);
    if (status != kCVReturnSuccess || !pool) {
        return NULL; // caller handles failure
    }
    return pool; // +1 from Create — caller owns
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

@implementation BeautyV2FilterGroup {
    // ── Runtime session output pool (borrowed — DO NOT CFRetain) ─────────────
    CVPixelBufferPoolRef _pool;

    // ── Metal resources ───────────────────────────────────────────────────────
    id<MTLDevice>       _device;
    id<MTLCommandQueue> _queue;

    // ── Pipeline states — one per Beauty V2 pass ──────────────────────────────
    id<MTLComputePipelineState> _psoBlurH;      // Pass 1: vanguard_beauty_blur_h
    id<MTLComputePipelineState> _psoBlurV;      // Pass 2: vanguard_beauty_blur_v
    id<MTLComputePipelineState> _psoHighpass;   // Pass 3: vanguard_beauty_highpass
    id<MTLComputePipelineState> _psoComposite;  // Pass 4: vanguard_beauty_composite

    // ── Node-local intermediate pools (node-owned — CFRelease on teardown) ────
    // _beautyPoolA: blur_h output  (Pass 1 → Pass 2 input)
    // _beautyPoolB: blur_v output  (meanColor; Pass 2 → Pass 3+4 input)
    // _beautyPoolC: highpass output (Pass 3 → Pass 4 input)
    CVPixelBufferPoolRef _beautyPoolA;
    CVPixelBufferPoolRef _beautyPoolB;
    CVPixelBufferPoolRef _beautyPoolC;

    // ── Prepare state ─────────────────────────────────────────────────────────
    size_t _preparedWidth;
    size_t _preparedHeight;
    BOOL   _poolsReady;
    os_unfair_lock _prepareLock;

    // ── Identity (VGMediaNode) ────────────────────────────────────────────────
    NSString *_nodeId;
    NSString *_nodeType;
    NSString *_filterName;
    NSString *_groupName;

    // ── Tunable parameters (Phase 4B Step 5 — property-driven) ───────────────
    BOOL  _useIntensityRamp; // Step 6B: YES = ramp, NO = use explicit params
    float _intensity;        // master slider [0, 1] (Step 6)
    int   _radius;           // Gaussian kernel half-radius [1, 12]
    float _sigma;            // Gaussian std-dev  (≥ 1.0)
    float _smoothStrength;   // smooth blend [0, 1]
    float _sharpenStrength;  // sharpen blend [0, 1]
    float _theta;            // composite luminance denominator (≥ 0.001)
    // Phase 4B.5: range (colour) sigma for bilateral-like blur (DEC-59).
    // Default 0.10. Driven by intensity ramp when useIntensityRamp=YES.
    // Phase 4B.5: wired to Metal blur kernels via BeautyBlurParams.rangeSigma
    float _rangeSigma;       // range sigma (≥ 0.01) — colour-similarity gate
    // Phase 4B.6 (DEC-60): perceptual composite params. CPU-plumbed in Step 1;
    // wired to GPU composite struct in Step 2.
    float _detailDamping;    // [0, 1]    — texture attenuation before add-back
    float _toneStrength;     // [0, 1]    — tone compression intensity
    float _midtoneLift;      // [0, 0.15] — midtone luminance boost

    // ── Phase 4F: mask texture cache (migrated from internal ownership) ────
    // Reusable R8Unorm Metal texture for uploading skin mask received
    // via VGFrameEnvelope.metadata from upstream VGSegmentationNode.
    // Recreated only when mask dimensions change.
    id<MTLTexture> _maskTexture;
    size_t _maskTexWidth;
    size_t _maskTexHeight;

    // ── Phase 4C Step 4: temporal fade + dropout (RR-57) ─────────────────
    // Smooth fade of maskStrength: ramps toward 1.0 when a valid mask exists,
    // ramps toward 0.0 when mask is lost. Prevents hard pop-on/pop-off.
    float _currentMaskStrength;       // current smoothed maskStrength [0,1]
    CFAbsoluteTime _lastValidMaskTime; // wall-clock time of last valid mask
    BOOL _hadMaskLastFrame;           // true if previous frame had a valid mask
}

@synthesize enabled              = _enabled;
@synthesize nodeId               = _nodeId;
@synthesize nodeType             = _nodeType;
@synthesize filterName           = _filterName;
@synthesize groupName            = _groupName;
@synthesize debugOutputPassIndex = _debugOutputPassIndex;
@synthesize useIntensityRamp     = _useIntensityRamp;
@synthesize intensity            = _intensity;
@synthesize radius               = _radius;
@synthesize sigma                = _sigma;
@synthesize smoothStrength       = _smoothStrength;
@synthesize sharpenStrength      = _sharpenStrength;
@synthesize theta                = _theta;
@synthesize rangeSigma           = _rangeSigma;
@synthesize detailDamping        = _detailDamping;
@synthesize toneStrength         = _toneStrength;
@synthesize midtoneLift          = _midtoneLift;
@synthesize faceAwareEnabled     = _faceAwareEnabled;
@synthesize faceSmoothBoost      = _faceSmoothBoost;
@synthesize faceToneBoost        = _faceToneBoost;
@synthesize faceLiftBoost        = _faceLiftBoost;
@synthesize faceDampingReduce    = _faceDampingReduce;
@synthesize faceWhitenStrength   = _faceWhitenStrength;
@synthesize faceRosyStrength     = _faceRosyStrength;
@synthesize faceToneUnifyStrength = _faceToneUnifyStrength;
@synthesize faceGlowStrength     = _faceGlowStrength;
@synthesize featureRestoreStrength = _featureRestoreStrength;
@synthesize featureDetailRestore   = _featureDetailRestore;
@synthesize featureContrastBoost   = _featureContrastBoost;
@synthesize featureSatBoost        = _featureSatBoost;

// ---------------------------------------------------------------------------
// MARK: VGMediaNode topology
// ---------------------------------------------------------------------------

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

// ---------------------------------------------------------------------------
// MARK: VGMetalFilterNode cost model
// ---------------------------------------------------------------------------

// Beauty V2 runs 4 sequential compute encoders — more expensive than V1.
// DEC-56 / DEC-58 / Phase4B plan §G.4.
- (BOOL)isExpensive {
    return YES; // enables thermal-policy disable at Serious tier
}

- (float)estimatedGPUCostMs {
    return 10.5f; // Phase 4C: +0.5ms for mask sample + mix (DEC-65)
}

// ---------------------------------------------------------------------------
// MARK: VGFilterGroupNode properties
// ---------------------------------------------------------------------------

- (NSInteger)passCount {
    return 4;
}

// ---------------------------------------------------------------------------
// MARK: Init
// ---------------------------------------------------------------------------

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;

    // Runtime session output pool — borrowed; DO NOT CFRetain (matches V1 convention).
    _pool   = pool;
    _device = device;
    _queue  = [device newCommandQueue];
    [self _compilePSOs];

    _enabled             = YES;
    _poolsReady          = NO;
    _preparedWidth       = 0;
    _preparedHeight      = 0;
    _prepareLock         = OS_UNFAIR_LOCK_INIT;
    _debugOutputPassIndex = -1;

    // ── Beauty V2 parameter defaults (Phase 4B Step 5 / Step 6) ───────────────
    // intensity = 0.75 maps to the named property defaults below via the ramp
    // in processEnvelope:. Individual properties can still be used directly
    // when useIntensityRamp = NO.
    _useIntensityRamp = YES;    // Step 6B: ramp ON by default
    _intensity        = 0.75f;  // master slider default
    _radius           = 10;     // Gaussian half-radius (clamp: [1, 12])
    _sigma            = 5.5f;   // Gaussian std-dev    (clamp: ≥ 1.0)
    _smoothStrength   = 0.90f;  // smooth blend
    _sharpenStrength  = 0.25f;  // sharpening blend
    _theta            = 0.06f;  // composite luminance denom (clamp: ≥ 0.001)
    _rangeSigma       = 0.10f;  // Phase 4B.5: range sigma default (DEC-59)
    _detailDamping    = 0.55f;  // Phase 4B.6: texture attenuation (DEC-60) — tuned baseline
    _toneStrength     = 0.25f;  // Phase 4B.6: tone compression (DEC-60)
    _midtoneLift      = 0.045f; // Phase 4B.6: midtone lift (DEC-60) — tuned baseline

    // Phase 4F (DEC-100): face detection and mask generation are now owned by
    // VGSegmentationNode. BeautyV2FilterGroup consumes mask data from
    // envelope.metadata — no internal detection/generation provider.

    // Phase 4C: face-aware mode OFF by default — production behavior is 4B.6.
    _faceAwareEnabled = NO;

    // Phase 4C.1 (DEC-66/67): face-weighted boost defaults.
    // Tuned values per Phase4C_1_FaceWeightedBeautyBoost.md §7.1 (final QA baseline).
    // Only consumed when faceAwareEnabled=YES and hasMask>0.
    _faceSmoothBoost   = 0.80f;
    _faceToneBoost     = 0.36f;
    _faceLiftBoost     = 0.080f;
    _faceDampingReduce = 0.30f;

    // Phase 4C.2 (DEC-70/71): color aesthetic layer defaults.
    // Conservative starting values per Phase4C_2_SkinColorAestheticLayer.md §6.1.
    // Only consumed when faceAwareEnabled=YES and hasMask>0.
    _faceWhitenStrength    = 0.15f;
    _faceRosyStrength      = 0.20f;
    _faceToneUnifyStrength = 0.27f;
    _faceGlowStrength      = 0.16f;

    // Phase 4C.3 (DEC-76/78): feature protection & enhancement defaults.
    // Tuned values per Phase4C_3_FeatureProtectionEnhancement.md §6.1.
    // Only consumed when faceAwareEnabled=YES and hasMask>0.
    _featureRestoreStrength = 0.45f;
    _featureDetailRestore   = 0.38f;
    _featureContrastBoost   = 0.28f;
    _featureSatBoost        = 0.20f;

    // Phase 4D (DEC-87): perceptual feature enhancement production defaults.
    // Tuned values derived from Step 5 QA — natural output preserved.
    // Only consumed when faceAwareEnabled=YES and hasMask>0.
    _eyeEnhanceStrength  = 0.25f;
    _lipEnhanceStrength  = 0.20f;
    _browEnhanceStrength = 0.12f;

    // Phase 4E (DEC-91): tone polish layer — defaults = 0 (identity).
    // Opt-in finishing layer; output = exact 4D when all are 0.
    _polishGlowStrength   = 0.0f;
    _polishSmoothStrength = 0.0f;
    _polishWarmthStrength = 0.0f;
    _polishBloomStrength  = 0.0f;

    // Phase 4C Step 4 (RR-57): temporal fade state — starts at 0 (no mask).
    _currentMaskStrength = 0.0f;
    _lastValidMaskTime   = 0;
    _hadMaskLastFrame    = NO;

    // Node-local pools start as NULL — created in prepareWithWidth:height:device:error:
    _beautyPoolA = NULL;
    _beautyPoolB = NULL;
    _beautyPoolC = NULL;

    // Identity
    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"BeautyV2FilterGroup";
    _filterName = @"BeautyV2";
    _groupName  = @"BeautyV2";

    return self;
}

- (void)dealloc {
    // Release node-local pools explicitly (CFRelease — not ARC).
    if (_beautyPoolA) { CFRelease(_beautyPoolA); _beautyPoolA = NULL; }
    if (_beautyPoolB) { CFRelease(_beautyPoolB); _beautyPoolB = NULL; }
    if (_beautyPoolC) { CFRelease(_beautyPoolC); _beautyPoolC = NULL; }
    // _pool is borrowed — do NOT release.
    _queue  = nil;
    _device = nil;
}

// ---------------------------------------------------------------------------
// MARK: prepareWithWidth:height:device:error:
// ---------------------------------------------------------------------------

- (BOOL)prepareWithWidth:(size_t)width
                  height:(size_t)height
                  device:(id<MTLDevice>)device
                   error:(NSError *__autoreleasing _Nullable *_Nullable)error {
    os_unfair_lock_lock(&_prepareLock);

    // Idempotent: same dimensions and device — already prepared, nothing to do.
    if (_poolsReady &&
        _preparedWidth  == width  &&
        _preparedHeight == height &&
        _device == device) {
        os_unfair_lock_unlock(&_prepareLock);
        return YES;
    }

    // Dimensions changed or first call — tear down old pools before rebuilding.
    if (_beautyPoolA) { CFRelease(_beautyPoolA); _beautyPoolA = NULL; }
    if (_beautyPoolB) { CFRelease(_beautyPoolB); _beautyPoolB = NULL; }
    if (_beautyPoolC) { CFRelease(_beautyPoolC); _beautyPoolC = NULL; }
    _poolsReady = NO;

    // Update device ref if changed (rare — usually same device across sessions).
    _device = device;

    // Create Pool A (blur_h output).
    CVPixelBufferPoolRef poolA = _VGBeautyCreatePool(width, height);
    if (!poolA) {
        os_unfair_lock_unlock(&_prepareLock);
        if (error) {
            *error = [NSError errorWithDomain:@"BeautyV2FilterGroup"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"[BeautyV2] Failed to create _beautyPoolA"
            }];
        }
        return NO;
    }

    // Create Pool B (blur_v / meanColor output).
    CVPixelBufferPoolRef poolB = _VGBeautyCreatePool(width, height);
    if (!poolB) {
        CFRelease(poolA);
        os_unfair_lock_unlock(&_prepareLock);
        if (error) {
            *error = [NSError errorWithDomain:@"BeautyV2FilterGroup"
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"[BeautyV2] Failed to create _beautyPoolB"
            }];
        }
        return NO;
    }

    // Create Pool C (highpass output).
    CVPixelBufferPoolRef poolC = _VGBeautyCreatePool(width, height);
    if (!poolC) {
        CFRelease(poolA);
        CFRelease(poolB);
        os_unfair_lock_unlock(&_prepareLock);
        if (error) {
            *error = [NSError errorWithDomain:@"BeautyV2FilterGroup"
                                         code:3
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"[BeautyV2] Failed to create _beautyPoolC"
            }];
        }
        return NO;
    }

    // All three pools created — assign (node owns +1 from each Create call).
    _beautyPoolA    = poolA;
    _beautyPoolB    = poolB;
    _beautyPoolC    = poolC;
    _preparedWidth  = width;
    _preparedHeight = height;
    _poolsReady     = YES;

    os_unfair_lock_unlock(&_prepareLock);
    return YES;
}

// ---------------------------------------------------------------------------
// MARK: invalidate (VGMediaNode + VanguardFilterNode)
// ---------------------------------------------------------------------------

- (void)invalidate {
    // Release all node-local pools via CFRelease (not ARC — CF type).
    // No async GPU drain needed for synchronous MVP (DEC-58 — waitUntilCompleted
    // ensures GPU is done before processEnvelope: returns, so pools are never
    // in use when invalidate fires after chain removal).
    os_unfair_lock_lock(&_prepareLock);
    if (_beautyPoolA) { CFRelease(_beautyPoolA); _beautyPoolA = NULL; }
    if (_beautyPoolB) { CFRelease(_beautyPoolB); _beautyPoolB = NULL; }
    if (_beautyPoolC) { CFRelease(_beautyPoolC); _beautyPoolC = NULL; }
    _poolsReady = NO;
    os_unfair_lock_unlock(&_prepareLock);

    // Phase 4F (DEC-100): face detection and mask generation are now owned by
    // VGSegmentationNode — no teardown needed here.

    // Phase 4C (DEC-63): release cached mask texture.
    _maskTexture = nil;
    _maskTexWidth = 0;
    _maskTexHeight = 0;


}

// ---------------------------------------------------------------------------
// MARK: prepareWithCompletion: (VGMediaNode legacy hook)
// ---------------------------------------------------------------------------

// Structural guard: validates that _pool is non-NULL before any
// processEnvelope: call. Mirrors VanguardLUTFilterNode pattern (DEC-49).
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))completion {
    if (!_pool) {
        NSError *err = [NSError
            errorWithDomain:@"BeautyV2FilterGroup"
                       code:10
                   userInfo:@{
            NSLocalizedDescriptionKey:
                @"[BeautyV2] prepareWithCompletion: _pool is NULL — "
                @"initWithPool:device: must provide a non-NULL pool"
        }];
        if (completion) completion(err);
        return;
    }
    if (completion) completion(nil);
}

// ---------------------------------------------------------------------------
// MARK: _compilePSOs
// ---------------------------------------------------------------------------

- (void)_compilePSOs {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSError  *err    = nil;
    id<MTLLibrary> lib = [_device newDefaultLibraryWithBundle:bundle error:&err];
    if (!lib) {
        os_log_error(OS_LOG_DEFAULT, "[BeautyV2] Metal library load failed: %{public}@", err);
        return;
    }
    NSDictionary *kernels = @{
        @"vanguard_beauty_blur_h":   @"_psoBlurH",
        @"vanguard_beauty_blur_v":   @"_psoBlurV",
        @"vanguard_beauty_highpass": @"_psoHighpass",
        @"vanguard_beauty_composite":@"_psoComposite",
    };
    for (NSString *name in kernels) {
        id<MTLFunction> fn = [lib newFunctionWithName:name];
        if (!fn) {
            os_log_error(OS_LOG_DEFAULT, "[BeautyV2] kernel not found: %{public}@", name);
            continue;
        }
        NSError *psoErr = nil;
        id<MTLComputePipelineState> pso = [_device newComputePipelineStateWithFunction:fn
                                                                                 error:&psoErr];
        if (!pso) {
            os_log_error(OS_LOG_DEFAULT, "[BeautyV2] PSO compile failed %{public}@: %{public}@",
                         name, psoErr);
            continue;
        }
        [self setValue:pso forKey:kernels[name]];
    }
}

// ---------------------------------------------------------------------------
// MARK: _makeTextureFromBuffer:usage: (helper)
// ---------------------------------------------------------------------------

/// Wraps an IOSurface-backed CVPixelBuffer as a Metal texture.
/// Returns nil if the buffer has no IOSurface or if its dimensions/stride
/// cannot support the requested w×h BGRA8 texture (Phase 6A-3F-R1 guard).
static id<MTLTexture> _Nullable
_VGMakeTexture(id<MTLDevice> device, CVPixelBufferRef buf,
               MTLTextureUsage usage, size_t w, size_t h) {
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(buf);
    if (!surf) return nil;

    // ── Phase 6A-3F-R1: IOSurface dimension preflight ────────────────────────
    // Metal aborts if bytesPerRow of the IOSurface is less than what the
    // requested texture descriptor requires. Validate before calling Metal.
    OSType fmt       = CVPixelBufferGetPixelFormatType(buf);
    size_t bufW      = CVPixelBufferGetWidth(buf);
    size_t bufH      = CVPixelBufferGetHeight(buf);
    size_t bufBPR    = CVPixelBufferGetBytesPerRow(buf);
    // Guard against overflow: w * 4 must not wrap.
    size_t reqBPR    = (w <= (SIZE_MAX / 4)) ? (w * 4) : SIZE_MAX;

    if (fmt != kCVPixelFormatType_32BGRA ||
        bufW < w || bufH < h || bufBPR < reqBPR) {
        os_log_error(OS_LOG_DEFAULT,
            "[BeautyV2-3F-R1] IOSurface stride mismatch — refusing texture creation. "
            "requested: %zu×%zu reqBPR=%zu | buffer: %zu×%zu bpr=%zu fmt=0x%X",
            w, h, reqBPR, bufW, bufH, bufBPR, (unsigned)fmt);
        return nil;
    }
    // ─────────────────────────────────────────────────────────────────────────

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = usage;
    return [device newTextureWithDescriptor:td iosurface:surf plane:0];
}

// ---------------------------------------------------------------------------
// MARK: processEnvelope:device: (VGMetalFilterNode)
// ---------------------------------------------------------------------------
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    // ── Gate 1: disabled → immediate passthrough ──────────────────────────────
    if (!_enabled) return envelope;

    // ── Gate 2: PSOs not compiled → passthrough ───────────────────────────────
    if (!_psoBlurH || !_psoBlurV || !_psoHighpass || !_psoComposite) return envelope;

    // ── Gate 3: nil input → passthrough ───────────────────────────────────────
    CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!input) return envelope;

    // ── Lazy prepare (RR-43) ───────────────────────────────────────────────────
    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);
    BOOL needsPrepare = NO;
    os_unfair_lock_lock(&_prepareLock);
    needsPrepare = (!_poolsReady || _preparedWidth != w || _preparedHeight != h);
    os_unfair_lock_unlock(&_prepareLock);
    if (needsPrepare) {
        NSError *prepErr = nil;
        if (![self prepareWithWidth:w height:h device:device error:&prepErr]) {
            os_log_error(OS_LOG_DEFAULT, "[BeautyV2] lazy prepare failed: %{public}@",
                         prepErr.localizedDescription);
            VGFrameEnvelope failed = envelope;
            failed.payload.videoBuffer = NULL;
            return failed;
        }
    }

    // ── Phase 4F: mask metadata consumption from VGSegmentationNode (DEC-100) ──
    // Face detection and mask generation are now owned by VGSegmentationNode.
    // When faceAwareEnabled=YES, read mask data from envelope.metadata.
    // When NO, hasMask=0 → exact 4B.6 output (no mask influence).

    // ── Intensity → parameter mapping (Step 6B) ──────────────────────────────────
    // Runs ONLY when useIntensityRamp == YES (playground slider path).
    // When NO, explicit granular params set by runtime are preserved.
    if (_useIntensityRamp) {
        float t = _intensity < 0.0f ? 0.0f : (_intensity > 1.0f ? 1.0f : _intensity);
        _radius          = (int)roundf(1.0f + t * (12.0f - 1.0f));  // unchanged
        _sigma           = 1.0f + t * 7.5f;                         // stronger blur
        _smoothStrength  = t * 1.40f;                                // stronger blend authority
        _theta           = 0.02f + t * 0.03f;                       // less aggressive edge suppression
        _sharpenStrength = 0.35f - t * 0.20f;                       // less detail restore at high intensity
        // Phase 4B.5 (DEC-59): tighten range gate at high intensity to protect edges.
        // Wide (0.20) at t=0 → behaves like spatial Gaussian (no visual change yet).
        // Tight (0.08) at t=1 → only colour-similar neighbours contribute.
        // Phase 4B.5: rangeSigma is wired into blurParams and consumed by both bilateral blur kernels.
        _rangeSigma      = 0.20f - t * (0.20f - 0.08f);            // [0.20, 0.08]
        // Phase 4B.6 (DEC-60): perceptual composite ramp — wired to GPU.
        _detailDamping   = 1.0f - t * 0.50f;                       // [1.0, 0.5]
        _toneStrength    = t * 0.30f;                               // [0, 0.3]
        _midtoneLift     = t * 0.06f;                               // [0, 0.06]
    }

    // ── CPU parameter sanitization ────────────────────────────────────────────
    // Read from properties (now updated by intensity ramp above, or by direct
    // caller assignment). Clamp to safe ranges before GPU uniform construction.
    // Clamp ranges (RR-38 §sanitization / ISSUE-1 / ISSUE-3):
    //   radius  → [1, 12]   (kernel size; upper bound matches header contract)
    //   sigma   → ≥ 1.0     (prevents exp(-x/0) NaN in Gaussian weight)
    //   theta   → ≥ 0.001   (prevents divide-by-zero in composite luminance)
    // Phase 4B.5: sanitize rangeSigma now; wire to GPU uniform in Step 2.
    float rangeSigma = MAX(_rangeSigma, 0.01f); // prevents exp(-x/0) NaN (DEC-59)
    // (void) suppressor removed — rangeSigma is now consumed by blurParams below.

    // Phase 4B.6 (DEC-60): sanitize perceptual params before GPU dispatch.
    float detailDamping = fminf(fmaxf(_detailDamping, 0.0f), 1.0f);
    float toneStrength  = fminf(fmaxf(_toneStrength,  0.0f), 1.0f);
    float midtoneLift   = fminf(fmaxf(_midtoneLift,   0.0f), 0.15f);

    // Phase 4C.1 (DEC-66/67): sanitize face-boost params before GPU dispatch.
    float faceSmoothBoost   = fminf(fmaxf(_faceSmoothBoost,   0.0f), 1.0f);  // RR-60
    float faceToneBoost     = fminf(fmaxf(_faceToneBoost,     0.0f), 0.7f);
    float faceLiftBoost     = fminf(fmaxf(_faceLiftBoost,     0.0f), 0.10f); // RR-62
    float faceDampingReduce = fminf(fmaxf(_faceDampingReduce, 0.0f), 0.5f);

    // Phase 4C.2 (DEC-70/71): sanitize color aesthetic params before GPU dispatch.
    float faceWhitenStrength    = fminf(fmaxf(_faceWhitenStrength,    0.0f), 1.0f);  // RR-65
    float faceRosyStrength      = fminf(fmaxf(_faceRosyStrength,      0.0f), 1.0f);  // RR-67
    float faceToneUnifyStrength = fminf(fmaxf(_faceToneUnifyStrength, 0.0f), 1.0f);  // RR-69
    float faceGlowStrength      = fminf(fmaxf(_faceGlowStrength,      0.0f), 1.0f);

    // Phase 4C.3 (DEC-76/78): sanitize feature params before GPU dispatch.
    float featureRestoreStrength = fminf(fmaxf(_featureRestoreStrength, 0.0f), 1.0f);  // RR-75
    float featureDetailRestore   = fminf(fmaxf(_featureDetailRestore,   0.0f), 1.0f);
    float featureContrastBoost   = fminf(fmaxf(_featureContrastBoost,   0.0f), 1.0f);  // RR-71
    float featureSatBoost        = fminf(fmaxf(_featureSatBoost,        0.0f), 1.0f);  // RR-73

    // Phase 4D (DEC-89): sanitize enhance params — hard guardrails prevent artifacts.
    float eyeEnhanceStrength  = fminf(fmaxf(_eyeEnhanceStrength,  0.0f), 0.35f);  // RR-77
    float lipEnhanceStrength  = fminf(fmaxf(_lipEnhanceStrength,  0.0f), 0.30f);  // RR-78
    float browEnhanceStrength = fminf(fmaxf(_browEnhanceStrength, 0.0f), 0.15f);  // RR-79

    // Phase 4E (DEC-90/92/98): sanitize polish params — production guardrails.
    float polishGlowStrength   = fminf(fmaxf(_polishGlowStrength,   0.0f), 0.40f);  // DEC-98
    float polishSmoothStrength = fminf(fmaxf(_polishSmoothStrength, 0.0f), 0.25f);  // DEC-98
    float polishWarmthStrength = fminf(fmaxf(_polishWarmthStrength, 0.0f), 0.18f);  // DEC-98
    float polishBloomStrength  = fminf(fmaxf(_polishBloomStrength,  0.0f), 0.12f);  // DEC-98

    // CPU struct must match Metal BeautyBlurParams EXACTLY (layout: 4+4+4 = 12 bytes).
    struct { int radius; float sigma; float rangeSigma; } blurParams = {
        .radius     = (int)MAX(1, MIN(_radius, 12)),
        .sigma      = MAX(_sigma, 1.0f),    // ISSUE-1: prevents NaN
        .rangeSigma = rangeSigma,           // Phase 4B.5: wired to bilateral kernel
    };

    // ── Phase 4F: read mask from envelope.metadata (DEC-100/101/102) ──────────
    // Mask data is produced by VGSegmentationNode and attached to the envelope
    // as an NSDictionary. We read it here for GPU upload.
    //
    // Phase 4C Step 4 (RR-57): temporal fade-in/fade-out + dropout hold.
    static const float kMaskFadeSpeed      = 0.15f;
    static const float kMaskHoldDurationS  = 0.15f;  // 150ms

    // ── Extract mask from metadata ───────────────────────────────────────────
    // maskValid: set to YES if a usable mask was found and texture was uploaded.
    // maskFaceCount: used for temporal fade logic below.
    BOOL maskValid = NO;
    NSInteger maskFaceCount = 0;

    if (_faceAwareEnabled && envelope.metadata != NULL) {
        NSDictionary *meta = (__bridge NSDictionary *)envelope.metadata;
        if ([meta isKindOfClass:[NSDictionary class]]) {
            NSInteger fc = [meta[VGSegmentationMetadataKeyFaceCount] integerValue];

            // ── Primary path: CVPixelBufferRef R8 (DEC-121) ─────────────────
            // VGSegmentationNode now produces a CVPixelBufferRef under
            // VGSegmentationMetadataKeySkinMaskBuffer. Read and upload inside
            // the lock so maskData is never accessed after unlock.
            id maskBufObj = meta[VGSegmentationMetadataKeySkinMaskBuffer];
            if (maskBufObj) {
                CVPixelBufferRef maskBuf = (__bridge CVPixelBufferRef)maskBufObj;
                size_t bufW = CVPixelBufferGetWidth(maskBuf);
                size_t bufH = CVPixelBufferGetHeight(maskBuf);
                if (bufW > 0 && bufH > 0 && fc > 0) {
                    CVPixelBufferLockBaseAddress(maskBuf, kCVPixelBufferLock_ReadOnly);
                    const uint8_t *baseAddr =
                        (const uint8_t *)CVPixelBufferGetBaseAddress(maskBuf);
                    size_t bpr = CVPixelBufferGetBytesPerRow(maskBuf);
                    if (baseAddr) {
                        // Recreate texture inside lock if dimensions changed.
                        if (!_maskTexture || _maskTexWidth != bufW || _maskTexHeight != bufH) {
                            MTLTextureDescriptor *desc = [MTLTextureDescriptor
                                texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                            width:bufW
                                                           height:bufH
                                                        mipmapped:NO];
                            desc.usage = MTLTextureUsageShaderRead;
                            desc.storageMode = MTLStorageModeShared;
                            _maskTexture = [device newTextureWithDescriptor:desc];
                            _maskTexWidth = bufW;
                            _maskTexHeight = bufH;
                        }
                        // Upload — replaceRegion: copies bytes synchronously.
                        // maskData is valid here: we are inside the lock.
                        if (_maskTexture) {
                            [_maskTexture replaceRegion:MTLRegionMake2D(0, 0, bufW, bufH)
                                           mipmapLevel:0
                                             withBytes:baseAddr
                                           bytesPerRow:bpr];
                        }
                        maskValid = (_maskTexture != nil);
                        maskFaceCount = fc;
                    }
                    CVPixelBufferUnlockBaseAddress(maskBuf, kCVPixelBufferLock_ReadOnly);
                }

            } else {
                // ── Legacy fallback: VGSkinMask * (DEC-110) ─────────────────
                // Used when the new key is absent (CVPixelBuffer creation failure
                // path, or pre-migration consumers).
                VGSkinMask *skinMask = meta[VGSegmentationMetadataKeySkinMask];
                if (skinMask && [skinMask isKindOfClass:[VGSkinMask class]]) {
                    if (skinMask.width > 0 && skinMask.height > 0 &&
                        skinMask.data != NULL && skinMask.faceCount > 0) {
                        // Recreate texture if dimensions changed.
                        if (!_maskTexture ||
                            _maskTexWidth  != skinMask.width ||
                            _maskTexHeight != skinMask.height) {
                            MTLTextureDescriptor *desc = [MTLTextureDescriptor
                                texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                            width:skinMask.width
                                                           height:skinMask.height
                                                        mipmapped:NO];
                            desc.usage = MTLTextureUsageShaderRead;
                            desc.storageMode = MTLStorageModeShared;
                            _maskTexture = [device newTextureWithDescriptor:desc];
                            _maskTexWidth  = skinMask.width;
                            _maskTexHeight = skinMask.height;
                        }
                        if (_maskTexture) {
                            [_maskTexture replaceRegion:MTLRegionMake2D(
                                                    0, 0, skinMask.width, skinMask.height)
                                           mipmapLevel:0
                                             withBytes:skinMask.data
                                           bytesPerRow:skinMask.bytesPerRow];
                        }
                        maskValid = (_maskTexture != nil);
                        maskFaceCount = skinMask.faceCount;
                    }
                }
            }
        }
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    if (maskValid) {
        // ── Valid mask: texture already uploaded above ─────────────────────
        _lastValidMaskTime = now;
        _hadMaskLastFrame = YES;

        // Fade-in: ramp toward 1.0.
        _currentMaskStrength = fminf(_currentMaskStrength + kMaskFadeSpeed, 1.0f);
    } else {
        // ── No valid mask ──────────────────────────────────────────────────
        if (_hadMaskLastFrame && (now - _lastValidMaskTime) < kMaskHoldDurationS) {
            // Dropout hold: keep last mask texture + current strength for grace period.
            // No ramp change — hold stable to ride out momentary detection gaps.
        } else {
            // Fade-out: ramp toward 0.0.
            _currentMaskStrength = fmaxf(_currentMaskStrength - kMaskFadeSpeed, 0.0f);
            if (_currentMaskStrength <= 0.0f) {
                _hadMaskLastFrame = NO;
            }
        }
    }

    // Derive GPU params from smoothed strength.
    // Thread-safety: snapshot _maskTexture into a local strong reference.
    // invalidate (main thread) can nil _maskTexture at any time; a bare ivar
    // read here races with that write and can pass nil to Metal's setTexture:,
    // which throws an exception that permanently freezes video (RR-74 fix).
    id<MTLTexture> maskTex = _maskTexture;
    float hasMask     = (_currentMaskStrength > 0.001f && maskTex) ? 1.0f : 0.0f;
    float maskStrength = _currentMaskStrength;

    // CPU struct must match Metal BeautyCompositeParams EXACTLY (layout: 28×float = 112 bytes).
    // Phase 4C.1 (DEC-66): expanded from 8 to 12 floats (4 face-boost offsets).
    // Phase 4C.2 (DEC-75): expanded from 12 to 16 floats (4 color aesthetic params).
    // Phase 4C.3 (DEC-81): expanded from 16 to 20 floats (4 feature params).
    // Phase 4D  (DEC-84): expanded from 20 to 24 floats (3 enhance params + 1 padding).
    // Phase 4E  (DEC-92): expanded from 24 to 28 floats (4 polish params + 1 padding).
    struct { float smoothStrength; float sharpenStrength; float theta;
             float detailDamping; float toneStrength; float midtoneLift;
             float hasMask; float maskStrength;
             float faceSmoothBoost; float faceToneBoost;
             float faceLiftBoost; float faceDampingReduce;
             float faceWhitenStrength; float faceRosyStrength;
             float faceToneUnifyStrength; float faceGlowStrength;
             float featureRestoreStrength; float featureDetailRestore;
             float featureContrastBoost; float featureSatBoost;
             float eyeEnhanceStrength; float lipEnhanceStrength;
             float browEnhanceStrength;
             float polishGlowStrength; float polishSmoothStrength;
             float polishWarmthStrength; float polishBloomStrength;
             float _pad1; }
        compositeParams = {
        .smoothStrength  = MAX(0.0f, MIN(_smoothStrength, 1.4f)),  // RR-38: defensive clamp
        .sharpenStrength = MAX(0.0f, MIN(_sharpenStrength, 0.5f)), // RR-38: defensive clamp
        .theta           = MAX(_theta, 0.001f), // ISSUE-3: prevents NaN
        .detailDamping   = detailDamping,        // Phase 4B.6: texture attenuation
        .toneStrength    = toneStrength,          // Phase 4B.6: tone compression
        .midtoneLift     = midtoneLift,           // Phase 4B.6: midtone lift
        .hasMask         = hasMask,               // Phase 4C: 0 = no mask, >0 = mask active
        .maskStrength    = maskStrength,           // Phase 4C: smoothed mask influence [0,1]
        // Phase 4C.1 (DEC-66/67): face-weighted boost offsets.
        // Sanitized above; consumed by GPU when hasMask>0 (DEC-69: fallback preserved).
        .faceSmoothBoost   = faceSmoothBoost,
        .faceToneBoost     = faceToneBoost,
        .faceLiftBoost     = faceLiftBoost,
        .faceDampingReduce = faceDampingReduce,
        // Phase 4C.2 (DEC-70/75): color aesthetic layer.
        // Sanitized above; consumed by GPU when hasMask>0 (DEC-74: fallback preserved).
        .faceWhitenStrength    = faceWhitenStrength,
        .faceRosyStrength      = faceRosyStrength,
        .faceToneUnifyStrength = faceToneUnifyStrength,
        .faceGlowStrength      = faceGlowStrength,
        // Phase 4C.3 (DEC-76/81): feature protection & enhancement.
        // Sanitized above; consumed by GPU when hasMask>0 (DEC-80: fallback preserved).
        .featureRestoreStrength = featureRestoreStrength,
        .featureDetailRestore   = featureDetailRestore,
        .featureContrastBoost   = featureContrastBoost,
        .featureSatBoost        = featureSatBoost,
        // Phase 4D (DEC-82/84): perceptual feature enhancement.
        // Sanitized above; consumed by GPU when hasMask>0 (DEC-85: fallback preserved).
        .eyeEnhanceStrength  = eyeEnhanceStrength,
        .lipEnhanceStrength  = lipEnhanceStrength,
        .browEnhanceStrength = browEnhanceStrength,
        // Phase 4E (DEC-90/92): tone polish layer.
        // Defaults = 0.0 (identity — exact 4D output, DEC-91).
        // Will be wired to runtime/Dart in Step 3.
        .polishGlowStrength   = polishGlowStrength,
        .polishSmoothStrength = polishSmoothStrength,
        .polishWarmthStrength = polishWarmthStrength,
        .polishBloomStrength  = polishBloomStrength,
        ._pad1                = 0.0f,
    };

    // Phase 4C.3: log active feature params when face-aware mask is engaged.
    if (hasMask > 0.0f) {
        os_log_debug(OS_LOG_DEFAULT,
            "[BeautyV2] 4C.3 feature: restore=%.2f detail=%.2f contrast=%.2f sat=%.2f",
            featureRestoreStrength, featureDetailRestore, featureContrastBoost, featureSatBoost);
    }

    // ── Snapshot pools under lock (RR-85 v2: CFRetain prevents use-after-free) ─
    // invalidate can CFRelease _beautyPoolA/B/C on another thread at any time.
    // Snapshot + retain under _prepareLock so the pools survive for the duration
    // of GPU work. The lock is NOT held during encoding or waitUntilCompleted.
    CVPixelBufferPoolRef poolA = NULL;
    CVPixelBufferPoolRef poolB = NULL;
    CVPixelBufferPoolRef poolC = NULL;

    os_unfair_lock_lock(&_prepareLock);
    if (_beautyPoolA && _beautyPoolB && _beautyPoolC) {
        poolA = (CVPixelBufferPoolRef)CFRetain(_beautyPoolA);
        poolB = (CVPixelBufferPoolRef)CFRetain(_beautyPoolB);
        poolC = (CVPixelBufferPoolRef)CFRetain(_beautyPoolC);
    }
    os_unfair_lock_unlock(&_prepareLock);

    if (!poolA || !poolB || !poolC) {
        if (poolA) CFRelease(poolA);
        if (poolB) CFRelease(poolB);
        if (poolC) CFRelease(poolC);
        os_log_error(OS_LOG_DEFAULT, "[BeautyV2] pools unavailable during processing — passthrough");
        return envelope;
    }

    // ── Acquire intermediate buffers from retained local pools ────────────────
    // RR-38: every early-return below releases all buffers acquired so far.
    // RR-39: NO buffer released before waitUntilCompleted returns.
    CVPixelBufferRef bufA = NULL, bufB = NULL, bufC = NULL, output = NULL;

    if (CVPixelBufferPoolCreatePixelBuffer(nil, poolA, &bufA) != kCVReturnSuccess) {
        CFRelease(poolA); CFRelease(poolB); CFRelease(poolC);
        os_log_error(OS_LOG_DEFAULT, "[BeautyV2] pool A exhausted");
        VGFrameEnvelope f = envelope; f.payload.videoBuffer = NULL; return f;
    }
    if (CVPixelBufferPoolCreatePixelBuffer(nil, poolB, &bufB) != kCVReturnSuccess) {
        CVPixelBufferRelease(bufA);
        CFRelease(poolA); CFRelease(poolB); CFRelease(poolC);
        os_log_error(OS_LOG_DEFAULT, "[BeautyV2] pool B exhausted");
        VGFrameEnvelope f = envelope; f.payload.videoBuffer = NULL; return f;
    }
    if (CVPixelBufferPoolCreatePixelBuffer(nil, poolC, &bufC) != kCVReturnSuccess) {
        CVPixelBufferRelease(bufA); CVPixelBufferRelease(bufB);
        CFRelease(poolA); CFRelease(poolB); CFRelease(poolC);
        os_log_error(OS_LOG_DEFAULT, "[BeautyV2] pool C exhausted");
        VGFrameEnvelope f = envelope; f.payload.videoBuffer = NULL; return f;
    }
    if (CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &output) != kCVReturnSuccess) {
        CVPixelBufferRelease(bufA); CVPixelBufferRelease(bufB); CVPixelBufferRelease(bufC);
        CFRelease(poolA); CFRelease(poolB); CFRelease(poolC);
        os_log_error(OS_LOG_DEFAULT, "[BeautyV2] output pool exhausted");
        VGFrameEnvelope f = envelope; f.payload.videoBuffer = NULL; return f;
    }

    // Pool snapshots no longer needed — buffers are independently retained.
    CFRelease(poolA); CFRelease(poolB); CFRelease(poolC);

    // ── Make Metal textures ───────────────────────────────────────────────────
    const MTLTextureUsage kRW = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> texIn  = _VGMakeTexture(device, input,  MTLTextureUsageShaderRead, w, h);
    id<MTLTexture> texA   = _VGMakeTexture(device, bufA,   kRW,                       w, h);
    id<MTLTexture> texB   = _VGMakeTexture(device, bufB,   kRW,                       w, h);
    id<MTLTexture> texC   = _VGMakeTexture(device, bufC,   kRW,                       w, h);
    id<MTLTexture> texOut = _VGMakeTexture(device, output, MTLTextureUsageShaderWrite, w, h);

    if (!texIn || !texA || !texB || !texC || !texOut) {
        CVPixelBufferRelease(bufA); CVPixelBufferRelease(bufB);
        CVPixelBufferRelease(bufC); CVPixelBufferRelease(output);
        // Return original envelope as passthrough so the preview continues.
        // The stride-mismatch case (camera switch) is already logged by
        // _VGMakeTexture with [BeautyV2-3F-R1]; no additional log here.
        return envelope;
    }

    // ── GPU uniform buffers ───────────────────────────────────────────────────
    id<MTLBuffer> blurBuf = [device newBufferWithBytes:&blurParams
                                                length:sizeof(blurParams)
                                               options:MTLResourceStorageModeShared];
    id<MTLBuffer> compBuf = [device newBufferWithBytes:&compositeParams
                                                length:sizeof(compositeParams)
                                               options:MTLResourceStorageModeShared];

    // ── Single command buffer — 4 sequential encoders (DEC-56 / DEC-57) ───────
    MTLSize grid = MTLSizeMake(w, h, 1);
    MTLSize tg   = MTLSizeMake(8, 8, 1);
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];

    // Pass 1: blur_h — original → intermediateA
    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:_psoBlurH];
        [enc setTexture:texIn atIndex:0];
        [enc setTexture:texA  atIndex:1];
        [enc setBuffer:blurBuf offset:0 atIndex:0];
        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];
    }
    // Pass 2: blur_v — intermediateA → intermediateB (meanColor)
    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:_psoBlurV];
        [enc setTexture:texA atIndex:0];
        [enc setTexture:texB atIndex:1];
        [enc setBuffer:blurBuf offset:0 atIndex:0];
        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];
    }
    // Pass 3: highpass — original + meanColor → intermediateC
    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:_psoHighpass];
        [enc setTexture:texIn  atIndex:0];
        [enc setTexture:texB  atIndex:1];
        [enc setTexture:texC  atIndex:2];
        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];
    }
    // Pass 4: composite — original + meanColor + highPassMap + mask → outputBuffer
    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:_psoComposite];
        [enc setTexture:texIn  atIndex:0];
        [enc setTexture:texB   atIndex:1];
        [enc setTexture:texC   atIndex:2];
        [enc setTexture:texOut atIndex:3];
        // Phase 4C (DEC-63): bind mask texture at index 4.
        // If no mask is available (hasMask=0), we still bind a valid texture
        // to satisfy the Metal argument table. The kernel branches on hasMask
        // and never reads maskTex when hasMask=0.
        if (maskTex) {
            [enc setTexture:maskTex atIndex:4];
        } else {
            // Bind original as dummy — hasMask=0 means kernel ignores texture(4).
            [enc setTexture:texIn atIndex:4];
        }
        [enc setBuffer:compBuf offset:0 atIndex:0];
        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];
    }

    // ── Commit + synchronous wait (DEC-58 — NO addCompletedHandler:) ──────────
    [cmd commit];
    [cmd waitUntilCompleted];

    // ── GPU fault check (Step 3B) ──────────────────────────────────────────────
    // waitUntilCompleted blocks until the GPU is done but does NOT guarantee
    // success. MTLCommandBufferStatusError occurs on device loss, TDR, or OOM
    // on the GPU timeline. Without this check a faulted command buffer would
    // deliver partially-written pixels to the renderer silently.
    if (cmd.status == MTLCommandBufferStatusError) {
        os_log_error(OS_LOG_DEFAULT,
                     "[BeautyV2] command buffer faulted: %{public}@",
                     cmd.error.localizedDescription);
        CVPixelBufferRelease(bufA);
        CVPixelBufferRelease(bufB);
        CVPixelBufferRelease(bufC);
        CVPixelBufferRelease(output);
        VGFrameEnvelope f = envelope; f.payload.videoBuffer = NULL; return f;
    }

    // ── Release intermediates — GPU completed successfully (RR-38 / RR-39) ────
    CVPixelBufferRelease(bufA);
    CVPixelBufferRelease(bufB);
    CVPixelBufferRelease(bufC);

    // ── Return outputBuffer at +1 (RR-41: NEVER return an intermediate) ───────
    VGFrameEnvelope out = envelope;
    out.payload.videoBuffer = output;
    return out;
}

// ---------------------------------------------------------------------------
// MARK: processBuffer:atTime:device: (VanguardFilterNode legacy)
// ---------------------------------------------------------------------------
//
// Image-path entry point (VanguardImageProcessor.applyFilterChain:).
// Wraps processEnvelope: to share the 4-pass GPU pipeline.
// Returns input at +1 on passthrough or failure (RR-28 / DEC-44).

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
    if (!_enabled || !input) {
        CVPixelBufferRetain(input);
        return input; // +1 passthrough
    }
    // Build a minimal synthetic envelope and delegate to processEnvelope:,
    // sharing the single 4-pass GPU implementation path.
    VGFrameEnvelope env = {};
    env.pts = t; env.dts = t;
    env.duration   = kCMTimeInvalid;
    env.generation = 0;
    env.mediaType  = VGMediaTypeVideo;
    env.payload.videoBuffer = input;

    VGFrameEnvelope result = [self processEnvelope:env device:device];

    CVPixelBufferRef outBuf = (CVPixelBufferRef)result.payload.videoBuffer;
    if (!outBuf || outBuf == input) {
        // Passthrough or failure — return input at +1.
        CVPixelBufferRetain(input);
        return input;
    }
    // outBuf is already at +1 from processEnvelope: — return directly.
    return outBuf;
}

@end
