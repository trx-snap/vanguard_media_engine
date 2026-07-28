// VGAudioPreviewFileResolver.m
// Vanguard Media Engine — S-P2 MOV original-audio repair
//
// Implementation of VGAudioPreviewFileResolver.
// See header for architecture and threading model.

#import "VGAudioPreviewFileResolver.h"

#if VG_USE_V2_GRAPH

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

// ─── File-container category test ────────────────────────────────────────────
//
// Returns YES if |url| points to a file that contains a video track (i.e. an
// audiovisual container such as MOV or MP4). AVURLAsset.tracksWithMediaType
// is used synchronously here because we run on a private serial queue, never
// on the main thread. The call is documented as synchronous for local files.

static BOOL VGURLIsAudiovisualContainer(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset assetWithURL:url];
    return [asset tracksWithMediaType:AVMediaTypeVideo].count > 0;
}

// ─── VGAudioPreviewFileResolver ──────────────────────────────────────────────

@implementation VGAudioPreviewFileResolver {
    // Private serial queue for extraction work.
    dispatch_queue_t _resolverQueue;

    // Temporary directory that owns all extracted CAF files.
    // Created in init; deleted recursively in _removeTemporaryDirectory.
    NSURL *_Nullable _tempDirURL;

    // Atomic cancellation flag. Set in cancelAndCleanupWithCompletion:.
    // The extraction loop checks this per-sample-buffer.
    _Atomic(BOOL) _cancelled;

    // Guards _cleanupComplete and _cleanupWaiters.
    dispatch_semaphore_t _cleanupSemaphore;

    // YES after cancelAndCleanupWithCompletion: has finished cleanup.
    BOOL _cleanupComplete;

    // Waiters queued while cleanup is in progress (race with
    // a second cancelAndCleanupWithCompletion: call from another thread).
    NSMutableArray<dispatch_block_t> *_cleanupWaiters;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _resolverQueue = dispatch_queue_create(
            "com.vanguard.audio.preview.fileResolver",
            DISPATCH_QUEUE_SERIAL);

        atomic_init(&_cancelled, NO);
        _cleanupComplete = NO;
        _cleanupWaiters = [NSMutableArray new];
        // Use a binary semaphore to synchronise cleanup state inspection
        // from different queues. Initialised to 1 (unlocked).
        _cleanupSemaphore = dispatch_semaphore_create(1);

        // Create a unique temporary directory for extracted CAFs.
        NSURL *tmpBase = [NSURL fileURLWithPath:NSTemporaryDirectory()
                                    isDirectory:YES];
        NSString *uuid = [NSUUID UUID].UUIDString;
        _tempDirURL = [tmpBase URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"vg_apr_%@", uuid]
                                              isDirectory:YES];
        NSError *mkdirErr = nil;
        [[NSFileManager defaultManager]
            createDirectoryAtURL:_tempDirURL
     withIntermediateDirectories:YES
                      attributes:nil
                           error:&mkdirErr];
        if (mkdirErr) {
            NSLog(@"[VGAudioPreviewFileResolver] failed to create temp dir: %@",
                  mkdirErr.localizedDescription);
            _tempDirURL = nil;
        }
    }
    return self;
}

- (void)dealloc {
    // Safety net: ensure cleanup on dealloc even without an explicit call.
    [self _removeTempDirectoryIfNeeded];
}

// ─── Public: resolvePlan:completion: ─────────────────────────────────────────

- (void)resolvePlan:(nullable VGAudioSidecarPlan *)plan
         completion:(void (^)(VGAudioSidecarPlan *_Nullable resolvedPlan))completion {
    NSParameterAssert(completion != nil);

    // No plan → silent passthrough.
    if (!plan || plan.tracks.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
        return;
    }

    dispatch_async(_resolverQueue, ^{
        [self _resolveTracksInPlan:plan completion:completion];
    });
}

// ─── Public: cancelAndCleanupWithCompletion: ─────────────────────────────────

