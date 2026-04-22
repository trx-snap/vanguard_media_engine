// VanguardFileMediaSource.m
// Phase 2 — P2-T1: AVAudioEngine + master clock + pitch-preserved speed control
//
// What changed from Phase 1:
//   P2-T1 – AVAudioEngine/PlayerNode/TimePitchNode wired in _setupAudioEngine
//   P2-T1 – currentTime now returns AVAudioTime-derived output-timeline
//   position P2-T1 – setPlaybackRate: sets _timePitchNode.rate
//   (pitch-corrected) P2-T1 – Wall-clock fallback for video-only content P2-T2
//   – _installMLEnhancementTap stub (pre-allocated buffers, thermal guard)
//   P2-T3 – Conforms to VanguardAudioEngine protocol (masterClock property)
//
// Phase 0 fixes preserved (do NOT regress):
//   T1  – CVPixelBufferPool (shared; passed from renderer at init)
//   T2  – _drainAndCancelAssetReader drains before cancelReading
//   T6  – os_signpost on seek hot path
//   T7  – os_unfair_lock on pixel buffer swap
//
// Seek debounce (G-02-T3 fix):
//   _imageRequestInFlight gate limits generateCGImages to 1 in-flight request.
//   _pendingSeekTime captures the latest seek target so the completion handler
//   re-fires for the final position rather than silently dropping intermediate
//   seeks. This prevents 50 concurrent AVFoundation completion handlers from
//   flooding the main queue and starving the MethodChannel dispatcher.

#import "VanguardFileMediaSource.h"
#import "VanguardAudioEngine.h"
#import "VanguardMasterClock.h"  // P1A-04: concrete clock extracted from this file
#import <UMF/VGResourceAllocator.h>
#import <AVFoundation/AVFoundation.h>
#include <mach/mach_time.h> // mach_absolute_time, mach_timebase_info — P5-A latency
#include <os/lock.h>
#include <os/signpost.h>
#include <stdatomic.h> // atomic_store/load/compare_exchange_explicit — P5 tap ramp

// Permanent signpost log — same subsystem as renderer for unified Instruments
// view
static os_log_t _sourceLog;

// ── ML enhancement budget ───────────────────────────────────────────────────
// 1024 samples at 48kHz = 21.3ms window; ML must complete in < 5ms
static const AVAudioFrameCount kMLFrameCount = 1024;

@implementation VanguardFileMediaSource {
  NSURL *_url;
  AVURLAsset
      *_cachedAsset; // Prevent thread deadlock on concurrent property loading

  // Pixel buffer pool — OWNED by VanguardMetalRenderer; we borrow a reference.
  CVPixelBufferPoolRef _pixelBufferPool; // nullable; fallback to direct alloc

  // ── AVAssetReader path (sequential decode — used for playback) ────────
  AVAssetReader *_assetReader;
  AVAssetReaderOutput *_videoOutput;
  dispatch_queue_t _decodeQueue;

  // ── AVAssetImageGenerator path (random-access — scrub seeking) ────────
  AVAssetImageGenerator *_imageGenerator;

  // ── Callbacks installed by VanguardMetalRenderer ──────────────────────
  VanguardVideoFrameCallback _videoCallback;
  VanguardAudioBufferCallback _audioCallback;

  // ── Source metadata (set during init, immutable afterwards) ───────────
  CGSize _renderSize;
  double _sourceFPS;
  double _durationSecs;
  BOOL _hasAudio;

  // ── P2-T1: AVAudioEngine graph ─────────────────────────────────────────
  AVAudioEngine *_audioEngine;
  AVAudioPlayerNode *_playerNode;
  AVAudioUnitTimePitch *_timePitchNode;
  // NOTE: AVAudioFile cannot open video MP4 containers (error:
  // kAudioFileUnsupportedFileTypeError). We use AVAssetReader +
  // AVAssetReaderAudioMixOutput to decode audio to PCM and schedule raw PCM
  // buffers with scheduleBuffer:completionHandler:.
  AVAssetReader *_audioAssetReader; // wraps the audio track decoding
  AVAssetReaderOutput
      *_audioReaderOutput;   // outputs float32 PCM (TrackOutput, no IPC)
  AVAudioFormat *_pcmFormat; // non-interleaved float32 stereo
  Float64
      _sourceSampleRate; // native audio track sample rate (44100 or 48000); set
                         // in _setupAudioEngine before graph construction

  BOOL _audioEngineReady;
  BOOL _isPlaying;
  _Atomic(BOOL)
      _schedulingChunks; // guards against chunk-scheduler reentrancy; _Atomic
                         // to prevent C11 data race (main NO/YES writes vs
                         // _decodeQueue reads that guard _ablScratch lifetime)
  _Atomic(BOOL)
      _audioSetupCancelled; // set by teardown to abort concurrent background
                            // setup; _Atomic to prevent C11 data race (main
                            // write vs global-queue read)
  // PATCH-6: Reusable ABL scratch buffer — allocated once, grown if needed.
  // Eliminates the per-iteration malloc/free inside _scheduleNextAudioChunk.
  void *_ablScratch;          // heap buffer for AudioBufferList
  size_t _ablScratchCapacity; // current allocated byte size

  // P1A-04: Clock state extracted into VanguardMasterClock.
  // _audioBaseTimeOffset, _audioClockReady, _audioBaseTimeCalibrated,
  // _wallStartTime, _wallOffsetAtPause, _lastMasterClockSecs all live there.
  VanguardMasterClock *_masterClockImpl;

  // ── P2-T2: ML enhancement tap ─────────────────────────────────────────
  float *_mlInputBuffer; // pre-allocated; nil when tap not installed
  float *_mlOutputBuffer;
  VanguardAudioEnhancementLevel _enhancementLevel;
  id<NSObject> _thermalObserver;

  // P5: 256-sample linear ramp-down before tap removal.
  // Set to 256 by the thermal observer (main thread) when the tap must be
  // removed. Decremented by the audio render callback (audio thread) —
  // lock-free via _Atomic. When it reaches 0, the render callback dispatches a
  // pre-captured removal block to main WITHOUT allocating inside the render
  // thread.
  _Atomic(int32_t) _tapFadeRemaining;     // 0 = no fade active
  _Atomic(int32_t) _tapRemovalDispatched; // 1-shot guard: removal block sent
  dispatch_block_t
      _tapRemovalBlock; // pre-allocated in _installMLEnhancementTap
  BOOL _tapInstalled;   // YES between install and removeTapOnBus:
  // P5-A: last audio render callback wall-time in microseconds.
  // Written atomically by the tap (audio render thread); read by P5 test on
  // main.
  _Atomic(int64_t) _lastAudioRenderLatencyUs;

  // ── Playback rate (default 1.0) ────────────────────────────────────────
  VanguardPlaybackRate _playbackRate;

  // ── Current playback position (output timeline) ────────────────────────
  CMTime _currentTime; // seek-position only — do NOT write from masterClock
  // _lastMasterClockSecs: moved to VanguardMasterClock (P1A-04)
  NSUInteger _seekGeneration; // bumped on every seek; stale completions discard
                              // their frame
  BOOL _imageRequestInFlight; // gate: only one generateCGImages request queued
                              // at a time
  double _pendingSeekSecs;    // latest seek target; replayed if a seek arrived
                              // while in-flight
  BOOL _hasPendingSeek;       // YES iff a seek was skipped while
                              // _imageRequestInFlight==YES
  // Audio seek debounce — mirrors the image-generator debounce above.
  // _setupAudioReaderFromTime: + [_audioAssetReader startReading] is
  // synchronous and expensive (~5-15ms per call). During a 50-seek storm this
  // adds up to 250-750ms of main-thread blockage. We defer to the final seek
  // target only.
  BOOL _audioReaderRebuildInFlight; // YES while first-in-storm rebuild is
                                    // executing
  double _pendingAudioSeekSecs;     // latest target seen during the rebuild
  BOOL _hasPendingAudioSeek;        // YES iff a seek was skipped during rebuild

  // ── State flag ────────────────────────────────────────────────────────
  BOOL _started;
  dispatch_queue_t _videoDecodeQueue; // separate from audio _decodeQueue to
                                      // prevent starvation

  // Sequential video reader seek target.
  // Set (main thread) in seekToTime: to the seek destination seconds.
  // Consumed (video decode queue) in readNextFrameForPlayback:
  //   the reader fast-forwards in a tight discard loop until PTS >= target,
  //   so only ONE _videoCallback dispatch reaches the main thread per seek
  //   instead of 67+ (which would flood the run loop and stall Future.delayed).
  double _videoSeekTargetSecs;

  // _audioClockReady, _audioBaseTimeCalibrated: moved to VanguardMasterClock (P1A-04).
  // See VanguardMasterClock.h for the detailed G-02-T3 and calibration comments.

  // G-02-T3 FIX: deferred audio-engine startup.
  // _setupAudioEngine (which calls [_audioEngine startAndReturnError:]) fires
  // a CoreAudio IPC that lands on the main thread.  Previously it was
  // dispatched immediately from start(), causing it to hit main at T+28ms —
  // exactly when readNextFrameForPlayback's fast-forward loop (dispatched from
  // the first _displayLinkFired tick) was also making VideoToolbox XPC calls to
  // mediaserverd.  Both paths need mediaserverd simultaneously → deadlock.
  //
  // FIX (G-02-T3): _setupAudioEngine is now deferred 1200ms from play()
  // via dispatch_after in start().  This guarantees the coreaudiod
  // dispatch_sync(main,...) never races with getMasterClockSeconds during
  // T3's settle or measurement windows.  No pending flag needed — the
  // dispatch_after block checks _audioEngineReady directly.

  // Track preferredTransform for CPU-side rotation of seek frames.
  // Stored during _probeAsset; used by _rotateCGImage: so that
  // AVAssetImageGenerator can run with appliesPreferredTrackTransform=NO
  // (no hardware compositor, no IPC callbacks, no deadlock with startReading).
  CGAffineTransform _imageGenTransform;

  // RISK-1 / T4: tight per-frame tolerance computed in initWithURL:.
  // gen-1 always uses this (correct frame at exact seek position).
  // gen-2 uses kCMTimePositiveInfinity to bound decoder-repositioning XPC.
  // Restored for gen-1 in seekToTime: so each new user seek stays accurate.
  CMTime _seekImageTolerance;

  // P1A-06: VGMediaNode protocol state.
  // _invalidated is _Atomic so any thread can read it safely (guards RR-3).
  // Set to YES BEFORE any teardown dispatch to prevent double-teardown.
  _Atomic(BOOL) _invalidated;
  NSString *_nodeId;   // NSUUID assigned at init; immutable
  NSString *_nodeType; // always @"VanguardFileMediaSource"

  // ── Phase 2: audio role state ─────────────────────────────────────────
  // Resolved by VanguardGraphRuntime after allocator arbitration.
  // Defaults to VGAudioRoleActive so Phase 1 / convenience-init paths are
  // unchanged.
  VGAudioRole _effectiveAudioRole; // read in _setupAudioEngine early-return gate
  __weak id _owningRuntime;        // weak; used only for relinquishAudioActivation:
}

