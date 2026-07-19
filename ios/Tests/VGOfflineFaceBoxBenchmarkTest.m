// VGOfflineFaceBoxBenchmarkTest.m
// ROI Compression 2C-Diagnostic — Reader Orientation Side-by-Side Box Comparison
//
// PROOF-ONLY. Do not promote to production.
//
// PURPOSE:
//   Instruments the offline benchmark to test both kCGImagePropertyOrientationRight (6)
//   and kCGImagePropertyOrientationLeft (8) for sequential AVAssetReader CVPixelBuffer frames,
//   runs candidate coordinate transforms (flips/rotations), and outputs side-by-side diagnostic tables.
//
// NO production code is invoked. Specifically:
//   - NO VNDetectFaceLandmarksRequest
//   - NO VGFaceDetectionProvider
//   - NO VGSegmentationNode
//   - NO VGSkinMaskGenerator
//   - NO VGLiteRTMaskProvider
//   - NO BeautyV2 filters
//   - NO export graph
//   - NO compositor
//   - NO encoder

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>

// ─── Result types ─────────────────────────────────────────────────────────────

/// Per-sample timing record.
typedef struct {
    double timestampMs;
    double frameExtractionMs;
    double visionFaceRectMs;
    double totalPerSampleMs;
    NSInteger faceCount;
    CGSize frameSize;          // generated pixel buffer size
    BOOL failed;               // frame extraction or Vision errored out
} VGFBSample;

// ─── Stability helpers ────────────────────────────────────────────────────────

static inline double _rectIntersectionArea(CGRect r1, CGRect r2) {
    CGRect inter = CGRectIntersection(r1, r2);
    if (CGRectIsNull(inter)) return 0.0;
    return inter.size.width * inter.size.height;
}

static inline double _rectUnionArea(CGRect r1, CGRect r2) {
    double a1 = r1.size.width * r1.size.height;
    double a2 = r2.size.width * r2.size.height;
    double inter = _rectIntersectionArea(r1, r2);
    return a1 + a2 - inter;
}

static inline double _rectIoU(CGRect r1, CGRect r2) {
    double unionArea = _rectUnionArea(r1, r2);
    if (unionArea <= 0.0) return 0.0;
    return _rectIntersectionArea(r1, r2) / unionArea;
}

// ─── Coordinate transformations for [0,1] normalized space ────────────────────

static CGRect _applyTransform(NSString *txName, CGRect r) {
    if ([txName isEqualToString:@"flipX"]) {
        return CGRectMake(1.0 - r.origin.x - r.size.width, r.origin.y, r.size.width, r.size.height);
    } else if ([txName isEqualToString:@"flipY"]) {
        return CGRectMake(r.origin.x, 1.0 - r.origin.y - r.size.height, r.size.width, r.size.height);
    } else if ([txName isEqualToString:@"flipXY"]) {
        return CGRectMake(1.0 - r.origin.x - r.size.width, 1.0 - r.origin.y - r.size.height, r.size.width, r.size.height);
    } else if ([txName isEqualToString:@"rotate90CWNormalized"]) {
        // (x, y, w, h) -> (1 - y - h, x, h, w)
        return CGRectMake(1.0 - r.origin.y - r.size.height, r.origin.x, r.size.height, r.size.width);
    } else if ([txName isEqualToString:@"rotate90CCWNormalized"]) {
        // (x, y, w, h) -> (y, 1 - x - w, h, w)
        return CGRectMake(r.origin.y, 1.0 - r.origin.x - r.size.width, r.size.height, r.size.width);
    }
    return r; // identityTopLeft
}

// ─── Test class ───────────────────────────────────────────────────────────────

@interface VGOfflineFaceBoxBenchmarkTest : XCTestCase
@end

@implementation VGOfflineFaceBoxBenchmarkTest

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Resolve the benchmark video URL or return nil.
- (NSURL *)_resolveVideoURLWithSource:(NSString *__autoreleasing *)outSource {
    NSString *envPath = NSProcessInfo.processInfo.environment[@"BENCHMARK_VIDEO_PATH"];
    if (envPath.length > 0) {
        NSURL *envURL = [NSURL fileURLWithPath:envPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:envPath]) {
            if (outSource) *outSource = @"BENCHMARK_VIDEO_PATH env var";
            return envURL;
        }
        NSLog(@"[VGFaceBoxBenchmark] BENCHMARK_VIDEO_PATH set but file not found: %@", envPath);
    }

    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *bundleURL = [bundle URLForResource:@"benchmark_face_clip" withExtension:@"mov"];
    if (bundleURL && [NSFileManager.defaultManager fileExistsAtPath:bundleURL.path]) {
        if (outSource) *outSource = @"bundled test resource (benchmark_face_clip.mov)";
        return bundleURL;
    }

    if (outSource) *outSource = nil;
    return nil;
}

