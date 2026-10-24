// Copyright (c) Connects - Android LL-HLS control ownership: pure playback control state.
// Single owner of the adapter's released / stopped / playing-intent / control-version / seek
// reservation / resume-position state.  No Handler, Player, Android, logging or I/O dependencies;
// every transition is one atomic swap of an immutable snapshot.

package com.connects.vanguard_media_engine.streaming

import java.util.concurrent.atomic.AtomicReference

/**
 * Pure, lock-free owner of [HttpAdaptivePlaybackAdapter] control state.
 *
 * One immutable [Snapshot] lives in an [AtomicReference]; every public transition is a
 * compare-and-set of the whole snapshot, so a caller on any thread observes a consistent
 * (version, intent, stopped, released, seek reservation) tuple and never a torn update.
 *
 * Responsibilities, and nothing else:
 * - `released`: irreversible; only the first [release] wins.
 * - `stopped`: set by [stop].  An experimental session requires a new open afterwards; an
 *   ordinary session clears it on [prepare] (existing re-prepare behaviour).
 * - `intendedPlaying`: the caller's current playing intent.
 * - `version`: monotonic control version advanced by every intent / lifecycle change; the
 *   adapter compares it to detect controls that landed while owner-thread work was blocked.
 * - seek reservation: at most one live ticket ([Snapshot.seekTicket]), its target and whether
 *   the session committed it.  SDK playback is held while any ticket is live.
 * - resume position ([Snapshot.resumePosition]): where an explicit resume should land.  An
 *   experimental [pause] without a pending seek records [ResumePosition.LIVE]; [beginSeek]
 *   records [ResumePosition.EXPLICIT], retained by commit / cancel / complete until a later
 *   pause; [consumeResumeIntent] validates and clears it; [prepare], [stop] and [release]
 *   reset it.  Ordinary owners never leave [ResumePosition.DEFAULT] through [pause].
 *
 * The adapter owns every side effect (Handler posts, Player calls); the session owns native
 * acceptance.  Recovery permission and graph / bridge epochs are owned elsewhere.
 *
 * @param experimental `true` for the Android LL-HLS experimental profile.  Only the stopped
 *   semantics differ: experimental [prepare] and [play] are rejected after [stop].
 */
class HttpAdaptivePlaybackControlState(private val experimental: Boolean) {

    /** Where an explicit resume should land.  Owned here; every SDK effect stays in the adapter. */
    enum class ResumePosition { DEFAULT, LIVE, EXPLICIT }

    /** Immutable control snapshot. */
    data class Snapshot(
        val version: Long,
        val intendedPlaying: Boolean,
        val stopped: Boolean,
        val released: Boolean,
        val seekTicket: Long,
        val seekPositionMs: Long?,
        val seekCommitted: Boolean,
        val resumePosition: ResumePosition,
    ) {
        /** Whether a seek reservation (committed or not) currently holds SDK playback. */
        val seekPending: Boolean get() = seekTicket != NO_SEEK_TICKET

        /** Whether the owner is stopped or released. */
        val terminal: Boolean get() = stopped || released
    }

    companion object {
        /** Returned by [beginSeek] when no reservation was made; never a valid ticket. */
        const val NO_SEEK_TICKET: Long = 0L

        private val INITIAL = Snapshot(
            version = 0L,
            intendedPlaying = false,
            stopped = false,
            released = false,
            seekTicket = NO_SEEK_TICKET,
            seekPositionMs = null,
            seekCommitted = false,
            resumePosition = ResumePosition.DEFAULT,
        )
    }

    private val ref: AtomicReference<Snapshot> = AtomicReference(INITIAL)

    /** The current snapshot.  Safe from any thread. */
    fun snapshot(): Snapshot = ref.get()

    /**
     * Initialises intent for a new preparation and invalidates every old ticket.  Cannot clear
     * `released`.  An experimental stopped owner is rejected (a new open is required); an
     * ordinary owner clears `stopped` (existing re-prepare behaviour).
     *
     * @return `true` when the preparation may proceed.
     */
    fun prepare(autoPlay: Boolean): Boolean = transition { s ->
        if (s.released) return@transition null
        if (experimental && s.stopped) return@transition null
        s.copy(
            version = s.version + 1,
            intendedPlaying = autoPlay,
            stopped = false,
            seekTicket = NO_SEEK_TICKET,
            seekPositionMs = null,
            seekCommitted = false,
            resumePosition = ResumePosition.DEFAULT,
        )
    } != null

    /**
     * Records playing intent.  Experimental stopped / released playback is rejected.  A pending
     * seek still prevents SDK playback: the adapter resumes only once the reservation clears.
     * The resume position is preserved for the adapter to validate and consume.
     *
     * @return `true` when intent was recorded.
     */
    fun play(): Boolean = transition { s ->
        if (s.released) return@transition null
        if (experimental && s.stopped) return@transition null
        s.copy(intendedPlaying = true)
    } != null

    /**
     * Records paused intent and advances the version.  A pending seek reservation is retained.
     * An experimental owner without a pending seek records a live resume position; a pending
     * seek keeps its explicit position.  Ordinary owners leave the resume position unchanged.
     *
     * @return `false` only when released.
     */
    fun pause(): Boolean = transition { s ->
        if (s.released) return@transition null
        val resume = if (experimental && !s.seekPending) ResumePosition.LIVE else s.resumePosition
        s.copy(version = s.version + 1, intendedPlaying = false, resumePosition = resume)
    } != null

