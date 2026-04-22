// VanguardPlaybackTypes.h
// Shared playback type definitions — imported by VanguardFileMediaSource,
// VanguardGraphRuntime, and any future Phase 2+ components that reason
// about audio role.
//
// Single source of truth for VGAudioRole.
// Do NOT redefine this enum in any other header.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Audio role assigned to a VanguardFileMediaSource instance.
/// Resolved by VanguardGraphRuntime after VGResourceAllocator arbitration.
/// The source itself never calls requestAudioActivation: — it reads this
/// value as a gate inside _setupAudioEngine.
typedef NS_ENUM(NSInteger, VGAudioRole) {
    VGAudioRoleActive = 0,  ///< AVAudioEngine runs; source owns active audio output
    VGAudioRoleMuted  = 1,  ///< AVAudioEngine skipped; wall-clock fallback active
};

NS_ASSUME_NONNULL_END
