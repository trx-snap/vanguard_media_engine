// VGFileSourceAdapter.h
// Phase 3: Adapter only. No runtime wiring.
//
// Wraps VanguardFileMediaSource into the V2 VGSourceNode protocol so a file-
// based media source can be registered in a VGGraphDescriptor-driven DAG
// without modifying VanguardFileMediaSource.
//
// Dependency note: Lives in vanguard_media_engine (NOT UMF).
//   vanguard_media_engine → UMF (one-way dependency, no circular risk).
//
// Pixel parity verification deferred to Phase 4 gate (RR-V2-003).
//
// pullFrame: is a Phase 3 stub — returns error. File source is push-only.
//   VanguardFileMediaSource has no synchronous pull API. Frame production is
//   callback-based (readNextFrameForPlayback fires _videoCallback on
//   _videoDecodeQueue). Callback-to-sync conversion is unsafe in Phase 3
//   (deadlock risk with serial decode queue). Phase 4 scheduler will bridge
//   this via the push-mode path (startProducing/stopProducing).
//
// Phase 3 stubs:
//   - pullFrame: → returns errorResult (push-only source, no sync API)
//   - negotiateFormatForPort:inputFormats: → returns nil
//   - seekTo:generation: → forwards time only; V2 generation ignored

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration — full definition in VanguardFileMediaSource.h,
// imported in the .m file only.
@class VanguardFileMediaSource;

/// Thin V2 adapter wrapping VanguardFileMediaSource as a push-mode VGSourceNode.
///
/// Push-mode delegation:
///   startProducing → [source start] — starts AVAssetReader + audio engine
///   stopProducing  → [source stop]  — tears down reader + audio engine
///
/// pullFrame: is a Phase 3 stub that returns an error result. The file source
/// is callback-driven; synchronous pull requires Phase 4 scheduler integration.
@interface VGFileSourceAdapter : NSObject <VGSourceNode>

/// The wrapped file media source. Retained by this adapter.
@property (nonatomic, strong, readonly) VanguardFileMediaSource *source;

/// Designated initialiser.
/// @param source  The VanguardFileMediaSource instance to wrap. Must not be nil.
- (instancetype)initWithSource:(VanguardFileMediaSource *)source NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
