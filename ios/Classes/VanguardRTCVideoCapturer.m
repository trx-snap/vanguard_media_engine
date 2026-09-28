// VanguardRTCVideoCapturer.m
// Vanguard Media Engine -> LiveKit LiveStreaming Egress Bridge (iOS)
//
// Repair (processed-frame receiver path):
//   The previous proof-of-concept swizzled VanguardCameraPlatformView.onFrame:pts:
//   and registered its own channel from +load. Neither ever ran for the
//   livestream screen: the screen previews through VGCameraSession + a Flutter
//   Texture (no platform view), and nothing registered the channel. This
//   implementation instead conforms to VanguardCameraFrameReceiver and is
//   wired into the active VGCameraGraphSession's fan-out by the plugin via
//   -connectProcessedFrameReceiver:, so it receives exactly the processed
//   frames the preview renders. No swizzling, no +load, no self-registration.
//
// Virtual camera (Option C): with the local flutter_webrtc fork's external
// video source SPI, the same receiver/gate path feeds a track flutter_webrtc
// created without any camera (-startExternalVideoSourceForTrackId:sink:), so
// the stock-capturer stop below is not needed on that path.

#import "VanguardRTCVideoCapturer.h"
#import "VGCameraGraphSession.h"
#import <os/lock.h>
#import <time.h>

// ── WebRTC Forward Declarations (Dynamic Runtime Binding) ────────────────────
// Forward declarations let this file compile without a WebRTC pod dependency;
// the classes are resolved at runtime from WebRTC.framework (RTC_OBJC_TYPE_PREFIX
// is empty in the bundled SDK, so the unprefixed names are the real ones).

@interface RTCCVPixelBuffer : NSObject
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@interface RTCVideoFrame : NSObject
- (instancetype)initWithBuffer:(id)buffer rotation:(NSInteger)rotation timeStampNs:(int64_t)timeStampNs;
@end

@protocol RTCVideoCapturerDelegate <NSObject>
- (void)capturer:(id)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame;
@end

// flutter_webrtc's per-track stop handler: ^(CompletionHandler handler).
typedef void (^VGRTCCompletionHandler)(void);
typedef void (^VGRTCCapturerStopHandler)(VGRTCCompletionHandler _Nonnull handler);

static NSString *const kVGRTCTag = @"[VanguardRTC]";
static const int64_t kVGRTCStockStopTimeoutNs = 1 * NSEC_PER_SEC;
static const uint64_t kVGRTCPeriodicLogFrames = 300;

// Virtual camera provider (flutter_webrtc external video source SPI).
static NSString *const kVGRTCVirtualCameraDeviceId = @"vanguard_virtual_camera";
static const NSInteger kVGRTCVirtualCameraWidth = 720;
static const NSInteger kVGRTCVirtualCameraHeight = 1280;
static const NSInteger kVGRTCVirtualCameraFps = 30;

static NSString *VGRTCFourCC(OSType fmt) {
    char c[5] = { (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, 0 };
    return [NSString stringWithUTF8String:c] ?: [NSString stringWithFormat:@"0x%08x", (unsigned)fmt];
}

// ── I2: image-first (standalone pump, no camera graph) ───────────────────────
static NSString *const kVGRTCInitialModeImage = @"image";
static const int64_t kVGRTCImageFirstCameraTimeoutNs = 6 * NSEC_PER_SEC;

// Cheap synchronous checks only (no decode). Returns the rejection reason or nil.
static NSString * _Nullable VGRTCValidateImagePath(id _Nullable rawPath) {
    if (![rawPath isKindOfClass:[NSString class]] || [(NSString *)rawPath length] == 0) {
        return @"imagePath is required.";
    }
    NSString *path = (NSString *)rawPath;
    if ([path containsString:@"://"]) {
        return [NSString stringWithFormat:@"imagePath must be a local filesystem path, not a URI: %@", path];
    }
    if (![path hasPrefix:@"/"]) {
        return [NSString stringWithFormat:@"imagePath must be absolute: %@", path];
    }
    BOOL isDirectory = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
        return [NSString stringWithFormat:@"imagePath does not exist or is not a file: %@", path];
    }
    if (![fm isReadableFileAtPath:path]) {
        return [NSString stringWithFormat:@"imagePath is not readable: %@", path];
    }
    return nil;
}

// ── Private Interface ────────────────────────────────────────────────────────

@interface VanguardRTCVideoCapturer () {
    os_unfair_lock _lock;

    // ── Guarded by _lock ─────────────────────────────────────────────────────
    id _activeVideoSource;              // RTCVideoSource (an RTCVideoCapturerDelegate)
    NSString *_attachedTrackId;
    BOOL _gateOpen;                     // frames are forwarded only while YES
    BOOL _stockStopConfirmed;
    BOOL _attachInProgress;             // between stock-stop request and gate open
    uint64_t _attachGeneration;         // invalidates stale completion/timeout blocks
    uint64_t _framesDelivered;
    FlutterResult _pendingAttachResult; // replied exactly once by whoever takes it
    __weak VGCameraGraphSession *_connectedGraphSession;
    VGRTCGraphSessionProvider _graphSessionProvider;
    BOOL _virtualSource;                // egress bound through the virtual camera provider

    // ── Resolved on first attach; immutable afterwards ───────────────────────
    Class _rtcPixelBufferClass;
    Class _rtcVideoFrameClass;

    // ── I2: image-first — armed state and standalone pump (guarded by _lock) ─
    // Armed by setInitialMediaSource (decoded before the reply), consumed by
    // the next startExternalVideoSourceForTrackId:sink:, cleared by detach.
    NSString *_pendingInitialMode;           // kVGRTCInitialModeImage or nil
    NSString *_pendingInitialImagePath;
    CVPixelBufferRef _pendingInitialBuffer;  // +1 owned
    uint64_t _initialGeneration;             // drops stale arm decodes
    // While YES the standalone pump (not a camera graph) feeds the sink.
    BOOL _imageFirstActive;
    CVPixelBufferRef _imagePumpBuffer;       // +1 owned; the still the pump repeats
    NSString *_imagePumpPath;
    BOOL _imagePumpMuted;
    uint64_t _imagePumpFrames;
    uint64_t _imagePumpSwapGeneration;       // drops stale hot-swap decodes
    dispatch_source_t _imagePumpTimer;       // fires on _imagePumpQueue
    dispatch_queue_t _imagePumpQueue;
    // image-first → camera hand-over: the first camera-graph frame completes it.
    BOOL _awaitingGraphFrame;
    uint64_t _imageFirstSwitchGeneration;
    FlutterResult _pendingImageFirstSwitchResult;
}
@end

@implementation VanguardRTCVideoCapturer

