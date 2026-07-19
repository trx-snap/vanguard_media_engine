// VanguardAudioRecorder.m
// Vanguard Media Engine — Audio Slice M
//
// Minimal microphone capture backed by AVAudioRecorder.
// Package-internal only — not part of the public API.
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

// ─── Production session manager ───────────────────────────────────────────────

@interface _VGRealSessionManager : NSObject <VGAudioRecorderSessionManager>
@end
@implementation _VGRealSessionManager

- (BOOL)activatePlayAndRecordWithError:(NSError **)error {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    // MixWithOthers: allow AVAudioEngine preview to keep playing alongside
    // the microphone input.  AllowBluetooth: enable BT microphone input.
    NSError *catErr = nil;
    BOOL ok = [s setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:(AVAudioSessionCategoryOptionMixWithOthers |
                              AVAudioSessionCategoryOptionAllowBluetooth)
                       error:&catErr];
    if (!ok) {
        if (error) *error = catErr;
        return NO;
    }
    NSError *actErr = nil;
    ok = [s setActive:YES error:&actErr];
    if (!ok) {
        if (error) *error = actErr;
        // Best-effort restore on partial failure.
        [s setCategory:AVAudioSessionCategoryPlayback error:nil];
        return NO;
    }
    return YES;
}

- (void)restorePlayback {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback error:nil];
    // Do NOT call setActive:NO — that would silence AVAudioEngine playback.
    NSLog(@"[VanguardAudioRecorder] AVAudioSession restored to Playback");
}

- (BOOL)isHeadphonesConnected {
    AVAudioSessionRouteDescription *route =
        [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *port in route.outputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortHeadphones] ||
            [port.portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [port.portType isEqualToString:AVAudioSessionPortBluetoothLE] ||
            [port.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
            return YES;
        }
    }
    return NO;
}

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

// ─── VGAudioRecordingStartInfo ────────────────────────────────────────────────

@implementation VGAudioRecordingStartInfo

