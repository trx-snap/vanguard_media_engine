// VGImageSourceAdapter.h
// Phase 3: Adapter only. No runtime wiring.
//
// Wraps VanguardImageMediaSource into the V2 VGSourceNode protocol so a static
// image can be used as a pull-mode source in a VGGraphDescriptor-driven DAG
// without modifying VanguardImageMediaSource.
//
// Dependency note: Lives in vanguard_media_engine (NOT UMF).
//   vanguard_media_engine → UMF (one-way dependency, no circular risk).
//
// Pixel parity verification deferred to Phase 4 gate (RR-V2-003).
//
// Buffer ownership contract:
//   pullFrame: calls [source copyRawBuffer], which returns a +1 CVPixelBufferRef
//   (verified: VanguardImageMediaSource.m line 334 calls CVPixelBufferRetain).
//   That +1 buffer is placed directly into VGFrameEnvelope.payload.videoBuffer.
//   The adapter does NOT release the buffer. The VGFrameResult consumer is
//   responsible for CVPixelBufferRelease when done with the frame.
//   Phase 4 must validate the full runtime release path before graph activation.
//
// Phase 3 stubs:
//   - negotiateFormatForPort:inputFormats: → returns nil
//   - startProducing / stopProducing → no-op (pull-only source)
//   - seekTo:generation: → no-op (single-frame; always same image)

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration — full definition in VanguardImageMediaSource.h,
// imported in the .m file only.
@class VanguardImageMediaSource;

/// Thin V2 adapter wrapping VanguardImageMediaSource as a pull-mode VGSourceNode.
///
/// pullFrame: acquires the decoded image buffer via copyRawBuffer and packages
/// it into a VGFrameEnvelope. The buffer's +1 ownership is transferred to the
/// result consumer (see ownership contract in the file header above).
///
/// This adapter is pull-only. startProducing and stopProducing are no-ops.
@interface VGImageSourceAdapter : NSObject <VGSourceNode>

/// The wrapped image media source. Retained by this adapter.
@property (nonatomic, strong, readonly) VanguardImageMediaSource *source;

/// Designated initialiser.
/// @param source  The VanguardImageMediaSource instance to wrap. Must not be nil.
///                The caller is responsible for calling prepareWithCompletion:
///                on the adapter (which delegates to the source) before pullFrame:.
- (instancetype)initWithSource:(VanguardImageMediaSource *)source NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
