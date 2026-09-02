package com.connects.vanguard_media_engine.audio_playback_graph

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

// -- VanguardRealtimePlaybackAudioFocusController (P4-AUDIO-REALTIME-
// PLAYBACK-FOCUS-RESPONSE, Y4a) -------------------------------------------
//
// Owns every OS-facing audio-focus / becoming-noisy registration for one
// realtime playback run: the application Context, the AudioManager, one
// AudioFocusRequest (API 26+) or the deprecated listener path (API 24/25),
// one OnAudioFocusChangeListener and one ACTION_AUDIO_BECOMING_NOISY
// BroadcastReceiver. All OS callbacks are delivered on the supplied main
// Handler and do exactly one thing: enqueue a typed [Event] (enum tag +
// monotonically increasing seq) into ONE bounded queue. Synthetic events
// used by the diagnostic take the SAME path (posted to the main Handler,
// enqueued there). Nothing is ever applied here: the sink pops events on
// its own run thread at explicit drain points and applies them itself.
//
// Fail-closed rules:
// - Focus request / receiver registration exceptions are recorded and
//   reported as not granted / not registered; they never propagate.
// - A full queue drops the event and increments [droppedCount]; the sink
//   gates any non-zero drop count to a failed verdict.
// - Events arriving after [release] are counted ([ignoredAfterReleaseCount])
//   and not enqueued.
// - [release] is idempotent: the receiver is unregistered at most once when
//   it was registered, focus is abandoned at most once when it was
//   requested.
//
// No route-change listener and no dead-object recovery live here (Y4b).
class VanguardRealtimePlaybackAudioFocusController(
    context: Context,
    private val mainHandler: Handler,
    private val queueCapacity: Int = DEFAULT_QUEUE_CAPACITY,
) {
    enum class Tag {
        FOCUS_GAIN,
        FOCUS_LOSS_PERMANENT,
        FOCUS_LOSS_TRANSIENT,
        FOCUS_LOSS_TRANSIENT_CAN_DUCK,
        BECOMING_NOISY,
        FOCUS_UNKNOWN;

        companion object {
            fun fromFocusChange(focusChange: Int): Tag = when (focusChange) {
                AudioManager.AUDIOFOCUS_GAIN,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE -> FOCUS_GAIN
                AudioManager.AUDIOFOCUS_LOSS -> FOCUS_LOSS_PERMANENT
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> FOCUS_LOSS_TRANSIENT
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> FOCUS_LOSS_TRANSIENT_CAN_DUCK
                else -> FOCUS_UNKNOWN
            }
        }
    }

    enum class Source { OS_FOCUS_CALLBACK, OS_NOISY_BROADCAST, SYNTHETIC }

    data class Event(
        val tag: Tag,
        val seq: Long,
        val source: Source,
        val rawFocusChange: Int,
        val enqueuedAtElapsedMs: Long,
    )

    companion object {
        const val DEFAULT_QUEUE_CAPACITY = 32
        const val RESULT_NOT_ATTEMPTED = Int.MIN_VALUE
        private const val AWAIT_SLICE_MS = 10L
    }

    private val appContext: Context = context.applicationContext ?: context
    private val audioManager: AudioManager? =
        try {
            appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        } catch (_: Throwable) {
            null
        }

    private val queue = ArrayBlockingQueue<Event>(maxOf(1, queueCapacity))
    private val enqueueLock = Any()
    private val nextSeq = AtomicLong(0L)
    private val released = AtomicBoolean(false)

    // -- Accounting (any-thread readable) ---------------------------------
    private val enqueuedTotal = AtomicLong(0L)
    private val drainedTotal = AtomicLong(0L)
    private val dropped = AtomicLong(0L)
    private val ignoredAfterRelease = AtomicLong(0L)
    private val realFocusCallbacks = AtomicLong(0L)
    private val realNoisyBroadcasts = AtomicLong(0L)
    private val syntheticPosted = AtomicLong(0L)
    private val enqueuedPerTag = Tag.entries.associateWith { AtomicLong(0L) }
    private val drainedPerTag = Tag.entries.associateWith { AtomicLong(0L) }

    // -- Registration state (mutated only on the caller's run thread) -----
    @Volatile private var focusRequested = false
    @Volatile private var focusGranted = false
    @Volatile private var focusRequestResult = RESULT_NOT_ATTEMPTED
    @Volatile private var focusRequestError = ""
    @Volatile private var focusAbandonAttempts = 0
    @Volatile private var focusAbandonResult = RESULT_NOT_ATTEMPTED
    @Volatile private var focusAbandonError = ""
    @Volatile private var receiverRegistered = false
    @Volatile private var receiverRegisterError = ""
    @Volatile private var receiverUnregisterAttempts = 0
    @Volatile private var receiverUnregisterError = ""

    private var focusRequestApi26: AudioFocusRequest? = null
    private var noisyReceiver: BroadcastReceiver? = null

    private val focusListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        realFocusCallbacks.incrementAndGet()
        enqueue(Tag.fromFocusChange(focusChange), Source.OS_FOCUS_CALLBACK, focusChange)
    }

    // -- Public read-only state -------------------------------------------

    val isFocusRequested: Boolean get() = focusRequested
    val isFocusGranted: Boolean get() = focusGranted
    val isReceiverRegistered: Boolean get() = receiverRegistered
    val isReleased: Boolean get() = released.get()
    val audioManagerAvailable: Boolean get() = audioManager != null

    val enqueuedCount: Long get() = enqueuedTotal.get()
    val drainedCount: Long get() = drainedTotal.get()
    val droppedCount: Long get() = dropped.get()
    val ignoredAfterReleaseCount: Long get() = ignoredAfterRelease.get()
    val realFocusCallbackCount: Long get() = realFocusCallbacks.get()
    val realNoisyBroadcastCount: Long get() = realNoisyBroadcasts.get()
    val syntheticPostedCount: Long get() = syntheticPosted.get()
    val pendingCount: Int get() = queue.size
    val focusAbandonCount: Int get() = focusAbandonAttempts
    val receiverUnregisterCount: Int get() = receiverUnregisterAttempts

    fun enqueuedCountFor(tag: Tag): Long = enqueuedPerTag.getValue(tag).get()
    fun drainedCountFor(tag: Tag): Long = drainedPerTag.getValue(tag).get()

    // -- Registration (run thread) ----------------------------------------

    // Requests AUDIOFOCUS_GAIN for USAGE_MEDIA / CONTENT_TYPE_MUSIC with the
    // listener bound to the main Handler. Returns true only when the OS
    // granted focus. Any exception is recorded and reported as not granted.
    fun requestFocus(): Boolean {
        if (released.get()) {
            focusRequestError = "released"
            return false
        }
        if (focusRequested) return focusGranted
        val am = audioManager
        if (am == null) {
            focusRequestError = "audio_manager_unavailable"
            return false
        }
        focusRequested = true
        try {
            val result: Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build(),
                    )
                    .setOnAudioFocusChangeListener(focusListener, mainHandler)
                    .build()
                focusRequestApi26 = request
                am.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    focusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN,
                )
            }
            focusRequestResult = result
            focusGranted = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            if (!focusGranted) focusRequestError = "focus_request_result_$result"
        } catch (t: Throwable) {
            focusGranted = false
            focusRequestError = "focus_request_exception:${t.javaClass.simpleName}:${t.message}"
        }
        return focusGranted
    }

    // Registers the ACTION_AUDIO_BECOMING_NOISY receiver. API 33+ uses
    // RECEIVER_NOT_EXPORTED (system broadcasts are still delivered). Any
    // exception is recorded and reported as not registered.
    fun registerNoisyReceiver(): Boolean {
        if (released.get()) {
            receiverRegisterError = "released"
            return false
        }
        if (receiverRegistered) return true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
                realNoisyBroadcasts.incrementAndGet()
                enqueue(Tag.BECOMING_NOISY, Source.OS_NOISY_BROADCAST, 0)
            }
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                appContext.registerReceiver(receiver, filter)
            }
            noisyReceiver = receiver
            receiverRegistered = true
        } catch (t: Throwable) {
            receiverRegistered = false
            receiverRegisterError = "receiver_register_exception:${t.javaClass.simpleName}:${t.message}"
        }
        return receiverRegistered
    }

    // -- Synthetic injection (any thread; enqueue happens on the main Handler) -

    // Posts one synthetic focus-change event through the main Handler so it
    // enters the queue on exactly the same thread and path as a real OS
    // focus callback. Returns false when the post itself was rejected.
    fun postSyntheticFocusChange(focusChange: Int): Boolean {
        if (released.get()) return false
        val posted = mainHandler.post {
            enqueue(Tag.fromFocusChange(focusChange), Source.SYNTHETIC, focusChange)
        }
        if (posted) syntheticPosted.incrementAndGet()
        return posted
    }

    // Posts one synthetic becoming-noisy event through the main Handler
    // (the receiver's delivery thread).
    fun postSyntheticBecomingNoisy(): Boolean {
        if (released.get()) return false
        val posted = mainHandler.post {
            enqueue(Tag.BECOMING_NOISY, Source.SYNTHETIC, 0)
        }
        if (posted) syntheticPosted.incrementAndGet()
        return posted
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

    // Unregisters the receiver once when registered, abandons focus once
    // when requested. Late callbacks after this point are counted, not
    // enqueued. Never throws.
    fun release() {
        if (!released.compareAndSet(false, true)) return
        unregisterNoisyReceiverOnce()
        abandonFocusOnce()
    }

    private fun unregisterNoisyReceiverOnce() {
        val receiver = noisyReceiver ?: return
        if (!receiverRegistered || receiverUnregisterAttempts > 0) return
        receiverUnregisterAttempts++
        try {
            appContext.unregisterReceiver(receiver)
        } catch (t: Throwable) {
            receiverUnregisterError = "receiver_unregister_exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            noisyReceiver = null
        }
    }

    private fun abandonFocusOnce() {
        if (!focusRequested || focusAbandonAttempts > 0) return
        val am = audioManager ?: return
        focusAbandonAttempts++
        try {
            focusAbandonResult = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = focusRequestApi26
                if (request != null) am.abandonAudioFocusRequest(request) else RESULT_NOT_ATTEMPTED
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusListener)
            }
        } catch (t: Throwable) {
            focusAbandonError = "focus_abandon_exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            focusRequestApi26 = null
        }
    }

    // -- Telemetry snapshot -----------------------------------------------

    fun telemetry(): Map<String, Any?> = mapOf(
        "audioManagerAvailable" to audioManagerAvailable,
        "focusRequested" to focusRequested,
        "focusGranted" to focusGranted,
        "focusRequestResult" to focusRequestResult,
        "focusRequestError" to focusRequestError,
        "focusAbandonCount" to focusAbandonAttempts,
        "focusAbandonResult" to focusAbandonResult,
        "focusAbandonError" to focusAbandonError,
        "receiverRegistered" to receiverRegistered,
        "receiverRegisterError" to receiverRegisterError,
        "receiverUnregisterCount" to receiverUnregisterAttempts,
        "receiverUnregisterError" to receiverUnregisterError,
        "receiverNotExportedFlagUsed" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU),
        "queueCapacity" to queueCapacity,
        "eventsEnqueued" to enqueuedTotal.get(),
        "eventsDrained" to drainedTotal.get(),
        "eventsDropped" to dropped.get(),
        "eventsIgnoredAfterRelease" to ignoredAfterRelease.get(),
        "eventsPending" to queue.size,
        "realFocusCallbackCount" to realFocusCallbacks.get(),
        "realNoisyBroadcastCount" to realNoisyBroadcasts.get(),
        "syntheticPostedCount" to syntheticPosted.get(),
        "released" to released.get(),
    ) + Tag.entries.associate { tag ->
        "enqueued_${tag.name.lowercase()}" to enqueuedPerTag.getValue(tag).get()
    } + Tag.entries.associate { tag ->
        "drained_${tag.name.lowercase()}" to drainedPerTag.getValue(tag).get()
    }

    // -- Single enqueue path (main Handler thread for every source) -------

    private fun enqueue(tag: Tag, source: Source, rawFocusChange: Int) {
        if (released.get()) {
            ignoredAfterRelease.incrementAndGet()
            return
        }
        // seq assignment and offer are atomic together so the seq order is
        // exactly the queue order.
        synchronized(enqueueLock) {
            val event = Event(
                tag = tag,
                seq = nextSeq.get(),
                source = source,
                rawFocusChange = rawFocusChange,
                enqueuedAtElapsedMs = SystemClock.elapsedRealtime(),
            )
            if (queue.offer(event)) {
                nextSeq.incrementAndGet()
                enqueuedTotal.incrementAndGet()
                enqueuedPerTag.getValue(tag).incrementAndGet()
            } else {
                dropped.incrementAndGet()
            }
        }
    }
}
