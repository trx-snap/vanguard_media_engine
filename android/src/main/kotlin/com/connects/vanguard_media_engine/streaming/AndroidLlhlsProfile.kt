// Copyright (c) Connects - Android LL-HLS experimental transfer (qualified lab profile clockfast1350).
// Default-off. This object owns only the tested Media3 configuration and the construction-time
// eligibility rule. It makes no recovery decisions, parses nothing and renders nothing.

package com.connects.vanguard_media_engine.streaming

import android.os.Build
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.DefaultLivePlaybackSpeedControl
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LivePlaybackSpeedControl

/**
 * Qualified Android LL-HLS client profile (`clockfast1350`), transferred verbatim from the lab:
 *
 * - streaming [DefaultLoadControl] 750 / 3000 / 350 / 500 ms,
 * - [MediaItem.LiveConfiguration] target offset 1350 ms, speed limits 0.97 / 1.30,
 * - [DefaultLivePlaybackSpeedControl] smoothing 0.90 and proportional factor 1.0, with the
 *   1350 ms target reasserted whenever Media3 forwards a live configuration.
 *
 * Every other Media3 behaviour (ABR, rebuffer response, startup position) is left at its default.
 * The 1.30 maximum is a control limit, not a claim about effective AudioTrack speed.
 *
 * Eligibility ([isEligible]) is evaluated exactly once at session construction; there is no
 * runtime fallback from the experimental profile to the ordinary one.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
object AndroidLlhlsProfile {

    const val PROFILE_NAME = "clockfast1350"

    const val MIN_BUFFER_MS = 750
    const val MAX_BUFFER_MS = 3_000
    const val BUFFER_FOR_PLAYBACK_MS = 350
    const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 500

    const val TARGET_OFFSET_MS = 1_350L
    const val MIN_PLAYBACK_SPEED = 0.97f
    const val MAX_PLAYBACK_SPEED = 1.30f

    const val MIN_POSSIBLE_LIVE_OFFSET_SMOOTHING_FACTOR = 0.90f
    const val PROPORTIONAL_CONTROL_FACTOR = 1.0f

    /** The headless ImageReader bridge requires API 29; the experiment never runs below it. */
    const val MIN_SDK_INT = Build.VERSION_CODES.Q

    /**
     * Construction-time eligibility. All conditions are required:
     * explicit opt-in, explicit HLS, LOW_LATENCY profile, no start position, read-through cache
     * disabled, and API >= [MIN_SDK_INT].
     */
    fun isEligible(config: HttpAdaptiveStreamConfig, sdkInt: Int): Boolean =
        config.androidLlhlsExperiment &&
            config.formatHint == AdaptiveStreamFormat.HLS &&
            config.networkProfile == AdaptiveStreamingNetworkProfile.LOW_LATENCY &&
            config.startPositionMs == null &&
            !config.cacheConfig.enabled &&
            sdkInt >= MIN_SDK_INT

    /** Tested streaming buffer windows; all other [DefaultLoadControl] defaults preserved. */
    fun buildLoadControl(): DefaultLoadControl =
        DefaultLoadControl.Builder()
            .setBufferDurationsMsForStreaming(
                MIN_BUFFER_MS,
                MAX_BUFFER_MS,
                BUFFER_FOR_PLAYBACK_MS,
                BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
            )
            .build()

    /** Tested live configuration attached to the HLS [MediaItem]. */
    fun buildLiveConfiguration(): MediaItem.LiveConfiguration =
        MediaItem.LiveConfiguration.Builder()
            .setTargetOffsetMs(TARGET_OFFSET_MS)
            .setMinPlaybackSpeed(MIN_PLAYBACK_SPEED)
            .setMaxPlaybackSpeed(MAX_PLAYBACK_SPEED)
            .build()

    /**
     * Tested live-rate controller: Media3's own [DefaultLivePlaybackSpeedControl] with the lab's
     * smoothing and gain, wrapped only to reassert the 1350 ms target. The SDK remains the sole
     * owner of live-rate adjustment; nothing else in the engine sets playback parameters.
     */
    fun buildLivePlaybackSpeedControl(): LivePlaybackSpeedControl =
        TargetReassertingLiveSpeedControl(
            targetOffsetMs = TARGET_OFFSET_MS,
            delegate = DefaultLivePlaybackSpeedControl.Builder()
                .setMinPossibleLiveOffsetSmoothingFactor(MIN_POSSIBLE_LIVE_OFFSET_SMOOTHING_FACTOR)
                .setProportionalControlFactor(PROPORTIONAL_CONTROL_FACTOR)
                .build(),
        )

    /** Diagnostic-only description of the transferred profile. */
    fun toDiagnosticMap(): Map<String, Any?> = mapOf(
        "profile" to PROFILE_NAME,
        "minBufferMs" to MIN_BUFFER_MS,
        "maxBufferMs" to MAX_BUFFER_MS,
        "bufferForPlaybackMs" to BUFFER_FOR_PLAYBACK_MS,
        "bufferForPlaybackAfterRebufferMs" to BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
        "targetOffsetMs" to TARGET_OFFSET_MS,
        "minPlaybackSpeed" to MIN_PLAYBACK_SPEED,
        "maxPlaybackSpeed" to MAX_PLAYBACK_SPEED,
        "minPossibleLiveOffsetSmoothingFactor" to MIN_POSSIBLE_LIVE_OFFSET_SMOOTHING_FACTOR,
        "proportionalControlFactor" to PROPORTIONAL_CONTROL_FACTOR,
        "minSdkInt" to MIN_SDK_INT,
    )
}

/**
 * Delegating [LivePlaybackSpeedControl] that forwards every call to Media3's default controller
 * and only rewrites the target offset of forwarded live configurations to [targetOffsetMs],
 * exactly as the qualified lab controller did. Rebuffer handling, override handling and speed
 * computation are the delegate's.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private class TargetReassertingLiveSpeedControl(
    private val targetOffsetMs: Long,
    private val delegate: LivePlaybackSpeedControl,
) : LivePlaybackSpeedControl {

    override fun setLiveConfiguration(liveConfiguration: MediaItem.LiveConfiguration) {
        val forwarded = if (liveConfiguration.targetOffsetMs != targetOffsetMs) {
            liveConfiguration.buildUpon().setTargetOffsetMs(targetOffsetMs).build()
        } else {
            liveConfiguration
        }
        delegate.setLiveConfiguration(forwarded)
    }

    override fun setTargetLiveOffsetOverrideUs(targetLiveOffsetOverrideUs: Long) {
        delegate.setTargetLiveOffsetOverrideUs(targetLiveOffsetOverrideUs)
    }

    override fun notifyRebuffer() {
        delegate.notifyRebuffer()
    }

    override fun getAdjustedPlaybackSpeed(liveOffsetUs: Long, bufferedDurationUs: Long): Float =
        delegate.getAdjustedPlaybackSpeed(liveOffsetUs, bufferedDurationUs)

    override fun getTargetLiveOffsetUs(): Long {
        val target = delegate.targetLiveOffsetUs
        return if (target == C.TIME_UNSET) C.TIME_UNSET else target
    }
}