+ (instancetype)sharedInstance {
    static VanguardRTCVideoCapturer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[VanguardRTCVideoCapturer alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _imagePumpQueue = dispatch_queue_create("com.vanguard.livestreamImageFirstPump",
                                                dispatch_queue_attr_make_with_qos_class(
                                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    }
    return self;
}

// ── Flutter Method Routing (main thread) ─────────────────────────────────────

- (void)setGraphSessionProvider:(VGRTCGraphSessionProvider)provider {
    VGRTCGraphSessionProvider copied = [provider copy];
    os_unfair_lock_lock(&_lock);
    _graphSessionProvider = copied;
    os_unfair_lock_unlock(&_lock);
    NSLog(@"%@ graph session provider %@", kVGRTCTag, provider ? @"installed" : @"cleared");
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([@"attachVanguardToLiveKitTrack" isEqualToString:call.method]) {
        os_unfair_lock_lock(&_lock);
        VGRTCGraphSessionProvider provider = _graphSessionProvider;
        os_unfair_lock_unlock(&_lock);
        VGCameraGraphSession *graphSession = provider ? provider() : nil;
        [self attachWithArguments:call.arguments graphSession:graphSession result:result];
    } else if ([@"detachVanguard" isEqualToString:call.method]) {
        [self detach];
        result(@{ @"status": @"detached" });
    } else if ([@"getStats" isEqualToString:call.method]) {
        result([self statsSnapshot]);
    } else if ([@"setMediaSource" isEqualToString:call.method]) {
        [self setMediaSourceWithArguments:call.arguments result:result];
    } else if ([@"setInitialMediaSource" isEqualToString:call.method]) {
        [self setInitialMediaSourceWithArguments:call.arguments result:result];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

// ── I2: image-first start ────────────────────────────────────────────────────
//
// setInitialMediaSource arms what the NEXT virtual track starts from. Camera
// (the default) clears any armed image and leaves the camera-first path
// untouched. Image validates the path at once, decodes it off the main thread
// through VGCreateLivestreamImageBuffer (720x1280 BGRA, the egress format) and
// replies only once that succeeded, so Dart aborts before any track exists on
// a bad image. The decoded buffer is consumed by the next
// startExternalVideoSourceForTrackId:sink:, which then feeds the sink from a
// standalone 30 fps pump without any VGCameraGraphSession: the camera hardware
// stays closed until the app creates a camera and requests
// setMediaSource(camera). Main thread; replies exactly once.
- (void)setInitialMediaSourceWithArguments:(id)arguments result:(FlutterResult)result {
    NSDictionary *args = [arguments isKindOfClass:[NSDictionary class]] ? (NSDictionary *)arguments : nil;
    NSString *mode = [args[@"mode"] isKindOfClass:[NSString class]] ? (NSString *)args[@"mode"] : nil;
    id rawPath = args[@"imagePath"];
    if ([mode isEqualToString:@"camera"]) {
        [self clearPendingInitialMediaSourceWithReason:@"initial source camera"];
        result(@{ @"status": @"armed", @"mode": @"camera", @"imagePath": [NSNull null] });
        return;
    }
    if (![mode isEqualToString:kVGRTCInitialModeImage]) {
        result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                   message:@"mode must be \"camera\" or \"image\""
                                   details:nil]);
        return;
    }
    NSString *reason = VGRTCValidateImagePath(rawPath);
    if (reason) {
        NSLog(@"%@ setInitialMediaSource(image) rejected (INVALID_IMAGE_PATH): %@", kVGRTCTag, reason);
        result([FlutterError errorWithCode:@"INVALID_IMAGE_PATH" message:reason details:nil]);
        return;
    }
    NSString *path = [(NSString *)rawPath copy];

    // A new arm replaces the previous one (its buffer is dropped now).
    CVPixelBufferRef previous = NULL;
    uint64_t generation = 0;
    os_unfair_lock_lock(&_lock);
    generation = ++_initialGeneration;
    previous = _pendingInitialBuffer;
    _pendingInitialBuffer = NULL;
    _pendingInitialMode = nil;
    _pendingInitialImagePath = nil;
    os_unfair_lock_unlock(&_lock);
    if (previous) CVPixelBufferRelease(previous);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *decodeError = nil;
        CVPixelBufferRef buffer = VGCreateLivestreamImageBuffer(path, (size_t)kVGRTCVirtualCameraWidth,
                                                                (size_t)kVGRTCVirtualCameraHeight, &decodeError);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                if (buffer) CVPixelBufferRelease(buffer);
                return;
            }
            if (!buffer) {
                NSLog(@"%@ setInitialMediaSource(image) decode failed: %@", kVGRTCTag, decodeError.localizedDescription);
                result([FlutterError errorWithCode:@"IMAGE_DECODE_FAILED"
                                           message:(decodeError.localizedDescription ?: @"The image could not be decoded.")
                                           details:nil]);
                return;
            }
            os_unfair_lock_lock(&strongSelf->_lock);
            const BOOL stale = (generation != strongSelf->_initialGeneration);
            if (!stale) {
                strongSelf->_pendingInitialBuffer = buffer;   // adopt the +1
                strongSelf->_pendingInitialMode = kVGRTCInitialModeImage;
                strongSelf->_pendingInitialImagePath = path;
            }
            os_unfair_lock_unlock(&strongSelf->_lock);
            if (stale) {
                CVPixelBufferRelease(buffer);
                result([FlutterError errorWithCode:@"SUPERSEDED"
                                           message:@"A newer initial media source replaced this one"
                                           details:nil]);
                return;
            }
            NSLog(@"%@ initial media source armed: image %@ (%zux%zu)", kVGRTCTag, path,
                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer));
            result(@{ @"status": @"armed", @"mode": kVGRTCInitialModeImage, @"imagePath": path });
        });
    });
}

// Drops the armed initial source (and supersedes an in-flight arm decode).
- (void)clearPendingInitialMediaSourceWithReason:(NSString *)reason {
    CVPixelBufferRef buffer = NULL;
    BOOL hadArmed = NO;
    os_unfair_lock_lock(&_lock);
    _initialGeneration += 1;
    buffer = _pendingInitialBuffer;
    _pendingInitialBuffer = NULL;
    hadArmed = (_pendingInitialMode != nil);
    _pendingInitialMode = nil;
    _pendingInitialImagePath = nil;
    os_unfair_lock_unlock(&_lock);
    if (buffer) CVPixelBufferRelease(buffer);
    if (hadArmed) NSLog(@"%@ initial media source cleared (%@)", kVGRTCTag, reason);
}

// Main thread. Starts the standalone timer; the pump state was installed by
// the caller under _lock.
- (void)startImagePumpTimer {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _imagePumpQueue);
    const uint64_t interval = NSEC_PER_SEC / (uint64_t)kVGRTCVirtualCameraFps;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{ [weakSelf imagePumpTick]; });
    os_unfair_lock_lock(&_lock);
    _imagePumpTimer = timer;
    os_unfair_lock_unlock(&_lock);
    dispatch_resume(timer);
}