/// Percentile value from a sorted C-array of doubles.
static double _percentile(double *sorted, NSInteger count, double pct) {
    if (count == 0) return 0.0;
    double idx = pct * (double)(count - 1);
    NSInteger lo = (NSInteger)floor(idx);
    NSInteger hi = (NSInteger)ceil(idx);
    if (lo == hi) return sorted[lo];
    double frac = idx - (double)lo;
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

/// Sort comparison for qsort.
static int _cmpDouble(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    if (da < db) return -1;
    if (da > db) return  1;
    return 0;
}

/// Convert Vision normalized bounding box (bottom-left origin) to normalized
/// top-left coordinates so it matches standard UI layout conventions.
static CGRect _visionBoxToTopLeft(CGRect visionBox) {
    return CGRectMake(
        visionBox.origin.x,
        1.0 - visionBox.origin.y - visionBox.size.height,
        visionBox.size.width,
        visionBox.size.height
    );
}

/// Map preferredTransform to CGImagePropertyOrientation so Vision processes unrotated frames correctly.
static CGImagePropertyOrientation _imageOrientationFromTransform(CGAffineTransform t) {
    if (t.a == 0 && t.b == 1.0 && t.c == -1.0 && t.d == 0) {
        // 90 degrees counter-clockwise
        return kCGImagePropertyOrientationLeft; // 8
    } else if (t.a == 0 && t.b == -1.0 && t.c == 1.0 && t.d == 0) {
        // 90 degrees clockwise
        return kCGImagePropertyOrientationRight; // 6
    } else if (t.a == -1.0 && t.b == 0 && t.c == 0 && t.d == -1.0) {
        // 180 degrees
        return kCGImagePropertyOrientationDown; // 3
    }
    // Identity or other
    return kCGImagePropertyOrientationUp; // 1
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Generator-Based Downscaled Benchmark
// ═══════════════════════════════════════════════════════════════════════════════

/// Runs the generator benchmark for one variant configuration.
- (NSDictionary *)_benchmarkGeneratorURL:(NSURL *)videoURL
                            maxDimension:(NSInteger)maxDimension
                           sampleRateFps:(double)sampleRateFps
                             maxDuration:(double)maxDuration {

    NSString *variantName = maxDimension == 0 ? @"full-res" : [NSString stringWithFormat:@"max%ld", (long)maxDimension];
    NSLog(@"[VGFaceBoxBenchmark] START — generatorVariant=%@ sampleRateFps=%.1f", variantName, sampleRateFps);

    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    CMTime assetDuration = asset.duration;
    double assetDurationSec = CMTimeGetSeconds(assetDuration);

    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    CGSize naturalSize = videoTrack ? videoTrack.naturalSize : CGSizeZero;
    CGAffineTransform preferredTransform = videoTrack ? videoTrack.preferredTransform : CGAffineTransformIdentity;
    BOOL hasRotation = !CGAffineTransformEqualToTransform(preferredTransform, CGAffineTransformIdentity);

    double scanDuration = MIN(assetDurationSec, maxDuration);
    double interval = 1.0 / sampleRateFps;
    NSMutableArray<NSValue *> *timestamps = [NSMutableArray array];
    for (double t = 0.0; t < scanDuration; t += interval) {
        [timestamps addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(t, 600)]];
    }

    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;
    if (maxDimension > 0) {
        generator.maximumSize = CGSizeMake(maxDimension, maxDimension);
    } else {
        generator.maximumSize = CGSizeZero;
    }

    NSMutableArray<NSData *> *records = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSValue *> *primaryBoxes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSValue *> *actualTimes = [NSMutableDictionary dictionary];
    NSInteger sampleIndex = 0;

    for (NSValue *tsValue in timestamps) {
        CMTime requestedTime = tsValue.CMTimeValue;
        double requestedSec  = CMTimeGetSeconds(requestedTime);

        VGFBSample sample = {};
        sample.timestampMs = requestedSec * 1000.0;
        sample.failed = NO;

        NSTimeInterval extractStart = CACurrentMediaTime();
        NSError *genError = nil;
        CMTime actualTime = kCMTimeZero;
        CGImageRef cgImage = [generator copyCGImageAtTime:requestedTime
                                               actualTime:&actualTime
                                                    error:&genError];
        NSTimeInterval extractEnd = CACurrentMediaTime();
        sample.frameExtractionMs = (extractEnd - extractStart) * 1000.0;

        if (!cgImage || genError) {
            sample.failed = YES;
            sample.totalPerSampleMs = sample.frameExtractionMs;
            [records addObject:[NSData dataWithBytes:&sample length:sizeof(sample)]];
            sampleIndex++;
            continue;
        }

        actualTimes[@(sample.timestampMs)] = [NSValue valueWithCMTime:actualTime];
        sample.frameSize = CGSizeMake(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));

        VNDetectFaceRectanglesRequest *faceRequest = [[VNDetectFaceRectanglesRequest alloc] init];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
            initWithCGImage:cgImage
                orientation:kCGImagePropertyOrientationUp
                    options:@{}];

        NSTimeInterval visionStart = CACurrentMediaTime();
        NSError *visionError = nil;
        BOOL ok = [handler performRequests:@[faceRequest] error:&visionError];
        NSTimeInterval visionEnd = CACurrentMediaTime();
        sample.visionFaceRectMs = (visionEnd - visionStart) * 1000.0;

        CGImageRelease(cgImage);

        if (!ok || visionError) {
            sample.failed = YES;
            sample.totalPerSampleMs = sample.frameExtractionMs + sample.visionFaceRectMs;
            [records addObject:[NSData dataWithBytes:&sample length:sizeof(sample)]];
            sampleIndex++;
            continue;
        }

        NSArray<VNFaceObservation *> *observations = faceRequest.results;
        sample.faceCount = (NSInteger)observations.count;
        sample.totalPerSampleMs = sample.frameExtractionMs + sample.visionFaceRectMs;

        if (sample.faceCount > 0) {
            VNFaceObservation *bestObs = observations[0];
            for (VNFaceObservation *obs in observations) {
                if (obs.confidence > bestObs.confidence) {
                    bestObs = obs;
                }
            }
            CGRect normTopLeft = _visionBoxToTopLeft(bestObs.boundingBox);
            primaryBoxes[@(sample.timestampMs)] = [NSValue valueWithCGRect:normTopLeft];
        }

        [records addObject:[NSData dataWithBytes:&sample length:sizeof(sample)]];
        sampleIndex++;
    }

    return @{
        @"samples": [records copy],
        @"boxes": [primaryBoxes copy],
        @"actualTimes": [actualTimes copy]
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - AVAssetReader CVPixelBuffer ROI Cost Benchmark (Decodes Sequentially)
// ═══════════════════════════════════════════════════════════════════════════════

/// Runs the reader benchmark for one variant configuration.
- (NSDictionary *)_benchmarkReaderURL:(NSURL *)videoURL
                         maxDimension:(NSInteger)maxDimension
                        sampleRateFps:(double)sampleRateFps
                          maxDuration:(double)maxDuration
                    forcedOrientation:(nullable NSNumber *)forcedOrientation {

    NSString *orientationSuffix = forcedOrientation ? [NSString stringWithFormat:@"-orient%@", forcedOrientation] : @"";
    NSString *variantName = maxDimension == 0 ? @"reader-full-res" : [NSString stringWithFormat:@"reader-max%ld%@", (long)maxDimension, orientationSuffix];

    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    CMTime assetDuration = asset.duration;
    double assetDurationSec = CMTimeGetSeconds(assetDuration);

    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) {
        return @{ @"samples": @[], @"boxes": @{}, @"rawBoxes": @{} };
    }

    CGSize naturalSize = videoTrack.naturalSize;
    CGAffineTransform preferredTransform = videoTrack.preferredTransform;
    CGImagePropertyOrientation visionOrientation = forcedOrientation ? [forcedOrientation unsignedIntValue] : _imageOrientationFromTransform(preferredTransform);

    CGFloat targetWidth = naturalSize.width;
    CGFloat targetHeight = naturalSize.height;
    if (maxDimension > 0 && naturalSize.width > 0 && naturalSize.height > 0) {
        if (naturalSize.width > naturalSize.height) {
            targetWidth = maxDimension;
            targetHeight = round((naturalSize.height / naturalSize.width) * maxDimension);
        } else {
            targetHeight = maxDimension;
            targetWidth = round((naturalSize.width / naturalSize.height) * maxDimension);
        }
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
    if (!reader || readerError) {
        return @{ @"samples": @[], @"boxes": @{}, @"rawBoxes": @{} };
    }

    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    }];
    if (maxDimension > 0) {
        settings[(id)kCVPixelBufferWidthKey]  = @((int)targetWidth);
        settings[(id)kCVPixelBufferHeightKey] = @((int)targetHeight);
    }

    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        return @{ @"samples": @[], @"boxes": @{}, @"rawBoxes": @{} };
    }
    [reader addOutput:output];
    [reader startReading];

    NSMutableArray<NSData *> *records = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSValue *> *primaryBoxes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSValue *> *rawBoxes = [NSMutableDictionary dictionary];

    double nextTargetSec = 0.0;
    double interval = 1.0 / sampleRateFps;
    double scanDuration = MIN(assetDurationSec, maxDuration);

    BOOL readerScalingHonored = NO;

    while (YES) {
        NSTimeInterval readStart = CACurrentMediaTime();
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        NSTimeInterval readEnd = CACurrentMediaTime();

        if (!sampleBuffer) {
            break;
        }

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        double ptsSec = CMTimeGetSeconds(pts);

        if (ptsSec > scanDuration) {
            CFRelease(sampleBuffer);
            break;
        }

        if (ptsSec >= nextTargetSec) {
            VGFBSample sample = {};
            sample.timestampMs = ptsSec * 1000.0;
            sample.failed = NO;
            sample.frameExtractionMs = (readEnd - readStart) * 1000.0;

            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                CVPixelBufferRetain(pixelBuffer);
            }
            CFRelease(sampleBuffer);

            if (!pixelBuffer) {
                sample.failed = YES;
                sample.totalPerSampleMs = sample.frameExtractionMs;
                [records addObject:[NSData dataWithBytes:&sample length:sizeof(sample)]];
                nextTargetSec += interval;
                continue;
            }

            size_t w = CVPixelBufferGetWidth(pixelBuffer);
            size_t h = CVPixelBufferGetHeight(pixelBuffer);
            sample.frameSize = CGSizeMake(w, h);

            if (maxDimension > 0 && w <= maxDimension && h <= maxDimension) {
                readerScalingHonored = YES;
            } else if (maxDimension == 0) {
                readerScalingHonored = YES;
            }

            VNDetectFaceRectanglesRequest *faceRequest = [[VNDetectFaceRectanglesRequest alloc] init];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
                initWithCVPixelBuffer:pixelBuffer
                          orientation:visionOrientation
                              options:@{}];

            NSTimeInterval visionStart = CACurrentMediaTime();
            NSError *visionError = nil;
            BOOL ok = [handler performRequests:@[faceRequest] error:&visionError];
            NSTimeInterval visionEnd = CACurrentMediaTime();
            sample.visionFaceRectMs = (visionEnd - visionStart) * 1000.0;

            CVPixelBufferRelease(pixelBuffer);

            if (!ok || visionError) {
                sample.failed = YES;
                sample.totalPerSampleMs = sample.frameExtractionMs + sample.visionFaceRectMs;
                [records addObject:[NSData dataWithBytes:&sample length:sizeof(sample)]];
                nextTargetSec += interval;
                continue;
            }

            NSArray<VNFaceObservation *> *observations = faceRequest.results;
            sample.faceCount = (NSInteger)observations.count;
            sample.totalPerSampleMs = sample.frameExtractionMs + sample.visionFaceRectMs;

            if (sample.faceCount > 0) {
                VNFaceObservation *bestObs = observations[0];
                for (VNFaceObservation *obs in observations) {
                    if (obs.confidence > bestObs.confidence) {
                        bestObs = obs;
                    }
                }
                CGRect visionBox = bestObs.boundingBox;
                rawBoxes[@(sample.timestampMs)] = [NSValue valueWithCGRect:visionBox];
                CGRect normTopLeft = _visionBoxToTopLeft(visionBox);
                primaryBoxes[@(sample.timestampMs)] = [NSValue valueWithCGRect:normTopLeft];
            }

            [records addObject:[NSData dataWithBytes:&sample length:sizeof(sample)]];
            nextTargetSec += interval;
        } else {
            CFRelease(sampleBuffer);
        }
    }

    [reader cancelReading];

    return @{
        @"samples": [records copy],
        @"boxes": [primaryBoxes copy],
        @"rawBoxes": [rawBoxes copy],
        @"scalingHonored": @(readerScalingHonored)
    };
}