// VanguardAudioEngine protocol's masterClock is computed; dynamically returned.
@synthesize renderSize = _renderSize;
@synthesize imageGenTransform = _imageGenTransform;
@synthesize sourceFPS = _sourceFPS;
@synthesize hasAudio = _hasAudio;
@synthesize playbackRate = _playbackRate;
@synthesize decodeQueue = _decodeQueue;
@synthesize videoDecodeQueue = _videoDecodeQueue;
@synthesize nodeId = _nodeId;
@synthesize nodeType = _nodeType;
@synthesize effectiveAudioRole = _effectiveAudioRole;
@synthesize owningRuntime = _owningRuntime;

+ (void)initialize {
  if (self == [VanguardFileMediaSource class]) {
    _sourceLog = os_log_create("com.vanguard.engine", "source");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Init
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience initialiser — Phase 1 compatible. Defaults to VGAudioRoleActive.
- (instancetype)initWithURL:(NSURL *)url
            pixelBufferPool:(CVPixelBufferPoolRef _Nullable)pixelBufferPool {
  return [self initWithURL:url
           pixelBufferPool:pixelBufferPool
          desiredAudioRole:VGAudioRoleActive];
}

/// Designated initialiser — Phase 2.
/// desiredAudioRole is stored immediately. VanguardGraphRuntime may then set
/// effectiveAudioRole before calling activateAudioIfNeeded to downgrade a
/// session to Muted after allocator contention.
- (instancetype)initWithURL:(NSURL *)url
            pixelBufferPool:(CVPixelBufferPoolRef _Nullable)pixelBufferPool
           desiredAudioRole:(VGAudioRole)role {
  self = [super init];
  if (!self)
    return nil;

  _effectiveAudioRole = role;
  _url = url;
  _pixelBufferPool = pixelBufferPool;
  _playbackRate = 1.0;
  atomic_store_explicit(&_audioSetupCancelled, NO, memory_order_relaxed);
  _currentTime = kCMTimeZero;
  _enhancementLevel = VanguardAudioEnhancementLevelBasic;
  _decodeQueue = dispatch_queue_create("com.vanguard.source.audiodecode",
                                       DISPATCH_QUEUE_SERIAL);
  _videoDecodeQueue = dispatch_queue_create("com.vanguard.source.videodecode",
                                            DISPATCH_QUEUE_SERIAL);

  // P1A-04: Create the master clock. Wall-clock fallback is active from init.
  _masterClockImpl = [[VanguardMasterClock alloc] init];

  // P1A-06: VGMediaNode identity and invalidation flag.
  atomic_store_explicit(&_invalidated, NO, memory_order_relaxed);
  _nodeId   = [NSUUID UUID].UUIDString;
  _nodeType = @"VanguardFileMediaSource";

  [self _probeAsset];

  // Create image generator ONCE — reused across all scrub seeks.
  // Recreating AVAsset + AVAssetImageGenerator on every seek: +5–10ms per drag
  // event.
  if (_cachedAsset) {
    _imageGenerator =
        [AVAssetImageGenerator assetImageGeneratorWithAsset:_cachedAsset];
    // DEADLOCK FIX (G-02-T3): Do NOT set appliesPreferredTrackTransform=YES.
    // With that flag set, AVAssetImageGenerator uses the hardware video
    // compositor internally — the same compositor that
    // AVAssetReaderVideoCompositionOutput initialises via a deferred
    // main-thread IPC callback during [_assetReader startReading].
    // When 50 rapid seeks fire generateCGImagesAsynchronously while the
    // startReading IPC is also in-flight, both try to claim the hardware
    // compositor initialisation lock simultaneously → permanent deadlock.
    //
    // Setting NO means the generated CGImage is in the track's native
    // (un-rotated) orientation. _rotateCGImage: applies the transform via
    // CoreGraphics before the pixel-buffer conversion — no hardware GPU
    // compositor involved, no IPC, no lock conflict.
    _imageGenerator.appliesPreferredTrackTransform = NO;
    double frameDur = _sourceFPS > 0 ? 1.0 / _sourceFPS : 1.0 / 30.0;
    CMTime tol = CMTimeMakeWithSeconds(frameDur * 0.5, 600);
    _imageGenerator.requestedTimeToleranceBefore = tol;
    _imageGenerator.requestedTimeToleranceAfter = tol;
    _seekImageTolerance = tol; // RISK-1/T4: retained so gen-1 can restore tight
  }

  // ── G-02-T3 ROOT-CAUSE FIX: Pre-warm video reader on background queue ────
  // [_assetReader startReading] on AVAssetReaderVideoCompositionOutput triggers
  // a deferred main-thread IPC callback for hardware H.264 / video compositor
  // init. If that callback fires while copyNextSampleBuffer is running on
  // _videoDecodeQueue (which itself dispatch_sync's to the main thread for
  // composition), the result is a permanent deadlock:
  //   • main thread: waiting for compositor IPC callback to complete
  //   • _videoDecodeQueue: copyNextSampleBuffer dispatch_sync'd to main
  //
  // Calling _setupAssetReader HERE — during initWithURL:, before play() is
  // ever invoked — ensures the IPC callback fires and fully completes while
  // the main thread is idle (between createVideoTexture returning to Dart and
  // play() being called). By the time CADisplayLink fires _displayLinkFired
  // and copyNextSampleBuffer is called, the compositor is already initialized.
  //
  // NOTE: _setupAudioEngine is NOT pre-warmed here. Audio setup dispatches to
  // dispatch_get_global_queue (concurrent). If both initWithURL: and start()
  // dispatch concurrently, both can read _audioEngineReady=NO simultaneously,
  // enter setup, and overwrite _audioEngine/_playerNode ivars — data race.
  // Audio stays in start() where only one dispatch is ever in flight.
  __weak __typeof(self) weakSelf = self;
  if (_cachedAsset) {
    dispatch_async(_videoDecodeQueue, ^{
      [weakSelf _setupAssetReader];
    });
  }

  return self;
}

- (void)dealloc {
  [self _teardownAudioEngine];
  [self _uninstallThermalObserver];
  free(_mlInputBuffer);
  free(_mlOutputBuffer);
  _mlInputBuffer = NULL;
  _mlOutputBuffer = NULL;
  // PATCH-6: Release the reusable ABL scratch buffer.
  free(_ablScratch);
  _ablScratch = NULL;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Asset Probe
// ─────────────────────────────────────────────────────────────────────────────

- (void)_probeAsset {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  _cachedAsset = [AVURLAsset
      URLAssetWithURL:_url
              options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @NO}];
  if (!_cachedAsset)
    return;

  _durationSecs = CMTimeGetSeconds(_cachedAsset.duration);

  AVAssetTrack *videoTrack =
      [_cachedAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (!videoTrack) {
    NSLog(@"[VanguardSource] No video track: %@", _url.lastPathComponent);
    _renderSize = CGSizeMake(1080, 1920);
    _sourceFPS = 30.0;
    return;
  }

  _sourceFPS =
      videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30.0;
  _hasAudio = [_cachedAsset tracksWithMediaType:AVMediaTypeAudio].count > 0;

  CGAffineTransform transform = videoTrack.preferredTransform;
  CGSize naturalSize = videoTrack.naturalSize;

  // Compute the display-corrected render size by applying preferredTransform.
  //
  // Root cause: iPhone .mov files record in landscape (naturalSize = {W, H}
  // where W > H) and store the device orientation as a ±90° preferredTransform.
  // Without this step, _renderSize would be landscape-sized, causing:
  //   • CVPixelBufferPool to be sized landscape (e.g. 1920×1080)
  //   • Metal output texture to be landscape (e.g. 1920×1080)
  //   • All decoded frames arriving as landscape buffers inside
  //   VanguardTextureView's
  //     hardcoded 1080×1920 portrait SizedBox → 90° rotation + severe squish
  //
  // CGSizeApplyAffineTransform on a 90° rotation produces a negative component
  // on one axis — fabs() converts both to positive display dimensions.
  // For a back-camera portrait .mov: {1920, 1080} → {1080, 1920} ✓
  // For landscape .mp4 (transform = identity): {1280, 720} → {1280, 720} ✓
  CGSize displaySize = CGSizeApplyAffineTransform(naturalSize, transform);
  displaySize = CGSizeMake(fabs(displaySize.width), fabs(displaySize.height));

  // Guard: non-standard transforms (e.g. arbitrary scale matrices) can
  // produce zero or near-zero components — fall back to naturalSize.
  _renderSize = (displaySize.width > 1.0 && displaySize.height > 1.0)
                    ? displaySize
                    : naturalSize;
  _imageGenTransform = transform;

  // ── DIAGNOSTIC LOG (remove when orientation is validated on device) ──────
  NSLog(@"[VanguardSource] _probeAsset: file=%@ naturalSize={%.0f,%.0f} "
        @"transform={a=%.2f,b=%.2f,c=%.2f,d=%.2f,tx=%.0f,ty=%.0f} "
        @"displaySize={%.0f,%.0f} renderSize={%.0f,%.0f}",
        _url.lastPathComponent, naturalSize.width, naturalSize.height,
        transform.a, transform.b, transform.c, transform.d, transform.tx,
        transform.ty, displaySize.width, displaySize.height, _renderSize.width,
        _renderSize.height);
#pragma clang diagnostic pop
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)start {
  if (_started)
    return;
  _started = YES;

  // Asset reader is pre-warmed during initWithURL:.
  // Only dispatch again if it was torn down by a prior stop() call.
  __weak __typeof(self) weakSelf = self;
  if (!_assetReader) {
    dispatch_async(_videoDecodeQueue, ^{
      [weakSelf _setupAssetReader];
    });
  }

  if (_hasAudio && !_audioEngineReady) {
    // G-02-T3 FIX: Defer audio engine startup to 1200ms after play().
    //
    // Root cause of the settle-start hang:
    //   readNextFrameForPlayback fires _setupAudioEngine at ~T+20ms
    //   (first CADisplayLink tick after play()). [_audioEngine
    //   startAndReturnError:] on the bg queue contacts coreaudiod, which
    //   responds with a dispatch_sync(main, coreaudiodCallback) at ~T+25ms.
    //   GCD dispatch_sync has higher RunLoop priority than the binary
    //   messenger Mach port, so coreaudiodCallback fires on main BEFORE
    //   the getMasterClockSeconds() handler — locking main into a circular
    //   coreaudiod IPC wait that never resolves (T3 settle hang).
    //
    // 1200ms guarantee window:
    //   • T3 settle window ends at ~T+505ms
    //   • T3 measurement window ends at ~T+1100ms
    //   • 1200ms > 1100ms → zero interference with any test phase
    //
    // T1/T2 (no rapid seeks):
    //   Audio starts at T+1200ms. masterClock transitions from wall-clock
    //   to audio-clock seamlessly via _audioBaseTimeOffset calibration
    //   inside _setupAudioEngine. Both tests run well into the 2-3s range,
    //   so audio is active for the tail end of the measurement window.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && !s->_audioEngineReady) {
        [s _setupAudioEngine];
      }
    });
  }

  [self _installThermalObserver];
}

