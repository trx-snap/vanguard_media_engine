// VanguardMultiCamMediaSource.m
// vanguard_media_engine — MC-7: Production MultiCam media source scaffold.
//
// ── IMPLEMENTATION NOTES ─────────────────────────────────────────────────────
//
// Session wiring pattern:
//   Uses the verbatim addInputWithNoConnections: / addOutputWithNoConnections: /
//   manual AVCaptureConnection pattern proven by MC-4 and MC-5. This is required
//   for AVCaptureMultiCamSession — the standard addInput: / addOutput: API
//   creates implicit connections that are not supported in MultiCam mode.
//
// Delegate pattern:
//   self conforms to AVCaptureVideoDataOutputSampleBufferDelegate.
//   Both front and back outputs share one delegate (self) on one serial captureQ.
//   Front/back are differentiated by output pointer identity:
//     output == _frontOutput → front camera frame
//     output == _backOutput  → back camera frame
//   This is identical to the approach MC-5 used in _VanguardMC5SoftPairDelegate.
//
// Pairing pattern:
//   On each callback, CMSampleBufferGetPresentationTimeStamp extracts the PTS.
//   PTS is fed to VanguardMultiCamFramePairer (MC-6).
//   The BOOL return signals whether a pair was formed — not used in MC-7 but
//   will be used in MC-8+ for CVPixelBuffer retention.
//   The sample buffer is NOT retained. Only the CMTime value is kept.
//
// systemPressureCost tracking:
//   Sampled on every delegate callback, same as MC-5.
//   Must be cast to AVCaptureMultiCamSession inside an @available block.
//
// Lifecycle:
//   init:  configures the session (beginConfiguration / commitConfiguration)
//          but does NOT start it. Returns nil on any configuration failure.
//   start: calls startRunning (synchronous, blocks thread).
//          Returns NO if session.isRunning == NO after the call.
//   stop:  calls stopRunning, nils delegates, calls pairer.flushPendingUnmatched,
//          records elapsed time. Idempotent via _stopped flag.
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamSyncDiagnostic.*     VanguardCameraMediaSource.*
//   VGCameraGraphSession.*               VanguardMediaEnginePlugin.swift
//   VanguardMultiCamFramePairer.*        VanguardMediaSource.h
//   connectsapp_*/**                     Android code
//   Phase 8 overlay files

#import "VanguardMultiCamMediaSource.h"
#import "VanguardMultiCamFramePairer.h"
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Pairing threshold: one full frame at 30 fps ≈ 33.3 ms.
/// Matches kPairingThresholdSeconds in VanguardMultiCamSyncDiagnostic (MC-5).
static const double kMC7PairingThresholdSeconds = 1.0 / 30.0;

// ─────────────────────────────────────────────────────────────────────────────
// Device lookup helper
// ─────────────────────────────────────────────────────────────────────────────

