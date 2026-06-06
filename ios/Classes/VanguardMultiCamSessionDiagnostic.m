// VanguardMultiCamSessionDiagnostic.m
// vanguard_media_engine — MC-3: Non-running MultiCam hardware cost diagnostic.

#import "VanguardMultiCamSessionDiagnostic.h"

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the AVCaptureDevice with the given uniqueID, or nil if not found.
static AVCaptureDevice *_deviceForUniqueId(NSString *uniqueId) {
  for (AVCaptureDevice *device in [AVCaptureDevice devices]) {
    if ([device.uniqueID isEqualToString:uniqueId]) {
      return device;
    }
  }
  return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardMultiCamSessionDiagnostic

+ (nullable NSDictionary<NSString *, NSNumber *> *)
    measureCostForFrontId:(NSString *)frontId
                   backId:(NSString *)backId {
  // ── iOS 13 guard ──────────────────────────────────────────────────────────
  if (@available(iOS 13.0, *)) {
    // proceed below
  } else {
    NSLog(@"[MultiCamDiag] iOS 13 required; returning nil.");
    return nil;
  }

  // ── MultiCam hardware support guard ───────────────────────────────────────
  if (@available(iOS 13.0, *)) {
    if (!AVCaptureMultiCamSession.isMultiCamSupported) {
      NSLog(@"[MultiCamDiag] MultiCam not supported on this device; returning nil.");
      return nil;
    }
  }

  // ── Camera authorization check (no prompt — check only) ───────────────────
  // Opus requirement: do NOT call requestAccess. If not yet authorized,
  // return nil. The existing camera startup path handles authorization prompts.
  AVAuthorizationStatus authStatus =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (authStatus != AVAuthorizationStatusAuthorized) {
    NSLog(@"[MultiCamDiag] Camera not authorized (status=%ld); returning nil.",
          (long)authStatus);
    return nil;
  }

  // ── Locate devices by uniqueID ────────────────────────────────────────────
  AVCaptureDevice *frontDevice = _deviceForUniqueId(frontId);
  AVCaptureDevice *backDevice  = _deviceForUniqueId(backId);

  if (!frontDevice) {
    NSLog(@"[MultiCamDiag] Front device not found for uniqueID: %@", frontId);
    return nil;
  }
  if (!backDevice) {
    NSLog(@"[MultiCamDiag] Back device not found for uniqueID: %@", backId);
    return nil;
  }

  // ── Allocate session (not retained beyond this method scope) ──────────────
  //
  // NOTE: ARC destroys the session and all its inputs/outputs when this
  // method returns. startRunning is never called.
  AVCaptureMultiCamSession * __autoreleasing session = nil;
  if (@available(iOS 13.0, *)) {
    session = [[AVCaptureMultiCamSession alloc] init];
  }

  [session beginConfiguration];

  // ── Front camera input ────────────────────────────────────────────────────
  NSError *frontErr = nil;
  AVCaptureDeviceInput *frontInput =
      [AVCaptureDeviceInput deviceInputWithDevice:frontDevice error:&frontErr];
  if (frontErr || !frontInput) {
    NSLog(@"[MultiCamDiag] Front input error: %@", frontErr.localizedDescription);
    [session commitConfiguration];
    return nil;
  }
  if (![session canAddInput:frontInput]) {
    NSLog(@"[MultiCamDiag] Cannot add front input to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addInputWithNoConnections:frontInput];

  // ── Back camera input ─────────────────────────────────────────────────────
  NSError *backErr = nil;
  AVCaptureDeviceInput *backInput =
      [AVCaptureDeviceInput deviceInputWithDevice:backDevice error:&backErr];
  if (backErr || !backInput) {
    NSLog(@"[MultiCamDiag] Back input error: %@", backErr.localizedDescription);
    [session commitConfiguration];
    return nil;
  }
  if (![session canAddInput:backInput]) {
    NSLog(@"[MultiCamDiag] Cannot add back input to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addInputWithNoConnections:backInput];

  // ── Front camera output (BGRA, no delegate — no frames delivered) ─────────
  //
  // Outputs must be added to get an accurate hardwareCost reading.
  // Opus requirement: do NOT set setSampleBufferDelegate:queue:.
  AVCaptureVideoDataOutput *frontOutput = [[AVCaptureVideoDataOutput alloc] init];
  frontOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
  };
  frontOutput.alwaysDiscardsLateVideoFrames = YES;
  // setSampleBufferDelegate intentionally NOT called.

  if (![session canAddOutput:frontOutput]) {
    NSLog(@"[MultiCamDiag] Cannot add front output to session.");
    [session commitConfiguration];
    return nil;
  }
  [session addOutputWithNoConnections:frontOutput];

  // ── Back camera output (BGRA, no delegate — no frames delivered) ──────────
  AVCaptureVideoDataOutput *backOutput = [[AVCaptureVideoDataOutput alloc] init];
  backOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
  };
  backOutput.alwaysDiscardsLateVideoFrames = YES;
  // setSampleBufferDelegate intentionally NOT called.

  if (![session canAddOutput:backOutput]) {
    NSLog(@"[MultiCamDiag] Cannot add back output to session.");
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
      // Portrait-canonical: always portrait so ISP delivers stable buffers.
      // Mirroring: automaticallyAdjustsVideoMirroring = NO, front = mirrored.
      if (frontConn.isVideoOrientationSupported) {
        frontConn.videoOrientation = AVCaptureVideoOrientationPortrait;
      }
      if (frontConn.isVideoMirroringSupported) {
        frontConn.automaticallyAdjustsVideoMirroring = NO;
        frontConn.videoMirrored = YES; // front camera: mirrored
      }
    }
  }

  // ── Connect back input port → back output ────────────────────────────────
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
      // ── Orientation/mirroring contract — matches VanguardCameraMediaSource ─
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

  // ── Read hardwareCost BEFORE startRunning ─────────────────────────────────
  //
  // Per Apple documentation, hardwareCost is valid after configuration and
  // before startRunning. It reflects ISP bandwidth consumed by the configured
  // inputs/outputs/formats. Values > 1.0 indicate the configuration is not
  // runnable.
  //
  // systemPressureCost is intentionally NOT read here per Opus architecture
  // validation: it is only meaningful on a running session.
  float hardwareCost = 0.0;
  if (@available(iOS 13.0, *)) {
    hardwareCost = session.hardwareCost;
  }

  NSLog(@"[MultiCamDiag] hardwareCost=%.4f for front=%@ back=%@",
        hardwareCost, frontId, backId);

  // ── DO NOT call startRunning ──────────────────────────────────────────────
  // startRunning is explicitly forbidden in MC-3.
  // The session is destroyed by ARC when this method returns.

  BOOL isWithinBudget = (hardwareCost <= 1.0f);

  return @{
    @"hardwareCost":   @((double)hardwareCost),
    @"isWithinBudget": @(isWithinBudget),
  };
}

@end
