// VGFaceDetectionProvider.m
// Phase 4C — Step 1: Async face detection provider (DEC-61).
//
// Implementation uses Apple Vision framework for face + landmark detection.
// Detection runs on a private serial queue; results are cached atomically.
// The render thread is NEVER blocked (DEC-58 compliance).
//
// Throttling:
//   - A frame counter tracks calls to detectInPixelBuffer:.
//   - Detection fires only when (frameCount % cadenceFrames == 0).
//   - An atomic flag prevents overlapping detections.
//
// Memory:
//   - The input CVPixelBuffer is retained during async detection and released
//     on completion (or cancellation).
//   - VGDetectedFace / VGFaceDetectionResult are lightweight ObjC objects.
//
// Orientation:
//   - Vision requests are configured with kCGImagePropertyOrientationUp.
//   - Camera frames are assumed to be delivered in their native capture
//     orientation. If the source applies rotation before the filter chain,
//     the Vision request orientation may need adjustment (documented assumption).

#import "VGFaceDetectionProvider.h"
#import <Vision/Vision.h>
#import <os/log.h>
#import <stdatomic.h>

// ---------------------------------------------------------------------------
// MARK: VGDetectedFace
// ---------------------------------------------------------------------------

@implementation VGDetectedFace {
    CGRect _boundingBox;
    float _confidence;
    NSNumber *_rollAngle;
    NSNumber *_yawAngle;
    NSArray<NSValue *> *_faceContourPoints;
    NSArray<NSValue *> *_leftEyePoints;
    NSArray<NSValue *> *_rightEyePoints;
    NSArray<NSValue *> *_leftEyebrowPoints;
    NSArray<NSValue *> *_rightEyebrowPoints;
    NSArray<NSValue *> *_outerLipsPoints;
    NSArray<NSValue *> *_nosePoints;
}

@synthesize boundingBox       = _boundingBox;
@synthesize confidence        = _confidence;
@synthesize rollAngle         = _rollAngle;
@synthesize yawAngle          = _yawAngle;
@synthesize faceContourPoints = _faceContourPoints;
@synthesize leftEyePoints     = _leftEyePoints;
@synthesize rightEyePoints    = _rightEyePoints;
@synthesize leftEyebrowPoints = _leftEyebrowPoints;
@synthesize rightEyebrowPoints = _rightEyebrowPoints;
@synthesize outerLipsPoints   = _outerLipsPoints;
@synthesize nosePoints        = _nosePoints;

- (instancetype)_initWithBoundingBox:(CGRect)box
                          confidence:(float)confidence
                           rollAngle:(NSNumber * _Nullable)roll
                            yawAngle:(NSNumber * _Nullable)yaw
                    faceContourPoints:(NSArray<NSValue *> * _Nullable)faceContour
                        leftEyePoints:(NSArray<NSValue *> * _Nullable)leftEye
                       rightEyePoints:(NSArray<NSValue *> * _Nullable)rightEye
                    leftEyebrowPoints:(NSArray<NSValue *> * _Nullable)leftEyebrow
                   rightEyebrowPoints:(NSArray<NSValue *> * _Nullable)rightEyebrow
                      outerLipsPoints:(NSArray<NSValue *> * _Nullable)outerLips
                           nosePoints:(NSArray<NSValue *> * _Nullable)nose {
    self = [super init];
    if (!self) return nil;
    _boundingBox       = box;
    _confidence        = confidence;
    _rollAngle         = roll;
    _yawAngle          = yaw;
    _faceContourPoints = [faceContour copy];
    _leftEyePoints     = [leftEye copy];
    _rightEyePoints    = [rightEye copy];
    _leftEyebrowPoints = [leftEyebrow copy];
    _rightEyebrowPoints = [rightEyebrow copy];
    _outerLipsPoints   = [outerLips copy];
    _nosePoints        = [nose copy];
    return self;
}

@end

// ---------------------------------------------------------------------------
// MARK: VGFaceDetectionResult
// ---------------------------------------------------------------------------

@implementation VGFaceDetectionResult {
    NSArray<VGDetectedFace *> *_faces;
    CMTime _sourcePTS;
    CFAbsoluteTime _completionTime;
}

@synthesize faces          = _faces;
@synthesize sourcePTS      = _sourcePTS;
@synthesize completionTime = _completionTime;

- (instancetype)_initWithFaces:(NSArray<VGDetectedFace *> *)faces
                     sourcePTS:(CMTime)pts
                completionTime:(CFAbsoluteTime)completionTime {
    self = [super init];
    if (!self) return nil;
    _faces          = [faces copy];
    _sourcePTS      = pts;
    _completionTime = completionTime;
    return self;
}

@end

// ---------------------------------------------------------------------------
// MARK: Landmark point extraction helper
// ---------------------------------------------------------------------------

/// Extracts normalized CGPoints from a VNFaceLandmarkRegion2D into an NSArray.
/// Returns nil if the region is nil or has no points.
static NSArray<NSValue *> * _Nullable
_VGExtractLandmarkPoints(VNFaceLandmarkRegion2D * _Nullable region) {
    if (!region || region.pointCount == 0) return nil;
    NSUInteger count = region.pointCount;
    // `normalizedPoints` returns landmark positions in normalized [0,1] coords.
    // This is the correct VNFaceLandmarkRegion2D API (pointsInImageCoordOfSize:
    // does not exist). The mask rasterizer scales to pixel coords internally.
    const CGPoint *pts = region.normalizedPoints;
    if (!pts) return nil;
    NSMutableArray<NSValue *> *arr = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [arr addObject:[NSValue valueWithCGPoint:pts[i]]];
    }
    return arr;
}

