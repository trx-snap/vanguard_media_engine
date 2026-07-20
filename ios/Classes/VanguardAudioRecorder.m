// VanguardAudioRecorder.m
// Vanguard Media Engine — Audio Slice N/O
//
// Minimal microphone capture backed by AVAudioRecorder.
// Module-visible only — not part of the public API.
//
// See VanguardAudioRecorder.h for full architecture notes.

#import "VanguardAudioRecorder.h"
#import "VGTimelineStateSnapshot.h"   // package-internal — readTimelineStateSnapshot
#import "VanguardGraphRuntime.h"

#if VG_USE_V2_GRAPH

// ─── Error domain ─────────────────────────────────────────────────────────────

NSString * const VGRecorderErrorDomain = @"VGRecorderErrorDomain";

static NSError *_makeError(VGRecorderError code, NSString *message) {
    return [NSError errorWithDomain:VGRecorderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Like _makeError, but also records the originating error under NSUnderlyingErrorKey.
/// The top-level error is ALWAYS in VGRecorderErrorDomain so callers never see
/// a raw AVAudioSession / mock domain leak out of this module.
static NSError *_makeErrorWithUnderlying(VGRecorderError code,
                                         NSString *message,
                                         NSError * _Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary
                                  dictionaryWithObject:message
                                               forKey:NSLocalizedDescriptionKey];
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:VGRecorderErrorDomain
                               code:code
                           userInfo:[info copy]];
}

// ─── Production time provider ─────────────────────────────────────────────────

@interface _VGRealTimeProvider : NSObject <VGAudioRecorderTimeProvider>
@end
@implementation _VGRealTimeProvider
- (NSTimeInterval)currentTime { return CACurrentMediaTime(); }
@end

// ─── Production recorder backend ─────────────────────────────────────────────
//
// Wraps a real AVAudioRecorder, forwarding all protocol messages.

@interface _VGRealRecorderBackend : NSObject <VGAudioRecorderBackend>
- (instancetype)initWithRecorder:(AVAudioRecorder *)recorder NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation _VGRealRecorderBackend {
    AVAudioRecorder *_recorder;
}

- (instancetype)initWithRecorder:(AVAudioRecorder *)recorder {
    self = [super init];
    if (self) { _recorder = recorder; }
    return self;
}
- (BOOL)prepareToRecord { return [_recorder prepareToRecord]; }
- (BOOL)record          { return [_recorder record]; }
- (void)stop            { [_recorder stop]; }
- (BOOL)isRecording     { return _recorder.isRecording; }
- (NSTimeInterval)currentTime { return _recorder.currentTime; }
@end

// ─── Production backend factory ───────────────────────────────────────────────

@interface _VGRealBackendFactory : NSObject <VGAudioRecorderBackendFactory>
@end
@implementation _VGRealBackendFactory

- (nullable id<VGAudioRecorderBackend>)backendWithURL:(NSURL *)url
                                             settings:(NSDictionary<NSString *, id> *)settings
                                                error:(NSError **)error {
    NSError *recErr = nil;
    AVAudioRecorder *rec = [[AVAudioRecorder alloc] initWithURL:url
                                                       settings:settings
                                                          error:&recErr];
    if (!rec) {
        if (error) *error = recErr;
        return nil;
    }
    return [[_VGRealRecorderBackend alloc] initWithRecorder:rec];
}

@end

// ─── Production duration probe ────────────────────────────────────────────────
//
// Reads the finalized encoded file's container duration via AVURLAsset after
// [backend stop] has flushed and closed the file. The actual container parse
// is performed off the main thread; the completion is always marshalled back
// to the main queue.
//
// Compatible with all iOS deployment targets supported by this package
// (AVURLAsset and CoreMedia are available since iOS 5).

@interface _VGRealDurationProbe : NSObject <VGAudioRecorderDurationProbe>
@end
@implementation _VGRealDurationProbe

