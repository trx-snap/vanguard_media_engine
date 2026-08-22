package com.connects.vanguard_media_engine.codec

data class AndroidDagPlaybackTransitionResult(
    val pass: Boolean,
    val fromState: AndroidDagPlaybackState,
    val toState: AndroidDagPlaybackState,
    val event: String,
    val reason: String? = null,
)

enum class AndroidDagPlaybackEvent {
    PrepareStarted,
    PrepareSucceeded,
    PlayRequested,
    PauseRequested,
    SeekStarted,
    SeekCompletedPaused,
    SeekCompletedPlaying,
    SurfaceLost,
    SurfaceRestored,
    Backgrounded,
    Foregrounded,
    Completed,
    Failed,
    Dispose,
}

class AndroidDagPlaybackStateMachine(
    initialState: AndroidDagPlaybackState = AndroidDagPlaybackState.Idle,
) {
    var state: AndroidDagPlaybackState = initialState
        private set

    val currentState: AndroidDagPlaybackState
        get() = state

    fun transition(event: AndroidDagPlaybackEvent, failureReason: String? = null): AndroidDagPlaybackTransitionResult {
        val from = state
        val eventName = event.name

        // Disposed is terminal and idempotent for Dispose event
        if (from == AndroidDagPlaybackState.Disposed) {
            return if (event == AndroidDagPlaybackEvent.Dispose) {
                AndroidDagPlaybackTransitionResult(
                    pass = true,
                    fromState = from,
                    toState = AndroidDagPlaybackState.Disposed,
                    event = eventName,
                    reason = "Already disposed",
                )
            } else {
                AndroidDagPlaybackTransitionResult(
                    pass = false,
                    fromState = from,
                    toState = from,
                    event = eventName,
                    reason = "Invalid event $eventName in terminal state Disposed",
                )
            }
        }

        val targetState: AndroidDagPlaybackState? = when (event) {
            AndroidDagPlaybackEvent.PrepareStarted -> {
                when (from) {
                    AndroidDagPlaybackState.Idle -> AndroidDagPlaybackState.Preparing
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.PrepareSucceeded -> {
                when (from) {
                    AndroidDagPlaybackState.Preparing -> AndroidDagPlaybackState.Prepared
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.PlayRequested -> {
                when (from) {
                    AndroidDagPlaybackState.Prepared,
                    AndroidDagPlaybackState.Paused,
                    AndroidDagPlaybackState.Completed,
                    AndroidDagPlaybackState.Playing -> AndroidDagPlaybackState.Playing
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.PauseRequested -> {
                when (from) {
                    AndroidDagPlaybackState.Playing,
                    AndroidDagPlaybackState.Prepared,
                    AndroidDagPlaybackState.Paused -> AndroidDagPlaybackState.Paused
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.SeekStarted -> {
                when (from) {
                    AndroidDagPlaybackState.Prepared,
                    AndroidDagPlaybackState.Playing,
                    AndroidDagPlaybackState.Paused,
                    AndroidDagPlaybackState.Completed,
                    AndroidDagPlaybackState.Seeking -> AndroidDagPlaybackState.Seeking
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.SeekCompletedPaused -> {
                when (from) {
                    AndroidDagPlaybackState.Seeking -> AndroidDagPlaybackState.Paused
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.SeekCompletedPlaying -> {
                when (from) {
                    AndroidDagPlaybackState.Seeking -> AndroidDagPlaybackState.Playing
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.SurfaceLost -> {
                when (from) {
                    AndroidDagPlaybackState.Idle,
                    AndroidDagPlaybackState.Preparing,
                    AndroidDagPlaybackState.Prepared,
                    AndroidDagPlaybackState.Playing,
                    AndroidDagPlaybackState.Paused,
                    AndroidDagPlaybackState.Seeking,
                    AndroidDagPlaybackState.Completed,
                    AndroidDagPlaybackState.Backgrounded,
                    AndroidDagPlaybackState.SurfaceLost -> AndroidDagPlaybackState.SurfaceLost
                    AndroidDagPlaybackState.Failed,
                    AndroidDagPlaybackState.Disposed -> null
                }
            }
            AndroidDagPlaybackEvent.SurfaceRestored -> {
                when (from) {
                    AndroidDagPlaybackState.SurfaceLost -> AndroidDagPlaybackState.Paused
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.Backgrounded -> {
                when (from) {
                    AndroidDagPlaybackState.Idle,
                    AndroidDagPlaybackState.Preparing,
                    AndroidDagPlaybackState.Prepared,
                    AndroidDagPlaybackState.Playing,
                    AndroidDagPlaybackState.Paused,
                    AndroidDagPlaybackState.Seeking,
                    AndroidDagPlaybackState.Completed,
                    AndroidDagPlaybackState.SurfaceLost,
                    AndroidDagPlaybackState.Backgrounded -> AndroidDagPlaybackState.Backgrounded
                    AndroidDagPlaybackState.Failed,
                    AndroidDagPlaybackState.Disposed -> null
                }
            }
            AndroidDagPlaybackEvent.Foregrounded -> {
                when (from) {
                    AndroidDagPlaybackState.Backgrounded -> AndroidDagPlaybackState.Paused
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.Completed -> {
                when (from) {
                    AndroidDagPlaybackState.Playing,
                    AndroidDagPlaybackState.Seeking,
                    AndroidDagPlaybackState.Completed -> AndroidDagPlaybackState.Completed
                    else -> null
                }
            }
            AndroidDagPlaybackEvent.Failed -> {
                AndroidDagPlaybackState.Failed
            }
            AndroidDagPlaybackEvent.Dispose -> {
                AndroidDagPlaybackState.Disposed
            }
        }

        return if (targetState != null) {
            state = targetState
            AndroidDagPlaybackTransitionResult(
                pass = true,
                fromState = from,
                toState = targetState,
                event = eventName,
                reason = failureReason,
            )
        } else {
            AndroidDagPlaybackTransitionResult(
                pass = false,
                fromState = from,
                toState = from,
                event = eventName,
                reason = "Invalid transition $eventName from $from",
            )
        }
    }

    fun prepareStarted(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.PrepareStarted)

    fun prepareSucceeded(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.PrepareSucceeded)

    fun playRequested(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.PlayRequested)

    fun pauseRequested(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.PauseRequested)

    fun seekStarted(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.SeekStarted)

    fun seekCompletedPaused(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.SeekCompletedPaused)

    fun seekCompletedPlaying(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.SeekCompletedPlaying)

    fun surfaceLost(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.SurfaceLost)

    fun surfaceRestored(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.SurfaceRestored)

    fun backgrounded(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.Backgrounded)

    fun foregrounded(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.Foregrounded)

    fun completed(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.Completed)

    fun failed(reason: String? = null): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.Failed, failureReason = reason)

    fun dispose(): AndroidDagPlaybackTransitionResult =
        transition(AndroidDagPlaybackEvent.Dispose)
}