/// Print summary and evaluate stability vs full-res baseline.
- (BOOL)_evaluateSummaryForVariant:(NSString *)variantName
                     sampleRateFps:(double)sampleRateFps
                           samples:(NSArray<NSData *> *)samples
                       variantBoxes:(NSDictionary<NSNumber *, NSValue *> *)variantBoxes
                      baselineBoxes:(NSDictionary<NSNumber *, NSValue *> *)baselineBoxes
               readerScalingHonored:(BOOL)readerScalingHonored {

    NSInteger failedFrames   = 0;
    NSInteger noFaceFrames   = 0;
    NSInteger faceDetected   = 0;
    NSInteger warmCount      = 0;
    double coldVisionMs      = -1.0;

    NSMutableArray<NSNumber *> *warmVision  = [NSMutableArray array];
    NSMutableArray<NSNumber *> *extractVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals   = [NSMutableArray array];

    CGSize actualFrameSize = CGSizeZero;

    for (NSInteger i = 0; i < (NSInteger)samples.count; i++) {
        VGFBSample s;
        [samples[(NSUInteger)i] getBytes:&s length:sizeof(s)];

        if (s.failed) { failedFrames++; continue; }
        if (s.faceCount == 0) noFaceFrames++; else faceDetected++;

        actualFrameSize = s.frameSize;
        [extractVals addObject:@(s.frameExtractionMs)];
        [totalVals   addObject:@(s.totalPerSampleMs)];

        if (i == 0) {
            coldVisionMs = s.visionFaceRectMs;
        } else {
            [warmVision addObject:@(s.visionFaceRectMs)];
            warmCount++;
        }
    }

    double *warmArr = (double *)malloc(sizeof(double) * (size_t)warmCount);
    for (NSInteger i = 0; i < warmCount; i++) warmArr[i] = warmVision[(NSUInteger)i].doubleValue;
    qsort(warmArr, (size_t)warmCount, sizeof(double), _cmpDouble);

    double *extArr   = (double *)malloc(sizeof(double) * (size_t)extractVals.count);
    double *totalArr = (double *)malloc(sizeof(double) * (size_t)totalVals.count);
    for (NSUInteger i = 0; i < extractVals.count; i++) extArr[i]   = extractVals[i].doubleValue;
    for (NSUInteger i = 0; i < totalVals.count;   i++) totalArr[i] = totalVals[i].doubleValue;
    qsort(extArr,   extractVals.count, sizeof(double), _cmpDouble);
    qsort(totalArr, totalVals.count,   sizeof(double), _cmpDouble);

    double warmAvg  = 0.0;
    for (NSInteger i = 0; i < warmCount; i++) warmAvg += warmArr[i];
    if (warmCount > 0) warmAvg /= (double)warmCount;

    double extAvg = 0.0;
    for (NSUInteger i = 0; i < extractVals.count; i++) extAvg += extArr[i];
    if (extractVals.count > 0) extAvg /= (double)extractVals.count;

    double totalAvg = 0.0;
    for (NSUInteger i = 0; i < totalVals.count; i++) totalAvg += totalArr[i];
    if (totalVals.count > 0) totalAvg /= (double)totalVals.count;

    double warmP50  = _percentile(warmArr, warmCount, 0.50);
    double warmP90  = _percentile(warmArr, warmCount, 0.90);
    double warmP95  = _percentile(warmArr, warmCount, 0.95);
    double warmMax  = warmCount > 0 ? warmArr[warmCount - 1] : 0.0;
    double extP95   = _percentile(extArr,   (NSInteger)extractVals.count, 0.95);
    double totalP95 = _percentile(totalArr, (NSInteger)totalVals.count,   0.95);

    double estAddedAvg = totalAvg * 180.0 * sampleRateFps / 1000.0;
    double estAddedP95 = totalP95 * 180.0 * sampleRateFps / 1000.0;

    NSString *logPrefix = [variantName hasPrefix:@"reader-"] ? @"VGFaceBoxReaderBenchmark" : @"VGFaceBoxBenchmark";

    NSLog(@"[%@] ── SUMMARY inputVariant=%@ sampleRateFps=%.1f ──────────────", logPrefix, variantName, sampleRateFps);
    NSLog(@"[%@]   sampleCount:             %lu", logPrefix, (unsigned long)samples.count);
    NSLog(@"[%@]   faceDetectedFrames:      %ld", logPrefix, (long)faceDetected);
    NSLog(@"[%@]   noFaceFrames:            %ld", logPrefix, (long)noFaceFrames);
    NSLog(@"[%@]   failedFrames:            %ld", logPrefix, (long)failedFrames);
    NSLog(@"[%@]   actualPixelBufferWidth:  %.0f", logPrefix, actualFrameSize.width);
    NSLog(@"[%@]   actualPixelBufferHeight: %.0f", logPrefix, actualFrameSize.height);
    NSLog(@"[%@]   readerScalingHonored:    %@", logPrefix, readerScalingHonored ? @"YES" : @"NO");
    NSLog(@"[%@]   coldVisionMs:            %.2f", logPrefix, coldVisionMs >= 0 ? coldVisionMs : -1.0);
    NSLog(@"[%@]   warmVisionAvgMs:         %.2f", logPrefix, warmAvg);
    NSLog(@"[%@]   warmVisionP50Ms:         %.2f", logPrefix, warmP50);
    NSLog(@"[%@]   warmVisionP90Ms:         %.2f", logPrefix, warmP90);
    NSLog(@"[%@]   warmVisionP95Ms:         %.2f", logPrefix, warmP95);
    NSLog(@"[%@]   warmVisionMaxMs:         %.2f", logPrefix, warmMax);
    NSLog(@"[%@]   frameReadOrTapAvgMs:     %.2f", logPrefix, extAvg);
    NSLog(@"[%@]   frameReadOrTapP95Ms:     %.2f", logPrefix, extP95);
    NSLog(@"[%@]   totalPerSampleAvgMs:     %.2f", logPrefix, totalAvg);
    NSLog(@"[%@]   totalPerSampleP95Ms:     %.2f", logPrefix, totalP95);
    NSLog(@"[%@]   estimatedAddedComputeFor180sAvg: %.2fs", logPrefix, estAddedAvg);
    NSLog(@"[%@]   estimatedAddedComputeFor180sP95: %.2fs  <── ROI OVERHEAD ESTIMATE", logPrefix, estAddedP95);

    BOOL isBaseline = [variantName isEqualToString:@"full-res"];
    BOOL stabilityAcceptable = YES;

    if (!isBaseline) {
        NSInteger matched = 0;
        NSInteger unmatched = 0;

        NSMutableArray<NSNumber *> *centerDeltas = [NSMutableArray array];
        NSMutableArray<NSNumber *> *sizeDeltas   = [NSMutableArray array];
        NSMutableArray<NSNumber *> *ious         = [NSMutableArray array];

        NSMutableSet<NSNumber *> *allTimestamps = [NSMutableSet setWithArray:baselineBoxes.allKeys];
        [allTimestamps addObjectsFromArray:variantBoxes.allKeys];

        for (NSNumber *ts in allTimestamps) {
            NSValue *baseVal = baselineBoxes[ts];
            NSValue *varVal  = variantBoxes[ts];

            if (baseVal && varVal) {
                CGRect r1 = [baseVal CGRectValue];
                CGRect r2 = [varVal CGRectValue];

                matched++;

                CGPoint c1 = CGPointMake(CGRectGetMidX(r1), CGRectGetMidY(r1));
                CGPoint c2 = CGPointMake(CGRectGetMidX(r2), CGRectGetMidY(r2));
                double dx = c1.x - c2.x;
                double dy = c1.y - c2.y;
                double cDelta = sqrt(dx*dx + dy*dy);
                [centerDeltas addObject:@(cDelta)];

                double dw = r1.size.width - r2.size.width;
                double dh = r1.size.height - r2.size.height;
                double sDelta = sqrt(dw*dw + dh*dh);
                [sizeDeltas addObject:@(sDelta)];

                double iou = _rectIoU(r1, r2);
                [ious addObject:@(iou)];
            } else {
                unmatched++;
            }
        }

        NSInteger cCount = (NSInteger)centerDeltas.count;
        double *cArr = (double *)malloc(sizeof(double) * (size_t)cCount);
        double *sArr = (double *)malloc(sizeof(double) * (size_t)cCount);
        double *iArr = (double *)malloc(sizeof(double) * (size_t)cCount);

        for (NSInteger i = 0; i < cCount; i++) {
            cArr[i] = centerDeltas[(NSUInteger)i].doubleValue;
            sArr[i] = sizeDeltas[(NSUInteger)i].doubleValue;
            iArr[i] = ious[(NSUInteger)i].doubleValue;
        }

        qsort(cArr, (size_t)cCount, sizeof(double), _cmpDouble);
        qsort(sArr, (size_t)cCount, sizeof(double), _cmpDouble);
        qsort(iArr, (size_t)cCount, sizeof(double), _cmpDouble);

        double cAvg = 0.0, sAvg = 0.0, iAvg = 0.0;
        for (NSInteger i = 0; i < cCount; i++) {
            cAvg += cArr[i];
            sAvg += sArr[i];
            iAvg += iArr[i];
        }
        if (cCount > 0) {
            cAvg /= (double)cCount;
            sAvg /= (double)cCount;
            iAvg /= (double)cCount;
        }

        double cP95 = _percentile(cArr, cCount, 0.95);
        double sP95 = _percentile(sArr, cCount, 0.95);
        double iMin = cCount > 0 ? iArr[0] : 0.0;

        NSLog(@"[%@] STABILITY vs full-res inputVariant=%@ sampleRateFps=%.1f", logPrefix, variantName, sampleRateFps);
        NSLog(@"[%@]   matchedFrames:           %ld", logPrefix, (long)matched);
        NSLog(@"[%@]   unmatchedFrames:         %ld", logPrefix, (long)unmatched);
        NSLog(@"[%@]   boxCenterDeltaAvg:       %.4f", logPrefix, cAvg);
        NSLog(@"[%@]   boxCenterDeltaP95:       %.4f", logPrefix, cP95);
        NSLog(@"[%@]   boxSizeDeltaAvg:         %.4f", logPrefix, sAvg);
        NSLog(@"[%@]   boxSizeDeltaP95:         %.4f", logPrefix, sP95);
        NSLog(@"[%@]   iouAvg:                  %.4f  (threshold >= 0.80)", logPrefix, iAvg);
        NSLog(@"[%@]   iouMin:                  %.4f  (threshold >= 0.65)", logPrefix, iMin);

        if (cCount == 0) {
            stabilityAcceptable = NO;
        } else {
            if (iAvg < 0.80) stabilityAcceptable = NO;
            if (iMin < 0.65) stabilityAcceptable = NO;
            if (cP95 > 0.08) stabilityAcceptable = NO;
            double mismatchRate = (double)unmatched / (double)(matched + unmatched);
            if (mismatchRate > 0.20) stabilityAcceptable = NO;
        }

        free(cArr);
        free(sArr);
        free(iArr);
    }

    NSString *verdict = @"EXPORT_FRAME_TAP_ROI_COST_BLOCKED";
    if (failedFrames == 0 && stabilityAcceptable) {
        if (estAddedP95 <= 3.0) {
            verdict = @"EXPORT_FRAME_TAP_ROI_COST_PROVEN_VIABLE";
        } else if (estAddedP95 <= 6.0) {
            verdict = @"EXPORT_FRAME_TAP_ROI_COST_WARNING_BUT_POSSIBLE";
        }
    }

    NSLog(@"[%@] RESULT inputVariant=%@ sampleRateFps=%.1f → %@", logPrefix, variantName, sampleRateFps, verdict);

    free(warmArr);
    free(extArr);
    free(totalArr);

    return [verdict isEqualToString:@"EXPORT_FRAME_TAP_ROI_COST_PROVEN_VIABLE"] || [verdict isEqualToString:@"EXPORT_FRAME_TAP_ROI_COST_WARNING_BUT_POSSIBLE"];
}