- (void)probeDurationOfFileAtURL:(NSURL *)fileURL
                      completion:(void (^)(NSTimeInterval duration))completion {
    // Capture the block so the dispatch block retains it.
    void (^cb)(NSTimeInterval) = [completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // AVURLAsset.duration blocks the calling thread for one XPC round-trip
        // to mediaserverd (~5–30 ms typical). Performed off-main to keep the
        // MethodChannel and timer dispatch unblocked.
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
        NSTimeInterval dur = CMTimeGetSeconds(asset.duration);
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(dur);
        });
    });
}

@end

// ─── VGAudioRecordingStartInfo ────────────────────────────────────────────────

@implementation VGAudioRecordingStartInfo

- (instancetype)initWithFilePath:(NSString *)filePath
                        startPTS:(double)startPTS {
    self = [super init];
    if (self) {
        _filePath = [filePath copy];
        _startPTS = startPTS;
    }
    return self;
}

@end

// ─── VGAudioRecordingStopInfo ─────────────────────────────────────────────────

@implementation VGAudioRecordingStopInfo

- (instancetype)initWithFilePath:(NSString *)filePath
                        startPTS:(double)startPTS
                 durationSeconds:(double)durationSeconds {
    self = [super init];
    if (self) {
        _filePath = [filePath copy];
        _startPTS = startPTS;
        _durationSeconds = durationSeconds;
    }
    return self;
}

@end

// ─── VanguardAudioRecorder ────────────────────────────────────────────────────

static const NSTimeInterval kDefaultProbeTimeoutSecs = 2.0;

@implementation VanguardAudioRecorder {
    id<VGAudioRecorderTimeProvider>      _timeProvider;
    id<VGAudioRecorderBackendFactory>    _backendFactory;
    id<VGAudioRecorderDurationProbe>     _durationProbe;
    NSTimeInterval                       _probeTimeoutSecs;

    id<VGAudioRecorderBackend> _Nullable _backend;
    NSString                 * _Nullable _activeFilePath;
    double                                _activeStartPTS;

    // Monotonic host-time timestamp captured immediately after [backend record]
    // succeeds. Used at stop as the fallback duration source when the finalized-
    // file probe fails or times out.
    // Reset to 0.0 on every state-clearing path (stop, cancel, failed start).
    NSTimeInterval                        _recordingStartHostTime;
}

// ── Initializers ──────────────────────────────────────────────────────────────

- (instancetype)initWithTimeProvider:(nullable id<VGAudioRecorderTimeProvider>)timeProvider
                      backendFactory:(nullable id<VGAudioRecorderBackendFactory>)backendFactory
                       durationProbe:(nullable id<VGAudioRecorderDurationProbe>)durationProbe
                   probeTimeoutSecs:(NSTimeInterval)probeTimeoutSecs {
    self = [super init];
    if (self) {
        _timeProvider     = timeProvider   ?: [[_VGRealTimeProvider alloc] init];
        _backendFactory   = backendFactory ?: [[_VGRealBackendFactory alloc] init];
        _durationProbe    = durationProbe  ?: [[_VGRealDurationProbe alloc] init];
        _probeTimeoutSecs = (isfinite(probeTimeoutSecs) && probeTimeoutSecs > 0.0)
                            ? probeTimeoutSecs
                            : kDefaultProbeTimeoutSecs;
    }
    return self;
}

- (instancetype)initWithTimeProvider:(nullable id<VGAudioRecorderTimeProvider>)timeProvider
                      backendFactory:(nullable id<VGAudioRecorderBackendFactory>)backendFactory {
    return [self initWithTimeProvider:timeProvider
                       backendFactory:backendFactory
                        durationProbe:nil
                    probeTimeoutSecs:kDefaultProbeTimeoutSecs];
}

- (instancetype)init {
    return [self initWithTimeProvider:nil backendFactory:nil];
}

- (BOOL)isRecording {
    return _backend != nil && _backend.isRecording;
}

// ── Start ─────────────────────────────────────────────────────────────────────

