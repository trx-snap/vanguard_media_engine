// VGVideoExportSession.m
// vanguard_media_engine — Phase 5C-5
//
// Full pipeline integration: VGExportGraphFactory + VGExportScheduler +
// VGVideoEncoderSinkNode → offline MP4 export.
//
// Pull-mode only. No VGGraphSchedulerV2. No push callbacks. No camera path.
//
// Key architectural invariants:
//   - All nodes prepared via dispatch_group before scheduler starts.
//   - Scheduler.completionHandler fires finalizeExportWithError: on success.
//   - finalizeExportWithError: runs after pull loop exits — no deadlock.
//   - Completion fires exactly once via atomic _completionFired gate.
//   - cancel is atomic: _cancelledAtomic flag + [scheduler cancelExport].
//   - dealloc invalidates scheduler as safety net.
//
// NOT imported:
//   VGGraphSchedulerV2, VanguardFileMediaSource, VanguardGraphRuntime,
//   VanguardMetalRenderer, VGFrameDelegate.

#import "VGVideoExportSession.h"

#import "VGExportScheduler.h"
#import "VGExportGraphFactory.h"
#import "VGVideoEncoderSinkNode.h"
#import "VGExportFileSourceNode.h"

#import <UMF/VGNode.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGResourceAllocator.h>

#import <os/log.h>
#include <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

static os_log_t sSessionLog;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - @implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGVideoExportSession {
    // Init-time config (all strongly retained)
    AVAsset                             *_asset;
    VGExportProfile                     *_profile;
    NSURL                               *_outputURL;
    NSArray                             *_filterChain;  // nullable

    // Pipeline objects (created in startWithCompletion:, strongly retained)
    VGVideoEncoderSinkNode              *_sink;
    VGExportScheduler                   *_scheduler;
    VGGraphExecutionContext             *_context;
    VGGraphDescriptor                   *_descriptor;
    NSDictionary<NSString *, id<VGNode>> *_nodes;
    VGExecutionPlan                     *_plan;

    // User completion block (copied)
    void (^_completion)(VGExportManifest * _Nullable, NSError * _Nullable);

    // State flags (atomic for thread-safety)
    _Atomic(BOOL)     _startedAtomic;
    _Atomic(BOOL)     _cancelledAtomic;
    _Atomic(BOOL)     _finishedAtomic;

    // CAS gate: 0→1, ensures completion fires exactly once
    _Atomic(int32_t)  _completionFired;
}

// ─── Synthesize ───────────────────────────────────────────────────────────────

@synthesize exporting  = _exporting;
@synthesize cancelled  = _cancelled;
@synthesize finished   = _finished;

// ─── Initialization ───────────────────────────────────────────────────────────

+ (void)initialize {
    if (self == [VGVideoExportSession class]) {
        sSessionLog = os_log_create("com.vanguard.engine", "videoExportSession");
    }
}

- (instancetype)initWithAsset:(AVAsset *)asset
                      profile:(VGExportProfile *)profile
                    outputURL:(NSURL *)outputURL
                  filterChain:(nullable NSArray *)filterChain {
    NSParameterAssert(asset != nil);
    NSParameterAssert(profile != nil);
    NSParameterAssert(outputURL != nil);

    self = [super init];
    if (!self) return nil;

    _asset       = asset;
    _profile     = profile;
    _outputURL   = outputURL;
    _filterChain = filterChain;

    atomic_store(&_startedAtomic,    NO);
    atomic_store(&_cancelledAtomic,  NO);
    atomic_store(&_finishedAtomic,   NO);
    atomic_store(&_completionFired,  0);

    os_log_debug(sSessionLog,
                 "[VGVideoExportSession] init outputURL=%{public}@",
                 outputURL.lastPathComponent);
    return self;
}

// ─── State accessors ──────────────────────────────────────────────────────────

- (BOOL)isExporting  {
    return atomic_load(&_startedAtomic) && !atomic_load(&_finishedAtomic);
}
- (BOOL)isCancelled  { return (BOOL)atomic_load(&_cancelledAtomic); }
- (BOOL)isFinished   { return (BOOL)atomic_load(&_finishedAtomic); }