// Any thread. Cancels the standalone pump, drops its buffer and leaves
// image-first mode. Idempotent. Never touches the sink/track or the gate.
- (void)stopImagePump {
    dispatch_source_t timer = nil;
    CVPixelBufferRef buffer = NULL;
    NSString *path = nil;
    uint64_t frames = 0;
    BOOL wasActive = NO;
    os_unfair_lock_lock(&_lock);
    timer = _imagePumpTimer;
    _imagePumpTimer = nil;
    buffer = _imagePumpBuffer;
    _imagePumpBuffer = NULL;
    path = _imagePumpPath;
    _imagePumpPath = nil;
    frames = _imagePumpFrames;
    wasActive = _imageFirstActive;
    _imageFirstActive = NO;
    _imagePumpMuted = YES;
    _awaitingGraphFrame = NO;
    os_unfair_lock_unlock(&_lock);
    if (timer) dispatch_source_cancel(timer);
    if (buffer) CVPixelBufferRelease(buffer);
    if (wasActive) {
        NSLog(@"%@ IOS_LIVESTREAM_IMAGE_FIRST_PUMP_STOPPED frames=%llu path=%@", kVGRTCTag,
              (unsigned long long)frames, path ?: @"");
    }
}

// Pump queue. Repeats the still into the sink as RTCVideoFrames with a
// monotonic timestamp (the same clock onFrame:pts: falls back to).
- (void)imagePumpTick {
    os_unfair_lock_lock(&_lock);
    if (_imagePumpMuted || !_imageFirstActive || !_gateOpen) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    id sink = _activeVideoSource;
    CVPixelBufferRef buffer = _imagePumpBuffer;
    if (buffer) CVPixelBufferRetain(buffer);
    Class pixelBufferClass = _rtcPixelBufferClass;
    Class videoFrameClass = _rtcVideoFrameClass;
    os_unfair_lock_unlock(&_lock);
    if (!sink || !buffer || !pixelBufferClass || !videoFrameClass) {
        if (buffer) CVPixelBufferRelease(buffer);
        return;
    }

    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    RTCCVPixelBuffer *rtcBuffer = [[pixelBufferClass alloc] initWithPixelBuffer:buffer];
    RTCVideoFrame *frame = rtcBuffer
        ? [[videoFrameClass alloc] initWithBuffer:rtcBuffer
                                         rotation:0
                                      timeStampNs:(int64_t)clock_gettime_nsec_np(CLOCK_MONOTONIC)]
        : nil;
    if (frame) {
        [(id<RTCVideoCapturerDelegate>)sink capturer:self didCaptureVideoFrame:frame];
    }
    CVPixelBufferRelease(buffer);
    if (!frame) return;

    os_unfair_lock_lock(&_lock);
    const uint64_t count = ++_imagePumpFrames;
    ++_framesDelivered;
    os_unfair_lock_unlock(&_lock);
    if (count == 1) {
        NSLog(@"%@ IOS_LIVESTREAM_IMAGE_FIRST_PUMP_READY %zux%zu fps=%ld (camera closed)", kVGRTCTag,
              width, height, (long)kVGRTCVirtualCameraFps);
    } else if (count % kVGRTCPeriodicLogFrames == 0) {
        NSLog(@"%@ IOS_LIVESTREAM_IMAGE_FIRST_PUMP_FRAME frame=%llu", kVGRTCTag, (unsigned long long)count);
    }
}

// Main thread. image → image while the standalone pump is the producer: the
// old still keeps streaming until the new one is decoded, then the buffer is
// swapped under _lock.
- (void)imageFirstReplaceImageAtPath:(NSString *)imagePath result:(FlutterResult)result {
    NSString *reason = VGRTCValidateImagePath(imagePath);
    if (reason) {
        result([FlutterError errorWithCode:@"INVALID_IMAGE_PATH" message:reason details:nil]);
        return;
    }
    NSString *path = [imagePath copy];
    uint64_t generation = 0;
    os_unfair_lock_lock(&_lock);
    generation = ++_imagePumpSwapGeneration;
    os_unfair_lock_unlock(&_lock);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *decodeError = nil;
        CVPixelBufferRef buffer = VGCreateLivestreamImageBuffer(path, (size_t)kVGRTCVirtualCameraWidth,
                                                                (size_t)kVGRTCVirtualCameraHeight, &decodeError);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                if (buffer) CVPixelBufferRelease(buffer);
                return;
            }
            if (!buffer) {
                result([FlutterError errorWithCode:@"IMAGE_DECODE_FAILED"
                                           message:(decodeError.localizedDescription ?: @"The image could not be decoded.")
                                           details:nil]);
                return;
            }
            CVPixelBufferRef previous = NULL;
            NSString *failure = nil;
            os_unfair_lock_lock(&strongSelf->_lock);
            if (!strongSelf->_imageFirstActive) {
                failure = @"NO_ACTIVE_STREAM";
            } else if (generation != strongSelf->_imagePumpSwapGeneration) {
                failure = @"SUPERSEDED";
            } else {
                previous = strongSelf->_imagePumpBuffer;
                strongSelf->_imagePumpBuffer = buffer;   // adopt the +1
                strongSelf->_imagePumpPath = path;
            }
            os_unfair_lock_unlock(&strongSelf->_lock);
            if (failure) {
                CVPixelBufferRelease(buffer);
                result([FlutterError errorWithCode:failure
                                           message:@"The image-first producer is no longer the target of this request"
                                           details:nil]);
                return;
            }
            if (previous) CVPixelBufferRelease(previous);
            NSLog(@"%@ IOS_LIVESTREAM_MEDIA_SOURCE_COMMITTED mode=image imageFirst=1 swap=hot path=%@", kVGRTCTag, path);
            result(@{ @"status": @"committed", @"mode": kVGRTCInitialModeImage, @"imagePath": path });
        });
    });
}

// Main thread. image-first → camera: the app has created a camera graph
// meanwhile; connect this receiver to it, start its capture, and keep the
// standalone pump ticking until the first graph frame reaches onFrame:pts:.
// That frame mutes the pump and finishImageFirstSwitchToCamera commits.
- (void)imageFirstSwitchToCameraWithGraphSession:(VGCameraGraphSession *)graphSession
                                          result:(FlutterResult)result {
    if (!graphSession) {
        result([FlutterError errorWithCode:@"NO_CAMERA_GRAPH"
                                   message:@"No Vanguard camera graph session; create the camera before switching"
                                   details:nil]);
        return;
    }
    if (![self ensureReceiverConnectedToGraphSession:graphSession]) {
        result([FlutterError errorWithCode:@"GRAPH_CONNECT_FAILED"
                                   message:@"VGCameraGraphSession refused the processed-frame receiver; image producer kept"
                                   details:nil]);
        return;
    }
    FlutterResult superseded = nil;
    uint64_t generation = 0;
    os_unfair_lock_lock(&_lock);
    superseded = _pendingImageFirstSwitchResult;
    _pendingImageFirstSwitchResult = [result copy];
    generation = ++_imageFirstSwitchGeneration;
    _awaitingGraphFrame = YES;
    os_unfair_lock_unlock(&_lock);
    if (superseded) {
        superseded([FlutterError errorWithCode:@"SUPERSEDED"
                                       message:@"A newer setMediaSource request replaced this one"
                                       details:nil]);
    }
    // The camera hardware starts now — on the app's explicit request only.
    [graphSession resumeCaptureSourceIfStopped];
    NSLog(@"%@ image-first → camera: graph session %p connected, waiting for its first frame", kVGRTCTag, graphSession);

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kVGRTCImageFirstCameraTimeoutNs), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        FlutterResult pending = nil;
        os_unfair_lock_lock(&strongSelf->_lock);
        if (generation == strongSelf->_imageFirstSwitchGeneration && strongSelf->_awaitingGraphFrame) {
            strongSelf->_awaitingGraphFrame = NO;
            pending = strongSelf->_pendingImageFirstSwitchResult;
            strongSelf->_pendingImageFirstSwitchResult = nil;
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
        if (pending) {
            NSLog(@"%@ image-first → camera: no camera frame in time; image producer kept", kVGRTCTag);
            pending([FlutterError errorWithCode:@"CAMERA_RESUME_TIMEOUT"
                                        message:@"No camera frame arrived in time; the image producer keeps running"
                                        details:nil]);
        }
    });
}

