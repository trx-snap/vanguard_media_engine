// VanguardMultiCamSyncDiagnostic.m
// vanguard_media_engine — MC-5: MultiCam software timestamp-pairing diagnostic.
//
// ── IMPLEMENTATION NOTE ──────────────────────────────────────────────────────
//
// This implementation intentionally uses AVCaptureVideoDataOutputSampleBufferDelegate
// (individual per-output delegates) and NOT AVCaptureDataOutputSynchronizer.
//
// AVCaptureDataOutputSynchronizer was evaluated and rejected: with two independent
// physical cameras and alwaysDiscardsLateVideoFrames=YES, the synchronizer
// consistently produced zero paired frames (droppedFront ≈ 89, droppedBack ≈ 90
// out of 179 total callbacks). Apple documents that alwaysDiscardsLateVideoFrames
// is honored by the synchronizer. For phase-offset independent sensors, this
// causes every secondary frame to be discarded before pairing.
//
// Software pairing on a shared serial queue (proven by MC-4 to receive real
// frames from both cameras) is the correct approach.

#import "VanguardMultiCamSyncDiagnostic.h"
#import <CoreMedia/CoreMedia.h>

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Fixed diagnostic window in seconds.
static const NSTimeInterval kSyncDiagnosticDurationSeconds = 3.0;

/// Pairing threshold: one full frame at 30fps.
/// Two frames are considered "paired" if |frontPTS − backPTS| ≤ this value.
static const double kPairingThresholdSeconds = 1.0 / 30.0;

// ─────────────────────────────────────────────────────────────────────────────
// Internal helper
// ─────────────────────────────────────────────────────────────────────────────

