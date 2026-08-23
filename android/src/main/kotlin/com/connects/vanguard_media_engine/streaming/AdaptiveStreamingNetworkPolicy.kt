// Copyright (c) Connects - Phase 4C5B: Streaming network profile policy.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector

/**
 * Immutable policy record that maps an [AdaptiveStreamingNetworkProfile] to the concrete
 * Media3 / ExoPlayer knob values that implement it.
 *
 * ## Design contract
 * - When [customPolicyEnabled] is **false** (the [AUTO] profile), none of the buffer or
 *   bitrate fields are meaningful; [buildLoadControl] and [buildTrackSelector] must not
 *   be called.  The caller ([HttpAdaptivePlaybackAdapter]) simply skips both
 *   `setLoadControl` and `setTrackSelector` on the `ExoPlayer.Builder`, which preserves
 *   the current Media3 defaults unchanged.
 * - When [customPolicyEnabled] is **true**, the caller must invoke both helpers and pass
 *   their results to `ExoPlayer.Builder.setLoadControl` /
 *   `ExoPlayer.Builder.setTrackSelector`.
 *
 * ## Media3 knob mapping
 * | Field                              | Media3 API                                                         |
 * |------------------------------------|--------------------------------------------------------------------|
 * | minBufferMs … bufferForPlaybackAfterRebufferMs | [DefaultLoadControl.Builder.setBufferDurationsMsForStreaming] |
 * | maxVideoBitrate                    | [DefaultTrackSelector.Parameters.maxVideoBitrate]                  |
 * | maxAudioBitrate                    | [DefaultTrackSelector.Parameters.maxAudioBitrate]                  |
 * | forceLowestBitrate                 | [DefaultTrackSelector.Parameters.forceLowestBitrate]               |
 * | exceedVideoConstraintsIfNecessary  | [DefaultTrackSelector.Parameters.exceedVideoConstraintsIfNecessary]|
 *
 * @param profile                          Source profile for reference / diagnostics.
 * @param customPolicyEnabled              Whether to install custom LoadControl + TrackSelector.
 * @param minBufferMs                      Min buffer to maintain (ms).
 * @param maxBufferMs                      Max buffer to maintain (ms).
 * @param bufferForPlaybackMs              Min buffer before first playback start (ms).
 * @param bufferForPlaybackAfterRebufferMs Min buffer before resuming after rebuffer (ms).
 * @param maxVideoBitrate                  Hard video bitrate cap (bps); null means no cap.
 * @param maxAudioBitrate                  Hard audio bitrate cap (bps); null means no cap.
 * @param forceLowestBitrate               If true, always picks the lowest available rendition.
 * @param exceedVideoConstraintsIfNecessary If true, allows exceeding the video cap when no
 *                                          other rendition satisfies selection constraints.
 * @param raw                              Human-readable description of the policy.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
data class AdaptiveStreamingNetworkPolicy(
    val profile: AdaptiveStreamingNetworkProfile,
    val customPolicyEnabled: Boolean,
    val minBufferMs: Int?,
    val maxBufferMs: Int?,
    val bufferForPlaybackMs: Int?,
    val bufferForPlaybackAfterRebufferMs: Int?,
    val maxVideoBitrate: Int?,
    val maxAudioBitrate: Int?,
    val forceLowestBitrate: Boolean,
    val exceedVideoConstraintsIfNecessary: Boolean,
    val raw: String,
) {

    /**
     * Returns a flat [Map] of diagnostic fields describing this policy.
     * Safe to call regardless of [customPolicyEnabled].
     */
    fun toDiagnosticMap(): Map<String, Any?> = mapOf(
        "profile" to profile.name,
        "customPolicyEnabled" to customPolicyEnabled,
        "minBufferMs" to minBufferMs,
        "maxBufferMs" to maxBufferMs,
        "bufferForPlaybackMs" to bufferForPlaybackMs,
        "bufferForPlaybackAfterRebufferMs" to bufferForPlaybackAfterRebufferMs,
        "maxVideoBitrate" to maxVideoBitrate,
        "maxAudioBitrate" to maxAudioBitrate,
        "forceLowestBitrate" to forceLowestBitrate,
        "exceedVideoConstraintsIfNecessary" to exceedVideoConstraintsIfNecessary,
        "raw" to raw,
    )

    /**
     * Builds a [DefaultLoadControl] configured with this policy's buffer durations.
     *
     * **Precondition:** [customPolicyEnabled] must be true.  Callers in
     * [HttpAdaptivePlaybackAdapter] are responsible for guarding this check.
     *
     * Uses [DefaultLoadControl.Builder.setBufferDurationsMsForStreaming] which maps
     * directly to minBufferMs, maxBufferMs, bufferForPlaybackMs, and
     * bufferForPlaybackAfterRebufferMs — all four values are non-null when
     * customPolicyEnabled is true.
     */
    fun buildLoadControl(): DefaultLoadControl {
        require(customPolicyEnabled) {
            "buildLoadControl() must only be called when customPolicyEnabled=true"
        }
        return DefaultLoadControl.Builder()
            .setBufferDurationsMsForStreaming(
                /* minBufferMs */                      minBufferMs!!,
                /* maxBufferMs */                      maxBufferMs!!,
                /* bufferForPlaybackMs */              bufferForPlaybackMs!!,
                /* bufferForPlaybackAfterRebufferMs */ bufferForPlaybackAfterRebufferMs!!,
            )
            .build()
    }

    /**
     * Builds a [DefaultTrackSelector] configured with this policy's bitrate caps and
     * rendition-selection flags.
     *
     * **Precondition:** [customPolicyEnabled] must be true.  Callers in
     * [HttpAdaptivePlaybackAdapter] are responsible for guarding this check.
     *
     * Bitrate caps ([maxVideoBitrate], [maxAudioBitrate]) are only set when non-null.
     * [exceedVideoConstraintsIfNecessary] and [forceLowestBitrate] are always applied.
     */
    fun buildTrackSelector(context: Context): DefaultTrackSelector {
        require(customPolicyEnabled) {
            "buildTrackSelector() must only be called when customPolicyEnabled=true"
        }
        val parametersBuilder = DefaultTrackSelector.Parameters.Builder(context)
            .setExceedVideoConstraintsIfNecessary(exceedVideoConstraintsIfNecessary)
            .setForceLowestBitrate(forceLowestBitrate)
        if (maxVideoBitrate != null) {
            parametersBuilder.setMaxVideoBitrate(maxVideoBitrate)
        }
        if (maxAudioBitrate != null) {
            parametersBuilder.setMaxAudioBitrate(maxAudioBitrate)
        }
        return DefaultTrackSelector(context, parametersBuilder.build())
    }

    companion object {

        /**
         * Returns the [AdaptiveStreamingNetworkPolicy] for the given [profile].
         *
         * - **AUTO**: [customPolicyEnabled] = false.  All buffer / bitrate fields are null.
         *   [buildLoadControl] and [buildTrackSelector] must NOT be called.  The player is
         *   built without any custom LoadControl or TrackSelector, which is identical to the
         *   pre-Phase-4C5B behaviour and preserves every Media3 ExoPlayer default.
         *
         * - **STABLE**: 15 s / 50 s buffer windows; 2.5 s start, 5 s rebuffer; no bitrate cap.
         *
         * - **CONSTRAINED**: 25 s / 60 s buffer windows; 5 s start, 8 s rebuffer;
         *   800 kbps video cap, 96 kbps audio cap.
         *
         * - **LOW_LATENCY**: 3 s / 10 s buffer windows; 1 s start, 1.5 s rebuffer;
         *   no bitrate cap.
         */
        fun forProfile(profile: AdaptiveStreamingNetworkProfile): AdaptiveStreamingNetworkPolicy =
            when (profile) {
                AdaptiveStreamingNetworkProfile.AUTO -> AdaptiveStreamingNetworkPolicy(
                    profile = profile,
                    customPolicyEnabled = false,
                    minBufferMs = null,
                    maxBufferMs = null,
                    bufferForPlaybackMs = null,
                    bufferForPlaybackAfterRebufferMs = null,
                    maxVideoBitrate = null,
                    maxAudioBitrate = null,
                    forceLowestBitrate = false,
                    exceedVideoConstraintsIfNecessary = false,
                    raw = "profile=AUTO;customPolicyEnabled=false;" +
                        "Media3 ExoPlayer defaults preserved; no custom LoadControl or TrackSelector installed.",
                )

                AdaptiveStreamingNetworkProfile.STABLE -> AdaptiveStreamingNetworkPolicy(
                    profile = profile,
                    customPolicyEnabled = true,
                    minBufferMs = 15_000,
                    maxBufferMs = 50_000,
                    bufferForPlaybackMs = 2_500,
                    bufferForPlaybackAfterRebufferMs = 5_000,
                    maxVideoBitrate = null,
                    maxAudioBitrate = null,
                    forceLowestBitrate = false,
                    exceedVideoConstraintsIfNecessary = true,
                    raw = "profile=STABLE;customPolicyEnabled=true;" +
                        "minBuffer=15000ms;maxBuffer=50000ms;start=2500ms;rebuffer=5000ms;" +
                        "maxVideoBitrate=none;maxAudioBitrate=none;" +
                        "forceLowest=false;exceedConstraints=true.",
                )

                AdaptiveStreamingNetworkProfile.CONSTRAINED -> AdaptiveStreamingNetworkPolicy(
                    profile = profile,
                    customPolicyEnabled = true,
                    minBufferMs = 25_000,
                    maxBufferMs = 60_000,
                    bufferForPlaybackMs = 5_000,
                    bufferForPlaybackAfterRebufferMs = 8_000,
                    maxVideoBitrate = 800_000,
                    maxAudioBitrate = 96_000,
                    forceLowestBitrate = false,
                    exceedVideoConstraintsIfNecessary = true,
                    raw = "profile=CONSTRAINED;customPolicyEnabled=true;" +
                        "minBuffer=25000ms;maxBuffer=60000ms;start=5000ms;rebuffer=8000ms;" +
                        "maxVideoBitrate=800000bps;maxAudioBitrate=96000bps;" +
                        "forceLowest=false;exceedConstraints=true.",
                )

                AdaptiveStreamingNetworkProfile.LOW_LATENCY -> AdaptiveStreamingNetworkPolicy(
                    profile = profile,
                    customPolicyEnabled = true,
                    minBufferMs = 3_000,
                    maxBufferMs = 10_000,
                    bufferForPlaybackMs = 1_000,
                    bufferForPlaybackAfterRebufferMs = 1_500,
                    maxVideoBitrate = null,
                    maxAudioBitrate = null,
                    forceLowestBitrate = false,
                    exceedVideoConstraintsIfNecessary = true,
                    raw = "profile=LOW_LATENCY;customPolicyEnabled=true;" +
                        "minBuffer=3000ms;maxBuffer=10000ms;start=1000ms;rebuffer=1500ms;" +
                        "maxVideoBitrate=none;maxAudioBitrate=none;" +
                        "forceLowest=false;exceedConstraints=true.",
                )
            }
    }
}
