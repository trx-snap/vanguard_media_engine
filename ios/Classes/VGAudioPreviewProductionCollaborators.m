// VGAudioPreviewProductionCollaborators.m
// Vanguard Media Engine — Audio Slice N
//
// Production AVFoundation adapters: clock, timer, file provider, engine,
// player. Previously defined inline in VanguardAudioPreviewRuntime.m.
// The runtime .m now imports this file instead.

#import "VGAudioPreviewProductionCollaborators.h"

#if VG_USE_V2_GRAPH

#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGProductionAudioPreviewClock ───────────────────────────────────────────

@implementation VGProductionAudioPreviewClock
- (NSTimeInterval)currentTime {
    return CACurrentMediaTime();
}
@end

// ─── VGProductionAudioPreviewTimer ───────────────────────────────────────────

@interface VGProductionAudioPreviewTimer () {
    dispatch_queue_t _targetQueue;
    dispatch_source_t _Nullable _source;
}
@end

@implementation VGProductionAudioPreviewTimer

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _targetQueue = queue;
        _source = nil;
    }
    return self;
}

- (void)armWithDelay:(NSTimeInterval)delay block:(dispatch_block_t)block {
    [self cancel];
    dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _targetQueue);
    uint64_t ns = (uint64_t)(delay * NSEC_PER_SEC);
    dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns),
                              DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
    dispatch_block_t capturedBlock = [block copy];
    dispatch_source_set_event_handler(src, capturedBlock);
    _source = src;
    dispatch_resume(src);
}

- (void)cancel {
    if (_source) {
        dispatch_source_cancel(_source);
        _source = nil;
    }
}

@end

// ─── VGProductionAudioPreviewFileProvider ────────────────────────────────────

@implementation VGProductionAudioPreviewFileProvider

- (nullable AVAudioFile *)openFileAtURL:(NSURL *)url
                                  error:(NSError * _Nullable * _Nullable)error {
    return [[AVAudioFile alloc] initForReading:url error:error];
}

- (BOOL)fileExistsAtURL:(NSURL *)url {
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path];
}

@end

// ─── VGProductionAudioPreviewEngine ──────────────────────────────────────────

@interface VGProductionAudioPreviewEngine () {
    AVAudioEngine *_engine;
}
@end

@implementation VGProductionAudioPreviewEngine

- (instancetype)initWithEngine:(AVAudioEngine *)engine {
    self = [super init];
    if (self) {
        _engine = engine;
    }
    return self;
}

- (void)attachNode:(AVAudioNode *)node {
    [_engine attachNode:node];
}

- (void)connect:(AVAudioNode *)node1
             to:(AVAudioNode *)node2
         format:(nullable AVAudioFormat *)format {
    [_engine connect:node1 to:node2 format:format];
}

- (void)prepare {
    [_engine prepare];
}

- (BOOL)startAndReturnError:(NSError * _Nullable * _Nullable)error {
    return [_engine startAndReturnError:error];
}

- (void)stop {
    [_engine stop];
}

- (BOOL)isRunning {
    return _engine.isRunning;
}

- (AVAudioMixerNode *)mainMixerNode {
    return _engine.mainMixerNode;
}

@end

// ─── VGProductionAudioPreviewPlayer ──────────────────────────────────────────

@interface VGProductionAudioPreviewPlayer () {
    AVAudioPlayerNode *_node;
}
@end

@implementation VGProductionAudioPreviewPlayer

- (instancetype)initWithNode:(AVAudioPlayerNode *)node {
    self = [super init];
    if (self) {
        _node = node;
    }
    return self;
}

- (void)scheduleSegment:(AVAudioFile *)file
             startingFrame:(AVAudioFramePosition)startFrame
                frameCount:(AVAudioFrameCount)frameCount
                    atTime:(nullable AVAudioTime *)when
    completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
         completionHandler:(nullable AVAudioPlayerNodeCompletionHandler)completionHandler {
    [_node scheduleSegment:file
                startingFrame:startFrame
                   frameCount:frameCount
                       atTime:when
       completionCallbackType:callbackType
            completionHandler:completionHandler];
}

- (void)play {
    [_node play];
}

- (void)stop {
    [_node stop];
}

- (void)setVolume:(float)volume {
    _node.volume = volume;
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
