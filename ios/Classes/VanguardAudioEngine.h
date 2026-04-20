// VanguardAudioEngine.h
// Phase 2 — P2-T3: Audio engine protocol (master clock interface)
//
// VanguardFileMediaSource conforms to this protocol for single-clip playback.
// Phase 6+: VanguardMultiTrackMixer conforms for timeline-wide audio mixing.
//
// THE CONTRACT: whoever conforms to this protocol owns the master clock.
// VanguardMetalRenderer asks for `masterClock` via the `_timeProvider` block —
// it never calls CACurrentMediaTime() directly after Phase 2.

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Audio enhancement level — escalates through layers based on device capability.
typedef NS_ENUM(NSInteger, VanguardAudioEnhancementLevel) {
    VanguardAudioEnhancementLevelNone     = 0, ///< Raw audio, no processing
    VanguardAudioEnhancementLevelBasic    = 1, ///< Layer 1: OS session mode only
    VanguardAudioEnhancementLevelEnhanced = 2, ///< Layer 2: CoreML Neural Engine
    VanguardAudioEnhancementLevelFull     = 3, ///< Layer 2 + Layer 3 DSP fallback
};

/// Protocol implemented by the audio subsystem that owns the master clock.
/// Video rendering slaves to this clock — it never uses CACurrentMediaTime in Phase 2+.
@protocol VanguardAudioEngine <NSObject>

// ── Lifecycle ──────────────────────────────────────────────────────────────

/// Start audio playback. Called after `setVideoCallback:` and `start`.
- (void)play;

/// Pause audio playback without releasing resources.
- (void)pause;

/// Seek audio to the specified output-timeline position.
/// Must be called before the corresponding video seek so the clock is correct.
- (void)seekToTime:(CMTime)time;

// ── Mixer ──────────────────────────────────────────────────────────────────

/// Set audio output volume. Range: 0.0–1.0. Thread-safe.
- (void)setVolume:(float)volume;

/// Select the audio enhancement level.
/// May reinstall/remove AVAudioEngine taps. Safe to call any time.
- (void)setEnhancementLevel:(VanguardAudioEnhancementLevel)level;

/// Attach to a timeline for multi-clip mixing (Phase 6+). No-op for single-clip.
- (void)attachToTimeline:(nullable id)timeline;

// ── Master Clock ───────────────────────────────────────────────────────────

/// THE master clock. The video renderer's `_timeProvider` block calls this.
/// For audio playback: derived from `AVAudioPlayerNode.sampleTime / sampleRate`.
/// For video-only / audio not yet started: wall-clock fallback via CACurrentMediaTime.
/// Units: output-timeline seconds (already rate-corrected — no additional scaling needed).
@property (readonly, nonatomic) CMTime masterClock;

@end

NS_ASSUME_NONNULL_END
