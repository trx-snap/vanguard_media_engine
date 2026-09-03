package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioRouting
import android.media.AudioTrack
import android.os.Handler
import android.os.SystemClock
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

// -- VanguardRealtimePlaybackRoutingController (P4-AUDIO-REALTIME-PLAYBACK-
// SINK-FAULT-TOLERANCE, Y4b) ------------------------------------------------
//
// Owns exactly one android.media.AudioRouting.OnRoutingChangedListener for
// one realtime playback run and nothing else: attaching it to an AudioTrack,
// detaching it again, and the single bounded queue every routing event is
// funnelled through. The listener is delivered on the supplied Handler and
// does exactly one thing: enqueue a typed [Event] (enum tag + monotonically
// increasing seq). It never blocks and never touches the AudioTrack.
//
// Event sources:
// - OS routing callback     -> ROUTE_CHANGED (telemetry/handoff only)
// - postSyntheticRouteChanged -> ROUTE_CHANGED posted through the SAME
//   Handler as a real callback, so it enters the queue on the same thread
//   and path.
// - postSyntheticRouteDisconnect -> ROUTE_DISCONNECT enqueued synchronously
//   on the calling thread so it is visible to the consumer at the very next
//   drain point (X11 precedent: no main-handler wait). There is no OS
//   source for ROUTE_DISCONNECT; it is synthetic-only.
//
// Nothing is ever applied here: this controller only queues typed events.
// For Y12 production, the session's own routing monitor thread is the sole
// consumer, popping events at its own drain points and applying them
// itself; the sink bridge never drains this queue and owns only listener
// attach/detach/release. No AudioTrack mutation happens from any callback.
//
// Fail-closed rules:
// - attach/detach exceptions are recorded and reported as false; they never
//   propagate.
// - A full queue drops the event and increments [droppedCount]; for Y12
//   production, the session-owned routing monitor detects droppedCount growth
//   and fails the session closed with routing_event_dropped; the sink bridge
//   owns only listener attach/detach and never drains/gates events.
// - Callbacks arriving while no listener is attached or after [release] are
//   counted, not enqueued.
// - [release] is idempotent: it detaches the listener at most once when it
//   is attached. It never releases the AudioTrack; the sink owns that and
//   must call [release] BEFORE releasing the track.
//
// No audio focus, no becoming-noisy receiver, no dead-object recovery
// policy lives here (Y4a / the sink own those).
class VanguardRealtimePlaybackRoutingController(
    private val listenerHandler: Handler,
    private val queueCapacity: Int = DEFAULT_QUEUE_CAPACITY,
) {
    enum class Tag { ROUTE_CHANGED, ROUTE_DISCONNECT }

    enum class Source { OS_ROUTING_CALLBACK, SYNTHETIC }

    data class Event(
        val tag: Tag,
        val seq: Long,
        val source: Source,
        val enqueuedAtElapsedMs: Long,
    )

    companion object {
        const val DEFAULT_QUEUE_CAPACITY = 32
        private const val AWAIT_SLICE_MS = 10L
    }

    private val queue = ArrayBlockingQueue<Event>(maxOf(1, queueCapacity))
    private val enqueueLock = Any()
    private val nextSeq = AtomicLong(0L)
    private val released = AtomicBoolean(false)
    private val listenerLive = AtomicBoolean(false)

    // -- Accounting (any-thread readable) ---------------------------------
    private val enqueuedTotal = AtomicLong(0L)
    private val drainedTotal = AtomicLong(0L)
    private val dropped = AtomicLong(0L)
    private val ignoredWhileDetached = AtomicLong(0L)
    private val ignoredAfterRelease = AtomicLong(0L)
    private val realRoutingCallbacks = AtomicLong(0L)
    private val syntheticRouteChangedPosted = AtomicLong(0L)
    private val syntheticRouteDisconnectPosted = AtomicLong(0L)
    private val enqueuedPerTag = Tag.entries.associateWith { AtomicLong(0L) }
    private val drainedPerTag = Tag.entries.associateWith { AtomicLong(0L) }

    // -- Attachment state (mutated only on the caller's run thread) -------
    @Volatile private var attachedTrack: AudioTrack? = null
    @Volatile private var attachAttempts = 0
    @Volatile private var detachAttempts = 0
    @Volatile private var attachError = ""
    @Volatile private var detachError = ""

    // The ONE real routing listener. Only counts and enqueues.
    private val routingListener = AudioRouting.OnRoutingChangedListener { _ ->
        realRoutingCallbacks.incrementAndGet()
        enqueue(Tag.ROUTE_CHANGED, Source.OS_ROUTING_CALLBACK)
    }

    // -- Public read-only state -------------------------------------------

    val isAttached: Boolean get() = attachedTrack != null
    val isReleased: Boolean get() = released.get()
    val attachCount: Int get() = attachAttempts
    val detachCount: Int get() = detachAttempts
    val lastAttachError: String get() = attachError
    val lastDetachError: String get() = detachError

    val enqueuedCount: Long get() = enqueuedTotal.get()
    val drainedCount: Long get() = drainedTotal.get()
    val droppedCount: Long get() = dropped.get()
    val ignoredWhileDetachedCount: Long get() = ignoredWhileDetached.get()
    val ignoredAfterReleaseCount: Long get() = ignoredAfterRelease.get()
    val realRoutingCallbackCount: Long get() = realRoutingCallbacks.get()
    val syntheticRouteChangedPostedCount: Long get() = syntheticRouteChangedPosted.get()
    val syntheticRouteDisconnectPostedCount: Long get() = syntheticRouteDisconnectPosted.get()
    val pendingCount: Int get() = queue.size

    fun enqueuedCountFor(tag: Tag): Long = enqueuedPerTag.getValue(tag).get()
    fun drainedCountFor(tag: Tag): Long = drainedPerTag.getValue(tag).get()

    // -- Attach / detach (run thread) -------------------------------------

    // Adds the listener to `track`, delivered on the listener Handler.
    // Exactly one track may be attached at a time; a handoff to a recreated
    // track is detach() then attach(newTrack). Returns true only when the
    // OS accepted the registration. Any exception is recorded and reported
    // as false.
    fun attach(track: AudioTrack): Boolean {
        if (released.get()) {
            attachError = "released"
            return false
        }
        if (attachedTrack != null) {
            attachError = "already_attached"
            return false
        }
        attachAttempts++
        return try {
            track.addOnRoutingChangedListener(routingListener, listenerHandler)
            attachedTrack = track
            listenerLive.set(true)
            true
        } catch (t: Throwable) {
            attachError = "routing_listener_attach_exception:${t.javaClass.simpleName}:${t.message}"
            false
        }
    }

    // Removes the listener from the currently attached track. Late
    // callbacks after this point are counted, not enqueued. Returns false
    // when nothing was attached or the removal threw (recorded). Never
    // throws.
    fun detach(): Boolean {
        val track = attachedTrack ?: return false
        detachAttempts++
        listenerLive.set(false)
        attachedTrack = null
        return try {
            track.removeOnRoutingChangedListener(routingListener)
            true
        } catch (t: Throwable) {
            detachError = "routing_listener_detach_exception:${t.javaClass.simpleName}:${t.message}"
            false
        }
    }

    // -- Synthetic injection ----------------------------------------------

    // Posts one synthetic ROUTE_CHANGED through the listener Handler so it
    // enters the queue on exactly the same thread and path as a real OS
    // routing callback. Returns false when the post itself was rejected.
    fun postSyntheticRouteChanged(): Boolean {
        if (released.get()) return false
        val posted = listenerHandler.post {
            enqueue(Tag.ROUTE_CHANGED, Source.SYNTHETIC, bypassLiveGate = true)
        }
        if (posted) syntheticRouteChangedPosted.incrementAndGet()
        return posted
    }

    // Enqueues the ONE synthetic ROUTE_DISCONNECT synchronously on the
    // calling (sink run) thread so the very next drain point on that thread
    // applies it. Returns false when released or when the queue was full
    // (the drop is counted).
    fun postSyntheticRouteDisconnect(): Boolean {
        if (released.get()) return false
        syntheticRouteDisconnectPosted.incrementAndGet()
        return enqueue(Tag.ROUTE_DISCONNECT, Source.SYNTHETIC, bypassLiveGate = true)
    }

    // -- Drain points (sink run thread) -----------------------------------

    // Non-blocking pop of the oldest pending event, or null.
    fun pollEvent(): Event? {
        val event = queue.poll() ?: return null
        drainedTotal.incrementAndGet()
        drainedPerTag.getValue(event.tag).incrementAndGet()
        return event
    }

    // Bounded wait for the oldest pending event, sliced so the caller's
    // `keepWaiting` predicate (cancel/deadline) is consulted regularly.
    fun awaitEvent(timeoutMs: Long, keepWaiting: () -> Boolean = { true }): Event? {
        val deadline = SystemClock.elapsedRealtime() + maxOf(0L, timeoutMs)
        while (true) {
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0L) return pollEvent()
            if (!keepWaiting()) return null
            val event = queue.poll(minOf(remaining, AWAIT_SLICE_MS), TimeUnit.MILLISECONDS)
            if (event != null) {
                drainedTotal.incrementAndGet()
                drainedPerTag.getValue(event.tag).incrementAndGet()
                return event
            }
        }
    }

    // Pops everything currently pending (oldest first).
    fun drainAll(): List<Event> {
        val out = ArrayList<Event>()
        while (true) {
            val event = pollEvent() ?: break
            out.add(event)
        }
        return out
    }

    // -- Teardown (run thread; idempotent) --------------------------------

    // Detaches the listener once when attached. Must run BEFORE the owning
    // sink releases the AudioTrack. Late callbacks after this point are
    // counted, not enqueued. Never throws.
    fun release() {
        if (!released.compareAndSet(false, true)) return
        if (attachedTrack != null) detach()
        listenerLive.set(false)
    }

    // -- Telemetry snapshot -----------------------------------------------

    fun telemetry(): Map<String, Any?> = mapOf(
        "attached" to isAttached,
        "attachCount" to attachAttempts,
        "detachCount" to detachAttempts,
        "attachError" to attachError,
        "detachError" to detachError,
        "queueCapacity" to queueCapacity,
        "eventsEnqueued" to enqueuedTotal.get(),
        "eventsDrained" to drainedTotal.get(),
        "eventsDropped" to dropped.get(),
        "eventsIgnoredWhileDetached" to ignoredWhileDetached.get(),
        "eventsIgnoredAfterRelease" to ignoredAfterRelease.get(),
        "eventsPending" to queue.size,
        "realRoutingCallbackCount" to realRoutingCallbacks.get(),
        "syntheticRouteChangedPostedCount" to syntheticRouteChangedPosted.get(),
        "syntheticRouteDisconnectPostedCount" to syntheticRouteDisconnectPosted.get(),
        "released" to released.get(),
    ) + Tag.entries.associate { tag ->
        "enqueued_${tag.name.lowercase()}" to enqueuedPerTag.getValue(tag).get()
    } + Tag.entries.associate { tag ->
        "drained_${tag.name.lowercase()}" to drainedPerTag.getValue(tag).get()
    }

    // -- Single enqueue path ----------------------------------------------

    // Real callbacks are gated on the listener being live (attached); a
    // callback that lands after detach is counted as ignored. Synthetic
    // posts bypass that gate but never the release gate. Returns true only
    // when the event entered the queue.
    private fun enqueue(tag: Tag, source: Source, bypassLiveGate: Boolean = false): Boolean {
        if (released.get()) {
            ignoredAfterRelease.incrementAndGet()
            return false
        }
        if (!bypassLiveGate && !listenerLive.get()) {
            ignoredWhileDetached.incrementAndGet()
            return false
        }
        // seq assignment and offer are atomic together so the seq order is
        // exactly the queue order.
        synchronized(enqueueLock) {
            val event = Event(
                tag = tag,
                seq = nextSeq.get(),
                source = source,
                enqueuedAtElapsedMs = SystemClock.elapsedRealtime(),
            )
            return if (queue.offer(event)) {
                nextSeq.incrementAndGet()
                enqueuedTotal.incrementAndGet()
                enqueuedPerTag.getValue(tag).incrementAndGet()
                true
            } else {
                dropped.incrementAndGet()
                false
            }
        }
    }
}