// ─── Test methods ─────────────────────────────────────────────────────────────

- (void)testFaceBoxDownscaledBenchmark_1fps {
    NSString *source = nil;
    NSURL *videoURL = [self _resolveVideoURLWithSource:&source];
    if (!videoURL) {
        XCTSkip(@"No video available for benchmark.");
    }

    NSDictionary *baselineRes = [self _benchmarkGeneratorURL:videoURL maxDimension:0 sampleRateFps:1.0 maxDuration:15.0];
    NSArray<NSData *> *baselineSamples = baselineRes[@"samples"];
    NSDictionary<NSNumber *, NSValue *> *baselineBoxes = baselineRes[@"boxes"];

    XCTAssertGreaterThan(baselineSamples.count, 0, @"Baseline produced no samples.");

    [self _evaluateSummaryForVariant:@"full-res"
                       sampleRateFps:1.0
                             samples:baselineSamples
                        variantBoxes:baselineBoxes
                       baselineBoxes:baselineBoxes
                readerScalingHonored:YES];

    NSArray<NSNumber *> *variants = @[@720, @540, @384, @256];
    for (NSNumber *varSize in variants) {
        NSInteger dim = varSize.integerValue;
        NSDictionary *res = [self _benchmarkGeneratorURL:videoURL maxDimension:dim sampleRateFps:1.0 maxDuration:15.0];
        NSArray<NSData *> *samples = res[@"samples"];
        NSDictionary<NSNumber *, NSValue *> *variantBoxes = res[@"boxes"];

        [self _evaluateSummaryForVariant:[NSString stringWithFormat:@"max%ld", (long)dim]
                           sampleRateFps:1.0
                                 samples:samples
                            variantBoxes:variantBoxes
                           baselineBoxes:baselineBoxes
                    readerScalingHonored:YES];
    }
}