// ─── Cancel ───────────────────────────────────────────────────────────────────

- (void)cancel {
    atomic_store(&_cancelledAtomic, YES);
    [_scheduler cancelExport];   // nil-safe; no-op if scheduler not yet created
    os_log_debug(sSessionLog, "[VGVideoExportSession] cancel requested");
}

// ─── Start ────────────────────────────────────────────────────────────────────

- (void)startWithCompletion:(void (^)(VGExportManifest * _Nullable,
                                      NSError * _Nullable))completion {
    // ── Guard: single-use ─────────────────────────────────────────────────────
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong(&_startedAtomic, &expected, YES)) {
        // Already started — no-op (do not fire completion again)
        os_log_debug(sSessionLog,
                     "[VGVideoExportSession] startWithCompletion: already started, ignoring");
        return;
    }

    _completion = [completion copy];

    // ── Guard: pre-cancelled ──────────────────────────────────────────────────
    if (atomic_load(&_cancelledAtomic)) {
        NSError *cancelErr = [self _cancelledError];
        [self _fireCompletionWithManifest:nil error:cancelErr];
        return;
    }

    // ── Guard: nil inputs ─────────────────────────────────────────────────────
    if (!_asset || !_profile || !_outputURL) {
        NSError *err = [NSError errorWithDomain:@"VGVideoExportSession"
                                           code:1
                                       userInfo:@{
            NSLocalizedDescriptionKey: @"asset, profile, and outputURL must be non-nil"
        }];
        [self _fireCompletionWithManifest:nil error:err];
        return;
    }

    // ── Step 1: Create sink ───────────────────────────────────────────────────
    _sink = [[VGVideoEncoderSinkNode alloc] initWithOutputURL:_outputURL
                                                      profile:_profile];

    // ── Step 2: Build graph ───────────────────────────────────────────────────
    NSError *graphErr = nil;
    NSDictionary *graphResult = [VGExportGraphFactory
        buildExportGraphWithAsset:_asset
                      filterChain:_filterChain
                             sink:_sink
                            error:&graphErr];

    if (!graphResult) {
        NSError *err = graphErr ?: [NSError errorWithDomain:@"VGVideoExportSession"
                                                       code:2
                                                   userInfo:@{
            NSLocalizedDescriptionKey: @"VGExportGraphFactory returned nil"
        }];
        os_log_error(sSessionLog,
                     "[VGVideoExportSession] graph build failed: %{public}@", err);
        [self _fireCompletionWithManifest:nil error:err];
        return;
    }

    _descriptor = graphResult[@"descriptor"];
    _nodes      = graphResult[@"nodes"];
    _plan       = graphResult[@"plan"];

    // ── Step 3: Create VGGraphExecutionContext ────────────────────────────────
    //
    // clock=nil: VGGraphExecutionContext.h L91 — "Nil for pull-mode (export)
    // graphs that do not need a real-time clock."
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    _context = [[VGGraphExecutionContext alloc] initWithDescriptor:_descriptor
                                                              plan:_plan
                                                             nodes:_nodes
                                                             clock:nil
                                                 resourceAllocator:allocator];

    if (!_context) {
        NSError *err = [NSError errorWithDomain:@"VGVideoExportSession"
                                           code:3
                                       userInfo:@{
            NSLocalizedDescriptionKey: @"VGGraphExecutionContext creation failed"
        }];
        [self _fireCompletionWithManifest:nil error:err];
        return;
    }

    // ── Step 4: Prepare all nodes (async dispatch_group barrier) ──────────────
    //
    // VGNode.h L82: "completion fires on a background queue, never synchronously."
    // We MUST use dispatch_group to handle asynchronous prepare completions.
    //
    // Implementation:
    //   - Enter group once per node before calling prepareWithContext:completion:
    //   - Leave group in each completion block
    //   - dispatch_group_notify fires on a private queue after ALL completions
    //   - Exactly one prepare error (first non-nil) is captured under a lock
    //
    [self _prepareAllNodesWithCompletion:^(NSError * _Nullable prepareError) {
        if (prepareError) {
            os_log_error(sSessionLog,
                         "[VGVideoExportSession] node prepare failed: %{public}@",
                         prepareError);
            [self _fireCompletionWithManifest:nil error:prepareError];
            return;
        }

        // ── Step 5: Create scheduler ──────────────────────────────────────────
        VGExportScheduler *scheduler =
            [[VGExportScheduler alloc] initWithPlan:self->_plan
                                              nodes:self->_nodes
                                            context:self->_context
                                                fps:self->_profile.fps];
        self->_scheduler = scheduler;

        // ── Step 6: Wire sink (weak in scheduler; strong in session) ──────────
        scheduler.sink = self->_sink;

        // ── Step 7: Wire completionHandler ────────────────────────────────────
        __weak typeof(self) weakSelf = self;
        scheduler.completionHandler = ^(BOOL success, NSError * _Nullable schedErr) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (success) {
                // Pull loop reached EOS — finalize sink (flushes encoder + muxes MP4)
                // This is safe: runs after the pull loop exits on the export queue.
                NSError *finalizeErr = nil;
                VGExportManifest *manifest =
                    [strongSelf->_sink finalizeExportWithError:&finalizeErr];
                [strongSelf _fireCompletionWithManifest:manifest error:finalizeErr];
            } else {
                // Export failed or cancelled — invalidate sink and propagate error
                [strongSelf->_sink invalidate];
                NSError *err = schedErr ?: [NSError errorWithDomain:@"VGVideoExportSession"
                                                               code:4
                                                           userInfo:@{
                    NSLocalizedDescriptionKey: @"Export scheduler failed or was cancelled"
                }];
                [strongSelf _fireCompletionWithManifest:nil error:err];
            }
        };

        // ── Step 8: Start export (async — pull loop on private serial queue) ──
        [scheduler startExport];
        os_log_debug(sSessionLog, "[VGVideoExportSession] export started");
    }];
}

