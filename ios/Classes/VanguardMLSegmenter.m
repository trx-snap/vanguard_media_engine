// VanguardMLSegmenter.m
#import "VanguardMLSegmenter.h"
#import "VanguardMLInputPool.h"
#import "VanguardMaskStore.h"
#import "VanguardMLHealthMonitor.h"
#import <CoreML/CoreML.h>
#import <Vision/Vision.h>
#import <os/lock.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardMLSegmenter () <VanguardMLHealthMonitorDelegate>
@end

@implementation VanguardMLSegmenter {
    os_unfair_lock          _stateLock;
    VanguardMLState         _state;
    BOOL                    _busy;              // guard against re-entrant inference
    BOOL                    _invalidated;

    dispatch_queue_t        _mlQueue;           // serial, background priority
    VNCoreMLModel *_Nullable _vnModel;
    VNCoreMLRequest *_Nullable _vnRequest;

    CFTimeInterval           _lastSubmitTime;   // CACurrentMediaTime() of last accepted frame
    uint64_t                 _generation;       // monotonic counter fed to health monitor

    VanguardMLHealthMonitor *_Nullable _healthMonitor;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Init
// ─────────────────────────────────────────────────────────────────────────────

@synthesize maskStore = _maskStore;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _stateLock       = OS_UNFAIR_LOCK_INIT;
    _state           = VanguardMLStateUnloaded;
    _minimumInterval = 0.1;
    _mlQueue         = dispatch_queue_create("com.vanguard.ml.segmenter",
                                             dispatch_queue_attr_make_with_qos_class(
                                                 DISPATCH_QUEUE_SERIAL,
                                                 QOS_CLASS_USER_INITIATED, 0));
    return self;
}

- (void)setMaskStore:(VanguardMaskStore *)maskStore {
    _maskStore = maskStore;
    if (maskStore) {
        _healthMonitor = [[VanguardMLHealthMonitor alloc] initWithMaskStore:maskStore delegate:self];
        os_unfair_lock_lock(&_stateLock);
        BOOL isReady = (_state == VanguardMLStateReady);
        os_unfair_lock_unlock(&_stateLock);
        if (isReady) {
            [_healthMonitor startMonitoring];
        }
    } else {
        [_healthMonitor stopMonitoring];
        _healthMonitor = nil;
    }
}

- (void)dealloc {
    [self invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: State accessors
// ─────────────────────────────────────────────────────────────────────────────

- (VanguardMLState)state {
    os_unfair_lock_lock(&_stateLock);
    VanguardMLState s = _state;
    os_unfair_lock_unlock(&_stateLock);
    return s;
}

- (void)_transitionTo:(VanguardMLState)newState {
    os_unfair_lock_lock(&_stateLock);
    _state = newState;
    os_unfair_lock_unlock(&_stateLock);
    id<VanguardMLSegmenterDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(segmenterDidTransitionToState:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate segmenterDidTransitionToState:newState];
        });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Model lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)loadModelAsync {
    dispatch_async(_mlQueue, ^{
        os_unfair_lock_lock(&self->_stateLock);
        BOOL invalidated = self->_invalidated;
        os_unfair_lock_unlock(&self->_stateLock);
        if (invalidated) return;

        NSError *error = nil;

        // Attempt to load a bundled CoreML model named "VanguardSegmentation".
        // Falls back to Vision's built-in person segmentation on failure.
        NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"VanguardSegmentation"
                                                  withExtension:@"mlmodelc"];
        MLModel *mlModel = nil;
        if (modelURL) {
            MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
            cfg.computeUnits = MLComputeUnitsAll;
            mlModel = [MLModel modelWithContentsOfURL:modelURL configuration:cfg error:&error];
        }

        if (!mlModel || error) {
            // Gracefully degrade: configure a stub request using VNGeneratePersonSegmentationRequest.
            // Full segmentation mask still published; just at Vision quality rather than custom model.
            NSLog(@"[VanguardMLSegmenter] Custom model unavailable (%@), using Vision fallback",
                  error.localizedDescription);
            [self _configureVisionFallback];
            [self _transitionTo:VanguardMLStateReady];
            [self->_healthMonitor startMonitoring];
            return;
        }

        VNCoreMLModel *vnModel = [VNCoreMLModel modelForMLModel:mlModel error:&error];
        if (!vnModel || error) {
            [self _transitionTo:VanguardMLStateFaulted];
            NSLog(@"[VanguardMLSegmenter] VNCoreMLModel creation failed: %@", error);
            return;
        }

        os_unfair_lock_lock(&self->_stateLock);
        self->_vnModel = vnModel;
        self->_vnRequest = [[VNCoreMLRequest alloc] initWithModel:vnModel];
        self->_vnRequest.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill;
        os_unfair_lock_unlock(&self->_stateLock);

        [self _transitionTo:VanguardMLStateReady];
        [self->_healthMonitor startMonitoring];
        NSLog(@"[VanguardMLSegmenter] Custom CoreML model loaded ✅");
    });
}

