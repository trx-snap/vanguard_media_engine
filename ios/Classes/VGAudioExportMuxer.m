// VGAudioExportMuxer.m
// vanguard_media_engine — Phase 8.14A Audio Sidecar Export Muxer MVP
//
// Post-pass sidecar audio muxer.
//
// Pipeline:
//   videoTempPath (H.264 MP4, video-only)
//   + sidecar audio track (any AVFoundation-readable audio file)
//   → AVMutableComposition
//     → AVAssetExportSession (AVAssetExportPresetPassthrough, no re-encode)
//       → finalOutputPath (.mp4)
//   → delete videoTempPath on success
//
// Key decisions (Opus approval 2026-06-08):
//   - AVAssetExportPresetPassthrough: copies already-encoded H.264 + AAC bits
//     directly into the container. Near-instant for typical short-form video.
//   - timescale 600: LCM of 24/25/30/60 fps denominators. Prevents sub-second
//     A/V drift from integer-timescale truncation.
//   - Audio duration clamped to video duration: prevents composition extending
//     beyond the video track, which would produce a longer-than-expected output.
//   - timeRemapAudioPolicy "mute": skip audio track entirely (no audio track).
//   - Output file deleted before AVAssetExportSession (cannot overwrite).
//   - Temp video deleted on success; both temp and output deleted on failure.
//
// Forbidden:
//   VGVideoEncoderSinkNode, VGVideoExportSession, VGAudioOnlyExporter,
//   VGExportScheduler, VGGraphDescriptor, VGGraphValidator, VGGraphPlanner,
//   VanguardGraphRuntime, MultiCam classes, Connects app code.

#import "VGAudioExportMuxer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <stdatomic.h>
#import <os/log.h>

// ─── Constants ────────────────────────────────────────────────────────────────

/// LCM of 24 / 25 / 30 / 60 fps denominators. Used for all CMTime construction
/// so that sub-second audio start/duration positions are lossless.
static const int32_t kVGMuxTimescale = 600;

static os_log_t sMuxerLog;

__attribute__((constructor))
static void _VGAudioExportMuxerLogInit(void) {
    sMuxerLog = os_log_create("com.vanguard.export.muxer", "VGAudioExportMuxer");
}

// ─── Implementation ───────────────────────────────────────────────────────────

@implementation VGAudioExportMuxer {
    NSString        *_videoTempPath;
    VGAudioSidecarPlan *_audioSidecar;
    NSString        *_finalOutputPath;

    // Single-fire gate (0 → 1 via atomic CAS).
    _Atomic(int32_t) _startedAtomic;
}

// ─── Designated initializer ───────────────────────────────────────────────────

- (instancetype)initWithVideoTempPath:(NSString *)videoTempPath
                         audioSidecar:(VGAudioSidecarPlan *)audioSidecar
                      finalOutputPath:(NSString *)finalOutputPath {
    NSParameterAssert(videoTempPath.length > 0);
    NSParameterAssert(audioSidecar != nil);
    NSParameterAssert(finalOutputPath.length > 0);

    self = [super init];
    if (!self) return nil;

    _videoTempPath   = [videoTempPath copy];
    _audioSidecar    = audioSidecar;
    _finalOutputPath = [finalOutputPath copy];
    atomic_init(&_startedAtomic, 0);

    os_log_debug(sMuxerLog,
                 "[8.14A] init videoTemp=%{public}@ out=%{public}@",
                 videoTempPath.lastPathComponent,
                 finalOutputPath.lastPathComponent);
    return self;
}

// ─── startMuxWithCompletion: ─────────────────────────────────────────────────

