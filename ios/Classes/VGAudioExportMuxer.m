// VGAudioExportMuxer.m
// vanguard_media_engine — Phase 8.14B Multi-Track Audio Mixdown / Phase 8.14C Original Clip Audio Preservation
//
// 2-pass post-pass audio muxer.
//
// Phase 8.14B Pipeline:
//   videoTempPath (H.264 MP4, video-only)
//   + sidecar audio tracks (any AVFoundation-readable audio files)
//
//   Pass 1 — Audio Mixdown (if any sidecar track exists AND volume/fade needed):
//     AVMutableComposition (audio-only) + AVMutableAudioMix
//     → AVAssetExportPresetAppleM4A, AVFileTypeAppleM4A
//     → audioMixTempPath (.audio_mix_tmp.m4a)
//
//   Pass 2 — Final Passthrough Mux:
//     AVMutableComposition (video-only MP4 + mixed M4A from Pass 1)
//     → AVAssetExportPresetPassthrough (no re-encode of video)
//     → finalOutputPath (.mp4)
//
//   Cleanup:
//     - videoTempPath deleted on success.
//     - audioMixTempPath deleted on success.
//     - All temp files + partial output deleted on any failure.
//
// Key decisions (Opus approval 2026-06-08):
//   - AVAssetExportPresetPassthrough cannot carry AVMutableAudioMix (Apple docs).
//     A 2-pass design is required: audio-only mixdown first, then passthrough mux.
//   - Pass 1 uses AVAssetExportPresetAppleM4A so AVMutableAudioMix is applied
//     during a re-encode of only the audio tracks (not the video).
//   - Pass 2 uses AVAssetExportPresetPassthrough: copies already-encoded H.264
//     video + re-encoded AAC audio directly into the MP4 container.
//   - One AVMutableCompositionTrack + one AVMutableAudioMixInputParameters
//     per sidecar track. Tracks are summed by AVFoundation mixing.
//   - Fade-in: setVolumeRampFrom:0→volume:timeRange covering the fade period.
//   - Fade-out: setVolumeRampFrom:volume→0:timeRange covering the fade period.
//   - Constant body: setVolume:atTime: covering the body period.
//   - Fade ramps are relative to each track's insertion point in the composition
//     (not relative to the source audio file).
//   - timescale 600: LCM of 24/25/30/60 fps denominators.
//   - Audio duration clamped to video duration.
//   - timeRemapAudioPolicy "mute": skip that track entirely.
//   - Output file deleted before AVAssetExportSession (cannot overwrite).
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
    NSString           *_videoTempPath;
    VGAudioSidecarPlan *_audioSidecar;
    NSString           *_finalOutputPath;

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
                 "[8.14B] init videoTemp=%{public}@ tracks=%lu out=%{public}@",
                 videoTempPath.lastPathComponent,
                 (unsigned long)audioSidecar.tracks.count,
                 finalOutputPath.lastPathComponent);
    return self;
}

// ─── startMuxWithCompletion: ─────────────────────────────────────────────────

- (void)startMuxWithCompletion:(void (^)(BOOL, NSTimeInterval, NSError * _Nullable))completion {
    // Single-fire gate: CAS 0 → 1.
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_startedAtomic, &expected, 1)) {
        os_log_debug(sMuxerLog, "[8.14B] startMuxWithCompletion: already started, ignoring");
        return;
    }

    NSParameterAssert(completion != nil);

    // Capture strong refs for the async block.
    NSString           *videoTempPath   = _videoTempPath;
    VGAudioSidecarPlan *sidecar         = _audioSidecar;
    NSString           *finalOutputPath = _finalOutputPath;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self _runMuxFromVideoTempPath:videoTempPath
                          audioSidecar:sidecar
                       finalOutputPath:finalOutputPath
                            completion:completion];
    });
}

