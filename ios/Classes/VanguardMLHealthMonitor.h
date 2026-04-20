// VanguardMLHealthMonitor.h
// Phase 4 — Silent stall detection for the ML snapshot pipeline
//
// Runs a 3-second background timer that checks if the VanguardMaskStore's
// generation counter has advanced. If it hasn't moved for 6 consecutive seconds
// (2 check intervals) while the model should be running, a stall is declared
// and the delegate is notified to trigger a fault transition.
//
// NOT in the hot path. NOT polled. Never touches capture or render queues.

#import <Foundation/Foundation.h>
#import "VanguardMaskStore.h"

NS_ASSUME_NONNULL_BEGIN

@protocol VanguardMLHealthMonitorDelegate <NSObject>
- (void)mlHealthMonitorDetectedStall:(NSString *)reason;
@end

@interface VanguardMLHealthMonitor : NSObject

- (instancetype)initWithMaskStore:(VanguardMaskStore *)store
                         delegate:(id<VanguardMLHealthMonitorDelegate>)delegate
NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Start monitoring. Safe to call multiple times (idempotent).
- (void)startMonitoring;

/// Stop monitoring (call on Camera Mode exit).
- (void)stopMonitoring;

@end

NS_ASSUME_NONNULL_END
