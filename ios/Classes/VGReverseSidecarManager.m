// VGReverseSidecarManager.m
// vanguard_media_engine — Phase 7.20A
//
// Thread-safe singleton manager for reverse-playback sidecar assets.
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 7.20A — REVERSE SIDECAR MANAGER FOUNDATION + MVP TRANSCODER
// ═══════════════════════════════════════════════════════════════════════════════
//
// Apple documentation cross-checked (Phase 7.20A):
//
//   AVURLAsset:
//     - Represents a media asset via a URL. Thread-safe after initialization.
//     - tracksWithMediaType: is synchronous in iOS 14–17. iOS 16+ prefers async
//       variant; synchronous is used here for simplicity (same pattern as
//       VGTimelineCompositorNode._buildReaderForClipIndex:startAtTime:error:).
//
//   AVAssetReader:
//     - Forward-only sequential sample delivery.
//     - timeRange must be set BEFORE startReading.
//     - startReading must be called exactly once; cannot be reset.
//     - Status transitions: Unknown → Reading → Completed / Failed.
//
//   AVAssetReaderVideoCompositionOutput:
//     - Decodes video frames through an AVVideoComposition, applying
//     orientation
//       normalization (preferredTransform) at decode time.
//     - Must set videoComposition BEFORE startReading.
//     - alwaysCopiesSampleData = NO: returns original decoded buffers
//     (read-only).
//     - copyNextSampleBuffer: is synchronous, blocking until next frame is
//     available.
//
//   AVMutableVideoComposition (videoCompositionWithPropertiesOfAsset:):
//     - Deprecated iOS 18 (async variant preferred). Synchronous variant (iOS
//     6+)
//       is retained here for the same reason as VGTimelineCompositorNode
//       (offline transcode queue, no structural constraint preventing
//       synchronous use).
//     - Automatically synthesises frameDuration and renderSize from track
//     properties.
//     - Applies preferredTransform from the video track. Orientation is baked
//     into
//       the output pixel buffers — the output track has identity transform.
//
//   AVAssetWriter:
//     - expectsMediaDataInRealTime = NO: optimal for offline offline
//     transcoding.
//       The writer manages internal buffering for optimal encode throughput.
//     - Must call startWriting and startSessionAtSourceTime before appending.
//     - finishWritingWithCompletionHandler: is async; we use semaphore to make
//     it
//       effectively synchronous within the serial transcode queue.
//     - Status: Unknown → Writing → Completed / Failed / Cancelled.
//
//   AVAssetWriterInput:
//     - expectsMediaDataInRealTime = NO for offline encode.
//     - isReadyForMoreMediaData must be checked (or
//     requestMediaDataWhenReadyOnQueue:
//       must be used). In our pull-mode offline loop, we check
//       isReadyForMoreMediaData before each append and spin-wait briefly if
//       needed.
//     - markAsFinished must be called before calling
//     finishWritingWithCompletionHandler:.
//
//   AVAssetWriterInputPixelBufferAdaptor:
//     - appendPixelBuffer:withPresentationTime: is the correct API for
//     CVPixelBuffer
//       submission when using a pixel buffer adaptor.
//     - pixelBufferPool: provides a reuse pool; use it to minimize
//     CVPixelBuffer
//       allocations when converting intermediate formats if needed.
//
//   AVVideoMaxKeyFrameIntervalKey = 1:
//     - Forces every frame to be an I-frame (All-Intra encoding).
//     - Guarantees random-access seeking to any frame, critical for the
//     compositor's
//       asynchronous seek-driven preview path.
//     - Increases file size vs. IBP encoding; acceptable for temporary sidecar
//     files.
//
//   AVVideoAllowFrameReorderingKey = NO:
//     - Suppresses B-frame encoding. Required for All-Intra
//     (maxKeyFrameInterval=1
//       already implies this, but explicit declaration is defensive).
//     - Without this, some encoders may still produce B-frames despite the key
//     frame
//       interval constraint.
//
//   AVAssetTrack.preferredTransform:
//     - Describes the display orientation for the track. Camera-captured clips
//     often
//       carry a 90°/270° rotation here.
//     - NOT automatically applied by AVAssetReader/AVAssetReaderTrackOutput.
//     - IS applied by AVAssetReaderVideoCompositionOutput when using a proper
//       AVMutableVideoComposition (videoCompositionWithPropertiesOfAsset:).
//     - After baking via video composition, the output pixels are
//     orientation-correct
//       and the output sidecar track should carry identity preferredTransform.
//
//   CVPixelBufferRef:
//     - Reference-counted. Must be retained/released symmetrically.
//     - kCVPixelFormatType_32BGRA: the compositor's native pixel format
//     (matches
//       VGTimelineCompositorNode._VGTCNOutputSettings()).
//     - Accumulated in NSMutableArray during forward decode pass; released
//     after
//       reverse write pass to minimize peak memory footprint.
//
//   CMTime / CMTimeRange:
//     - timescale 600 used consistently (same as VGTimelineCompositorNode).
//     - CMTimeMakeWithSeconds(0.0, 600) = start of sidecar output timeline.
//     - Frame PTS in sidecar = (frameCount - 1 - i) * frameDuration, writing
//       in reverse visual order with monotonically increasing output
//       timestamps.
//
// ─── Memory budget (Opus CORRECTION 1 applied) ───────────────────────────────
// kVGSidecarMaxFrameCount = 300 frames (10s at 30fps — conservative default).
// kVGSidecarMaxEstimatedBytes = 160 MB (target size BGRA: 640×360×4 = ~900
// KB/frame;
//   300 frames × ~0.9MB = ~270MB at 720p. We cap at 640×360 scale or provided
//   targetSize, whichever is smaller).
// Clips exceeding either limit fail gracefully with
// kVGSidecarErrorFrameBudgetExceeded. Disk-backed chunked transcoding for
// longer clips is deferred to Phase 7.20A-ext.

#import "VGReverseSidecarManager.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdatomic.h>

// ─── Logging
// ──────────────────────────────────────────────────────────────────

static os_log_t sSidecarLog;

// ─── Memory budget constants
// ──────────────────────────────────────────────────

