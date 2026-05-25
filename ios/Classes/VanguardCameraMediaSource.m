// VanguardCameraMediaSource.m
// Phase 3: Camera source.
//
// Threading model:
//   _captureQueue (serial, .userInteractive): ALL AVCapture delegate callbacks,
//     ALL AVAssetWriter appends, ALL jitter + backpressure accounting.
//   Main thread: MTKView draw (via CADisplayLink), frameReceiver dispatch.
//   VT internal thread: vtOutputCallback (streaming path only, not
//   AVAssetWriter).
//
// Buffer ownership:
//   CVPixelBuffer from CMSampleBufferGetImageBuffer: +0 ref (owned by
//   CMSampleBuffer). Retained (+1) immediately for _latestBuffer; released when
//   replaced. appendPixelBuffer:withPresentationTime: is synchronous — no extra
//   retain needed. Max simultaneous retains: 2 (one in _latestBuffer, one in
//   MTKView draw).

#import "VanguardCameraMediaSource.h"
#import "VanguardMLGate.h"
#import <ImageIO/ImageIO.h>
#import <mach/mach.h>
#import <os/lock.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Internal recording state

typedef NS_ENUM(NSInteger, VanguardRecordingState) {
  VanguardRecordingStateIdle = 0,
  VanguardRecordingStateWriting = 1,
  VanguardRecordingStateFinishing = 2,
};

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Implementation

@interface VanguardCameraMediaSource () <
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate>
@end

@implementation VanguardCameraMediaSource {
  // ── Session ───────────────────────────────────────────────────────────────
  AVCaptureSession *_session;
  AVCaptureVideoDataOutput *_videoOutput;
  AVCaptureAudioDataOutput *_audioOutput;
  dispatch_queue_t _captureQueue;
  AVCaptureDevicePosition _position;
  int _targetFPS;

  // ── VanguardMediaSource callbacks ─────────────────────────────────────────
  void (^_videoCallback)(CVPixelBufferRef, CMTime);
  BOOL (^_audioCallback)(AudioBufferList *, CMTime); // unused in camera mode

  // ── Preview buffer (capture → MTKView) ───────────────────────────────────
  CVPixelBufferRef _latestBuffer;
  os_unfair_lock _latestBufferLock;

  // ── Jitter measurement (Welford online algorithm, O(1)) ───────────────────
  CMTime _lastFrameTime;
  uint64_t _jitterFrameCount;
  double _jitterMean; // seconds
  double _jitterM2;   // sum of squared deviations
  BOOL _previewThrottled;

  // ── Recording: AVAssetWriter path ────────────────────────────────────────
  AVAssetWriter *_assetWriter;
  AVAssetWriterInput *_videoWriterInput;
  AVAssetWriterInput *_audioWriterInput;
  AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;
  VanguardRecordingState _recordingState;
  BOOL _sessionStarted; // startSessionAtSourceTime: called
  void (^_stopCompletion)(NSURL *, NSUInteger, NSUInteger, NSError *);
  NSURL *_outputURL;

  // ── Backpressure accounting ───────────────────────────────────────────────
  int32_t _droppedFrameCount;
  int32_t _totalFrameCount;
  int32_t _consecutiveDropCount;
  // Sliding 2-second window (60-frame ring at 30fps)
  int32_t _windowDrops;  // drops in current 2s window
  int32_t _windowFrames; // frames in current 2s window
  NSTimeInterval _windowStart;
  // Tier 2 state
  int _recordingFrameSkip; // 1=normal, 2=halved
  int _frameSkipCounter;
  NSTimeInterval _tier2ActiveAt; // when Tier 2 was triggered

  // ── watchdog ──────────────────────────────────────────────────────────────
  NSTimeInterval _lastFrameWallTime;
  dispatch_source_t _watchdogTimer;

  // ── G-03: ML Gate — live wiring ───────────────────────────────────────────
  // Allocated in init; offerFrame: called on every video frame.
  // Gate performs O(1) checks: model state, thermal floor, minimum interval,
  // concurrent submission guard, and pool availability. Dispatches to _mlQueue
  // only when all gates pass.
  VanguardMLGate *_mlGate;
  CVPixelBufferPoolRef _mlInputPool; // 256x256 BGRA pool owned by this source
  dispatch_queue_t _mlQueue;
  id _thermalObserver;     // NSNotificationCenter token
  id _orientationObserver; // UIDevice orientation change token

  // ── Device controls & camera switching (Phases 2–3) ──────────────────────
  // _captureDevice: retained reference to the active video device; used by
  //   setZoom:, setFocusPoint:, setTorchMode:, and switchToPosition:.
  // _videoInput:    the active video device input; swapped atomically inside
  //   beginConfiguration/commitConfiguration by switchToPosition:.
  AVCaptureDevice *_captureDevice;
  AVCaptureDeviceInput *_videoInput;

  // ── Photo capture (Phase 4) ───────────────────────────────────────────────
  // _photoQueue: persistent serial queue for JPEG encode + file write.
  //   Allocated once in init; reused across shutter taps so no queue-create
  //   overhead per capture and consecutive taps are serialized.
  // _isSwitching: YES during the ~150ms moveCameraToPosition: reconfiguration
  //   window. Read and written exclusively on the main thread — no lock needed.
  dispatch_queue_t _photoQueue;
  BOOL _isSwitching;

  // ── Phase 6C: Preview orientation lock ───────────────────────────────────
  // When YES, _applyConnectionOrientationContract forces portrait orientation
  // and suppresses the device-rotation-triggered updates so capture buffers
  // remain stable at 1080x1920 while native camera preview is displayed.
  // Written on main thread only; read on main thread (orientation observer
  // fires on main queue). No lock needed.
  BOOL _previewOrientationLocked;
}

@synthesize captureSession = _session;

// Camera is a live source — playbackRate is always 1.0. Setting it is a no-op.
// Required for VanguardMediaSource protocol conformance.
@synthesize playbackRate = _playbackRate;

// Queue-specific key used by stopRecordingAndWait to assert it is not called
// from _captureQueue (which would deadlock via stopRecordingWithCompletion:).
static const char kCaptureQueueKey = 0;

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Init