// ─── Private: top-level mux entry ────────────────────────────────────────────

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

    if (!sidecar || sidecar.tracks.count == 0) {
        // No audio tracks — copy video-only to final output.
        os_log(sMuxerLog, "[8.14B] no sidecar tracks — passthrough video copy");
        [self _copyVideoOnlyFrom:videoTempPath
                              to:finalOutputPath
                      completion:completion];
        return;
    }

    // ── 3. Check timeRemapAudioPolicy at plan level ───────────────────────────
    //    If ALL tracks are muted, skip audio entirely.

    NSArray<NSDictionary<NSString *, id> *> *tracks = sidecar.tracks;
    NSMutableArray<NSDictionary<NSString *, id> *> *activeTracks = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *td in tracks) {
        NSString *policy = td[@"timeRemapAudioPolicy"];
        if ([policy isEqualToString:@"mute"]) {
            os_log(sMuxerLog,
                   "[8.14B] skipping muted track: %{public}@",
                   td[@"trackId"]);
            continue;
        }
        [activeTracks addObject:td];
    }

    if (activeTracks.count == 0) {
        os_log(sMuxerLog, "[8.14B] all tracks muted — passthrough video copy");
        [self _copyVideoOnlyFrom:videoTempPath
                              to:finalOutputPath
                      completion:completion];
        return;
    }

    // ── 4. Load video asset to get the reference video duration ──────────────

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

    os_log(sMuxerLog,
           "[8.14B] video duration=%.3fs tracks=%lu active audio tracks=%lu",
           videoDurationSecs,
           (unsigned long)videoTracks.count,
           (unsigned long)activeTracks.count);

    // ── 5. Pass 1: Audio-only mixdown → audioMixTempPath (.m4a) ──────────────

    NSString *audioMixTempPath = [finalOutputPath stringByAppendingString:@".audio_mix_tmp.m4a"];

    [self _pass1AudioMixdown:activeTracks
           videoDurationSecs:videoDurationSecs
           audioMixTempPath:audioMixTempPath
                  completion:^(BOOL pass1OK, NSError * _Nullable pass1Err) {
        if (!pass1OK) {
            // Pass 1 failed. Clean up video temp and any partial audio temp.
            [self _deleteFileIfExists:videoTempPath];
            [self _deleteFileIfExists:audioMixTempPath];
            [self _deleteFileIfExists:finalOutputPath];
            [self _fireCompletion:completion success:NO duration:0.0 error:pass1Err];
            return;
        }

        // ── 6. Pass 2: Video + mixed audio → finalOutputPath ─────────────────

        [self _pass2FinalMux:videoTempPath
               videoAsset:videoAsset
         audioMixTempPath:audioMixTempPath
          finalOutputPath:finalOutputPath
               completion:^(BOOL pass2OK, NSTimeInterval outDuration, NSError * _Nullable pass2Err) {
            if (pass2OK) {
                // Success: delete both temp files.
                [self _deleteFileIfExists:videoTempPath];
                [self _deleteFileIfExists:audioMixTempPath];
                os_log(sMuxerLog, "[8.14B] mux complete: %.3fs", outDuration);
                [self _fireCompletion:completion success:YES duration:outDuration error:nil];
            } else {
                // Pass 2 failed: delete all temps and partial output.
                [self _deleteFileIfExists:videoTempPath];
                [self _deleteFileIfExists:audioMixTempPath];
                [self _deleteFileIfExists:finalOutputPath];
                [self _fireCompletion:completion success:NO duration:0.0 error:pass2Err];
            }
        }];
    }];
}

// ─── Pass 1: Audio-only mixdown ───────────────────────────────────────────────
//
// Builds an audio-only AVMutableComposition from all active sidecar tracks.
// Applies per-track volume and fade ramps via AVMutableAudioMix.
// Exports using AVAssetExportPresetAppleM4A (AVFileTypeAppleM4A) — this preset
// is compatible with AVMutableAudioMix (it re-encodes only the audio, not video).
//
// Each track gets:
//   - One AVMutableCompositionTrack.
//   - One AVMutableAudioMixInputParameters targeting that composition track.
//   - setVolumeRamp from 0.0 → volume for fadeIn period (if fadeInSeconds > 0).
//   - setVolume:atTime: for the constant body between fades.
//   - setVolumeRamp from volume → 0.0 for fadeOut period (if fadeOutSeconds > 0).
//   All ramp times are relative to the track's insertion point in the composition.