- (nullable VGAudioRecordingStartInfo *)
    startRecordingWithRuntime:(VanguardGraphRuntime *)runtime
                   outputPath:(NSString *)outputPath
                        error:(NSError **)outError {

    NSAssert([NSThread isMainThread], @"VanguardAudioRecorder: must be called on main thread");

    // 1. Guard: already recording — refuse, do not silently discard user audio.
    if (self.isRecording) {
        [self _setError:outError
                   code:VGRecorderErrorAlreadyRecording
                message:@"startRecording called while a recording is already active. "
                         "Call stopRecording or cancelRecording first."];
        return nil;
    }

    // 2. Guard: nil runtime.
    if (!runtime) {
        [self _setError:outError
                   code:VGRecorderErrorNoRuntime
                message:@"startRecording: runtime must not be nil"];
        return nil;
    }

    // 3. Guard: bad output path.
    if (outputPath.length == 0) {
        [self _setError:outError
                   code:VGRecorderErrorBadOutputPath
                message:@"startRecording: outputPath must be non-empty"];
        return nil;
    }

    // 4. Build backend (settings: AAC, 44.1 kHz mono).
    // Backend is constructed before reading the timeline snapshot so that
    // any file-system / hardware allocation failures surface early.
    NSDictionary<NSString *, id> *settings = @{
        AVFormatIDKey:            @(kAudioFormatMPEG4AAC),
        AVSampleRateKey:          @44100.0,
        AVNumberOfChannelsKey:    @1,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh),
        AVEncoderBitRateKey:      @64000,
    };

    NSURL *url = [NSURL fileURLWithPath:outputPath];
    NSError *backendErr = nil;
    id<VGAudioRecorderBackend> backend = [_backendFactory backendWithURL:url
                                                                settings:settings
                                                                   error:&backendErr];
    if (!backend) {
        NSLog(@"[VanguardAudioRecorder] backend init failed: %@", backendErr);
        if (outError) *outError = _makeErrorWithUnderlying(VGRecorderErrorRecorderInit,
                                                           @"Recorder backend initialisation failed",
                                                           backendErr);
        return nil;
    }

    // 5. prepareToRecord — allocates output file and hardware resources.
    //    Must succeed before we read the timeline snapshot so the skew between
    //    the PTS read and the first recorded sample is minimised.
    if (![backend prepareToRecord]) {
        NSLog(@"[VanguardAudioRecorder] prepareToRecord failed");
        [self _setError:outError
                   code:VGRecorderErrorRecorderInit
                message:@"Recorder backend prepareToRecord returned NO"];
        return nil;
    }

    // 6. Read timeline snapshot immediately before record().
    //    The caller (VGAudioRecordingHandler) has already activated
    //    PlayAndRecord via VGAudioSessionTransitionCoordinator before this call.
    VGTimelineStateSnapshot snap = [runtime readTimelineStateSnapshot];
    if (!snap.isValid) {
        [self _setError:outError
                   code:VGRecorderErrorInvalidSnapshot
                message:@"startRecording: timeline snapshot is invalid "
                         "(runtime may be invalidated or not yet prepared)"];
        return nil;
    }

    double startPTS;
    if (snap.isPlaying) {
        NSTimeInterval now = [_timeProvider currentTime];
        double elapsed = MAX(0.0, now - snap.playStartHostTime);
        startPTS = snap.playStartPTS + elapsed;
        NSLog(@"[VanguardAudioRecorder] start PTS (playing): %.6f "
              @"(playStartPTS=%.6f, elapsed=%.6f)",
              startPTS, snap.playStartPTS, elapsed);
    } else {
        startPTS = snap.timelinePTS;
        NSLog(@"[VanguardAudioRecorder] start PTS (paused): %.6f", startPTS);
    }

    // 7. Begin capture.
    if (![backend record]) {
        NSLog(@"[VanguardAudioRecorder] record failed to start");
        [self _setError:outError
                   code:VGRecorderErrorRecorderInit
                message:@"Recorder backend record returned NO"];
        return nil;
    }

    // 8. Commit state — recorder is now live.
    // Capture the monotonic start timestamp AFTER record() has succeeded so
    // that a failed start leaves _recordingStartHostTime at its zero value.
    _backend                = backend;
    _activeFilePath         = [outputPath copy];
    _activeStartPTS         = startPTS;
    _recordingStartHostTime = [_timeProvider currentTime];

    NSLog(@"[VanguardAudioRecorder] recording started: path=%@, startPTS=%.6f",
          outputPath.lastPathComponent, startPTS);

    return [[VGAudioRecordingStartInfo alloc]
              initWithFilePath:outputPath
                      startPTS:startPTS];
}