static AVCaptureDevice *_syncDeviceForUniqueId(NSString *uniqueId) {
  for (AVCaptureDevice *device in [AVCaptureDevice devices]) {
    if ([device.uniqueID isEqualToString:uniqueId]) {
      return device;
    }
  }
  return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// Delegate
// ─────────────────────────────────────────────────────────────────────────────
//
// Single delegate instance handles both front and back outputs.
// Differentiates them by pointer identity (same as MC-4).
//
// All callbacks fire on a shared serial captureQ, so all property accesses
// below are safe without locks.
//
// ── Software pairing state ───────────────────────────────────────────────────
//
// lastUnmatchedFrontPTS / lastUnmatchedBackPTS: the PTS of the most recently
// received frame from each camera that has not yet found a partner.
// kCMTimeInvalid means "no unmatched frame pending".
//
// On each frame arrival from camera X:
//   1. Increment X frame counter.
//   2. If the other camera has a pending unmatched PTS:
//      a. Compute drift = |newPTS - pendingOtherPTS|
//      b. If drift ≤ threshold → pair: increment pairedFrames, update drift stats,
//         clear other pending PTS. Do NOT store X PTS.
//      c. If drift > threshold → stale: count other pending as unmatched,
//         clear it, store new X PTS as unmatched.
//   3. If the other camera has NO pending unmatched PTS:
//      a. If X already has a pending unmatched PTS, count it as unmatched first.
//      b. Store new X PTS as pending.
//
// At teardown any remaining pending PTS on either side is counted as unmatched.
//
// ── No CMSampleBuffer or CVPixelBuffer retention ─────────────────────────────
//
// Only CMTime values (two 64-bit integers + 32-bit flags, ~20 bytes each) are
// retained across callbacks. The sample buffer itself is not retained.

@interface _VanguardMC5SoftPairDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

// ── Raw frame counts ─────────────────────────────────────────────────────────

@property (nonatomic, assign) int32_t frontFramesReceived;
@property (nonatomic, assign) int32_t backFramesReceived;

// ── Pairing metrics ──────────────────────────────────────────────────────────

@property (nonatomic, assign) int32_t pairedFramesReceived;
@property (nonatomic, assign) int32_t unmatchedFrontFrames;
@property (nonatomic, assign) int32_t unmatchedBackFrames;

@property (nonatomic, assign) double maxDriftSeconds;
@property (nonatomic, assign) double accumulatedDriftSeconds;

// ── System metrics ───────────────────────────────────────────────────────────

@property (nonatomic, assign) double peakSystemPressureCost;

// ── Output identity (strong — used as pointer comparators only) ──────────────

/// Strong reference: used only for pointer-identity comparison (output == self.frontOutput).
/// Does not create a retain cycle — session is held weak.
@property (nonatomic, strong) AVCaptureVideoDataOutput *frontOutput;

/// Strong reference: same rationale as frontOutput.
@property (nonatomic, strong) AVCaptureVideoDataOutput *backOutput;

// ── Session (weak to avoid retain cycle: session → output → delegate → session) ─

@property (nonatomic, weak) AVCaptureSession *session API_AVAILABLE(ios(13.0));

// ── Pairing state (written and read only on captureQ — no locks needed) ──────

/// PTS of most recent unmatched front frame. kCMTimeInvalid if none.
@property (nonatomic, assign) CMTime lastUnmatchedFrontPTS;

/// PTS of most recent unmatched back frame. kCMTimeInvalid if none.
@property (nonatomic, assign) CMTime lastUnmatchedBackPTS;

@end

@implementation _VanguardMC5SoftPairDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    // Initialise PTS state to invalid (no pending frame).
    _lastUnmatchedFrontPTS = kCMTimeInvalid;
    _lastUnmatchedBackPTS  = kCMTimeInvalid;
  }
  return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

  // ── Identify camera ────────────────────────────────────────────────────────
  BOOL isFront = (output == self.frontOutput);
  BOOL isBack  = (output == self.backOutput);

  if (!isFront && !isBack) {
    // Unknown output — should never happen. Ignore.
    return;
  }

  // ── Extract PTS ────────────────────────────────────────────────────────────
  // CMSampleBufferGetPresentationTimeStamp is a lightweight read.
  // The sample buffer is NOT retained beyond this scope.
  CMTime newPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

  if (!CMTIME_IS_NUMERIC(newPTS)) {
    // Non-numeric PTS (invalid / indefinite) — skip pairing, still count frame.
    if (isFront) self.frontFramesReceived++;
    else         self.backFramesReceived++;
    return;
  }

  // ── Software pairing ───────────────────────────────────────────────────────
  if (isFront) {
    self.frontFramesReceived++;
    [self _pairNewPTS:newPTS
             isFront:YES];
  } else {
    self.backFramesReceived++;
    [self _pairNewPTS:newPTS
             isFront:NO];
  }

  // ── Peak systemPressureCost ────────────────────────────────────────────────
  if (@available(iOS 13.0, *)) {
    AVCaptureMultiCamSession *mc = (AVCaptureMultiCamSession *)self.session;
    if (mc) {
      double cost = (double)mc.systemPressureCost;
      if (cost > self.peakSystemPressureCost) {
        self.peakSystemPressureCost = cost;
      }
    }
  }
}

/// Implements the nearest-neighbour software pairing algorithm described in
/// the header. Called from captureOutput:didOutputSampleBuffer:fromConnection:
/// which always runs on the serial captureQ — no locking needed.
///
/// @param newPTS  The presentation timestamp of the newly arrived frame.
/// @param isFront YES if the frame came from the front camera, NO for back.
- (void)_pairNewPTS:(CMTime)newPTS isFront:(BOOL)isFront {
  // Pointers to the relevant "my" and "other" pending PTS storage.
  // Because Objective-C does not allow taking the address of a property directly,
  // we read/write them explicitly.

  BOOL otherHasPending = isFront
      ? CMTIME_IS_NUMERIC(self.lastUnmatchedBackPTS)
      : CMTIME_IS_NUMERIC(self.lastUnmatchedFrontPTS);

  if (otherHasPending) {
    CMTime otherPTS = isFront ? self.lastUnmatchedBackPTS
                               : self.lastUnmatchedFrontPTS;

    // Compute absolute drift in seconds.
    Float64 newSec   = CMTimeGetSeconds(newPTS);
    Float64 otherSec = CMTimeGetSeconds(otherPTS);
    double drift = fabs(newSec - otherSec);

    if (drift <= kPairingThresholdSeconds) {
      // ── Paired ──────────────────────────────────────────────────────────
      self.pairedFramesReceived++;

      if (drift > self.maxDriftSeconds) {
        self.maxDriftSeconds = drift;
      }
      self.accumulatedDriftSeconds += drift;

      // Clear other pending — this frame was consumed in a pair.
      if (isFront) self.lastUnmatchedBackPTS  = kCMTimeInvalid;
      else         self.lastUnmatchedFrontPTS = kCMTimeInvalid;
      // Do NOT store newPTS — it was paired.

    } else {
      // ── Stale other frame — too far apart to pair ────────────────────────
      if (isFront) {
        self.unmatchedBackFrames++;
        self.lastUnmatchedBackPTS  = kCMTimeInvalid;
      } else {
        self.unmatchedFrontFrames++;
        self.lastUnmatchedFrontPTS = kCMTimeInvalid;
      }
      // Store the new frame as unmatched, replacing any previous same-side pending.
      [self _storePendingPTS:newPTS isFront:isFront];
    }

  } else {
    // ── No other pending frame yet: store this one as unmatched ─────────────
    [self _storePendingPTS:newPTS isFront:isFront];
  }
}