- (instancetype)initWithPosition:(AVCaptureDevicePosition)position
                       frameRate:(int)fps {
  self = [super init];
  if (!self)
    return nil;

  _position = position;
  _targetFPS = fps;
  _latestBufferLock = OS_UNFAIR_LOCK_INIT;
  _lastFrameTime = kCMTimeInvalid;
  _recordingFrameSkip = 1;

  _captureQueue = dispatch_queue_create(
      "com.vanguard.capture",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                              QOS_CLASS_USER_INTERACTIVE, 0));
  // Mark the queue so stopRecordingAndWait can detect re-entrant calls.
  dispatch_queue_set_specific(_captureQueue, &kCaptureQueueKey,
                              (void *)&kCaptureQueueKey, NULL);

  // ── G-03: ML Gate allocation ──────────────────────────────────────────────
  // _mlQueue is a separate serial queue at .userInitiated priority.
  // Inference dispatched here; capture queue (.userInteractive) is never
  // blocked.
  _mlQueue = dispatch_queue_create(
      "com.vanguard.ml",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                              QOS_CLASS_USER_INITIATED, 0));

  // Persistent queue for JPEG encoding + file I/O (Phase 4).
  // Allocated here once; reused for every takePhotoToURL: call.
  _photoQueue = dispatch_queue_create(
      "com.vanguard.photo",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                              QOS_CLASS_USER_INITIATED, 0));

  // Create the raw CVPixelBufferPool that VanguardMLGate requires.
  // VanguardMLGate.initWithMLQueue:inputPool: takes a CVPixelBufferPoolRef
  // directly. Resolution: 256x256 BGRA — matches kMLInputWidth/kMLInputHeight
  // in VanguardMLGate.m
  NSDictionary *bufAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @256,
    (id)kCVPixelBufferHeightKey : @256,
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  // NULL poolAttrs: minimum buffer count is a hint only; pool allocates on
  // demand.
  CVReturn poolErr = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                             (__bridge CFDictionaryRef)bufAttrs,
                                             &_mlInputPool);
  if (poolErr != kCVReturnSuccess) {
    NSLog(@"[VanguardCamera] ML input pool creation failed (%d) — ML gate "
          @"disabled",
          poolErr);
    // Continue without ML gate (graceful degradation). _mlGate remains nil;
    // offerFrame: calls are guarded by nil-check.
  } else {
    // VanguardMLGate starts in Unloaded state; modelState is set to Ready by
    // the plugin after a CoreML model is loaded. Until then offerFrame: is
    // a pure O(1) gate-check that drops every frame (~2ns overhead).
    _mlGate = [[VanguardMLGate alloc] initWithMLQueue:_mlQueue
                                            inputPool:_mlInputPool
                                             delegate:nil];
    // delegate = nil until frameReceiver is set by the plugin after
    // PlatformView creation.
  }

  // ── G-04: Thermal observer for ML gate ───────────────────────────────────
  __weak typeof(self) weakSelf = self;
  _thermalObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification *_) {
                // Assign to strong local first — required for __weak ivar
                // dereference.
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf)
                  return;
                NSProcessInfoThermalState state =
                    NSProcessInfo.processInfo.thermalState;
                [strongSelf->_mlGate updateThermalState:state];
                NSLog(@"[VanguardCamera] Thermal \u2192 %ld; ML gate updated",
                      (long)state);
              }];

  // ── Phase 6A-3J-F: Device orientation observer ────────────────────────────
  // AVCaptureConnection.videoOrientation does NOT auto-update when the device
  // physically rotates (Apple docs). We must re-apply the orientation contract
  // whenever the device orientation changes so the ISP delivers correctly
  // oriented pixels matching the physical device angle.
  [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
  _orientationObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:UIDeviceOrientationDidChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *_) {
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf->_session.isRunning)
                  return;
                [strongSelf _applyConnectionOrientationContract];
              }];

  _session = [[AVCaptureSession alloc] init];
  [self _configureSession];

  // POC2: raw forwarding gate defaults to YES (POC1 path active by default).
  // Set to NO by VGCameraGraphSession.connectPlatformViewReceiver: when the
  // two-child VGFanOutSink is installed to prevent raw+processed double
  // delivery.
  self.platformViewRawForwardingEnabled = YES;

  return self;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Session configuration

