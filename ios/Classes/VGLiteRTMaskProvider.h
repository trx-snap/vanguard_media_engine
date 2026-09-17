// VGLiteRTMaskProvider.h
// Phase 9B-2 — TFLite/LiteRT-backed VGMaskProvider conformer.
//
// Owns the full model/interpreter lifecycle for one .tflite segmentation
// model and bridges raw CVPixelBuffer frames to a VGSkinMask. The tensor
// contract is read from the model after tensor allocation (not assumed):
//   input   float32 NHWC, N = 1, C = 3 (RGB, [0,1]); any positive H/W
//   output  float32 NHWC, N = 1, any positive H/W, C ∈ {1, 2, 6}
//     C = 6 → MediaPipe Selfie Multiclass (256×256 only): the matte is built
//             by the injected VGFaceNeckBeautyMaskPolicy (processTensor:…).
//     C = 1 → channel 0 is person confidence; C = 2 → the last channel is
//             person confidence (MediaPipe selfie segmenter layouts). The
//             provider publishes the confidence directly as a OneComponent8
//             matte at the model output size — no policy, no temporal state.
//   Anything else fails closed at setup (fallback mode).
//
// Threading:
//   submitFrame:pts:generation: is non-blocking — dispatches to _mlQueue.
//   All TFLite interpreter calls and policy calls run on _mlQueue (serial).
//   latestMask is atomic — safe to read from any thread.
//
// Fallback:
//   If model load, interpreter creation, tensor allocation, contract
//   validation, scratch allocation, or the optional warm-up invoke fails, the
//   provider enters fallback mode and forwards all frame submissions to the
//   supplied fallback provider (if any).
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

// ─── Input geometry ──────────────────────────────────────────────────────────

/// How a camera frame is mapped into the model input tensor. Fixed at init.
typedef NS_ENUM(NSInteger, VGLiteRTInputGeometry) {
    /// Anamorphic resize: the whole frame is stretched to the tensor size
    /// (pre-existing behaviour). The multiclass policy resamples its matte
    /// back to the frame aspect, so the stretch is undone there.
    VGLiteRTInputGeometryStretch = 0,
    /// Aspect-preserving fit: the frame is scaled to fit inside the tensor,
    /// centred, and the remaining border is zero (black). A matte published at
    /// the model output aspect (the direct person-confidence path) then lines
    /// up with the frame when the consumer scale-to-fills + centre-crops it —
    /// the compositor's existing mask placement — because that crop removes
    /// exactly the border. (A centre-crop/cover mapping would NOT line up with
    /// that placement: the two crops fall on different axes.)
    VGLiteRTInputGeometryAspectFit = 1,
};

// ─── Diagnostic timing sample ────────────────────────────────────────────────

/// One per-frame timing sample. Delivered through `onTimingSample` after each
/// successful mask publish (i.e. immediately after `latestMask` was replaced).
/// All durations are wall-clock milliseconds measured on the ML queue.
///
/// Span decomposition (each span is measured back-to-back, no gaps):
///   preMs          = pixel buffer → float RGB scratch
///   inputCopyMs    = TfLiteInterpreterGetInputTensor + TfLiteTensorCopyFromBuffer
///   invokeMs       = TfLiteInterpreterInvoke only
///   outputAccessMs = TfLiteInterpreterGetOutputTensor + TfLiteTensorData
///                    (with the Metal delegate this is where any GPU → host
///                    readback/synchronization not already paid inside
///                    Invoke shows up)
///   policyMs       = policy processTensor:… (matte build), or the direct
///                    person-confidence byte matte build for 1/2-channel models
///   inferMs        = inputCopyMs + invokeMs            (backward-compatible;
///                    output access is NOT included)
///   postMs         = outputAccessMs + policyMs         (backward-compatible)
///   totalMs        = preMs + inferMs + postMs
typedef struct VGLiteRTMaskProviderTimingSample {
    /// Pixel-buffer → float RGB preprocessing.
    double     preMs;
    /// Combined inference span: inputCopyMs + invokeMs. Kept for callers that
    /// predate the split; excludes output tensor access (see postMs).
    double     inferMs;
    /// Output tensor access + policy (matte build): outputAccessMs + policyMs.
    double     postMs;
    /// preMs + inferMs + postMs (single frame, end to end on the ML queue).
    double     totalMs;
    /// Host scratch → input tensor (TfLiteTensorCopyFromBuffer, including the
    /// TfLiteInterpreterGetInputTensor lookup that precedes it).
    double     inputCopyMs;
    /// TfLiteInterpreterInvoke only.
    double     invokeMs;
    /// TfLiteInterpreterGetOutputTensor + TfLiteTensorData pointer access.
    double     outputAccessMs;
    /// Policy processTensor:… (matte build) only.
    double     policyMs;
    /// Time since the previous successful publish; -1 for the first publish.
    double     cadenceMs;
    /// CMTimeGetSeconds of the frame's PTS (NaN when the PTS is not numeric).
    double     ptsSeconds;
    /// Seek-generation stamp the frame was submitted with.
    uint64_t   generation;
    /// 1-based index of frames that entered processing (includes failed frames).
    NSUInteger frameIndex;
} VGLiteRTMaskProviderTimingSample;