// ── Stop ──────────────────────────────────────────────────────────────────────

- (void)stopRecordingWithCompletion:
    (void (^)(VGAudioRecordingStopInfo * _Nullable, NSError * _Nullable))completion {

    NSAssert([NSThread isMainThread], @"VanguardAudioRecorder: must be called on main thread");
    NSAssert(completion != nil, @"completion must not be nil");

    if (!self.isRecording) {
        completion(nil, _makeError(VGRecorderErrorNotRecording,
                                   @"stopRecording called but no recording is active"));
        return;
    }

    // ── Step 1: Capture per-stop local state ──────────────────────────────────
    // All values are captured into local variables so a later recorder reuse
    // cannot corrupt this stop operation's closure captures.
    NSString       *filePath         = [_activeFilePath copy];
    double          startPTS         = _activeStartPTS;
    NSTimeInterval  stopHostTime     = [_timeProvider currentTime];
    NSTimeInterval  startHostTime    = _recordingStartHostTime;

    // Compute finite, nonnegative monotonic elapsed — the fallback duration.
    // _recordingStartHostTime is always set after record() succeeds.
    NSTimeInterval monotonicElapsed = stopHostTime - startHostTime;
    if (monotonicElapsed < 0.0) { monotonicElapsed = 0.0; }

    // ── Step 2: Finalise the encoded file ─────────────────────────────────────
    // [backend stop] flushes all pending audio frames and closes the container.
    // This must happen before the duration probe, which reads the closed file.
    [_backend stop];

    // ── Step 3: Clear active recording state synchronously on the main thread ─
    // The recorder is now idle. Any subsequent startRecording call will see
    // isRecording == NO and proceed independently.
    _backend                = nil;
    _activeFilePath         = nil;
    _activeStartPTS         = 0.0;
    _recordingStartHostTime = 0.0;

    // Note: AVAudioSession restoration is NOT performed here.
    // The caller (VGAudioRecordingHandler) is responsible for calling
    // coordinator.restorePlayback() after this completion fires.

    // ── Steps 4–7: Async duration probe with bounded timeout ──────────────────
    // The finalized-file duration is authoritative when the probe returns a
    // finite, positive value. Monotonic elapsed is used only on probe failure
    // or timeout. Both paths funnel through one main-queue-confined resolver.

    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    NSTimeInterval timeoutSecs = _probeTimeoutSecs;
    id<VGAudioRecorderDurationProbe> probe = _durationProbe;

    // Gate and timer are __block so the resolver can nil the timer reference
    // after cancellation, breaking the dispatch_source retain cycle.
    __block BOOL delivered = NO;
    __block dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());

    // ── Single resolver — called on the main queue by either path ─────────────
    // The timeout path invokes this resolver with isTimeout = YES, in which case
    // probedDuration is ignored and monotonicElapsed is selected as fallback.
    // The probe and timeout share the main-queue exactly-once gate.
    //
    // Captured state: filePath, startPTS, monotonicElapsed, timer, delivered,
    // completion. All are local to this stop invocation.
    void (^resolve)(NSTimeInterval probedDuration, BOOL isTimeout) =
        ^(NSTimeInterval probedDuration, BOOL isTimeout) {
        // Exactly-once gate — main queue serialises concurrent arrivals.
        if (delivered) { return; }
        delivered = YES;

        // Cancel and release the timer to break the dispatch_source retain cycle.
        dispatch_source_cancel(timer);
        timer = nil;

        // Duration selection: finalized-file is authoritative when finite and > 0.
        // Never compare against monotonic elapsed.
        BOOL useFileProbe = (!isTimeout && isfinite(probedDuration) && probedDuration > 0.0);
        NSTimeInterval selected = useFileProbe ? probedDuration : monotonicElapsed;

        // Final finite/nonnegative guard against exotic clock or probe results.
        if (!isfinite(selected) || selected < 0.0) { selected = 0.0; }

        if (isTimeout) {
            NSLog(@"[VanguardAudioRecorder] recording stopped: path=%@, "
                  @"monotonicElapsed=%.6f, selectedDuration=%.6f (timeout-fallback)",
                  filePath.lastPathComponent, monotonicElapsed, selected);
        } else if (useFileProbe) {
            NSLog(@"[VanguardAudioRecorder] recording stopped: path=%@, "
                  @"fileDuration=%.6f, monotonicElapsed=%.6f, "
                  @"selectedDuration=%.6f (finalized-file)",
                  filePath.lastPathComponent, probedDuration, monotonicElapsed, selected);
        } else {
            NSLog(@"[VanguardAudioRecorder] recording stopped: path=%@, "
                  @"probedDuration=%.6f (invalid), monotonicElapsed=%.6f, "
                  @"selectedDuration=%.6f (probe-invalid-fallback)",
                  filePath.lastPathComponent, probedDuration, monotonicElapsed, selected);
        }

        VGAudioRecordingStopInfo *info =
            [[VGAudioRecordingStopInfo alloc] initWithFilePath:filePath
                                                      startPTS:startPTS
                                               durationSeconds:selected];
        completion(info, nil);
    };

    // ── Timeout handler ───────────────────────────────────────────────────────
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSecs * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER,  // one-shot
        (uint64_t)(0.05 * NSEC_PER_SEC));  // 50 ms leeway

    dispatch_source_set_event_handler(timer, ^{
        resolve(0.0, YES /*isTimeout*/);
    });

    dispatch_resume(timer);

    // ── Duration probe ────────────────────────────────────────────────────────
    // The production probe marshals its callback to the main queue. Injected
    // probes should do the same; we defensively re-dispatch any off-main
    // callback before calling the resolver, so the gate is always main-confined.
    [probe probeDurationOfFileAtURL:fileURL completion:^(NSTimeInterval probedDuration) {
        if ([NSThread isMainThread]) {
            resolve(probedDuration, NO /*isTimeout*/);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                resolve(probedDuration, NO /*isTimeout*/);
            });
        }
    }];
}