- (void)startMuxWithCompletion:(void (^)(BOOL, NSTimeInterval, NSError * _Nullable))completion {
    // Single-fire gate: CAS 0 → 1.
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_startedAtomic, &expected, 1)) {
        os_log_debug(sMuxerLog, "[8.14A] startMuxWithCompletion: already started, ignoring");
        return;
    }

    NSParameterAssert(completion != nil);

    // Capture strong refs for the async block.
    NSString *videoTempPath   = _videoTempPath;
    VGAudioSidecarPlan *sidecar  = _audioSidecar;
    NSString *finalOutputPath = _finalOutputPath;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self _runMuxFromVideoTempPath:videoTempPath
                          audioSidecar:sidecar
                       finalOutputPath:finalOutputPath
                            completion:completion];
    });
}

// ─── Private: mux implementation ─────────────────────────────────────────────

- (void)_runMuxFromVideoTempPath:(NSString *)videoTempPath
                    audioSidecar:(VGAudioSidecarPlan *)sidecar
                 finalOutputPath:(NSString *)finalOutputPath
                      completion:(void (^)(BOOL, NSTimeInterval, NSError * _Nullable))completion {

    NSFileManager *fm = [NSFileManager defaultManager];

    // ── 1. Validate: video temp file must exist ───────────────────────────────

    if (![fm fileExistsAtPath:videoTempPath]) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:1
                                      message:[NSString stringWithFormat:
                                               @"Video temp file not found: %@", videoTempPath]]];
        return;
    }

    // ── 2. Validate: sidecar has at least one track ───────────────────────────
    //    Phase 8.14A: use first track only.

    if (!sidecar || sidecar.tracks.count == 0) {
        // No audio track — copy the video file to final output and succeed.
        // This path should not occur via VGTimelineExportHelper (it only calls
        // the muxer when audioSidecar is non-nil and non-empty), but is kept
        // as a safe fallback.
        os_log(sMuxerLog, "[8.14A] no sidecar tracks — passthrough video copy");
        [self _copyVideoOnlyFrom:videoTempPath
                              to:finalOutputPath
                      completion:completion];
        return;
    }

    NSDictionary<NSString *, id> *trackDict = sidecar.tracks.firstObject;

    // ── 3. Check timeRemapAudioPolicy: "mute" → skip audio ───────────────────

    NSString *policy = trackDict[@"timeRemapAudioPolicy"];
    if ([policy isEqualToString:@"mute"]) {
        os_log(sMuxerLog, "[8.14A] timeRemapAudioPolicy=mute — passthrough video copy");
        [self _copyVideoOnlyFrom:videoTempPath
                              to:finalOutputPath
                      completion:completion];
        return;
    }

    // ── 4. Parse track fields ─────────────────────────────────────────────────

    NSString *audioURL = trackDict[@"url"];
    if (audioURL.length == 0) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:2 message:@"Sidecar track url is empty"]];
        return;
    }

    double startTime = [trackDict[@"startTime"] doubleValue];
    double duration  = [trackDict[@"duration"]  doubleValue];
    double volume    = [trackDict[@"volume"]    doubleValue];
    if (volume <= 0.0) volume = 1.0; // safe default

    if (duration <= 0.0) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:3
                                      message:[NSString stringWithFormat:
                                               @"Sidecar track duration is <= 0: %f", duration]]];
        return;
    }
    if (startTime < 0.0) startTime = 0.0;

    os_log(sMuxerLog,
           "[8.14A] track: url=%{public}@ startTime=%.3f duration=%.3f volume=%.2f",
           [audioURL lastPathComponent], startTime, duration, volume);

    // ── 5. Load video asset ───────────────────────────────────────────────────

    NSURL *videoAssetURL = [NSURL fileURLWithPath:videoTempPath];
    AVAsset *videoAsset  = [AVAsset assetWithURL:videoAssetURL];

    CMTime videoDuration = videoAsset.duration;
    if (!CMTIME_IS_VALID(videoDuration) || !CMTIME_IS_NUMERIC(videoDuration)) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:4 message:@"Video temp asset has invalid duration"]];
        return;
    }
    double videoDurationSecs = CMTimeGetSeconds(videoDuration);
    if (videoDurationSecs <= 0.0) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:5 message:@"Video temp asset duration is <= 0"]];
        return;
    }

    NSArray<AVAssetTrack *> *videoTracks = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:6 message:@"Video temp asset has no video track"]];
        return;
    }
    AVAssetTrack *videoTrack = videoTracks.firstObject;

    // ── 6. Load audio asset ───────────────────────────────────────────────────

    NSURL *audioAssetURL = [NSURL fileURLWithPath:audioURL];
    if (![fm fileExistsAtPath:audioURL]) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:7
                                      message:[NSString stringWithFormat:
                                               @"Sidecar audio file not found: %@", audioURL]]];
        return;
    }
    AVAsset *audioAsset = [AVAsset assetWithURL:audioAssetURL];
    NSArray<AVAssetTrack *> *audioTracks = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:8
                                      message:[NSString stringWithFormat:
                                               @"Sidecar audio asset has no audio track: %@",
                                               audioURL]]];
        return;
    }
    AVAssetTrack *audioTrack = audioTracks.firstObject;

    // ── 7. Build AVMutableComposition ─────────────────────────────────────────

    AVMutableComposition *composition = [AVMutableComposition composition];

    // 7a. Add video track ─────────────────────────────────────────────────────

    AVMutableCompositionTrack *compVideoTrack =
        [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                preferredTrackID:kCMPersistentTrackID_Invalid];

    CMTimeRange fullVideoRange = CMTimeRangeMake(kCMTimeZero, videoDuration);
    NSError *insertErr = nil;
    BOOL inserted = [compVideoTrack insertTimeRange:fullVideoRange
                                           ofTrack:videoTrack
                                            atTime:kCMTimeZero
                                             error:&insertErr];
    if (!inserted) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:9
                                      message:@"Failed to insert video track into composition"
                                   underlying:insertErr]];
        return;
    }

    // 7b. Compute clamped audio insertion range ────────────────────────────────
    //
    // startTime: where in the composition timeline the audio begins.
    // duration:  how many seconds of source audio to include.
    //
    // Clamped so that (startTime + duration) <= videoDuration.
    // This prevents the composition from extending beyond the video length.

    double effectiveEnd = startTime + duration;
    if (effectiveEnd > videoDurationSecs) {
        double clampedDuration = videoDurationSecs - startTime;
        os_log(sMuxerLog,
               "[8.14A] clamping audio duration %.3f → %.3f (video=%.3f startTime=%.3f)",
               duration, clampedDuration, videoDurationSecs, startTime);
        duration = clampedDuration;
    }
    if (startTime >= videoDurationSecs || duration <= 0.0) {
        // Audio starts after video ends — treat as no audio. Copy video only.
        os_log(sMuxerLog, "[8.14A] audio startTime >= video duration — skipping audio");
        [self _copyVideoOnlyFrom:videoTempPath
                              to:finalOutputPath
                      completion:completion];
        return;
    }

    // ── Use timescale 600 for all CMTime construction (Opus requirement). ──────
    // Timescale 600 = LCM(24,25,30,60); sub-second positions are lossless.

    CMTime audioInsertionStart = CMTimeMakeWithSeconds(startTime, kVGMuxTimescale);
    CMTime audioDurationTime   = CMTimeMakeWithSeconds(duration,  kVGMuxTimescale);

    // Source range in the audio asset: always starts from the beginning of the
    // file for Phase 8.14A MVP. If the asset is shorter than requested duration,
    // AVAssetTrack's own duration caps it (the insert will insert up to track end).
    CMTime audioSourceStart = kCMTimeZero;
    CMTime audioSourceDuration = audioDurationTime;

    // Cap to actual audio asset duration to avoid inserting beyond asset end.
    CMTime audioAssetDuration = audioAsset.duration;
    if (CMTIME_IS_VALID(audioAssetDuration) && CMTIME_IS_NUMERIC(audioAssetDuration)) {
        if (CMTimeCompare(audioSourceDuration, audioAssetDuration) > 0) {
            audioSourceDuration = audioAssetDuration;
        }
    }
    CMTimeRange audioSourceRange = CMTimeRangeMake(audioSourceStart, audioSourceDuration);

    // 7c. Add audio track ─────────────────────────────────────────────────────

    AVMutableCompositionTrack *compAudioTrack =
        [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                preferredTrackID:kCMPersistentTrackID_Invalid];

    NSError *audioInsertErr = nil;
    BOOL audioInserted = [compAudioTrack insertTimeRange:audioSourceRange
                                                ofTrack:audioTrack
                                                 atTime:audioInsertionStart
                                                  error:&audioInsertErr];
    if (!audioInserted) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:10
                                      message:@"Failed to insert audio track into composition"
                                   underlying:audioInsertErr]];
        return;
    }

    // 7d. Apply volume (via AVMutableAudioMix) ─────────────────────────────────
    //
    // Only apply if volume differs from unity to avoid unnecessary mixing.

    AVMutableAudioMix *audioMix = nil;
    if (fabs(volume - 1.0) > 0.001) {
        AVMutableAudioMixInputParameters *params =
            [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:compAudioTrack];
        [params setVolume:(float)volume atTime:kCMTimeZero];
        audioMix = [AVMutableAudioMix audioMix];
        audioMix.inputParameters = @[params];
    }

    os_log(sMuxerLog,
           "[8.14A] composition ready: video=%.2fs audio=%.2fs@%.2fs vol=%.2f",
           videoDurationSecs, duration, startTime, volume);

    // ── 8. Delete existing output file (AVAssetExportSession cannot overwrite) ──

    if ([fm fileExistsAtPath:finalOutputPath]) {
        NSError *removeErr = nil;
        if (![fm removeItemAtPath:finalOutputPath error:&removeErr]) {
            [self _fireCompletion:completion
                          success:NO
                         duration:0.0
                            error:[self _errorCode:11
                                          message:@"Failed to remove existing output file"
                                       underlying:removeErr]];
            return;
        }
    }

    // ── 9. AVAssetExportSession ────────────────────────────────────────────────
    //
    // AVAssetExportPresetPassthrough: no re-encode. Copies the already-encoded
    // H.264 video bits and AAC audio bits directly into the MP4 container.
    // For typical short-form video this completes in < 1s.

    NSURL *outputURL = [NSURL fileURLWithPath:finalOutputPath];
    AVAssetExportSession *exportSession =
        [[AVAssetExportSession alloc] initWithAsset:composition
                                         presetName:AVAssetExportPresetPassthrough];

    if (!exportSession) {
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:12 message:@"AVAssetExportSession init failed"]];
        return;
    }

    exportSession.outputFileType = AVFileTypeMPEG4;
    exportSession.outputURL      = outputURL;
    if (audioMix) {
        exportSession.audioMix = audioMix;
    }

    os_log(sMuxerLog, "[8.14A] AVAssetExportSession starting");

    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        AVAssetExportSessionStatus status = exportSession.status;

        switch (status) {
            case AVAssetExportSessionStatusCompleted: {
                // Measure actual output duration.
                AVAsset *outAsset = [AVAsset assetWithURL:outputURL];
                CMTime outDuration = outAsset.duration;
                NSTimeInterval outSecs = 0.0;
                if (CMTIME_IS_VALID(outDuration) && CMTIME_IS_NUMERIC(outDuration)) {
                    outSecs = CMTimeGetSeconds(outDuration);
                }

                // Delete temp video on success.
                NSFileManager *localFM = [NSFileManager defaultManager];
                if ([localFM fileExistsAtPath:videoTempPath]) {
                    [localFM removeItemAtPath:videoTempPath error:nil];
                }

                os_log(sMuxerLog, "[8.14A] mux complete: %.2fs", outSecs);
                [self _fireCompletion:completion success:YES duration:outSecs error:nil];
                break;
            }

            case AVAssetExportSessionStatusCancelled:
                [self _cleanupTempPath:videoTempPath partialOutputPath:finalOutputPath];
                [self _fireCompletion:completion
                              success:NO
                             duration:0.0
                                error:[self _errorCode:20 message:@"AVAssetExportSession was cancelled"]];
                break;

            default: {
                NSError *exportErr = exportSession.error;
                os_log_error(sMuxerLog,
                             "[8.14A] mux failed status=%ld err=%{public}@",
                             (long)status, exportErr.localizedDescription);
                [self _cleanupTempPath:videoTempPath partialOutputPath:finalOutputPath];
                [self _fireCompletion:completion
                              success:NO
                             duration:0.0
                                error:[self _errorCode:21
                                              message:@"AVAssetExportSession failed"
                                           underlying:exportErr]];
                break;
            }
        }
    }];
}