/// Maximum number of decoded frames held in memory during transcode.
/// 300 frames ≈ 10 seconds at 30fps. Clips longer than this will fail with
/// kVGSidecarErrorFrameBudgetExceeded. Disk-backed mode deferred to 7.20A-ext.
static const NSInteger kVGSidecarMaxFrameCount = 300;

/// Maximum estimated raw pixel bytes for the in-memory frame accumulation.
/// Estimated as: targetWidth × targetHeight × 4 × frameCount.
/// Default: 200 MB — still bounded for foreground app footprint while allowing
/// short <=10s / ~30fps reverse preview sidecars at the 540px target dimension.
static const NSUInteger kVGSidecarMaxEstimatedBytes = 200 * 1024 * 1024;

/// Maximum target size dimension for sidecar output. Frames are downscaled to
/// at most this size to reduce memory footprint. This matches typical preview
/// canvas sizes; larger sources are scaled down.
/// Phase 7.20 patch: lowered from 720 → 540 to keep the 5-s Clip A sidecar
/// (~95–100 MB) under the kVGSidecarMaxEstimatedBytes (160 MB) budget.
static const CGFloat kVGSidecarMaxTargetDimension = 540.0;

/// Default bitrate for H.264 sidecar encoding (bits per second).
/// 4 Mbps at 720p provides good preview quality. Adjust in 7.20B if needed.
static const NSInteger kVGSidecarBitrate = 4000000;

// ─── Error constants
// ──────────────────────────────────────────────────────────

NSString *const kVGSidecarErrorFrameBudgetExceeded =
    @"SIDECAR_FRAME_BUDGET_EXCEEDED";
NSString *const kVGSidecarErrorMissingSourceFile =
    @"SIDECAR_MISSING_SOURCE_FILE";
NSString *const kVGSidecarErrorNoVideoTrack = @"SIDECAR_NO_VIDEO_TRACK";
NSString *const kVGSidecarErrorInvalidTrimRange = @"SIDECAR_INVALID_TRIM_RANGE";
NSString *const kVGSidecarErrorReaderCreationFailed =
    @"SIDECAR_READER_CREATION_FAILED";
NSString *const kVGSidecarErrorWriterCreationFailed =
    @"SIDECAR_WRITER_CREATION_FAILED";
NSString *const kVGSidecarErrorAdaptorCreationFailed =
    @"SIDECAR_ADAPTOR_CREATION_FAILED";
NSString *const kVGSidecarErrorAppendFailed = @"SIDECAR_APPEND_FAILED";
NSString *const kVGSidecarErrorFinishWritingFailed =
    @"SIDECAR_FINISH_WRITING_FAILED";
NSString *const kVGSidecarErrorCancelled = @"SIDECAR_CANCELLED";

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGReverseSidecarStatus (internal init)
// ─────────────────────────────────────────────────────────────────────────────

@interface VGReverseSidecarStatus ()
@property(nonatomic, readwrite) VGReverseSidecarState state;
@property(nonatomic, readwrite, nullable) NSString *sidecarPath;
@property(nonatomic, readwrite, nullable) NSString *errorMessage;
@property(nonatomic, readwrite) double progress;
@end

@implementation VGReverseSidecarStatus

+ (instancetype)statusWithState:(VGReverseSidecarState)state
                    sidecarPath:(nullable NSString *)sidecarPath
                   errorMessage:(nullable NSString *)errorMessage
                       progress:(double)progress {
  VGReverseSidecarStatus *s = [[VGReverseSidecarStatus alloc] init];
  s.state = state;
  s.sidecarPath = sidecarPath;
  s.errorMessage = errorMessage;
  s.progress = progress;
  return s;
}

- (NSString *)description {
  return [NSString
      stringWithFormat:
          @"<VGReverseSidecarStatus state=%ld path=%@ err=%@ progress=%.2f>",
          (long)self.state, self.sidecarPath, self.errorMessage, self.progress];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Internal clip record
// ─────────────────────────────────────────────────────────────────────────────

/// Internal per-clip record stored in the manager's dictionary.
@interface _VGSidecarRecord : NSObject
/// Stored hash of (sourcePath + trimStart + trimEnd + targetSize).
@property(nonatomic, copy) NSString *sourceHash;
/// Current state.
@property(nonatomic, assign) VGReverseSidecarState state;
/// Sidecar file path when state == ready.
@property(nonatomic, copy, nullable) NSString *sidecarPath;
/// Error message when state == failed.
@property(nonatomic, copy, nullable) NSString *errorMessage;
/// Progress [0.0, 1.0] during preparing.
@property(nonatomic, assign) double progress;
/// Monotonically increasing generation token. Incremented on invalidation.
/// In-flight transcode tasks capture the generation at start; if the captured
/// generation no longer matches the record's generation at completion time,
/// the result is discarded (stale transcode).
@property(nonatomic, assign) uint64_t generation;
/// Pending completion blocks for coalesced requests.
@property(nonatomic, strong)
    NSMutableArray<void (^)(VGReverseSidecarStatus *)> *pendingCompletions;
@end

@implementation _VGSidecarRecord
- (instancetype)init {
  if ((self = [super init])) {
    _state = VGReverseSidecarStateIdle;
    _progress = 0.0;
    _generation = 0;
    _pendingCompletions = [NSMutableArray array];
  }
  return self;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGReverseSidecarManager private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface VGReverseSidecarManager ()

/// Serial queue for all transcode operations.
/// Also used as the synchronisation context for the lock — all lock-protected
/// state mutations happen on the calling thread, protected by _lock.
@property(nonatomic, strong) dispatch_queue_t _sidecarTranscodeQueue;

/// Maps clipId (NSString) → _VGSidecarRecord.
/// Protected by _lock for all reads and writes.
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, _VGSidecarRecord *> *_records;

@end

@implementation VGReverseSidecarManager {
  /// os_unfair_lock for all _records mutations.
  os_unfair_lock _lock;
}

// ─── Singleton
// ────────────────────────────────────────────────────────────────

+ (instancetype)sharedManager {
  static VGReverseSidecarManager *sInstance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sInstance = [[VGReverseSidecarManager alloc] _initPrivate];
  });
  return sInstance;
}

