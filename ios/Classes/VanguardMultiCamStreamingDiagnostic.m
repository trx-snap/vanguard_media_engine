// VanguardMultiCamStreamingDiagnostic.m
// vanguard_media_engine — MC-4: Running MultiCam streaming diagnostic.

#import "VanguardMultiCamStreamingDiagnostic.h"

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// The fixed diagnostic window duration in seconds.
static const NSTimeInterval kDiagnosticDurationSeconds = 3.0;

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the AVCaptureDevice with the given uniqueID, or nil if not found.
static AVCaptureDevice *_streamingDeviceForUniqueId(NSString *uniqueId) {
  for (AVCaptureDevice *device in [AVCaptureDevice devices]) {
    if ([device.uniqueID isEqualToString:uniqueId]) {
      return device;
    }
  }
  return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// Frame counter context
// ─────────────────────────────────────────────────────────────────────────────
//
// Both front and back delegates fire on the same serial queue. Using OSAtomic
// integers is safe (serial queue), but we use plain C int32_t behind a context
// struct and access them only from that queue for simplicity and correctness.
// The struct is stack-allocated inside +runForFrontId:backId: and a pointer to
// it is captured by the block registered as the delegate object's context.
// Because the block runs on the same serial queue as the read at method end,
// there is no data race.

// ─────────────────────────────────────────────────────────────────────────────
// Delegate implementation
// ─────────────────────────────────────────────────────────────────────────────

/// Internal delegate class that counts frames and tracks peak systemPressureCost.
/// One instance handles both front and back outputs; it differentiates by
/// comparing the `output` pointer to the stored front/back output references.
@interface _VanguardMC4Delegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

/// Number of frames received from the front camera output.
@property (nonatomic, assign) int32_t frontFrames;

/// Number of frames received from the back camera output.
@property (nonatomic, assign) int32_t backFrames;

/// Peak systemPressureCost observed during the run window.
@property (nonatomic, assign) double peakSystemPressureCost;

/// Weak reference to the session so the delegate can sample systemPressureCost.
/// Weak to avoid a retain cycle: session → output → delegate → session.
@property (nonatomic, weak) AVCaptureSession *session API_AVAILABLE(ios(13.0));

/// The front output reference used to distinguish front vs back frames.
@property (nonatomic, weak) AVCaptureVideoDataOutput *frontOutput;

/// The back output reference used to distinguish front vs back frames.
@property (nonatomic, weak) AVCaptureVideoDataOutput *backOutput;

@end

@implementation _VanguardMC4Delegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  // ── Frame counting only — no rendering, no pixel-buffer access ─────────────
  //
  // This delegate does NOT:
  //   - retain CVPixelBuffer
  //   - create textures or renderers
  //   - composite frames
  //   - write to any shared state outside frame counters / peak pressure

  if (output == self.frontOutput) {
    self.frontFrames++;
  } else if (output == self.backOutput) {
    self.backFrames++;
  }

  // ── Sample systemPressureCost ─────────────────────────────────────────────
  //
  // Apple: "systemPressureCost returns 0.0 unless the session is running."
  // We sample it on every delegate callback (from the capture queue) and
  // record the peak. This is a lightweight float read on the running session.
  if (@available(iOS 13.0, *)) {
    AVCaptureMultiCamSession *multiCamSession =
        (AVCaptureMultiCamSession *)self.session;
    if (multiCamSession) {
      double cost = (double)multiCamSession.systemPressureCost;
      if (cost > self.peakSystemPressureCost) {
        self.peakSystemPressureCost = cost;
      }
    }
  }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  // Intentionally no-op. Dropped-frame detection deferred to MC-5.
  // alwaysDiscardsLateVideoFrames = YES means drops are expected under load;
  // the diagnostic counts delivered frames only.
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardMultiCamStreamingDiagnostic

+ (nullable NSDictionary<NSString *, NSNumber *> *)
    runForFrontId:(NSString *)frontId
           backId:(NSString *)backId {

  // ── iOS 13 guard ──────────────────────────────────────────────────────────
  if (@available(iOS 13.0, *)) {
    // proceed below
  } else {
    NSLog(@"[MultiCamStream] iOS 13 required; returning nil.");
    return nil;
  }

  // ── MultiCam hardware support guard ───────────────────────────────────────
  if (@available(iOS 13.0, *)) {
    if (!AVCaptureMultiCamSession.isMultiCamSupported) {
      NSLog(@"[MultiCamStream] MultiCam not supported on this device; returning nil.");
      return nil;
    }
  }

  // ── Camera authorization check (no prompt — check only) ───────────────────
  // Opus requirement: do NOT call requestAccess. If not yet authorized,
  // return nil. The existing camera startup path handles authorization prompts.
  AVAuthorizationStatus authStatus =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (authStatus != AVAuthorizationStatusAuthorized) {
    NSLog(@"[MultiCamStream] Camera not authorized (status=%ld); returning nil.",
          (long)authStatus);
    return nil;
  }

  // ── Locate devices by uniqueID ────────────────────────────────────────────
  AVCaptureDevice *frontDevice = _streamingDeviceForUniqueId(frontId);
  AVCaptureDevice *backDevice  = _streamingDeviceForUniqueId(backId);

  if (!frontDevice) {
    NSLog(@"[MultiCamStream] Front device not found for uniqueID: %@", frontId);
    return nil;
  }
  if (!backDevice) {
    NSLog(@"[MultiCamStream] Back device not found for uniqueID: %@", backId);
    return nil;
  }

  // ── Allocate session ──────────────────────────────────────────────────────
  //
  // AVCaptureMultiCamSession is a local variable. ARC destroys the session
  // and all retained inputs/outputs when this method returns (or on any early
  // exit below). stopRunning is called explicitly before return.
  AVCaptureMultiCamSession *session = nil;
  if (@available(iOS 13.0, *)) {
    session = [[AVCaptureMultiCamSession alloc] init];
  }

  [session beginConfiguration];

  // ── Front camera input ────────────────────────────────────────────────────
  NSError *frontErr = nil;
  AVCaptureDeviceInput *frontInput =
      [AVCaptureDeviceInput deviceInputWithDevice:frontDevice error:&frontErr];
  if (frontErr || !frontInput) {
    NSLog(@"[MultiCamStream] Front input error: %@", frontErr.localizedDescription);
    [session commitConfiguration];
    return nil;
  }
  if (![session canAddInput:frontInput]) {
    NSLog(@"[MultiCamStream] Cannot add front input to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addInputWithNoConnections:frontInput];

  // ── Back camera input ─────────────────────────────────────────────────────
  NSError *backErr = nil;
  AVCaptureDeviceInput *backInput =
      [AVCaptureDeviceInput deviceInputWithDevice:backDevice error:&backErr];
  if (backErr || !backInput) {
    NSLog(@"[MultiCamStream] Back input error: %@", backErr.localizedDescription);
    [session commitConfiguration];
    return nil;
  }
  if (![session canAddInput:backInput]) {
    NSLog(@"[MultiCamStream] Cannot add back input to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addInputWithNoConnections:backInput];

  // ── Front camera output (BGRA, delegate wired below) ──────────────────────
  //
  // alwaysDiscardsLateVideoFrames = YES: matches production VanguardCameraMediaSource.
  // This is required for the diagnostic — we never want to block the capture
  // pipeline on a slow delegate.
  AVCaptureVideoDataOutput *frontOutput = [[AVCaptureVideoDataOutput alloc] init];
  frontOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
  };
  frontOutput.alwaysDiscardsLateVideoFrames = YES;

  if (![session canAddOutput:frontOutput]) {
    NSLog(@"[MultiCamStream] Cannot add front output to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addOutputWithNoConnections:frontOutput];

  // ── Back camera output (BGRA, delegate wired below) ───────────────────────
  AVCaptureVideoDataOutput *backOutput = [[AVCaptureVideoDataOutput alloc] init];
  backOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
  };
  backOutput.alwaysDiscardsLateVideoFrames = YES;

  if (![session canAddOutput:backOutput]) {
    NSLog(@"[MultiCamStream] Cannot add back output to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addOutputWithNoConnections:backOutput];

  // ── Connect front input port → front output ───────────────────────────────
  AVCaptureInputPort *frontPort = nil;
  for (AVCaptureInputPort *port in frontInput.ports) {
    if ([port.mediaType isEqualToString:AVMediaTypeVideo]) {
      frontPort = port;
      break;
    }
  }
  if (frontPort) {
    AVCaptureConnection *frontConn =
        [AVCaptureConnection connectionWithInputPorts:@[frontPort]
                                              output:frontOutput];
    if ([session canAddConnection:frontConn]) {
      [session addConnection:frontConn];
      // ── Orientation/mirroring contract — matches VanguardCameraMediaSource ─
      // Portrait-canonical: always portrait so ISP delivers stable 1080×1920
      // buffers regardless of device orientation.
      // Mirroring: automaticallyAdjustsVideoMirroring = NO (explicit control).
      //   Front camera: mirrored = YES.
      if (frontConn.isVideoOrientationSupported) {
        frontConn.videoOrientation = AVCaptureVideoOrientationPortrait;
      }
      if (frontConn.isVideoMirroringSupported) {
        frontConn.automaticallyAdjustsVideoMirroring = NO;
        frontConn.videoMirrored = YES; // front camera: mirrored
      }
    }
  }

  // ── Connect back input port → back output ─────────────────────────────────
  AVCaptureInputPort *backPort = nil;
  for (AVCaptureInputPort *port in backInput.ports) {
    if ([port.mediaType isEqualToString:AVMediaTypeVideo]) {
      backPort = port;
      break;
    }
  }
  if (backPort) {
    AVCaptureConnection *backConn =
        [AVCaptureConnection connectionWithInputPorts:@[backPort]
                                             output:backOutput];
    if ([session canAddConnection:backConn]) {
      [session addConnection:backConn];
      // ── Orientation/mirroring contract ────────────────────────────────────
      // Back camera: not mirrored.
      if (backConn.isVideoOrientationSupported) {
        backConn.videoOrientation = AVCaptureVideoOrientationPortrait;
      }
      if (backConn.isVideoMirroringSupported) {
        backConn.automaticallyAdjustsVideoMirroring = NO;
        backConn.videoMirrored = NO; // back camera: not mirrored
      }
    }
  }

  [session commitConfiguration];

  // ── Read hardwareCost (pre-start) ─────────────────────────────────────────
  //
  // Re-read here to confirm the MC-3 static reading is consistent once the
  // session is fully configured with delegates. The Opus-required return value
  // includes this reading.
  double hardwareCost = 0.0;
  if (@available(iOS 13.0, *)) {
    hardwareCost = (double)session.hardwareCost;
  }
  NSLog(@"[MultiCamStream] hardwareCost=%.4f (pre-start)", hardwareCost);

  // ── Set up dedicated serial dispatch queue for both delegate callbacks ─────
  //
  // Both outputs share a single serial queue. The delegate differentiates
  // front/back by comparing the `output` pointer.
  // Serial queue avoids concurrent frame counting without locks.
  dispatch_queue_t captureQ = dispatch_queue_create(
      "com.vanguard.multicam.stream.diagnostic",
      dispatch_queue_attr_make_with_qos_class(
          DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));

  // ── Allocate frame-counting delegate ──────────────────────────────────────
  _VanguardMC4Delegate *delegate = [[_VanguardMC4Delegate alloc] init];
  delegate.session     = session;
  delegate.frontOutput = frontOutput;
  delegate.backOutput  = backOutput;

  [frontOutput setSampleBufferDelegate:delegate queue:captureQ];
  [backOutput  setSampleBufferDelegate:delegate queue:captureQ];

  // ── Start running ─────────────────────────────────────────────────────────
  //
  // startRunning is synchronous and blocking (~50–200ms for hardware init).
  // This method must be called on a background queue — the plugin route
  // ensures this via DispatchQueue.global(qos:).async before invoking us.
  //
  // After startRunning returns, frames begin arriving on captureQ via delegate.
  NSLog(@"[MultiCamStream] Calling startRunning...");
  NSTimeInterval startWall = CACurrentMediaTime();
  [session startRunning];
  NSLog(@"[MultiCamStream] Session isRunning=%d", session.isRunning);

  // ── 3-second diagnostic window ────────────────────────────────────────────
  //
  // Block the current background thread for exactly kDiagnosticDurationSeconds.
  // During this window, captureQ delivers frames to the delegate concurrently.
  // This is safe: the serial captureQ and this calling queue are different
  // queues — captureQ is free to run while this thread sleeps.
  [NSThread sleepForTimeInterval:kDiagnosticDurationSeconds];

  NSTimeInterval elapsed = CACurrentMediaTime() - startWall;

  // ── Stop running ──────────────────────────────────────────────────────────
  //
  // stopRunning is synchronous — it blocks until all in-flight delegate
  // callbacks on captureQ have drained. After this returns:
  //   - No further callbacks will fire.
  //   - The camera hardware lock is released.
  //   - The green camera indicator will disappear.
  [session stopRunning];
  NSLog(@"[MultiCamStream] Session stopped. isRunning=%d", session.isRunning);

  // ── Detach delegates before ARC reclaims the session ─────────────────────
  //
  // Clearing the delegate reference prevents any residual queue-scheduled
  // blocks (if any) from calling back into a partially deallocated context.
  // With alwaysDiscardsLateVideoFrames = YES and stopRunning already drained,
  // this is a belt-and-suspenders safety measure.
  [frontOutput setSampleBufferDelegate:nil queue:nil];
  [backOutput  setSampleBufferDelegate:nil queue:nil];

  // ── Collect results from the delegate ─────────────────────────────────────
  //
  // The delegate's counters were written only on captureQ (serial). After
  // stopRunning drains captureQ and we clear the delegate, reading the counters
  // here on the calling thread is safe — captureQ can no longer write to them.
  int32_t frontFrames = delegate.frontFrames;
  int32_t backFrames  = delegate.backFrames;
  double peakPressure = delegate.peakSystemPressureCost;

  NSLog(@"[MultiCamStream] front=%d frames, back=%d frames, peakPressure=%.4f, elapsed=%.3fs",
        (int)frontFrames, (int)backFrames, peakPressure, elapsed);

  // ── ARC cleanup note ──────────────────────────────────────────────────────
  //
  // session, frontInput, backInput, frontOutput, backOutput, frontConn, backConn,
  // captureQ, and delegate all go out of scope at method return. ARC releases
  // the session and all associated AVFoundation objects. No explicit nil-ing
  // required; the green dot is already gone because stopRunning returned.

  return @{
    @"frontFramesReceived":    @((int32_t)frontFrames),
    @"backFramesReceived":     @((int32_t)backFrames),
    @"peakSystemPressureCost": @(peakPressure),
    @"hardwareCost":           @(hardwareCost),
    @"durationSeconds":        @(elapsed),
  };
}

@end