// ─── Private: video-only copy (no audio) ─────────────────────────────────────

- (void)_copyVideoOnlyFrom:(NSString *)videoTempPath
                        to:(NSString *)finalOutputPath
                completion:(void (^)(BOOL, NSTimeInterval, NSError * _Nullable))completion {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Delete existing output if present.
    if ([fm fileExistsAtPath:finalOutputPath]) {
        NSError *removeErr = nil;
        if (![fm removeItemAtPath:finalOutputPath error:&removeErr]) {
            [self _fireCompletion:completion
                          success:NO
                         duration:0.0
                            error:[self _errorCode:30
                                          message:@"Failed to remove existing output file before copy"
                                       underlying:removeErr]];
            return;
        }
    }

    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtPath:videoTempPath toPath:finalOutputPath error:&copyErr];
    if (!copied) {
        [self _cleanupTempPath:videoTempPath partialOutputPath:finalOutputPath];
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:31
                                      message:@"Failed to copy video-only temp to final output"
                                   underlying:copyErr]];
        return;
    }

    // Measure duration of copied file.
    AVAsset *outAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:finalOutputPath]];
    CMTime outDuration = outAsset.duration;
    NSTimeInterval outSecs = 0.0;
    if (CMTIME_IS_VALID(outDuration) && CMTIME_IS_NUMERIC(outDuration)) {
        outSecs = CMTimeGetSeconds(outDuration);
    }

    // Delete temp on success.
    if ([fm fileExistsAtPath:videoTempPath]) {
        [fm removeItemAtPath:videoTempPath error:nil];
    }

    os_log(sMuxerLog, "[8.14A] video-only copy complete: %.2fs", outSecs);
    [self _fireCompletion:completion success:YES duration:outSecs error:nil];
}

// ─── Private: cleanup on failure ─────────────────────────────────────────────

- (void)_cleanupTempPath:(NSString *)videoTempPath
       partialOutputPath:(NSString *)outputPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:videoTempPath]) {
        [fm removeItemAtPath:videoTempPath error:nil];
    }
    if ([fm fileExistsAtPath:outputPath]) {
        [fm removeItemAtPath:outputPath error:nil];
    }
}

// ─── Private: completion helper ──────────────────────────────────────────────

- (void)_fireCompletion:(void (^)(BOOL, NSTimeInterval, NSError * _Nullable))completion
                success:(BOOL)success
               duration:(NSTimeInterval)duration
                  error:(nullable NSError *)error {
    if (completion) {
        completion(success, duration, error);
    }
}

// ─── Private: error helpers ───────────────────────────────────────────────────

- (NSError *)_errorCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"VGAudioExportMuxer"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSError *)_errorCode:(NSInteger)code
                message:(NSString *)message
             underlying:(nullable NSError *)underlying {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:@"VGAudioExportMuxer"
                               code:code
                           userInfo:[info copy]];
}

@end
