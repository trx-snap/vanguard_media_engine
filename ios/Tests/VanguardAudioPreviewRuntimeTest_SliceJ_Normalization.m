// VanguardAudioPreviewRuntimeTest_SliceJ_Normalization.m
// Vanguard Media Engine — Audio Slice J
//
// 16 normalization selectors: testJ_T1 through testJ_T16.
// Tests the VGAudioPreviewKeyframeNormalizer pure contract.

#import "VanguardAudioPreviewRuntimeTest.h"
#import "VGAudioPreviewKeyframeNormalizer.h"
#import "VGAudioPreviewVolumeKeyframe.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (SliceJNormalization)

static NSDictionary *kf(double t, double v) {
  return @{@"time" : @(t), @"volume" : @(v)};
}

static NSDictionary *kfCurve(double t, double v, NSString *curve) {
  return @{@"time" : @(t), @"volume" : @(v), @"curve" : curve};
}

// T1: nil raw array returns nil.
- (void)testJ_T1_nilRawArrayReturnsNil {
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:nil
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNil(result);
}

// T2: empty raw array returns nil.
- (void)testJ_T2_emptyRawArrayReturnsNil {
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:@[]
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNil(result);
}

// T3: non-dictionary entries ignored.
- (void)testJ_T3_nonDictionaryEntriesIgnored {
  NSArray *raw = @[@"not a dict", @42, [NSNull null]];
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNil(result);
}

// T4: missing time or volume rejected.
- (void)testJ_T4_missingTimeOrVolumeRejected {
  NSArray *raw = @[
    @{@"volume" : @(0.5)}, // missing time
    @{@"time" : @(1.0)},   // missing volume
  ];
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNil(result);
}

// T5: nonfinite time or volume rejected.
- (void)testJ_T5_nonfiniteTimeOrVolumeRejected {
  NSArray *raw = @[
    @{@"time" : @(INFINITY), @"volume" : @(0.5)},
    @{@"time" : @(1.0), @"volume" : @(NAN)},
  ];
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNil(result);
}

// T6: absent curve accepted, unsupported curve rejected.
- (void)testJ_T6_absentCurveAcceptedUnsupportedRejected {
  // One valid entry (no curve), one rejected (unsupported curve).
  NSArray *raw = @[
    kf(2.0, 0.5),
    kfCurve(3.0, 0.8, @"ease"),
  ];
  NSArray<VGAudioPreviewVolumeKeyframe *> *result =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                            timelineStart:0.0
                                             effectiveEnd:10.0];
  // Only the first entry survives. Normalizer prepends start (0,0) and
  // appends end (10, lastVolume=0.5).
  XCTAssertNotNil(result);
  XCTAssertEqualWithAccuracy(result[1].time, 2.0, 1e-9);
  XCTAssertEqualWithAccuracy(result[1].volume, 0.5f, 1e-6f);
}

// T7: "linear" curve accepted.
- (void)testJ_T7_linearCurveAccepted {
  NSArray *raw = @[kfCurve(2.0, 0.5, @"linear")];
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNotNil(result);
}

// T8: volume clamped to [0, 1].
- (void)testJ_T8_volumeClamped {
  NSArray *raw = @[
    @{@"time" : @(1.0), @"volume" : @(-0.5)},
    @{@"time" : @(5.0), @"volume" : @(2.5)},
  ];
  NSArray<VGAudioPreviewVolumeKeyframe *> *result =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                            timelineStart:0.0
                                             effectiveEnd:10.0];
  XCTAssertNotNil(result);
  for (VGAudioPreviewVolumeKeyframe *kf in result) {
    XCTAssertGreaterThanOrEqual(kf.volume, 0.0f);
    XCTAssertLessThanOrEqual(kf.volume, 1.0f);
  }
}

// T9: timestamps outside range discarded.
- (void)testJ_T9_outOfRangeTimestampsDiscarded {
  NSArray *raw = @[
    kf(-1.0, 0.5),
    kf(11.0, 0.8),
  ];
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNil(result, @"All out-of-range entries should yield nil");
}