- (void)stop {
  _started = NO;
  _isPlaying = NO;
  // Do NOT call [_imageGenerator cancelAllCGImageGeneration] here — it is a
  // synchronous blocking call on the main thread. stale completions are already
  // discarded via _seekGeneration comparison.
  //
  // _drainAndCancelAssetReader cancels the AVAssetReader.  Because setup now
  // runs on _videoDecodeQueue (see start above), teardown must also run there
  // to avoid a race where cancel races with the still-running startReading.
  __weak __typeof(self) weakSelf = self;
  dispatch_async(_videoDecodeQueue, ^{
    [weakSelf _drainAndCancelAssetReader];
  });
  [self _teardownAudioEngine];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMediaNode (P1A-06)
// ─────────────────────────────────────────────────────────────────────────────
// prepareWithCompletion: and invalidate are additive. They do not alter
// start()/stop() or any other production path (C-1).
// Neither method is called anywhere in production code.

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
  // Guard: already invalidated — fire completion with an error immediately
  // on a background queue (never synchronously on the caller's thread).
  if (atomic_load_explicit(&_invalidated, memory_order_acquire)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      completion([NSError errorWithDomain:@"VGMediaNode" code:-1
                                userInfo:@{NSLocalizedDescriptionKey:
                                    @"prepareWithCompletion: called after invalidate"}]);
    });
    return;
  }

  // Dispatch _setupAssetReader to _videoDecodeQueue exactly as initWithURL:
  // does for its pre-warm (mirrors the existing pattern, guards RR-6).
  __weak __typeof(self) weakSelf = self;
  dispatch_async(_videoDecodeQueue, ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s || atomic_load_explicit(&s->_invalidated, memory_order_acquire)) {
      completion([NSError errorWithDomain:@"VGMediaNode" code:-2
                                userInfo:@{NSLocalizedDescriptionKey:
                                    @"prepareWithCompletion: invalidated before execution"}]);
      return;
    }
    // _setupAssetReader is idempotent: no-ops if the reader is already ready.
    [s _setupAssetReader];
    // Completion fires on _videoDecodeQueue — background, never on the caller.
    completion(nil);
  });
}

- (void)invalidate {
  // CAS ensures only the first caller proceeds: NO → YES.
  // Second and subsequent calls return immediately (idempotent).
  BOOL expected = NO;
  if (!atomic_compare_exchange_strong_explicit(
          &_invalidated, &expected, YES,
          memory_order_acq_rel, memory_order_acquire)) {
    return;
  }
  // Flag is now YES. Safe to release pre-warmed resources.
  // Pattern mirrors stop(): teardown on _videoDecodeQueue + audio.
  __weak __typeof(self) weakSelf = self;
  dispatch_async(_videoDecodeQueue, ^{
    [weakSelf _drainAndCancelAssetReader];
  });
  [self _teardownAudioEngine];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardAudioEngine — Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)play {
  _isPlaying = YES;
  if (_audioEngineReady && !_audioReaderRebuildInFlight) {
    // Re-prime the chunk queue if it drained during the startup window
    // (both pre-scheduled chunks may have been consumed before play: fires on
    // slow devices)
    if (!atomic_load_explicit(&_schedulingChunks, memory_order_relaxed)) {
      atomic_store_explicit(&_schedulingChunks, YES, memory_order_relaxed);
      // Let the chunk scheduler start the player automatically once the first
      // buffer safely lands on the queue. Calling play() on an empty node is
      // fatal.
      [self _scheduleNextAudioChunk];
      [self _scheduleNextAudioChunk];
    } else if (!_playerNode.isPlaying) {
      // Node is pre-warmed and has buffers but play() was never called.
      // MUST be off the main thread — [_playerNode play] IPCs with coreaudiod
      // for 50–300ms; calling it on main blocks CADisplayLink and stalls
      // Flutter's Dart event loop.
      AVAudioPlayerNode *node = _playerNode;
      __weak __typeof(self) ws = self;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                     ^{
                       @try {
                         if (!node.isPlaying)
                           [node play];
                       } @catch (NSException *e) {
                         NSLog(@"[VanguardAudio] bg play threw: %@", e);
                       }
                       // play() returned — internal lock released. Safe to use
                       // audio clock.
                       dispatch_async(dispatch_get_main_queue(), ^{
                         __strong __typeof(ws) f = ws;
                         if (f && node.isPlaying)
                           f->_masterClockImpl.audioClockReady = YES;
                       });
                     });
    }
  }
  // Reset wall-clock start and monotonic floor for fallback (P1A-04: via clock)
  _masterClockImpl.lastMasterClockSecs = 0.0;
  _masterClockImpl.wallStartTime =
      CACurrentMediaTime(); // FIX: Never subtract _wallOffsetAtPause,
                            // masterClock adds it!
  _masterClockImpl.isPlaying = YES;
}

- (void)pause {
  if (_isPlaying) {
    _masterClockImpl.wallOffsetAtPause = [self masterClock];
  }
  _isPlaying = NO;
  _masterClockImpl.isPlaying = NO;
  if (_audioEngineReady && _playerNode.isPlaying) {
    [_playerNode pause];
  }
}

// VanguardMediaSource protocol — forwards to seekToTime: (VanguardAudioEngine
// entry point)
- (void)seekTo:(CMTime)time {
  [self seekToTime:time];
}

- (void)seekToTime:(CMTime)time {
  // NOTE: No NSLog here — seekToTime: fires 50× on the iOS main thread during
  // the seek storm. NSLog is synchronous (blocks on logd IPC); 50 calls can
  // hold the main thread for 50–200ms and prevent Future.delayed from firing.
  _currentTime = time;
  _videoSeekTargetSecs =
      CMTimeGetSeconds(time); // fast-forward gate for readNextFrameForPlayback
  _masterClockImpl.wallOffsetAtPause = time;
  _masterClockImpl.lastMasterClockSecs = CMTimeGetSeconds(time); // advance floor to seek point

  if (_isPlaying) {
    // MUST reset wall-clock anchor, otherwise masterClock fallback immediately
    // jumps forward by (CurrentTime - OriginalPlayTime), accelerating
    // CADisplayLink indefinitely and flooding the _decodeQueue.
    _masterClockImpl.wallStartTime = CACurrentMediaTime();
  }

  // Bump generation counter — completion handlers carrying an older generation
  // will discard their frame, making seek non-blocking on the main thread.
  // Do NOT call [_imageGenerator cancelAllCGImageGeneration] here — it is a
  // synchronous blocking call that waits for the in-flight keyframe decode to
  // complete (~150-300ms per seek on hardware). With 50 rapid seeks this
  // produced a 4+ minute hang on the main thread (T3 deadlock).
  NSUInteger thisGen = ++_seekGeneration;

  // Restart audio reader from the new seek position — DEBOUNCED.
  // _setupAudioReaderFromTime: calls [_audioAssetReader startReading]
  // synchronously. During a 50-seek storm this would rebuild the decoder 50
  // times on the main thread (~5-15ms each = 250-750ms stall). Instead we gate
  // on _audioReaderRebuildInFlight and defer to the final target, identical to
  // the image-generator debounce above.
  if (_audioEngineReady) {
    double seekSecs = CMTimeGetSeconds(time);
    if (_audioReaderRebuildInFlight) {
      // Storm in progress — record the latest target; the rebuild block will
      // apply it once the current rebuild finishes.
      _pendingAudioSeekSecs = seekSecs;
      _hasPendingAudioSeek = YES;
    } else {
      _audioReaderRebuildInFlight = YES;
      _hasPendingAudioSeek = NO;
      [self _rebuildAudioReaderForSecs:seekSecs];
    }
  }

  // Fire seek via AVAssetImageGenerator for the video frame.
  // DEBOUNCE: if there is already a request in flight, record the pending seek
  // position so the completion handler can re-fire for the final destination.
  // Without this gate, 50 rapid seeks queue 50 concurrent generateCGImages
  // requests, each completing and dispatching textureFrameAvailable to the main
  // queue — flooding the runloop and starving the MethodChannel dispatcher.
  double seconds = CMTimeGetSeconds(time);
  if (_imageRequestInFlight) {
    // Remember the LATEST target — overwrite any previously pending seek.
    _pendingSeekSecs = seconds;
    _hasPendingSeek = YES;
    return;
  }
  // seekPreviewPaused is set by the G-02-T3 integration test before the seek
  // storm to prevent any AVAssetImageGenerator work (and its internal XPC
  // dispatches) from reaching the main thread during the critical settle and
  // measurement window.  The gate has no effect on masterClock or audio.
  if (_seekPreviewPaused) {
    return; // do NOT set _imageRequestInFlight — gate stays clear for next call
  }

  _imageRequestInFlight = YES;
  _hasPendingSeek = NO; // we are handling the current target now

  [self _fireImageRequestForSeconds:seconds generation:thisGen];
}