- (void)_configureVisionFallback {
    // Use VNGeneratePersonSegmentationRequest as the inference request.
    // Results are delivered in the same completionHandler path.
    os_unfair_lock_lock(&_stateLock);
    _vnModel   = nil;
    _vnRequest = nil;   // nil signals "use Vision fallback path" in submitFrame
    os_unfair_lock_unlock(&_stateLock);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Frame submission
// ─────────────────────────────────────────────────────────────────────────────

- (void)submitFrame:(CVPixelBufferRef)pixelBuffer presentationTime:(CMTime)pts {
    // Gate 1: state
    os_unfair_lock_lock(&_stateLock);
    VanguardMLState state = _state;
    BOOL busy             = _busy;
    BOOL invalidated      = _invalidated;
    os_unfair_lock_unlock(&_stateLock);
    if (state != VanguardMLStateReady || busy || invalidated) return;

    // Gate 2: minimum interval (thermal-adaptive throttle)
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastSubmitTime < _minimumInterval) return;
    _lastSubmitTime = now;

    // Gate 3: pool pressure — borrow a prescaled buffer
    CVPixelBufferRef mlBuffer = NULL;
    VanguardMLInputPool *pool = self.inputPool;
    if (pool) {
        mlBuffer = [pool borrowBuffer];
        if (!mlBuffer) return;   // pool exhausted (WEAT) — skip frame
    } else {
        // No pool: use the capture buffer directly (retain for async use)
        CVPixelBufferRetain(pixelBuffer);
        mlBuffer = pixelBuffer;
    }

    // Mark busy before dispatching
    os_unfair_lock_lock(&_stateLock);
    _busy = YES;
    os_unfair_lock_unlock(&_stateLock);

    CVPixelBufferRef bufferToProcess = mlBuffer;
    CMTime ptsCapture = pts;

    dispatch_async(_mlQueue, ^{
        [self _runInferenceOnBuffer:bufferToProcess pts:ptsCapture];
        if (bufferToProcess) CVPixelBufferRelease(bufferToProcess);

        os_unfair_lock_lock(&self->_stateLock);
        self->_busy = NO;
        os_unfair_lock_unlock(&self->_stateLock);
    });
}

- (void)_runInferenceOnBuffer:(CVPixelBufferRef)buffer pts:(CMTime)pts {
    os_unfair_lock_lock(&_stateLock);
    BOOL invalidated     = _invalidated;
    VNCoreMLRequest *req = _vnRequest;
    os_unfair_lock_unlock(&_stateLock);
    if (invalidated) return;

    NSError *error = nil;

    if (req) {
        // CoreML path
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
            initWithCVPixelBuffer:buffer options:@{}];
        [handler performRequests:@[req] error:&error];
        if (error) {
            NSLog(@"[VanguardMLSegmenter] Inference error: %@", error);
            [self _transitionTo:VanguardMLStateFaulted];
            [_healthMonitor stopMonitoring];
            return;
        }
        VNPixelBufferObservation *obs = req.results.firstObject;
        if (obs) {
            [self _publishMask:obs.pixelBuffer pts:pts];
        }
    } else {
        // Vision person-segmentation fallback
        VNGeneratePersonSegmentationRequest *segReq =
            [[VNGeneratePersonSegmentationRequest alloc] init];
        segReq.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
            initWithCVPixelBuffer:buffer options:@{}];
        [handler performRequests:@[segReq] error:&error];
        if (error) {
            NSLog(@"[VanguardMLSegmenter] Vision fallback error: %@", error);
            [self _transitionTo:VanguardMLStateFaulted];
            [_healthMonitor stopMonitoring];
            return;
        }
        VNPixelBufferObservation *obs = segReq.results.firstObject;
        if (obs) {
            [self _publishMask:obs.pixelBuffer pts:pts];
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Mask publication
// ─────────────────────────────────────────────────────────────────────────────

- (void)_publishMask:(CVPixelBufferRef)maskBuffer pts:(CMTime)pts {
    VanguardMaskStore *store = self.maskStore;
    if (!store || !maskBuffer) return;

    os_unfair_lock_lock(&_stateLock);
    uint64_t gen = ++_generation;
    os_unfair_lock_unlock(&_stateLock);

    VanguardMaskSnapshot *snapshot = [[VanguardMaskSnapshot alloc] initWithPixelBuffer:maskBuffer
                                                                             timestamp:CACurrentMediaTime()
                                                                            generation:gen];
    [store commitSnapshot:snapshot];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Reset / Invalidate
// ─────────────────────────────────────────────────────────────────────────────

- (void)reset {
    [_healthMonitor stopMonitoring];
    os_unfair_lock_lock(&_stateLock);
    if (_state == VanguardMLStateFaulted) {
        _state    = VanguardMLStateUnloaded;
        _vnModel  = nil;
        _vnRequest= nil;
        _busy     = NO;
    }
    os_unfair_lock_unlock(&_stateLock);
    [self loadModelAsync];
}

- (void)invalidate {
    [_healthMonitor stopMonitoring];
    os_unfair_lock_lock(&_stateLock);
    _invalidated = YES;
    _state       = VanguardMLStateUnloaded;
    _vnModel     = nil;
    _vnRequest   = nil;
    os_unfair_lock_unlock(&_stateLock);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: VanguardMLHealthMonitorDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)healthMonitorDidDetectStall {
    NSLog(@"[VanguardMLSegmenter] ⚠️ Stall detected — transitioning to Faulted");
    [self _transitionTo:VanguardMLStateFaulted];
    id<VanguardMLSegmenterDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(segmenterDidStall)]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate segmenterDidStall]; });
    }
}

@end
