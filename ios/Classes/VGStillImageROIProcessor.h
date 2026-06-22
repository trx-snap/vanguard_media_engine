// VGStillImageROIProcessor.h
// vanguard_media_engine — Phase 10-D.4A
//
// Still-image Region-of-Interest (ROI) preprocessor.
//
// Performs a synchronous Vision face detection on an already-decoded UIImage
// and produces a grayscale Core Image mask that can be passed to
// VGROIEntropySuppressionFilterNode for background entropy suppression.
//
// Responsibilities:
//   1. Run VNDetectFaceRectanglesRequest synchronously on the source image.
//   2. Filter detections that are too small (< minFaceRatio).
//   3. For each accepted face bounding-box, apply the configured expansion
//      margins and clamp to image bounds.
//   4. Rasterize a feathered ellipse per face into a shared grayscale pixel
//      buffer (quarter-resolution) using vImage.
//   5. Return the composite mask as a CIImage in the same coordinate space
//      as the canvas (matching canvasWidth × canvasHeight).
//
// Coordinate conventions:
//   - Vision uses normalized [0,1] bottom-left origin coordinates.
//   - Core Image uses bottom-left pixel coordinates.
//   - Because UIImage normalizes EXIF orientation at decode time, and we run
//     Vision on the UIImage-backed CIImage (or CGImage), no Y-inversion is
//     required for the Vision → CI mapping:
//       pixelX = visionX * canvasWidth
//       pixelY = visionY * canvasHeight
//   - Expansion is applied in pixel space and clamped to canvas bounds.
//
// Mask design:
//   - Shape: feathered ellipse per face.
//   - Mask buffer is quarter-resolution (canvasW/4 × canvasH/4) for speed.
//   - After rasterization the mask is upscaled to full canvas resolution via
//     CILanczosScaleTransform + CIGaussianBlur (feather).
//   - Foreground (face/head region) → mask value 1.0 (white, kept sharp).
//   - Background (outside all face boxes) → mask value 0.0 (black, suppressed).
//
// Threading:
//   - Designed for use on a background DispatchQueue (the optimizeImage queue).
//   - All methods are synchronous and single-use.
//   - Not thread-safe for concurrent calls on the same instance.
//
// Failure handling:
//   - Vision errors: treated as "no face detected" — returns nil mask.
//   - Empty observations: returns nil mask.
//   - All small-face rejections leave the image on the standard path.
//
// Phase 10-D.4A — derivative-only. Master export is never modified.

#pragma once

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGROIFaceRegion — expanded, clamped face bounding box in pixel coords ────

/// An expanded face bounding box in canvas pixel coordinates (bottom-left origin).
///
/// Computed from a VNFaceObservation.boundingBox after applying the configured
/// expansion margins and clamping to the canvas dimensions.
@interface VGROIFaceRegion : NSObject

/// Expanded bounding box in canvas pixel coordinates.
/// Origin is bottom-left (Core Image convention).
@property (nonatomic, readonly) CGRect pixelRect;

/// Confidence of the source VNFaceObservation.
@property (nonatomic, readonly) float confidence;

- (instancetype)init NS_UNAVAILABLE;

@end

// ─── VGROIDetectionResult — output of a synchronous detection pass ─────────

/// Result of a single synchronous Vision face detection pass.
@interface VGROIDetectionResult : NSObject

/// All accepted face regions in canvas pixel coordinates.
/// Empty if no faces were detected or all were below minFaceRatio.
@property (nonatomic, readonly) NSArray<VGROIFaceRegion *> *faceRegions;

/// Grayscale mask CIImage at full canvas resolution.
/// Nil if faceRegions is empty.
/// White (1.0) = foreground (ROI), black (0.0) = background.
@property (nonatomic, readonly, nullable) CIImage *maskImage;

/// The detector string to return to Dart.
@property (nonatomic, readonly) NSString *detectorTag;

- (instancetype)init NS_UNAVAILABLE;

@end

// ─── VGStillImageROIProcessor ─────────────────────────────────────────────────

/// Synchronous still-image ROI processor.
///
/// Creates one instance per optimizeImage call. Not reusable.
///
/// Call `-detectAndBuildMaskForImage:canvasWidth:canvasHeight:` once.
/// The result is available synchronously on return.
@interface VGStillImageROIProcessor : NSObject

// ── Configuration ────────────────────────────────────────────────────────────

/// Fractional expansion on the left and right of each face bounding box.
/// Default: 0.25 (25%).
@property (nonatomic, assign) double faceExpandX;

/// Fractional upward expansion (head/hair).
/// Default: 0.35 (35%).
@property (nonatomic, assign) double faceExpandYTop;

/// Fractional downward expansion (chin/neck).
/// Default: 0.15 (15%).
@property (nonatomic, assign) double faceExpandYBottom;

/// Minimum face size as a fraction of max(canvasWidth, canvasHeight).
/// Detections below this threshold are rejected. Default: 0.05 (5%).
@property (nonatomic, assign) double minFaceRatio;

/// Gaussian feather radius applied to the upscaled mask (pixels at canvas res).
/// Default: 18.0.
@property (nonatomic, assign) double featherRadius;

// ── Designated initializer ────────────────────────────────────────────────────

/// Creates the processor with default ROI expansion and mask parameters.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

// ── Detection ─────────────────────────────────────────────────────────────────

/// Runs a synchronous Vision face detection on `sourceImage` and builds the
/// ROI mask at (canvasWidth × canvasHeight) resolution.
///
/// @param sourceImage   The orientation-normalized source UIImage (EXIF baked).
///                      Vision runs on the full-resolution image for accuracy.
/// @param canvasWidth   Target canvas width (after downscale by TransformNode).
/// @param canvasHeight  Target canvas height (after downscale by TransformNode).
///
/// @return A VGROIDetectionResult whose `maskImage` is nil when no usable
///         faces are found and non-nil when at least one face passed the
///         minimum-size filter.
- (VGROIDetectionResult *)detectAndBuildMaskForImage:(UIImage *)sourceImage
                                         canvasWidth:(NSInteger)canvasWidth
                                        canvasHeight:(NSInteger)canvasHeight;

@end

NS_ASSUME_NONNULL_END
