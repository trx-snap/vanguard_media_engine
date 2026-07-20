// VGAudioSessionTransitionCoordinator.m
// Vanguard Media Engine — Audio Slice N

#import "VGAudioSessionTransitionCoordinator.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── Stable error domain ──────────────────────────────────────────────────────

NSString * const VGSessionTransitionErrorDomain = @"VGSessionTransitionErrorDomain";

typedef NS_ENUM(NSInteger, VGSessionTransitionError) {
    VGSessionTransitionErrorCategoryFailed     = 1,
    VGSessionTransitionErrorActivationFailed   = 2,
    VGSessionTransitionErrorRollbackFailed     = 3,
    VGSessionTransitionErrorNormalizationFailed = 4,
    VGSessionTransitionErrorInvalidState       = 5,
};

static NSError *_makeSessionError(VGSessionTransitionError code, NSString *msg) {
    return [NSError errorWithDomain:VGSessionTransitionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSError *_makeSessionErrorWithUnderlying(VGSessionTransitionError code,
                                                NSString *msg,
                                                NSError * _Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary
                                  dictionaryWithObject:msg
                                               forKey:NSLocalizedDescriptionKey];
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:VGSessionTransitionErrorDomain
                               code:code
                           userInfo:[info copy]];
}

// ─── Production AVAudioSession backend ───────────────────────────────────────

@interface _VGProductionSessionBackend : NSObject <VGAudioSessionBackend>
@end

@implementation _VGProductionSessionBackend

- (BOOL)setCategory:(AVAudioSessionCategory)category
         withOptions:(AVAudioSessionCategoryOptions)options
               error:(NSError * _Nullable * _Nullable)outError {
    return [[AVAudioSession sharedInstance] setCategory:category
                                           withOptions:options
                                                 error:outError];
}

- (BOOL)setActiveYesWithError:(NSError * _Nullable * _Nullable)outError {
    return [[AVAudioSession sharedInstance] setActive:YES error:outError];
}

- (VGRouteSnapshot *)currentRoute {
    AVAudioSessionRouteDescription *route =
        [AVAudioSession sharedInstance].currentRoute;

    NSMutableArray<VGPortSnapshot *> *inputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in route.inputs) {
        [inputs addObject:
            [[VGPortSnapshot alloc]
                initWithPortType:p.portType
                        portName:p.portName
                             UID:p.UID
          selectedDataSourceName:p.selectedDataSource.dataSourceName]];
    }

    NSMutableArray<VGPortSnapshot *> *outputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in route.outputs) {
        [outputs addObject:
            [[VGPortSnapshot alloc]
                initWithPortType:p.portType
                        portName:p.portName
                             UID:p.UID
          selectedDataSourceName:p.selectedDataSource.dataSourceName]];
    }

    return [[VGRouteSnapshot alloc] initWithInputs:inputs outputs:outputs];
}

- (NSArray<VGPortSnapshot *> *)availableInputs {
    NSArray<AVAudioSessionPortDescription *> *avail =
        [AVAudioSession sharedInstance].availableInputs ?: @[];
    NSMutableArray<VGPortSnapshot *> *result = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in avail) {
        [result addObject:
            [[VGPortSnapshot alloc]
                initWithPortType:p.portType
                        portName:p.portName
                             UID:p.UID
          selectedDataSourceName:p.selectedDataSource.dataSourceName]];
    }
    return result;
}

@end

// ─── VGSessionTransitionOutcome ──────────────────────────────────────────────

@implementation VGSessionTransitionOutcome

- (instancetype)_initWithStatus:(VGSessionTransitionStatus)status
                    primaryError:(nullable NSError *)primary
                  secondaryError:(nullable NSError *)secondary {
    self = [super init];
    if (self) {
        _status        = status;
        _primaryError  = primary;
        _secondaryError = secondary;
    }
    return self;
}

+ (instancetype)success {
    return [[self alloc] _initWithStatus:VGSessionTransitionStatusSuccess
                            primaryError:nil
                          secondaryError:nil];
}

+ (instancetype)failureWithStatus:(VGSessionTransitionStatus)status
                     primaryError:(NSError *)primaryError
                   secondaryError:(nullable NSError *)secondaryError {
    return [[self alloc] _initWithStatus:status
                            primaryError:primaryError
                          secondaryError:secondaryError];
}

@end

// ─── VGAudioSessionTransitionCoordinator ─────────────────────────────────────

@implementation VGAudioSessionTransitionCoordinator {
    id<VGAudioSessionBackend> _backend;
    VGSessionCoordinatorState _state;
}

