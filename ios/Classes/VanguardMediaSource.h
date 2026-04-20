// VanguardMediaSource.h
// Phase 1 — P1-T1: Core media source abstraction
//
// This protocol decouples the Metal renderer from any specific decode path.
// All concrete sources (file, camera, image) implement this interface.
// The renderer never knows what kind of source it is reading from.
//
// Design rules:
//   • Video callback fires on the source's internal decode queue (not main thread)
//   • Audio callback fires on AVAudioEngine render thread — NEVER allocate inside it
//   • seekTo: must be a no-op on live sources (camera); never assert on this
//   • stop: must be idempotent — safe to call multiple times
//   • currentTime is audio-driven when audio is present; wall-clock otherwise

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// The playback rate for this source segment. Default: 1.0 (normal speed).
/// Range: [0.05, 8.0]. Values outside this range are clamped by the engine.
typedef double VanguardPlaybackRate;

/// Callback fired by the source for each decoded video frame.
/// @param frame  Metal-compatible CVPixelBufferRef. Callee MUST NOT retain beyond the block.
/// @param pts    Presentation timestamp in the output timeline.
typedef void (^VanguardVideoFrameCallback)(CVPixelBufferRef frame, CMTime pts);

/// Callback fired by the source for each decoded audio buffer.
/// @param buf    AudioBufferList filled with PCM samples.
/// @param pts    Audio presentation timestamp.
/// @return YES if the buffer was filled; NO if source has no audio (video-only).
typedef BOOL (^VanguardAudioBufferCallback)(AudioBufferList * _Nonnull buf, CMTime pts);

// ─────────────────────────────────────────────────────────────────────────────

@protocol VanguardMediaSource <NSObject>

/// Begin producing frames. Safe to call multiple times (idempotent when already started).
- (void)start;

/// Stop producing frames. Must be idempotent — safe to call multiple times or from
/// any thread. Must not block. Must complete any in-flight callback before returning.
- (void)stop;

/// Seek to a specific time in the source content.
/// Camera sources MUST implement this as a no-op (they have no concept of position).
/// File sources restart the AVAssetReader from the new position.
/// Thread: may be called from main or from the Dart isolate thread.
- (void)seekTo:(CMTime)time;

/// Install the video frame callback. Must be called before start.
/// The callback fires on the source's internal decode queue — NOT the main thread.
- (void)setVideoCallback:(VanguardVideoFrameCallback)callback;

/// Install the audio buffer callback. Must be called before start.
/// Returns YES per invocation if source has audio; NO for video-only sources.
/// Pass nil to remove the callback (stops audio production).
- (void)setAudioCallback:(nullable VanguardAudioBufferCallback)callback;

/// The current playback position in the source's output timeline.
/// Audio-driven when AVAudioEngine is playing; wall-clock fallback otherwise.
/// Thread-safe — may be called from any thread.
@property (readonly, nonatomic) CMTime currentTime;

/// Total duration of this source. kCMTimeIndefinite for live/camera sources.
@property (readonly, nonatomic) CMTime duration;

/// The playback rate for this source. 1.0 = normal, 0.5 = slow-mo, 2.0 = fast.
/// Setting this adjusts both the video seek rate and the audio AVAudioUnitTimePitch node.
@property (nonatomic) VanguardPlaybackRate playbackRate;

@end

NS_ASSUME_NONNULL_END
