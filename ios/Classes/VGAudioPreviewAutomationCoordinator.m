// VGAudioPreviewAutomationCoordinator.m
// Vanguard Media Engine — Audio Slice J

#import "VGAudioPreviewAutomationCoordinator.h"
#import "VGAudioPreviewEnvelopeEvaluator.h"
#import "VGAudioPreviewKeyframeNormalizer.h"

#if VG_USE_V2_GRAPH

/// Volume suppression threshold: only emit setVolume: when the gain
/// changes by more than this amount.
static const float kVGAutomationVolumeThreshold = 1e-6f;
/// Automation polling cadence: 33 ms ≈ 30 fps.
/// The coordinator owns the cadence decision; the timer is generic.
static const NSTimeInterval kVGAutomationTickIntervalSeconds = 0.033;

@interface VGAudioPreviewAutomationCoordinator () {
  id<VGAudioPreviewAutomationTimer> _timer;
  void (^_gainSink)(float volume);

  /// Current normalized envelope, or nil if no keyframe automation is active.
  NSArray<VGAudioPreviewVolumeKeyframe *> *_Nullable _envelope;

  /// Last volume emitted through gainSink; used for change suppression.
  float _lastAppliedVolume;
}
@end

@implementation VGAudioPreviewAutomationCoordinator

- (instancetype)initWithTimer:(id<VGAudioPreviewAutomationTimer>)timer
                     gainSink:(void (^)(float volume))gainSink {
  self = [super init];
  if (self) {
    _timer = timer;
    _gainSink = [gainSink copy];
    _envelope = nil;
    _lastAppliedVolume = -1.0f; // sentinel: no value applied yet
  }
  return self;
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)activateWithRawKeyframes:(nullable NSArray *)rawKeyframes
                   timelineStart:(NSTimeInterval)timelineStart
                    effectiveEnd:(NSTimeInterval)effectiveEnd
                      initialPTS:(NSTimeInterval)initialPTS {
  // Cancel any existing polling so we don't carry over a stale timer.
  [_timer cancel];

  // Normalize raw keyframes.
  NSArray<VGAudioPreviewVolumeKeyframe *> *normalized = nil;
  if (rawKeyframes.count > 0) {
    normalized = [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:rawKeyframes
                                                        timelineStart:timelineStart
                                                         effectiveEnd:effectiveEnd];
  }

  _envelope = normalized;
  _lastAppliedVolume = -1.0f; // reset suppression

  // Apply initial gain if envelope exists.
  // If no envelope, the runtime applies staticVolume directly.
  if (_envelope) {
    float gain = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:_envelope
                                                             atPTS:initialPTS];
    _gainSink(gain);
    _lastAppliedVolume = gain;
  }
}

- (void)reevaluateAtPTS:(NSTimeInterval)pts {
  if (!_envelope)
    return;
  float gain = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:_envelope
                                                           atPTS:pts];
  _gainSink(gain);
  _lastAppliedVolume = gain;
}

- (void)startPollingWithTickBlock:(dispatch_block_t)tickBlock {
  if (!_envelope) {
    // Static descriptor — no automation required.
    return;
  }
  [_timer startWithInterval:kVGAutomationTickIntervalSeconds block:tickBlock];
}

- (void)evaluateAtPTS:(NSTimeInterval)pts {
  if (!_envelope)
    return;
  float gain = [VGAudioPreviewEnvelopeEvaluator evaluateEnvelope:_envelope
                                                           atPTS:pts];
  if (fabsf(gain - _lastAppliedVolume) >= kVGAutomationVolumeThreshold) {
    _gainSink(gain);
    _lastAppliedVolume = gain;
  }
}

- (void)pause {
  // Cancel timer but preserve envelope for same-descriptor resume.
  [_timer cancel];
}

- (void)deactivate {
  // Cancel timer and clear envelope state.
  [_timer cancel];
  _envelope = nil;
  _lastAppliedVolume = -1.0f;
}

- (void)invalidate {
  // Full teardown.
  [_timer cancel];
  _envelope = nil;
  _lastAppliedVolume = -1.0f;
  // Nil out sink to break any remaining block references.
  _gainSink = ^(float v) { (void)v; };
}

// ─── Property ────────────────────────────────────────────────────────────────

- (BOOL)hasActiveEnvelope {
  return _envelope != nil;
}

@end

#endif // VG_USE_V2_GRAPH