- (instancetype)initWithSessionBackend:(nullable id<VGAudioSessionBackend>)backend {
    self = [super init];
    if (self) {
        _backend = backend ?: [[_VGProductionSessionBackend alloc] init];
        _state   = VGSessionCoordinatorStatePlayback;
    }
    return self;
}

- (instancetype)init {
    return [self initWithSessionBackend:nil];
}

- (VGSessionCoordinatorState)state {
    return _state;
}

// ── switchToPlayAndRecord ────────────────────────────────────────────────────

- (VGSessionTransitionOutcome *)switchToPlayAndRecord {
    NSAssert([NSThread isMainThread],
             @"VGAudioSessionTransitionCoordinator: must be called on main thread");

    if (_state != VGSessionCoordinatorStatePlayback) {
        NSError *err = _makeSessionError(VGSessionTransitionErrorInvalidState,
            @"switchToPlayAndRecord called from invalid state");
        return [VGSessionTransitionOutcome failureWithStatus:VGSessionTransitionStatusFailedNoMutation
                                               primaryError:err
                                             secondaryError:nil];
    }

    _state = VGSessionCoordinatorStateEnteringRecord;

    // Step 1: set category.
    NSError *catErr = nil;
    BOOL catOK = [_backend
        setCategory:AVAudioSessionCategoryPlayAndRecord
        withOptions:(AVAudioSessionCategoryOptionMixWithOthers |
                     AVAudioSessionCategoryOptionAllowBluetoothHFP |
                     AVAudioSessionCategoryOptionAllowBluetoothA2DP)
              error:&catErr];

    if (!catOK) {
        // No mutation — category was not changed.
        _state = VGSessionCoordinatorStatePlayback;
        NSError *wrapped = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorCategoryFailed,
            @"setCategory:PlayAndRecord failed", catErr);
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedNoMutation
                 primaryError:wrapped
               secondaryError:nil];
    }

    // Step 2: activate.
    NSError *actErr = nil;
    BOOL actOK = [_backend setActiveYesWithError:&actErr];
    if (actOK) {
        _state = VGSessionCoordinatorStateRecord;
        NSLog(@"[VGCoordinator] switched to PlayAndRecord");
        return [VGSessionTransitionOutcome success];
    }

    // Activation failed — attempt rollback to Playback.
    NSError *primaryErr = _makeSessionErrorWithUnderlying(
        VGSessionTransitionErrorActivationFailed,
        @"setActive:YES failed for PlayAndRecord", actErr);

    NSError *rbCatErr = nil;
    BOOL rbCatOK = [_backend
        setCategory:AVAudioSessionCategoryPlayback
        withOptions:0
              error:&rbCatErr];

    if (!rbCatOK) {
        _state = VGSessionCoordinatorStateUnknown;
        NSError *secondary = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorRollbackFailed,
            @"setCategory:Playback rollback also failed", rbCatErr);
        NSLog(@"[VGCoordinator] switchToPlayAndRecord rollback FAILED → unknown");
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:primaryErr
               secondaryError:secondary];
    }

    NSError *rbActErr = nil;
    BOOL rbActOK = [_backend setActiveYesWithError:&rbActErr];
    if (!rbActOK) {
        // setCategory:Playback succeeded but setActive:YES failed.
        // The session is in an unknown state.
        _state = VGSessionCoordinatorStateUnknown;
        NSError *secondary = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorRollbackFailed,
            @"setActive:YES for Playback rollback failed", rbActErr);
        NSLog(@"[VGCoordinator] rollback setActive:YES failed → unknown");
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:primaryErr
               secondaryError:secondary];
    }

    _state = VGSessionCoordinatorStatePlayback;
    NSLog(@"[VGCoordinator] switchToPlayAndRecord failed — rolled back to Playback");
    return [VGSessionTransitionOutcome
        failureWithStatus:VGSessionTransitionStatusFailedKnownPlayback
             primaryError:primaryErr
           secondaryError:nil];
}

// ── restorePlayback ──────────────────────────────────────────────────────────

