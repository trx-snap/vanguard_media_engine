// Copyright (c) Connects - Android LL-HLS experimental transfer: guarded media-playlist adaptation.
// Controlled client adaptation only. No origin playlist, server configuration or server code
// changes are implied; the parser never alters tags, segments, parts, media bytes or URIs.

package com.connects.vanguard_media_engine.streaming

import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.exoplayer.hls.playlist.DefaultHlsPlaylistParserFactory
import androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylistParserFactory
import androidx.media3.exoplayer.upstream.ParsingLoadable
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * [HlsPlaylistParserFactory] that delegates all parsing to [DefaultHlsPlaylistParserFactory] and
 * then applies the qualified lab's single, guarded model adaptation to live media playlists:
 * `startOffsetUs` becomes [C.TIME_UNSET] and `preciseStart` becomes `true`, so Media3's live
 * configuration (not an `EXT-X-START` hint) governs the start position.
 *
 * Both factory overloads delegate normal parsing first. The adaptation applies only when every
 * guard in [evaluate] passes; any declined playlist is returned exactly as parsed. A declined
 * playlist is never rebuilt and never triggers a different player construction.
 *
 * Every other parsed field (tags, segments, parts, server control, rendition reports,
 * interstitials, init segment, DRM data) is passed through to the copy unchanged.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AndroidLlhlsPlaylistParserFactory(
    private val targetOffsetMs: Long,
    private val graphEpoch: Long,
    private val delegate: HlsPlaylistParserFactory = DefaultHlsPlaylistParserFactory(),
) : HlsPlaylistParserFactory {

    companion object {
        private const val TAG = "AndroidLlhlsParser"

        const val REASON_APPLIED = "applied"
        const val REASON_MULTIVARIANT = "multivariant"
        const val REASON_PLAYLIST_TYPE_NOT_UNKNOWN = "playlist_type_not_unknown"
        const val REASON_HAS_END_TAG = "has_end_tag"
        const val REASON_MISSING_PROGRAM_DATE_TIME = "missing_program_date_time"
        const val REASON_DURATION_NOT_POSITIVE = "duration_not_positive"
        const val REASON_PART_TARGET_DURATION_NOT_POSITIVE = "part_target_duration_not_positive"
        const val REASON_CANNOT_BLOCK_RELOAD = "cannot_block_reload"
        const val REASON_PART_HOLD_BACK_INVALID = "part_hold_back_invalid"
        const val REASON_POSITIVE_START_OFFSET = "positive_start_offset"
    }

    init {
        require(targetOffsetMs > 0L) { "targetOffsetMs must be positive, got $targetOffsetMs" }
    }

    private val appliedCount = AtomicLong(0L)
    private val declinedCount = AtomicLong(0L)

    @Volatile
    private var lastReason: String? = null

    /** Number of media playlists adapted by this factory instance (diagnostic-only). */
    val appliedPlaylists: Long get() = appliedCount.get()

    /** Number of media playlists returned unchanged by this factory instance (diagnostic-only). */
    val declinedPlaylists: Long get() = declinedCount.get()

    /** Most recent decision reason (diagnostic-only). */
    val lastDecisionReason: String? get() = lastReason

    override fun createPlaylistParser(): ParsingLoadable.Parser<HlsPlaylist> =
        AdaptingParser(delegate.createPlaylistParser())

    override fun createPlaylistParser(
        multivariantPlaylist: HlsMultivariantPlaylist,
        previousMediaPlaylist: HlsMediaPlaylist?,
    ): ParsingLoadable.Parser<HlsPlaylist> =
        AdaptingParser(delegate.createPlaylistParser(multivariantPlaylist, previousMediaPlaylist))

    /**
     * Returns [REASON_APPLIED] when [playlist] qualifies for adaptation, otherwise the decline
     * reason. Pure; evaluates the guards in the lab's exact order.
     */
    fun evaluate(playlist: HlsPlaylist): String {
        if (playlist !is HlsMediaPlaylist) return REASON_MULTIVARIANT
        if (playlist.playlistType != HlsMediaPlaylist.PLAYLIST_TYPE_UNKNOWN) {
            return REASON_PLAYLIST_TYPE_NOT_UNKNOWN
        }
        if (playlist.hasEndTag) return REASON_HAS_END_TAG
        if (!playlist.hasProgramDateTime) return REASON_MISSING_PROGRAM_DATE_TIME
        if (playlist.durationUs <= 0L) return REASON_DURATION_NOT_POSITIVE
        if (playlist.partTargetDurationUs <= 0L) return REASON_PART_TARGET_DURATION_NOT_POSITIVE
        // Media3 declares serverControl non-null; the lab's null branch is unreachable here.
        val serverControl = playlist.serverControl
        if (!serverControl.canBlockReload) return REASON_CANNOT_BLOCK_RELOAD
        if (serverControl.partHoldBackUs <= 0L ||
            serverControl.partHoldBackUs > targetOffsetMs * 1_000L
        ) {
            return REASON_PART_HOLD_BACK_INVALID
        }
        if (playlist.hasPositiveStartOffset) return REASON_POSITIVE_START_OFFSET
        return REASON_APPLIED
    }

    /**
     * Applies the adaptation when [evaluate] returns [REASON_APPLIED]; otherwise returns
     * [playlist] itself (the same instance, never a rebuilt one).
     */
    fun adapt(playlist: HlsPlaylist): HlsPlaylist {
        val reason = evaluate(playlist)
        if (reason != REASON_APPLIED) {
            declinedCount.incrementAndGet()
            logDecision(reason, playlist)
            return playlist
        }
        val p = playlist as HlsMediaPlaylist
        val adapted = HlsMediaPlaylist(
            p.playlistType,
            p.baseUri,
            p.tags,
            C.TIME_UNSET,
            true,
            p.startTimeUs,
            p.hasDiscontinuitySequence,
            p.discontinuitySequence,
            p.mediaSequence,
            p.version,
            p.targetDurationUs,
            p.partTargetDurationUs,
            p.hasIndependentSegments,
            p.hasEndTag,
            p.hasProgramDateTime,
            p.protectionSchemes,
            p.segments,
            p.trailingParts,
            p.serverControl,
            p.renditionReports,
            p.interstitials,
            p.lastSeenInitSegment,
        )
        appliedCount.incrementAndGet()
        logDecision(REASON_APPLIED, p)
        return adapted
    }

    /** Logs only when the decision reason changes, so steady-state reloads stay quiet. */
    private fun logDecision(reason: String, playlist: HlsPlaylist) {
        if (lastReason == reason) return
        lastReason = reason
        val media = playlist as? HlsMediaPlaylist
        Log.i(
            TAG,
            "epoch=$graphEpoch reason=$reason targetOffsetMs=$targetOffsetMs" +
                (media?.let {
                    " mediaSequence=${it.mediaSequence} durationUs=${it.durationUs}" +
                        " originalStartOffsetUs=${it.startOffsetUs} originalPreciseStart=${it.preciseStart}" +
                        " partHoldBackUs=${it.serverControl?.partHoldBackUs}"
                } ?: ""),
        )
    }

    /** Delegates parsing, then adapts. Delegate parse failures propagate unchanged. */
    private inner class AdaptingParser(
        private val delegateParser: ParsingLoadable.Parser<HlsPlaylist>,
    ) : ParsingLoadable.Parser<HlsPlaylist> {

        @Throws(IOException::class)
        override fun parse(uri: Uri, inputStream: InputStream): HlsPlaylist =
            adapt(delegateParser.parse(uri, inputStream))
    }
}