// Main thread. The first camera-graph frame was forwarded (onFrame:pts:
// already muted the pump): stop the pump and commit camera mode.
- (void)finishImageFirstSwitchToCamera {
    FlutterResult pending = nil;
    os_unfair_lock_lock(&_lock);
    const BOOL active = _imageFirstActive;
    if (active) {
        pending = _pendingImageFirstSwitchResult;
        _pendingImageFirstSwitchResult = nil;
    }
    os_unfair_lock_unlock(&_lock);
    if (!active) return;
    [self stopImagePump];
    NSLog(@"%@ IOS_LIVESTREAM_MEDIA_SOURCE_COMMITTED mode=camera imageFirst=0 (camera graph now feeds the track)", kVGRTCTag);
    if (pending) {
        pending(@{ @"status": @"committed", @"mode": @"camera", @"imagePath": [NSNull null] });
    }
}

// ── I1: live media source switching ─────────────────────────────────────────
//
// Routes setMediaSource to the live graph session, which swaps its producer
// (camera ↔ still-image pump) upstream of the fan-out. This capturer keeps the
// RTC sink/track exactly as they are: onFrame:pts: simply keeps receiving
// whatever the graph emits. Main thread; replies exactly once.
- (void)setMediaSourceWithArguments:(id)arguments result:(FlutterResult)result {
    NSDictionary *args = [arguments isKindOfClass:[NSDictionary class]] ? (NSDictionary *)arguments : nil;
    NSString *mode = [args[@"mode"] isKindOfClass:[NSString class]] ? (NSString *)args[@"mode"] : nil;
    id rawPath = args[@"imagePath"];
    NSString *imagePath = [rawPath isKindOfClass:[NSString class]] ? (NSString *)rawPath : nil;
    const BOOL wantsCamera = [mode isEqualToString:@"camera"];
    const BOOL wantsImage = [mode isEqualToString:@"image"];
    if (!wantsCamera && !wantsImage) {
        result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                   message:@"mode must be \"camera\" or \"image\""
                                   details:nil]);
        return;
    }

    os_unfair_lock_lock(&_lock);
    const BOOL streaming = (_gateOpen && _activeVideoSource != nil);
    const BOOL imageFirst = _imageFirstActive;
    VGRTCGraphSessionProvider provider = _graphSessionProvider;
    os_unfair_lock_unlock(&_lock);
    if (!streaming) {
        result([FlutterError errorWithCode:@"NO_ACTIVE_STREAM"
                                   message:@"No Vanguard-fed LiveKit track is live"
                                   details:nil]);
        return;
    }
    VGCameraGraphSession *graphSession = provider ? provider() : nil;
    if (imageFirst) {
        // I2: the standalone pump is the producer; no graph session is
        // involved for an image swap, and the camera hand-over needs the graph
        // session the app created since.
        if (wantsImage) {
            [self imageFirstReplaceImageAtPath:(imagePath ?: @"") result:result];
        } else {
            [self imageFirstSwitchToCameraWithGraphSession:graphSession result:result];
        }
        return;
    }
    if (!graphSession) {
        result([FlutterError errorWithCode:@"NO_CAMERA_GRAPH"
                                   message:@"No active Vanguard camera graph session"
                                   details:nil]);
        return;
    }

    __block FlutterResult pendingResult = [result copy];
    void (^reply)(NSError * _Nullable) = ^(NSError * _Nullable error) {
        FlutterResult outstanding = pendingResult;
        pendingResult = nil;
        if (!outstanding) return;
        if (error) {
            NSLog(@"%@ setMediaSource(%@) failed (%@): %@", kVGRTCTag, mode, error.domain, error.localizedDescription);
            outstanding([FlutterError errorWithCode:(error.domain ?: @"MEDIA_SOURCE_FAILED")
                                            message:error.localizedDescription
                                            details:nil]);
            return;
        }
        NSString *committedMode = [graphSession livestreamMediaSourceModeName];
        NSString *committedPath = [graphSession livestreamMediaSourceImagePath];
        NSLog(@"%@ setMediaSource committed mode=%@ path=%@", kVGRTCTag, committedMode, committedPath ?: @"");
        outstanding(@{
            @"status": @"committed",
            @"mode": committedMode,
            @"imagePath": committedPath ?: [NSNull null],
        });
    };
    if (wantsImage) {
        [graphSession setLivestreamMediaSourceImageAtPath:(imagePath ?: @"") completion:reply];
    } else {
        [graphSession setLivestreamMediaSourceCameraWithCompletion:reply];
    }
}

// ── Attach ───────────────────────────────────────────────────────────────────