- (void)_pass1AudioMixdown:(NSArray<NSDictionary<NSString *, id> *> *)activeTracks
         videoDurationSecs:(double)videoDurationSecs
         audioMixTempPath:(NSString *)audioMixTempPath
               completion:(void (^)(BOOL, NSError * _Nullable))completion {

    NSFileManager *fm = [NSFileManager defaultManager];

    // Delete any stale audio mix temp.
    if ([fm fileExistsAtPath:audioMixTempPath]) {
        NSError *removeErr = nil;
        if (![fm removeItemAtPath:audioMixTempPath error:&removeErr]) {
            completion(NO, [self _errorCode:30
                                    message:@"Failed to remove stale audio mix temp"
                                 underlying:removeErr]);
            return;
        }
    }

    AVMutableComposition *composition = [AVMutableComposition composition];
    NSMutableArray<AVMutableAudioMixInputParameters *> *mixParams =
        [NSMutableArray array];
    BOOL anyTrackInserted = NO;

    for (NSDictionary<NSString *, id> *td in activeTracks) {

        // ── Parse track fields ────────────────────────────────────────────────

        NSString *audioURL = td[@"url"];
        if (audioURL.length == 0) {
            os_log_error(sMuxerLog, "[8.14B] pass1: skipping track with empty url");
            continue;
        }

        if (![fm fileExistsAtPath:audioURL]) {
            os_log_error(sMuxerLog,
                         "[8.14B] pass1: audio file not found: %{public}@", audioURL);
            // Treat missing audio as non-fatal for that track; skip it.
            continue;
        }

        double startTime      = [td[@"startTime"] doubleValue];
        double duration       = [td[@"duration"]  doubleValue];
        double volume         = [td[@"volume"]    doubleValue];
        double fadeInSeconds  = [td[@"fadeInSeconds"]  doubleValue];
        double fadeOutSeconds = [td[@"fadeOutSeconds"] doubleValue];

        if (volume <= 0.0) volume = 1.0;
        if (startTime < 0.0) startTime = 0.0;
        if (duration <= 0.0) {
            os_log_error(sMuxerLog,
                         "[8.14B] pass1: skipping track with duration <= 0: %{public}@",
                         td[@"trackId"]);
            continue;
        }
        if (fadeInSeconds < 0.0)  fadeInSeconds  = 0.0;
        if (fadeOutSeconds < 0.0) fadeOutSeconds = 0.0;

        // ── Clamp to video duration ───────────────────────────────────────────

        double effectiveEnd = startTime + duration;
        if (effectiveEnd > videoDurationSecs) {
            double clamped = videoDurationSecs - startTime;
            os_log(sMuxerLog,
                   "[8.14B] pass1: clamping track %{public}@ duration %.3f → %.3f",
                   td[@"trackId"], duration, clamped);
            duration = clamped;
        }
        if (startTime >= videoDurationSecs || duration <= 0.0) {
            os_log(sMuxerLog,
                   "[8.14B] pass1: track %{public}@ starts after video end — skipping",
                   td[@"trackId"]);
            continue;
        }

        // Clamp fades so they don't exceed the available duration.
        if (fadeInSeconds > duration)  fadeInSeconds  = duration;
        if (fadeOutSeconds > duration) fadeOutSeconds = duration;
        if (fadeInSeconds + fadeOutSeconds > duration) {
            // Overlap: proportionally scale each fade.
            double total = fadeInSeconds + fadeOutSeconds;
            fadeInSeconds  = (fadeInSeconds  / total) * duration;
            fadeOutSeconds = (fadeOutSeconds / total) * duration;
        }

        // ── Load audio asset ──────────────────────────────────────────────────

        NSURL *audioAssetURL = [NSURL fileURLWithPath:audioURL];
        AVAsset *audioAsset  = [AVAsset assetWithURL:audioAssetURL];
        NSArray<AVAssetTrack *> *audioTracks =
            [audioAsset tracksWithMediaType:AVMediaTypeAudio];
        if (audioTracks.count == 0) {
            os_log_error(sMuxerLog,
                         "[8.14B] pass1: no audio track in file: %{public}@", audioURL);
            continue;
        }
        AVAssetTrack *audioTrack = audioTracks.firstObject;

        // ── Compute source range ──────────────────────────────────────────────
        // Phase 8.14C: read sourceTrimStart for original clip audio tracks.
        // Absent or 0.0 means start of file (backward-compatible with 8.14B).

        double sourceTrimStart = [td[@"sourceTrimStart"] doubleValue];
        if (sourceTrimStart < 0.0) sourceTrimStart = 0.0;

        CMTime audioDurationTime = CMTimeMakeWithSeconds(duration, kVGMuxTimescale);
        CMTime sourceStartTime   = CMTimeMakeWithSeconds(sourceTrimStart, kVGMuxTimescale);

        // Cap source range so sourceStart + duration does not exceed asset duration.
        // If sourceStart is past asset end or resulting duration is <= 0, skip.
        CMTime assetDur = audioAsset.duration;
        if (CMTIME_IS_VALID(assetDur) && CMTIME_IS_NUMERIC(assetDur)) {
            // If sourceStart is at or past the asset duration, skip this track.
            if (CMTimeCompare(sourceStartTime, assetDur) >= 0) {
                os_log_error(sMuxerLog,
                             "[8.14C] pass1: sourceTrimStart (%.3fs) is past "
                             "asset duration (%.3fs) for track %{public}@ — skipping",
                             sourceTrimStart, CMTimeGetSeconds(assetDur),
                             td[@"trackId"]);
                continue;
            }
            // Clamp: sourceStart + audioDuration must not exceed asset duration.
            CMTime sourceEnd = CMTimeAdd(sourceStartTime, audioDurationTime);
            if (CMTimeCompare(sourceEnd, assetDur) > 0) {
                audioDurationTime = CMTimeSubtract(assetDur, sourceStartTime);
                if (CMTimeCompare(audioDurationTime, kCMTimeZero) <= 0) {
                    os_log_error(sMuxerLog,
                                 "[8.14C] pass1: clamped duration <= 0 for "
                                 "track %{public}@ — skipping",
                                 td[@"trackId"]);
                    continue;
                }
                os_log(sMuxerLog,
                       "[8.14C] pass1: clamped track %{public}@ "
                       "sourceEnd %.3f → asset end %.3fs",
                       td[@"trackId"], CMTimeGetSeconds(sourceEnd),
                       CMTimeGetSeconds(assetDur));
            }
        }

        CMTimeRange sourceRange = CMTimeRangeMake(sourceStartTime, audioDurationTime);


        // ── Compute insertion point ───────────────────────────────────────────

        CMTime insertionPoint = CMTimeMakeWithSeconds(startTime, kVGMuxTimescale);

        // ── Add composition track ─────────────────────────────────────────────

        AVMutableCompositionTrack *compTrack =
            [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                    preferredTrackID:kCMPersistentTrackID_Invalid];

        NSError *insertErr = nil;
        BOOL inserted = [compTrack insertTimeRange:sourceRange
                                          ofTrack:audioTrack
                                           atTime:insertionPoint
                                            error:&insertErr];
        if (!inserted) {
            os_log_error(sMuxerLog,
                         "[8.14B] pass1: failed to insert track %{public}@: %{public}@",
                         td[@"trackId"],
                         insertErr.localizedDescription);
            continue;
        }

        anyTrackInserted = YES;

        // ── Build AVMutableAudioMixInputParameters for this track ─────────────
        // Phase 8.15A: if per-track volumeKeyframes are present and valid, they
        // completely override static volume / fadeInSeconds / fadeOutSeconds.
        // Only setVolumeRampFromStartVolume:toEndVolume:timeRange: is used for
        // keyframed tracks (never setVolume:atTime:) to avoid AVFoundation
        // ramp-vs-point interaction bugs.

        AVMutableAudioMixInputParameters *params =
            [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:compTrack];

        double insertStart_s = startTime;
        double insertEnd_s   = insertStart_s + CMTimeGetSeconds(audioDurationTime);
        CMTime insertEnd     = CMTimeAdd(insertionPoint, audioDurationTime);

        // ── Phase 8.15A: keyframe path ────────────────────────────────────────
        NSArray *rawKeyframes = td[@"volumeKeyframes"];
        BOOL useKeyframes = NO;

        if ([rawKeyframes isKindOfClass:[NSArray class]] && rawKeyframes.count > 0) {
            // 1. Parse and clamp to valid keyframes inside the track range.
            NSMutableArray<NSDictionary *> *validKfs = [NSMutableArray array];
            for (id entry in rawKeyframes) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *kfDict = (NSDictionary *)entry;
                double kfTime   = [kfDict[@"time"]   doubleValue];
                double kfVolume = [kfDict[@"volume"] doubleValue];
                // Clamp volume to [0, 1].
                kfVolume = MAX(0.0, MIN(1.0, kfVolume));
                // Discard keyframes outside the effective track range.
                if (kfTime < insertStart_s || kfTime > insertEnd_s) continue;
                [validKfs addObject:@{@"time": @(kfTime), @"volume": @(kfVolume)}];
            }

            // 2. Sort by time ascending.
            [validKfs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                double ta = [a[@"time"] doubleValue];
                double tb = [b[@"time"] doubleValue];
                if (ta < tb) return NSOrderedAscending;
                if (ta > tb) return NSOrderedDescending;
                return NSOrderedSame;
            }];

            // 3. Merge adjacent keyframes closer than 1 ms (keep later volume).
            NSMutableArray<NSDictionary *> *mergedKfs = [NSMutableArray array];
            for (NSUInteger i = 0; i < validKfs.count; i++) {
                if (mergedKfs.count == 0) {
                    [mergedKfs addObject:validKfs[i]];
                    continue;
                }
                NSDictionary *prev = mergedKfs.lastObject;
                double prevTime = [prev[@"time"] doubleValue];
                double currTime = [validKfs[i][@"time"] doubleValue];
                if ((currTime - prevTime) < 0.001) {
                    // Replace last with current (keep later volume).
                    [mergedKfs removeLastObject];
                }
                [mergedKfs addObject:validKfs[i]];
            }

            if (mergedKfs.count > 0) {
                useKeyframes = YES;

                // 4. Synthesize implicit start keyframe if needed.
                double firstKfTime = [mergedKfs.firstObject[@"time"] doubleValue];
                if (firstKfTime > insertStart_s + 0.001) {
                    NSMutableArray *withStart = [NSMutableArray array];
                    [withStart addObject:@{@"time": @(insertStart_s), @"volume": @(0.0)}];
                    [withStart addObjectsFromArray:mergedKfs];
                    mergedKfs = withStart;
                }

                // 5. Synthesize implicit terminal keyframe if needed (hold last volume).
                double lastKfTime   = [mergedKfs.lastObject[@"time"] doubleValue];
                double lastKfVolume = [mergedKfs.lastObject[@"volume"] doubleValue];
                if (lastKfTime < insertEnd_s - 0.001) {
                    [mergedKfs addObject:@{@"time": @(insertEnd_s), @"volume": @(lastKfVolume)}];
                }

                // 6. Emit one contiguous ramp per consecutive keyframe pair.
                for (NSUInteger i = 0; i + 1 < mergedKfs.count; i++) {
                    double t0 = [mergedKfs[i][@"time"]     doubleValue];
                    double v0 = [mergedKfs[i][@"volume"]   doubleValue];
                    double t1 = [mergedKfs[i + 1][@"time"]   doubleValue];
                    double v1 = [mergedKfs[i + 1][@"volume"] doubleValue];
                    if (t1 - t0 < 0.001) continue; // skip sub-ms gaps
                    CMTime segStart = CMTimeMakeWithSeconds(t0, kVGMuxTimescale);
                    CMTime segEnd   = CMTimeMakeWithSeconds(t1, kVGMuxTimescale);
                    CMTimeRange segRange = CMTimeRangeMake(segStart,
                                                           CMTimeSubtract(segEnd, segStart));
                    [params setVolumeRampFromStartVolume:(float)v0
                                             toEndVolume:(float)v1
                                               timeRange:segRange];
                }

                os_log(sMuxerLog,
                       "[8.15A] pass1: track %{public}@ keyframe path — %lu kf(s) "
                       "start=%.3fs dur=%.3fs",
                       td[@"trackId"], (unsigned long)mergedKfs.count,
                       insertStart_s, insertEnd_s - insertStart_s);
            }
        }

        // ── Static volume/fade path (unchanged from 8.14B) ───────────────────
        if (!useKeyframes) {
            CMTime bodyStartTime = CMTimeMakeWithSeconds(insertStart_s + fadeInSeconds,
                                                         kVGMuxTimescale);
            if (fadeInSeconds > 0.0) {
                CMTime fadeInEnd = CMTimeMakeWithSeconds(insertStart_s + fadeInSeconds,
                                                         kVGMuxTimescale);
                CMTimeRange fadeInRange = CMTimeRangeMake(insertionPoint,
                                                           CMTimeSubtract(fadeInEnd, insertionPoint));
                [params setVolumeRampFromStartVolume:0.0f
                                         toEndVolume:(float)volume
                                           timeRange:fadeInRange];
            }
            [params setVolume:(float)volume atTime:bodyStartTime];
            if (fadeOutSeconds > 0.0) {
                double fadeOutStart_s = insertEnd_s - fadeOutSeconds;
                CMTime fadeOutStart = CMTimeMakeWithSeconds(fadeOutStart_s, kVGMuxTimescale);
                CMTimeRange fadeOutRange = CMTimeRangeMake(fadeOutStart,
                                                            CMTimeSubtract(insertEnd, fadeOutStart));
                [params setVolumeRampFromStartVolume:(float)volume
                                         toEndVolume:0.0f
                                           timeRange:fadeOutRange];
            }
            os_log(sMuxerLog,
                   "[8.14B] pass1: track %{public}@ start=%.3fs dur=%.3fs vol=%.2f "
                   "fadeIn=%.3fs fadeOut=%.3fs",
                   td[@"trackId"], startTime, CMTimeGetSeconds(audioDurationTime),
                   volume, fadeInSeconds, fadeOutSeconds);
        }

        [mixParams addObject:params];
    }

    if (!anyTrackInserted) {
        // All tracks were skipped (missing files, bad durations, etc.).
        // Fall back to video-only passthrough.
        os_log(sMuxerLog, "[8.14B] pass1: no valid tracks inserted — will copy video only");
        completion(NO, [self _errorCode:31 message:@"No valid audio tracks could be inserted"]);
        return;
    }

    // ── Build AVMutableAudioMix ───────────────────────────────────────────────

    AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
    audioMix.inputParameters = [mixParams copy];

    // ── Export Pass 1 ─────────────────────────────────────────────────────────
    // AVAssetExportPresetAppleM4A: re-encodes audio with the mix applied.
    // Compatible with AVMutableAudioMix (unlike AVAssetExportPresetPassthrough).

    NSURL *audioMixTempURL = [NSURL fileURLWithPath:audioMixTempPath];

    AVAssetExportSession *pass1Session =
        [[AVAssetExportSession alloc] initWithAsset:composition
                                         presetName:AVAssetExportPresetAppleM4A];

    if (!pass1Session) {
        completion(NO, [self _errorCode:32 message:@"AVAssetExportSession (pass1) init failed"]);
        return;
    }

    pass1Session.outputFileType = AVFileTypeAppleM4A;
    pass1Session.outputURL      = audioMixTempURL;
    pass1Session.audioMix       = audioMix;

    os_log(sMuxerLog, "[8.14B] pass1: starting AVAssetExportPresetAppleM4A export");

    [pass1Session exportAsynchronouslyWithCompletionHandler:^{
        AVAssetExportSessionStatus status = pass1Session.status;
        if (status == AVAssetExportSessionStatusCompleted) {
            os_log(sMuxerLog, "[8.14B] pass1: audio mixdown complete");
            completion(YES, nil);
        } else {
            NSError *exportErr = pass1Session.error;
            os_log_error(sMuxerLog,
                         "[8.14B] pass1: export failed status=%ld err=%{public}@",
                         (long)status, exportErr.localizedDescription);
            completion(NO, [self _errorCode:33
                                    message:@"Pass 1 AVAssetExportSession failed"
                                 underlying:exportErr]);
        }
    }];
}