static AVCaptureDevice *_mc7DeviceForUniqueId(NSString *uniqueId) {
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

@interface VanguardMultiCamMediaSource () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation VanguardMultiCamMediaSource {

    // ── Session ───────────────────────────────────────────────────────────────
    AVCaptureMultiCamSession *_session;

    // ── Outputs (used for pointer-identity differentiation in delegate) ────────
    AVCaptureVideoDataOutput *_frontOutput;
    AVCaptureVideoDataOutput *_backOutput;

    // ── Shared serial delegate queue ──────────────────────────────────────────
    //
    // Both front and back outputs share this single serial queue.
    // Serial ordering ensures VanguardMultiCamFramePairer state is accessed
    // atomically without any additional locking — same invariant as MC-5.
    dispatch_queue_t _captureQ;

    // ── Frame pairer (MC-6) ───────────────────────────────────────────────────
    VanguardMultiCamFramePairer *_pairer;

    // ── Session-level metrics ─────────────────────────────────────────────────
    double _hardwareCost;
    double _peakSystemPressureCost;

    // ── Duration tracking ─────────────────────────────────────────────────────
    NSTimeInterval _startWallTime;
    NSTimeInterval _durationSeconds;

    // ── Lifecycle guard ───────────────────────────────────────────────────────
    // Written from stop; read from stop. stop is documented as safe to call
    // from any thread, so we use an atomic flag.
    _Atomic(BOOL) _stopped;
}

@synthesize pairer = _pairer;

// ─── Designated initializer ───────────────────────────────────────────────────

- (nullable instancetype)initWithFrontDeviceId:(NSString *)frontId
                                  backDeviceId:(NSString *)backId
                                     frameRate:(int)fps {
    self = [super init];
    if (!self) return nil;

    // ── iOS 13 guard ──────────────────────────────────────────────────────────
    // Caller (plugin) guards with #available(iOS 13.0, *) before instantiating.
    // Redundant guard here for defense in depth.
    if (@available(iOS 13.0, *)) {
        // Proceed below.
    } else {
        NSLog(@"[MC7] iOS 13 required; returning nil.");
        return nil;
    }

    // ── MultiCam hardware support guard ───────────────────────────────────────
    if (!AVCaptureMultiCamSession.isMultiCamSupported) {
        NSLog(@"[MC7] AVCaptureMultiCamSession not supported on this device.");
        return nil;
    }

    // ── Camera authorization check (no prompt — check only) ───────────────────
    AVAuthorizationStatus status =
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status != AVAuthorizationStatusAuthorized) {
        NSLog(@"[MC7] Camera not authorized (status=%ld); returning nil.", (long)status);
        return nil;
    }

    // ── Locate devices by uniqueID ────────────────────────────────────────────
    AVCaptureDevice *frontDevice = _mc7DeviceForUniqueId(frontId);
    AVCaptureDevice *backDevice  = _mc7DeviceForUniqueId(backId);

    if (!frontDevice) {
        NSLog(@"[MC7] Front device not found for uniqueID: %@", frontId);
        return nil;
    }
    if (!backDevice) {
        NSLog(@"[MC7] Back device not found for uniqueID: %@", backId);
        return nil;
    }

    // ── Create pairer ─────────────────────────────────────────────────────────
    _pairer = [[VanguardMultiCamFramePairer alloc]
        initWithThresholdSeconds:kMC7PairingThresholdSeconds];

    // ── Create serial capture queue ───────────────────────────────────────────
    _captureQ = dispatch_queue_create(
        "com.vanguard.multicam.source.captureQ",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));

    // ── Create session ────────────────────────────────────────────────────────
    _session = [[AVCaptureMultiCamSession alloc] init];

    [_session beginConfiguration];

    // ── Front camera input ────────────────────────────────────────────────────
    NSError *frontInputErr = nil;
    AVCaptureDeviceInput *frontInput =
        [AVCaptureDeviceInput deviceInputWithDevice:frontDevice
                                              error:&frontInputErr];
    if (frontInputErr || !frontInput) {
        NSLog(@"[MC7] Front input error: %@", frontInputErr.localizedDescription);
        [_session commitConfiguration];
        return nil;
    }
    if (![_session canAddInput:frontInput]) {
        NSLog(@"[MC7] Cannot add front input to session.");
        [_session commitConfiguration];
        return nil;
    }
    [_session addInputWithNoConnections:frontInput];

    // ── Back camera input ─────────────────────────────────────────────────────
    NSError *backInputErr = nil;
    AVCaptureDeviceInput *backInput =
        [AVCaptureDeviceInput deviceInputWithDevice:backDevice
                                              error:&backInputErr];
    if (backInputErr || !backInput) {
        NSLog(@"[MC7] Back input error: %@", backInputErr.localizedDescription);
        [_session commitConfiguration];
        return nil;
    }
    if (![_session canAddInput:backInput]) {
        NSLog(@"[MC7] Cannot add back input to session.");
        [_session commitConfiguration];
        return nil;
    }
    [_session addInputWithNoConnections:backInput];

    // ── Front camera output ───────────────────────────────────────────────────
    _frontOutput = [[AVCaptureVideoDataOutput alloc] init];
    _frontOutput.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    _frontOutput.alwaysDiscardsLateVideoFrames = YES;

    if (![_session canAddOutput:_frontOutput]) {
        NSLog(@"[MC7] Cannot add front output to session.");
        [_session commitConfiguration];
        return nil;
    }
    [_session addOutputWithNoConnections:_frontOutput];

    // ── Back camera output ────────────────────────────────────────────────────
    _backOutput = [[AVCaptureVideoDataOutput alloc] init];
    _backOutput.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    _backOutput.alwaysDiscardsLateVideoFrames = YES;

    if (![_session canAddOutput:_backOutput]) {
        NSLog(@"[MC7] Cannot add back output to session.");
        [_session commitConfiguration];
        return nil;
    }
    [_session addOutputWithNoConnections:_backOutput];

    // ── Front connection: input port → front output ───────────────────────────
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
                                                  output:_frontOutput];
        if ([_session canAddConnection:frontConn]) {
            [_session addConnection:frontConn];
            // Portrait-canonical — matches VanguardCameraMediaSource contract.
            if (frontConn.isVideoOrientationSupported) {
                frontConn.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if (frontConn.isVideoMirroringSupported) {
                frontConn.automaticallyAdjustsVideoMirroring = NO;
                frontConn.videoMirrored = YES; // front: mirrored
            }
        } else {
            NSLog(@"[MC7] Cannot add front connection.");
        }
    } else {
        NSLog(@"[MC7] No video port found on front input.");
    }

    // ── Back connection: input port → back output ─────────────────────────────
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
                                                  output:_backOutput];
        if ([_session canAddConnection:backConn]) {
            [_session addConnection:backConn];
            if (backConn.isVideoOrientationSupported) {
                backConn.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if (backConn.isVideoMirroringSupported) {
                backConn.automaticallyAdjustsVideoMirroring = NO;
                backConn.videoMirrored = NO; // back: not mirrored
            }
        } else {
            NSLog(@"[MC7] Cannot add back connection.");
        }
    } else {
        NSLog(@"[MC7] No video port found on back input.");
    }

    [_session commitConfiguration];

    // ── Read hardwareCost (post-config, pre-start) ────────────────────────────
    _hardwareCost = (double)_session.hardwareCost;
    NSLog(@"[MC7] hardwareCost=%.4f (post-config, pre-start)", _hardwareCost);

    // ── Wire delegates ────────────────────────────────────────────────────────
    //
    // Both outputs share self as delegate on the single serial captureQ.
    // Serial ordering ensures lock-free access to _pairer and metrics state.
    [_frontOutput setSampleBufferDelegate:self queue:_captureQ];
    [_backOutput  setSampleBufferDelegate:self queue:_captureQ];

    _stopped = NO;
    _startWallTime = 0;
    _durationSeconds = 0;

    return self;
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

