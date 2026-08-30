package com.connects.vanguard_media_engine.codec

import java.util.concurrent.atomic.AtomicInteger

/**
 * Vanguard Android True-DAG P2-CONCURRENT-DEC: concurrent decoder slot admission.
 *
 * Tracks active hardware decoder slot admission for one coordinator run, gated by
 * [advisoryMaxInstances] (from [AndroidConcurrentDecoderSlotPolicy.getAdvisoryMaxInstances]).
 * This is an upper-bound gate only: a granted slot does not guarantee the codec will
 * create/configure/start successfully -- callers must still call [releaseSlot] on any
 * downstream failure so admission accounting stays correct.
 */
class AndroidConcurrentDecoderPool(private val advisoryMaxInstances: Int) {
    private val activeSlots = AtomicInteger(0)

    fun acquireSlot(): Boolean {
        while (true) {
            val current = activeSlots.get()
            if (current >= advisoryMaxInstances) return false
            if (activeSlots.compareAndSet(current, current + 1)) return true
        }
    }

    fun releaseSlot() {
        activeSlots.updateAndGet { current -> if (current > 0) current - 1 else 0 }
    }

    fun activeCount(): Int = activeSlots.get()
}