// ─── Pass 2: Final passthrough mux ───────────────────────────────────────────
//
// Builds a composition of:
//   - The video-only MP4 (from VGVideoEncoderSinkNode)
//   - The mixed audio M4A (from Pass 1)
// Exports using AVAssetExportPresetPassthrough (no re-encode of video or audio).

- (void)_pass2FinalMux:(NSString *)videoTempPath
            videoAsset:(AVAsset *)videoAsset
      audioMixTempPath:(NSString *)audioMixTempPath
       finalOutputPath:(NSString *)finalOutputPath
            completion:(void (^)(BOOL, NSTimeInterval, NSError * _Nullable))completion {

    NSFileManager *fm = [NSFileManager defaultManager];

    // Validate audio mix temp was produced.
    if (![fm fileExistsAtPath:audioMixTempPath]) {
        completion(NO, 0.0,
                   [self _errorCode:40 message:@"Audio mix temp file not found for pass 2"]);
        return;
    }

    CMTime videoDuration = videoAsset.duration;
    double videoDurationSecs = CMTimeGetSeconds(videoDuration);

    NSArray<AVAssetTrack *> *videoTracks = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        completion(NO, 0.0,
                   [self _errorCode:41 message:@"Video asset has no video track for pass 2"]);
        return;
    }
    AVAssetTrack *videoTrack = videoTracks.firstObject;

    // Load mixed audio asset.
    NSURL *audioMixURL = [NSURL fileURLWithPath:audioMixTempPath];
    AVAsset *audioMixAsset = [AVAsset assetWithURL:audioMixURL];
    NSArray<AVAssetTrack *> *audioMixTracks =
        [audioMixAsset tracksWithMediaType:AVMediaTypeAudio];
    if (audioMixTracks.count == 0) {
        completion(NO, 0.0,
                   [self _errorCode:42 message:@"Mixed audio temp has no audio track"]);
        return;
    }
    AVAssetTrack *audioMixTrack = audioMixTracks.firstObject;

    // ── Build final composition ───────────────────────────────────────────────

    AVMutableComposition *composition = [AVMutableComposition composition];

    // 1. Insert video track.
    AVMutableCompositionTrack *compVideoTrack =
        [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTimeRange fullVideoRange = CMTimeRangeMake(kCMTimeZero, videoDuration);
    NSError *videoInsertErr = nil;
    BOOL videoInserted = [compVideoTrack insertTimeRange:fullVideoRange
                                               ofTrack:videoTrack
                                                atTime:kCMTimeZero
                                                 error:&videoInsertErr];
    if (!videoInserted) {
        completion(NO, 0.0,
                   [self _errorCode:43
                             message:@"Failed to insert video track into pass 2 composition"
                          underlying:videoInsertErr]);
        return;
    }

    // 2. Insert mixed audio track.
    // Clamp audio to video duration in case Pass 1 produced a slightly longer file.
    AVMutableCompositionTrack *compAudioTrack =
        [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                preferredTrackID:kCMPersistentTrackID_Invalid];

    CMTime audioMixDuration = audioMixAsset.duration;
    if (!CMTIME_IS_VALID(audioMixDuration) || !CMTIME_IS_NUMERIC(audioMixDuration)) {
        audioMixDuration = videoDuration;
    }
    if (CMTimeCompare(audioMixDuration, videoDuration) > 0) {
        audioMixDuration = videoDuration;
    }
    CMTimeRange audioInsertRange = CMTimeRangeMake(kCMTimeZero, audioMixDuration);

    NSError *audioInsertErr = nil;
    BOOL audioInserted = [compAudioTrack insertTimeRange:audioInsertRange
                                               ofTrack:audioMixTrack
                                                atTime:kCMTimeZero
                                                 error:&audioInsertErr];
    if (!audioInserted) {
        completion(NO, 0.0,
                   [self _errorCode:44
                             message:@"Failed to insert audio track into pass 2 composition"
                          underlying:audioInsertErr]);
        return;
    }

    os_log(sMuxerLog,
           "[8.14B] pass2: composition ready — video=%.3fs audio=%.3fs",
           videoDurationSecs, CMTimeGetSeconds(audioMixDuration));

    // ── Delete existing output (AVAssetExportSession cannot overwrite) ────────

    if ([fm fileExistsAtPath:finalOutputPath]) {
        NSError *removeErr = nil;
        if (![fm removeItemAtPath:finalOutputPath error:&removeErr]) {
            completion(NO, 0.0,
                       [self _errorCode:45
                                 message:@"Failed to remove existing output file before pass 2"
                              underlying:removeErr]);
            return;
        }
    }

    // ── Pass 2 export ─────────────────────────────────────────────────────────
    // AVAssetExportPresetPassthrough: copies H.264 video bits + AAC audio bits
    // directly into the MP4 container without re-encoding.

    NSURL *outputURL = [NSURL fileURLWithPath:finalOutputPath];
    AVAssetExportSession *pass2Session =
        [[AVAssetExportSession alloc] initWithAsset:composition
                                         presetName:AVAssetExportPresetPassthrough];

    if (!pass2Session) {
        completion(NO, 0.0,
                   [self _errorCode:46 message:@"AVAssetExportSession (pass2) init failed"]);
        return;
    }

    // NOTE: do NOT set audioMix on a passthrough session — Apple ignores it
    // and it indicates a design error. The audio was already mixed in Pass 1.
    pass2Session.outputFileType = AVFileTypeMPEG4;
    pass2Session.outputURL      = outputURL;

    os_log(sMuxerLog, "[8.14B] pass2: starting AVAssetExportPresetPassthrough export");

    [pass2Session exportAsynchronouslyWithCompletionHandler:^{
        AVAssetExportSessionStatus status = pass2Session.status;

        if (status == AVAssetExportSessionStatusCompleted) {
            // Measure actual output duration.
            AVAsset *outAsset   = [AVAsset assetWithURL:outputURL];
            CMTime outDuration  = outAsset.duration;
            NSTimeInterval outSecs = 0.0;
            if (CMTIME_IS_VALID(outDuration) && CMTIME_IS_NUMERIC(outDuration)) {
                outSecs = CMTimeGetSeconds(outDuration);
            }
            os_log(sMuxerLog, "[8.14B] pass2: complete — output %.3fs", outSecs);
            completion(YES, outSecs, nil);

        } else if (status == AVAssetExportSessionStatusCancelled) {
            completion(NO, 0.0,
                       [self _errorCode:47 message:@"Pass 2 AVAssetExportSession was cancelled"]);
        } else {
            NSError *exportErr = pass2Session.error;
            os_log_error(sMuxerLog,
                         "[8.14B] pass2: failed status=%ld err=%{public}@",
                         (long)status, exportErr.localizedDescription);
            completion(NO, 0.0,
                       [self _errorCode:48
                                 message:@"Pass 2 AVAssetExportSession failed"
                              underlying:exportErr]);
        }
    }];
}

