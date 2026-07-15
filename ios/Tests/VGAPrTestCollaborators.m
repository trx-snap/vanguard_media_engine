// VGAPrTestCollaborators.m
// Vanguard Media Engine — Audio Modularity M1
//
// Implementation of private test-only mock collaborators and support utilities
// for VanguardAudioPreviewRuntimeTest.

#import "VGAPrTestCollaborators.h"
#import "VanguardAudioPreviewRuntime+Testing.h"

#if VG_USE_V2_GRAPH

// ─── VGAPr_MockClock
// ──────────────────────────────────────────────────────────

@implementation VGAPr_MockClock
- (NSTimeInterval)currentTime {
  return _currentTime;
}
@end

// ─── VGAPr_MockAutomationTimer
// ──────────────────────────────────────────────────

@implementation VGAPr_MockAutomationTimer

- (void)startWithInterval:(NSTimeInterval)interval block:(dispatch_block_t)block {
  _startCount++;
  _lastInterval = interval;
  _pendingBlock = [block copy];
}

- (void)cancel {
  _cancelCount++;
  _pendingBlock = nil;
}

- (void)fireOnce {
  dispatch_block_t block = self.pendingBlock;
  if (block)
    block();
}

@end

// ────────────────────────────────────────────────────────── Records whether
// armWithDelay:block: and cancel were called. The test drives the timer
// callback manually via -fireForcefully.

@implementation VGAPr_MockTimer

- (void)armWithDelay:(NSTimeInterval)delay block:(dispatch_block_t)block {
  _armCount++;
  _lastDelay = delay;
  _pendingBlock = [block copy];
}

- (void)cancel {
  _cancelCount++;
  _pendingBlock = nil;
}

- (void)fireForcefully {
  VanguardAudioPreviewRuntime *rt = self.runtime;
  NSAssert(rt != nil, @"Mock timer requires its owning runtime.");

  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    dispatch_block_t block = self.pendingBlock;
    self.pendingBlock = nil;
    if (block) {
      block();
    }
  }];
}

@end

// ─── VGAPr_MockFileProvider
// ─────────────────────────────────────────────────── Returns a fake
// AVAudioFile substitute via KVC to avoid touching the real filesystem. In
// practice AVAudioFile cannot be reasonably subclassed, so for tests that need
// file opening to succeed we use a stub subclass.

@implementation VGAPr_MockFileProvider

- (nullable AVAudioFile *)openFileAtURL:(NSURL *)url
                                  error:(NSError *_Nullable *_Nullable)error {
  _openCount++;
  if (_shouldFail) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"VGAPr_MockFileProvider"
                     code:1
                 userInfo:@{NSLocalizedDescriptionKey : @"mock failure"}];
    }
    return nil;
  }
  if (_shouldFailWithNoError) {
    return nil;
  }
  return _stubbedFile;
}

- (BOOL)fileExistsAtURL:(NSURL *)url {
  _existsCount++;
  return !_fileDoesNotExist;
}

@end

// ─── VGAPr_MockEngine
// ─────────────────────────────────────────────────────────

@implementation VGAPr_MockEngine

- (instancetype)init {
  self = [super init];
  if (self) {
    _mixerNode = [[AVAudioMixerNode alloc] init];
  }
  return self;
}

- (void)attachNode:(AVAudioNode *)node {
  _attachCount++;
}
- (void)connect:(AVAudioNode *)n1
             to:(AVAudioNode *)n2
         format:(nullable AVAudioFormat *)fmt {
}
- (void)prepare {
  _prepareCount++;
}
- (void)stop {
  _stopCount++;
}
- (AVAudioMixerNode *)mainMixerNode {
  return _mixerNode;
}

- (BOOL)startAndReturnError:(NSError *_Nullable *_Nullable)error {
  _startCount++;
  if (_shouldFailStart) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"VGAPr_MockEngine"
                              code:2
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"mock engine failure"
                          }];
    }
    return NO;
  }
  return YES;
}

@end

// ─── VGAPr_MockPlayer
// ─────────────────────────────────────────────────────────

@implementation VGAPr_MockPlayer

- (void)scheduleSegment:(AVAudioFile *)file
             startingFrame:(AVAudioFramePosition)startFrame
                frameCount:(AVAudioFrameCount)frameCount
                    atTime:(nullable AVAudioTime *)when
    completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
         completionHandler:
             (nullable AVAudioPlayerNodeCompletionHandler)completionHandler {
  _scheduleCount++;
  _lastStartFrame = startFrame;
  _lastFrameCount = frameCount;
  _lastCompletionHandler = completionHandler ? [completionHandler copy] : nil;
}

- (void)play {
  _playCount++;
}
- (void)stop {
  _stopCount++;
}
- (void)setVolume:(float)v {
  _lastVolume = v;
}

@end

// ─── VGAPr_FakeAudioFile
// ────────────────────────────────────────────────────── AVAudioFile cannot be
// trivially constructed without a real file. Instead we create a real 1-frame
// PCM temp file so we can test the real file path.

NSURL *_Nullable VGAPrCreateTempWAVURL(AVAudioFramePosition frames,
                                       double sampleRate) {
  AVAudioFormat *fmt =
      [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate
                                                     channels:1];
  if (!fmt)
    return nil;
  AVAudioPCMBuffer *buf =
      [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                    frameCapacity:(AVAudioFrameCount)frames];
  if (!buf)
    return nil;
  buf.frameLength = (AVAudioFrameCount)frames;

  NSURL *tempURL = [NSURL
      fileURLWithPath:
          [NSTemporaryDirectory()
              stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"vg_apr_test_%lld.wav",
                                             (long long)[[NSDate date]
                                                 timeIntervalSince1970]]]];

  NSError *writeErr = nil;
  AVAudioFile *f = [[AVAudioFile alloc] initForWriting:tempURL
                                              settings:fmt.settings
                                                 error:&writeErr];
  if (!f || writeErr)
    return nil;
  [f writeFromBuffer:buf error:&writeErr];
  if (writeErr)
    return nil;
  return tempURL;
}

#endif // VG_USE_V2_GRAPH