// ── Cancel ────────────────────────────────────────────────────────────────────

- (void)cancelRecording {
    NSAssert([NSThread isMainThread], @"VanguardAudioRecorder: must be called on main thread");
    if (_backend) {
        // 1. Copy the path before clearing state so we can delete after stop.
        NSString *pathToDelete = [_activeFilePath copy];

        // 2. Stop the backend (synchronous — AVAudioRecorder.stop).
        [_backend stop];

        // 3. Clear recorder state.
        _backend                = nil;
        _activeFilePath         = nil;
        _activeStartPTS         = 0.0;
        _recordingStartHostTime = 0.0;

        // 4. Delete the partial file if a path was captured.
        // No duration probe is triggered on the cancel path.
        if (pathToDelete) {
            NSError *removeErr = nil;
            BOOL removed = [[NSFileManager defaultManager]
                               removeItemAtPath:pathToDelete
                                          error:&removeErr];
            if (removed) {
                NSLog(@"[VanguardAudioRecorder] partial file deleted: %@",
                      pathToDelete.lastPathComponent);
            } else {
                // 5. Log failure without crashing.
                NSLog(@"[VanguardAudioRecorder] WARNING: failed to delete partial file %@: %@",
                      pathToDelete.lastPathComponent,
                      removeErr.localizedDescription);
            }
        }

        NSLog(@"[VanguardAudioRecorder] recording cancelled");
    }
    // Note: AVAudioSession restoration is NOT performed here.
    // The caller (VGAudioRecordingHandler) is responsible for calling
    // coordinator.restorePlayback() after this returns.
}

// ── Internals ─────────────────────────────────────────────────────────────────

- (void)_setError:(NSError **)outError code:(VGRecorderError)code message:(NSString *)msg {
    if (outError) *outError = _makeError(code, msg);
}

@end

#endif // VG_USE_V2_GRAPH
