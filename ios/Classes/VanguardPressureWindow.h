// VanguardPressureWindow.h
// Phase 4 — Sliding-window backpressure aggregator
//
// Replaces per-frame consecutive-count triggers with a 2-second rolling window
// that counts discrete pressure events (encoder drops, pool exhaustions, etc.).
//
// Rules:
//   • recordDrop MUST be called from a single serial queue (caller's queue).
//   • Delegate callbacks fire on the same queue as recordDrop.
//   • Window rolls automatically; caller never resets state manually.
//   • Thresholds represent events per 2-second window, not consecutive frames.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VanguardPressureWindowDelegate;

@interface VanguardPressureWindow : NSObject

/// @param name        Human-readable label for logging (e.g. "encoder", "ml-pool")
/// @param threshold   Events per 2-second window to trigger degradation callback
/// @param recovery    Events per 2-second window to allow recovery callback
///                    (must be < threshold; typically threshold / 3)
/// @param delegate    Receives pressure and recovery events
- (instancetype)initWithName:(NSString *)name
                   threshold:(NSInteger)threshold
                    recovery:(NSInteger)recovery
                    delegate:(id<VanguardPressureWindowDelegate>)delegate
NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Record one pressure event. O(1). Must be called on the owner's serial queue.
- (void)recordDrop;

/// Current state for logging/debugging.
@property (readonly, nonatomic) NSInteger currentWindowDrops;
@property (readonly, nonatomic) BOOL      isPressured;

@end

@protocol VanguardPressureWindowDelegate <NSObject>

/// Fired when drops exceed `threshold` within the 2-second window.
/// Called on the same queue as `recordDrop`.
- (void)pressureWindowDidExceedThreshold:(VanguardPressureWindow *)window
                                   drops:(NSInteger)drops;

/// Fired when drops fall below `recovery` for two consecutive windows.
/// Called on the same queue as `recordDrop`.
- (void)pressureWindowDidRecover:(VanguardPressureWindow *)window;

@end

NS_ASSUME_NONNULL_END
