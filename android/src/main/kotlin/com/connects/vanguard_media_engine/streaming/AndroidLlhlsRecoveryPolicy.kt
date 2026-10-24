// Copyright (c) Connects - Android LL-HLS experimental transfer: bounded recovery decisions.
// Pure Kotlin. No Android, Media3, threading or I/O dependencies; independently testable.

package com.connects.vanguard_media_engine.streaming

/**
 * Pure decision policy for the bounded `mode=rebuild` recovery paths:
 *
 * `trigger=ready` (qualified in the lab):
 * 1. A graph becomes recoverable only after it has rendered a first frame ([onFirstFrame]).
 * 2. A buffering transition on that rendered, live, intentionally-playing graph arms recovery
 *    ([onBuffering]).
 * 3. On the next READY of that same graph, [claimReady] consumes one attempt only when the live
 *    offset is strictly above [excessLagThresholdMs], intent is still playing, the output and
 *    network are valid, fewer than [maxActions] attempts were used and at least [cooldownMs]
 *    elapsed since the previous attempt.
 *
 * `trigger=behind_live_window` (fatal SDK chunk-window error on a rendered graph):
 * [claimBehindLiveWindow] consumes one attempt from the same budget when the current graph has
 * rendered, intent is still playing and the output and network are valid.  It requires neither an
 * armed buffering transition nor an offset threshold: the SDK already decided the position is
 * outside the live window.
 *
 * Both claims share one lifetime [actionCount] / [lastActionMs] budget.  Declines that leave the
 * policy armed mirror the lab's "leave playback alone" branches; declines that clear it mirror the
 * lab's `clearArmed=true` branches. [disable] is one-way: once disabled the policy never arms or
 * claims again, and only a fresh policy instance can re-enable recovery.
 *
 * Not thread-safe; the owner confines all calls to one thread.
 */