- (instancetype)initWithFilePath:(NSString *)filePath
                        startPTS:(double)startPTS
             isHeadphonesConnected:(BOOL)isHeadphonesConnected {
    self = [super init];
    if (self) {
        _filePath = [filePath copy];
        _startPTS = startPTS;
        _isHeadphonesConnected = isHeadphonesConnected;
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

@implementation VanguardAudioRecorder {
    id<VGAudioRecorderTimeProvider>      _timeProvider;
    id<VGAudioRecorderSessionManager>    _sessionManager;
    id<VGAudioRecorderBackendFactory>    _backendFactory;

    id<VGAudioRecorderBackend> _Nullable _backend;
    NSString                 * _Nullable _activeFilePath;
    double                                _activeStartPTS;

    // YES between a successful activatePlayAndRecord and restorePlayback.
    BOOL _sessionSwitched;
}

- (instancetype)initWithTimeProvider:(nullable id<VGAudioRecorderTimeProvider>)timeProvider
                      sessionManager:(nullable id<VGAudioRecorderSessionManager>)sessionManager
                      backendFactory:(nullable id<VGAudioRecorderBackendFactory>)backendFactory {
    self = [super init];
    if (self) {
        _timeProvider   = timeProvider   ?: [[_VGRealTimeProvider alloc] init];
        _sessionManager = sessionManager ?: [[_VGRealSessionManager alloc] init];
        _backendFactory = backendFactory ?: [[_VGRealBackendFactory alloc] init];
    }
    return self;
}

- (instancetype)init {
    return [self initWithTimeProvider:nil sessionManager:nil backendFactory:nil];
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

    // 4. Read snapshot to compute authoritative start PTS.
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

    // 5. Check headphone route BEFORE switching session (route is stable here).
    BOOL headphones = [_sessionManager isHeadphonesConnected];

    // 6. Switch AVAudioSession → PlayAndRecord.
    NSError *sessErr = nil;
    if (![_sessionManager activatePlayAndRecordWithError:&sessErr]) {
        NSLog(@"[VanguardAudioRecorder] session activation failed: %@", sessErr);
        if (outError) *outError = _makeErrorWithUnderlying(VGRecorderErrorSessionActivation,
                                                           @"AVAudioSession activation failed",
                                                           sessErr);
        return nil;
    }
    _sessionSwitched = YES;

    // 7. Build backend (settings: AAC, 44.1 kHz mono).
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
        [self _cleanupSession];
        if (outError) *outError = _makeErrorWithUnderlying(VGRecorderErrorRecorderInit,
                                                           @"Recorder backend initialisation failed",
                                                           backendErr);
        return nil;
    }

    if (![backend prepareToRecord]) {
        NSLog(@"[VanguardAudioRecorder] prepareToRecord failed");
        [self _cleanupSession];
        [self _setError:outError
                   code:VGRecorderErrorRecorderInit
                message:@"Recorder backend prepareToRecord returned NO"];
        return nil;
    }

    if (![backend record]) {
        NSLog(@"[VanguardAudioRecorder] record failed to start");
        [self _cleanupSession];
        [self _setError:outError
                   code:VGRecorderErrorRecorderInit
                message:@"Recorder backend record returned NO"];
        return nil;
    }

    // 8. Capture state.
    _backend        = backend;
    _activeFilePath = [outputPath copy];
    _activeStartPTS = startPTS;

    NSLog(@"[VanguardAudioRecorder] recording started: path=%@, startPTS=%.6f, headphones=%d",
          outputPath.lastPathComponent, startPTS, headphones);

    return [[VGAudioRecordingStartInfo alloc]
              initWithFilePath:outputPath
                      startPTS:startPTS
           isHeadphonesConnected:headphones];
}

// ── Stop ──────────────────────────────────────────────────────────────────────

- (void)stopRecordingWithCompletion:
    (void (^)(VGAudioRecordingStopInfo * _Nullable, NSError * _Nullable))completion {

    NSAssert([NSThread isMainThread], @"VanguardAudioRecorder: must be called on main thread");
    NSAssert(completion != nil, @"completion must not be nil");

    if (!self.isRecording) {
        [self _cleanupSession];
        completion(nil, _makeError(VGRecorderErrorNotRecording,
                                   @"stopRecording called but no recording is active"));
        return;
    }

    // Capture state before stop.
    NSString *filePath          = [_activeFilePath copy];
    double    startPTS          = _activeStartPTS;
    NSTimeInterval durationSecs = _backend.currentTime;

    [_backend stop];
    _backend        = nil;
    _activeFilePath = nil;
    _activeStartPTS = 0.0;

    [self _cleanupSession];

    NSLog(@"[VanguardAudioRecorder] recording stopped: path=%@, duration≈%.3f",
          filePath.lastPathComponent, durationSecs);

    VGAudioRecordingStopInfo *info =
        [[VGAudioRecordingStopInfo alloc] initWithFilePath:filePath
                                                  startPTS:startPTS
                                           durationSeconds:durationSecs];
    completion(info, nil);
}

// ── Cancel ────────────────────────────────────────────────────────────────────

- (void)cancelRecording {
    NSAssert([NSThread isMainThread], @"VanguardAudioRecorder: must be called on main thread");
    if (_backend) {
        [_backend stop];
        _backend        = nil;
        _activeFilePath = nil;
        _activeStartPTS = 0.0;
        NSLog(@"[VanguardAudioRecorder] recording cancelled");
    }
    [self _cleanupSession];
}

// ── Internals ─────────────────────────────────────────────────────────────────

/// Restores AVAudioSession to Playback exactly once.
- (void)_cleanupSession {
    if (_sessionSwitched) {
        _sessionSwitched = NO;
        [_sessionManager restorePlayback];
    }
}

- (void)_setError:(NSError **)outError code:(VGRecorderError)code message:(NSString *)msg {
    if (outError) *outError = _makeError(code, msg);
}

@end

#endif // VG_USE_V2_GRAPH
