// VanguardRTCVideoCapturer.m
// Vanguard Media Engine -> LiveKit LiveStreaming Egress Bridge
// Isolated Proof of Concept

#import "VanguardRTCVideoCapturer.h"
#import <objc/runtime.h>
#import <os/lock.h>

// ── WebRTC Forward Declarations (Dynamic Runtime Binding) ────────────────────
// Using forward declarations allows compiling without adding a static pod dependency
// to vanguard_media_engine.podspec. Symbols are resolved dynamically from WebRTC.framework.

@interface RTCCVPixelBuffer : NSObject
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@interface RTCVideoFrame : NSObject
- (instancetype)initWithBuffer:(id)buffer rotation:(NSInteger)rotation timeStampNs:(int64_t)timeStampNs;
@end

@protocol RTCVideoCapturerDelegate <NSObject>
- (void)capturer:(id)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame;
@end

@interface RTCVideoSource : NSObject <RTCVideoCapturerDelegate>
- (void)capturer:(id)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame;
@end

// ── Private Interface ────────────────────────────────────────────────────────

@interface VanguardRTCVideoCapturer () {
    os_unfair_lock _lock;
    id _activeVideoSource;
    uint64_t _framesDelivered;
    BOOL _isStreaming;
    NSString *_attachedTrackId;
}
@end

@implementation VanguardRTCVideoCapturer

static VanguardRTCVideoCapturer *_sharedInstance = nil;
static FlutterMethodChannel *_methodChannel = nil;
static BOOL _swizzleInstalled = NO;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[VanguardRTCVideoCapturer alloc] init];
    });
    return _sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _activeVideoSource = nil;
        _framesDelivered = 0;
        _isStreaming = NO;
        _attachedTrackId = nil;
    }
    return self;
}

// ── Auto-Registration on Startup ─────────────────────────────────────────────

+ (void)load {
    // Automatically install hooks when framework is mapped into process space.
    static dispatch_once_t loadToken;
    dispatch_once(&loadToken, ^{
        [self installSwizzles];
    });
}

+ (void)installSwizzles {
    // 1. Swizzle VanguardCameraPlatformView.onFrame:pts:
    // This allows capturing Metal-processed frames without altering VanguardCameraPlatformView.swift.
    Class pvClass = NSClassFromString(@"vanguard_media_engine.VanguardCameraPlatformView");
    if (!pvClass) {
        pvClass = NSClassFromString(@"VanguardCameraPlatformView");
    }

    if (pvClass) {
        SEL originalSel = NSSelectorFromString(@"onFrame:pts:");
        SEL swizzledSel = @selector(vanguardRTC_swizzled_onFrame:pts:);

        Method origMethod = class_getInstanceMethod(pvClass, originalSel);
        Method swizMethod = class_getInstanceMethod([self class], swizzledSel);

        if (origMethod && swizMethod) {
            BOOL didAdd = class_addMethod(pvClass,
                                          swizzledSel,
                                          method_getImplementation(origMethod),
                                          method_getTypeEncoding(origMethod));
            if (didAdd) {
                class_replaceMethod(pvClass,
                                    originalSel,
                                    method_getImplementation(swizMethod),
                                    method_getTypeEncoding(swizMethod));
            } else {
                method_exchangeImplementations(origMethod, swizMethod);
            }
            NSLog(@"[VanguardRTC] Swizzled VanguardCameraPlatformView.onFrame:pts: successfully ✓");
            _swizzleInstalled = YES;
        }
    } else {
        NSLog(@"[VanguardRTC] Note: VanguardCameraPlatformView class not found yet during +load. Will retry on attach.");
    }
}

// Swizzled method injected into VanguardCameraPlatformView
- (void)vanguardRTC_swizzled_onFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts {
    // 1. Call original VanguardCameraPlatformView implementation (renders to MTKView)
    [self vanguardRTC_swizzled_onFrame:pixelBuffer pts:pts];

    // 2. Deliver zero-copy frame to WebRTC if streaming
    [VanguardRTCVideoCapturer deliverFrame:pixelBuffer pts:pts];
}

// ── MethodChannel Setup ──────────────────────────────────────────────────────

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    [self setupMethodChannelWithMessenger:[registrar messenger]];
}