// ─── Private: video-only copy (no audio) ─────────────────────────────────────
//
// Used when no active audio tracks exist. Copies the video temp directly to
// the final output path. Does NOT use AVAssetExportSession so the video is
// not re-encoded.

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
                            error:[self _errorCode:50
                                          message:@"Failed to remove existing output before copy"
                                       underlying:removeErr]];
            return;
        }
    }

    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtPath:videoTempPath toPath:finalOutputPath error:&copyErr];
    if (!copied) {
        [self _deleteFileIfExists:videoTempPath];
        [self _deleteFileIfExists:finalOutputPath];
        [self _fireCompletion:completion
                      success:NO
                     duration:0.0
                        error:[self _errorCode:51
                                      message:@"Failed to copy video-only temp to final output"
                                   underlying:copyErr]];
        return;
    }

    // Measure duration of copied file.
    AVAsset *outAsset   = [AVAsset assetWithURL:[NSURL fileURLWithPath:finalOutputPath]];
    CMTime outDuration  = outAsset.duration;
    NSTimeInterval outSecs = 0.0;
    if (CMTIME_IS_VALID(outDuration) && CMTIME_IS_NUMERIC(outDuration)) {
        outSecs = CMTimeGetSeconds(outDuration);
    }

    // Delete temp on success.
    [self _deleteFileIfExists:videoTempPath];

    os_log(sMuxerLog, "[8.14B] video-only copy complete: %.3fs", outSecs);
    [self _fireCompletion:completion success:YES duration:outSecs error:nil];
}

// ─── Private: file deletion helper ───────────────────────────────────────────

- (void)_deleteFileIfExists:(NSString *)path {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) {
        [fm removeItemAtPath:path error:nil];
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