- (void)cancelAndCleanupWithCompletion:(dispatch_block_t)completion {
    NSParameterAssert(completion != nil);

    // Set cancel flag atomically. The extraction loop will see this on its
    // next iteration and terminate.
    atomic_store(&_cancelled, YES);

    // Check whether cleanup is already done or in progress.
    dispatch_semaphore_wait(_cleanupSemaphore, DISPATCH_TIME_FOREVER);
    if (_cleanupComplete) {
        dispatch_semaphore_signal(_cleanupSemaphore);
        dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    [_cleanupWaiters addObject:[completion copy]];
    dispatch_semaphore_signal(_cleanupSemaphore);

    // Dispatch cleanup work to the resolver queue. Because the queue is
    // serial, this block will only run after any in-flight extraction has
    // exited (or yields immediately if the queue is idle).
    dispatch_async(_resolverQueue, ^{
        // Remove the temporary directory (contains partial and completed CAFs).
        [self _removeTempDirectoryIfNeeded];

        // Transition to complete and drain waiters on main.
        dispatch_semaphore_wait(self->_cleanupSemaphore, DISPATCH_TIME_FOREVER);
        self->_cleanupComplete = YES;
        NSArray<dispatch_block_t> *waiters = [self->_cleanupWaiters copy];
        [self->_cleanupWaiters removeAllObjects];
        dispatch_semaphore_signal(self->_cleanupSemaphore);

        dispatch_async(dispatch_get_main_queue(), ^{
            for (dispatch_block_t w in waiters) {
                w();
            }
        });
    });
}

// ─── Private: track resolution loop ──────────────────────────────────────────

/// Called on _resolverQueue.
- (void)_resolveTracksInPlan:(VGAudioSidecarPlan *)plan
                  completion:(void (^)(VGAudioSidecarPlan *_Nullable))completion {
    NSMutableArray<NSDictionary<NSString *, id> *> *resolvedTracks =
        [NSMutableArray arrayWithCapacity:plan.tracks.count];

    for (NSDictionary<NSString *, id> *trackDict in plan.tracks) {
        // Cancellation check between tracks.
        if (atomic_load(&_cancelled)) {
            NSLog(@"[VGAudioPreviewFileResolver] cancelled between tracks — aborting");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        NSString *urlString = trackDict[@"url"];
        if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
            NSLog(@"[VGAudioPreviewFileResolver] track missing url — dropping");
            continue;
        }

        NSURL *sourceURL = [NSURL fileURLWithPath:urlString];

        // Determine whether this source is an audiovisual container.
        if (!VGURLIsAudiovisualContainer(sourceURL)) {
            // Pure audio source: pass through.
            [resolvedTracks addObject:trackDict];
            continue;
        }

        // Audiovisual container: extract audio to CAF.
        NSString *trackId = trackDict[@"trackId"] ?: @"unknown";
        NSURL *cafURL = [self _tempCafURLForTrackId:trackId];
        if (!cafURL) {
            NSLog(@"[VGAudioPreviewFileResolver] no temp dir — dropping track %@", trackId);
            continue;
        }

        BOOL success = [self _extractAudioFromURL:sourceURL toCAFURL:cafURL trackId:trackId];
        if (!success) {
            // Failure logged inside _extractAudioFromURL. Drop this track.
            continue;
        }

        // Build rewritten track dict: copy all fields, replace only "url".
        NSMutableDictionary<NSString *, id> *rewritten = [trackDict mutableCopy];
        rewritten[@"url"] = cafURL.path;
        [resolvedTracks addObject:[rewritten copy]];
    }

    // Post-loop cancellation check.
    if (atomic_load(&_cancelled)) {
        NSLog(@"[VGAudioPreviewFileResolver] cancelled after track loop — aborting");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    if (resolvedTracks.count == 0) {
        NSLog(@"[VGAudioPreviewFileResolver] all tracks dropped — returning nil plan");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    // Construct new immutable plan: preserve volumeKeyframes, waveformCache,
    // timeRemapAudioPolicy verbatim; only "url" keys differ in tracks.
    VGAudioSidecarPlan *resolvedPlan =
        [[VGAudioSidecarPlan alloc]
            initWithTracks:[resolvedTracks copy]
           volumeKeyframes:plan.volumeKeyframes
             waveformCache:plan.waveformCache
     timeRemapAudioPolicy:plan.timeRemapAudioPolicy];

    dispatch_async(dispatch_get_main_queue(), ^{
        completion(resolvedPlan);
    });
}

// ─── Private: extraction ──────────────────────────────────────────────────────

/// Extracts the first audio track of |sourceURL| to a float32 interleaved
/// PCM CAF file at |cafURL|. Returns YES on success.
/// Runs on _resolverQueue. Checks _cancelled per sample buffer.
- (BOOL)_extractAudioFromURL:(NSURL *)sourceURL
                   toCAFURL:(NSURL *)cafURL
                    trackId:(NSString *)trackId {

    AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];

    // Find first audio track.
    NSArray<AVAssetTrack *> *audioTracks =
        [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — no audio track in container %@",
              trackId, sourceURL.lastPathComponent);
        return NO;
    }
    AVAssetTrack *audioTrack = audioTracks.firstObject;

    // ── Step 1: Read source audio format ─────────────────────────────────────
    //
    // We need the source sample rate and channel count to build ASBDs.
    // Obtain from the track's first format description.

    Float64 sourceSampleRate = 44100.0; // safe default; overridden below
    UInt32 sourceChannels    = 1;

    NSArray *fmtDescs = audioTrack.formatDescriptions;
    if (fmtDescs.count > 0) {
        CMFormatDescriptionRef fmtDesc =
            (__bridge CMFormatDescriptionRef)fmtDescs.firstObject;
        const AudioStreamBasicDescription *srcASBD =
            CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);
        if (srcASBD) {
            if (srcASBD->mSampleRate > 0) sourceSampleRate = srcASBD->mSampleRate;
            if (srcASBD->mChannelsPerFrame > 0) sourceChannels = srcASBD->mChannelsPerFrame;
        }
    }

    // ── Step 2: Create AVAssetReader with PCM output ──────────────────────────
    //
    // Request float32 interleaved PCM from the reader. We use interleaved
    // here to keep the reader output simple; ExtAudioFile handles the
    // client-format conversion from interleaved to non-interleaved when
    // kExtAudioFileProperty_ClientDataFormat is set.

    NSDictionary *readerSettings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey:      @32,
        AVLinearPCMIsFloatKey:       @YES,
        AVLinearPCMIsBigEndianKey:   @NO,
        AVLinearPCMIsNonInterleaved: @NO,   // interleaved from reader
    };

    NSError *readerErr = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerErr];
    if (!reader) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — AVAssetReader init failed: %@",
              trackId, readerErr.localizedDescription);
        return NO;
    }

    AVAssetReaderTrackOutput *trackOutput =
        [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:audioTrack
                            outputSettings:readerSettings];
    trackOutput.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:trackOutput]) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — cannot add reader output",
              trackId);
        return NO;
    }
    [reader addOutput:trackOutput];

    // ── Step 3: Create ExtAudioFile with file ASBD ────────────────────────────
    //
    // File ASBD: CAF container, float32 interleaved PCM.
    // This is what gets written to disk.

    AudioStreamBasicDescription fileASBD = {
        .mSampleRate       = sourceSampleRate,
        .mFormatID         = kAudioFormatLinearPCM,
        .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket   = 4 * sourceChannels,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = 4 * sourceChannels,
        .mChannelsPerFrame = sourceChannels,
        .mBitsPerChannel   = 32,
    };

    // Remove pre-existing file (ExtAudioFileCreateWithURL with
    // kAudioFileFlags_EraseFile requires the file to not exist or will
    // overwrite; the erase flag handles it on most paths, but explicit
    // removal guards against stale partial files from a prior run).
    [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];

    ExtAudioFileRef cafFile = NULL;
    OSStatus osErr = ExtAudioFileCreateWithURL(
        (__bridge CFURLRef)cafURL,
        kAudioFileCAFType,
        &fileASBD,
        NULL,                        // channel layout: let CoreAudio infer
        kAudioFileFlags_EraseFile,
        &cafFile);
    if (osErr != noErr) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — ExtAudioFileCreateWithURL "
              @"failed: %d", trackId, (int)osErr);
        return NO;
    }

    // ── Step 4: Set client data format (interleaved float32) ────────────────
    //
    // The client ASBD defines the format in which we hand data to
    // ExtAudioFileWrite. Both reader output and client format are interleaved
    // float32 PCM; no conversion is needed. The property is set explicitly
    // as required by the ExtAudioFile contract.

    AudioStreamBasicDescription clientASBD = {
        .mSampleRate       = sourceSampleRate,
        .mFormatID         = kAudioFormatLinearPCM,
        .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket   = 4 * sourceChannels,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = 4 * sourceChannels,
        .mChannelsPerFrame = sourceChannels,
        .mBitsPerChannel   = 32,
    };

    osErr = ExtAudioFileSetProperty(
        cafFile,
        kExtAudioFileProperty_ClientDataFormat,
        sizeof(clientASBD),
        &clientASBD);
    if (osErr != noErr) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — "
              @"kExtAudioFileProperty_ClientDataFormat failed: %d",
              trackId, (int)osErr);
        ExtAudioFileDispose(cafFile);
        [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
        return NO;
    }

    // ── Step 5: Start reader and pump samples ─────────────────────────────────

    if (![reader startReading]) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — AVAssetReader startReading "
              @"failed: %@", trackId, reader.error.localizedDescription);
        ExtAudioFileDispose(cafFile);
        [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
        return NO;
    }

    BOOL success = YES;

    while (YES) {
        // Per-buffer cancellation check.
        if (atomic_load(&_cancelled)) {
            NSLog(@"[VGAudioPreviewFileResolver] track %@ — cancelled during extraction",
                  trackId);
            [reader cancelReading];
            ExtAudioFileDispose(cafFile);
            // Remove partial output.
            [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
            return NO;
        }

        CMSampleBufferRef sampleBuffer = [trackOutput copyNextSampleBuffer];
        if (!sampleBuffer) {
            // copyNextSampleBuffer returns nil at EOF or on error.
            // Only AVAssetReaderStatusCompleted is a success.
            if (reader.status != AVAssetReaderStatusCompleted) {
                NSLog(@"[VGAudioPreviewFileResolver] track %@ — reader ended with "
                      @"non-completed status %ld: %@",
                      trackId, (long)reader.status,
                      reader.error.localizedDescription);
                success = NO;
            }
            break;
        }

        // Extract AudioBufferList from sample buffer.
        CMBlockBufferRef blockBuffer = NULL;
        AudioBufferList abl;
        CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);
        OSStatus ablErr = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            NULL,           // bufferListSizeNeededOut
            &abl,
            sizeof(abl),
            NULL,           // blockBufferAllocator
            NULL,           // blockBufferMemoryAllocator
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &blockBuffer);

        if (ablErr != noErr) {
            NSLog(@"[VGAudioPreviewFileResolver] track %@ — "
                  @"CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer "
                  @"failed: %d", trackId, (int)ablErr);
            CFRelease(sampleBuffer);
            success = NO;
            break;
        }

        // Write frames to CAF.
        osErr = ExtAudioFileWrite(cafFile, (UInt32)frameCount, &abl);
        if (osErr != noErr) {
            NSLog(@"[VGAudioPreviewFileResolver] track %@ — ExtAudioFileWrite "
                  @"failed: %d", trackId, (int)osErr);
            if (blockBuffer) CFRelease(blockBuffer);
            CFRelease(sampleBuffer);
            success = NO;
            break;
        }

        if (blockBuffer) CFRelease(blockBuffer);
        CFRelease(sampleBuffer);
    }

    // ── Step 6: Finalise or clean up ─────────────────────────────────────────

    ExtAudioFileDispose(cafFile);   // Flushes and closes. Always called.

    if (!success) {
        [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
    }

    return success;
}

// ─── Private: temporary file URL ─────────────────────────────────────────────

- (nullable NSURL *)_tempCafURLForTrackId:(NSString *)trackId {
    if (!_tempDirURL) return nil;
    // Sanitise trackId for use in a filename: replace non-alphanumeric chars.
    NSString *safe = [[trackId componentsSeparatedByCharactersInSet:
                          [NSCharacterSet alphanumericCharacterSet].invertedSet]
                         componentsJoinedByString:@"_"];
    NSString *filename = [NSString stringWithFormat:@"%@.caf", safe];
    return [_tempDirURL URLByAppendingPathComponent:filename];
}

// ─── Private: temp directory removal ─────────────────────────────────────────

- (void)_removeTempDirectoryIfNeeded {
    NSURL *dir = _tempDirURL;
    if (!dir) return;
    _tempDirURL = nil;
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtURL:dir error:&err];
    if (err) {
        NSLog(@"[VGAudioPreviewFileResolver] temp dir removal error: %@",
              err.localizedDescription);
    }
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