+ (void)setupMethodChannelWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    static dispatch_once_t channelToken;
    dispatch_once(&channelToken, ^{
        _methodChannel = [FlutterMethodChannel methodChannelWithName:@"vanguard_livekit_bridge"
                                                     binaryMessenger:messenger];
        [_methodChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
            [[VanguardRTCVideoCapturer sharedInstance] handleMethodCall:call result:result];
        }];
        NSLog(@"[VanguardRTC] MethodChannel 'vanguard_livekit_bridge' registered successfully ✓");
    });
}

// ── Flutter Method Routing ───────────────────────────────────────────────────

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([@"attachVanguardToLiveKitTrack" isEqualToString:call.method]) {
        NSDictionary *args = [call arguments];
        NSString *trackId = args[@"trackId"];
        if (!trackId || ![trackId isKindOfClass:[NSString class]]) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"trackId must be a non-empty string"
                                       details:nil]);
            return;
        }

        NSError *error = nil;
        BOOL ok = [self attachToTrackId:trackId error:&error];
        if (ok) {
            result(@{
                @"status": @"attached",
                @"trackId": trackId,
                @"framesDelivered": @(_framesDelivered)
            });
        } else {
            result([FlutterError errorWithCode:@"ATTACH_FAILED"
                                       message:error.localizedDescription ?: @"Failed to attach to WebRTC track"
                                       details:nil]);
        }
    } else if ([@"detachVanguard" isEqualToString:call.method]) {
        [self detach];
        result(@{@"status": @"detached"});
    } else if ([@"getStats" isEqualToString:call.method]) {
        os_unfair_lock_lock(&_lock);
        uint64_t count = _framesDelivered;
        BOOL streaming = _isStreaming;
        NSString *tid = _attachedTrackId ?: @"";
        os_unfair_lock_unlock(&_lock);

        result(@{
            @"isStreaming": @(streaming),
            @"framesDelivered": @(count),
            @"trackId": tid,
            @"swizzleInstalled": @(_swizzleInstalled)
        });
    } else {
        result(FlutterMethodNotImplemented);
    }
}

// ── WebRTC Attach / Detach ───────────────────────────────────────────────────

