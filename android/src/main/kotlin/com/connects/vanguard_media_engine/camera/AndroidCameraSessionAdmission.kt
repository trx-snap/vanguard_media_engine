package com.connects.vanguard_media_engine.camera

// -----------------------------------------------------------------------------
// VG-CAMERA-ADMISSION: engine-wide single owner guard for the live camera /
// live-keying lane.
// -----------------------------------------------------------------------------
//
// Exactly one live camera session may exist at a time across every engine
// feature that opens the camera for a preview/keying pipeline (Duet, generic
// live green screen, future callers). This class is the neutral arbiter: it
// holds no camera, no session state and no feature knowledge — only the
// (owner, sessionId) pair that currently holds the lane.
//
// Contract:
//   - tryAcquire(owner, sessionId): true when the lane was free or already
//     held by exactly this pair (idempotent re-acquire); false otherwise. The
//     caller maps false to its own conflict error (`session_conflict` for
//     Duet, `live_busy` for the generic live session).
//   - release(owner, sessionId): frees the lane only when held by exactly this
//     pair, so a stale release from a superseded session can never free a
//     lane owned by someone else. Idempotent.
//   - isHeldByOther(owner, sessionId): true when some other pair holds it.
//
// Thread-safe (single lock, no blocking inside). Callers acquire on their
// main-thread admission path and release on every terminal path.

class AndroidCameraSessionAdmission {

    companion object {
        /** Owner id used by the Duet session coordinator. */
        const val OWNER_DUET = "duet"

        /** Owner id used by the generic live green-screen session coordinator. */
        const val OWNER_LIVE_GREEN_SCREEN = "live_green_screen"
    }

    /** Immutable view of the pair currently holding the lane. */
    data class Holder(val owner: String, val sessionId: String)

    private val lock = Any()
    private var holder: Holder? = null

    /**
     * Attempts to take the lane for ([owner], [sessionId]). Returns true when
     * the lane was free or is already held by this exact pair; false when any
     * other pair holds it.
     */
    fun tryAcquire(owner: String, sessionId: String): Boolean {
        synchronized(lock) {
            val current = holder
            if (current == null) {
                holder = Holder(owner, sessionId)
                return true
            }
            return current.owner == owner && current.sessionId == sessionId
        }
    }

    /**
     * Frees the lane when it is held by exactly ([owner], [sessionId]).
     * Returns true when the lane was released by this call; false when it was
     * free or held by another pair (no-op).
     */
    fun release(owner: String, sessionId: String): Boolean {
        synchronized(lock) {
            val current = holder ?: return false
            if (current.owner != owner || current.sessionId != sessionId) return false
            holder = null
            return true
        }
    }

    /** True when the lane is held by a pair other than ([owner], [sessionId]). */
    fun isHeldByOther(owner: String, sessionId: String): Boolean {
        synchronized(lock) {
            val current = holder ?: return false
            return current.owner != owner || current.sessionId != sessionId
        }
    }

    /** True when any pair holds the lane. */
    fun isHeld(): Boolean {
        synchronized(lock) { return holder != null }
    }

    /** Current holder, or null when the lane is free. */
    fun snapshot(): Holder? {
        synchronized(lock) { return holder }
    }

    /** `owner:sessionId` of the holder, or `free`. For logs and error messages. */
    fun debugString(): String {
        val current = snapshot() ?: return "free"
        return "${current.owner}:${current.sessionId}"
    }

    override fun toString(): String = "AndroidCameraSessionAdmission(${debugString()})"
}