- (instancetype)_initPrivate {
  if ((self = [super init])) {
    _lock = OS_UNFAIR_LOCK_INIT;
    __records = [NSMutableDictionary dictionary];
    __sidecarTranscodeQueue = dispatch_queue_create(
        "com.vanguard.reverse_sidecar", DISPATCH_QUEUE_SERIAL);
    sSidecarLog =
        os_log_create("com.vanguard.media_engine", "VGReverseSidecar");

    // Ensure the sidecar directory exists.
    [self _ensureSidecarDirectory];
  }
  return self;
}

// ─── Directory management
// ─────────────────────────────────────────────────────

- (NSString *)_sidecarDirectory {
  return [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"VGReverseSidecars"];
}

- (void)_ensureSidecarDirectory {
  NSString *dir = [self _sidecarDirectory];
  NSError *err = nil;
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&err];
  if (err) {
    os_log_error(sSidecarLog,
                 "[VGSidecar] failed to create sidecar directory: %{public}@",
                 err.localizedDescription);
  }
}

- (NSString *)_sidecarPathForClipId:(NSString *)clipId {
  // File names are safe slugs derived from clipId.
  // Use MD5-like truncation: keep the clipId alphanumeric chars.
  NSMutableString *safe = [NSMutableString string];
  for (NSUInteger i = 0; i < clipId.length && i < 32; i++) {
    unichar c = [clipId characterAtIndex:i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_') {
      [safe appendFormat:@"%C", c];
    } else {
      [safe appendString:@"_"];
    }
  }
  NSString *filename = [NSString stringWithFormat:@"vg_rev_%@.mov", safe];
  return [[self _sidecarDirectory] stringByAppendingPathComponent:filename];
}

// ─── Query
// ────────────────────────────────────────────────────────────────────

- (VGReverseSidecarStatus *)statusForClipId:(NSString *)clipId {
  os_unfair_lock_lock(&_lock);
  _VGSidecarRecord *record = __records[clipId];
  os_unfair_lock_unlock(&_lock);

  if (!record) {
    return [VGReverseSidecarStatus statusWithState:VGReverseSidecarStateIdle
                                       sidecarPath:nil
                                      errorMessage:nil
                                          progress:0.0];
  }
  os_unfair_lock_lock(&_lock);
  VGReverseSidecarStatus *status =
      [VGReverseSidecarStatus statusWithState:record.state
                                  sidecarPath:record.sidecarPath
                                 errorMessage:record.errorMessage
                                     progress:record.progress];
  os_unfair_lock_unlock(&_lock);
  return status;
}

// ─── Prepare ─────────────────────────────────────────────────────────────────

- (void)prepareSidecarForClipId:(NSString *)clipId
                     sourcePath:(NSString *)sourcePath
                      trimStart:(double)trimStart
                        trimEnd:(double)trimEnd
                     targetSize:(CGSize)targetSize
                     sourceHash:(NSString *)sourceHash
                     completion:
                         (void (^)(VGReverseSidecarStatus *status))completion {

  os_unfair_lock_lock(&_lock);
  _VGSidecarRecord *record = __records[clipId];

  if (!record) {
    record = [[_VGSidecarRecord alloc] init];
    __records[clipId] = record;
  }

  // ── Case 1: Already ready with matching hash ──────────────────────────────
  if (record.state == VGReverseSidecarStateReady &&
      [record.sourceHash isEqualToString:sourceHash]) {
    NSString *path = record.sidecarPath;
    os_unfair_lock_unlock(&_lock);
    os_log(sSidecarLog,
           "[VGSidecar] cache hit: clip=%{public}@ path=%{public}@", clipId,
           path);
    VGReverseSidecarStatus *status =
        [VGReverseSidecarStatus statusWithState:VGReverseSidecarStateReady
                                    sidecarPath:path
                                   errorMessage:nil
                                       progress:1.0];
    dispatch_async(__sidecarTranscodeQueue, ^{
      completion(status);
    });
    return;
  }

  // ── Case 2: In-flight with matching hash — coalesce ───────────────────────
  if (record.state == VGReverseSidecarStatePreparing &&
      [record.sourceHash isEqualToString:sourceHash]) {
    [record.pendingCompletions addObject:[completion copy]];
    os_unfair_lock_unlock(&_lock);
    os_log(sSidecarLog, "[VGSidecar] coalescing request: clip=%{public}@",
           clipId);
    return;
  }

  // ── Case 3: Stale hash / wrong state — invalidate stale data and restart ──
  if (record.state == VGReverseSidecarStateReady ||
      record.state == VGReverseSidecarStatePreparing ||
      record.state == VGReverseSidecarStateFailed ||
      record.state == VGReverseSidecarStateInvalidated) {
    // Invalidate stale sidecar file (async deletion, does not block the lock).
    NSString *stalePath = record.sidecarPath;
    record.sidecarPath = nil;
    record.errorMessage = nil;
    record.progress = 0.0;
    record.state = VGReverseSidecarStateIdle;
    record.generation += 1;
    [record.pendingCompletions removeAllObjects];
    if (stalePath) {
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *delErr = nil;
        [[NSFileManager defaultManager] removeItemAtPath:stalePath
                                                   error:&delErr];
        if (delErr) {
          os_log_error(sSidecarLog,
                       "[VGSidecar] stale sidecar delete failed: %{public}@",
                       delErr.localizedDescription);
        }
      });
    }
  }

  // ── Start a new transcode task ────────────────────────────────────────────
  record.sourceHash = [sourceHash copy];
  record.state = VGReverseSidecarStatePreparing;
  record.progress = 0.0;
  [record.pendingCompletions addObject:[completion copy]];

  NSString *sidecarPath = [self _sidecarPathForClipId:clipId];
  uint64_t capturedGeneration = record.generation;

  os_unfair_lock_unlock(&_lock);

  os_log(sSidecarLog,
         "[VGSidecar] starting transcode: clip=%{public}@ src=%{public}@ "
         "trim=[%.3f,%.3f] gen=%llu",
         clipId, sourcePath, trimStart, trimEnd,
         (unsigned long long)capturedGeneration);

  // Capture all values needed by the transcode block — no references to self
  // properties that could race with the lock.
  NSString *capturedClipId = [clipId copy];
  NSString *capturedSrcPath = [sourcePath copy];
  NSString *capturedSidecarPath = [sidecarPath copy];

  dispatch_async(__sidecarTranscodeQueue, ^{
    [self _transcodeClipId:capturedClipId
                sourcePath:capturedSrcPath
                 trimStart:trimStart
                   trimEnd:trimEnd
                targetSize:targetSize
               sidecarPath:capturedSidecarPath
        capturedGeneration:capturedGeneration];
  });
}