    /**
     * Marks the owner stopped: intent cleared, version advanced, pending ticket invalidated.
     *
     * @return `false` only when released.
     */
    fun stop(): Boolean = transition { s ->
        if (s.released) return@transition null
        s.copy(
            version = s.version + 1,
            intendedPlaying = false,
            stopped = true,
            seekTicket = NO_SEEK_TICKET,
            seekPositionMs = null,
            seekCommitted = false,
            resumePosition = ResumePosition.DEFAULT,
        )
    } != null

    /**
     * Irreversible release: intent cleared, version advanced, pending ticket invalidated.
     *
     * @return `true` only for the first winning transition.
     */
    fun release(): Boolean = transition { s ->
        if (s.released) return@transition null
        s.copy(
            version = s.version + 1,
            intendedPlaying = false,
            released = true,
            seekTicket = NO_SEEK_TICKET,
            seekPositionMs = null,
            seekCommitted = false,
            resumePosition = ResumePosition.DEFAULT,
        )
    } != null

    /**
     * Publishes a seek reservation atomically: target, fresh ticket, fresh version, an
     * uncommitted playback hold and an explicit resume position.  Any earlier reservation is
     * superseded.
     *
     * @return the new positive ticket, or [NO_SEEK_TICKET] when stopped or released.
     */
    fun beginSeek(positionMs: Long): Long {
        require(positionMs >= 0L) { "beginSeek: positionMs must be >= 0, got $positionMs" }
        val next = transition { s ->
            if (s.terminal) return@transition null
            val version = s.version + 1
            s.copy(
                version = version,
                seekTicket = version,
                seekPositionMs = positionMs,
                seekCommitted = false,
                resumePosition = ResumePosition.EXPLICIT,
            )
        } ?: return NO_SEEK_TICKET
        return next.seekTicket
    }

    /**
     * Marks the current live [ticket] committed.  Duplicate commits are harmless.  A stale,
     * superseded, cancelled or invalidated ticket is rejected.
     *
     * @return `true` when [ticket] is the committed live reservation.
     */
    fun commitSeek(ticket: Long): Boolean {
        if (ticket == NO_SEEK_TICKET) return false
        return transition { s ->
            if (s.seekTicket != ticket) return@transition null
            if (s.seekCommitted) s else s.copy(seekCommitted = true)
        } != null
    }

    /**
     * Clears the reservation only when [ticket] is the current live ticket.  A stale ticket
     * cannot clear a newer reservation.
     *
     * @return `true` when the reservation was cleared by this call.
     */
    fun cancelSeek(ticket: Long): Boolean {
        if (ticket == NO_SEEK_TICKET) return false
        return transition { s ->
            if (s.seekTicket != ticket) return@transition null
            s.copy(
                version = s.version + 1,
                seekTicket = NO_SEEK_TICKET,
                seekPositionMs = null,
                seekCommitted = false,
            )
        } != null
    }

    /**
     * Clears the reservation after its target was issued, only when [ticket] is the current
     * committed live ticket.  Each committed ticket completes at most once.
     *
     * @return `true` when the reservation was cleared by this call.
     */
    fun completeSeek(ticket: Long): Boolean {
        if (ticket == NO_SEEK_TICKET) return false
        return transition { s ->
            if (s.seekTicket != ticket || !s.seekCommitted) return@transition null
            s.copy(seekTicket = NO_SEEK_TICKET, seekPositionMs = null, seekCommitted = false)
        } != null
    }

    /**
     * Validates and consumes the resume intent for an explicit resume the adapter evaluated at
     * [expectedVersion].  Rejected for an ordinary owner, a terminal or seek-holding snapshot,
     * absent playing intent, a version other than [expectedVersion] (a control landed since the
     * adapter read its snapshot) or an [ResumePosition.EXPLICIT] position, which only a later
     * pause may replace.  Otherwise the position becomes [ResumePosition.DEFAULT] without
     * advancing the version, so a replacement claimed at [expectedVersion] still matches; graph
     * retirement, not this owner, guarantees at most one replacement per old graph.
     *
     * @return `true` when the intent was valid and is now consumed.
     */
    fun consumeResumeIntent(expectedVersion: Long): Boolean {
        if (!experimental) return false
        return transition { s ->
            if (s.terminal || s.seekPending || !s.intendedPlaying) return@transition null
            if (s.version != expectedVersion) return@transition null
            if (s.resumePosition == ResumePosition.EXPLICIT) return@transition null
            if (s.resumePosition == ResumePosition.DEFAULT) s else s.copy(resumePosition = ResumePosition.DEFAULT)
        } != null
    }

    /**
     * Atomic transition: [compute] maps the current snapshot to its successor, or `null` to
     * reject.  Retries until the compare-and-set wins.
     *
     * @return the installed successor, or `null` when rejected.
     */
    private inline fun transition(compute: (Snapshot) -> Snapshot?): Snapshot? {
        while (true) {
            val current = ref.get()
            val next = compute(current) ?: return null
            if (ref.compareAndSet(current, next)) return next
        }
    }
}