/// Invoked on the provider's private serial ML queue. Must return quickly and
/// must not call back into the provider synchronously.
typedef void (^VGLiteRTMaskProviderTimingHandler)(VGLiteRTMaskProviderTimingSample sample);

// ─── VGLiteRTMaskProvider ─────────────────────────────────────────────────────

/// TFLite/LiteRT-backed mask provider (MediaPipe selfie models).
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

/// Metal delegate precision option this instance was created with
/// (TFLGpuDelegateOptions.allow_precision_loss). NO = full float32 precision
/// (the default and the only pre-existing behaviour); YES = the delegate may
/// downcast to float16 ("fast Metal"). Fixed at init; ignored on simulator
/// (no Metal delegate) and meaningless in fallback mode.
@property (atomic, readonly) BOOL metalAllowPrecisionLoss;

/// Inference backend actually attached, for diagnostics:
///   "metal_fp32"    — device, Metal delegate, allow_precision_loss = NO
///   "metal_fp16"    — device, Metal delegate, allow_precision_loss = YES
///   "cpu_simulator" — simulator build, no Metal delegate
///   "unavailable"   — provider is in fallback mode (no interpreter)
@property (atomic, readonly, copy) NSString *inferenceBackend;

/// Frame → input tensor mapping this instance was created with.
@property (atomic, readonly) VGLiteRTInputGeometry inputGeometry;

/// Model input tensor size (W×H×C) read after tensor allocation; 0 until
/// ready and in fallback mode.
@property (atomic, readonly) NSInteger inputWidth;
@property (atomic, readonly) NSInteger inputHeight;
@property (atomic, readonly) NSInteger inputChannels;

/// Model output tensor size (W×H×C) read after tensor allocation; 0 until
/// ready and in fallback mode. outputChannels is 6 on the multiclass policy
/// path and 1 or 2 on the direct person-confidence path.
@property (atomic, readonly) NSInteger outputWidth;
@property (atomic, readonly) NSInteger outputHeight;
@property (atomic, readonly) NSInteger outputChannels;

/// Matte path selected by the output contract, for diagnostics:
///   "multiclass_policy"        — 6-channel output → policy processTensor:…
///   "person_confidence_direct" — 1/2-channel output → direct byte matte at
///                                the model output size, no temporal smoothing
///   "none"                     — not ready / fallback mode
@property (atomic, readonly, copy) NSString *mattePath;

/// Optional diagnostic hook. Nil by default: when nil the provider's timing
/// path is byte-for-byte the pre-existing throttled os_log path and no extra
/// clock reads happen. When set, every successful publish also measures the
/// frame and delivers one sample on the ML queue. Not fired in fallback mode
/// (frames are forwarded to `fallback` instead) and never after `invalidate`.
@property (atomic, copy, nullable) VGLiteRTMaskProviderTimingHandler onTimingSample;

/// Convenience initializer. Uses default VGFaceNeckBeautyMaskPolicy.
///
/// @param modelURL  File URL to the .tflite model asset.
/// @param fallback  Optional provider to forward frames to in fallback mode.
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback;

/// Convenience initializer. Allows injection of a custom policy (primarily for
/// testing). Full float32 Metal precision (metalAllowPrecisionLoss = NO) —
/// identical to the behaviour before the precision option existed.
///
/// @param modelURL  File URL to the .tflite model asset.
/// @param fallback  Optional provider to forward frames to in fallback mode.
/// @param policy    Policy to use; if nil, a default instance is created.
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy;

/// Convenience initializer. Adds the Metal delegate precision option; stretch
/// input geometry, no warm-up invoke (the pre-existing production path).
///
/// @param modelURL                 File URL to the .tflite model asset.
/// @param fallback                 Optional provider to forward frames to in fallback mode.
/// @param policy                   Policy to use; if nil, a default instance is created.
/// @param metalAllowPrecisionLoss  NO = full float32 precision (default path);
///                                 YES = TFLGpuDelegateOptions.allow_precision_loss
///                                 ("fast Metal", float16 permitted). No effect
///                                 on simulator builds.
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy
                  metalAllowPrecisionLoss:(BOOL)metalAllowPrecisionLoss;

/// Designated initializer.
///
/// @param modelURL                 File URL to the .tflite model asset.
/// @param fallback                 Optional provider to forward frames to in fallback mode.
/// @param policy                   Policy for a 6-channel model; if nil, a
///                                 default instance is created once the model
///                                 proves to be 6-channel. Unused (never
///                                 created) for 1/2-channel models.
/// @param metalAllowPrecisionLoss  As above.
/// @param inputGeometry            Frame → input tensor mapping (see enum).
/// @param warmUpInvokeAtSetup      YES runs one TfLiteInterpreterInvoke with a
///                                 zero input during setup and enters fallback
///                                 mode if it fails — makes a model the
///                                 attached delegate/runtime cannot execute
///                                 (e.g. an unresolved custom op) fail closed
///                                 at setup instead of on every frame. NO is
///                                 the pre-existing behaviour.
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                                 fallback:(nullable id<VGMaskProvider>)fallback
                                   policy:(nullable VGFaceNeckBeautyMaskPolicy *)policy
                  metalAllowPrecisionLoss:(BOOL)metalAllowPrecisionLoss
                            inputGeometry:(VGLiteRTInputGeometry)inputGeometry
                      warmUpInvokeAtSetup:(BOOL)warmUpInvokeAtSetup
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