- (BOOL)start {
    NSLog(@"[MC7] Calling startRunning...");
    _startWallTime = CACurrentMediaTime();
    [_session startRunning];
    BOOL running = _session.isRunning;
    NSLog(@"[MC7] Session isRunning=%d", running);
    return running;
}

- (void)stop {
    // Idempotent: only execute stop logic once.
    BOOL alreadyStopped = atomic_exchange(&_stopped, YES);
    if (alreadyStopped) {
        NSLog(@"[MC7] stop called again — no-op (already stopped).");
        return;
    }

    // ── Record elapsed time ───────────────────────────────────────────────────
    if (_startWallTime > 0) {
        _durationSeconds = CACurrentMediaTime() - _startWallTime;
    }

    // ── Stop session ──────────────────────────────────────────────────────────
    [_session stopRunning];
    NSLog(@"[MC7] Session stopped. isRunning=%d durationSeconds=%.3f",
          _session.isRunning, _durationSeconds);

    // ── Nil delegates ─────────────────────────────────────────────────────────
    //
    // Prevents any residual queue-scheduled callbacks from firing post-stop.
    // Belt-and-suspenders: stopRunning already drains the captureQ.
    [_frontOutput setSampleBufferDelegate:nil queue:nil];
    [_backOutput  setSampleBufferDelegate:nil queue:nil];

    // ── Flush remaining unmatched PTS ─────────────────────────────────────────
    //
    // After stopRunning drains captureQ, no more callbacks will fire.
    // Any PTS still pending in the pairer never found a partner — count them.
    [_pairer flushPendingUnmatched];

    NSLog(@"[MC7] stop complete. paired=%d front=%d back=%d "
          "unmatchedFront=%d unmatchedBack=%d "
          "maxDrift=%.6fs avgDrift=%.6fs peakPressure=%.4f",
          (int)_pairer.pairedFramesReceived,
          (int)_pairer.frontFramesReceived,
          (int)_pairer.backFramesReceived,
          (int)_pairer.unmatchedFrontFrames,
          (int)_pairer.unmatchedBackFrames,
          _pairer.maxDriftSeconds,
          _pairer.averageDriftSeconds,
          _peakSystemPressureCost);
}

// ─── Metrics ──────────────────────────────────────────────────────────────────

- (NSDictionary<NSString *, NSNumber *> *)metrics {
    // Merge pairer metrics with session-level metrics.
    // Pairer metrics dictionary has 8 keys matching VGMultiCamSyncReport shape.
    NSMutableDictionary<NSString *, NSNumber *> *result =
        [NSMutableDictionary dictionaryWithDictionary:[_pairer metrics]];

    result[@"peakSystemPressureCost"] = @(_peakSystemPressureCost);
    result[@"hardwareCost"]           = @(_hardwareCost);
    result[@"durationSeconds"]        = @(_durationSeconds);

    return [result copy];
}

// ─── AVCaptureVideoDataOutputSampleBufferDelegate ─────────────────────────────

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {

    // ── Identify camera by output pointer identity ────────────────────────────
    BOOL isFront = (output == _frontOutput);
    BOOL isBack  = (output == _backOutput);

    if (!isFront && !isBack) {
        // Unknown output — should never happen.
        return;
    }

    // ── Extract PTS ────────────────────────────────────────────────────────────
    //
    // CMSampleBufferGetPresentationTimeStamp is a lightweight read (~1µs).
    // The sample buffer is NOT retained beyond this scope.
    // CMSampleBufferGetImageBuffer is NOT called — no CVPixelBuffer access.
    // CVBufferRetain is NOT called.
    // CVBufferRelease is NOT called.
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    // ── Feed PTS to pairer ────────────────────────────────────────────────────
    //
    // VanguardMultiCamFramePairer handles non-numeric PTS internally.
    // The BOOL return (paired?) is not used in MC-7 — reserved for MC-8+
    // when a paired CVPixelBuffer will be retained for compositing.
    if (isFront) {
        [_pairer offerFrontPTS:pts];
    } else {
        [_pairer offerBackPTS:pts];
    }

    // ── Track peak systemPressureCost ─────────────────────────────────────────
    //
    // All state access here is safe without locks: this method always runs
    // on the serial _captureQ.
    double cost = (double)_session.systemPressureCost;
    if (cost > _peakSystemPressureCost) {
        _peakSystemPressureCost = cost;
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    // Intentionally no-op.
    // alwaysDiscardsLateVideoFrames = YES may drop frames under load.
    // The source counts only delivered frames.
}

@end