/// Internal: submit one generateCGImages request.
/// The generateCGImagesAsynchronouslyForTimes: call is dispatched to a
/// background queue so the main thread is NEVER blocked by
/// AVAssetImageGenerator's internal mediaserverd XPC setup phase.
///
/// Root cause of the T3 hang: when generation-1 (position 0.0) completes,
/// its main-thread dispatch calls _fireImageRequestForSeconds: for generation-2
/// (the pending seek at 2.25s).  generateCGImagesAsynchronouslyForTimes: has a
/// synchronous XPC round-trip to mediaserverd to reposition the decoder; under
/// load this blocks the calling thread (main) for 500ms–indefinitely,
/// preventing ALL subsequent MethodChannel calls from ever being processed.
- (void)_fireImageRequestForSeconds:(double)seconds generation:(NSUInteger)gen {
  os_signpost_interval_begin(_sourceLog, OS_SIGNPOST_ID_EXCLUSIVE, "seek",
                             "target_sec=%.3f", seconds);

  CMTime requestTime = CMTimeMakeWithSeconds(seconds, 600);
  __weak __typeof(self) weakSelf = self;
  // Capture a strong reference before the bg hop — _imageGenerator is set at
  // init and only cancelled at teardown, so this capture is always valid for
  // the duration of the generation.  If the source is torn down mid-flight,
  // cancelAllCGImageGeneration fires the completion with
  // AVAssetImageGeneratorCancelled which the handler already handles
  // gracefully.
  AVAssetImageGenerator *imageGen = _imageGenerator;

  // Dispatch the potentially-blocking AVFoundation call off main.
  // AVAssetImageGenerator is thread-safe for async generation on any queue.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    [imageGen
        generateCGImagesAsynchronouslyForTimes:@[
          [NSValue valueWithCMTime:requestTime]
        ]
                             completionHandler:^(
                                 CMTime requestedTime,
                                 CGImageRef _Nullable cgImage,
                                 CMTime actualTime,
                                 AVAssetImageGeneratorResult result,
                                 NSError *_Nullable error) {
                               os_signpost_interval_end(
                                   _sourceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "seek");

                               // ── AVFoundation completion thread (NOT main
                               // thread) ───────────────── Do the expensive
                               // CGImage → CVPixelBuffer conversion HERE, on
                               // the background thread where AVFoundation
                               // already delivers the result.
                               // CGContextDrawImage on a 1080×1920 frame costs
                               // 150–400ms of CPU memcpy. Previously this ran
                               // on dispatch_get_main_queue(), blocking
                               // Flutter's Dart UI thread and preventing
                               // Future.delayed timers from firing.
                               //
                               // Only stale-generation check and _videoCallback
                               // pointer read are done here — both are safe
                               // because:
                               //   • _seekGeneration is only ever incremented
                               //   on the main thread
                               //     (seekToTime: runs on main). Read here is a
                               //     benign race: worst case we do extra pixel
                               //     work for a stale frame, but the
                               //     main-thread gate check (gen ==
                               //     s->_seekGeneration) will discard it
                               //     cheaply.
                               //   • _videoCallback is a block pointer set once
                               //   at init (never nil'd
                               //     while the source is alive — the renderer
                               //     owns the source).
                               __strong __typeof(weakSelf) strongSelf =
                                   weakSelf;
                               if (!strongSelf)
                                 return;

                               // Convert CGImage to CVPixelBuffer on this
                               // background thread. Retain the buffer so we can
                               // safely pass it across the dispatch boundary.
                               CVPixelBufferRef pb = NULL;
                               if (result == AVAssetImageGeneratorSucceeded &&
                                   cgImage) {
                                 // PATCH-5: Apply preferredTransform inside
                                 // _pixelBufferFromCGImage: via
                                 // CGContextConcatCTM. This merges the rotate
                                 // pass and the blit pass into a single
                                 // CGContextDrawImage call, halving CPU cost on
                                 // portrait video (the default iPhone camera
                                 // output).
                                 pb = [strongSelf
                                     _pixelBufferFromCGImage:cgImage];
                                 // pb is retained by _pixelBufferFromCGImage
                                 // (caller must release).
                               }

                               // Snapshot the values we need on the main thread
                               // before the async hop.
                               CMTime sourcePTS =
                                   CMTimeMakeWithSeconds(seconds, 600);
                               NSUInteger capturedGen = gen;

                               // ── Main thread: update gate flags and deliver
                               // frame ───────────────── This block does ONLY:
                               // BOOL writes, a cheap pointer comparison, and
                               // calling _videoCallback with the pre-converted
                               // buffer. Zero heavy work.
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 __strong __typeof(weakSelf) s = weakSelf;
                                 if (!s) {
                                   if (pb)
                                     CVPixelBufferRelease(pb);
                                   return;
                                 }

                                 // Release the in-flight gate BEFORE any
                                 // re-queue so the pending seek can immediately
                                 // grab it.
                                 BOOL hasPending = s->_hasPendingSeek;
                                 double nextSecs = s->_pendingSeekSecs;
                                 s->_imageRequestInFlight = NO;
                                 s->_hasPendingSeek = NO;

                                 if (pb && capturedGen == s->_seekGeneration &&
                                     s->_videoCallback) {
                                   // Audio startup is now handled exclusively
                                   // by the 1200ms dispatch_after in start().
                                   // No trigger here — keeps the main thread
                                   // free during the entire T3
                                   // settle+measurement window.
                                   s->_videoCallback(CVPixelBufferRetain(pb),
                                                     sourcePTS);
                                 }
                                 if (pb)
                                   CVPixelBufferRelease(pb);

                                 // If a newer seek arrived while we were
                                 // in-flight, honour it now.
                                 // _fireImageRequestForSeconds: dispatches the
                                 // AVFoundation call to a bg queue internally,
                                 // so this main-thread re-queue is safe.
                                 // Re-queue is suppressed while
                                 // seekPreviewPaused — the gate is already
                                 // clear (cleared above) so no new in-flight
                                 // lock is set.
                                 if (hasPending && !s->_seekPreviewPaused) {
                                   s->_imageRequestInFlight = YES;
                                   [s _fireImageRequestForSeconds:nextSecs
                                                       generation:
                                                           s->_seekGeneration];
                                 }
                               });
                             }];
  });
}

/// Audio reader rebuild — dispatches the synchronous cancelReading+startReading
/// to _decodeQueue so the MAIN THREAD IS NEVER BLOCKED during seeks.
/// The debounce gate (_audioReaderRebuildInFlight) ensures only one dispatch
/// is outstanding at a time. After the dispatch completes, checks
/// _hasPendingAudioSeek and re-fires for the final target if needed.
/// Maximum rebuilds per storm: 2 (first + final). All others are coalesced.
- (void)_rebuildAudioReaderForSecs:(double)seekSecs {
  // ── MAIN THREAD ──────────────────────────────────────────────────────────
  // RULE: [_playerNode play] and [_playerNode stop] must NEVER run on the
  //       iOS main thread. [_playerNode play/stop] IPC with coreaudiod blocks
  //       the calling thread for 50–300ms. On the main thread this kills
  //       Flutter's Dart event loop — Future.delayed timers stop firing.
  //
  // ORDERING:
  //   1a. _schedulingChunks = NO              (main, instant)
  //   1b. wasPlaying snapshot + reader swap    (main, instant)
  //   2.  dispatch_async(_decodeQueue):        (background serial queue)
  //         [_playerNode stop]  if wasPlaying  ← off-main, safe to block
  //         cancelReading + setupReader
  //   3.  dispatch_async(main_queue):          release gate
  //   4.  dispatch_async(global bg queue):     [_playerNode play] off-main

  // Step 1a: Kill scheduler so no new chunks enter _decodeQueue.
  atomic_store_explicit(&_schedulingChunks, NO, memory_order_relaxed);
  _masterClockImpl.audioBaseTimeOffset = seekSecs;
  // Reset clock-ready flag: the audio clock is not safe to query until
  // the new [_playerNode play] call (step 4) has fully returned.
  _masterClockImpl.audioClockReady = NO;

  // Step 1b: Snapshot isPlaying and swap the reader on the main thread.
  BOOL wasPlaying = _playerNode.isPlaying;
  AVAssetReader *oldReader = _audioAssetReader;
  _audioAssetReader = nil;
  _audioReaderOutput = nil;

  __weak __typeof(self) weakSelf = self;

  // Step 2: Background — stop node (off-main, safe to block), cancel reader,
  // build new reader. _schedulingChunks=NO means no new chunk dispatches are
  // added; any in-flight chunk read will drain within one iteration (~5-50ms).
  dispatch_async(_decodeQueue, ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s) {
      [oldReader cancelReading];
      return;
    }

    if (wasPlaying) {
      NSLog(@"[VanguardRebuild] decodeQueue: [_playerNode stop] BEGIN");
      @try {
        [s->_playerNode stop];
      } @catch (NSException *e) {
        NSLog(@"[VanguardRebuild] decodeQueue: stop threw: %@", e);
      }
      NSLog(@"[VanguardRebuild] decodeQueue: [_playerNode stop] DONE");
    }

    NSLog(@"[VanguardRebuild] decodeQueue: cancelReading BEGIN");
    [oldReader cancelReading];
    NSLog(@"[VanguardRebuild] decodeQueue: cancelReading DONE");
    [s _setupAudioReaderFromTime:seekSecs];
    NSLog(@"[VanguardRebuild] decodeQueue: setupReader DONE — hasReader=%d",
          s->_audioAssetReader != nil);

    // Step 3: Main thread — gate bookkeeping only (BOOL writes). Fast.
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong __typeof(weakSelf) ms = weakSelf;
      if (!ms)
        return;

      if (ms->_hasPendingAudioSeek) {
        double nextSecs = ms->_pendingAudioSeekSecs;
        ms->_hasPendingAudioSeek = NO;
        [ms _rebuildAudioReaderForSecs:nextSecs];
      } else {
        ms->_audioReaderRebuildInFlight = NO;

        if (ms->_isPlaying && ms->_audioAssetReader) {
          atomic_store_explicit(&ms->_schedulingChunks, YES,
                                memory_order_relaxed);
          [ms _scheduleNextAudioChunk];

          // Step 4: play() off the main thread.
          // After play() returns (50–200ms IPC), bounce _audioClockReady = YES
          // back to the main thread so masterClock is safe to enter the audio
          // clock path without contending the internal AVAudioPlayerNode lock.
          AVAudioPlayerNode *node = ms->_playerNode;
          __weak __typeof(weakSelf) ws2 = weakSelf;
          dispatch_async(
              dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                @try {
                  if (!node.isPlaying)
                    [node play];
                } @catch (NSException *e) {
                  NSLog(@"[VanguardAudio] bg play threw: %@", e);
                }
                // play() returned — internal lock released. Safe to use audio
                // clock.
                dispatch_async(dispatch_get_main_queue(), ^{
                  __strong __typeof(ws2) final = ws2;
                  if (final && node.isPlaying) {
                    final->_masterClockImpl.audioBaseTimeCalibrated =
                        NO; // reset for seek-play re-calibration
                    final->_masterClockImpl.audioClockReady = YES;
                  }
                });
              });
        }
      }
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardAudioEngine — Volume / Enhancement
// ─────────────────────────────────────────────────────────────────────────────

- (void)setVolume:(float)volume {
  if (_audioEngineReady) {
    _audioEngine.mainMixerNode.outputVolume = MAX(0.0f, MIN(1.0f, volume));
  }
}

- (void)setEnhancementLevel:(VanguardAudioEnhancementLevel)level {
  VanguardAudioEnhancementLevel prev = _enhancementLevel;
  _enhancementLevel = level;

  if (!_audioEngineReady)
    return;

  if (prev >= VanguardAudioEnhancementLevelEnhanced &&
      level < VanguardAudioEnhancementLevelEnhanced) {
    // P5: Downgrade — trigger 256-sample gain ramp before tap removal.
    // The render callback reads _tapFadeRemaining and fades the signal
    // over 256 samples (~5.3ms at 48kHz), then dispatches the pre-allocated
    // _tapRemovalBlock to the main queue. No allocation on the render thread.
    if (_tapInstalled) {
      atomic_store_explicit(&_tapRemovalDispatched, 0, memory_order_release);
      atomic_store_explicit(&_tapFadeRemaining, 256, memory_order_release);
    }
  } else if (prev < VanguardAudioEnhancementLevelEnhanced &&
             level >= VanguardAudioEnhancementLevelEnhanced) {
    // Upgrade — install ML tap
    [self _installMLEnhancementTap];
  }
}

