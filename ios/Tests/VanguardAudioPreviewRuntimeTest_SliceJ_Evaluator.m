// VanguardAudioPreviewRuntimeTest_SliceJ_Evaluator.m
// Vanguard Media Engine — Audio Slice J
//
// 6 evaluator selectors: testJ_T17 through testJ_T22.
// Tests the VGAudioPreviewEnvelopeEvaluator pure contract.

#import "VanguardAudioPreviewRuntimeTest.h"
#import "VGAudioPreviewEnvelopeEvaluator.h"
#import "VGAudioPreviewVolumeKeyframe.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

static VGAudioPreviewVolumeKeyframe *mkKF(NSTimeInterval t, float v) {
  return [[VGAudioPreviewVolumeKeyframe alloc] initWithTime:t volume:v];
}

static NSArray<VGAudioPreviewVolumeKeyframe *> *ramp(void) {
  // Envelope: (0, 0) → (5, 1) → (10, 0.5)
  return @[mkKF(0.0, 0.0f), mkKF(5.0, 1.0f), mkKF(10.0, 0.5f)];
}

@implementation VanguardAudioPreviewRuntimeTest (SliceJEvaluator)

// T17: PTS before first point returns first volume.
- (void)testJ_T17_ptsBeforeFirstPoint {
  float v = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:ramp() atPTS:-1.0];
  XCTAssertEqualWithAccuracy(v, 0.0f, 1e-6f);
}

// T18: PTS at exact first point returns first volume.
- (void)testJ_T18_ptsAtFirstPoint {
  float v = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:ramp() atPTS:0.0];
  XCTAssertEqualWithAccuracy(v, 0.0f, 1e-6f);
}

// T19: linear interpolation between points.
- (void)testJ_T19_linearInterpolation {
  float v = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:ramp() atPTS:2.5];
  XCTAssertEqualWithAccuracy(v, 0.5f, 1e-5f);
}

// T20: PTS at exact middle point returns exact volume.
- (void)testJ_T20_ptsAtMiddlePoint {
  float v = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:ramp() atPTS:5.0];
  XCTAssertEqualWithAccuracy(v, 1.0f, 1e-6f);
}

// T21: PTS after last point returns last volume.
- (void)testJ_T21_ptsAfterLastPoint {
  float v = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:ramp() atPTS:15.0];
  XCTAssertEqualWithAccuracy(v, 0.5f, 1e-6f);
}

// T22: interpolation in second segment (5 → 10).
- (void)testJ_T22_interpolationInSecondSegment {
  float v = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:ramp() atPTS:7.5];
  // Linear: 1.0 + (0.5/5.0) * 2.5 = 0.75
  XCTAssertEqualWithAccuracy(v, 0.75f, 1e-5f);
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
