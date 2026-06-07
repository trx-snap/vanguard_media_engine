// VanguardMultiCamMediaSource.m
// vanguard_media_engine — MC-7/MC-8: Production MultiCam media source.
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
#import "VanguardMultiCamPairedFrame.h"
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

    // ── Pending pixel buffers (MC-8) ──────────────────────────────────────────
    //
    // At most one pending +1-retained buffer per camera side at any time.
    // Written and read exclusively on the serial _captureQ — no locks needed.
    // Released on displacement (new frame arrives before pair forms),
    // on stop (after stopRunning drains captureQ), and in dealloc (safety net).
    CVPixelBufferRef _pendingFrontBuffer;  // NULL if none pending
    CMTime           _pendingFrontPTS;
    CVPixelBufferRef _pendingBackBuffer;   // NULL if none pending
    CMTime           _pendingBackPTS;

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
@synthesize delegate = _delegate;

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
    _pendingFrontBuffer = NULL;
    _pendingFrontPTS    = kCMTimeInvalid;
    _pendingBackBuffer  = NULL;
    _pendingBackPTS     = kCMTimeInvalid;

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

    // ── Release any remaining pending pixel buffers (MC-8) ────────────────────────
    //
    // After stopRunning drains captureQ, no more delegate callbacks will fire.
    // Any pending buffers were never paired — release them now.
    // Guard against NULL: CVPixelBufferRelease(NULL) is undefined behavior.
    if (_pendingFrontBuffer) {
        CVPixelBufferRelease(_pendingFrontBuffer);
        _pendingFrontBuffer = NULL;
    }
    if (_pendingBackBuffer) {
        CVPixelBufferRelease(_pendingBackBuffer);
        _pendingBackBuffer = NULL;
    }

    NSLog(@"[MC8] stop complete. paired=%d front=%d back=%d "
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

    // ── Extract PTS and pixel buffer ──────────────────────────────────────────
    //
    // CMSampleBufferGetPresentationTimeStamp: lightweight CMTime read (~1µs).
    // CMSampleBufferGetImageBuffer: returns CVPixelBuffer at +0, owned by
    //   CMSampleBuffer, valid only for the duration of this callback.
    //   We must CVPixelBufferRetain before storing or using beyond this scope.
    // CMSampleBuffer is NOT retained.
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    // ── Feed PTS to pairer ────────────────────────────────────────────────────
    //
    // VanguardMultiCamFramePairer (MC-6) is CMTime-only and is NOT modified.
    // Returns YES if a pair formed (|frontPTS − backPTS| ≤ threshold).
    BOOL paired;
    if (isFront) {
        paired = [_pairer offerFrontPTS:pts];
    } else {
        paired = [_pairer offerBackPTS:pts];
    }

    if (paired) {
        // ── Pair formed ───────────────────────────────────────────────────────
        //
        // The current callback's pixelBuffer is +0 (borrowed). Retain for pair.
        // The pending buffer from the other side is already +1 (stored earlier).
        // Transfer ownership of both to VanguardMultiCamPairedFrame.
        CVPixelBufferRetain(pixelBuffer);  // +1 for the paired frame

        CVPixelBufferRef frontBuf, backBuf;
        CMTime frontPTS, backPTS;

        if (isFront) {
            frontBuf = pixelBuffer;        // +1 just retained
            frontPTS = pts;
            backBuf  = _pendingBackBuffer; // +1 from prior pending storage
            backPTS  = _pendingBackPTS;
            _pendingBackBuffer = NULL;     // ownership transferred; do NOT release
        } else {
            backBuf  = pixelBuffer;         // +1 just retained
            backPTS  = pts;
            frontBuf = _pendingFrontBuffer; // +1 from prior pending storage
            frontPTS = _pendingFrontPTS;
            _pendingFrontBuffer = NULL;     // ownership transferred; do NOT release
        }

        // Construct paired frame — takes ownership of both +1 buffers.
        // dealloc calls CVPixelBufferRelease on each buffer.
        VanguardMultiCamPairedFrame *frame =
            [[VanguardMultiCamPairedFrame alloc]
                initWithFrontBuffer:frontBuf frontPTS:frontPTS
                         backBuffer:backBuf  backPTS:backPTS];

        // Deliver synchronously on captureQ.
        // Delegate must return quickly — no GPU work, no blocking I/O.
        // Do NOT retain frame beyond the callback unless needed.
        id<VanguardMultiCamMediaSourceDelegate> delegate = _delegate;
        if (delegate) {
            [delegate multiCamMediaSource:self didOutputPairedFrame:frame];
        }
        // ARC releases frame here → dealloc → CVPixelBufferRelease × 2.

    } else {
        // ── Not paired — store as pending unmatched ───────────────────────────
        //
        // Retain the current buffer (+1) for pending storage.
        // If there is already a pending buffer on this side, it was displaced
        // (the pairer cleared it as stale) — release the old one.
        CVPixelBufferRetain(pixelBuffer);  // +1 for pending storage

        if (isFront) {
            if (_pendingFrontBuffer) {
                CVPixelBufferRelease(_pendingFrontBuffer);  // release displaced
            }
            _pendingFrontBuffer = pixelBuffer;  // takes +1 ownership
            _pendingFrontPTS    = pts;
        } else {
            if (_pendingBackBuffer) {
                CVPixelBufferRelease(_pendingBackBuffer);   // release displaced
            }
            _pendingBackBuffer = pixelBuffer;   // takes +1 ownership
            _pendingBackPTS    = pts;
        }
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

// ─── dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    // Safety net: release any pending pixel buffers that were not consumed
    // (e.g., if stop was not called before dealloc, or stop was interrupted).
    // Guard against NULL: CVPixelBufferRelease(NULL) is undefined behavior.
    if (_pendingFrontBuffer) {
        CVPixelBufferRelease(_pendingFrontBuffer);
        _pendingFrontBuffer = NULL;
    }
    if (_pendingBackBuffer) {
        CVPixelBufferRelease(_pendingBackBuffer);
        _pendingBackBuffer = NULL;
    }
}

@end