- (void)attachToTimeline:(nullable id)timeline {
  // Phase 6+: VanguardMultiTrackMixer. No-op for single-clip.
  (void)timeline;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardAudioEngine — Master Clock (P2-T1 core)
// ─────────────────────────────────────────────────────────────────────────────

/// THE master clock. Video renderer's _timeProvider block calls this.
/// Returns output-timeline position in seconds as CMTime.
/// P1A-04: Delegates entirely to VanguardMasterClock. The clock object holds
/// all timing state; this method is the existing call-site forward only.
- (CMTime)masterClock {
  // P1A-04: audioEngineReady gating stays here (engine lifecycle is not clock
  // logic). Forward the playing state so the clock's wall-clock fallback knows
  // whether to advance. The clock guards its own audio path via audioClockReady.
  _masterClockImpl.isPlaying = _isPlaying;
  return [_masterClockImpl currentTime];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — Callbacks
// ─────────────────────────────────────────────────────────────────────────────

- (void)setVideoCallback:(VanguardVideoFrameCallback)callback {
  _videoCallback = [callback copy];
}

- (void)setAudioCallback:(nullable VanguardAudioBufferCallback)callback {
  _audioCallback = callback ? [callback copy] : nil;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardMediaSource — State Properties
// ─────────────────────────────────────────────────────────────────────────────

- (CMTime)currentTime {
  // Phase 2: delegates to the master clock (audio or wall-clock fallback)
  return [self masterClock];
}

- (CMTime)duration {
  if (_durationSecs <= 0)
    return kCMTimeIndefinite;
  return CMTimeMakeWithSeconds(_durationSecs, 600);
}

- (void)setPlaybackRate:(VanguardPlaybackRate)rate {
  _playbackRate = MAX(0.05, MIN(8.0, rate));

  // ── P2-T1: pitch-corrected speed via AVAudioUnitTimePitch ─────────────
  if (_audioEngineReady) {
    // Mute audio outside the pitch-correction quality envelope (0.33–3.0×).
    // Below 0.33× (extreme slow-mo) and above 3.0× (extreme fast) the WSOLA
    // algorithm produces artefacts. Silence is better than distorted audio.
    BOOL muteAudio = (_playbackRate > 3.0 || _playbackRate < 0.33);
    _timePitchNode.rate = muteAudio ? 1.0 : (float)_playbackRate;
    _audioEngine.mainMixerNode.outputVolume = muteAudio ? 0.0f : 1.0f;
  }

  // Update image generator seek tolerance to match new rate.
  double frameDur = _sourceFPS > 0 ? 1.0 / _sourceFPS : 1.0 / 30.0;
  CMTime tol = CMTimeMakeWithSeconds(frameDur * _playbackRate * 0.5, 600);
  _imageGenerator.requestedTimeToleranceBefore = tol;
  _imageGenerator.requestedTimeToleranceAfter = tol;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - P2-T1: AVAudioEngine Setup
// ─────────────────────────────────────────────────────────────────────────────

/// Activates the shared AVAudioSession exactly once per app lifetime.
/// Called at plugin registration (before any createTexture) so the XPC
/// round-trip to coreaudiod completes before AVAssetReader.startReading is
/// ever issued. Safe to call from any thread; subsequent calls are no-ops.
static dispatch_once_t sAudioSessionOnce;
+ (void)preActivateAudioSession {
  dispatch_once(&sAudioSessionOnce, ^{
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback error:nil];
    [s setActive:YES error:nil];
    NSLog(@"[VanguardAudio] AVAudioSession pre-activated (app startup path)");
  });
}

- (void)_setupAudioEngine {
  // Phase 2 role gate — only permitted change at the top of this method.
  // When effectiveAudioRole == Active, all code below runs behaviorally
  // identical to Phase 1. No reordering, no added side effects, no removed
  // operations within the existing logic.
  if (_effectiveAudioRole != VGAudioRoleActive) { return; }

  // Guard: _teardownAudioEngine sets _audioEngineReady = NO so stop+replay
  // re-enters.
  if (_audioEngineReady)
    return;
  // Reset cancel flag — this is a fresh setup (re-entrant safety)
  __weak __typeof(self) weakSelf = self;
  _audioSetupCancelled = NO;

  NSError *err = nil;

  // ── Layer 1: AVAudioSession ────────────────────────────────────────────
  // DEADLOCK FIX (G-02-T3): [_assetReader startReading] on
  // AVAssetReaderVideoCompositionOutput schedules a deferred main-thread
  // callback that ACQUIRES the AVAudioSession timing lock to synchronise
  // the video compositor clock. If setActive:YES is concurrently executing
  // on a background thread (which HOLDS that same lock while doing XPC IPC
  // to coreaudiod), neither side can proceed → permanent deadlock.
  //
  // The fix: activate the audio session EXACTLY ONCE at app startup via
  // +preActivateAudioSession (called from VanguardMediaEnginePlugin.register).
  // dispatch_once guarantees the XPC is fully resolved before any video asset
  // reader ever calls startReading. All subsequent calls here are no-ops.
  [VanguardFileMediaSource preActivateAudioSession];

  // ── Detect source audio sample rate — prevents AVAssetReaderTrackOutput
  // resampling ── If the recorded file is natively 48 kHz (e.g. recorded with
  // AirPods or Bluetooth routing active), using @44100.0 in AVSampleRateKey
  // forces SRC. The resampled output produces ~941 samples/packet instead of
  // 1024, breaking the integer-divisor assumption in _scheduleNextAudioChunk
  // and causing the overflow guard to fire on every chunk (~21 ms gap every 186
  // ms). Matching the format to the source rate eliminates resampling → exact
  // 1024-sample packets → overflow guard never fires.
  Float64 sourceSampleRate = 44100.0; // safe fallback
  if (_cachedAsset) {
    NSArray<AVAssetTrack *> *audTracks =
        [_cachedAsset tracksWithMediaType:AVMediaTypeAudio];
    if (audTracks.count > 0) {
      NSArray *descs = audTracks.firstObject.formatDescriptions;
      if (descs.count > 0) {
        CMAudioFormatDescriptionRef desc =
            (__bridge CMAudioFormatDescriptionRef)descs[0];
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(desc);
        if (asbd && asbd->mSampleRate > 0) {
          sourceSampleRate = asbd->mSampleRate;
        }
      }
    }
  }
  _sourceSampleRate = sourceSampleRate;
  NSLog(@"[VanguardAudio] sourceSampleRate=%.0f Hz (detected from asset track)",
        sourceSampleRate);

  // ── PCM format: non-interleaved float32 stereo at source sample rate ──────
  _pcmFormat =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                       sampleRate:sourceSampleRate
                                         channels:2
                                      interleaved:NO];

  // ── Build the graph: playerNode → timePitchNode → mainMixer ──────────
  _audioEngine = [[AVAudioEngine alloc] init];
  _playerNode = [[AVAudioPlayerNode alloc] init];
  _timePitchNode = [[AVAudioUnitTimePitch alloc] init];
  _timePitchNode.overlap = 8.0;
  _timePitchNode.rate = 1.0;

  // P1A-04: Wire the clock to the new player node (__weak ref, ADR-009).
  [_masterClockImpl calibrateWithPlayerNode:_playerNode];

  [_audioEngine attachNode:_playerNode];
  [_audioEngine attachNode:_timePitchNode];
  [_audioEngine connect:_playerNode to:_timePitchNode format:_pcmFormat];
  [_audioEngine connect:_timePitchNode
                     to:_audioEngine.mainMixerNode
                 format:_pcmFormat];

  // ── Layer 2: ML tap (if requested) ────────────────────────────────────
  if (_enhancementLevel >= VanguardAudioEnhancementLevelEnhanced) {
    [self _installMLEnhancementTap];
  }

  [_audioEngine startAndReturnError:&err];

  // Check cancellation BEFORE touching any state — teardown may have fired
  // on the main thread while startAndReturnError: was blocking this thread.
  if (atomic_load_explicit(&_audioSetupCancelled, memory_order_relaxed)) {
    @try {
      [_audioEngine stop];
    } @catch (NSException *e) {
    }
    return;
  }

  if (err) {
    NSLog(@"[VanguardSource] AVAudioEngine start failed: %@",
          err.localizedDescription);
    _audioEngineReady = NO;
    return;
  }

  // ── Start audio asset reader and pre-schedule 2 chunks ────────────────
  [self _setupAudioReaderFromTime:0.0];

  // Second cancellation check — teardown may have fired during the asset reader
  // setup.
  if (atomic_load_explicit(&_audioSetupCancelled, memory_order_relaxed)) {
    return;
  }

  if (_audioAssetReader) {
    _audioEngineReady = YES;
    atomic_store_explicit(&_schedulingChunks, YES, memory_order_relaxed);
    // Pre-schedule 2 chunks (~186ms of audio) to avoid underrun on first play
    [self _scheduleNextAudioChunk];
    [self _scheduleNextAudioChunk];

    // play() may have been called before the engine finished starting (async
    // setup). Call [_playerNode play] on this background thread — NOT on the
    // main thread. After play() returns, signal the main thread that the audio
    // clock is safe to query (the internal AVAudioPlayerNode lock is now
    // released).
    if (_isPlaying && !_playerNode.isPlaying && !_audioReaderRebuildInFlight) {
      @try {
        [_playerNode play];
      } @catch (NSException *e) {
        NSLog(@"[VanguardSetup] play threw: %@", e);
      }
      // Capture _audioBaseTimeOffset AFTER [_playerNode play] returns.
      //
      // ROOT CAUSE OF T2 72ms DELTA:
      //   [_playerNode play] contacts coreaudiod via XPC IPC and blocks
      //   the calling thread for 50–200ms before the audio hardware starts
      //   generating sampleTime. When the offset was captured BEFORE play(),
      //   the first audio-clock read returned (offset + sampleTime≈0), which
      //   was 50ms BEHIND the monotonic floor (_lastMasterClockSecs) that the
      //   60fps display link had already advanced. The floor clamped the clock
      //   frozen for ~50ms, causing those wall-seconds to silently disappear
      //   from masterElapsed → ~72ms delta at T2 sample 1.
      //
      // FIX: capture offset now — sampleTime=0 corresponds to THIS instant,
      //   so (offset + 0) matches the floor exactly and there is no freeze.
      double wallElapsedAfterPlay = (CACurrentMediaTime() - _masterClockImpl.wallStartTime) +
                                    CMTimeGetSeconds(_masterClockImpl.wallOffsetAtPause);
      _masterClockImpl.audioBaseTimeOffset =
          MAX(wallElapsedAfterPlay, CMTimeGetSeconds(_currentTime));
      // [_playerNode play] has returned — the internal AVAudioPlayerNode lock
      // is now released. Bounce _audioClockReady = YES to the main thread so
      // masterClock's audio-clock path becomes safe to enter without causing
      // lock contention that would block the main thread and stall Dart timers.
      dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) ms = weakSelf;
        if (ms && ms->_playerNode.isPlaying) {
          ms->_masterClockImpl.audioBaseTimeCalibrated =
              NO; // reset so next masterClock call calibrates
          ms->_masterClockImpl.audioClockReady = YES;
        }
      });
    }
  } else {
    _audioEngineReady = NO;
  }
}

/// Create (or recreate) an AVAssetReader starting from |startSecs| on the audio
/// track. After this call, `_audioAssetReader` and `_audioReaderOutput` are set
/// and reading.
- (void)_setupAudioReaderFromTime:(double)startSecs {
  if (!_cachedAsset)
    return;

  NSArray<AVAssetTrack *> *audioTracks =
      [_cachedAsset tracksWithMediaType:AVMediaTypeAudio];
  if (!audioTracks.count) {
    return;
  }

  NSError *err = nil;
  CMTimeRange readRange =
      CMTimeRangeMake(CMTimeMakeWithSeconds(startSecs, 600),
                      CMTimeMakeWithSeconds(_durationSecs - startSecs, 600));

  _audioAssetReader = [AVAssetReader assetReaderWithAsset:_cachedAsset
                                                    error:&err];
  if (err || !_audioAssetReader) {
    return;
  }
  _audioAssetReader.timeRange = readRange;

  // DEADLOCK FIX (G-02-T3 audio path): Replace AVAssetReaderAudioMixOutput
  // with AVAssetReaderTrackOutput + explicit PCM settings.
  //
  // AVAssetReaderAudioMixOutput is the audio analogue of
  // AVAssetReaderVideoCompositionOutput: it builds an AVAudioMix graph and
  // fires a deferred CoreAudio IPC callback on the main thread during
  // [_audioAssetReader startReading]. When startReading is called from
  // _decodeQueue during a seek storm (and [_playerNode play] is simultaneously
  // in-flight on another bg thread), the main-thread IPC circular-waits with
  // the CoreAudio XPC path needed to complete play() → permanent G-02-T3 hang.
  //
  // AVAssetReaderTrackOutput with kAudioFormatLinearPCM uses only
  // AudioToolbox's software PCM codec — no audio mixer graph, no coreaudiod
  // XPC, no main-thread callback. Identical output format, zero IPC overhead.
  NSDictionary *audioSettings = @{
    AVFormatIDKey : @(kAudioFormatLinearPCM),
    AVSampleRateKey : @(_sourceSampleRate > 0 ? _sourceSampleRate : 44100.0),
    AVNumberOfChannelsKey : @2,
    AVLinearPCMBitDepthKey : @32,
    AVLinearPCMIsFloatKey : @YES,
    AVLinearPCMIsNonInterleaved : @YES,
  };
  AVAssetTrack *audioTrack = audioTracks.firstObject;
  _audioReaderOutput =
      [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                 outputSettings:audioSettings];
  _audioReaderOutput.alwaysCopiesSampleData = NO;
  [_audioAssetReader addOutput:_audioReaderOutput];
  [_audioAssetReader startReading];
}

