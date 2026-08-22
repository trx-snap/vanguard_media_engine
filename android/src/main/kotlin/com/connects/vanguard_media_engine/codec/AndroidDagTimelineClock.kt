package com.connects.vanguard_media_engine.codec

class AndroidDagTimelineClock(
    initialAnchorMediaPtsUs: Long = 0L,
    initialPlaybackSpeed: Double = 1.0,
) {
    var anchorMediaPtsUs: Long = maxOf(0L, initialAnchorMediaPtsUs)
        private set

    var anchorFrameTimeNanos: Long = 0L
        private set

    var playbackSpeed: Double = if (initialPlaybackSpeed > 0.0) initialPlaybackSpeed else 1.0
        private set

    var isPlaying: Boolean = false
        private set

    var isDisposed: Boolean = false
        private set

    fun currentPositionUs(frameTimeNanos: Long): Long {
        if (isDisposed) {
            return maxOf(0L, anchorMediaPtsUs)
        }
        if (!isPlaying || anchorFrameTimeNanos == 0L) {
            return maxOf(0L, anchorMediaPtsUs)
        }
        val elapsedNanos = frameTimeNanos - anchorFrameTimeNanos
        val elapsedUs = (elapsedNanos * playbackSpeed / 1000.0).toLong()
        val calculatedUs = anchorMediaPtsUs + elapsedUs
        return maxOf(0L, calculatedUs)
    }

    fun start(frameTimeNanos: Long, initialMediaPtsUs: Long = 0L): Long {
        if (isDisposed) return maxOf(0L, anchorMediaPtsUs)
        anchorMediaPtsUs = maxOf(0L, initialMediaPtsUs)
        anchorFrameTimeNanos = frameTimeNanos
        isPlaying = true
        return anchorMediaPtsUs
    }

    fun resume(frameTimeNanos: Long): Long {
        if (isDisposed) return maxOf(0L, anchorMediaPtsUs)
        if (!isPlaying) {
            anchorFrameTimeNanos = frameTimeNanos
            isPlaying = true
        }
        return currentPositionUs(frameTimeNanos)
    }

    fun pause(frameTimeNanos: Long): Long {
        if (isDisposed) return maxOf(0L, anchorMediaPtsUs)
        if (isPlaying) {
            anchorMediaPtsUs = currentPositionUs(frameTimeNanos)
            anchorFrameTimeNanos = frameTimeNanos
            isPlaying = false
        }
        return anchorMediaPtsUs
    }

    fun seek(targetPtsUs: Long, frameTimeNanos: Long): Long {
        if (isDisposed) return maxOf(0L, anchorMediaPtsUs)
        anchorMediaPtsUs = maxOf(0L, targetPtsUs)
        anchorFrameTimeNanos = frameTimeNanos
        return anchorMediaPtsUs
    }

    fun updateSeekAnchor(targetPtsUs: Long, frameTimeNanos: Long): Long {
        return seek(targetPtsUs, frameTimeNanos)
    }

    fun setPlaybackSpeed(speed: Double, frameTimeNanos: Long): Double {
        if (isDisposed) return playbackSpeed
        val validSpeed = if (speed > 0.0) speed else 1.0
        if (isPlaying && anchorFrameTimeNanos != 0L) {
            anchorMediaPtsUs = currentPositionUs(frameTimeNanos)
            anchorFrameTimeNanos = frameTimeNanos
        }
        playbackSpeed = validSpeed
        return playbackSpeed
    }

    fun reset(initialPtsUs: Long = 0L) {
        anchorMediaPtsUs = maxOf(0L, initialPtsUs)
        anchorFrameTimeNanos = 0L
        playbackSpeed = 1.0
        isPlaying = false
        isDisposed = false
    }

    fun dispose() {
        isPlaying = false
        isDisposed = true
    }
}
