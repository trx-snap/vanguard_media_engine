// VGAudioPlaybackService.m
// vanguard_media_engine — Phase 8.16
//
// Implementation notes:
//   - AVPlayer for simple file-based playback. No AVAudioEngine.
//   - Single active player; load() tears down any prior player.
//   - AVPlayerItem end notification → pause (no auto-loop).
//   - Zero-tolerance seek for accurate positioning.
//   - All public entry points are main-thread only (asserted via NSThread check
//     in DEBUG builds).
//   - Does not touch AVAudioSession. Relies on pre-activated .playback session.

#import "VGAudioPlaybackService.h"

static NSString * const VGAudioPlaybackErrorDomain = @"VGAudioPlaybackService";

// Error codes
typedef NS_ENUM(NSInteger, VGAudioPlaybackErrorCode) {
    VGAudioPlaybackErrorEmptyPath      = 1,
    VGAudioPlaybackErrorFileNotFound   = 2,
    VGAudioPlaybackErrorLoadFailed     = 3,
    VGAudioPlaybackErrorNoAudioTrack   = 4,
};

@implementation VGAudioPlaybackService {
    AVPlayer       *_player;
    id              _endObserver;   // AVPlayerItemDidPlayToEndTimeNotification token
}

// ─── Private helpers ──────────────────────────────────────────────────────────

- (void)_assertMainThread {
#ifdef DEBUG
    NSAssert([NSThread isMainThread],
             @"VGAudioPlaybackService: method called off main thread");
#endif
}

/// Removes end notification observer and releases _player safely.
- (void)_releasePlayer {
    if (_endObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
        _endObserver = nil;
    }
    if (_player) {
        [_player pause];
        [_player replaceCurrentItemWithPlayerItem:nil];
        _player = nil;
    }
}

// ─── Public API ───────────────────────────────────────────────────────────────

- (void)loadWithPath:(NSString *)path
          completion:(void (^)(double, NSError * _Nullable))completion {
    [self _assertMainThread];

    // Validate path.
    if (path.length == 0) {
        NSError *err = [NSError errorWithDomain:VGAudioPlaybackErrorDomain
                                           code:VGAudioPlaybackErrorEmptyPath
                                       userInfo:@{NSLocalizedDescriptionKey: @"path must not be empty"}];
        completion(0.0, err);
        return;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:path];

    // Verify file exists.
    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
        NSError *err = [NSError errorWithDomain:VGAudioPlaybackErrorDomain
                                           code:VGAudioPlaybackErrorFileNotFound
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      [NSString stringWithFormat:@"File not found or unreadable: %@", path]}];
        completion(0.0, err);
        return;
    }

    // Release any existing player.
    [self _releasePlayer];

    // Build asset + player item.
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];

    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"duration", @"tracks"] completionHandler:^{
        // Hop to main thread for all AVPlayer mutations.
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                completion(0.0, nil);
                return;
            }

            // Check loading status.
            NSError *assetError = nil;
            AVKeyValueStatus durationStatus = [asset statusOfValueForKey:@"duration" error:&assetError];
            if (durationStatus == AVKeyValueStatusFailed) {
                NSError *err = [NSError errorWithDomain:VGAudioPlaybackErrorDomain
                                                   code:VGAudioPlaybackErrorLoadFailed
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                              [NSString stringWithFormat:@"Asset load failed: %@",
                                                               assetError.localizedDescription ?: @"unknown"]}];
                completion(0.0, err);
                return;
            }

            // Verify at least one audio track.
            NSArray<AVAssetTrack *> *audioTracks =
                [asset tracksWithMediaType:AVMediaTypeAudio];
            if (audioTracks.count == 0) {
                NSError *err = [NSError errorWithDomain:VGAudioPlaybackErrorDomain
                                                   code:VGAudioPlaybackErrorNoAudioTrack
                                               userInfo:@{NSLocalizedDescriptionKey: @"Asset contains no audio track"}];
                completion(0.0, err);
                return;
            }

            // Duration.
            CMTime duration = asset.duration;
            double durationSeconds = CMTimeGetSeconds(duration);
            if (isnan(durationSeconds) || durationSeconds <= 0.0) {
                durationSeconds = 0.0; // caller receives 0 but no error
            }

            // Create player item and player.
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            strongSelf->_player = [AVPlayer playerWithPlayerItem:item];
            strongSelf->_player.volume = 1.0;

            // Observe playback-end to pause (no auto-loop).
            __weak typeof(strongSelf) weakSelf2 = strongSelf;
            strongSelf->_endObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                            object:item
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification * _Nonnull note) {
                    typeof(weakSelf2) strongSelf2 = weakSelf2;
                    if (strongSelf2) {
                        [strongSelf2 pause];
                        NSLog(@"[VGAudioPlayback] playback reached end — paused.");
                    }
                }];

            NSLog(@"[VGAudioPlayback] loaded: %@ (%.2fs)", path.lastPathComponent, durationSeconds);
            completion(durationSeconds, nil);
        });
    }];
}

- (void)play {
    [self _assertMainThread];
    if (!_player) return;
    [_player play];
}

- (void)pause {
    [self _assertMainThread];
    if (!_player) return;
    [_player pause];
}

- (void)stop {
    [self _assertMainThread];
    if (!_player) return;

    // Seek to zero before releasing.
    [_player pause];
    CMTime zero = kCMTimeZero;
    [_player seekToTime:zero
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero];

    [self _releasePlayer];
    NSLog(@"[VGAudioPlayback] stopped.");
}

- (void)seekToSeconds:(double)seconds completion:(void (^)(void))completion {
    [self _assertMainThread];
    if (!_player) {
        // No player loaded — complete immediately on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion();
        });
        return;
    }

    CMTime target = CMTimeMakeWithSeconds(seconds, 44100);
    [_player seekToTime:target
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished) {
        // AVPlayer invokes this on an arbitrary background thread.
        // Must hop to main before touching any AVPlayer state or
        // signalling Dart (Flutter MethodChannel is main-thread only).
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion();
        });
    }];
}

- (void)setVolume:(float)volume {
    [self _assertMainThread];
    if (!_player) return;
    volume = MAX(0.0f, MIN(1.0f, volume));
    _player.volume = volume;
}

- (double)currentPositionSeconds {
    if (!_player) return 0.0;
    CMTime pos = _player.currentTime;
    if (!CMTIME_IS_VALID(pos) || CMTIME_IS_INDEFINITE(pos)) return 0.0;
    double seconds = CMTimeGetSeconds(pos);
    return isnan(seconds) ? 0.0 : seconds;
}

- (void)dealloc {
    // Safety net — _releasePlayer must be called explicitly, but dealloc
    // handles the case where the plugin is torn down without an explicit stop.
    if (_endObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
        _endObserver = nil;
    }
    // Do not call pause here in dealloc — AVPlayer may not survive the
    // dealloc path safely. Just nil the references.
    _player = nil;
}

@end