- (BOOL)attachToTrackId:(NSString *)trackId error:(NSError **)error {
    // Ensure swizzle is active
    if (!_swizzleInstalled) {
        [VanguardRTCVideoCapturer installSwizzles];
    }

    // 1. Locate FlutterWebRTCPlugin singleton
    Class webrtcPluginClass = NSClassFromString(@"FlutterWebRTCPlugin");
    if (!webrtcPluginClass) {
        if (error) {
            *error = [NSError errorWithDomain:@"VanguardRTC"
                                         code:101
                                     userInfo:@{NSLocalizedDescriptionKey: @"FlutterWebRTCPlugin class not loaded"}];
        }
        return NO;
    }

    SEL sharedSingletonSel = NSSelectorFromString(@"sharedSingleton");
    if (![webrtcPluginClass respondsToSelector:sharedSingletonSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"VanguardRTC"
                                         code:102
                                     userInfo:@{NSLocalizedDescriptionKey: @"FlutterWebRTCPlugin.sharedSingleton not found"}];
        }
        return NO;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSObject *plugin = [webrtcPluginClass performSelector:sharedSingletonSel];
#pragma clang diagnostic pop

    if (!plugin) {
        if (error) {
            *error = [NSError errorWithDomain:@"VanguardRTC"
                                         code:103
                                     userInfo:@{NSLocalizedDescriptionKey: @"FlutterWebRTCPlugin.sharedSingleton returned nil"}];
        }
        return NO;
    }

    // Ensure our method channel is ready
    NSObject<FlutterBinaryMessenger> *messenger = [plugin valueForKey:@"messenger"];
    if (messenger && !_methodChannel) {
        [VanguardRTCVideoCapturer setupMethodChannelWithMessenger:messenger];
    }

    // 2. Locate local track in plugin.localTracks
    NSDictionary *localTracks = [plugin valueForKey:@"localTracks"];
    id localTrack = localTracks[trackId];
    if (!localTrack) {
        if (error) {
            *error = [NSError errorWithDomain:@"VanguardRTC"
                                         code:104
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Track %@ not found in localTracks", trackId]}];
        }
        return NO;
    }

    // 3. Extract the underlying RTCVideoSource
    id videoSource = nil;
    @try {
        id processing = [localTrack valueForKey:@"processing"];
        if (processing && [processing respondsToSelector:NSSelectorFromString(@"source")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            videoSource = [processing performSelector:NSSelectorFromString(@"source")];
#pragma clang diagnostic pop
        }
        if (!videoSource) {
            id vt = [localTrack valueForKey:@"videoTrack"];
            if (vt && [vt respondsToSelector:NSSelectorFromString(@"source")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                videoSource = [vt performSelector:NSSelectorFromString(@"source")];
#pragma clang diagnostic pop
            }
        }
    } @catch (NSException *ex) {
        NSLog(@"[VanguardRTC] Exception finding videoSource: %@", ex);
    }

    if (!videoSource) {
        if (error) {
            *error = [NSError errorWithDomain:@"VanguardRTC"
                                         code:105
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not find RTCVideoSource on track"}];
        }
        return NO;
    }

    // 4. Stop stock camera capturer to avoid AVCaptureSession hardware contention
    @try {
        id stockCapturer = [plugin valueForKey:@"videoCapturer"];
        if (stockCapturer && [stockCapturer respondsToSelector:NSSelectorFromString(@"stopCapture")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [stockCapturer performSelector:NSSelectorFromString(@"stopCapture")];
#pragma clang diagnostic pop
            NSLog(@"[VanguardRTC] Stock RTCCameraVideoCapturer stopped to prevent hardware contention ✓");
        }
    } @catch (NSException *ex) {
        NSLog(@"[VanguardRTC] Note: Could not stop stock capturer: %@", ex);
    }

    // 5. Activate streaming
    os_unfair_lock_lock(&_lock);
    _activeVideoSource = videoSource;
    _attachedTrackId = [trackId copy];
    _framesDelivered = 0;
    _isStreaming = YES;
    os_unfair_lock_unlock(&_lock);

    NSLog(@"[VanguardRTC] Attached to track %@ successfully. Egress active ✓", trackId);
    return YES;
}

- (void)detach {
    os_unfair_lock_lock(&_lock);
    _isStreaming = NO;
    _activeVideoSource = nil;
    _attachedTrackId = nil;
    os_unfair_lock_unlock(&_lock);

    NSLog(@"[VanguardRTC] Detached. Egress stopped ✓");
}

// ── Zero-Copy Frame Delivery ─────────────────────────────────────────────────

+ (void)deliverFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts {
    VanguardRTCVideoCapturer *capturer = [VanguardRTCVideoCapturer sharedInstance];
    if (!capturer->_isStreaming) return;

    os_unfair_lock_lock(&capturer->_lock);
    id videoSource = capturer->_activeVideoSource;
    BOOL streaming = capturer->_isStreaming;
    os_unfair_lock_unlock(&capturer->_lock);

    if (!streaming || !videoSource) return;

    // Resolve WebRTC classes dynamically
    Class rtcPixelBufferClass = NSClassFromString(@"RTCCVPixelBuffer");
    Class rtcVideoFrameClass = NSClassFromString(@"RTCVideoFrame");
    if (!rtcPixelBufferClass || !rtcVideoFrameClass) return;

    // 1. Wrap CVPixelBufferRef into RTCCVPixelBuffer (Zero-copy CoreVideo buffer)
    RTCCVPixelBuffer *rtcBuffer = [[rtcPixelBufferClass alloc] initWithPixelBuffer:pixelBuffer];
    if (!rtcBuffer) return;

    // 2. Wrap into RTCVideoFrame with nanosecond timestamp
    int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(pts) * 1000000000.0);
    RTCVideoFrame *frame = [[rtcVideoFrameClass alloc] initWithBuffer:rtcBuffer
                                                             rotation:0
                                                          timeStampNs:timeStampNs];
    if (!frame) return;

    // 3. Deliver to WebRTC RTCVideoSource
    [(id<RTCVideoCapturerDelegate>)videoSource capturer:capturer didCaptureVideoFrame:frame];

    os_unfair_lock_lock(&capturer->_lock);
    capturer->_framesDelivered++;
    uint64_t count = capturer->_framesDelivered;
    os_unfair_lock_unlock(&capturer->_lock);

    if (count == 1 || count % 300 == 0) {
        NSLog(@"[VanguardRTC] Delivered %llu frames to WebRTC hardware encoder ✓", count);
    }
}

// ── Properties ───────────────────────────────────────────────────────────────

- (uint64_t)framesDelivered {
    os_unfair_lock_lock(&_lock);
    uint64_t count = _framesDelivered;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (BOOL)isStreaming {
    os_unfair_lock_lock(&_lock);
    BOOL streaming = _isStreaming;
    os_unfair_lock_unlock(&_lock);
    return streaming;
}

@end
