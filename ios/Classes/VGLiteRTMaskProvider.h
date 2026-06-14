// VGLiteRTMaskProvider.h
// Phase 9B-2 — TFLite/LiteRT-backed VGMaskProvider conformer.
//
// Owns the full model/interpreter lifecycle for selfie_multiclass_256x256.tflite
// and bridges raw CVPixelBuffer frames to VGFaceNeckBeautyMaskPolicy output.
//
// Threading:
//   submitFrame:pts:generation: is non-blocking — dispatches to _mlQueue.
//   All TFLite interpreter calls and policy calls run on _mlQueue (serial).
//   latestMask is atomic — safe to read from any thread.
//
// Fallback:
//   If model load, interpreter creation, tensor allocation, or any inference
//   step fails, the provider enters fallback mode and forwards all frame
//   submissions to the supplied fallback provider (if any).
//
// Non-goals (Phase 9B-2):
//   No Metal shader preprocessing.
//   No production graph wiring (that is Phase 9B-3).
//   No Dart API changes.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import "VGMaskProvider.h"

@class VGSkinMask;
@class VGFaceNeckBeautyMaskPolicy;

NS_ASSUME_NONNULL_BEGIN

// ─── VGLiteRTMaskProvider ─────────────────────────────────────────────────────

/// TFLite/LiteRT-backed mask provider using MediaPipe Selfie Multiclass.
///
/// Conforms to VGMaskProvider. Owns the TFLite interpreter lifecycle
/// on a private serial queue. Publishes VGSkinMask via latestMask.
@interface VGLiteRTMaskProvider : NSObject <VGMaskProvider>

/// Latest generated mask. Nil until the first successful inference completes
/// or while in fallback mode (returns fallback.latestMask instead).
@property (atomic, readonly, nullable) VGSkinMask *latestMask;

/// YES when provider is in fallback mode (model/interpreter/tensor failure).
@property (atomic, readonly, getter=isUsingFallback) BOOL usingFallback;

/// YES once interpreter is ready and tensors are allocated.
@property (atomic, readonly, getter=isReady) BOOL ready;

/// Convenience initializer. Uses default VGFaceNeckBeautyMaskPolicy.
///
/// @param modelURL  File URL to the .tflite model asset.
/// @param fallback  Optional provider to forward frames to in fallback mode.
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback;

/// Designated initializer. Allows injection of a custom policy (primarily for testing).
///
/// @param modelURL  File URL to the .tflite model asset.
/// @param fallback  Optional provider to forward frames to in fallback mode.
/// @param policy    Policy to use; if nil, a default instance is created.
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