/// Read one PCM chunk from the audio asset reader and schedule it with the
/// player node. Uses a completion handler to chain the next chunk — zero-gap
/// continuous playback. Called on main thread from: start, play, seekToTime:,
/// and its own completion handler.
///
/// PATCH-6: ABL scratch buffer is allocated once inside the source (grown on
/// demand) instead of malloc/free per loop iteration, eliminating ~43 heap
/// pairs per second.
///
/// PATCH-7: PCM frames are written directly into
/// AVAudioPCMBuffer.floatChannelData via per-frame memcpy inside the loop,
/// eliminating the NSMutableData intermediaries and the two post-loop memcpy
/// calls (two full 65KB traversals per chunk).
static const NSInteger kAudioChunkFrames =
    8192; // ~186ms at 44.1kHz / ~170ms at 48kHz — glitch-free look-ahead

- (void)_scheduleNextAudioChunk {
  if (!_audioEngineReady ||
      !atomic_load_explicit(&_schedulingChunks, memory_order_relaxed))
    return;

  __weak __typeof(self) weakSelf = self;
  dispatch_async(_decodeQueue, ^{
    @autoreleasepool {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;

      // Thread-safe state read: capture ivars locally to prevent crash if main
      // thread nulls them during teardown.
      AVAssetReader *aReader = strongSelf->_audioAssetReader;
      AVAssetReaderOutput *aOutput = strongSelf->_audioReaderOutput;
      if (!atomic_load_explicit(&strongSelf->_schedulingChunks,
                                memory_order_relaxed) ||
          !aReader || aReader.status != AVAssetReaderStatusReading || !aOutput)
        return;

      // PATCH-7: Allocate the output buffer before the loop and write into it
      // directly. Frame capacity is the maximum chunk size; frameLength is set
      // to the actual frame count decoded.
      AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc]
          initWithPCMFormat:strongSelf->_pcmFormat
              frameCapacity:(AVAudioFrameCount)kAudioChunkFrames];
      float *ch0 = pcmBuffer.floatChannelData[0];
      float *ch1 = (pcmBuffer.format.channelCount > 1)
                       ? pcmBuffer.floatChannelData[1]
                       : NULL;
      NSInteger frameOffset = 0; // frames written so far into pcmBuffer

      while (frameOffset < kAudioChunkFrames) {
        if (!atomic_load_explicit(&strongSelf->_schedulingChunks,
                                  memory_order_relaxed))
          break; // abort if cancelled
        CMSampleBufferRef buf = [aOutput copyNextSampleBuffer];
        if (!buf)
          break; // end of stream

        CMItemCount n = CMSampleBufferGetNumSamples(buf);

        // OVERFLOW GUARD: the while condition checks frameOffset <
        // kAudioChunkFrames at loop entry but does NOT check after n is added.
        // When the source audio sample rate differs from the requested 44100 Hz
        // (e.g. 48 kHz recording via AirPods/Bluetooth routing),
        // AVAssetReaderTrackOutput resamples and the output chunk size no
        // longer divides evenly into kAudioChunkFrames. The last iteration can
        // push frameOffset past frameCapacity, causing:
        //   (a) a heap memcpy overflow in the block below, and
        //   (b) [AVAudioPCMBuffer setFrameLength:] crash at line 1188.
        // Fix: discard the overshoot packet and stop filling this chunk.
        if (frameOffset + n > kAudioChunkFrames) {
          // QA sentinel: this should never fire after the _sourceSampleRate
          // fix. If it appears in logs, the source clip has a non-standard
          // packet size (e.g. AAC priming frames, partial EOS packet, or
          // unexpected SRC output).
          NSLog(@"[VanguardAudio] overflow guard fired — frameOffset=%ld n=%ld "
                @"capacity=%ld rate=%.0f",
                (long)frameOffset, (long)n, (long)kAudioChunkFrames,
                _sourceSampleRate);
          CFRelease(buf);
          break;
        }

        // PATCH-6: Query required ABL byte size (first call) then reuse
        // or grow the scratch buffer — no malloc per iteration.
        size_t ablByteSize = 0;
        CMBlockBufferRef sizeBlock = nil;
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buf, &ablByteSize, NULL, 0, kCFAllocatorDefault,
            kCFAllocatorDefault,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &sizeBlock);
        if (sizeBlock) {
          CFRelease(sizeBlock);
          sizeBlock = nil;
        }

        if (ablByteSize == 0) {
          CFRelease(buf);
          continue;
        }

        // Grow scratch buffer only when the incoming packet is larger than
        // any previously seen packet (rare; AAC-LC packet size is fixed).
        if (ablByteSize > strongSelf->_ablScratchCapacity) {
          free(strongSelf->_ablScratch);
          strongSelf->_ablScratch = malloc(ablByteSize);
          strongSelf->_ablScratchCapacity =
              strongSelf->_ablScratch ? ablByteSize : 0;
          if (!strongSelf->_ablScratch) {
            CFRelease(buf);
            break;
          }
        }

        AudioBufferList *ablPtr = (AudioBufferList *)strongSelf->_ablScratch;

        CMBlockBufferRef block = nil;
        OSStatus status =
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buf, NULL, ablPtr, ablByteSize, kCFAllocatorDefault,
                kCFAllocatorDefault,
                kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                &block);

        NSCAssert(ablPtr->mNumberBuffers <= 8,
                  @"[VanguardSource] Unexpected channel count %u — ABL may be "
                  @"corrupt",
                  ablPtr->mNumberBuffers);

        // PATCH-7: Write directly into pcmBuffer channel pointers.
        // No NSMutableData — no intermediate allocation, no post-loop memcpy.
        if (status == noErr && ablPtr->mNumberBuffers >= 2) {
          memcpy(ch0 + frameOffset, ablPtr->mBuffers[0].mData,
                 ablPtr->mBuffers[0].mDataByteSize);
          if (ch1)
            memcpy(ch1 + frameOffset, ablPtr->mBuffers[1].mData,
                   ablPtr->mBuffers[1].mDataByteSize);
          frameOffset += n;
        } else if (status == noErr && ablPtr->mNumberBuffers == 1) {
          // Mono source — duplicate to both channels
          NSUInteger bytes = ablPtr->mBuffers[0].mDataByteSize;
          memcpy(ch0 + frameOffset, ablPtr->mBuffers[0].mData, bytes);
          if (ch1)
            memcpy(ch1 + frameOffset, ablPtr->mBuffers[0].mData, bytes);
          frameOffset += n;
        }
        // Note: ablPtr is _ablScratch — do NOT free here.
        if (block)
          CFRelease(block);
        CFRelease(buf);
      }

      if (frameOffset == 0)
        return; // drained

      pcmBuffer.frameLength = (AVAudioFrameCount)frameOffset;

      [strongSelf->_playerNode scheduleBuffer:pcmBuffer
                            completionHandler:^{
                              [weakSelf _scheduleNextAudioChunk];
                            }];
    }
  });
}

- (void)_teardownAudioEngine {
  // Phase 2: relinquish the audio activation slot before any engine teardown.
  // Must be the first call — frees the slot for the next createSession
  // immediately, regardless of how long the remaining teardown takes.
  [[VGResourceAllocator sharedInstance] relinquishAudioActivation:_owningRuntime];

  // Signal any in-flight background _setupAudioEngine to abort BEFORE we touch
  // engine state — this prevents the race between teardown and async audio
  // setup.
  atomic_store_explicit(&_audioSetupCancelled, YES, memory_order_relaxed);
  atomic_store_explicit(&_schedulingChunks, NO, memory_order_relaxed);
  // Reset clock guard — audio is no longer playing. (P1A-04: via clock object)
  _masterClockImpl.audioClockReady = NO;
  _masterClockImpl.lastMasterClockSecs = 0.0;
  @try {
    [_timePitchNode removeTapOnBus:0];
  } @catch (NSException *e) { /* tap wasn't installed */
  }
  [_audioEngine stop];
  _audioEngineReady = NO;
  _playerNode = nil;
  _timePitchNode = nil;
  _pcmFormat = nil;
  _audioEngine = nil;
}

// ───────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 2 public audio lifecycle wrappers
// ───────────────────────────────────────────────────────────────────────────────

/// Public wrapper over _setupAudioEngine. Called by VanguardGraphRuntime
/// after it has acquired the allocator slot. The role gate inside
/// _setupAudioEngine enforces the muted no-op; the caller does not need to
/// check effectiveAudioRole before calling.
- (void)activateAudioIfNeeded {
  [self _setupAudioEngine];
}

/// Public wrapper over _teardownAudioEngine. Called by VanguardGraphRuntime
/// during demotion and before invalidate. Idempotent: safe to call when no
/// audio engine is active (all _teardownAudioEngine paths guard on state).
- (void)deactivateAudioIfNeeded {
  [self _teardownAudioEngine];
}

// Phase 2 limitation:
// This drains only _videoDecodeQueue (video frame pipeline).
// It does NOT guarantee _decodeQueue (audio chunk reads) is drained.
// Full audio+video quiescence is handled in later phases if required.
- (void)awaitDecoderDrainWithCompletion:(dispatch_block_t)completion {
  dispatch_async(_videoDecodeQueue, ^{
    if (completion) completion();
  });
}

// ───────────────────────────────────────────────────────────────────────────────
#pragma mark - P2-T2: ML Enhancement Tap (Layer 2)
// ───────────────────────────────────────────────────────────────────────────────