- (void)attachWithArguments:(id)arguments
               graphSession:(VGCameraGraphSession *)graphSession
                     result:(FlutterResult)result {
    NSString *trackId = nil;
    if ([arguments isKindOfClass:[NSDictionary class]]) {
        id raw = ((NSDictionary *)arguments)[@"trackId"];
        if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] > 0) {
            trackId = raw;
        }
    }
    if (!trackId) {
        result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                   message:@"trackId must be a non-empty string"
                                   details:nil]);
        return;
    }
    if (!graphSession) {
        // Nothing has been touched: the stock capturer keeps publishing.
        result([FlutterError errorWithCode:@"NO_CAMERA_GRAPH"
                                   message:@"No active Vanguard camera graph session"
                                   details:nil]);
        return;
    }

    // Idempotency / concurrency guards.
    os_unfair_lock_lock(&_lock);
    BOOL inProgress = _attachInProgress;
    BOOL sameTrackActive = (_activeVideoSource != nil && [_attachedTrackId isEqualToString:trackId]);
    BOOL otherTrackActive = (_activeVideoSource != nil && !sameTrackActive);
    os_unfair_lock_unlock(&_lock);
    if (inProgress) {
        result([FlutterError errorWithCode:@"ATTACH_IN_PROGRESS"
                                   message:@"An attach is already in progress"
                                   details:nil]);
        return;
    }
    if (sameTrackActive) {
        result([self attachedReply]);
        return;
    }
    if (otherTrackActive) {
        [self detach];
    }

    // Resolve flutter_webrtc internals. No side effects yet.
    id videoSource = nil;
    VGRTCCapturerStopHandler stopHandler = nil;
    id stockCapturer = nil;
    NSString *failureCode = nil;
    NSString *failureMessage = nil;
    if (![self resolveWebRTCForTrackId:trackId
                           videoSource:&videoSource
                           stopHandler:&stopHandler
                         stockCapturer:&stockCapturer
                           failureCode:&failureCode
                               message:&failureMessage]) {
        NSLog(@"%@ attach rejected (%@): %@", kVGRTCTag, failureCode, failureMessage);
        result([FlutterError errorWithCode:failureCode message:failureMessage details:nil]);
        return;
    }

    if (![self resolveRTCFrameClasses]) {
        result([FlutterError errorWithCode:@"WEBRTC_INTERNALS_UNAVAILABLE"
                                   message:@"RTCCVPixelBuffer / RTCVideoFrame classes are not loaded"
                                   details:nil]);
        return;
    }

    if (![self ensureReceiverConnectedToGraphSession:graphSession]) {
        // The session keeps its previous graph; the stock capturer is untouched.
        result([FlutterError errorWithCode:@"GRAPH_CONNECT_FAILED"
                                   message:@"VGCameraGraphSession refused the processed-frame receiver"
                                   details:nil]);
        return;
    }

    // Arm the attach. The gate stays closed until the stock capturer stops so
    // stock and processed frames never interleave on the same track.
    uint64_t generation;
    os_unfair_lock_lock(&_lock);
    _attachGeneration += 1;
    generation = _attachGeneration;
    _attachInProgress = YES;
    _gateOpen = NO;
    _stockStopConfirmed = NO;
    _activeVideoSource = videoSource;
    _attachedTrackId = [trackId copy];
    _framesDelivered = 0;
    _pendingAttachResult = [result copy];
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    void (^openGate)(BOOL) = ^(BOOL confirmed) {
        [weakSelf finishAttachForGeneration:generation stockStopConfirmed:confirmed];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kVGRTCStockStopTimeoutNs),
                   dispatch_get_main_queue(), ^{
        openGate(NO);
    });

    if (stopHandler) {
        NSLog(@"%@ stopping stock capturer for track %@ via per-track stop handler", kVGRTCTag, trackId);
        stopHandler(^{
            dispatch_async(dispatch_get_main_queue(), ^{ openGate(YES); });
        });
    } else {
        NSLog(@"%@ stopping stock capturer for track %@ via stopCaptureWithCompletionHandler:", kVGRTCTag, trackId);
        SEL stopSel = NSSelectorFromString(@"stopCaptureWithCompletionHandler:");
        VGRTCCompletionHandler completion = ^{
            dispatch_async(dispatch_get_main_queue(), ^{ openGate(YES); });
        };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [stockCapturer performSelector:stopSel withObject:completion];
#pragma clang diagnostic pop
    }
}

// Main thread. Resolves the WebRTC frame classes once (immutable afterwards,
// set before any gate opens). NO when WebRTC.framework does not provide them.
- (BOOL)resolveRTCFrameClasses {
    if (!_rtcPixelBufferClass) _rtcPixelBufferClass = NSClassFromString(@"RTCCVPixelBuffer");
    if (!_rtcVideoFrameClass) _rtcVideoFrameClass = NSClassFromString(@"RTCVideoFrame");
    return _rtcPixelBufferClass != nil && _rtcVideoFrameClass != nil;
}

// Main thread. Connects this receiver to the graph unless it already is: one
// fan-out rebuild per graph session, and none on re-attach after a detach.
// NO when the session refused the receiver (it keeps its previous graph).
- (BOOL)ensureReceiverConnectedToGraphSession:(VGCameraGraphSession *)graphSession {
    os_unfair_lock_lock(&_lock);
    BOOL alreadyConnected = (_connectedGraphSession != nil && _connectedGraphSession == graphSession);
    os_unfair_lock_unlock(&_lock);
    if (alreadyConnected) {
        NSLog(@"%@ receiver already connected to graph session %p (reused)", kVGRTCTag, graphSession);
        return YES;
    }
    if (![graphSession connectProcessedFrameReceiver:self]) {
        return NO;
    }
    os_unfair_lock_lock(&_lock);
    _connectedGraphSession = graphSession;
    os_unfair_lock_unlock(&_lock);
    NSLog(@"%@ receiver connected to graph session %p (fan-out rebuilt)", kVGRTCTag, graphSession);
    return YES;
}

// Main thread. Called by the stock-stop completion (confirmed=YES) and by the
// 1 s timeout (confirmed=NO); only the first caller for a generation replies.
- (void)finishAttachForGeneration:(uint64_t)generation stockStopConfirmed:(BOOL)confirmed {
    FlutterResult reply = nil;
    NSDictionary *payload = nil;
    BOOL opened = NO;
    BOOL lateConfirmation = NO;
    VGCameraGraphSession *graphSession = nil;

    os_unfair_lock_lock(&_lock);
    if (generation == _attachGeneration) {
        if (_attachInProgress) {
            _attachInProgress = NO;
            _gateOpen = YES;
            _stockStopConfirmed = confirmed;
            opened = YES;
            reply = _pendingAttachResult;
            _pendingAttachResult = nil;
            payload = @{
                @"status": @"attached",
                @"trackId": _attachedTrackId ?: @"",
                @"framesDelivered": @(_framesDelivered),
                @"stockStopConfirmed": @(confirmed),
            };
        } else if (confirmed && _gateOpen && !_stockStopConfirmed) {
            // Timeout won the race; record the late confirmation for getStats.
            _stockStopConfirmed = YES;
            lateConfirmation = YES;
        }
        graphSession = _connectedGraphSession;
    }
    os_unfair_lock_unlock(&_lock);

    if (opened) {
        NSLog(@"%@ egress gate open (stockStopConfirmed=%d)", kVGRTCTag, confirmed);
    } else if (lateConfirmation) {
        NSLog(@"%@ stock capturer stop confirmed after the 1 s timeout", kVGRTCTag);
    }

    // Capture resume kick. connectProcessedFrameReceiver: ran the source start
    // path while the stock capturer still held the camera, so the Vanguard
    // AVCaptureSession may be stopped/interrupted; nothing else restarts it
    // until a filter transaction rebuilds the graph. Once the stock capturer
    // has confirmed its stop (immediately or late), run that same start path
    // again. Idempotent: it is a no-op while the session already runs, and it
    // never rebuilds the graph.
    if (confirmed && (opened || lateConfirmation)) {
        if (graphSession) {
            NSLog(@"%@ stock capturer stopped — resuming Vanguard capture source", kVGRTCTag);
            [graphSession resumeCaptureSourceIfStopped];
        } else {
            NSLog(@"%@ stock capturer stopped but no connected graph session to resume", kVGRTCTag);
        }
    } else if (opened) {
        NSLog(@"%@ gate opened on timeout; capture resume waits for the stock stop confirmation", kVGRTCTag);
    }

    if (reply) {
        reply(payload);
    }
}

