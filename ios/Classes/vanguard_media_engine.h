// vanguard_media_engine.h
// Public umbrella header for the vanguard_media_engine CocoaPods framework.
//
// Purpose: satisfies the Swift-generated bridging header's auto-emitted import:
//
//   #import <vanguard_media_engine/vanguard_media_engine.h>
//
// When the Swift compiler (swiftc) generates vanguard_media_engine-Swift.h for
// VGSessionRegistry.swift, it emits this import at the top of that file.
// Without a corresponding header in the framework's public Headers directory,
// the module cannot be built by downstream targets (Runner, integration_test).
//
// This file is a compile-time/module-visibility fix only.
// It has zero runtime impact — no symbols, functions, or data are defined here.
//
// CocoaPods picks this up via the podspec glob:
//   s.source_files = 'Classes/**/*.{swift,h,m,mm,metal}'
// and copies it to the built framework's Headers directory.

#import <Foundation/Foundation.h>

// ── Phase 2 public ObjC surface ──────────────────────────────────────────────
// Only headers that are part of the module's public API and required for
// the Swift-generated bridging header to compile cleanly.
// Do NOT add internal implementation headers here.

#import "VanguardPlaybackTypes.h"     // VGAudioRole enum — used by VGSessionRegistry.swift
#import "VanguardFileMediaSource.h"   // VanguardFileMediaSource — registry-owned runtime source
#import "VanguardGraphRuntime.h"      // VanguardGraphRuntime — primary runtime type cast in Swift
#import "VGReverseSidecarManager.h"   // Phase 7.20B: VGReverseSidecarManager + VGReverseSidecarStatus
#import "VGDualCameraCompositorNode.h" // Phase 7.x-C: DEV descriptor smoke route
// MC-7/MC-8: MultiCam media source and paired-frame type.
// Required so Swift plugin code can reference VanguardMultiCamMediaSource,
// VanguardMultiCamMediaSourceDelegate, and VanguardMultiCamPairedFrame.
#import "VanguardMultiCamMediaSource.h"  // MC-7: VanguardMultiCamMediaSource + delegate protocol
#import "VanguardMultiCamPairedFrame.h"  // MC-8: VanguardMultiCamPairedFrame (RAII pixel buffer wrapper)
// MC-9/MC-19: MultiCam production compositor (promoted from VanguardMultiCamRenderDiagnostic).
// Required so Swift plugin code can reference VanguardMultiCamRenderer.
#import "VanguardMultiCamRenderer.h"  // MC-9/MC-19: MultiCam compositor (production renderer)
// Phase 8.15C: offline audio waveform extraction utility.
#import "VGWaveformExtractor.h"       // VGWaveformExtractor + VGWaveformResult
// Phase 8.16: standalone AVPlayer-backed audio playback service.
#import "VGAudioPlaybackService.h"    // VGAudioPlaybackService
// Phase 8.17: disk-backed waveform result cache.
#import "VGWaveformCache.h"           // VGWaveformCache