- (void)_configureSession {
  [_session beginConfiguration];

  // Preset: 1080p on A13+; 720p fallback on older devices
  NSString *preset = AVCaptureSessionPreset1920x1080;
  if (![_session canSetSessionPreset:preset]) {
    preset = AVCaptureSessionPreset1280x720;
  }
  _session.sessionPreset = preset;

  // ── Video input ───────────────────────────────────────────────────────────
  AVCaptureDevice *cam = [AVCaptureDevice
      defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                        mediaType:AVMediaTypeVideo
                         position:_position];
  NSError *err = nil;
  AVCaptureDeviceInput *vidIn =
      [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
  if (!err && vidIn && [_session canAddInput:vidIn])
    [_session addInput:vidIn];
  // Retain for device control (zoom/focus/torch) and camera-position switching.
  // Both are written only on the main thread (method-channel handlers) and
  // before any switchToPosition: call can arrive, so no concurrent-write race.
  _captureDevice = cam;
  _videoInput = vidIn;

  // ── Video output: BGRA, Metal-compatible, MUST discard late frames ────────
  _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
  _videoOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey :
        @YES, // IOSurface-backed for zero-copy Metal
  };
  _videoOutput.alwaysDiscardsLateVideoFrames =
      YES; // non-negotiable: never queue
  [_videoOutput setSampleBufferDelegate:self queue:_captureQueue];
  if ([_session canAddOutput:_videoOutput])
    [_session addOutput:_videoOutput];

  // Orientation + mirroring: follow physical device orientation.
  // Uses shared helper (Phase 6A-3J-F) for consistency with
  // moveCameraToPosition: and the device-orientation observer.
  [self _applyConnectionOrientationContract];

  // Frame rate
  [cam lockForConfiguration:nil];
  cam.activeVideoMinFrameDuration = CMTimeMake(1, _targetFPS);
  cam.activeVideoMaxFrameDuration = CMTimeMake(1, _targetFPS);
  [cam unlockForConfiguration];

  // ── Audio input ───────────────────────────────────────────────────────────
  // Added at session config (not deferred to startRecording) to eliminate
  // the ~50ms beginConfiguration stall at recording start. AVAssetWriter
  // auto-rejects audio samples before startSessionAtSourceTime: — no manual
  // timestamp gating needed.
  AVCaptureDevice *mic =
      [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  AVCaptureDeviceInput *audIn =
      [AVCaptureDeviceInput deviceInputWithDevice:mic error:&err];
  if (!err && audIn && [_session canAddInput:audIn])
    [_session addInput:audIn];

  _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
  [_audioOutput setSampleBufferDelegate:self queue:_captureQueue];
  if ([_session canAddOutput:_audioOutput])
    [_session addOutput:_audioOutput];

  [_session commitConfiguration];

  // ── Voice Isolation (iOS 15+) ─────────────────────────────────────────────
  [self _configureVoiceIsolation];
}

- (void)_configureVoiceIsolation {
  // NOTE: AVCaptureDeviceInputSource / activeInputSource /
  // supportedInputSources are macOS-only APIs and do not exist on iOS.
  //
  // On iOS, voice isolation is handled automatically by the system when
  // AVAudioSession is configured in .videoRecording mode (set by the plugin
  // on Mode.camera entry). No per-device configuration is required.
  // If explicit voice isolation is needed in a future phase, use
  // AVAudioSession.setPreferredInputDataSource with supportedPolarPatterns.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — start / stop

- (void)start {
  if (_session.isRunning) {
    NSLog(
        @"[VanguardCamera] start — session already running, idempotent no-op.");
    return;
  }

  NSLog(@"[VanguardCamera] start — session initialising");
  [_session startRunning];
  NSLog(@"[VanguardCamera] start — session running=%d", _session.isRunning);
  [self _startWatchdog];
}

- (void)stop {
  [self _stopWatchdog];
  // If recording in progress — finalise first, then stop session
  if (_recordingState == VanguardRecordingStateWriting) {
    [self stopRecordingWithCompletion:^(NSURL *url, NSUInteger d, NSUInteger t,
                                        NSError *e) {
      [self->_session stopRunning];
    }];
  } else {
    [_session stopRunning];
  }
  // Release _latestBuffer
  os_unfair_lock_lock(&_latestBufferLock);
  if (_latestBuffer) {
    CVPixelBufferRelease(_latestBuffer);
    _latestBuffer = NULL;
  }
  os_unfair_lock_unlock(&_latestBufferLock);
}

- (void)seekTo:(CMTime)time { /* no-op: live source */
}

- (CMTime)currentTime {
  return kCMTimeZero;
} // live source: no concept of position

- (CMTime)duration {
  return kCMTimeIndefinite;
}

- (void)setVideoCallback:(void (^)(CVPixelBufferRef, CMTime))callback {
  _videoCallback = [callback copy];
}

- (void)setAudioCallback:(nullable BOOL (^)(AudioBufferList *,
                                            CMTime))callback {
  _audioCallback = [callback copy]; // stored but unused in camera mode
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

  // ── AUDIO path ────────────────────────────────────────────────────────────
  if (output == _audioOutput) {
    if (_recordingState == VanguardRecordingStateWriting && _sessionStarted &&
        _audioWriterInput.isReadyForMoreMediaData) {
      [_audioWriterInput appendSampleBuffer:sampleBuffer];
    }
    return;
  }

  // ── VIDEO path ────────────────────────────────────────────────────────────
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!pixelBuffer)
    return;

  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

  // Update watchdog
  _lastFrameWallTime = CACurrentMediaTime();

  // ── G-03 (live): ML Gate — O(1) submission ───────────────────────────────
  // offerFrame: performs only gate checks on the capture queue
  // (.userInteractive). If all 5 gates pass, the frame is dispatched to
  // _mlQueue — never blocking here. When model is Unloaded, this is a single
  // atomic read + return (~2ns overhead).
  [_mlGate offerFrame:pixelBuffer pts:pts];

  // ── Jitter measurement (Welford, O(1)) ────────────────────────────────────
  if (CMTIME_IS_VALID(_lastFrameTime) && _jitterFrameCount >= 1) {
    double interval = CMTimeGetSeconds(CMTimeSubtract(pts, _lastFrameTime));
    if (interval > 0.001 &&
        interval < 1.0) { // sanity: skip first/bogus intervals
      _jitterFrameCount++;
      double delta = interval - _jitterMean;
      _jitterMean += delta / _jitterFrameCount;
      _jitterM2 += delta * (interval - _jitterMean);

      // Warm-up: wait 1 second of data before acting on jitter
      if (_jitterFrameCount >= (uint64_t)_targetFPS) {
        double jitter = sqrt(_jitterM2 / (_jitterFrameCount - 1));

        // Pre-failure signal: throttle preview before isReadyForMoreMediaData
        // fires
        if (jitter > 0.010 && !_previewThrottled) {
          _previewThrottled = YES;
          dispatch_async(dispatch_get_main_queue(), ^{
            [self->_frameReceiver setPreviewFPS:30];
          });
          // os_signpost: jitter_throttle (Instruments profiling point)
        } else if (jitter < 0.005 && _previewThrottled &&
                   _recordingFrameSkip == 1) {
          // Recovery: jitter settled AND not in Tier 2
          _previewThrottled = NO;
          dispatch_async(dispatch_get_main_queue(), ^{
            [self->_frameReceiver setPreviewFPS:60];
          });
        }
      }
    }
  } else {
    _jitterFrameCount = 1; // first frame
  }
  _lastFrameTime = pts;

  // ── Preview path: update _latestBuffer + notify frameReceiver ────────────
  CVPixelBufferRetain(pixelBuffer); // extend lifetime past this callback
  CVPixelBufferRef old = NULL;
  os_unfair_lock_lock(&_latestBufferLock);
  old = _latestBuffer;
  _latestBuffer = pixelBuffer; // takes the +1 retain
  os_unfair_lock_unlock(&_latestBufferLock);
  if (old)
    CVPixelBufferRelease(old); // release previous, outside lock

  // Fire videoCallback (primary: frameReceiver renders via Metal).
  // OWNERSHIP CONTRACT: _videoCallback receives a +1 retained CVPixelBuffer.
  // _onVideoFrame: (the renderer's callback) calls
  // CVPixelBufferRelease(rawFrame) unconditionally. That release must balance
  // THIS retain — not _latestBuffer's. _latestBuffer and the callback are
  // independent ownership domains:
  //   Retain #1 (line 360) → owned by _latestBuffer, released when next frame
  //   arrives. Retain #2 (here)     → owned by the callback, released by
  //   _onVideoFrame:514.
  if (_videoCallback)
    _videoCallback(CVPixelBufferRetain(pixelBuffer), pts);

  // ── POC 1: raw frame forwarding → VanguardCameraPlatformView ────────────
  // Delivers the raw (pre-graph) CVPixelBuffer directly to the PlatformView's
  // onFrame:pts: so POC 1 can prove live camera rendering without the graph.
  //
  // Ownership: pixelBuffer is +0 here (owned by CMSampleBuffer until return).
  // VanguardCameraPlatformView.onFrame:pts: (Swift) retains via ARC on
  // assignment to latestBuffer — no extra CVPixelBufferRetain needed here.
  //
  // POC2 gate: when platformViewRawForwardingEnabled is NO (set by
  // VGCameraGraphSession.connectPlatformViewReceiver:), this block is bypassed
  // so the MTKView receives only graph-processed frames from VGFanOutSink.
  //
  // REMOVE before Phase 7 / production.
  id<VanguardCameraFrameReceiver> receiver =
      _frameReceiver; // strong local, atomic read
  if (receiver && self.platformViewRawForwardingEnabled) {
    static dispatch_once_t _poc1FirstFrameOnce;
    dispatch_once(&_poc1FirstFrameOnce, ^{
      NSLog(@"[Vanguard] POC1: first raw frame forwarded to frameReceiver ✓");
    });
    [receiver onFrame:pixelBuffer pts:pts];
  }

  // ── Recording path ────────────────────────────────────────────────────────
  if (_recordingState != VanguardRecordingStateWriting)
    return;

  // Phase 6E.1D.1: Graph-backed recording gate.
  // When graphRecordingEnabled is YES, the processed graph path (via
  // appendProcessedVideoFrame:pts:) is the active recording source. The raw
  // hardware buffer must not also be appended — it would duplicate frames and
  // corrupt the timeline. Defaults to NO so this guard is currently a no-op;
  // the Swift plugin will set it to YES in Phase 6E.1D.2.
  if (self.graphRecordingEnabled) {
    return;
  }

  // All access to these counters is on _captureQueue (serial) — plain ++ is
  // safe.
  int32_t total = ++_totalFrameCount;

  // Frame skip (Tier 2 active)
  if (_recordingFrameSkip > 1) {
    if (++_frameSkipCounter % _recordingFrameSkip != 0)
      return;
  }

  // isReadyForMoreMediaData gate
  if (!_videoWriterInput.isReadyForMoreMediaData) {
    int32_t dropped = ++_droppedFrameCount;
    int32_t consec = ++_consecutiveDropCount;
    _windowDrops++;

    // os_signpost: frame_drop (Instruments profiling point)
    (void)dropped;
    (void)consec; // used for logging in production builds

    [self _evaluateBackpressureWithTotal:total];
    return;
  }
  _consecutiveDropCount = 0;
  _windowDrops =
      MAX(0, _windowDrops - 0); // reset consecutive only; keep window count

  // First frame: start AVAssetWriter session at this PTS
  if (!_sessionStarted) {
    [_assetWriter startSessionAtSourceTime:pts];
    _sessionStarted = YES;
    _windowStart = CACurrentMediaTime();
  }

  // Write video frame
  [_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:pts];

  // Window bookkeeping
  _windowFrames++;
  NSTimeInterval elapsed = CACurrentMediaTime() - _windowStart;
  if (elapsed >= 2.0) {
    [self _evaluateBackpressureWithTotal:total];
    _windowDrops = 0;
    _windowFrames = 0;
    _windowStart = CACurrentMediaTime();
  }

  // Tier 2 recovery check (hysteresis)
  if (_recordingFrameSkip > 1 && _tier2ActiveAt > 0) {
    if (_windowDrops == 0 && (CACurrentMediaTime() - _tier2ActiveAt) > 10.0) {
      _recordingFrameSkip = 1;
      _frameSkipCounter = 0;
      _tier2ActiveAt = 0;
      NSLog(@"[Vanguard] Tier 2 recovered — restoring 30fps recording");
    }
  }
}

- (void)_evaluateBackpressureWithTotal:(int32_t)total {
  // Tier 2: > 5 drops in 2-second window → halve recording frame rate
  if (_windowDrops > 5 && _recordingFrameSkip == 1) {
    _recordingFrameSkip = 2;
    _tier2ActiveAt = CACurrentMediaTime();
    NSLog(@"[Vanguard] Tier 2: frame rate halved (30→15fps). drops=%d/2s",
          _windowDrops);
  }

  // Tier 3: > 10% drop rate over life of recording → stop
  if (total > 150) { // wait for 5s of data at 30fps before evaluating
    double dropRate = (double)_droppedFrameCount / (double)total;
    if (dropRate > 0.10) {
      NSLog(@"[Vanguard] Tier 3: %.0f%% drop rate — stopping recording",
            dropRate * 100);
      [self stopRecordingWithCompletion:^(NSURL *url, NSUInteger d,
                                          NSUInteger t, NSError *e){
          // Surfaced to Flutter via _stopCompletion callback
      }];
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Recording lifecycle

- (void)startRecordingToURL:(NSURL *)url
                 completion:(void (^)(NSError *_Nullable))completion {

  dispatch_async(_captureQueue, ^{
    if (self->_recordingState != VanguardRecordingStateIdle) {
      NSError *err = [NSError
          errorWithDomain:@"VanguardCamera"
                     code:-1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Recording already active"
                 }];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(err);
      });
      return;
    }

    // ── Disk space pre-flight ─────────────────────────────────────────────
    // 10Mbps H.264 = ~75MB/min. Require 200MB minimum.
    NSError *fsErr = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:url.path.stringByDeletingLastPathComponent
                                error:&fsErr];
    int64_t freeBytes = [attrs[NSFileSystemFreeSize] longLongValue];
    if (fsErr || freeBytes < 200 * 1024 * 1024) {
      NSError *diskErr = [NSError
          errorWithDomain:NSCocoaErrorDomain
                     code:NSFileWriteOutOfSpaceError
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Insufficient disk space"
                 }];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(diskErr);
      });
      return;
    }

    self->_outputURL = url;

    // ── AVAssetWriter setup ───────────────────────────────────────────────
    NSError *writerErr = nil;
    self->_assetWriter = [AVAssetWriter assetWriterWithURL:url
                                                  fileType:AVFileTypeMPEG4
                                                     error:&writerErr];
    if (writerErr || !self->_assetWriter) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(writerErr);
      });
      return;
    }

    // Video input — H.264, real-time
    NSDictionary *videoSettings = @{
      AVVideoCodecKey : AVVideoCodecTypeH264,
      AVVideoWidthKey : @1080,
      AVVideoHeightKey : @1920,
      AVVideoCompressionPropertiesKey : @{
        AVVideoAverageBitRateKey : @(10000000),
        AVVideoMaxKeyFrameIntervalKey : @30, // 1 keyframe/sec at 30fps
        AVVideoExpectedSourceFrameRateKey : @30,
        AVVideoAllowFrameReorderingKey : @NO,
      },
    };
    self->_videoWriterInput =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                           outputSettings:videoSettings];
    self->_videoWriterInput.expectsMediaDataInRealTime =
        YES; // minimises isReadyForMoreMediaData=NO

    // Pixel buffer adaptor — feed CVPixelBuffer directly (no extra copy)
    NSDictionary *pbAttrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    self->_pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:
            self->_videoWriterInput
                                   sourcePixelBufferAttributes:pbAttrs];

    // Audio input — AAC
    NSDictionary *audioSettings = @{
      AVFormatIDKey : @(kAudioFormatMPEG4AAC),
      AVSampleRateKey : @44100,
      AVNumberOfChannelsKey : @1,
      AVEncoderBitRateKey : @(128000),
    };
    self->_audioWriterInput =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                           outputSettings:audioSettings];
    self->_audioWriterInput.expectsMediaDataInRealTime = YES;

    if ([self->_assetWriter canAddInput:self->_videoWriterInput])
      [self->_assetWriter addInput:self->_videoWriterInput];
    if ([self->_assetWriter canAddInput:self->_audioWriterInput])
      [self->_assetWriter addInput:self->_audioWriterInput];

    if (![self->_assetWriter startWriting]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(self->_assetWriter.error);
      });
      return;
    }

    // startSessionAtSourceTime: deferred to first video frame (hardware PTS)
    self->_sessionStarted = NO;
    self->_recordingState = VanguardRecordingStateWriting;
    self->_droppedFrameCount = 0;
    self->_totalFrameCount = 0;
    self->_windowDrops = 0;
    self->_windowFrames = 0;
    self->_windowStart = CACurrentMediaTime();
    self->_recordingFrameSkip = 1;
    self->_frameSkipCounter = 0;
    self->_tier2ActiveAt = 0;
    // PATCH-9: Reset Welford jitter accumulators so each new recording clip
    // starts from a clean statistical baseline rather than inheriting state
    // from the previous clip's capture session.
    self->_jitterMean = 0.0;
    self->_jitterM2 = 0.0;
    self->_jitterFrameCount = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil);
    });
  });
}