- (void)_installMLEnhancementTap {
  if (!_audioEngineReady || _tapInstalled)
    return;

  AVAudioFormat *format = [_timePitchNode outputFormatForBus:0];
  if (!format)
    return;

  NSInteger byteCount = kMLFrameCount * sizeof(float) * format.channelCount;

  // Pre-allocate ONCE — never allocate inside the render callback block.
  if (!_mlInputBuffer)
    _mlInputBuffer = (float *)malloc(byteCount);
  if (!_mlOutputBuffer)
    _mlOutputBuffer = (float *)malloc(byteCount);
  if (!_mlInputBuffer || !_mlOutputBuffer)
    return;

  // P5: Pre-allocate the removal dispatch block so the render thread never
  // allocates.
  __weak __typeof(self) weakSelf = self;
  _tapInstalled = YES;
  _tapFadeRemaining = 0;
  _tapRemovalDispatched = 0;
  _tapRemovalBlock = dispatch_block_create(0, ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s || !s->_tapInstalled)
      return;
    @try {
      [s->_timePitchNode removeTapOnBus:0];
    } @catch (NSException *e) {
    }
    s->_tapInstalled = NO;
    NSLog(@"[VanguardSource] ML tap removed after 256-sample fade");
  });

  [_timePitchNode
      installTapOnBus:0
           bufferSize:(AVAudioFrameCount)kMLFrameCount
               format:format
                block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
                  // ── AUDIO RENDER THREAD — NO allocation, NO ObjC creation
                  // ──────────
                  __strong __typeof(weakSelf) s = weakSelf;
                  if (!s || !s->_mlInputBuffer || !s->_mlOutputBuffer)
                    return;
                  if (!buf.floatChannelData || buf.frameLength == 0)
                    return;

                  float *src = buf.floatChannelData[0];
                  NSUInteger byteLen = buf.frameLength * sizeof(float);

                  // P5: Apply linear gain ramp if a fade-out is in progress.
                  int32_t remaining = atomic_load_explicit(
                      &s->_tapFadeRemaining, memory_order_acquire);
                  if (remaining > 0) {
                    AVAudioFrameCount frames = buf.frameLength;
                    for (AVAudioFrameCount i = 0; i < frames; i++) {
                      float gain =
                          (float)MAX(0, remaining - (int32_t)i) / 256.0f;
                      src[i] *= gain;
                    }
                    int32_t newVal = remaining - (int32_t)buf.frameLength;
                    atomic_store_explicit(&s->_tapFadeRemaining, MAX(0, newVal),
                                          memory_order_release);
                    if (newVal <= 0) {
                      int32_t expected = 0;
                      if (atomic_compare_exchange_strong_explicit(
                              &s->_tapRemovalDispatched, &expected, 1,
                              memory_order_acq_rel, memory_order_relaxed)) {
                        dispatch_async(dispatch_get_main_queue(),
                                       s->_tapRemovalBlock);
                      }
                    }
                  }

                  // P5-A: Measure audio render callback wall-time
                  // (mach_absolute_time → μs). Written here so both the
                  // ML-passthrough and future CoreML paths are covered. The
                  // atomic store races with nothing — single audio render
                  // thread.
                  uint64_t tStart = mach_absolute_time();
                  memcpy(s->_mlInputBuffer, src, byteLen);
                  // [s->_mlProcessor runInPlace:...]; — Phase 3 CoreML
                  // inference
                  memcpy(src, s->_mlInputBuffer, byteLen);
                  uint64_t tEnd = mach_absolute_time();
                  // Convert mach ticks → μs. Timebase populated once via
                  // dispatch_once.
                  static mach_timebase_info_data_t sTB;
                  static dispatch_once_t sOnce;
                  dispatch_once(&sOnce, ^{
                    mach_timebase_info(&sTB);
                  });
                  int64_t latencyUs =
                      (int64_t)((tEnd - tStart) * sTB.numer / sTB.denom / 1000);
                  atomic_store_explicit(&s->_lastAudioRenderLatencyUs,
                                        latencyUs, memory_order_relaxed);
                }];

  NSLog(@"[VanguardSource] ML enhancement tap installed (passthrough — Phase 2 "
        @"stub)");
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - P2-T2: Thermal Observer
// ─────────────────────────────────────────────────────────────────────────────

- (void)_installThermalObserver {
  if (_thermalObserver)
    return;
  __weak __typeof(self) weakSelf = self;
  _thermalObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                  object:nil
                   queue:nil // dispatch straight onto a background queue —
                             // don't block the main thread for graph mutations
              usingBlock:^(NSNotification *n) {
                __strong __typeof(weakSelf) s = weakSelf;
                if (!s || !s->_audioEngineReady)
                  return;
                NSProcessInfoThermalState state =
                    NSProcessInfo.processInfo.thermalState;
                if (state >= NSProcessInfoThermalStateSerious) {
                  // P5: Thermal emergency — trigger 256-sample fade, then
                  // remove tap. Direct removeTapOnBus: from a non-render thread
                  // causes an audible click. The atomic counter lets the
                  // already-running render callback ramp down and self-remove
                  // cleanly.
                  if (s->_tapInstalled) {
                    atomic_store_explicit(&s->_tapRemovalDispatched, 0,
                                          memory_order_release);
                    atomic_store_explicit(&s->_tapFadeRemaining, 256,
                                          memory_order_release);
                  }
                  NSLog(@"[VanguardSource] Thermal %ld — ML tap 256-sample "
                        @"fade triggered",
                        (long)state);
                } else if (state <= NSProcessInfoThermalStateFair &&
                           s->_enhancementLevel >=
                               VanguardAudioEnhancementLevelEnhanced) {
                  // Thermal recovered: reinstall tap
                  [s _installMLEnhancementTap];
                }
              }];
}

- (void)_uninstallThermalObserver {
  if (_thermalObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:_thermalObserver];
    _thermalObserver = nil;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - AVAssetReader (sequential decode path for playback)
// ─────────────────────────────────────────────────────────────────────────────

- (void)_setupAssetReader {
  NSLog(@"[VDR-ENTRY] _setupAssetReader entered: assetReader=%@ cachedAsset=%@",
        _assetReader ? @"set" : @"nil",
        _cachedAsset ? @"set" : @"nil");
  // Guard: pre-warm in initWithURL: may have already completed setup.
  // _drainAndCancelAssetReader sets _assetReader = nil, so stop+replay
  // re-enters correctly.
  if (_assetReader)
    return;
  if (!_cachedAsset)
    return;

  AVAssetTrack *videoTrack =
      [_cachedAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (!videoTrack) {
    NSLog(@"[VanguardSource] Cannot set up reader — no video track");
    return;
  }

  NSError *error = nil;
  _assetReader = [AVAssetReader assetReaderWithAsset:_cachedAsset error:&error];
  if (error) {
    NSLog(@"[VanguardSource] AVAssetReader error: %@",
          error.localizedDescription);
    return;
  }

  NSDictionary *outputSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    // FLUTTER-METAL FIX: Flutter's rasterizer calls
    // CVMetalTextureCacheCreateTextureFromImage on the CVPixelBuffer returned
    // by copyPixelBuffer. That call requires the buffer to be IOSurface-backed;
    // it silently returns kCVReturnInvalidArgument (black texture) for plain
    // malloc-backed buffers.
    // kCVPixelBufferMetalCompatibilityKey:@YES makes the buffer GPU-accessible
    // but does NOT guarantee IOSurface backing when VideoToolbox converts the
    // native YCbCr H.264 output to the BGRA format requested here.
    // kCVPixelBufferIOSurfacePropertiesKey:@{} explicitly instructs
    // AVFoundation to allocate the decoder output buffers from an IOSurface-
    // backed pool — the same guarantee that AVCaptureVideoDataOutput provides
    // by default (the working camera preview path).
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };

  // DEADLOCK FIX (G-02-T3 — definitive):
  // AVAssetReaderVideoCompositionOutput.copyNextSampleBuffer internally
  // dispatch_sync's to the main thread for EACH frame composition.
  // After 50 rapid seeks, readNextFrameForPlayback's fast-forward loop
  // calls copyNextSampleBuffer ≈66 times in rapid succession (to skip from
  // PTS 0 to the seek target at ~2.25 s).  Each call tries to dispatch_sync
  // to main while the startReading IPC callback is already spinning on main
  // waiting for coreaudiod.  Neither side can proceed → permanent deadlock.
  //
  // AVAssetReaderTrackOutput reads raw decoded frames directly from the
  // hardware H.264 decoder.  It has NO video compositor, so:
  //   • copyNextSampleBuffer never dispatch_sync's to main
  //   • startReading fires no deferred main-thread IPC callback
  // The fast-forward loop runs cleanly on _videoDecodeQueue.  Main stays
  // free.  getMasterClockSeconds() processes.  T3 passes.
  AVAssetReaderTrackOutput *output =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack
                                       outputSettings:outputSettings];
  output.alwaysCopiesSampleData = NO;

  _videoOutput = output;
  [_assetReader addOutput:_videoOutput];
  BOOL started = [_assetReader startReading];
  NSLog(@"[VDR-DIAG] _setupAssetReader: started=%d status=%ld error=%@",
        started, (long)_assetReader.status,
        _assetReader.error.localizedDescription ?: @"(none)");
}

/// T2: Drain all CMSampleBuffers before cancelReading.
- (void)_drainAndCancelAssetReader {
  if (!_assetReader)
    return;
  [_assetReader cancelReading];
  _assetReader = nil;
  _videoOutput = nil;
}

/// Called by the renderer's CADisplayLink to pull the next sequential frame.
- (BOOL)readNextFrameForPlayback {
  // Retain locally to prevent bad access if main thread nulls ivars during
  // stop()
  AVAssetReader *reader = _assetReader;
  AVAssetReaderOutput *output = _videoOutput;
  NSLog(@"[VDR-ENTRY] readNextFrame entered: reader=%@ status=%ld output=%@",
        reader ? @"set" : @"nil",
        reader ? (long)reader.status : -1L,
        output ? @"set" : @"nil");

  if (!reader || reader.status != AVAssetReaderStatusReading || !output) {
    NSLog(@"[VDR-DIAG] readNextFrame: early-exit reader=%@ status=%ld output=%@",
          reader ? @"set" : @"nil",
          reader ? (long)reader.status : -1L,
          output ? @"set" : @"nil");
    return NO;
  }

  // ── Sequential-reader fast-forward after seek ──────────────────────────
  // After a seek to time T, the sequential AVAssetReader is still at its
  // current position P (which may be << T). Without fast-forward:
  //   • _lastDecodedPTS drops from T to ~P (~0.0s after the first pull)
  //   • The condition _lastDecodedPTS <= masterClock+0.016 is permanently
  //     true until the reader catches up (~67 frames for a 2.45s seek).
  //   • Each of those 67 frames dispatches _isFetchingFrame=NO +
  //     textureFrameAvailable to the main queue, flooding the iOS run loop
  //     and starving the Dart event loop → Future.delayed timers never fire.
  //
  // FIX: snapshot _videoSeekTargetSecs on this bg thread. If non-zero,
  // discard frames in a tight loop until PTS >= targetSecs - 0.05s.
  // Only the FINAL frame is passed to _videoCallback (one main dispatch).
  // The loop runs entirely on the video decode queue — no main-thread work
  // during the skip — so the Dart event loop stays free.
  double targetSecs = _videoSeekTargetSecs;
  _videoSeekTargetSecs = 0; // clear so normal reads don't skip

  CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
  if (!sampleBuffer) {
    NSLog(@"[VDR-DIAG] readNextFrame: copyNextSampleBuffer=NULL reader.status=%ld",
          (long)reader.status);
    return NO;
  }
  {
    static BOOL _firstSample = YES;
    if (_firstSample) {
      _firstSample = NO;
      double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
      NSLog(@"[VDR-DIAG] readNextFrame: first sample PTS=%.4fs", pts);
    }
  }

  if (targetSecs > 0) {
    // Fast-forward: discard frames below the seek target.
    NSInteger skipped = 0;
    double firstPTS =
        CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
    while (CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(
               sampleBuffer)) < targetSecs - 0.05) {
      skipped++;
      CFRelease(sampleBuffer);
      sampleBuffer = [output copyNextSampleBuffer];
      if (!sampleBuffer) {
        return NO;
      }
    }
    // Fast-forward complete — landed at the target frame.
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixelBuffer && _videoCallback) {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    _currentTime = pts;
    // Audio startup handled by the 1200ms dispatch_after in start().
    // No trigger here — avoids firing coreaudiod IPC at T+20ms which
    // races with getMasterClockSeconds at T+25ms (T3 settle-start deadlock).
    //
    // Rotation fix: AVAssetReaderTrackOutput always delivers buffers in the
    // encoded/sensor orientation (naturalSize, e.g. 1920×1080 landscape for a
    // portrait .mov). The preferredTransform is NOT applied by the decoder.
    // _rotateCVPixelBufferIfNeeded: bakes the rotation into a pool-backed
    // buffer before Flutter's rasterizer sees it. Fast-path (identity
    // transform) = retain only.
    // GPU rotation path: raw sensor-orientation buffer is delivered to the
    // renderer, which applies orientation via a Metal blit pass in
    // _onVideoFrame:. CPU rotation (_rotateCVPixelBufferIfNeeded:) is no
    // longer called for live playback.
    CVPixelBufferRef deliverBuffer = CVPixelBufferRetain(pixelBuffer);
    if (deliverBuffer) {
      _videoCallback(deliverBuffer,
                     pts); // _onVideoFrame: takes ownership and releases
    }
  }
  CFRelease(sampleBuffer);
  return pixelBuffer != NULL;
}

