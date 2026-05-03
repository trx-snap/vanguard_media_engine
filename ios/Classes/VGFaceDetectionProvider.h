// VGFaceDetectionProvider.h
// Phase 4C — Step 1: Async face detection provider (DEC-61).
//
// Provides throttled, async face/landmark detection using Apple Vision.
// Designed to be owned by a filter node (e.g. BeautyV2FilterGroup) and
// queried for the latest cached face observations each frame.
//
// Threading contract:
//   - detectInPixelBuffer: may be called from any thread (render thread OK).
//   - Detection work runs on a private serial dispatch queue.
//   - latestResult is atomic — safe to read from the render thread.
//   - Detection NEVER blocks the caller; if a detection is already in-flight
//     or the throttle has not elapsed, the call returns immediately.
//
// Lifecycle:
//   - Create with initWithCadenceFrames:
//   - Call detectInPixelBuffer: each render frame (throttle is internal).
//   - Read latestResult for the most recent detection.
//   - Call invalidate on teardown to cancel pending work.
//
// Architecture alignment:
//   DEC-58 — render path remains synchronous (provider is async, never blocks GPU)
//   DEC-61 — platform-native face detection only (Vision framework)
//   RR-54  — throttled cadence mitigates latency spikes
//   RR-57  — cached results bridge detection gaps

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// VGDetectedFace — lightweight face observation model
// ---------------------------------------------------------------------------
// Normalized coordinates [0,1] in Vision orientation (origin = bottom-left).
// Step 2 (mask generation) will convert to pixel coordinates.

@interface VGDetectedFace : NSObject

/// Normalized face bounding box [0,1] in Vision coordinate space.
/// Origin = bottom-left. Width and height are fractions of the image.
@property (nonatomic, readonly) CGRect boundingBox;

/// Detection confidence [0,1]. 0 = low confidence, 1 = high.
@property (nonatomic, readonly) float confidence;

/// Roll angle in radians (rotation around the axis pointing out of the face).
/// 0 = upright. May be nil if not available.
@property (nonatomic, readonly, nullable) NSNumber *rollAngle;

/// Yaw angle in radians (rotation around vertical axis).
/// 0 = facing camera. May be nil if not available.
@property (nonatomic, readonly, nullable) NSNumber *yawAngle;

/// Face contour landmark points (normalized [0,1], Vision coords).
/// nil if landmarks were not requested or not available.
/// Array of NSValue-wrapped CGPoints.
@property (nonatomic, readonly, nullable) NSArray<NSValue *> *faceContourPoints;

/// Left eye landmark points. nil if not available.
@property (nonatomic, readonly, nullable) NSArray<NSValue *> *leftEyePoints;

/// Right eye landmark points. nil if not available.
@property (nonatomic, readonly, nullable) NSArray<NSValue *> *rightEyePoints;

/// Left eyebrow landmark points. nil if not available.
@property (nonatomic, readonly, nullable) NSArray<NSValue *> *leftEyebrowPoints;

/// Right eyebrow landmark points. nil if not available.
@property (nonatomic, readonly, nullable) NSArray<NSValue *> *rightEyebrowPoints;

/// Outer lips landmark points. nil if not available.
@property (nonatomic, readonly, nullable) NSArray<NSValue *> *outerLipsPoints;

/// Nose landmark points. nil if not available.
@property (nonatomic, readonly, nullable) NSArray<NSValue *> *nosePoints;

- (instancetype)init NS_UNAVAILABLE;

@end

// ---------------------------------------------------------------------------
// VGFaceDetectionResult — timestamped detection result
// ---------------------------------------------------------------------------

@interface VGFaceDetectionResult : NSObject

/// Array of detected faces (may be empty if no faces found).
@property (nonatomic, readonly) NSArray<VGDetectedFace *> *faces;

/// Timestamp of the source frame used for this detection.
@property (nonatomic, readonly) CMTime sourcePTS;

/// Wall-clock time when detection completed (for staleness checks).
@property (nonatomic, readonly) CFAbsoluteTime completionTime;

- (instancetype)init NS_UNAVAILABLE;

@end

// ---------------------------------------------------------------------------
// VGFaceDetectionProvider — async throttled face detection
// ---------------------------------------------------------------------------

@interface VGFaceDetectionProvider : NSObject

/// Latest detection result. Atomic — safe to read from any thread.
/// nil until the first detection completes.
@property (atomic, readonly, nullable) VGFaceDetectionResult *latestResult;

/// Whether detection is currently enabled. Default: YES.
/// Set to NO to pause detection without deallocating the provider.
@property (nonatomic, assign) BOOL enabled;

/// Number of render frames to skip between detections.
/// Default: 3 (detect every 3rd frame → ~10 Hz at 30fps).
/// Minimum: 1 (detect every frame). Maximum: 30.
@property (nonatomic, assign) NSInteger cadenceFrames;

/// Maximum number of faces to detect. Default: 5.
/// Set to 1 for single-face optimisation.
@property (nonatomic, assign) NSInteger maxFaces;

/// Creates a face detection provider.
/// @param cadenceFrames Number of render frames between detections.
///        E.g. 3 = detect every 3rd call to detectInPixelBuffer:.
- (instancetype)initWithCadenceFrames:(NSInteger)cadenceFrames NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Submit a frame for face detection.
///
/// This method is designed to be called every render frame. Internally it
/// throttles based on cadenceFrames and skips if a detection is already
/// in-flight. The method returns immediately — it NEVER blocks.
///
/// @param pixelBuffer The input frame. The provider retains it for the
///        duration of async detection and releases it upon completion.
/// @param pts         Presentation timestamp of the frame.
- (void)detectInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        pts:(CMTime)pts;

/// Cancel any in-flight detection and release resources.
/// Safe to call multiple times. After invalidate, detectInPixelBuffer: is a no-op.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