- (void)testFaceBoxDownscaledBenchmark_2fps {
    NSString *source = nil;
    NSURL *videoURL = [self _resolveVideoURLWithSource:&source];
    if (!videoURL) {
        XCTSkip(@"No video available for benchmark.");
    }

    NSDictionary *baselineRes = [self _benchmarkGeneratorURL:videoURL maxDimension:0 sampleRateFps:2.0 maxDuration:15.0];
    NSArray<NSData *> *baselineSamples = baselineRes[@"samples"];
    NSDictionary<NSNumber *, NSValue *> *baselineBoxes = baselineRes[@"boxes"];

    XCTAssertGreaterThan(baselineSamples.count, 0, @"Baseline produced no samples.");

    [self _evaluateSummaryForVariant:@"full-res"
                       sampleRateFps:2.0
                             samples:baselineSamples
                        variantBoxes:baselineBoxes
                       baselineBoxes:baselineBoxes
                readerScalingHonored:YES];

    NSArray<NSNumber *> *variants = @[@720, @540, @384, @256];
    for (NSNumber *varSize in variants) {
        NSInteger dim = varSize.integerValue;
        NSDictionary *res = [self _benchmarkGeneratorURL:videoURL maxDimension:dim sampleRateFps:2.0 maxDuration:15.0];
        NSArray<NSData *> *samples = res[@"samples"];
        NSDictionary<NSNumber *, NSValue *> *variantBoxes = res[@"boxes"];

        [self _evaluateSummaryForVariant:[NSString stringWithFormat:@"max%ld", (long)dim]
                           sampleRateFps:2.0
                                 samples:samples
                            variantBoxes:variantBoxes
                           baselineBoxes:baselineBoxes
                    readerScalingHonored:YES];
    }
}