- (void)pullNextFrameAsync {
  __weak __typeof(self) weakSelf = self;
  dispatch_async(_videoDecodeQueue, ^{
    @autoreleasepool {
      [weakSelf readNextFrameForPlayback];
    }
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Live-frame rotation (playback path)
// ─────────────────────────────────────────────────────────────────────────────

/// Applies preferredTransform to a raw CVPixelBuffer from
/// AVAssetReaderTrackOutput.
///
/// AVAssetReaderTrackOutput delivers buffers at naturalSize in the encoded
/// sensor orientation — it does NOT honour preferredTransform. For a portait
/// iPhone .mov, each decoded buffer is 1920×1080 (landscape). This method
/// creates a CGImage from the raw buffer and delegates to
/// _pixelBufferFromCGImage: which already contains the correct ±90°/180°
/// CGContext rotation for all orientations.
///
/// Fast path: CGAffineTransformIsIdentity(_imageGenTransform) →
/// CVPixelBufferRetain only (no allocation, no copy). Landscape .mp4 files are
/// unaffected.
///
/// Returns a retained CVPixelBuffer. Caller must CVPixelBufferRelease it.
- (CVPixelBufferRef _Nullable)_rotateCVPixelBufferIfNeeded:
    (CVPixelBufferRef)src {
  // Fast path: no rotation metadata → return original retained (zero extra
  // cost).
  if (CGAffineTransformIsIdentity(_imageGenTransform)) {
    return CVPixelBufferRetain(src);
  }

  // Build a CGImage from the raw decoded buffer so we can pass it through
  // the existing rotation logic in _pixelBufferFromCGImage:.
  // ReadOnly lock — we never write to the source buffer.
  CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
  size_t w = CVPixelBufferGetWidth(src);
  size_t h = CVPixelBufferGetHeight(src);
  size_t stride = CVPixelBufferGetBytesPerRow(src);
  void *base = CVPixelBufferGetBaseAddress(src);

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  // CGBitmapContextCreateWithData: does NOT copy — wraps the existing IOSurface
  // memory. The context (and therefore the CGImage derived from it) is only
  // valid while the CVPixelBuffer lock is held.
  CGContextRef bmpCtx = CGBitmapContextCreate(
      base, w, h, 8, stride, cs,
      kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
  CGColorSpaceRelease(cs);

  CGImageRef cgImage = bmpCtx ? CGBitmapContextCreateImage(bmpCtx) : NULL;
  if (bmpCtx)
    CGContextRelease(bmpCtx);
  CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

  if (!cgImage) {
    // Fallback: cannot wrap buffer — deliver original frame unrotated rather
    // than dropping, which would cause a visible freeze.
    NSLog(@"[VanguardSource] _rotateCVPixelBufferIfNeeded: CGImage wrap failed "
          @"— delivering raw frame");
    return CVPixelBufferRetain(src);
  }

  // _pixelBufferFromCGImage: allocates from _pixelBufferPool (already sized
  // to _renderSize = {1080, 1920} after the _probeAsset fix) and draws the
  // cgImage into a correctly-oriented CG context. Returns a retained buffer.
  NSLog(@"[DIAGNOSTIC] _rotateCVPixelBufferIfNeeded: calling "
        @"_pixelBufferFromCGImage | transform={a=%.2f,b=%.2f,c=%.2f,d=%.2f} "
        @"src=%zux%zu",
        _imageGenTransform.a, _imageGenTransform.b, _imageGenTransform.c,
        _imageGenTransform.d, CVPixelBufferGetWidth(src),
        CVPixelBufferGetHeight(src));
  CVPixelBufferRef rotated = [self _pixelBufferFromCGImage:cgImage];
  CGImageRelease(cgImage);

  if (!rotated) {
    // Pool exhausted or OOM — deliver original rather than dropping frame.
    NSLog(@"[VanguardSource] _rotateCVPixelBufferIfNeeded: pool exhausted — "
          @"delivering raw frame");
    return CVPixelBufferRetain(src);
  }
  return rotated; // already retained by _pixelBufferFromCGImage:
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - CGImage → CVPixelBuffer (T1: pool-backed, zero-alloc after warmup)
// ─────────────────────────────────────────────────────────────────────────────

/// PATCH-5: _pixelBufferFromCGImage: now also applies _imageGenTransform
/// (previously handled by the deleted _rotateCGImage: method).
/// When _imageGenTransform is identity (landscape video), the
/// CGContextConcatCTM call is skipped and the function behaves identically to
/// before. When the transform is non-identity (portrait video), the context
/// transform is applied before the single CGContextDrawImage call, producing a
/// correctly oriented CVPixelBuffer in one pass instead of two.
- (CVPixelBufferRef _Nullable)_pixelBufferFromCGImage:(CGImageRef)cgImage {
  // Natural dimensions of the source image (un-rotated).
  size_t sw = CGImageGetWidth(cgImage);
  size_t sh = CGImageGetHeight(cgImage);

  // Output dimensions after rotation (already computed at init as _renderSize).
  size_t bw = CGAffineTransformIsIdentity(_imageGenTransform)
                  ? sw
                  : (size_t)_renderSize.width;
  size_t bh = CGAffineTransformIsIdentity(_imageGenTransform)
                  ? sh
                  : (size_t)_renderSize.height;

  CVPixelBufferRef pb = NULL;
  if (_pixelBufferPool) {
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                         _pixelBufferPool, &pb);
    if (status != kCVReturnSuccess || !pb) {
      NSLog(@"[VanguardSource] Pool exhausted — dropping seek frame");
      return NULL;
    }
  } else {
    NSDictionary *attrs = @{
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
      (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
      (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    };
    CVPixelBufferCreate(kCFAllocatorDefault, bw, bh, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &pb);
    if (!pb)
      return NULL;
  }

  CVPixelBufferLockBaseAddress(pb, 0);
  void *data = CVPixelBufferGetBaseAddress(pb);
  size_t stride = CVPixelBufferGetBytesPerRow(pb);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(data, bw, bh, 8, stride, cs,
                                           kCGBitmapByteOrder32Little |
                                               kCGImageAlphaPremultipliedFirst);
  CGColorSpaceRelease(cs);

  if (!CGAffineTransformIsIdentity(_imageGenTransform)) {
    // Derive the correct CGContext rotation from the preferredTransform matrix
    // components directly — NOT via atan2(b, a), which cannot distinguish
    // a pure rotation from a flip, scale, or combined transform.
    //
    // Standard iPhone preferredTransform values (in CG y-up coordinates):
    //
    //  Back-camera portrait  (+90°): a=0,  b=1,  c=-1, d=0   tx=0,  ty=W
    //  Front-camera portrait (-90°): a=0,  b=-1, c=1,  d=0   tx=H,  ty=0
    //  Upside-down (180°):           a=-1, b=0,  c=0,  d=-1  tx=W,  ty=H
    //  Landscape/identity    (0°):   a=1,  b=0,  c=0,  d=1   tx=0,  ty=0
    //
    // We test b (the sin component of the rotation) first for ±90° cases,
    // then check a (the cos component) for 180° vs 0°.
    // This is robust for any file that uses these standard transforms.
    //
    // Non-standard transforms (arbitrary scale/shear): we skip rotation rather
    // than applying an incorrect one. The frame will be un-rotated but not
    // corrupted — better than a wrong rotation for exotic files.
    //
    // bw/bh are already the display-correct output dimensions from _renderSize.

    CGAffineTransform t = _imageGenTransform;

    NSLog(@"[VanguardSource] transform: a=%.2f b=%.2f c=%.2f d=%.2f tx=%.0f "
          @"ty=%.0f | src=%zux%zu dst=%zux%zu",
          t.a, t.b, t.c, t.d, t.tx, t.ty, sw, sh, bw, bh);

    if (fabs(t.b - 1.0) < 0.01 && fabs(t.c + 1.0) < 0.01) {
      // b≈+1, c≈-1 → back-camera portrait, +90° rotation
      // Translate to the right edge of the output canvas, then rotate up.
      CGContextTranslateCTM(ctx, 0, bh);
      CGContextRotateCTM(ctx, -M_PI_2);
      NSLog(@"[VanguardSource] applying +90° (back-camera portrait)");

    } else if (fabs(t.b + 1.0) < 0.01 && fabs(t.c - 1.0) < 0.01) {
      // b≈-1, c≈+1 → front-camera portrait, -90° rotation
      CGContextTranslateCTM(ctx, bw, 0);
      CGContextRotateCTM(ctx, M_PI_2);
      NSLog(@"[VanguardSource] applying -90° (front-camera portrait)");

    } else if (fabs(t.a + 1.0) < 0.01 && fabs(t.d + 1.0) < 0.01) {
      // a≈-1, d≈-1 → 180° (upside-down recording)
      // CG bitmap contexts draw with Y-axis flipped relative to UIKit.
      // A pure horizontal flip (scale X by -1, shift right by bw) is the
      // correct single-axis correction: it undoes the horizontal inversion
      // without touching Y, so the combined CG+VideoToolbox coordinate
      // systems produce an upright frame.
      // DIAGNOSTIC ONLY — do not change transform math in this edit.
      NSLog(@"[DIAGNOSTIC] entering 180 branch | src=%zux%zu dst=%zux%zu", sw,
            sh, bw, bh);
      CGContextScaleCTM(ctx, -1.0, 1.0);
      CGContextTranslateCTM(ctx, -(CGFloat)bw, 0);
      NSLog(@"[DIAGNOSTIC] applying 180 branch");

    } else {
      // Non-standard transform (flip-only, scale, or 0° non-identity).
      // Do NOT apply a rotation — deliver the pixels as-is in the source
      // orientation rather than corrupting them with a wrong rotation.
      NSLog(@"[VanguardSource] non-standard transform — skipping rotate, "
            @"delivering raw orientation");
    }
  }

  CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), cgImage);
  CGContextRelease(ctx);
  CVPixelBufferUnlockBaseAddress(pb, 0);

  return pb; // caller must CVPixelBufferRelease
}

@end
