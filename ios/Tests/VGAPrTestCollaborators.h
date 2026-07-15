// VGAPrTestCollaborators.h
// Vanguard Media Engine — Audio Modularity M1
//
// Private test-only mock collaborators and support utilities for
// VanguardAudioPreviewRuntimeTest. Not part of the production API.

#import <XCTest/XCTest.h>
#import <stdatomic.h>
#import <stdint.h>

#import "VGTimelineStateSnapshot.h"
#import "VanguardAudioPreviewRuntime.h"
#import "VGAudioPreviewAutomationTimer.h"
#import <UMF/VGAudioSidecarPlan.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── VGAPr_MockClock
// ──────────────────────────────────────────────────────────

@interface VGAPr_MockClock : NSObject <VGAudioPreviewClock>
@property(nonatomic) NSTimeInterval currentTime;
@end

// ─── VGAPr_MockAutomationTimer
// ──────────────────────────────────────
// Mock automation timer for Slice J tests. Records start/cancel calls and
// allows the test to fire the callback manually via -fireOnce.

@interface VGAPr_MockAutomationTimer : NSObject <VGAudioPreviewAutomationTimer>
@property(nonatomic) NSInteger startCount;
@property(nonatomic) NSInteger cancelCount;
@property(nonatomic) NSTimeInterval lastInterval;
@property(nonatomic, copy, nullable) dispatch_block_t pendingBlock;
- (void)fireOnce;
@end

// ─── VGAPr_MockTimer
// ────────────────────────────────────────────────────────
// Records whether armWithDelay:block: and cancel were called. The test drives
// the timer callback manually via -fireForcefully.

@interface VGAPr_MockTimer : NSObject <VGAudioPreviewTimer>
@property(nonatomic) NSInteger armCount;
@property(nonatomic) NSInteger cancelCount;
@property(nonatomic) NSTimeInterval lastDelay;
@property(nonatomic, copy, nullable) dispatch_block_t pendingBlock;
@property(nonatomic, weak, nullable) VanguardAudioPreviewRuntime *runtime;
- (void)fireForcefully;
@end

// ─── VGAPr_MockFileProvider
// ─────────────────────────────────────────────────── Returns a fake
// AVAudioFile substitute via KVC to avoid touching the real filesystem. In
// practice AVAudioFile cannot be reasonably subclassed, so for tests that need
// file opening to succeed we use a stub subclass.

@interface VGAPr_MockFileProvider : NSObject <VGAudioPreviewFileProvider>
/// When non-nil, returned for any openFileAtURL: call.
@property(nonatomic, strong, nullable) AVAudioFile *stubbedFile;
/// When YES, openFileAtURL: returns nil with an error.
@property(nonatomic) BOOL shouldFail;
/// When YES, openFileAtURL: returns nil with NO error (file missing).
@property(nonatomic) BOOL shouldFailWithNoError;
/// When YES, fileExistsAtURL: returns NO.
@property(nonatomic) BOOL fileDoesNotExist;
@property(nonatomic) NSInteger openCount;
@property(nonatomic) NSInteger existsCount;
@end

// ─── VGAPr_MockEngine
// ─────────────────────────────────────────────────────────

@interface VGAPr_MockEngine : NSObject <VGAudioPreviewEngine>
@property(nonatomic) BOOL shouldFailStart;
@property(nonatomic) NSInteger startCount;
@property(nonatomic) NSInteger stopCount;
@property(nonatomic) NSInteger attachCount;
@property(nonatomic) NSInteger prepareCount;
@property(nonatomic, strong, nullable) AVAudioMixerNode *mixerNode;
@end

// ─── VGAPr_MockPlayer
// ─────────────────────────────────────────────────────────

@interface VGAPr_MockPlayer : NSObject <VGAudioPreviewPlayer>
@property(nonatomic) NSInteger scheduleCount;
@property(nonatomic) NSInteger playCount;
@property(nonatomic) NSInteger stopCount;
@property(nonatomic) float lastVolume;
@property(nonatomic) AVAudioFramePosition lastStartFrame;
@property(nonatomic) AVAudioFrameCount lastFrameCount;
/// When set, the completion block for the last scheduleSegment call is stored
/// here. Tests can call it manually to simulate natural track completion.
@property(nonatomic, copy, nullable)
    AVAudioPlayerNodeCompletionHandler lastCompletionHandler;
@end

// ─── VGAPr_FakeAudioFile
// ────────────────────────────────────────────────────── AVAudioFile cannot be
// trivially constructed without a real file. Instead we create a real 1-frame
// PCM temp file so we can test the real file path.

/// Creates a temporary WAV file with the given frame count and sample rate.
/// The caller is responsible for deleting the file when done.
NSURL *_Nullable VGAPrCreateTempWAVURL(AVAudioFramePosition frames,
                                       double sampleRate);

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