class AndroidLlhlsRecoveryPolicy(
    initialEpoch: Long = NO_EPOCH,
    private val excessLagThresholdMs: Long = DEFAULT_EXCESS_LAG_THRESHOLD_MS,
    private val maxActions: Int = DEFAULT_MAX_ACTIONS,
    private val cooldownMs: Long = DEFAULT_COOLDOWN_MS,
) {

    companion object {
        /** Lab target offset (1350 ms) plus the lab excess-lag margin (750 ms). */
        const val DEFAULT_EXCESS_LAG_THRESHOLD_MS = 2_100L
        const val DEFAULT_MAX_ACTIONS = 2
        const val DEFAULT_COOLDOWN_MS = 10_000L
        const val NO_EPOCH = -1L
        const val NO_TIME = Long.MIN_VALUE

        const val DECISION_NONE = "none"
        const val DECISION_DISABLED = "disabled"
        const val DECISION_STALE_EPOCH = "stale_epoch"
        const val DECISION_NOT_ARMED = "not_armed"
        const val DECISION_NOT_RENDERED = "not_rendered"
        const val DECISION_OFFSET_WITHIN_THRESHOLD = "offset_within_threshold"
        const val DECISION_NOT_PLAYING_INTENT = "not_playing_intent"
        const val DECISION_NOT_LIVE = "not_live"
        const val DECISION_INVALID_OUTPUT = "invalid_output"
        const val DECISION_NO_ACTIVE_NETWORK = "no_active_network"
        const val DECISION_MAX_ACTIONS = "max_actions"
        const val DECISION_COOLDOWN = "cooldown"
        const val DECISION_CLAIMED = "claimed"
    }

    init {
        require(excessLagThresholdMs > 0L) { "excessLagThresholdMs must be positive" }
        require(maxActions >= 0) { "maxActions must be >= 0" }
        require(cooldownMs >= 0L) { "cooldownMs must be >= 0" }
    }

    /** Immutable view of the player at a READY decision point. */
    data class Snapshot(
        val epoch: Long,
        val nowMs: Long,
        val liveOffsetMs: Long?,
        val readyLive: Boolean,
        val playingIntent: Boolean,
        val outputValid: Boolean,
        val activeNetwork: Boolean,
    )

    /** Immutable view of the player at a fatal behind-live-window error decision point. */
    data class FailureSnapshot(
        val epoch: Long,
        val nowMs: Long,
        val live: Boolean,
        val playingIntent: Boolean,
        val outputValid: Boolean,
        val activeNetwork: Boolean,
    )

    var currentEpoch: Long = initialEpoch
        private set

    /** Epoch of the graph that has rendered a first frame, or [NO_EPOCH]. */
    var renderedEpoch: Long = NO_EPOCH
        private set

    var armed: Boolean = false
        private set

    var actionCount: Int = 0
        private set

    var lastActionMs: Long = NO_TIME
        private set

    var disabled: Boolean = false
        private set

    var disableReason: String? = null
        private set

    var lastDecision: String = DECISION_NONE
        private set

    /** Records that [epoch] rendered its first frame; stale epochs are ignored. */
    fun onFirstFrame(epoch: Long) {
        if (disabled || epoch != currentEpoch) return
        renderedEpoch = epoch
    }

    /**
     * Arms recovery when the current, already-rendered graph starts buffering while live with
     * playing intent. Startup buffering (before a first frame) never arms.
     */
    fun onBuffering(epoch: Long, live: Boolean, playingIntent: Boolean) {
        if (disabled || armed || epoch != currentEpoch) return
        if (renderedEpoch != epoch) return
        if (!live || !playingIntent) return
        armed = true
    }

    /**
     * Consumes one recovery attempt when every lab condition holds. Returns `true` exactly when
     * the caller must replace the graph now.
     */
    fun claimReady(snapshot: Snapshot): Boolean {
        if (disabled) return decline(DECISION_DISABLED, clearArmed = true)
        if (snapshot.epoch != currentEpoch) return decline(DECISION_STALE_EPOCH, clearArmed = false)
        if (!armed) return decline(DECISION_NOT_ARMED, clearArmed = false)
        val offset = snapshot.liveOffsetMs
        if (offset == null || offset <= excessLagThresholdMs) {
            return decline(DECISION_OFFSET_WITHIN_THRESHOLD, clearArmed = false)
        }
        if (!snapshot.playingIntent) return decline(DECISION_NOT_PLAYING_INTENT, clearArmed = true)
        if (!snapshot.readyLive) return decline(DECISION_NOT_LIVE, clearArmed = false)
        if (!snapshot.outputValid) return decline(DECISION_INVALID_OUTPUT, clearArmed = false)
        if (!snapshot.activeNetwork) return decline(DECISION_NO_ACTIVE_NETWORK, clearArmed = false)
        return claimAttempt(snapshot.nowMs)
    }

    /**
     * Consumes one recovery attempt for a fatal behind-live-window error on the current, already
     * rendered graph.  Neither an armed buffering transition nor an offset threshold is required.
     * Returns `true` exactly when the caller must replace the graph now.
     */
    fun claimBehindLiveWindow(snapshot: FailureSnapshot): Boolean {
        if (disabled) return decline(DECISION_DISABLED, clearArmed = true)
        if (snapshot.epoch != currentEpoch) return decline(DECISION_STALE_EPOCH, clearArmed = false)
        if (renderedEpoch != snapshot.epoch) return decline(DECISION_NOT_RENDERED, clearArmed = false)
        if (!snapshot.playingIntent) return decline(DECISION_NOT_PLAYING_INTENT, clearArmed = true)
        if (!snapshot.live) return decline(DECISION_NOT_LIVE, clearArmed = false)
        if (!snapshot.outputValid) return decline(DECISION_INVALID_OUTPUT, clearArmed = false)
        if (!snapshot.activeNetwork) return decline(DECISION_NO_ACTIVE_NETWORK, clearArmed = false)
        return claimAttempt(snapshot.nowMs)
    }

    /** Installs [epoch] as the current graph; the new graph must render before it can arm. */
    fun onGraphReplaced(epoch: Long) {
        currentEpoch = epoch
        renderedEpoch = NO_EPOCH
        armed = false
    }

    /** One-way. Clears armed state and blocks every later arm/claim. */
    fun disable(reason: String) {
        if (disabled) return
        disabled = true
        disableReason = reason
        armed = false
    }

    /** Compact diagnostic description. */
    fun toDiagnosticString(): String =
        "epoch=$currentEpoch;rendered=${renderedEpoch == currentEpoch};armed=$armed;" +
            "actions=$actionCount/$maxActions;disabled=$disabled;disableReason=$disableReason;" +
            "lastDecision=$lastDecision"

    /**
     * Shared budget tail of every claim: declines on an exhausted [maxActions] budget (clearing
     * armed) or an unexpired [cooldownMs] (leaving armed), otherwise consumes one attempt.
     */
    private fun claimAttempt(nowMs: Long): Boolean {
        if (actionCount >= maxActions) return decline(DECISION_MAX_ACTIONS, clearArmed = true)
        if (actionCount > 0 && nowMs - lastActionMs < cooldownMs) {
            return decline(DECISION_COOLDOWN, clearArmed = false)
        }
        armed = false
        actionCount += 1
        lastActionMs = nowMs
        lastDecision = DECISION_CLAIMED
        return true
    }

    private fun decline(reason: String, clearArmed: Boolean): Boolean {
        if (clearArmed) armed = false
        lastDecision = reason
        return false
    }
}