// T10: sorted ascending by time.
- (void)testJ_T10_stableSortedAscending {
  NSArray *raw = @[kf(5.0, 0.5), kf(2.0, 0.2), kf(8.0, 0.8)];
  NSArray<VGAudioPreviewVolumeKeyframe *> *result =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                            timelineStart:0.0
                                             effectiveEnd:10.0];
  XCTAssertNotNil(result);
  for (NSUInteger i = 1; i < result.count; i++) {
    XCTAssertLessThanOrEqual(result[i - 1].time, result[i].time);
  }
}

// T11: adjacent entries < 0.001 s merged; later wins.
- (void)testJ_T11_adjacentMergedLaterWins {
  NSArray *raw = @[kf(2.0, 0.3), kf(2.0005, 0.7)];
  NSArray<VGAudioPreviewVolumeKeyframe *> *result =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                            timelineStart:0.0
                                             effectiveEnd:10.0];
  XCTAssertNotNil(result);
  // Expect: start (0, 0), merged (2.0005, 0.7), end (10, 0.7).
  BOOL foundMerged = NO;
  for (VGAudioPreviewVolumeKeyframe *kf in result) {
    if (fabs(kf.time - 2.0005) < 1e-9) {
      XCTAssertEqualWithAccuracy(kf.volume, 0.7f, 1e-6f);
      foundMerged = YES;
    }
    XCTAssertFalse(fabs(kf.time - 2.0) < 1e-9 && fabs(kf.volume - 0.3f) < 1e-6f,
                   @"Earlier merged entry must not appear");
  }
  XCTAssertTrue(foundMerged);
}

// T12: leading boundary prepended when first point > start + 0.001.
- (void)testJ_T12_leadingBoundaryPrepended {
  NSArray *raw = @[kf(5.0, 0.6)];
  NSArray<VGAudioPreviewVolumeKeyframe *> *result =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                            timelineStart:0.0
                                             effectiveEnd:10.0];
  XCTAssertNotNil(result);
  VGAudioPreviewVolumeKeyframe *first = result.firstObject;
  XCTAssertEqualWithAccuracy(first.time, 0.0, 1e-9);
  XCTAssertEqualWithAccuracy(first.volume, 0.0f, 1e-6f);
}

// T13: trailing boundary appended when last point < end - 0.001.
- (void)testJ_T13_trailingBoundaryAppended {
  NSArray *raw = @[kf(2.0, 0.4)];
  NSArray<VGAudioPreviewVolumeKeyframe *> *result =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                            timelineStart:0.0
                                             effectiveEnd:10.0];
  XCTAssertNotNil(result);
  VGAudioPreviewVolumeKeyframe *last = result.lastObject;
  XCTAssertEqualWithAccuracy(last.time, 10.0, 1e-9);
  XCTAssertEqualWithAccuracy(last.volume, 0.4f, 1e-6f);
}

// T14: all-valid entries without prepend/append needed.
- (void)testJ_T14_noPrependOrAppendWhenAtBoundaries {
  // Points exactly at start and end within 0.001 threshold.
  NSArray *raw = @[kf(0.0, 0.1), kf(10.0, 0.9)];
  NSArray<VGAudioPreviewVolumeKeyframe *> *result =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                            timelineStart:0.0
                                             effectiveEnd:10.0];
  XCTAssertNotNil(result);
  // Should not add extra boundary points since points are at/within 0.001 of
  // effectiveStart and effectiveEnd.
  XCTAssertLessThanOrEqual(result.count, 3UL);
}

// T15: nil returned when all entries out of range.
- (void)testJ_T15_allOutOfRangeReturnsNil {
  NSArray *raw = @[kf(20.0, 0.5), kf(30.0, 0.9)];
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                                           timelineStart:0.0
                                                            effectiveEnd:10.0];
  XCTAssertNil(result);
}

// T16: effectiveEnd <= timelineStart returns nil immediately.
- (void)testJ_T16_zeroRangeReturnsNil {
  NSArray *raw = @[kf(5.0, 0.5)];
  NSArray *result = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:raw
                                                           timelineStart:5.0
                                                            effectiveEnd:5.0];
  XCTAssertNil(result);
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