// ─── Invalidate
// ───────────────────────────────────────────────────────────────

- (void)invalidateSidecarForClipId:(NSString *)clipId {
  os_unfair_lock_lock(&_lock);
  _VGSidecarRecord *record = __records[clipId];
  if (!record) {
    os_unfair_lock_unlock(&_lock);
    return;
  }

  NSString *stalePath = record.sidecarPath;
  record.state = VGReverseSidecarStateIdle;
  record.sidecarPath = nil;
  record.errorMessage = nil;
  record.progress = 0.0;
  record.generation += 1;
  [record.pendingCompletions removeAllObjects];
  os_unfair_lock_unlock(&_lock);

  os_log(sSidecarLog, "[VGSidecar] invalidated: clip=%{public}@", clipId);

  if (stalePath) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSError *delErr = nil;
      [[NSFileManager defaultManager] removeItemAtPath:stalePath error:&delErr];
      if (delErr) {
        os_log_error(sSidecarLog,
                     "[VGSidecar] invalidate delete failed: %{public}@",
                     delErr.localizedDescription);
      }
    });
  }
}

- (void)cleanupAllSidecars {
  os_unfair_lock_lock(&_lock);
  NSMutableArray<NSString *> *pathsToDelete = [NSMutableArray array];
  for (_VGSidecarRecord *record in __records.allValues) {
    if (record.sidecarPath) {
      [pathsToDelete addObject:record.sidecarPath];
    }
    record.state = VGReverseSidecarStateIdle;
    record.sidecarPath = nil;
    record.errorMessage = nil;
    record.progress = 0.0;
    record.generation += 1;
    [record.pendingCompletions removeAllObjects];
  }
  [__records removeAllObjects];
  os_unfair_lock_unlock(&_lock);

  os_log(sSidecarLog, "[VGSidecar] cleanupAllSidecars: deleting %lu files",
         (unsigned long)pathsToDelete.count);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    for (NSString *path in pathsToDelete) {
      NSError *delErr = nil;
      [[NSFileManager defaultManager] removeItemAtPath:path error:&delErr];
      if (delErr) {
        os_log_error(sSidecarLog,
                     "[VGSidecar] cleanup delete failed: %{public}@",
                     delErr.localizedDescription);
      }
    }
  });

  // Also attempt to delete any orphaned sidecar directory files from prior
  // sessions.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    [self _deleteOrphanedSidecarFiles];
  });
}

/// Deletes all .mov files in the sidecar directory that are no longer tracked.
- (void)_deleteOrphanedSidecarFiles {
  NSString *dir = [self _sidecarDirectory];
  NSError *listErr = nil;
  NSArray<NSString *> *files =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir
                                                          error:&listErr];
  if (listErr || !files)
    return;

  for (NSString *file in files) {
    if (![file.pathExtension isEqualToString:@"mov"])
      continue;
    NSString *fullPath = [dir stringByAppendingPathComponent:file];
    NSError *delErr = nil;
    [[NSFileManager defaultManager] removeItemAtPath:fullPath error:&delErr];
    if (delErr) {
      os_log_error(sSidecarLog,
                   "[VGSidecar] orphan delete failed %{public}@: %{public}@",
                   file, delErr.localizedDescription);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Transcode engine (MVP: memory-bounded in-memory accumulation)
// ─────────────────────────────────────────────────────────────────────────────

/// Core transcode method. Runs on _sidecarTranscodeQueue (serial).
///
/// Memory contract (Opus CORRECTION 1):
///   - Clamps targetSize to kVGSidecarMaxTargetDimension in each dimension.
///   - Estimates total BGRA memory before decoding.
///   - Fails with kVGSidecarErrorFrameBudgetExceeded if estimate exceeds
///   limits.
///   - Releases all CVPixelBuffer references after the write pass.
///
/// Orientation contract (Opus CORRECTION 3):
///   - Uses AVAssetReaderVideoCompositionOutput with
///     AVMutableVideoComposition.videoCompositionWithPropertiesOfAsset: to bake
///     the source track's preferredTransform into decoded pixel data.
///   - The output .mov track carries identity preferredTransform.
///   - 7.20C must NOT re-apply preferredTransform when reading the sidecar.
///
/// Write order:
///   - Frames are decoded forward (index 0 = earliest in trimmed range).
///   - Written to AVAssetWriter in reverse order (index N-1 first), with
///     monotonically increasing output presentation timestamps.
///   - This produces a forward-playable file whose visual content is the
///     reversed clip.
- (void)_transcodeClipId:(NSString *)clipId
              sourcePath:(NSString *)sourcePath
               trimStart:(double)trimStart
                 trimEnd:(double)trimEnd
              targetSize:(CGSize)targetSize
             sidecarPath:(NSString *)sidecarPath
      capturedGeneration:(uint64_t)capturedGeneration {

  // ── 0. Staleness guard (pre-work) ─────────────────────────────────────────
  if (![self _isGenerationCurrent:capturedGeneration forClipId:clipId]) {
    os_log(sSidecarLog,
           "[VGSidecar] transcode stale (pre-work): clip=%{public}@ gen=%llu",
           clipId, (unsigned long long)capturedGeneration);
    return;
  }

  // ── 1. Validate source file ───────────────────────────────────────────────
  NSURL *assetURL = [NSURL fileURLWithPath:sourcePath];
  if (!assetURL) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorMissingSourceFile
               detail:@"sourceURL is nil"];
    return;
  }
  if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorMissingSourceFile
               detail:[NSString
                          stringWithFormat:@"File not found: %@", sourcePath]];
    return;
  }

  // ── 2. Validate trim range ────────────────────────────────────────────────
  if (trimEnd <= trimStart || trimStart < 0.0) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorInvalidTrimRange
               detail:[NSString stringWithFormat:@"trimStart=%.3f trimEnd=%.3f",
                                                 trimStart, trimEnd]];
    return;
  }

  // ── 3. Load asset and find video track ───────────────────────────────────
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
  NSArray<AVAssetTrack *> *tracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  AVAssetTrack *videoTrack = tracks.firstObject;
  if (!videoTrack) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorNoVideoTrack
               detail:[NSString stringWithFormat:@"No video track in %@",
                                                 sourcePath]];
    return;
  }

  // ── 4. Determine output size (canvas normalization + memory budget) ───────
  // Apply the same aspect-fit canvas normalization as _buildReaderForClipIndex:
  // in VGTimelineCompositorNode. (Opus CORRECTION 3)
  CGAffineTransform preferredTx = videoTrack.preferredTransform;
  CGSize naturalSize = videoTrack.naturalSize;
  CGRect displayRect = CGRectApplyAffineTransform(
      CGRectMake(0, 0, naturalSize.width, naturalSize.height), preferredTx);
  CGFloat displayW = fabs(displayRect.size.width);
  CGFloat displayH = fabs(displayRect.size.height);
  if (displayW <= 0 || displayH <= 0) {
    displayW = naturalSize.width;
    displayH = naturalSize.height;
  }

  // Apply targetSize clamping. If targetSize is zero, use display dimensions.
  CGFloat outW, outH;
  if (targetSize.width > 0 && targetSize.height > 0) {
    CGFloat scaleW = targetSize.width / displayW;
    CGFloat scaleH = targetSize.height / displayH;
    CGFloat scale = MIN(scaleW, scaleH);
    outW = round(displayW * scale);
    outH = round(displayH * scale);
  } else {
    outW = displayW;
    outH = displayH;
  }

  // Further clamp to kVGSidecarMaxTargetDimension to limit memory.
  if (outW > kVGSidecarMaxTargetDimension ||
      outH > kVGSidecarMaxTargetDimension) {
    CGFloat clampScale = MIN(kVGSidecarMaxTargetDimension / outW,
                             kVGSidecarMaxTargetDimension / outH);
    outW = round(outW * clampScale);
    outH = round(outH * clampScale);
  }
  // Ensure even dimensions (H.264 requirement).
  outW = (outW < 2) ? 2 : (CGFloat)(((int)outW) & ~1);
  outH = (outH < 2) ? 2 : (CGFloat)(((int)outH) & ~1);
  // outputSize is used implicitly via outW/outH below.

  // ── 5. Estimate frame count and memory ───────────────────────────────────
  // Compute source FPS from the video composition (same as
  // _buildReaderForClipIndex:).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  AVMutableVideoComposition *videoComposition =
      [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset];