- (NSDictionary *)attachedReply {
    os_unfair_lock_lock(&_lock);
    NSDictionary *payload = @{
        @"status": @"attached",
        @"trackId": _attachedTrackId ?: @"",
        @"framesDelivered": @(_framesDelivered),
        @"stockStopConfirmed": @(_stockStopConfirmed),
    };
    os_unfair_lock_unlock(&_lock);
    return payload;
}

// ── flutter_webrtc resolution (no side effects) ──────────────────────────────

- (BOOL)resolveWebRTCForTrackId:(NSString *)trackId
                    videoSource:(id *)outVideoSource
                    stopHandler:(VGRTCCapturerStopHandler *)outStopHandler
                  stockCapturer:(id *)outStockCapturer
                    failureCode:(NSString **)outCode
                        message:(NSString **)outMessage {
    Class webrtcPluginClass = NSClassFromString(@"FlutterWebRTCPlugin");
    SEL sharedSingletonSel = NSSelectorFromString(@"sharedSingleton");
    if (!webrtcPluginClass || ![webrtcPluginClass respondsToSelector:sharedSingletonSel]) {
        *outCode = @"WEBRTC_INTERNALS_UNAVAILABLE";
        *outMessage = @"flutter_webrtc plugin class or sharedSingleton not found";
        return NO;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id plugin = [webrtcPluginClass performSelector:sharedSingletonSel];
#pragma clang diagnostic pop
    if (!plugin) {
        *outCode = @"WEBRTC_INTERNALS_UNAVAILABLE";
        *outMessage = @"flutter_webrtc sharedSingleton returned nil";
        return NO;
    }

    id localTrack = nil;
    id videoSource = nil;
    id stopHandler = nil;
    id stockCapturer = nil;
    @try {
        id localTracks = [plugin valueForKey:@"localTracks"];
        if ([localTracks isKindOfClass:[NSDictionary class]]) {
            localTrack = ((NSDictionary *)localTracks)[trackId];
        }
        if (localTrack) {
            SEL sourceSel = NSSelectorFromString(@"source");
            id processing = [localTrack valueForKey:@"processing"];
            if (processing && [processing respondsToSelector:sourceSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                videoSource = [processing performSelector:sourceSel];
#pragma clang diagnostic pop
            }
            if (!videoSource) {
                id videoTrack = [localTrack valueForKey:@"videoTrack"];
                if (videoTrack && [videoTrack respondsToSelector:sourceSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    videoSource = [videoTrack performSelector:sourceSel];
#pragma clang diagnostic pop
                }
            }
        }
        id handlers = [plugin valueForKey:@"videoCapturerStopHandlers"];
        if ([handlers isKindOfClass:[NSDictionary class]]) {
            stopHandler = ((NSDictionary *)handlers)[trackId];
        }
        stockCapturer = [plugin valueForKey:@"videoCapturer"];
    } @catch (NSException *exception) {
        *outCode = @"WEBRTC_INTERNALS_UNAVAILABLE";
        *outMessage = [NSString stringWithFormat:@"flutter_webrtc internals changed: %@", exception.reason];
        return NO;
    }

    if (!localTrack) {
        *outCode = @"TRACK_NOT_FOUND";
        *outMessage = [NSString stringWithFormat:@"Track %@ not found in flutter_webrtc local tracks", trackId];
        return NO;
    }
    if (!videoSource || ![videoSource respondsToSelector:@selector(capturer:didCaptureVideoFrame:)]) {
        *outCode = @"WEBRTC_INTERNALS_UNAVAILABLE";
        *outMessage = @"RTCVideoSource not found on the local track";
        return NO;
    }
    SEL stopSel = NSSelectorFromString(@"stopCaptureWithCompletionHandler:");
    BOOL capturerCanStop = (stockCapturer != nil && [stockCapturer respondsToSelector:stopSel]);
    if (!stopHandler && !capturerCanStop) {
        *outCode = @"WEBRTC_INTERNALS_UNAVAILABLE";
        *outMessage = @"No stock capturer stop path for the local track";
        return NO;
    }

    *outVideoSource = videoSource;
    *outStopHandler = (VGRTCCapturerStopHandler)stopHandler;
    *outStockCapturer = capturerCanStop ? stockCapturer : nil;
    return YES;
}

// ── Detach ───────────────────────────────────────────────────────────────────

- (void)detach {
    [self detachRestoringLivestreamMediaSource:YES];
}

// I1: with `restore`, an image source left live on the connected graph session
// is switched back to the camera once the egress is gone (WebRTC onStop,
// explicit detach, track replacement). Graph teardown passes NO because the
// session is about to be invalidated anyway.
- (void)detachRestoringLivestreamMediaSource:(BOOL)restore {
    FlutterResult pending = nil;
    FlutterResult pendingSwitch = nil;
    NSString *trackId = nil;
    uint64_t frames = 0;
    BOOL wasActive = NO;
    VGCameraGraphSession *graphSession = nil;

    // I2: the standalone pump and any armed initial source never outlive the
    // egress; an in-flight image-first → camera hand-over is cancelled.
    [self stopImagePump];
    [self clearPendingInitialMediaSourceWithReason:@"detach"];

    os_unfair_lock_lock(&_lock);
    graphSession = _connectedGraphSession;
    _attachGeneration += 1;  // any in-flight stock-stop completion / timeout is now stale
    pending = _pendingAttachResult;
    _pendingAttachResult = nil;
    pendingSwitch = _pendingImageFirstSwitchResult;
    _pendingImageFirstSwitchResult = nil;
    _imageFirstSwitchGeneration += 1;
    trackId = _attachedTrackId;
    frames = _framesDelivered;
    wasActive = (_activeVideoSource != nil) || _attachInProgress;
    _gateOpen = NO;
    _attachInProgress = NO;
    _stockStopConfirmed = NO;
    _activeVideoSource = nil;
    _attachedTrackId = nil;
    _virtualSource = NO;
    os_unfair_lock_unlock(&_lock);

    if (pending) {
        pending([FlutterError errorWithCode:@"ATTACH_CANCELLED"
                                    message:@"Detached before the attach completed"
                                    details:nil]);
    }
    if (pendingSwitch) {
        pendingSwitch([FlutterError errorWithCode:@"EGRESS_STOPPED"
                                          message:@"Detached before the camera hand-over completed"
                                          details:nil]);
    }
    // The receiver stays connected to the graph (inert while the gate is
    // closed); the graph is never rebuilt and the stock capturer never
    // restarted here.
    if (wasActive) {
        NSLog(@"%@ detached from track %@ after %llu frames. Egress stopped", kVGRTCTag, trackId, frames);
    }
    if (restore && wasActive && graphSession) {
        // Camera-first baseline for whatever track comes next; no-op in camera mode.
        [graphSession restoreLivestreamCameraSourceForEgressStop];
    }
}

// ── Virtual camera provider (flutter_webrtc external video source SPI) ───────

- (BOOL)registerAsVirtualCameraProvider {
    Class pluginClass = NSClassFromString(@"FlutterWebRTCPlugin");
    SEL registerSel = NSSelectorFromString(@"registerExternalVideoSourceProvider:forDeviceId:");
    if (!pluginClass || ![pluginClass respondsToSelector:registerSel]) {
        NSLog(@"%@ flutter_webrtc external video source SPI not present; virtual camera unavailable", kVGRTCTag);
        return NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [pluginClass performSelector:registerSel withObject:self withObject:kVGRTCVirtualCameraDeviceId];
#pragma clang diagnostic pop
    NSLog(@"%@ virtual camera provider registered for deviceId %@", kVGRTCTag, kVGRTCVirtualCameraDeviceId);
    return YES;
}

- (void)unregisterAsVirtualCameraProvider {
    Class pluginClass = NSClassFromString(@"FlutterWebRTCPlugin");
    SEL unregisterSel = NSSelectorFromString(@"unregisterExternalVideoSourceProviderForDeviceId:");
    if (!pluginClass || ![pluginClass respondsToSelector:unregisterSel]) {
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [pluginClass performSelector:unregisterSel withObject:kVGRTCVirtualCameraDeviceId];
#pragma clang diagnostic pop
}

- (NSDictionary<NSString *, NSNumber *> *)externalVideoSourceOutputFormat {
    return @{
        @"width": @(kVGRTCVirtualCameraWidth),
        @"height": @(kVGRTCVirtualCameraHeight),
        @"frameRate": @(kVGRTCVirtualCameraFps),
    };
}

- (BOOL)startExternalVideoSourceForTrackId:(NSString *)trackId sink:(id)sink {
    if (trackId.length == 0 || ![sink respondsToSelector:@selector(capturer:didCaptureVideoFrame:)]) {
        NSLog(@"%@ virtual camera start rejected: invalid track id or sink", kVGRTCTag);
        return NO;
    }

    // I2: consume an armed image start FIRST (the detach below would clear
    // it). With one, no camera graph is required and none is touched.
    CVPixelBufferRef initialBuffer = NULL;
    NSString *initialPath = nil;
    os_unfair_lock_lock(&_lock);
    if ([_pendingInitialMode isEqualToString:kVGRTCInitialModeImage] && _pendingInitialBuffer) {
        initialBuffer = _pendingInitialBuffer;
        _pendingInitialBuffer = NULL;
        initialPath = _pendingInitialImagePath;
    }
    _pendingInitialMode = nil;
    _pendingInitialImagePath = nil;
    _initialGeneration += 1;
    os_unfair_lock_unlock(&_lock);

    if (initialBuffer) {
        if (![self resolveRTCFrameClasses]) {
            CVPixelBufferRelease(initialBuffer);
            NSLog(@"%@ image-first start rejected for %@: RTCCVPixelBuffer / RTCVideoFrame not loaded", kVGRTCTag, trackId);
            return NO;
        }
        // One egress at a time (also stops any older standalone pump).
        [self detach];
        os_unfair_lock_lock(&_lock);
        _attachGeneration += 1;
        _activeVideoSource = sink;
        _attachedTrackId = [trackId copy];
        _framesDelivered = 0;
        _attachInProgress = NO;
        _stockStopConfirmed = NO;
        _virtualSource = YES;
        _gateOpen = YES;
        _imageFirstActive = YES;
        _awaitingGraphFrame = NO;
        _imagePumpBuffer = initialBuffer;   // adopt the +1
        _imagePumpPath = initialPath;
        _imagePumpMuted = NO;
        _imagePumpFrames = 0;
        os_unfair_lock_unlock(&_lock);
        [self startImagePumpTimer];
        NSLog(@"%@ virtual camera started image-first for track %@ (%ldx%ld@%ld, path=%@, camera closed, no stock capturer)",
              kVGRTCTag, trackId, (long)kVGRTCVirtualCameraWidth, (long)kVGRTCVirtualCameraHeight,
              (long)kVGRTCVirtualCameraFps, initialPath ?: @"");
        return YES;
    }

    // Camera-first (default, unchanged below): the live camera graph feeds the track.
    os_unfair_lock_lock(&_lock);
    VGRTCGraphSessionProvider provider = _graphSessionProvider;
    os_unfair_lock_unlock(&_lock);
    VGCameraGraphSession *graphSession = provider ? provider() : nil;
    if (!graphSession) {
        NSLog(@"%@ virtual camera start rejected for %@: no active Vanguard camera graph session", kVGRTCTag, trackId);
        return NO;
    }
    if (![self resolveRTCFrameClasses]) {
        NSLog(@"%@ virtual camera start rejected for %@: RTCCVPixelBuffer / RTCVideoFrame not loaded", kVGRTCTag, trackId);
        return NO;
    }

    // One egress at a time: a legacy attach or an earlier virtual track (e.g.
    // a LiveKit restartTrack) gives way to this one.
    [self detach];

    if (![self ensureReceiverConnectedToGraphSession:graphSession]) {
        NSLog(@"%@ virtual camera start rejected for %@: graph session refused the receiver", kVGRTCTag, trackId);
        return NO;
    }

    // No stock capturer exists for this track, so the gate opens at once.
    os_unfair_lock_lock(&_lock);
    _attachGeneration += 1;
    _activeVideoSource = sink;
    _attachedTrackId = [trackId copy];
    _framesDelivered = 0;
    _attachInProgress = NO;
    _stockStopConfirmed = NO;
    _virtualSource = YES;
    _gateOpen = YES;
    os_unfair_lock_unlock(&_lock);

    // No-op while the Vanguard AVCaptureSession runs (nothing contends for the
    // camera on this path); restarts it if it was interrupted.
    [graphSession resumeCaptureSourceIfStopped];
    NSLog(@"%@ virtual camera started for track %@ (%ldx%ld@%ld, no stock capturer)", kVGRTCTag, trackId,
          (long)kVGRTCVirtualCameraWidth, (long)kVGRTCVirtualCameraHeight, (long)kVGRTCVirtualCameraFps);
    return YES;
}

- (void)stopExternalVideoSourceForTrackId:(NSString *)trackId {
    os_unfair_lock_lock(&_lock);
    BOOL matches = _virtualSource && [_attachedTrackId isEqualToString:trackId];
    os_unfair_lock_unlock(&_lock);
    if (!matches) {
        NSLog(@"%@ virtual camera stop for %@ ignored (egress not bound to it)", kVGRTCTag, trackId);
        return;
    }
    [self detach];
    NSLog(@"%@ virtual camera stopped for track %@", kVGRTCTag, trackId);
}

- (void)detachForGraphSessionTeardown:(VGCameraGraphSession *)session {
    os_unfair_lock_lock(&_lock);
    VGCameraGraphSession *connected = _connectedGraphSession;
    BOOL matches = (session == nil) || (connected == nil) || (connected == session);
    const BOOL imageFirst = _imageFirstActive;
    FlutterResult pendingSwitch = nil;
    if (matches) {
        _connectedGraphSession = nil;
        if (imageFirst) {
            // I2: the standalone pump does not depend on any camera graph; an
            // unfinished hand-over to this session is cancelled, the pump stays.
            _awaitingGraphFrame = NO;
            _imageFirstSwitchGeneration += 1;
            pendingSwitch = _pendingImageFirstSwitchResult;
            _pendingImageFirstSwitchResult = nil;
        }
    }
    os_unfair_lock_unlock(&_lock);

    if (matches && imageFirst) {
        if (pendingSwitch) {
            pendingSwitch([FlutterError errorWithCode:@"CAMERA_STOPPED"
                                              message:@"The camera graph was torn down before the hand-over; image producer kept"
                                              details:nil]);
        }
        NSLog(@"%@ graph session %p tearing down while image-first: receiver dropped, image producer kept", kVGRTCTag, session);
        return;
    }
    if (matches) {
        [self detachRestoringLivestreamMediaSource:NO];
        NSLog(@"%@ graph session %p tearing down: egress detached, receiver dropped", kVGRTCTag, session);
    } else {
        NSLog(@"%@ graph session %p tearing down but egress is bound to %p: ignored", kVGRTCTag, session, connected);
    }
}

// ── VanguardCameraFrameReceiver (graph execution queue) ──────────────────────

- (void)onFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts {
    if (!pixelBuffer) return;

    BOOL handOver = NO;
    os_unfair_lock_lock(&_lock);
    if (_imageFirstActive) {
        // I2: while the standalone pump is the producer, camera-graph frames
        // are not forwarded — except the first one after an image-first →
        // camera request, which mutes the pump and completes the hand-over.
        if (!_awaitingGraphFrame) {
            os_unfair_lock_unlock(&_lock);
            return;
        }
        _awaitingGraphFrame = NO;
        _imagePumpMuted = YES;
        handOver = YES;
    }
    id source = _gateOpen ? _activeVideoSource : nil;
    Class pixelBufferClass = _rtcPixelBufferClass;
    Class videoFrameClass = _rtcVideoFrameClass;
    os_unfair_lock_unlock(&_lock);
    if (handOver) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishImageFirstSwitchToCamera]; });
    }
    if (!source || !pixelBufferClass || !videoFrameClass) return;

    // RTCCVPixelBuffer retains the CVPixelBuffer, so +0 delivery from the
    // fan-out is safe; the graph may recycle its buffer after we return.
    RTCCVPixelBuffer *rtcBuffer = [[pixelBufferClass alloc] initWithPixelBuffer:pixelBuffer];
    if (!rtcBuffer) return;

    int64_t timeStampNs;
    if (CMTIME_IS_NUMERIC(pts)) {
        timeStampNs = (int64_t)(CMTimeGetSeconds(pts) * 1000000000.0);
    } else {
        timeStampNs = (int64_t)clock_gettime_nsec_np(CLOCK_MONOTONIC);
    }
    RTCVideoFrame *frame = [[videoFrameClass alloc] initWithBuffer:rtcBuffer
                                                          rotation:0
                                                       timeStampNs:timeStampNs];
    if (!frame) return;

    [(id<RTCVideoCapturerDelegate>)source capturer:self didCaptureVideoFrame:frame];

    os_unfair_lock_lock(&_lock);
    uint64_t count = ++_framesDelivered;
    os_unfair_lock_unlock(&_lock);

    if (count == 1 || count % kVGRTCPeriodicLogFrames == 0) {
        NSLog(@"%@ delivered %llu frames to WebRTC (%zux%zu %@)",
              kVGRTCTag, count,
              CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
              VGRTCFourCC(CVPixelBufferGetPixelFormatType(pixelBuffer)));
    }
}

// Required by VanguardCameraFrameReceiver; only the preview MTKView cares about
// the throttle hint. Egress forwards whatever the graph emits.
- (void)setPreviewFPS:(NSInteger)fps {
    (void)fps;
}

// ── Stats / Properties ───────────────────────────────────────────────────────

- (NSDictionary *)statsSnapshot {
    // I1: the committed producer comes from the graph session (serialized on
    // its own queue; stats are read from the main thread, never from it).
    os_unfair_lock_lock(&_lock);
    const BOOL streamingNow = (_gateOpen && _activeVideoSource != nil);
    const BOOL imageFirstNow = _imageFirstActive;
    NSString *imageFirstPath = _imagePumpPath;
    NSString *pendingInitialMode = _pendingInitialMode;
    VGRTCGraphSessionProvider provider = _graphSessionProvider;
    os_unfair_lock_unlock(&_lock);
    NSString *mediaSource = @"camera";
    NSString *mediaSourceImagePath = nil;
    if (imageFirstNow) {
        // I2: the standalone pump is the producer; no graph session is asked.
        mediaSource = kVGRTCInitialModeImage;
        mediaSourceImagePath = imageFirstPath;
    } else {
        VGCameraGraphSession *graphSession = (streamingNow && provider) ? provider() : nil;
        mediaSource = graphSession ? [graphSession livestreamMediaSourceModeName] : @"camera";
        mediaSourceImagePath = graphSession ? [graphSession livestreamMediaSourceImagePath] : nil;
    }

    os_unfair_lock_lock(&_lock);
    NSDictionary *snapshot = @{
        @"isStreaming": @(_gateOpen && _activeVideoSource != nil),
        @"framesDelivered": @(_framesDelivered),
        @"trackId": _attachedTrackId ?: @"",
        @"stockStopConfirmed": @(_stockStopConfirmed),
        @"attachInProgress": @(_attachInProgress),
        @"receiverConnected": @(_connectedGraphSession != nil),
        @"mode": _virtualSource ? @"virtual" : (_activeVideoSource != nil ? @"attached" : @"idle"),
        @"mediaSource": mediaSource,
        @"mediaSourceImagePath": mediaSourceImagePath ?: [NSNull null],
        @"imageFirst": @(imageFirstNow),
        @"pendingInitialMediaSource": pendingInitialMode ?: [NSNull null],
    };
    os_unfair_lock_unlock(&_lock);
    return snapshot;
}

- (uint64_t)framesDelivered {
    os_unfair_lock_lock(&_lock);
    uint64_t count = _framesDelivered;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (BOOL)isStreaming {
    os_unfair_lock_lock(&_lock);
    BOOL streaming = _gateOpen && _activeVideoSource != nil;
    os_unfair_lock_unlock(&_lock);
    return streaming;
}

@end