/// Stores newPTS as the latest unmatched frame on the given side.
/// If there is already a pending PTS on the same side, it is counted as
/// unmatched first (replaced by the newer frame).
- (void)_storePendingPTS:(CMTime)newPTS isFront:(BOOL)isFront {
  if (isFront) {
    if (CMTIME_IS_NUMERIC(self.lastUnmatchedFrontPTS)) {
      // A previous front frame never got a partner — count it as unmatched.
      self.unmatchedFrontFrames++;
    }
    self.lastUnmatchedFrontPTS = newPTS;
  } else {
    if (CMTIME_IS_NUMERIC(self.lastUnmatchedBackPTS)) {
      // A previous back frame never got a partner — count it as unmatched.
      self.unmatchedBackFrames++;
    }
    self.lastUnmatchedBackPTS = newPTS;
  }
}

/// Flushes any remaining unmatched pending PTS at the end of the run window.
/// Call after stopRunning drains captureQ.
- (void)flushPendingUnmatched {
  if (CMTIME_IS_NUMERIC(self.lastUnmatchedFrontPTS)) {
    self.unmatchedFrontFrames++;
    self.lastUnmatchedFrontPTS = kCMTimeInvalid;
  }
  if (CMTIME_IS_NUMERIC(self.lastUnmatchedBackPTS)) {
    self.unmatchedBackFrames++;
    self.lastUnmatchedBackPTS = kCMTimeInvalid;
  }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
          fromConnection:(AVCaptureConnection *)connection {
  // Intentionally no-op. alwaysDiscardsLateVideoFrames=YES may drop frames
  // under load; the diagnostic counts delivered frames only.
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardMultiCamSyncDiagnostic

+ (nullable NSDictionary<NSString *, NSNumber *> *)
    runForFrontId:(NSString *)frontId
           backId:(NSString *)backId {

  // ── iOS 13 guard ──────────────────────────────────────────────────────────
  if (@available(iOS 13.0, *)) {
    // proceed below
  } else {
    NSLog(@"[MultiCamSync] iOS 13 required; returning nil.");
    return nil;
  }

  // ── MultiCam hardware support guard ───────────────────────────────────────
  if (@available(iOS 13.0, *)) {
    if (!AVCaptureMultiCamSession.isMultiCamSupported) {
      NSLog(@"[MultiCamSync] MultiCam not supported on this device; returning nil.");
      return nil;
    }
  }

  // ── Camera authorization check (no prompt — check only) ───────────────────
  // Opus requirement: do NOT call requestAccess. If not yet authorized,
  // return nil. The existing camera startup path handles authorization prompts.
  AVAuthorizationStatus authStatus =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (authStatus != AVAuthorizationStatusAuthorized) {
    NSLog(@"[MultiCamSync] Camera not authorized (status=%ld); returning nil.",
          (long)authStatus);
    return nil;
  }

  // ── Locate devices by uniqueID ────────────────────────────────────────────
  AVCaptureDevice *frontDevice = _syncDeviceForUniqueId(frontId);
  AVCaptureDevice *backDevice  = _syncDeviceForUniqueId(backId);

  if (!frontDevice) {
    NSLog(@"[MultiCamSync] Front device not found for uniqueID: %@", frontId);
    return nil;
  }
  if (!backDevice) {
    NSLog(@"[MultiCamSync] Back device not found for uniqueID: %@", backId);
    return nil;
  }

  // ── Allocate session ──────────────────────────────────────────────────────
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
    NSLog(@"[MultiCamSync] Front input error: %@", frontErr.localizedDescription);
    [session commitConfiguration];
    return nil;
  }
  if (![session canAddInput:frontInput]) {
    NSLog(@"[MultiCamSync] Cannot add front input to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addInputWithNoConnections:frontInput];

  // ── Back camera input ─────────────────────────────────────────────────────
  NSError *backErr = nil;
  AVCaptureDeviceInput *backInput =
      [AVCaptureDeviceInput deviceInputWithDevice:backDevice error:&backErr];
  if (backErr || !backInput) {
    NSLog(@"[MultiCamSync] Back input error: %@", backErr.localizedDescription);
    [session commitConfiguration];
    return nil;
  }
  if (![session canAddInput:backInput]) {
    NSLog(@"[MultiCamSync] Cannot add back input to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addInputWithNoConnections:backInput];

  // ── Front camera output ───────────────────────────────────────────────────
  //
  // setSampleBufferDelegate is intentionally used here.
  // MC-5 uses independent per-output delegates (same as MC-4) because
  // AVCaptureDataOutputSynchronizer is not suitable for independent
  // front/back cameras — see header for full rationale.
  AVCaptureVideoDataOutput *frontOutput = [[AVCaptureVideoDataOutput alloc] init];
  frontOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
  };
  frontOutput.alwaysDiscardsLateVideoFrames = YES;

  if (![session canAddOutput:frontOutput]) {
    NSLog(@"[MultiCamSync] Cannot add front output to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addOutputWithNoConnections:frontOutput];

  // ── Back camera output ────────────────────────────────────────────────────
  AVCaptureVideoDataOutput *backOutput = [[AVCaptureVideoDataOutput alloc] init];
  backOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
  };
  backOutput.alwaysDiscardsLateVideoFrames = YES;

  if (![session canAddOutput:backOutput]) {
    NSLog(@"[MultiCamSync] Cannot add back output to session.");
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
      // Portrait-canonical — matches VanguardCameraMediaSource contract.
      if (frontConn.isVideoOrientationSupported) {
        frontConn.videoOrientation = AVCaptureVideoOrientationPortrait;
      }
      if (frontConn.isVideoMirroringSupported) {
        frontConn.automaticallyAdjustsVideoMirroring = NO;
        frontConn.videoMirrored = YES; // front: mirrored
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
      if (backConn.isVideoOrientationSupported) {
        backConn.videoOrientation = AVCaptureVideoOrientationPortrait;
      }
      if (backConn.isVideoMirroringSupported) {
        backConn.automaticallyAdjustsVideoMirroring = NO;
        backConn.videoMirrored = NO; // back: not mirrored
      }
    }
  }

  [session commitConfiguration];

  // ── Read hardwareCost (post-config, pre-start) ────────────────────────────
  double hardwareCost = 0.0;
  if (@available(iOS 13.0, *)) {
    hardwareCost = (double)session.hardwareCost;
  }
  NSLog(@"[MultiCamSync] hardwareCost=%.4f (pre-start)", hardwareCost);

  // ── Dedicated serial dispatch queue ───────────────────────────────────────
  //
  // Both outputs share this single serial queue. The serial ordering
  // ensures that the software pairing state machine executes atomically
  // without any additional locking.
  dispatch_queue_t captureQ = dispatch_queue_create(
      "com.vanguard.multicam.sync.diagnostic",
      dispatch_queue_attr_make_with_qos_class(
          DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));

  // ── Allocate delegate ─────────────────────────────────────────────────────
  _VanguardMC5SoftPairDelegate *delegate =
      [[_VanguardMC5SoftPairDelegate alloc] init];
  delegate.session     = session;
  delegate.frontOutput = frontOutput;
  delegate.backOutput  = backOutput;

  // ── Wire delegates ────────────────────────────────────────────────────────
  //
  // Individual setSampleBufferDelegate:queue: is the correct approach for
  // independent camera pairing. Both outputs share the same serial captureQ,
  // enabling lock-free access to the shared pairing state in the delegate.
  // This matches the MC-4 pattern proven to work on physical devices.
  [frontOutput setSampleBufferDelegate:delegate queue:captureQ];
  [backOutput  setSampleBufferDelegate:delegate queue:captureQ];

  // ── Start running ─────────────────────────────────────────────────────────
  NSLog(@"[MultiCamSync] Calling startRunning...");
  NSTimeInterval startWall = CACurrentMediaTime();
  [session startRunning];
  NSLog(@"[MultiCamSync] Session isRunning=%d", session.isRunning);

  // ── 3-second diagnostic window ────────────────────────────────────────────
  //
  // Block the calling background thread. captureQ is a different queue and
  // delivers frames freely during this sleep.
  [NSThread sleepForTimeInterval:kSyncDiagnosticDurationSeconds];

  NSTimeInterval elapsed = CACurrentMediaTime() - startWall;

  // ── Stop running ──────────────────────────────────────────────────────────
  [session stopRunning];
  NSLog(@"[MultiCamSync] Session stopped. isRunning=%d", session.isRunning);

  // ── Clear delegates ───────────────────────────────────────────────────────
  //
  // Prevents residual queue-scheduled callbacks from firing after stopRunning.
  // Belt-and-suspenders: stopRunning already drains captureQ.
  [frontOutput setSampleBufferDelegate:nil queue:nil];
  [backOutput  setSampleBufferDelegate:nil queue:nil];

  // ── Flush remaining unmatched pending PTS ─────────────────────────────────
  //
  // After stopRunning drains captureQ, no more callbacks will fire.
  // Any PTS still in lastUnmatchedFrontPTS / lastUnmatchedBackPTS never
  // found a partner. Count them as unmatched.
  [delegate flushPendingUnmatched];

  // ── Collect results ───────────────────────────────────────────────────────
  int32_t paired          = delegate.pairedFramesReceived;
  int32_t frontFrames     = delegate.frontFramesReceived;
  int32_t backFrames      = delegate.backFramesReceived;
  int32_t unmatchedFront  = delegate.unmatchedFrontFrames;
  int32_t unmatchedBack   = delegate.unmatchedBackFrames;
  double  maxDrift        = delegate.maxDriftSeconds;
  double  accDrift        = delegate.accumulatedDriftSeconds;
  double  peakPressure    = delegate.peakSystemPressureCost;

  double averageDrift = (paired > 0) ? (accDrift / (double)paired) : 0.0;

  NSLog(@"[MultiCamSync] paired=%d, front=%d, back=%d, "
        "unmatchedFront=%d, unmatchedBack=%d, "
        "maxDrift=%.6fs, avgDrift=%.6fs, peakPressure=%.4f, elapsed=%.3fs",
        (int)paired, (int)frontFrames, (int)backFrames,
        (int)unmatchedFront, (int)unmatchedBack,
        maxDrift, averageDrift, peakPressure, elapsed);

  return @{
    @"pairedFramesReceived":    @((int32_t)paired),
    @"frontFramesReceived":     @((int32_t)frontFrames),
    @"backFramesReceived":      @((int32_t)backFrames),
    @"unmatchedFrontFrames":    @((int32_t)unmatchedFront),
    @"unmatchedBackFrames":     @((int32_t)unmatchedBack),
    @"maxDriftSeconds":         @(maxDrift),
    @"averageDriftSeconds":     @(averageDrift),
    @"peakSystemPressureCost":  @(peakPressure),
    @"hardwareCost":            @(hardwareCost),
    @"durationSeconds":         @(elapsed),
    @"pairingThresholdSeconds": @(kPairingThresholdSeconds),
  };
}

@end
