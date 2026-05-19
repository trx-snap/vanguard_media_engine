// VGFanOutSink.h
// vanguard_media_engine — Phase 6A-1
//
// VGFanOutSink is a composite VGFrameSink node that forwards incoming frame
// envelopes to an ordered set of child sinks. It presents itself to the V2
// scheduler as a single sink node, keeping VGGraphSchedulerV2 unchanged.
//
// Key Contracts:
//   - Ordered array of child sinks must not contain nil or empty values.
//   - Sync forwarding: synchronous presentEnvelope: invocation on children.
//   - Zero buffer retention beyond the presentEnvelope: call duration.
//   - Thread safety: delegates thread safety to children.
//
// Phase 6A-1: Structural implementation only.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

/// A composite VGFrameSink that fans out presentEnvelope: calls to multiple child sinks in order.
@interface VGFanOutSink : NSObject <VGFrameSink>

/// The synthesized nodeId for this composite sink.
@property (nonatomic, readonly, copy) NSString *nodeId;

/// The list of child sinks.
@property (nonatomic, readonly, copy) NSArray<id<VGFrameSink>> *sinks;

/// Designated initializer.
///
/// Rejects sinks array if nil, empty, or if any element does not conform to VGFrameSink.
/// Rejects nodeId if nil or empty.
///
/// @param nodeId The unique node identifier in the graph.
/// @param sinks  The ordered list of child sinks. Must have at least 1 child.
/// @return An initialized fan-out sink instance, or nil if validation fails.
- (nullable instancetype)initWithNodeId:(NSString *)nodeId
                                  sinks:(NSArray<id<VGFrameSink>> *)sinks NS_DESIGNATED_INITIALIZER;

/// Convenience initializer using a default node ID of @"fan_out_sink".
///
/// @param sinks The ordered list of child sinks. Must have at least 1 child.
/// @return An initialized fan-out sink instance, or nil if validation fails.
- (nullable instancetype)initWithSinks:(NSArray<id<VGFrameSink>> *)sinks;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
