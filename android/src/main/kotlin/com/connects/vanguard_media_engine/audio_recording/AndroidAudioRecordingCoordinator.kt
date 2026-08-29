package com.connects.vanguard_media_engine.audio_recording

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// ── AndroidAudioRecordingCoordinator (Phase 4-Unit H / Phase 5-Unit AC) ──────
//
// Owns the production `startAudioRecording` / `stopAudioRecording` MethodChannel
// routes -- Android parity with VGAudioRecordingHandler.swift (iOS), bounded to
// a timeline-independent slice: startPTS is deliberately frozen to 0.0 for both
// start and stop, and there is no NO_TIMELINE / runtime-handle dependency.
//
// State machine (main thread owned):
//   IDLE -> STARTING -> RECORDING -> STOPPING -> IDLE
// A single background executor serializes all blocking MediaRecorder /
// MediaMetadataRetriever I/O so the active recorder is never touched from two
// threads at once. Every async completion is delivered back to the main
// thread and re-validates (generation, detached) before mutating state or
// invoking the FlutterResult -- this also guards teardown races on dispose.
class AndroidAudioRecordingCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private val OWNED_METHODS = setOf("startAudioRecording", "stopAudioRecording")

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private enum class State { IDLE, STARTING, RECORDING, STOPPING }

    private var state: State = State.IDLE
    private var generation: Long = 0L
    @Volatile private var detached: Boolean = false

    private var activeRecorder: AndroidMediaRecorderWrapper? = null
    private var activeOutputPath: String? = null
    private var startElapsedRealtimeMs: Long = 0L

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        when (method) {
            "startAudioRecording" -> handleStart(args, result)
            "stopAudioRecording" -> handleStop(result)
        }
    }

    // ── startAudioRecording ───────────────────────────────────────────────────

    private fun handleStart(args: Map<*, *>?, result: MethodChannel.Result) {
        when (state) {
            State.STARTING -> {
                result.error("START_IN_PROGRESS",
                    "startAudioRecording: a start is already in progress", null)
                return
            }
            State.RECORDING -> {
                result.error("ALREADY_RECORDING",
                    "startAudioRecording: a recording is already active", null)
                return
            }
            State.STOPPING -> {
                result.error("STOP_IN_PROGRESS",
                    "startAudioRecording: a stop is currently in progress", null)
                return
            }
            State.IDLE -> {}
        }

        val outputPath = (args?.get("outputPath") as? String)?.takeIf { it.isNotEmpty() }
        if (outputPath == null) {
            result.error("INVALID_ARG",
                "startAudioRecording: outputPath is required and must be non-empty", null)
            return
        }

        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("MISSING_PERMISSION",
                "startAudioRecording: RECORD_AUDIO permission not granted", null)
            return
        }

        val routeSnapshot = AndroidAudioRouteInspector.capture(context)
        if (!routeSnapshot.inputAvailable) {
            result.error("NO_INPUT_AVAILABLE",
                "startAudioRecording: no audio input available", null)
            return
        }

        if (File(outputPath).exists()) {
            result.error("RECORDING_FAILED",
                "startAudioRecording: output file already exists: $outputPath", null)
            return
        }

        state = State.STARTING
        generation += 1
        val capturedGen = generation

        val wrapper = try {
            AndroidMediaRecorderWrapper.create(context, outputPath)
        } catch (t: Throwable) {
            state = State.IDLE
            result.error("RECORDING_FAILED", t.message ?: t.javaClass.simpleName, null)
            return
        }
        activeRecorder = wrapper
        activeOutputPath = outputPath

        executor.execute {
            var startError: Throwable? = null
            try {
                wrapper.prepareAndStart()
            } catch (t: Throwable) {
                startError = t
            }
            if (startError != null) {
                wrapper.releaseQuietly()
                try { File(outputPath).delete() } catch (_: Throwable) {}
            }
            val elapsedAtStart = SystemClock.elapsedRealtime()

            mainHandler.post {
                if (detached || generation != capturedGen) return@post
                if (startError != null) {
                    activeRecorder = null
                    activeOutputPath = null
                    state = State.IDLE
                    result.error("RECORDING_FAILED",
                        startError.message ?: startError.javaClass.simpleName, null)
                } else {
                    startElapsedRealtimeMs = elapsedAtStart
                    state = State.RECORDING
                    result.success(mapOf(
                        "filePath" to outputPath,
                        "startPTS" to 0.0,
                        "isHeadphonesConnected" to routeSnapshot.hasHeadphoneOutput,
                        "audioRoute" to routeSnapshot.toMap(),
                    ))
                }
            }
        }
    }

    // ── stopAudioRecording ────────────────────────────────────────────────────

    private fun handleStop(result: MethodChannel.Result) {
        when (state) {
            State.IDLE -> {
                result.error("NOT_RECORDING",
                    "stopAudioRecording: no recording is active", null)
                return
            }
            State.STARTING -> {
                result.error("START_IN_PROGRESS",
                    "stopAudioRecording: a start is currently in progress", null)
                return
            }
            State.STOPPING -> {
                result.error("STOP_IN_PROGRESS",
                    "stopAudioRecording: a stop is already in progress", null)
                return
            }
            State.RECORDING -> {}
        }

        val wrapper = activeRecorder
        val outputPath = activeOutputPath
        if (wrapper == null || outputPath == null) {
            state = State.IDLE
            result.error("STOP_FAILED", "stopAudioRecording: no active recorder", null)
            return
        }

        state = State.STOPPING
        generation += 1
        val capturedGen = generation
        val elapsedAtStart = startElapsedRealtimeMs

        executor.execute {
            var stopError: Throwable? = null
            try {
                wrapper.stopAndRelease()
            } catch (t: Throwable) {
                stopError = t
            }

            if (stopError != null) {
                try { File(outputPath).delete() } catch (_: Throwable) {}
                val error = stopError
                mainHandler.post {
                    if (detached || generation != capturedGen) return@post
                    activeRecorder = null
                    activeOutputPath = null
                    state = State.IDLE
                    result.error("STOP_FAILED", error.message ?: error.javaClass.simpleName, null)
                }
                return@execute
            }

            var durationSeconds = probeDurationSeconds(outputPath)
            if (durationSeconds == null || durationSeconds <= 0.0) {
                val elapsedMs = (SystemClock.elapsedRealtime() - elapsedAtStart).coerceAtLeast(0L)
                durationSeconds = elapsedMs / 1000.0
            }
            val resolvedDuration = durationSeconds

            mainHandler.post {
                if (detached || generation != capturedGen) return@post
                activeRecorder = null
                activeOutputPath = null
                state = State.IDLE
                result.success(mapOf(
                    "filePath" to outputPath,
                    "startPTS" to 0.0,
                    "durationSeconds" to resolvedDuration,
                    "transitionStatus" to mapOf(
                        "sessionRestored" to true,
                        "previewRecovered" to true,
                    ),
                ))
            }
        }
    }

    private fun probeDurationSeconds(path: String): Double? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val ms = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
            if (ms != null && ms >= 0L) ms / 1000.0 else null
        } catch (_: Throwable) {
            null
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /// Idempotently detaches, best-effort tears down any active recorder, and
    /// deletes its uncommitted output file. Never invokes a FlutterResult after
    /// this point -- matches the "no channel call after detach" convention used
    /// by the other coordinators in this plugin.
    fun disposeAll() {
        detached = true
        generation += 1
        val wrapper = activeRecorder
        val outputPath = activeOutputPath
        activeRecorder = null
        activeOutputPath = null
        state = State.IDLE
        if (wrapper != null) {
            executor.execute {
                wrapper.releaseQuietly()
                if (outputPath != null) {
                    try { File(outputPath).delete() } catch (_: Throwable) {}
                }
            }
        }
        executor.shutdown()
    }
}
