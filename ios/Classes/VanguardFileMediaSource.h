// VanguardFileMediaSource.h
// Phase 2 — P2-T1/T3: File-based media source with AVAudioEngine master clock
//
// Conforms to:
//   VanguardMediaSource — video frame callbacks, seek, rate control
//   VanguardAudioEngine — master clock, play/pause, volume, enhancement level
//
// Phase 1: wall-clock _timeProvider → NOW Phase 2: AVAudioTime master clock
// Phase 3 adds: VanguardCameraMediaSource (zero changes to this file)
//
// PHASE 2 MIGRATION STATE — temporary hybrid owner.
// Owns: video decode, audio engine (conditional on effectiveAudioRole),
//       master clock, seek debounce.
// Phase 3 splits this into VGFileVideoSourceNode + VGAudioPlayerSinkNode.
// See migration inventory row 1. Do not add new responsibilities here.

#import "VanguardMediaSource.h"
#import "VanguardAudioEngine.h"
#import "VanguardPlaybackTypes.h"   // VGAudioRole — shared enum (single definition)
#import <UMF/VGMediaNode.h>
#import <UMF/VGMasterClock.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// File-based media source. Decodes MP4/MOV/M4V using AVAssetReader (playback)
/// and AVAssetImageGenerator (scrub seeking). Owns an AVAudioEngine subgraph
/// whose AVAudioPlayerNode provides the master clock for video synchronisation.
/// When effectiveAudioRole == Muted the audio engine is not started and the
/// source runs on the wall-clock fallback path.
@interface VanguardFileMediaSource : NSObject <VanguardMediaSource, VanguardAudioEngine, VGMediaNode, VGMasterClock>

/// Designated initialiser — preferred for Phase 2 multi-instance use.
/// @param url               Local file URL (must be reachable while source is active)
/// @param pixelBufferPool   Shared pool from the renderer — source allocates decode buffers from it
/// @param role              Desired audio role; passed from VanguardGraphRuntime after allocator arbitration
- (instancetype)initWithURL:(NSURL *)url
            pixelBufferPool:(CVPixelBufferPoolRef _Nullable)pixelBufferPool
           desiredAudioRole:(VGAudioRole)role NS_DESIGNATED_INITIALIZER;

/// Convenience initialiser — defaults to VGAudioRoleActive (Phase 1 compatible).
/// @param url               Local file URL
/// @param pixelBufferPool   Shared pool from the renderer
- (instancetype)initWithURL:(NSURL *)url
            pixelBufferPool:(CVPixelBufferPoolRef _Nullable)pixelBufferPool;

- (instancetype)init NS_UNAVAILABLE;

/// Natural render size (after applying preferredTransform rotation).
/// Valid after init. Used by the renderer to allocate the output texture.
@property (readonly, nonatomic) CGSize renderSize;

/// The raw preferredTransform from the video track.
/// Used by VanguardMetalRenderer to derive the GPU rotation index.
@property (readonly, nonatomic) CGAffineTransform imageGenTransform;

/// Per-track frame rate (nominalFrameRate). Used to scale seek tolerance.
@property (readonly, nonatomic) double sourceFPS;

/// Whether the source asset has an audio track.
/// If NO, masterClock uses wall-clock fallback.
@property (readonly, nonatomic) BOOL hasAudio;

/// PATCH-8: Shared CVPixelBufferPool from the renderer.
/// Set by VanguardMetalRenderer after initWithSource: creates the pool.
/// When non-nil, seek frames are allocated from this pool instead of
/// calling CVPixelBufferCreate, eliminating one VM allocation per seek frame.
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;

// ── Phase 2 audio role ─────────────────────────────────────────────────────

/// Effective audio role resolved by VanguardGraphRuntime after allocator
/// arbitration. Must be set BEFORE activateAudioIfNeeded is called.
/// When VGAudioRoleMuted, _setupAudioEngine returns immediately at its first line.
@property (nonatomic, assign) VGAudioRole effectiveAudioRole;

/// Weak back-reference to the owning VanguardGraphRuntime.
/// Used ONLY so _teardownAudioEngine can call relinquishAudioActivation:
/// on the correct runtime. Migration glue — removed when VGAudioPlayerSinkNode
/// is extracted in Phase 3. Must not be used for coordination or ownership.
@property (nonatomic, weak, nullable) id owningRuntime;

// ── Sequential decode ──────────────────────────────────────────────────────

/// Pull the next sequential frame from AVAssetReader and fire the videoCallback.
/// Called by VanguardMetalRenderer on the CADisplayLink callback (main thread).
/// Returns YES if a frame was decoded; NO if the reader is exhausted.
- (BOOL)readNextFrameForPlayback;

/// Asynchronous wrapper for `readNextFrameForPlayback` that strictly serialises
/// AVAssetReader requests to prevent global-queue race condition deadlocks.
- (void)pullNextFrameAsync;

// ── Teardown synchronization ───────────────────────────────────────────────

/// The serial GCD queue used for audio chunk reads and audio asset reader operations.
/// NOT the queue on which _videoCallback fires. Do not use this for filter chain barriers.
@property (readonly, nonatomic) dispatch_queue_t decodeQueue;

/// The serial GCD queue on which _videoCallback (and therefore _onVideoFrame:) executes.
/// replaceFilterChain: MUST dispatch_barrier_async on THIS queue to serialise
/// _filterChain writes against concurrent reads inside _onVideoFrame:.
/// Using decodeQueue for filter chain barriers is incorrect — it is a different queue.
@property (readonly, nonatomic) dispatch_queue_t videoDecodeQueue;

// ── Phase 2 audio lifecycle wrappers (required Phase 2 source contract) ────
// VanguardGraphRuntime calls these public methods.
// MUST NOT call _setupAudioEngine / _teardownAudioEngine directly from outside.

/// Activates the audio engine if effectiveAudioRole == Active. No-op otherwise.
/// Caller (VanguardGraphRuntime) must have already acquired the allocator slot.
- (void)activateAudioIfNeeded;

/// Deactivates the audio engine and relinquishes the allocator slot.
/// Idempotent. Safe to call when no engine is active.
- (void)deactivateAudioIfNeeded;

/// Drains pending decode work then fires completion on a background queue.
/// Used by VanguardGraphRuntime.invalidateAsync to safely await teardown.
/// MUST NOT access _videoDecodeQueue directly from outside the source.
- (void)awaitDecoderDrainWithCompletion:(dispatch_block_t)completion;

// ── App-startup pre-activation ─────────────────────────────────────────────

/// Activates AVAudioSession (setCategory:Playback + setActive:YES) exactly once
/// per app lifetime using dispatch_once. Must be called from plugin registration
/// (on a bg queue) before any video is loaded. This guarantees the coreaudiod
/// XPC round-trip completes before AVAssetReader.startReading fires its own
/// deferred main-thread callback, eliminating the audio-session-lock deadlock
/// that causes G-02-T3 to hang at settle-start.
+ (void)preActivateAudioSession;

// ── Test-only seek-preview gate ────────────────────────────────────────────

/// When YES, all calls to _fireImageRequestForSeconds: are suppressed — no
/// AVAssetImageGenerator work is dispatched, and no internal AVFoundation XPC
/// can reach the main thread.  Set to YES before a seek storm (G-02-T3) and
/// NO after measurement completes.  Has no effect on masterClock or playback.
@property (nonatomic) BOOL seekPreviewPaused;

@end

NS_ASSUME_NONNULL_END