// ─── Private: prepare barrier ─────────────────────────────────────────────────

/// Prepares all nodes via dispatch_group. Fires completion exactly once on a
/// background queue after all prepareWithContext:completion: callbacks return.
- (void)_prepareAllNodesWithCompletion:(void (^)(NSError * _Nullable))completion {
    NSDictionary<NSString *, id<VGNode>> *nodes = _nodes;
    VGGraphExecutionContext *context = _context;

    if (nodes.count == 0) {
        // No nodes to prepare — proceed immediately
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            completion(nil);
        });
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t resultQueue =
        dispatch_queue_create("com.vanguard.export.prepare", DISPATCH_QUEUE_SERIAL);

    // Captured under resultQueue for thread-safety (exactly-once first-error)
    __block NSError *firstError = nil;

    for (NSString *nodeId in nodes) {
        id<VGNode> node = nodes[nodeId];
        if (!node) continue;

        dispatch_group_enter(group);
        [node prepareWithContext:context completion:^(NSError * _Nullable err) {
            dispatch_async(resultQueue, ^{
                if (err && !firstError) {
                    firstError = err;
                }
                dispatch_group_leave(group);
            });
        }];
    }

    dispatch_group_notify(group, resultQueue, ^{
        NSError *captured = firstError;
        completion(captured);
    });
}

// ─── Private: completion gate ─────────────────────────────────────────────────

/// Fire user completion exactly once via CAS gate (0→1).
- (void)_fireCompletionWithManifest:(nullable VGExportManifest *)manifest
                              error:(nullable NSError *)error {
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_completionFired, &expected, 1)) {
        return;  // completion already fired
    }

    atomic_store(&_finishedAtomic, YES);

    void (^cb)(VGExportManifest *, NSError *) = _completion;
    _completion = nil;  // release block

    if (cb) {
        cb(manifest, error);
    }
}

// ─── Private: error helpers ───────────────────────────────────────────────────

- (NSError *)_cancelledError {
    return [NSError errorWithDomain:@"VGVideoExportSession"
                               code:5
                           userInfo:@{
        NSLocalizedDescriptionKey: @"Export was cancelled before it started"
    }];
}

// ─── Dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    // Safety net: invalidate scheduler if still running at dealloc time.
    // This cancels the pull loop and fires completionHandler (if not already fired).
    [_scheduler invalidate];
}

@end

NS_ASSUME_NONNULL_END
