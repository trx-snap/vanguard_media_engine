// VanguardMultiCamPairedFrame.m
// vanguard_media_engine — MC-8: MultiCam paired-frame pixel buffer lifecycle.
//
// ── IMPLEMENTATION NOTES ─────────────────────────────────────────────────────
//
// This is an intentionally minimal RAII wrapper. The only non-trivial logic is
// in the designated initializer (storing the ivars) and dealloc (releasing both
// pixel buffers).
//
// Buffer ownership invariant:
//   - The initializer does NOT call CVPixelBufferRetain.
//   - The caller must pass already-retained (+1) buffers.
//   - dealloc calls CVPixelBufferRelease on each non-NULL buffer.
//   - CVPixelBufferRelease(NULL) is undefined per CoreFoundation. We guard.
//
// This pattern is identical to the VanguardCameraMediaSource._latestBuffer
// ownership domain (see line ~472 in VanguardCameraMediaSource.m).
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamFramePairer.*    VanguardMultiCamSyncDiagnostic.*
//   VanguardCameraMediaSource.*      VGCameraGraphSession.*
//   VanguardMediaSource.h            VanguardMediaEnginePlugin.swift
//   connectsapp_*/**                 Android code
//   Phase 8 overlay files

#import "VanguardMultiCamPairedFrame.h"

// ─────────────────────────────────────────────────────────────────────────────
// Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardMultiCamPairedFrame {
    // Both buffers are +1 retained on init, released in dealloc.
    // These are raw CF types — ARC does not manage them.
    CVPixelBufferRef _frontBuffer;
    CMTime           _frontPTS;
    CVPixelBufferRef _backBuffer;
    CMTime           _backPTS;
}

// ─── Designated initializer ───────────────────────────────────────────────────

- (instancetype)initWithFrontBuffer:(CVPixelBufferRef)frontBuffer
                           frontPTS:(CMTime)frontPTS
                         backBuffer:(CVPixelBufferRef)backBuffer
                            backPTS:(CMTime)backPTS {
    self = [super init];
    if (!self) return nil;

    // Take ownership — caller has already retained both buffers (+1 each).
    // We do NOT call CVPixelBufferRetain here.
    _frontBuffer = frontBuffer;
    _frontPTS    = frontPTS;
    _backBuffer  = backBuffer;
    _backPTS     = backPTS;

    return self;
}

// ─── Property accessors ───────────────────────────────────────────────────────

- (CVPixelBufferRef)frontBuffer { return _frontBuffer; }
- (CMTime)frontPTS              { return _frontPTS;    }
- (CVPixelBufferRef)backBuffer  { return _backBuffer;  }
- (CMTime)backPTS               { return _backPTS;     }

// ─── Dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    // Release both retained buffers.
    // Guard against NULL — CVPixelBufferRelease(NULL) is undefined behavior.
    if (_frontBuffer) {
        CVPixelBufferRelease(_frontBuffer);
        _frontBuffer = NULL;
    }
    if (_backBuffer) {
        CVPixelBufferRelease(_backBuffer);
        _backBuffer = NULL;
    }
}

@end
