// VanguardAudioPreviewRuntimeTest.h
// Vanguard Media Engine — Audio Modularity M1
//
// Private test-class header for VanguardAudioPreviewRuntimeTest.
// Declares the test class interface with @protected ivars and the helper
// methods needed by independently compiled category files.

#import "VGAPrTestCollaborators.h"
#import "VanguardAudioPreviewRuntime+Testing.h"
#import "VGAudioPreviewTrackDescriptor.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test class interface
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardAudioPreviewRuntimeTest : XCTestCase {
@protected
  VGAPr_MockClock *_clock;
  VGAPr_MockTimer *_timer;
  VGAPr_MockAutomationTimer *_automationTimer;
  VGAPr_MockFileProvider *_fileProvider;
  VGAPr_MockEngine *_engine;
  VGAPr_MockPlayer *_player;
  VGTimelineStateSnapshot _stubbedSnapshot;
}

/// Mutable snapshot returned by the provider.
@property(nonatomic, assign) VGTimelineStateSnapshot stubbedSnapshot;

/// Builds a runtime with lifecycle epoch 1.
- (VanguardAudioPreviewRuntime *)makeRuntime;

/// Builds a runtime with the specified lifecycle epoch.
- (VanguardAudioPreviewRuntime *)makeRuntimeWithEpoch:(uint64_t)epoch;

/// Builds a valid music track dictionary.
- (NSDictionary<NSString *, id> *)trackDictWithStartTime:(double)start
                                                 duration:(double)duration
                                                   volume:(double)volume;

/// Prepares a runtime with a real temp WAV file. Returns nil if temp WAV
/// creation fails.
- (nullable VanguardAudioPreviewRuntime *)
    makePreparedRuntimeWithTrackStart:(double)start
                             duration:(double)duration
                           sampleRate:(double)sr
                         fileDuration:(double)fileDur
                     timelineDuration:(double)tlDur
                               result:(VGAudioPreviewPreparationResult *)
                                          outResult;

/// Synchronously waits for an expectation with a short timeout.
- (void)waitFor:(NSTimeInterval)seconds;

/// Invalidates a runtime and waits for the async completion block.
- (void)invalidateAndWait:(VanguardAudioPreviewRuntime *)rt;

/// Builds an original-role track dictionary.
- (NSDictionary<NSString *, id> *)originalTrackDictWithId:(NSString *)tid
                                                startTime:(double)start
                                                 duration:(double)dur
                                                   volume:(double)vol
                                                      url:(NSString *)path;

/// Builds a music-role track dictionary with a custom id and URL.
- (NSDictionary<NSString *, id> *)musicTrackDictWithId:(NSString *)tid
                                             startTime:(double)start
                                              duration:(double)dur
                                                volume:(double)vol
                                                   url:(NSString *)path;

/// Builds a track dictionary with volumeKeyframes.
- (NSDictionary<NSString *, id> *)trackDictWithId:(NSString *)tid
                                             role:(NSString *)role
                                        startTime:(double)start
                                         duration:(double)dur
                                           volume:(double)vol
                                              url:(NSString *)path
                                       keyframes:(nullable NSArray *)keyframes;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