#pragma clang diagnostic pop

  double sourceFPS = 30.0;
  if (videoComposition && CMTIME_IS_VALID(videoComposition.frameDuration) &&
      CMTimeGetSeconds(videoComposition.frameDuration) > 0.0) {
    sourceFPS = 1.0 / CMTimeGetSeconds(videoComposition.frameDuration);
  } else if (videoTrack.nominalFrameRate > 0.0f) {
    sourceFPS = (double)videoTrack.nominalFrameRate;
  }
  if (sourceFPS <= 0.0 || sourceFPS > 240.0)
    sourceFPS = 30.0;

  double trimDuration = trimEnd - trimStart;
  NSInteger estimatedFrameCount = (NSInteger)ceil(trimDuration * sourceFPS);
  if (estimatedFrameCount <= 0)
    estimatedFrameCount = 1;

  NSUInteger estimatedBytes =
      (NSUInteger)(outW * outH * 4) * (NSUInteger)estimatedFrameCount;

  os_log(sSidecarLog,
         "[VGSidecar] plan: clip=%{public}@ fps=%.1f frames≈%ld "
         "size=%.0fx%.0f estimatedMB=%.1f",
         clipId, sourceFPS, (long)estimatedFrameCount, outW, outH,
         estimatedBytes / (1024.0 * 1024.0));

  // ── Memory budget check (Opus CORRECTION 1) ───────────────────────────────
  if (estimatedFrameCount > kVGSidecarMaxFrameCount) {
    [self
        _failClipId:clipId
         generation:capturedGeneration
              error:kVGSidecarErrorFrameBudgetExceeded
             detail:[NSString stringWithFormat:
                                  @"Estimated %ld frames exceeds limit of %ld. "
                                   "Clip duration=%.1fs fps=%.1f. "
                                   "Disk-backed transcoding deferred to Phase "
                                   "7.20A-ext.",
                                  (long)estimatedFrameCount,
                                  (long)kVGSidecarMaxFrameCount, trimDuration,
                                  sourceFPS]];
    return;
  }
  if (estimatedBytes > kVGSidecarMaxEstimatedBytes) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorFrameBudgetExceeded
               detail:[NSString
                          stringWithFormat:
                              @"Estimated %.1f MB exceeds budget of %.1f MB. "
                               "frames≈%ld size=%.0fx%.0f. "
                               "Disk-backed transcoding deferred to Phase "
                               "7.20A-ext.",
                              estimatedBytes / (1024.0 * 1024.0),
                              kVGSidecarMaxEstimatedBytes / (1024.0 * 1024.0),
                              (long)estimatedFrameCount, outW, outH]];
    return;
  }

  // ── 6. Build AVAssetReader with VideoCompositionOutput ───────────────────
  // Apply the canvas fit + orientation normalization via video composition.
  // Mirrors _buildReaderForClipIndex: in VGTimelineCompositorNode. (Opus
  // CORRECTION 3)
  [self _applyAspectFitComposition:videoComposition
                        videoTrack:videoTrack
                          outWidth:(CGFloat)outW
                         outHeight:(CGFloat)outH
                       preferredTx:preferredTx
                          displayW:displayW
                          displayH:displayH];

  NSError *readerErr = nil;
  AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset
                                                        error:&readerErr];
  if (!reader) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorReaderCreationFailed
               detail:readerErr.localizedDescription
                          ?: @"AVAssetReader init failed"];
    return;
  }

  // Set trim range.
  CMTime startTime = CMTimeMakeWithSeconds(trimStart, 600);
  CMTime endTime = CMTimeMakeWithSeconds(trimEnd, 600);
  CMTime duration = asset.duration;

  // Clamp endTime to asset duration.
  if (CMTIME_IS_VALID(duration) && CMTimeCompare(endTime, duration) > 0) {
    endTime = duration;
  }
  if (CMTimeCompare(startTime, endTime) < 0) {
    reader.timeRange =
        CMTimeRangeMake(startTime, CMTimeSubtract(endTime, startTime));
  }

  // Build output: BGRA pixel format (matches compositor native format).
  NSDictionary *outputSettings = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
  };
  AVAssetReaderVideoCompositionOutput *output =
      [[AVAssetReaderVideoCompositionOutput alloc]
          initWithVideoTracks:@[ videoTrack ]
                videoSettings:outputSettings];
  output.videoComposition = videoComposition;
  output.alwaysCopiesSampleData = NO; // return original decoded buffers

  if (![reader canAddOutput:output]) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorReaderCreationFailed
               detail:@"Cannot add AVAssetReaderVideoCompositionOutput"];
    return;
  }
  [reader addOutput:output];

  if (![reader startReading]) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorReaderCreationFailed
               detail:reader.error.localizedDescription
                          ?: @"startReading failed"];
    return;
  }

  // ── 7. Decode all frames forward into memory ──────────────────────────────
  // The memory budget check above ensures we won't OOM for supported clip
  // lengths.
  NSMutableArray<id> *pixelBuffers =
      [NSMutableArray arrayWithCapacity:estimatedFrameCount];
  NSMutableArray<NSNumber *> *frameDurations =
      [NSMutableArray arrayWithCapacity:estimatedFrameCount];

  NSInteger frameIndex = 0;
  BOOL budgetExceeded = NO;

  while (reader.status == AVAssetReaderStatusReading) {
    // ── Staleness guard inside decode loop ────────────────────────────────
    if (frameIndex % 30 == 0) {
      if (![self _isGenerationCurrent:capturedGeneration forClipId:clipId]) {
        os_log(sSidecarLog,
               "[VGSidecar] cancelled mid-decode: clip=%{public}@ frame=%ld",
               clipId, (long)frameIndex);
        [reader cancelReading];
        [self _failClipId:clipId
               generation:capturedGeneration
                    error:kVGSidecarErrorCancelled
                   detail:@"Invalidated during decode"];
        // Release accumulated buffers.
        for (id buf in pixelBuffers) {
          CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
        }
        return;
      }
    }

    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (!sample)
      break;

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
    if (!pb) {
      CFRelease(sample);
      continue;
    }
    CVPixelBufferRetain(pb);

    // Get frame duration for accurate output timing.
    CMTime sampleDur = CMSampleBufferGetDuration(sample);
    double dur =
        (CMTIME_IS_VALID(sampleDur) && !CMTIME_IS_INDEFINITE(sampleDur))
            ? CMTimeGetSeconds(sampleDur)
            : (1.0 / sourceFPS);
    [frameDurations addObject:@(dur)];

    CFRelease(sample);

    // Live budget guard: check actual frame count and byte size as we go.
    if (frameIndex >= kVGSidecarMaxFrameCount) {
      os_log_error(sSidecarLog,
                   "[VGSidecar] frame budget exceeded mid-decode: "
                   "clip=%{public}@ frames=%ld",
                   clipId, (long)frameIndex);
      CVPixelBufferRelease(pb);
      [reader cancelReading];
      budgetExceeded = YES;
      break;
    }

    [pixelBuffers addObject:(__bridge id)pb];
    frameIndex++;

    // Update progress periodically.
    if (frameIndex % 10 == 0 && estimatedFrameCount > 0) {
      double prog = MIN(0.95, (double)frameIndex / (double)estimatedFrameCount);
      [self _updateProgress:prog clipId:clipId generation:capturedGeneration];
    }
  }

  if (reader.status == AVAssetReaderStatusFailed) {
    // Release accumulated buffers.
    for (id buf in pixelBuffers) {
      CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
    }
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorReaderCreationFailed
               detail:reader.error.localizedDescription
                          ?: @"AVAssetReader failed"];
    return;
  }

  if (budgetExceeded) {
    // Release accumulated buffers.
    for (id buf in pixelBuffers) {
      CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
    }
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorFrameBudgetExceeded
               detail:[NSString
                          stringWithFormat:
                              @"Actual frame count %ld exceeded limit %ld.",
                              (long)frameIndex, (long)kVGSidecarMaxFrameCount]];
    return;
  }

  NSInteger actualFrameCount = (NSInteger)pixelBuffers.count;
  if (actualFrameCount == 0) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorReaderCreationFailed
               detail:@"No frames decoded from source clip"];
    return;
  }

  os_log(sSidecarLog, "[VGSidecar] decoded %ld frames: clip=%{public}@",
         (long)actualFrameCount, clipId);

  // ── 8. Staleness guard before writing ─────────────────────────────────────
  if (![self _isGenerationCurrent:capturedGeneration forClipId:clipId]) {
    for (id buf in pixelBuffers) {
      CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
    }
    os_log(sSidecarLog,
           "[VGSidecar] stale after decode: clip=%{public}@ gen=%llu", clipId,
           (unsigned long long)capturedGeneration);
    return;
  }

  // ── 9. Build AVAssetWriter ────────────────────────────────────────────────
  // Delete any pre-existing file at the sidecar path.
  [[NSFileManager defaultManager] removeItemAtPath:sidecarPath error:nil];

  NSURL *sidecarURL = [NSURL fileURLWithPath:sidecarPath];
  NSError *writerErr = nil;
  AVAssetWriter *writer =
      [AVAssetWriter assetWriterWithURL:sidecarURL
                               fileType:AVFileTypeQuickTimeMovie
                                  error:&writerErr];
  if (!writer) {
    for (id buf in pixelBuffers) {
      CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
    }
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorWriterCreationFailed
               detail:writerErr.localizedDescription
                          ?: @"AVAssetWriter init failed"];
    return;
  }

  // Writer settings: H.264 All-Intra (Opus CORRECTION 2).
  NSDictionary *compressionProps = @{
    AVVideoMaxKeyFrameIntervalKey : @(1), // All-Intra — every frame is I-frame
    AVVideoAllowFrameReorderingKey : @(NO), // No B-frames (explicit, defensive)
    AVVideoAverageBitRateKey : @(kVGSidecarBitrate), // 4 Mbps preview quality
    AVVideoExpectedSourceFrameRateKey : @((NSInteger)round(sourceFPS)),
    AVVideoProfileLevelKey : AVVideoProfileLevelH264HighAutoLevel,
  };
  NSDictionary *writerSettings = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @((NSInteger)outW),
    AVVideoHeightKey : @((NSInteger)outH),
    AVVideoCompressionPropertiesKey : compressionProps,
  };

  AVAssetWriterInput *writerInput =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:writerSettings];
  // expectsMediaDataInRealTime = NO: optimal for offline transcoding.
  // Allows the encoder to buffer and reorder internally for best throughput.
  writerInput.expectsMediaDataInRealTime = NO;

  // Natural transform: identity — orientation is already baked by the reader.
  // (Opus CORRECTION 3: sidecar output must have identity transform)
  writerInput.transform = CGAffineTransformIdentity;

  // Pixel buffer adaptor: use BGRA format to match the decoded buffers
  // directly.
  NSDictionary *adaptorAttrs = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferWidthKey : @((NSInteger)outW),
    (NSString *)kCVPixelBufferHeightKey : @((NSInteger)outH),
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [AVAssetWriterInputPixelBufferAdaptor
          assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                     sourcePixelBufferAttributes:adaptorAttrs];
  if (!adaptor) {
    for (id buf in pixelBuffers) {
      CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
    }
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorAdaptorCreationFailed
               detail:@"AVAssetWriterInputPixelBufferAdaptor creation failed"];
    return;
  }

  if (![writer canAddInput:writerInput]) {
    for (id buf in pixelBuffers) {
      CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
    }
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorWriterCreationFailed
               detail:@"Cannot add AVAssetWriterInput"];
    return;
  }
  [writer addInput:writerInput];

  if (![writer startWriting]) {
    for (id buf in pixelBuffers) {
      CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
    }
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorWriterCreationFailed
               detail:writer.error.localizedDescription
                          ?: @"startWriting failed"];
    return;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];

  // ── 10. Write frames in reverse visual order ──────────────────────────────
  // Output presentation timestamps are monotonically increasing (required by
  // AVAssetWriter). The i-th output PTS corresponds to the
  // (actualFrameCount-1-i)-th decoded frame, producing a forward-playable file
  // with reversed visual content.
  //
  // Frame duration: use actual decoded durations when available, falling back
  // to 1/sourceFPS. Output PTS accumulates from kCMTimeZero.
  double outputPTSSecs = 0.0;
  BOOL appendFailed = NO;

  for (NSInteger i = 0; i < actualFrameCount; i++) {
    // Write the (last - i)-th decoded frame first.
    NSInteger sourceIdx = actualFrameCount - 1 - i;
    CVPixelBufferRef pb = (__bridge CVPixelBufferRef)pixelBuffers[sourceIdx];

    CMTime outputPTS = CMTimeMakeWithSeconds(outputPTSSecs, 600);

    // Spin-wait for writer input to be ready (non-realtime encode path).
    // In practice this is immediate for offline encoding with the serial queue.
    NSInteger spinCount = 0;
    while (!writerInput.isReadyForMoreMediaData && spinCount < 100) {
      [NSThread sleepForTimeInterval:0.005]; // 5ms
      spinCount++;
    }
    if (!writerInput.isReadyForMoreMediaData) {
      os_log_error(sSidecarLog,
                   "[VGSidecar] writer not ready after spin: "
                   "clip=%{public}@ frame=%ld",
                   clipId, (long)i);
      appendFailed = YES;
      break;
    }

    BOOL appended = [adaptor appendPixelBuffer:pb
                          withPresentationTime:outputPTS];
    if (!appended) {
      os_log_error(sSidecarLog,
                   "[VGSidecar] append failed: clip=%{public}@ frame=%ld "
                   "writerStatus=%ld writerErr=%{public}@",
                   clipId, (long)i, (long)writer.status,
                   writer.error.localizedDescription);
      appendFailed = YES;
      break;
    }

    // Advance output PTS by the source frame's duration.
    // Use the matching decoded duration (same index in frameDurations).
    double frameDur = (sourceIdx < (NSInteger)frameDurations.count)
                          ? [frameDurations[sourceIdx] doubleValue]
                          : (1.0 / sourceFPS);
    outputPTSSecs += frameDur;

    // Update progress during write pass.
    if (i % 10 == 0 && actualFrameCount > 0) {
      double writeProgress =
          0.5 + 0.45 * ((double)i / (double)actualFrameCount);
      [self _updateProgress:writeProgress
                     clipId:clipId
                 generation:capturedGeneration];
    }
  }

  // Release all pixel buffers immediately after write pass.
  for (id buf in pixelBuffers) {
    CVPixelBufferRelease((__bridge CVPixelBufferRef)buf);
  }
  [pixelBuffers removeAllObjects];

  if (appendFailed) {
    [writerInput markAsFinished];
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtPath:sidecarPath error:nil];
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorAppendFailed
               detail:writer.error.localizedDescription
                          ?: @"appendPixelBuffer failed"];
    return;
  }

  // ── 11. Finish writing ────────────────────────────────────────────────────
  [writerInput markAsFinished];

  // Staleness guard before finishWriting.
  if (![self _isGenerationCurrent:capturedGeneration forClipId:clipId]) {
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtPath:sidecarPath error:nil];
    os_log(sSidecarLog,
           "[VGSidecar] stale before finishWriting: clip=%{public}@", clipId);
    return;
  }

  // finishWritingWithCompletionHandler: is async. Use a semaphore to wait.
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block BOOL finishOK = NO;
  __block NSError *finishErr = nil;

  [writer finishWritingWithCompletionHandler:^{
    finishOK = (writer.status == AVAssetWriterStatusCompleted);
    finishErr = writer.error;
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

  if (!finishOK) {
    [[NSFileManager defaultManager] removeItemAtPath:sidecarPath error:nil];
    [self
        _failClipId:clipId
         generation:capturedGeneration
              error:kVGSidecarErrorFinishWritingFailed
             detail:finishErr.localizedDescription ?: @"finishWriting failed"];
    return;
  }

  // ── 12. Verify file exists ────────────────────────────────────────────────
  if (![[NSFileManager defaultManager] fileExistsAtPath:sidecarPath]) {
    [self _failClipId:clipId
           generation:capturedGeneration
                error:kVGSidecarErrorFinishWritingFailed
               detail:@"Sidecar file missing after finishWriting"];
    return;
  }

  // ── 13. Staleness guard after writing ─────────────────────────────────────
  if (![self _isGenerationCurrent:capturedGeneration forClipId:clipId]) {
    [[NSFileManager defaultManager] removeItemAtPath:sidecarPath error:nil];
    os_log(sSidecarLog,
           "[VGSidecar] stale after finishWriting: clip=%{public}@", clipId);
    return;
  }

  // ── 14. Mark ready and fire completions ───────────────────────────────────
  [self _succeedClipId:clipId
            generation:capturedGeneration
           sidecarPath:sidecarPath
              duration:outputPTSSecs];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Video composition aspect-fit setup
// ─────────────────────────────────────────────────────────────────────────────

/// Applies aspect-fit canvas normalization to the video composition, matching
/// VGTimelineCompositorNode._buildReaderForClipIndex:startAtTime:error:
/// (Phase 7.9).
///
/// This ensures the decoded pixel buffers are orientation-normalized and
/// scaled to the target canvas size. (Opus CORRECTION 3)
- (void)_applyAspectFitComposition:(AVMutableVideoComposition *)videoComposition
                        videoTrack:(AVAssetTrack *)videoTrack
                          outWidth:(CGFloat)outWidth
                         outHeight:(CGFloat)outHeight
                       preferredTx:(CGAffineTransform)preferredTx
                          displayW:(CGFloat)displayW
                          displayH:(CGFloat)displayH {
  if (outWidth <= 0 || outHeight <= 0 || displayW <= 0 || displayH <= 0)
    return;

  // Compute aspect-fit scale (same logic as VGTimelineCompositorNode
  // Phase 7.9).
  CGFloat fitScale = MIN(outWidth / displayW, outHeight / displayH);
  CGFloat tx = (outWidth - displayW * fitScale) / 2.0;
  CGFloat ty = (outHeight - displayH * fitScale) / 2.0;

  // Compose: preferredTransform → uniform scale → center translate.
  CGAffineTransform fitTransform = CGAffineTransformConcat(
      preferredTx,
      CGAffineTransformConcat(CGAffineTransformMakeScale(fitScale, fitScale),
                              CGAffineTransformMakeTranslation(tx, ty)));

  AVMutableVideoCompositionLayerInstruction *layerInstr =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstr setTransform:fitTransform atTime:kCMTimeZero];

  // Cover the full asset duration; trim clamping is handled by
  // reader.timeRange.
  AVURLAsset *asset = (AVURLAsset *)videoTrack.asset;
  CMTime assetDuration =
      asset ? asset.duration : CMTimeMakeWithSeconds(3600, 600);

  AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, assetDuration);
  instruction.layerInstructions = @[ layerInstr ];

  videoComposition.renderSize = CGSizeMake(outWidth, outHeight);
  videoComposition.instructions = @[ instruction ];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - State helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns YES if the record's generation matches capturedGeneration.
/// Thread-safe (acquires lock).
- (BOOL)_isGenerationCurrent:(uint64_t)gen forClipId:(NSString *)clipId {
  os_unfair_lock_lock(&_lock);
  _VGSidecarRecord *record = __records[clipId];
  BOOL current = (record != nil && record.generation == gen);
  os_unfair_lock_unlock(&_lock);
  return current;
}

/// Updates the progress of a clip, if the generation is still current.
- (void)_updateProgress:(double)progress
                 clipId:(NSString *)clipId
             generation:(uint64_t)gen {
  os_unfair_lock_lock(&_lock);
  _VGSidecarRecord *record = __records[clipId];
  if (record && record.generation == gen &&
      record.state == VGReverseSidecarStatePreparing) {
    record.progress = progress;
  }
  os_unfair_lock_unlock(&_lock);
}

/// Transitions the clip to the failed state, fires pending completions.
- (void)_failClipId:(NSString *)clipId
         generation:(uint64_t)gen
              error:(NSString *)errorCode
             detail:(NSString *)detail {
  NSString *message =
      [NSString stringWithFormat:@"%@: %@", errorCode, detail ?: @""];
  os_log_error(sSidecarLog, "[VGSidecar] FAIL clip=%{public}@ err=%{public}@",
               clipId, message);

  NSMutableArray<void (^)(VGReverseSidecarStatus *)> *completionsToFire = nil;

  os_unfair_lock_lock(&_lock);
  _VGSidecarRecord *record = __records[clipId];
  if (record && record.generation == gen) {
    record.state = VGReverseSidecarStateFailed;
    record.errorMessage = message;
    record.sidecarPath = nil;
    record.progress = 0.0;
    completionsToFire = [record.pendingCompletions mutableCopy];
    [record.pendingCompletions removeAllObjects];
  }
  os_unfair_lock_unlock(&_lock);

  if (!completionsToFire.count)
    return;
  VGReverseSidecarStatus *failStatus =
      [VGReverseSidecarStatus statusWithState:VGReverseSidecarStateFailed
                                  sidecarPath:nil
                                 errorMessage:message
                                     progress:0.0];
  for (void (^completion)(VGReverseSidecarStatus *) in completionsToFire) {
    completion(failStatus);
  }
}

/// Transitions the clip to the ready state, fires pending completions.
- (void)_succeedClipId:(NSString *)clipId
            generation:(uint64_t)gen
           sidecarPath:(NSString *)path
              duration:(double)duration {
  os_log(sSidecarLog,
         "[VGSidecar] READY clip=%{public}@ path=%{public}@ duration=%.3fs",
         clipId, path, duration);

  NSMutableArray<void (^)(VGReverseSidecarStatus *)> *completionsToFire = nil;

  os_unfair_lock_lock(&_lock);
  _VGSidecarRecord *record = __records[clipId];
  if (record && record.generation == gen) {
    record.state = VGReverseSidecarStateReady;
    record.sidecarPath = [path copy];
    record.errorMessage = nil;
    record.progress = 1.0;
    completionsToFire = [record.pendingCompletions mutableCopy];
    [record.pendingCompletions removeAllObjects];
  }
  os_unfair_lock_unlock(&_lock);

  if (!completionsToFire.count)
    return;
  VGReverseSidecarStatus *readyStatus =
      [VGReverseSidecarStatus statusWithState:VGReverseSidecarStateReady
                                  sidecarPath:path
                                 errorMessage:nil
                                     progress:1.0];
  for (void (^completion)(VGReverseSidecarStatus *) in completionsToFire) {
    completion(readyStatus);
  }
}

@end
