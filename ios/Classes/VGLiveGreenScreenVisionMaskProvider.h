// VGLiveGreenScreenVisionMaskProvider.h
// Generic live green-screen: Apple Vision person-segmentation conformer of
// VGMaskProvider. RND / diagnostic backend used to A/B the production
// LiteRT/Metal path (VGLiteRTMaskProvider + VGLiveGreenScreenPersonMattePolicy)
// against VNGeneratePersonSegmentationRequest through the same live physical
// smoke. Caller-agnostic — live meeting/calling, going live, camera, or any
// other surface; nothing here is scoped to Duet.
//
// Selection: VGLiveGreenScreenMaskProviderAdapter instantiates this class only
// when it was created with the `visionFast` / `visionBalanced` / `visionAccurate`
// segmentation backend (diagnostics options for the next start). The production adapter
// `init` / `litert` backend never touches this class.
//
// Pipeline per frame (private serial Vision queue):
//   VNImageRequestHandler(cameraPixelBuffer)
//     → performRequests:[VNGeneratePersonSegmentationRequest]   (quality fast|balanced|accurate,
//                                                                outputPixelFormat OneComponent8)
//     → VNPixelBufferObservation.pixelBuffer                     (OneComponent8, 255 = person)
//     → row-by-row copy into an immutable VGSkinMask snapshot    (faceCount = 1 → valid matte)
//   Missing observation / unexpected pixel format / lock failure → nothing is
//   published for that frame (latestMask keeps the previous snapshot); never a crash.
//
// Threading / backlog (same shape as VGLiteRTMaskProvider's pending-frame guard):
//   submitFrame:pts:generation: never blocks the capture queue. Under one
//   os_unfair_lock it either (a) marks a frame in flight, retains it, and
//   dispatches to the Vision queue, or (b) — while a frame is in flight —
//   replaces the single pending slot (newest frame wins; the replaced frame is
//   released). When the in-flight frame finishes, the Vision queue drains the
//   pending slot immediately and only then clears the in-flight flag, so at
//   most one in-flight + one pending frame exist and the queue can never back
//   up. latestMask is atomic — safe to read from any thread. invalidate is
//   terminal and idempotent; afterwards submitFrame is a no-op.
//
// Availability: VNGeneratePersonSegmentationRequest requires iOS 15. On earlier
// systems initWithQuality: returns nil; the adapter maps that to
// providerKind = unavailable (no silent fallback to another backend, so an A/B
// run can never report "Vision" numbers produced by something else).
//
// Timing diagnostics reuse VGLiteRTMaskProviderTimingSample so the adapter's
// aggregation code is shared unchanged. Field mapping for THIS provider:
//   preMs          = VNImageRequestHandler creation (+ lazy request creation on
//                    the first frame)
//   inputCopyMs    = 0 — Vision reads the CVPixelBuffer directly; there is no
//                    host → tensor copy
//   invokeMs       = performRequests: span — the Vision request itself
//   inferMs        = inputCopyMs + invokeMs == invokeMs
//   outputAccessMs = results → VNPixelBufferObservation → pixelBuffer + format check
//   policyMs       = OneComponent8 row copy into the VGSkinMask snapshot
//   postMs         = outputAccessMs + policyMs
//   totalMs        = preMs + inferMs + postMs (whole frame on the Vision queue)
//   cadenceMs / ptsSeconds / generation / frameIndex — as for LiteRT
//   (cadence = publish-to-publish gap, -1 for the first publish; frameIndex is
//   the 1-based count of frames that entered processing, including failures).
// Samples are delivered only after a successful publish, on the Vision queue.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import "VGMaskProvider.h"
#import "VGLiteRTMaskProvider.h"   // VGLiteRTMaskProviderTimingSample / -Handler (reused, see mapping above)

@class VGSkinMask;

NS_ASSUME_NONNULL_BEGIN

/// VNGeneratePersonSegmentationRequestQualityLevel levels offered for the A/B.
/// `accurate` is Vision's full-resolution, highest-quality (and slowest) level.
/// It is exposed RND-only so its real per-frame cost and matte quality can be
/// measured on the same physical harness as fast/balanced; nothing here claims
/// it is suitable for a live-preview session.
typedef NS_ENUM(NSInteger, VGLiveGreenScreenVisionMaskQuality) {
    VGLiveGreenScreenVisionMaskQualityFast     = 0,
    VGLiveGreenScreenVisionMaskQualityBalanced = 1,
    VGLiveGreenScreenVisionMaskQualityAccurate = 2,
};

@interface VGLiveGreenScreenVisionMaskProvider : NSObject <VGMaskProvider>

/// Latest published person matte. Atomic — safe from any thread. nil until the
/// first successful Vision request; unchanged by frames that produce no mask.
@property (atomic, readonly, nullable) VGSkinMask *latestMask;

/// Quality level fixed at init.
@property (atomic, readonly) VGLiveGreenScreenVisionMaskQuality quality;

/// "fast" | "balanced" | "accurate". The adapter reports providerMode = "vision_" + qualityName.
@property (atomic, readonly, copy) NSString *qualityName;

/// YES from a successful init until invalidate (Vision person segmentation is
/// available on this system and the provider accepts frames).
@property (atomic, readonly, getter=isReady) BOOL ready;

/// Optional diagnostic hook, delivered on the private Vision queue after each
/// successful publish (see the field mapping in the file header). Nil by
/// default; when nil only the throttled NSLog diagnostics run. Never fired
/// after invalidate.
@property (atomic, copy, nullable) VGLiteRTMaskProviderTimingHandler onTimingSample;

/// Designated initializer. Returns nil when VNGeneratePersonSegmentationRequest
/// is unavailable (iOS < 15).
- (nullable instancetype)initWithQuality:(VGLiveGreenScreenVisionMaskQuality)quality NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