- (void)stopRecordingWithCompletion:(void (^)(NSURL *, NSUInteger, NSUInteger,
                                              NSError *))completion {
  dispatch_async(_captureQueue, ^{
    // FIX-B: When a prior finishWriting is already in-flight (.Finishing),
    // chain the new completion onto _stopCompletion so it fires only after
    // AVAssetWriter is fully done. Firing immediately (old behaviour) caused
    // teardownCameraAsync to believe the write completed and nil the source
    // while finishWritingWithCompletionHandler was still executing — truncating
    // the output file and racing on _assetWriter instance variables.
    if (self->_recordingState == VanguardRecordingStateFinishing) {
      void (^prev)(NSURL *, NSUInteger, NSUInteger, NSError *) =
          self->_stopCompletion;
      self->_stopCompletion =
          ^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
            if (prev)
              prev(u, d, t, e);
            dispatch_async(dispatch_get_main_queue(), ^{
              if (completion)
                completion(u, d, t, e);
            });
          };
      return;
    }
    if (self->_recordingState != VanguardRecordingStateWriting) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, 0, 0, nil);
      });
      return;
    }

    // Phase 6E.1D.1: Clear the graph recording gate before transitioning to
    // Finishing. This prevents any pending appendProcessedVideoFrame:pts:
    // dispatch_async blocks that are queued on _captureQueue from appending
    // after finishWritingWithCompletionHandler: is called. Those blocks will
    // hit the !graphRecordingEnabled fast-exit path (Gate 1) and release
    // their retained buffers cleanly.
    self.graphRecordingEnabled = NO;

    self->_recordingState = VanguardRecordingStateFinishing;

    NSUInteger dropped = self->_droppedFrameCount;
    NSUInteger total = self->_totalFrameCount;
    NSURL *url = self->_outputURL;

    [self->_assetWriter finishWritingWithCompletionHandler:^{
      // FIX-B v2: Re-dispatch onto _captureQueue so that _stopCompletion is
      // always read and cleared on the same queue it is written on. Without
      // this, AVFoundation calls this block on an arbitrary thread concurrently
      // with the _captureQueue block that chains _stopCompletion — a data race.
      NSError *err = self->_assetWriter.error;
      dispatch_async(self->_captureQueue, ^{
        self->_recordingState = VanguardRecordingStateIdle;
        self->_sessionStarted = NO;
        self->_assetWriter = nil;
        self->_videoWriterInput = nil;
        self->_audioWriterInput = nil;
        self->_pixelBufferAdaptor = nil;
        // Fire any chained completion (FIX-B) and the primary completion.
        void (^chained)(NSURL *, NSUInteger, NSUInteger, NSError *) =
            self->_stopCompletion;
        self->_stopCompletion = nil;
        if (chained)
          chained(err ? nil : url, dropped, total, err);
        dispatch_async(dispatch_get_main_queue(), ^{
          if (completion)
            completion(err ? nil : url, dropped, total, err);
        });
      });
    }];
  });
}