- (VGSessionTransitionOutcome *)restorePlayback {
    NSAssert([NSThread isMainThread],
             @"VGAudioSessionTransitionCoordinator: must be called on main thread");

    if (_state == VGSessionCoordinatorStatePlayback) {
        // Already in playback — idempotent success.
        return [VGSessionTransitionOutcome success];
    }

    _state = VGSessionCoordinatorStateRestoringPlayback;

    NSError *catErr = nil;
    BOOL catOK = [_backend setCategory:AVAudioSessionCategoryPlayback
                           withOptions:0
                                 error:&catErr];
    if (!catOK) {
        _state = VGSessionCoordinatorStateUnknown;
        NSError *wrapped = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorCategoryFailed,
            @"setCategory:Playback restoration failed", catErr);
        NSLog(@"[VGCoordinator] restorePlayback category failed → unknown");
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:wrapped
               secondaryError:nil];
    }

    NSError *actErr = nil;
    BOOL actOK = [_backend setActiveYesWithError:&actErr];
    if (!actOK) {
        _state = VGSessionCoordinatorStateUnknown;
        NSError *wrapped = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorActivationFailed,
            @"setActive:YES for Playback restoration failed", actErr);
        NSLog(@"[VGCoordinator] restorePlayback activation failed → unknown");
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:wrapped
               secondaryError:nil];
    }

    _state = VGSessionCoordinatorStatePlayback;
    NSLog(@"[VGCoordinator] restored to Playback");
    return [VGSessionTransitionOutcome success];
}

// ── normalizationAttempt ─────────────────────────────────────────────────────

- (VGSessionTransitionOutcome *)normalizationAttempt {
    NSAssert([NSThread isMainThread],
             @"VGAudioSessionTransitionCoordinator: must be called on main thread");

    if (_state == VGSessionCoordinatorStatePlayback) {
        // Already in a known Playback state.
        return [VGSessionTransitionOutcome success];
    }

    NSError *catErr = nil;
    BOOL catOK = [_backend setCategory:AVAudioSessionCategoryPlayback
                           withOptions:0
                                 error:&catErr];

    if (!catOK) {
        _state = VGSessionCoordinatorStateUnknown;
        NSError *wrapped = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorNormalizationFailed,
            @"normalizationAttempt setCategory:Playback failed", catErr);
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:wrapped
               secondaryError:nil];
    }

    NSError *actErr = nil;
    BOOL actOK = [_backend setActiveYesWithError:&actErr];
    if (!actOK) {
        _state = VGSessionCoordinatorStateUnknown;
        NSError *wrapped = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorNormalizationFailed,
            @"normalizationAttempt setActive:YES failed", actErr);
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:wrapped
               secondaryError:nil];
    }

    _state = VGSessionCoordinatorStatePlayback;
    NSLog(@"[VGCoordinator] normalization succeeded → Playback");
    return [VGSessionTransitionOutcome success];
}

// ── forceNormalizePlaybackAfterExternalChange ─────────────────────────────────

- (VGSessionTransitionOutcome *)forceNormalizePlaybackAfterExternalChange {
    NSAssert([NSThread isMainThread],
             @"VGAudioSessionTransitionCoordinator: must be called on main thread");

    // Unlike restorePlayback / normalizationAttempt, we do NOT short-circuit
    // when _state == Playback. The OS may have silently mutated the session
    // category during interruption or background, making our cached state stale.
    // We unconditionally re-assert the Playback category and re-activate.

    NSLog(@"[VGCoordinator] forceNormalizePlaybackAfterExternalChange — forcing Playback");

    NSError *catErr = nil;
    BOOL catOK = [_backend setCategory:AVAudioSessionCategoryPlayback
                           withOptions:0
                                 error:&catErr];
    if (!catOK) {
        _state = VGSessionCoordinatorStateUnknown;
        NSError *wrapped = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorNormalizationFailed,
            @"forceNormalize setCategory:Playback failed", catErr);
        NSLog(@"[VGCoordinator] forceNormalize setCategory failed → unknown");
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:wrapped
               secondaryError:nil];
    }

    NSError *actErr = nil;
    BOOL actOK = [_backend setActiveYesWithError:&actErr];
    if (!actOK) {
        _state = VGSessionCoordinatorStateUnknown;
        NSError *wrapped = _makeSessionErrorWithUnderlying(
            VGSessionTransitionErrorActivationFailed,
            @"forceNormalize setActive:YES failed", actErr);
        NSLog(@"[VGCoordinator] forceNormalize setActive:YES failed → unknown");
        return [VGSessionTransitionOutcome
            failureWithStatus:VGSessionTransitionStatusFailedUnknown
                 primaryError:wrapped
               secondaryError:nil];
    }

    _state = VGSessionCoordinatorStatePlayback;
    NSLog(@"[VGCoordinator] forceNormalize succeeded → Playback");
    return [VGSessionTransitionOutcome success];
}

// ── captureRouteSnapshot ──────────────────────────────────────────────────────

- (VGAudioRouteSnapshot *)captureRouteSnapshot {
    NSAssert([NSThread isMainThread],
             @"VGAudioSessionTransitionCoordinator: must be called on main thread");

    VGRouteSnapshot *route = [_backend currentRoute];
    NSArray<VGPortSnapshot *> *available = [_backend availableInputs];

    return VGBuildAudioRouteSnapshot(route.inputs, route.outputs, available);
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