- (void)testFaceBoxReaderBenchmark_1fps {
    NSString *source = nil;
    NSURL *videoURL = [self _resolveVideoURLWithSource:&source];
    if (!videoURL) {
        XCTSkip(@"No video available for benchmark.");
    }

    NSDictionary *baselineRes = [self _benchmarkGeneratorURL:videoURL maxDimension:0 sampleRateFps:1.0 maxDuration:15.0];
    NSDictionary<NSNumber *, NSValue *> *baselineBoxes = baselineRes[@"boxes"];

    NSArray<NSNumber *> *variants = @[@0, @540, @384, @256];
    for (NSNumber *varSize in variants) {
        NSInteger dim = varSize.integerValue;
        NSDictionary *res = [self _benchmarkReaderURL:videoURL maxDimension:dim sampleRateFps:1.0 maxDuration:15.0 forcedOrientation:nil];
        NSArray<NSData *> *samples = res[@"samples"];
        NSDictionary<NSNumber *, NSValue *> *variantBoxes = res[@"boxes"];
        BOOL scalingHonored = [res[@"scalingHonored"] boolValue];

        NSString *variantName = dim == 0 ? @"reader-full-res" : [NSString stringWithFormat:@"reader-max%ld", (long)dim];
        [self _evaluateSummaryForVariant:variantName
                           sampleRateFps:1.0
                                 samples:samples
                            variantBoxes:variantBoxes
                           baselineBoxes:baselineBoxes
                    readerScalingHonored:scalingHonored];
    }
}