/// Synchronously finalises any active recording before returning.
/// Blocks the calling thread (must NOT be _captureQueue — deadlock) until
/// AVAssetWriter.finishWritingWithCompletionHandler: fires.
/// teardownCurrentMode MUST call this before starting editor or export mode
/// so the shared H.264 hardware encoder slot is released before AVAssetReader
/// or AVAssetExportSession claim it.
/// Safe to call when not recording: returns immediately.
- (void)stopRecordingAndWait {
  if (_recordingState == VanguardRecordingStateIdle)
    return;

  // Safety: calling this from _captureQueue would deadlock because
  // stopRecordingWithCompletion: dispatches onto _captureQueue internally.
  // We use a queue-specific key set at init time to detect this in DEBUG
  // builds.
  NSCAssert(
      dispatch_get_specific(&kCaptureQueueKey) == NULL,
      @"stopRecordingAndWait must not be called from _captureQueue (deadlock)");

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSError *finishError = nil;

  [self stopRecordingWithCompletion:^(NSURL *url, NSUInteger dropped,
                                      NSUInteger total, NSError *err) {
    finishError = err;
    dispatch_semaphore_signal(sem);
  }];

  // 5-second timeout: if AVAssetWriter stalls (mediaserverd crash or device
  // out of storage), we still proceed rather than hanging the UI thread.
  long rc = dispatch_semaphore_wait(
      sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
  if (rc != 0) {
    NSLog(
        @"[VanguardCamera] stopRecordingAndWait: AVAssetWriter did not finish "
         "within 5s — recording may be truncated");
  }
  NSCAssert(_recordingState == VanguardRecordingStateIdle,
            @"stopRecordingAndWait must not return with state != Idle");
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 6E.1C — Graph-backed recording append

/// Appends a processed (effects-applied) graph frame to the active AVAssetWriter.
///
/// Threading: Called from VGRecordingSinkNode.presentEnvelope: on the graph
/// execution queue (com.vanguard.cameraGraphExecution). Dispatches internally
/// to _captureQueue so all writer state is always accessed on a single serial
/// queue. Retains pixelBuffer before dispatch; releases unconditionally on
/// every exit path inside the block.
///
/// Behavior is a no-op in Phase 6E.1C because graphRecordingEnabled defaults
/// to NO. No caller sets it to YES in this phase.
- (void)appendProcessedVideoFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts {
  // Gate 1: graph recording must be explicitly enabled (defaults NO in 6E.1C).
  if (!self.graphRecordingEnabled) return;

  // Gate 2: buffer must be valid.
  if (!pixelBuffer) return;

  // Gate 3: fast-path recording state check (non-authoritative; re-checked on
  // _captureQueue below to avoid a race on _recordingState).
  if (_recordingState != VanguardRecordingStateWriting) return;

  // Retain buffer across the async boundary. Released unconditionally inside
  // the block below.
  CVPixelBufferRetain(pixelBuffer);

  dispatch_async(_captureQueue, ^{
    // Re-check state on the owning queue (authoritative).
    if (self->_recordingState != VanguardRecordingStateWriting) {
      CVPixelBufferRelease(pixelBuffer);
      return;
    }

    // First-frame: start the AVAssetWriter session at this PTS. Mirrors the
    // raw append path so the timeline origin is consistent regardless of which
    // path delivers the first frame.
    if (!self->_sessionStarted) {
      [self->_assetWriter startSessionAtSourceTime:pts];
      self->_sessionStarted = YES;
      self->_windowStart = CACurrentMediaTime();
    }

    // Backpressure: isReadyForMoreMediaData gate. Mirrors the raw path counters
    // so stats reported via stopRecordingWithCompletion: remain accurate.
    if (!self->_videoWriterInput.isReadyForMoreMediaData) {
      int32_t dropped = ++self->_droppedFrameCount;
      int32_t consec  = ++self->_consecutiveDropCount;
      self->_windowDrops++;
      int32_t total = ++self->_totalFrameCount;
      (void)dropped;
      (void)consec;
      [self _evaluateBackpressureWithTotal:total];
      CVPixelBufferRelease(pixelBuffer);
      return;
    }
    self->_consecutiveDropCount = 0;

    int32_t total = ++self->_totalFrameCount;

    // Append the processed frame. AVAssetWriterInputPixelBufferAdaptor is
    // synchronous — buffer consumed before this returns.
    [self->_pixelBufferAdaptor appendPixelBuffer:pixelBuffer
                              withPresentationTime:pts];

    // Window bookkeeping — mirrors raw path exactly.
    self->_windowFrames++;
    NSTimeInterval elapsed = CACurrentMediaTime() - self->_windowStart;
    if (elapsed >= 2.0) {
      [self _evaluateBackpressureWithTotal:total];
      self->_windowDrops  = 0;
      self->_windowFrames = 0;
      self->_windowStart  = CACurrentMediaTime();
    }

    // No Tier-2 frame-skip here. The graph execution queue already provides
    // drop-latest backpressure via VGCameraGraphSession._graphInFlight.

    CVPixelBufferRelease(pixelBuffer);
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Watchdog (mediaserverd stall detection)

- (void)_startWatchdog {
  _lastFrameWallTime = CACurrentMediaTime();
  _watchdogTimer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
  dispatch_source_set_timer(_watchdogTimer,
                            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                            5 * NSEC_PER_SEC, NSEC_PER_SEC);
  // PATCH-4: Use __weak capture to break the retain cycle:
  //   self → _watchdogTimer → handler block → self
  // Without __weak, dealloc is unreachable if stop() is not called before
  // release.
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_watchdogTimer, ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    if (strongSelf->_recordingState == VanguardRecordingStateWriting &&
        CACurrentMediaTime() - strongSelf->_lastFrameWallTime > 3.0) {
      NSLog(@"[Vanguard] Watchdog: no frames for >3s — stopping recording");
      [strongSelf stopRecordingWithCompletion:^(NSURL *u, NSUInteger d,
                                                NSUInteger t, NSError *e){
      }];
    }
  });
  dispatch_resume(_watchdogTimer);
}

- (void)_stopWatchdog {
  if (_watchdogTimer) {
    dispatch_source_cancel(_watchdogTimer);
    _watchdogTimer = nil;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Device Controls (Phase 2)
// ─────────────────────────────────────────────────────────────────────────────
// All three methods are called from the iOS main thread (method-channel
// handlers). AVCaptureDevice.lockForConfiguration is non-blocking: returns NO
// with an error if the device is currently locked. Failed locks silently no-op
// — imperceptible at the UI refresh rate.
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)isRecording {
  // _assetWriter is created in startRecordingToURL: and nil'd in the
  // stopRecordingWithCompletion: handler. If non-nil, a recording is active.
  return _assetWriter != nil;
}

/// Sets camera zoom level. factor = 1.0 is no zoom.
/// Clamped to the device's activeFormat.videoMaxZoomFactor on the native side.
- (void)setZoom:(CGFloat)factor {
  AVCaptureDevice *dev = _captureDevice;
  if (!dev)
    return;
  NSError *lockErr = nil;
  if ([dev lockForConfiguration:&lockErr]) {
    CGFloat maxZoom = dev.activeFormat.videoMaxZoomFactor;
    dev.videoZoomFactor = MAX(1.0, MIN(factor, maxZoom));
    [dev unlockForConfiguration];
  }
}

/// Returns zoom capability values from the active AVCaptureDevice.
///
/// All reads are on read-only AVCaptureDevice properties — no
/// lockForConfiguration required (Apple docs: only write operations need the
/// configuration lock; read-only properties are freely accessible).
///
/// Wide-angle-first: device discovery is still bound to
/// builtInWideAngleCamera. virtualDeviceSwitchOverZoomFactors is therefore
/// always [] and isVirtualDevice is always NO in this phase. Virtual
/// multi-camera discovery is deferred.
///
/// maxZoomFactor in the returned dictionary is the RECOMMENDED quality-safe
/// maximum for pinch-zoom clamping. It is NOT the technical ceiling.
/// Callers should use maxZoomFactor for UI/gesture clamping and
/// technicalMaxZoomFactor only for diagnostics / developer tooling.
- (nullable NSDictionary *)zoomCapabilities {
  AVCaptureDevice *dev = _captureDevice;
  if (!dev)
    return nil;

  // ── Camera position string ────────────────────────────────────────────────
  NSString *positionStr;
  switch (dev.position) {
    case AVCaptureDevicePositionFront:
      positionStr = @"front";
      break;
    case AVCaptureDevicePositionBack:
      positionStr = @"back";
      break;
    default:
      positionStr = @"unknown";
      break;
  }
  BOOL isFront = (dev.position == AVCaptureDevicePositionFront);

  // ── minZoomFactor ─────────────────────────────────────────────────────────
  CGFloat minZoom = 1.0;
  if (@available(iOS 11.0, *)) {
    minZoom = dev.minAvailableVideoZoomFactor;
  }

  // ── technicalMaxZoomFactor ────────────────────────────────────────────────
  // The absolute hardware/digital ceiling reported by AVFoundation.
  // On modern wide-angle cameras this is typically 100× – 200×.
  // Do NOT present this to users as a zoom limit.
  CGFloat technicalMax = dev.activeFormat.videoMaxZoomFactor;
  if (@available(iOS 11.0, *)) {
    technicalMax = dev.maxAvailableVideoZoomFactor;
  }

  // ── upscaleThresholdZoomFactor ────────────────────────────────────────────
  // Zoom factors above this threshold require digital upscaling (pixel
  // interpolation). Below or at the threshold the output is a lossless
  // sensor crop — no quality degradation.
  // iOS 7+: videoZoomFactorUpscaleThreshold is available without availability
  // annotation (it's on AVCaptureDevice.Format which is iOS 7+).
  CGFloat upscaleThreshold = technicalMax; // safe fallback
  CGFloat rawThreshold = dev.activeFormat.videoZoomFactorUpscaleThreshold;
  if (rawThreshold > 1.0) {
    // Threshold is well-defined: use it.
    upscaleThreshold = rawThreshold;
  }
  // Guard against degenerate case where threshold exceeds technical max.
  upscaleThreshold = MIN(upscaleThreshold, technicalMax);

  // ── maxZoomFactor — RECOMMENDED quality-safe maximum ─────────────────────
  //
  // Policy:
  //   Front camera: capped at 2.0× to preserve image fidelity (front sensors
  //     have lower resolution and no telephoto option).
  //   Back camera: up to 2.5× beyond the lossless sensor crop threshold,
  //     capped at 10× (matches native iOS Camera back-camera experience),
  //     but never exceeds the technical maximum.
  //
  // We allow a modest amount beyond the lossless threshold because modern iOS
  // camera stacks apply spatial Quality/Noise Reduction algorithms that
  // maintain acceptable quality for moderate digital zoom beyond the optical
  // limit, similar to what iPhone Camera shows.
  CGFloat recommendedMax;
  if (isFront) {
    recommendedMax = MIN(2.0, technicalMax);
  } else {
    // Back: upscaleThreshold * 2.5, capped at 10× product max.
    recommendedMax = MIN(upscaleThreshold * 2.5, 10.0);
    // Never exceed the technical ceiling.
    recommendedMax = MIN(recommendedMax, technicalMax);
  }
  // Ensure recommendedMax is at least minZoom (degenerate device guard).
  recommendedMax = MAX(recommendedMax, minZoom);

  // ── defaultZoomFactor ─────────────────────────────────────────────────────
  // Always 1.0 in the wide-angle-first phase. When virtual multi-camera
  // discovery is implemented this may need to reflect the standard-lens
  // factor on virtual devices.
  CGFloat defaultZoom = 1.0;

  // ── displayZoomFactorMultiplier ───────────────────────────────────────────
  CGFloat displayMultiplier = 1.0;
  if (@available(iOS 18.0, *)) {
    displayMultiplier = dev.displayVideoZoomFactorMultiplier;
  }

  // ── virtualDeviceSwitchOverZoomFactors ────────────────────────────────────
  NSArray<NSNumber *> *switchOvers = @[];
  BOOL isVirtual = NO;
  if (@available(iOS 13.0, *)) {
    switchOvers = dev.virtualDeviceSwitchOverVideoZoomFactors ?: @[];
    isVirtual = dev.isVirtualDevice;
  }

  return @{
    @"minZoomFactor" : @(minZoom),
    @"maxZoomFactor" : @(recommendedMax),      // recommended quality-safe max
    @"technicalMaxZoomFactor" : @(technicalMax), // raw AVFoundation ceiling
    @"upscaleThresholdZoomFactor" : @(upscaleThreshold), // lossless boundary
    @"defaultZoomFactor" : @(defaultZoom),
    @"displayZoomFactorMultiplier" : @(displayMultiplier),
    @"virtualDeviceSwitchOverZoomFactors" : switchOvers,
    @"isVirtualDevice" : @(isVirtual),
    @"cameraPosition" : positionStr,
  };
}


/// Sets tap-to-focus and tap-to-expose at a normalised point (0.0–1.0,
/// 0.0–1.0). x = horizontal from left, y = vertical from top (AVFoundation
/// coordinate space).
- (void)applyFocusPoint:(CGPoint)point {
  AVCaptureDevice *dev = _captureDevice;
  if (!dev)
    return;
  BOOL canFocus = [dev isFocusPointOfInterestSupported];
  BOOL canExpose = [dev isExposurePointOfInterestSupported];
  if (!canFocus && !canExpose)
    return;
  NSError *lockErr = nil;
  if ([dev lockForConfiguration:&lockErr]) {
    if (canFocus) {
      dev.focusPointOfInterest = point;
      dev.focusMode = AVCaptureFocusModeAutoFocus;
    }
    if (canExpose) {
      dev.exposurePointOfInterest = point;
      dev.exposureMode = AVCaptureExposureModeAutoExpose;
    }
    [dev unlockForConfiguration];
  }
}

/// Turns the video torch on or off. mode: @"on" | @"off".
/// Named setTorchMode: (not flash) — the torch is a continuous video light,
/// distinct from the single-burst photo flash (AVCaptureDevice.flashMode).
/// No-op if the current device has no torch (e.g. front camera, simulator).
- (void)setTorchMode:(NSString *)mode {
  AVCaptureDevice *dev = _captureDevice;
  if (!dev || ![dev isTorchAvailable])
    return;
  AVCaptureTorchMode torchMode;
  if ([mode isEqualToString:@"on"])
    torchMode = AVCaptureTorchModeOn;
  else if ([mode isEqualToString:@"off"])
    torchMode = AVCaptureTorchModeOff;
  else
    return; // unrecognised mode — silent no-op
  NSError *lockErr = nil;
  if ([dev lockForConfiguration:&lockErr]) {
    dev.torchMode = torchMode;
    [dev unlockForConfiguration];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Camera Switch (Phase 3)
// ─────────────────────────────────────────────────────────────────────────────

/// Switches to the opposite camera sensor without tearing down the session.
/// Uses AVCaptureSession reconfiguration (~100–200 ms) instead of full source
/// teardown (~600 ms). The preview texture and audio session remain unchanged.
///
/// SAFETY: Must NOT be called while a recording is active (_assetWriter !=
/// nil). The plugin's switchCamera case guards this with isRecording before
/// dispatching. Called on the main thread.
- (void)moveCameraToPosition:(AVCaptureDevicePosition)position {
  if (_position == position)
    return; // already on requested side — no work

  AVCaptureDevice *newCam = [AVCaptureDevice
      defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                        mediaType:AVMediaTypeVideo
                         position:position];
  if (!newCam)
    return; // device not available (e.g. simulator without front cam)

  NSError *inputErr = nil;
  AVCaptureDeviceInput *newInput =
      [AVCaptureDeviceInput deviceInputWithDevice:newCam error:&inputErr];
  if (!newInput || inputErr)
    return;

  // Guard photo capture: reject takePhotoToURL: calls arriving during the
  // reconfiguration window. Both this flag and takePhotoToURL: are accessed
  // on the main thread only — no lock needed.
  _isSwitching = YES;

  [_session beginConfiguration];

  // Remove old video input; add new one. Audio input is left unchanged.
  if (_videoInput && [_session.inputs containsObject:_videoInput]) {
    [_session removeInput:_videoInput];
  }
  if ([_session canAddInput:newInput]) {
    [_session addInput:newInput];
    _videoInput = newInput;
    _captureDevice = newCam;
    _position = position;
  } else {
    // Roll back: re-add original input; ivars remain unchanged.
    if (_videoInput)
      [_session addInput:_videoInput];
  }

  // Phase 6A-3J-F: Set orientation and mirroring inside the configuration
  // block so AVFoundation batches all mutations into the single
  // commitConfiguration call. Uses shared helper for consistency.
  [self _applyConnectionOrientationContract];

  [_session commitConfiguration];

  // Phase 6C: re-apply portrait lock if it was active before the switch.
  // _applyConnectionOrientationContract above already enforces portrait when
  // locked, but calling the public method logs the event for diagnostics.
  if (_previewOrientationLocked) {
    NSLog(@"[Vanguard][6C] moveCameraToPosition: re-applying portrait lock after camera switch");
    // Lock already enforced by _applyConnectionOrientationContract; no further work.
  }

  // Reconfiguration complete — photo capture allowed again.
  _isSwitching = NO;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 6C: Preview Orientation Lock
// ─────────────────────────────────────────────────────────────────────────────
//
// These methods are called by VGNativeCameraViewController (inside
// VanguardMediaEnginePlugin.swift) to bracket native camera preview.
//
// lockPreviewOrientationToPortrait:
//   - Sets _previewOrientationLocked = YES.
//   - Immediately forces videoOrientation = portrait on the active connection.
//   - Future _applyConnectionOrientationContract calls will skip the
//     device-orientation switch and keep portrait locked.
//
// unlockPreviewOrientation:
//   - Clears _previewOrientationLocked.
//   - Calls _applyConnectionOrientationContract to re-sync orientation with
//     the current device orientation.

- (void)lockPreviewOrientationToPortrait {
  _previewOrientationLocked = YES;
  // Force portrait immediately on the active video connection.
  AVCaptureConnection *vidConn =
      [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
  if (vidConn && vidConn.isVideoOrientationSupported) {
    vidConn.videoOrientation = AVCaptureVideoOrientationPortrait;
  }
  NSLog(@"[Vanguard][6C] preview orientation locked to portrait");
}

- (void)unlockPreviewOrientation {
  _previewOrientationLocked = NO;
  // Restore orientation to match current device angle.
  [self _applyConnectionOrientationContract];
  NSLog(@"[Vanguard][6C] preview orientation unlocked");
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Photo Capture (Phase 4)
// ─────────────────────────────────────────────────────────────────────────────
//
// Threading model:
//   takePhotoToURL:completion: is called on the main thread (method-channel).
//   _isSwitching is checked on the main thread only — no lock needed.
//   _latestBuffer is read under _latestBufferLock (nanosecond hold).
//   Encoding and file I/O run on _photoQueue (persistent, .userInitiated).
//   completion: is always dispatched back to the main thread.
//   _captureQueue and AVAssetWriter state are never touched.

- (void)takePhotoToURL:(NSURL *)url
            completion:
                (void (^)(NSURL *_Nullable, NSError *_Nullable))completion {

  // Step 1 — Reject during camera-switch reconfiguration window.
  // _isSwitching and this call are both on the main thread; no lock required.
  if (_isSwitching) {
    NSError *err = [NSError
        errorWithDomain:@"VanguardCamera"
                   code:3
               userInfo:@{
                 NSLocalizedDescriptionKey : @"Camera switch in progress"
               }];
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil, err);
    });
    return;
  }

  // Step 2 — Retain a snapshot of _latestBuffer under lock.
  // Lock is held for nanoseconds: retain + pointer swap only.
  // No encoding or allocation happens inside the lock.
  os_unfair_lock_lock(&_latestBufferLock);
  CVPixelBufferRef snapshot =
      _latestBuffer ? CVPixelBufferRetain(_latestBuffer) : NULL;
  os_unfair_lock_unlock(&_latestBufferLock);

  // Step 3 — Guard: no frame delivered yet (startup window ~100ms).
  if (!snapshot) {
    NSError *err = [NSError
        errorWithDomain:@"VanguardCamera"
                   code:1
               userInfo:@{NSLocalizedDescriptionKey : @"No frame available"}];
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil, err);
    });
    return;
  }

  // Step 4 — Encode and write on the persistent _photoQueue.
  // The buffer is already mirrored for front camera by the AVCaptureConnection
  // (videoMirrored = YES in _configureSession and re-applied in
  // moveCameraToPosition:). No transform is applied; the saved JPEG matches
  // what the user saw in the preview.
  dispatch_async(_photoQueue, ^{
    // Wrap CVPixelBuffer in a CIImage. On A-series SoCs this reads the
    // IOSurface directly without a pixel-data copy.
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:snapshot];
    CVPixelBufferRelease(snapshot); // balanced +1 from Step 2

    // Determine the color space.
    // ciImage.colorSpace is a non-owning reference — do NOT release it.
    // CGColorSpaceCreateDeviceRGB() returns +1 — MUST be released.
    CGColorSpaceRef cs = ciImage.colorSpace;
    BOOL ownedCS = NO;
    if (!cs) {
      cs = CGColorSpaceCreateDeviceRGB();
      ownedCS = YES;
    }

    CIContext *ctx = [CIContext context];
    NSDictionary *options = @{
      (id)kCGImageDestinationLossyCompressionQuality : @0.9,
    };
    NSData *jpegData = [ctx JPEGRepresentationOfImage:ciImage
                                           colorSpace:cs
                                              options:options];
    if (ownedCS) {
      CGColorSpaceRelease(cs); // release only the space we created
    }

    if (!jpegData) {
      NSError *err =
          [NSError errorWithDomain:@"VanguardCamera"
                              code:2
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"JPEG encoding failed"
                          }];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, err);
      });
      return;
    }

    NSError *writeErr = nil;
    [jpegData writeToURL:url options:NSDataWritingAtomic error:&writeErr];
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(writeErr ? nil : url, writeErr);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Dealloc

- (void)dealloc {
  [self _stopWatchdog];
  // Phase 6A-3J-F: Remove orientation observer.
  if (_orientationObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:_orientationObserver];
    _orientationObserver = nil;
  }
  [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
  // G-04: Remove thermal observer before our strong references go away.
  if (_thermalObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:_thermalObserver];
    _thermalObserver = nil;
  }
  // G-03: Release the ML input pool (VanguardMLGate retains it separately via
  // CVPixelBufferPoolRetain).
  if (_mlInputPool) {
    CVPixelBufferPoolRelease(_mlInputPool);
    _mlInputPool = NULL;
  }
  os_unfair_lock_lock(&_latestBufferLock);
  if (_latestBuffer) {
    CVPixelBufferRelease(_latestBuffer);
    _latestBuffer = NULL;
  }
  os_unfair_lock_unlock(&_latestBufferLock);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Connection Orientation Contract (Phase 6A-3J-F)
// ─────────────────────────────────────────────────────────────────────────────

/// Orientation-adaptive connection contract.
///
/// Maps the current UIDeviceOrientation to AVCaptureVideoOrientation so the
/// ISP delivers pixels matching the physical device angle.
///
/// Apple UIDeviceOrientation -> AVCaptureVideoOrientation mapping
/// (per Apple AVCam sample code -- landscape axes are INVERTED):
///   UIDeviceOrientationPortrait            ->
///   AVCaptureVideoOrientationPortrait UIDeviceOrientationPortraitUpsideDown ->
///   AVCaptureVideoOrientationPortraitUpsideDown
///   UIDeviceOrientationLandscapeLeft       ->
///   AVCaptureVideoOrientationLandscapeRight UIDeviceOrientationLandscapeRight
///   -> AVCaptureVideoOrientationLandscapeLeft FaceUp / FaceDown / Unknown ->
///   Portrait fallback
///
/// Mirroring contract:
///   automaticallyAdjustsVideoMirroring = NO
///   videoMirrored = YES for front camera, NO for back
///
/// Called from:
///   _configureSession       -- initial session setup
///   moveCameraToPosition:   -- inside beginConfiguration/commitConfiguration
///   UIDeviceOrientationDidChangeNotification -- re-apply after physical
///   rotation
- (void)_applyConnectionOrientationContract {
  AVCaptureConnection *vidConn =
      [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
  if (!vidConn)
    return;

  if (vidConn.isVideoOrientationSupported) {
    // Phase 6C: when the preview orientation is locked, always force portrait
    // so capture buffers remain stable at 1080x1920 regardless of device angle.
    // The VC+MTKView presenter handles the visual rotation instead.
    if (_previewOrientationLocked) {
      vidConn.videoOrientation = AVCaptureVideoOrientationPortrait;
    } else {
      UIDeviceOrientation devOrientation = UIDevice.currentDevice.orientation;
      AVCaptureVideoOrientation vidOrientation;

      switch (devOrientation) {
      case UIDeviceOrientationPortraitUpsideDown:
        vidOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
        break;
      case UIDeviceOrientationLandscapeLeft:
        // Device rotated left (home button right) -> landscape right
        vidOrientation = AVCaptureVideoOrientationLandscapeRight;
        break;
      case UIDeviceOrientationLandscapeRight:
        // Device rotated right (home button left) -> landscape left
        vidOrientation = AVCaptureVideoOrientationLandscapeLeft;
        break;
      case UIDeviceOrientationPortrait:
      default:
        // Portrait, FaceUp, FaceDown, Unknown -> portrait fallback
        vidOrientation = AVCaptureVideoOrientationPortrait;
        break;
      }

      vidConn.videoOrientation = vidOrientation;
    }
  }

  if (vidConn.isVideoMirroringSupported) {
    vidConn.automaticallyAdjustsVideoMirroring = NO;
    vidConn.videoMirrored = (_position == AVCaptureDevicePositionFront);
  }
}

@end