// ---------------------------------------------------------------------------
// MARK: VGFaceDetectionProvider
// ---------------------------------------------------------------------------

@implementation VGFaceDetectionProvider {
    dispatch_queue_t _detectionQueue;
    atomic_bool      _detectionInFlight;
    atomic_bool      _invalidated;
    NSInteger        _frameCounter;
}

@synthesize latestResult = _latestResult;
@synthesize enabled      = _enabled;
@synthesize cadenceFrames = _cadenceFrames;
@synthesize maxFaces     = _maxFaces;

- (instancetype)initWithCadenceFrames:(NSInteger)cadenceFrames {
    self = [super init];
    if (!self) return nil;

    _detectionQueue = dispatch_queue_create(
        "com.vanguard.faceDetection", DISPATCH_QUEUE_SERIAL);
    atomic_store(&_detectionInFlight, false);
    atomic_store(&_invalidated, false);

    _enabled        = YES;
    _cadenceFrames  = MAX(1, MIN(cadenceFrames, 30));
    _maxFaces       = 5;
    _frameCounter   = 0;
    _latestResult   = nil;

    return self;
}

- (void)detectInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        pts:(CMTime)pts {
    // ── Gate 1: invalidated or disabled → no-op ──────────────────────────
    if (atomic_load(&_invalidated) || !_enabled) return;
    if (!pixelBuffer) return;

    // ── Gate 2: throttle — only detect every Nth frame ───────────────────
    _frameCounter++;
    if ((_frameCounter % _cadenceFrames) != 0) return;

    // ── Gate 3: skip if previous detection still in-flight ───────────────
    // atomic_exchange returns the previous value; if true, detection is busy.
    if (atomic_exchange(&_detectionInFlight, true)) return;

    // ── Retain pixel buffer for async use (RR-38 compliance) ─────────────
    CVPixelBufferRetain(pixelBuffer);
    CMTime capturedPTS = pts;
    NSInteger maxFaces = _maxFaces;

    // ── Dispatch async detection ─────────────────────────────────────────
    __weak typeof(self) weakSelf = self;
    dispatch_async(_detectionQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_invalidated)) {
            CVPixelBufferRelease(pixelBuffer);
            if (strongSelf) atomic_store(&strongSelf->_detectionInFlight, false);
            return;
        }

        // ── Build Vision request ─────────────────────────────────────────
        // Use VNDetectFaceLandmarksRequest which includes face rectangles
        // AND landmarks in a single pass — no need for two requests.
        VNDetectFaceLandmarksRequest *request =
            [[VNDetectFaceLandmarksRequest alloc] init];

        // Revision 3 is available on iOS 14+; use default revision for
        // broadest compatibility.
        // Limit constellation to improve performance (DEC-61 / RR-54).

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
            initWithCVPixelBuffer:pixelBuffer
                      orientation:kCGImagePropertyOrientationUp
                          options:@{}];

        NSError *error = nil;
        [handler performRequests:@[request] error:&error];

        // ── Release pixel buffer — Vision has finished reading it ────────
        CVPixelBufferRelease(pixelBuffer);

        if (error) {
            os_log_error(OS_LOG_DEFAULT,
                         "[VGFaceDetection] Vision error: %{public}@",
                         error.localizedDescription);
            atomic_store(&strongSelf->_detectionInFlight, false);
            return;
        }

        // ── Process results ──────────────────────────────────────────────
        NSArray<VNFaceObservation *> *observations = request.results;
        NSMutableArray<VGDetectedFace *> *faces = [NSMutableArray array];

        NSInteger faceCount = 0;
        for (VNFaceObservation *obs in observations) {
            if (faceCount >= maxFaces) break;

            VNFaceLandmarks2D *landmarks = obs.landmarks;

            VGDetectedFace *face = [[VGDetectedFace alloc]
                _initWithBoundingBox:obs.boundingBox
                          confidence:obs.confidence
                           rollAngle:obs.roll
                            yawAngle:obs.yaw
                    faceContourPoints:_VGExtractLandmarkPoints(landmarks.faceContour)
                        leftEyePoints:_VGExtractLandmarkPoints(landmarks.leftEye)
                       rightEyePoints:_VGExtractLandmarkPoints(landmarks.rightEye)
                    leftEyebrowPoints:_VGExtractLandmarkPoints(landmarks.leftEyebrow)
                   rightEyebrowPoints:_VGExtractLandmarkPoints(landmarks.rightEyebrow)
                      outerLipsPoints:_VGExtractLandmarkPoints(landmarks.outerLips)
                           nosePoints:_VGExtractLandmarkPoints(landmarks.nose)];
            [faces addObject:face];
            faceCount++;
        }

        VGFaceDetectionResult *result = [[VGFaceDetectionResult alloc]
            _initWithFaces:faces
                 sourcePTS:capturedPTS
            completionTime:CFAbsoluteTimeGetCurrent()];

        // ── Atomic publish ───────────────────────────────────────────────
        strongSelf->_latestResult = result;
        atomic_store(&strongSelf->_detectionInFlight, false);

        if (faces.count > 0) {
            os_log_info(OS_LOG_DEFAULT,
                        "[VGFaceDetection] Detected %lu face(s) at PTS %.3f",
                        (unsigned long)faces.count,
                        CMTimeGetSeconds(capturedPTS));
        }
    });
}

- (void)invalidate {
    atomic_store(&_invalidated, true);
    // No need to drain the queue — the in-flight block checks _invalidated
    // and will release its pixel buffer + exit early.
    _latestResult = nil;
}

@end