- (void)testFaceBoxReaderBenchmark_2fps {
    NSString *source = nil;
    NSURL *videoURL = [self _resolveVideoURLWithSource:&source];
    if (!videoURL) {
        XCTSkip(@"No video available for benchmark.");
    }

    NSDictionary *baselineRes = [self _benchmarkGeneratorURL:videoURL maxDimension:0 sampleRateFps:2.0 maxDuration:15.0];
    NSDictionary<NSNumber *, NSValue *> *baselineBoxes = baselineRes[@"boxes"];

    NSArray<NSNumber *> *variants = @[@0, @540, @384, @256];
    for (NSNumber *varSize in variants) {
        NSInteger dim = varSize.integerValue;
        NSDictionary *res = [self _benchmarkReaderURL:videoURL maxDimension:dim sampleRateFps:2.0 maxDuration:15.0 forcedOrientation:nil];
        NSArray<NSData *> *samples = res[@"samples"];
        NSDictionary<NSNumber *, NSValue *> *variantBoxes = res[@"boxes"];
        BOOL scalingHonored = [res[@"scalingHonored"] boolValue];

        NSString *variantName = dim == 0 ? @"reader-full-res" : [NSString stringWithFormat:@"reader-max%ld", (long)dim];
        [self _evaluateSummaryForVariant:variantName
                           sampleRateFps:2.0
                                 samples:samples
                            variantBoxes:variantBoxes
                           baselineBoxes:baselineBoxes
                    readerScalingHonored:scalingHonored];
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Diagnostic Side-by-Side Orientation and Coordinate Transforms Test
// ═══════════════════════════════════════════════════════════════════════════════

- (void)testFaceBoxReaderDiagnostic {
    NSString *source = nil;
    NSURL *videoURL = [self _resolveVideoURLWithSource:&source];
    if (!videoURL) {
        XCTSkip(@"No video available for diagnostic.");
    }

    NSLog(@"[VGFaceBoxReaderDiagnostic] Starting Side-by-Side Orientation & Coordinate Transforms Diagnostic...");

    // 1. Run Generator baseline with requestedTimeTolerance = Zero
    NSDictionary *genBaseline = [self _benchmarkGeneratorURL:videoURL maxDimension:0 sampleRateFps:2.0 maxDuration:15.0];
    NSDictionary<NSNumber *, NSValue *> *baselineBoxes = genBaseline[@"boxes"];
    NSDictionary<NSNumber *, NSValue *> *genActualTimes = genBaseline[@"actualTimes"];

    XCTAssertGreaterThan(baselineBoxes.count, 0, @"Baseline boxes dictionary is empty!");

    // 2. Run Reader max384 with Orientation 6 and Orientation 8
    NSDictionary *readerOrient6Res = [self _benchmarkReaderURL:videoURL maxDimension:384 sampleRateFps:2.0 maxDuration:15.0 forcedOrientation:@6];
    NSDictionary<NSNumber *, NSValue *> *readerOrient6Boxes = readerOrient6Res[@"boxes"];
    NSDictionary<NSNumber *, NSValue *> *readerOrient6RawBoxes = readerOrient6Res[@"rawBoxes"];

    NSDictionary *readerOrient8Res = [self _benchmarkReaderURL:videoURL maxDimension:384 sampleRateFps:2.0 maxDuration:15.0 forcedOrientation:@8];
    NSDictionary<NSNumber *, NSValue *> *readerOrient8Boxes = readerOrient8Res[@"boxes"];
    NSDictionary<NSNumber *, NSValue *> *readerOrient8RawBoxes = readerOrient8Res[@"rawBoxes"];

    // 3. Print Side-by-Side Table for the first 8 samples
    NSArray<NSNumber *> *sortedKeys = [baselineBoxes.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSInteger printLimit = MIN((NSInteger)sortedKeys.count, 8);

    NSLog(@"[VGFaceBoxReaderDiagnostic] ═══════════════ BEGIN SAMPLE COMPARISON TABLE ═══════════════");
    for (NSInteger i = 0; i < printLimit; i++) {
        NSNumber *tsKey = sortedKeys[(NSUInteger)i];
        double targetSec = tsKey.doubleValue / 1000.0;
        NSValue *actualTimeVal = genActualTimes[tsKey];
        double actualSec = actualTimeVal ? CMTimeGetSeconds(actualTimeVal.CMTimeValue) : -1.0;

        CGRect genBox = [baselineBoxes[tsKey] CGRectValue];

        NSValue *o6BoxVal = readerOrient6Boxes[tsKey];
        NSValue *o6RawVal = readerOrient6RawBoxes[tsKey];
        CGRect o6Box = o6BoxVal ? [o6BoxVal CGRectValue] : CGRectZero;
        CGRect o6Raw = o6RawVal ? [o6RawVal CGRectValue] : CGRectZero;
        double o6IoU = o6BoxVal ? _rectIoU(genBox, o6Box) : 0.0;
        double o6CD = 0.0;
        if (o6BoxVal) {
            CGPoint c1 = CGPointMake(CGRectGetMidX(genBox), CGRectGetMidY(genBox));
            CGPoint c2 = CGPointMake(CGRectGetMidX(o6Box), CGRectGetMidY(o6Box));
            o6CD = sqrt((c1.x - c2.x)*(c1.x - c2.x) + (c1.y - c2.y)*(c1.y - c2.y));
        }

        NSValue *o8BoxVal = readerOrient8Boxes[tsKey];
        NSValue *o8RawVal = readerOrient8RawBoxes[tsKey];
        CGRect o8Box = o8BoxVal ? [o8BoxVal CGRectValue] : CGRectZero;
        CGRect o8Raw = o8RawVal ? [o8RawVal CGRectValue] : CGRectZero;
        double o8IoU = o8BoxVal ? _rectIoU(genBox, o8Box) : 0.0;
        double o8CD = 0.0;
        if (o8BoxVal) {
            CGPoint c1 = CGPointMake(CGRectGetMidX(genBox), CGRectGetMidY(genBox));
            CGPoint c2 = CGPointMake(CGRectGetMidX(o8Box), CGRectGetMidY(o8Box));
            o8CD = sqrt((c1.x - c2.x)*(c1.x - c2.x) + (c1.y - c2.y)*(c1.y - c2.y));
        }

        NSLog(@"[VGFaceBoxReaderDiagnostic] sample=%ld", (long)i);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   requestedTime=%.3f generatorActualTime=%.3f readerPTS=%.3f", targetSec, actualSec, targetSec);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   generatorBoxTL={x:%.3f, y:%.3f, w:%.3f, h:%.3f}", genBox.origin.x, genBox.origin.y, genBox.size.width, genBox.size.height);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   readerOrient6RawVisionBox={x:%.3f, y:%.3f, w:%.3f, h:%.3f}", o6Raw.origin.x, o6Raw.origin.y, o6Raw.size.width, o6Raw.size.height);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   readerOrient6TopLeftBox={x:%.3f, y:%.3f, w:%.3f, h:%.3f}", o6Box.origin.x, o6Box.origin.y, o6Box.size.width, o6Box.size.height);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   readerOrient6IoU=%.4f readerOrient6CenterDelta=%.4f", o6IoU, o6CD);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   readerOrient8RawVisionBox={x:%.3f, y:%.3f, w:%.3f, h:%.3f}", o8Raw.origin.x, o8Raw.origin.y, o8Raw.size.width, o8Raw.size.height);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   readerOrient8TopLeftBox={x:%.3f, y:%.3f, w:%.3f, h:%.3f}", o8Box.origin.x, o8Box.origin.y, o8Box.size.width, o8Box.size.height);
        NSLog(@"[VGFaceBoxReaderDiagnostic]   readerOrient8IoU=%.4f readerOrient8CenterDelta=%.4f", o8IoU, o8CD);
        NSLog(@"[VGFaceBoxReaderDiagnostic] ────────────────────────────────────────────────────────");
    }
    NSLog(@"[VGFaceBoxReaderDiagnostic] ════════════════ END SAMPLE COMPARISON TABLE ════════════════");

    // 4. Evaluate each coordinate transform candidate for both orientations
    NSArray<NSString *> *candidates = @[
        @"identityTopLeft",
        @"flipX",
        @"flipY",
        @"flipXY",
        @"rotate90CWNormalized",
        @"rotate90CCWNormalized"
    ];

    double bestIoU = -1.0;
    NSString *bestOrientation = @"";
    NSString *bestCandidate = @"";

    NSArray<NSDictionary *> *configs = @[
        @{@"orientation": @6, @"boxes": readerOrient6Boxes},
        @{@"orientation": @8, @"boxes": readerOrient8Boxes}
    ];

    for (NSDictionary *config in configs) {
        NSInteger orient = [config[@"orientation"] integerValue];
        NSDictionary<NSNumber *, NSValue *> *orientBoxes = config[@"boxes"];

        for (NSString *candidate in candidates) {
            NSInteger matched = 0;
            NSInteger unmatched = 0;
            double totalIoU = 0.0;
            double minIoU = 1.0;

            NSMutableArray<NSNumber *> *centerDeltas = [NSMutableArray array];

            for (NSNumber *tsKey in sortedKeys) {
                NSValue *baseVal = baselineBoxes[tsKey];
                NSValue *varVal  = orientBoxes[tsKey];

                if (baseVal && varVal) {
                    CGRect rGen = [baseVal CGRectValue];
                    CGRect rVar = [varVal CGRectValue];

                    // Apply candidates to top-left coordinate space
                    CGRect rTransformed = _applyTransform(candidate, rVar);

                    matched++;
                    double iou = _rectIoU(rGen, rTransformed);
                    totalIoU += iou;
                    if (iou < minIoU) minIoU = iou;

                    CGPoint c1 = CGPointMake(CGRectGetMidX(rGen), CGRectGetMidY(rGen));
                    CGPoint c2 = CGPointMake(CGRectGetMidX(rTransformed), CGRectGetMidY(rTransformed));
                    double cDelta = sqrt((c1.x - c2.x)*(c1.x - c2.x) + (c1.y - c2.y)*(c1.y - c2.y));
                    [centerDeltas addObject:@(cDelta)];
                } else {
                    unmatched++;
                }
            }

            double iouAvg = matched > 0 ? (totalIoU / (double)matched) : 0.0;
            if (matched == 0) minIoU = 0.0;

            double cAvg = 0.0;
            double cP95 = 0.0;
            if (centerDeltas.count > 0) {
                double *cArr = (double *)malloc(sizeof(double) * centerDeltas.count);
                for (NSUInteger k = 0; k < centerDeltas.count; k++) cArr[k] = centerDeltas[k].doubleValue;
                qsort(cArr, centerDeltas.count, sizeof(double), _cmpDouble);
                for (NSUInteger k = 0; k < centerDeltas.count; k++) cAvg += cArr[k];
                cAvg /= (double)centerDeltas.count;
                cP95 = _percentile(cArr, (NSInteger)centerDeltas.count, 0.95);
                free(cArr);
            }

            NSLog(@"[VGFaceBoxReaderDiagnostic] EVALUATING orientation=%ld candidate=%@ matched=%ld unmatched=%ld iouAvg=%.4f iouMin=%.4f boxCenterDeltaAvg=%.4f boxCenterDeltaP95=%.4f",
                  (long)orient, candidate, (long)matched, (long)unmatched, iouAvg, minIoU, cAvg, cP95);

            if (iouAvg > bestIoU && matched > 0) {
                bestIoU = iouAvg;
                bestOrientation = [NSString stringWithFormat:@"%ld", (long)orient];
                bestCandidate = candidate;
            }
        }
    }

    NSLog(@"[VGFaceBoxReaderDiagnostic] BEST orientation=%@ candidate=%@ iouAvg=%.4f", bestOrientation, bestCandidate, bestIoU);
}

@end
