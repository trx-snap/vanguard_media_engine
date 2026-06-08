// VGWaveformExtractor.h
// vanguard_media_engine — Phase 8.15C
//
// Offline audio waveform extraction: AVAssetReader → RMS Float32 samples.
//
// Design:
//   - Stateless single-shot utility. Create, call extract, discard.
//   - Pure offline: no AVAudioEngine, no coreaudiod XPC, no real-time graph.
//   - Reader settings: kAudioFormatLinearPCM, Int16, interleaved, mono.
//     alwaysCopiesSampleData = NO.
//   - Buffer iteration via CMBlockBufferGetDataPointer — no AudioBufferList.
//   - Each CMSampleBufferRef is CFRelease'd immediately after processing.
//   - @autoreleasepool wraps each loop iteration.
//   - Output: Float32 RMS values normalized to [0.0, 1.0].
//   - Completion block fires on a private serial background queue.
//
// Forbidden imports:
//   VGAudioExportMuxer, VGExportScheduler, VGGraphDescriptor,
//   VGGraphValidator, VGGraphPlanner, VGGraphExecutionContext,
//   VGVideoEncoderSinkNode, VGImageEncoderSinkNode, VGExportGraphFactory,
//   VGFrameSink, VGFrameEnvelope, VGGraphSchedulerV2.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Error domain and codes ───────────────────────────────────────────────────

extern NSString * const VGWaveformExtractorErrorDomain;

typedef NS_ENUM(NSInteger, VGWaveformExtractorErrorCode) {
    VGWaveformExtractorErrorNoAudioTrack     = 1,
    VGWaveformExtractorErrorZeroDuration     = 2,
    VGWaveformExtractorErrorDurationExceeded = 3,
    VGWaveformExtractorErrorReaderSetup      = 4,
    VGWaveformExtractorErrorReaderFailed     = 5,
    VGWaveformExtractorErrorCancelled        = 6,
};

// ─── Result ───────────────────────────────────────────────────────────────────

/// Immutable waveform result returned on success.
@interface VGWaveformResult : NSObject

/// RMS Float32 samples normalised to [0.0, 1.0]. Length == pointCount.
@property (nonatomic, readonly) NSData *samplesData;

/// Total duration of the extracted audio in seconds.
@property (nonatomic, readonly) double durationSeconds;

/// Requested samples per second (may differ slightly from actual density
/// if the last window was partial).
@property (nonatomic, readonly) NSInteger samplesPerSecond;

/// Number of Float32 values in samplesData.
@property (nonatomic, readonly) NSInteger pointCount;

- (instancetype)initWithSamplesData:(NSData *)samplesData
                    durationSeconds:(double)durationSeconds
                   samplesPerSecond:(NSInteger)samplesPerSecond
                         pointCount:(NSInteger)pointCount;

@end

// ─── Extractor ────────────────────────────────────────────────────────────────

/// Single-shot offline waveform extractor.
///
/// Usage:
///   VGWaveformExtractor *ex = [[VGWaveformExtractor alloc] initWithAsset:asset];
///   [ex extractWithSamplesPerSecond:100
///               maxDurationSeconds:600
///                        completion:^(VGWaveformResult *r, NSError *e) { ... }];
///
/// The completion block fires exactly once on a private background queue.
/// The extractor object must be retained until completion fires.
@interface VGWaveformExtractor : NSObject

/// Designated initialiser. [asset] must be an AVURLAsset or AVComposition.
- (instancetype)initWithAsset:(AVAsset *)asset NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Begins waveform extraction asynchronously.
///
/// @param samplesPerSecond  RMS points per timeline second (1–1000). Default 100.
/// @param maxDurationSeconds  Maximum audio duration to process (> 0). Default 600.
/// @param completion  Called once on a private background queue with result or error.
- (void)extractWithSamplesPerSecond:(NSInteger)samplesPerSecond
                 maxDurationSeconds:(double)maxDurationSeconds
                         completion:(void (^)(VGWaveformResult * _Nullable result,
                                              NSError * _Nullable error))completion;

/// Requests cancellation. Idempotent. The completion block will be called
/// with VGWaveformExtractorErrorCancelled if already in progress.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
