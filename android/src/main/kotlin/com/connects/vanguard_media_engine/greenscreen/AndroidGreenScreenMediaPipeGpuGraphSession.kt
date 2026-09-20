package com.connects.vanguard_media_engine.greenscreen

import android.content.Context
import android.util.Log
import android.view.Surface
import com.google.mediapipe.framework.AndroidAssetUtil
import com.google.mediapipe.framework.Graph
import com.google.mediapipe.framework.GraphTextureFrame
import com.google.mediapipe.framework.Packet
import com.google.mediapipe.framework.PacketCreator
import com.google.mediapipe.framework.PacketGetter
import com.google.mediapipe.framework.SurfaceOutput
import com.google.mediapipe.framework.TextureReleaseCallback
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// VG-GREENSCREEN: MediaPipe Framework GPU graph lifecycle + frame I/O.
// -----------------------------------------------------------------------------
//
// Opens the low-level com.google.mediapipe.framework.Graph API directly
// against the `SelfieSegmentationGpu` module graph: loads the compiled
// binary graph asset, sets the MODEL_SELECTION input side packet, registers a
// SEGMENTATION_MASK callback that forwards each mask GraphTextureFrame to
// [maskTextureCallback], and starts the graph. [sendRgbaTexture2d] feeds a
// caller-resolved RGBA GL texture (from [AndroidGreenScreenGpuTextureBridge]) into
// the graph's `image` input stream; this class itself does not touch camera
// or AHardwareBuffer APIs directly.
//
// This diagnostic graph requires the package-owned custom MediaPipe
// framework JNI native library (libmediapipe_jni.so, bundled under
// jniLibs/arm64-v8a alongside its libopencv_java4.so dependency) — not the
// Tasks Vision JNI shipped by the tasks-vision Maven dependency. The
// low-level Graph/PacketCreator/PacketGetter native symbols this class calls
// are not exported by libmediapipe_tasks_vision_jni.so.

class AndroidGreenScreenMediaPipeGpuGraphSession {

    companion object {
        private const val TAG = "GreenScreenMpGpuGraph"

        private const val GRAPH_ASSET_PATH =
            "mediapipe/modules/selfie_segmentation/selfie_segmentation_gpu.binarypb"
        private const val MODEL_SELECTION_SIDE_PACKET = "model_selection"
        private const val SEGMENTATION_MASK_STREAM = "segmentation_mask"
        private const val IMAGE = "image"

        // AndroidAssetUtil.initializeNativeAssetManager() calls a native method
        // (nativeInitializeAssetManager) implemented inside the package-owned
        // custom MediaPipe framework JNI library (libmediapipe_jni.so, bundled
        // under jniLibs/arm64-v8a), not the tasks-vision dependency's JNI. On
        // some devices that library is not yet loaded into the process when
        // this class is first used, which throws UnsatisfiedLinkError. Load it
        // once, fail closed, and cache the result so every open() call after a
        // failed load returns false without retrying or throwing.
        private const val NATIVE_LIBRARY_NAME = "mediapipe_jni"

        @Volatile private var nativeLibraryLoaded: Boolean? = null

        private fun ensureNativeLibraryLoaded(): Boolean {
            nativeLibraryLoaded?.let { return it }
            synchronized(this) {
                nativeLibraryLoaded?.let { return it }
                val loaded = try {
                    System.loadLibrary(NATIVE_LIBRARY_NAME)
                    true
                } catch (t: Throwable) {
                    Log.e(
                        TAG,
                        "System.loadLibrary($NATIVE_LIBRARY_NAME) failed: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        t,
                    )
                    false
                }
                nativeLibraryLoaded = loaded
                return loaded
            }
        }
    }

    /** True once [open] has not yet succeeded, or after [close]; false while a graph is live. */
    private val closed = AtomicBoolean(true)

    @Volatile private var graph: Graph? = null
    @Volatile private var surfaceOutput: SurfaceOutput? = null

    /**
     * Receives each decoded segmentation-mask [GraphTextureFrame] plus its timestamp (in
     * microseconds). The callback owns the frame and must call [GraphTextureFrame.release] on
     * it once done consuming it (e.g. after sampling it into a GL draw call).
     */
    @Volatile private var maskTextureCallback: ((GraphTextureFrame, Long) -> Unit)? = null

    /** Sets or clears the mask-texture consumer. Pass `null` to stop receiving frames. */
    fun setMaskTextureCallback(callback: ((GraphTextureFrame, Long) -> Unit)?) {
        maskTextureCallback = callback
    }

    /**
     * Loads and starts the selfie-segmentation GPU graph. [modelSelection] selects the
     * general-purpose (0) or landscape-optimized (1) model; any other value is clamped to 0
     * (the graph's own documented default when the side packet is unspecified).
     *
     * Never throws: returns `false` and logs on any failure so this stays safe to call from
     * exploratory/manual proof code. Idempotent against a live session — returns `false` if
     * already open.
     */
    fun open(
        context: Context,
        modelSelection: Int,
        parentGlContext: Long = 0L,
        maskOutputSurface: Surface? = null,
    ): Boolean {
        if (graph != null) {
            Log.w(TAG, "open() called while a graph session is already live; ignoring")
            return false
        }
        if (!ensureNativeLibraryLoaded()) {
            Log.w(TAG, "open() failed: native MediaPipe library not loaded")
            return false
        }
        val clampedModelSelection = if (modelSelection == 1) 1 else 0

        var createdGraph: Graph? = null
        return try {
            AndroidAssetUtil.initializeNativeAssetManager(context)

            val g = Graph()
            createdGraph = g
            g.loadBinaryGraph(AndroidAssetUtil.getAssetBytes(context.assets, GRAPH_ASSET_PATH))

            val packetCreator = PacketCreator(g)
            g.setInputSidePackets(
                mapOf(MODEL_SELECTION_SIDE_PACKET to packetCreator.createInt32(clampedModelSelection))
            )

            val requestedSurfaceOutput = if (maskOutputSurface != null) {
                g.addSurfaceOutput(SEGMENTATION_MASK_STREAM).also {
                    it.setFlipY(false)
                    it.setUpdatePresentationTime(true)
                }
            } else {
                null
            }

            if (requestedSurfaceOutput == null) {
                g.addMultiStreamCallback(listOf(SEGMENTATION_MASK_STREAM)) { packets ->
                    val packet = packets.firstOrNull()
                    if (packet == null) {
                        Log.w(TAG, "addMultiStreamCallback: no mask packet in list")
                    } else {
                        try {
                            val frame: GraphTextureFrame? = try {
                                PacketGetter.getTextureFrameDeferredSync(packet)
                            } catch (t: Throwable) {
                                Log.e(TAG, "getTextureFrameDeferredSync() failed: ${t.message}", t)
                                null
                            }
                            if (frame != null) {
                                val timestampUs = packet.timestamp
                                val callback = maskTextureCallback
                                if (!closed.get() && callback != null) {
                                    try {
                                        callback(frame, timestampUs)
                                    } catch (t: Throwable) {
                                        Log.e(TAG, "maskTextureCallback threw: ${t.message}", t)
                                        try { frame.release() } catch (_: Throwable) {}
                                    }
                                } else {
                                    try { frame.release() } catch (_: Throwable) {}
                                }
                            }
                        } finally {
                            try { packet.release() } catch (_: Throwable) {}
                        }
                    }
                }
            }

            if (parentGlContext != 0L) {
                try {
                    g.setParentGlContext(parentGlContext)
                } catch (t: Throwable) {
                    Log.w(
                        TAG,
                        "setParentGlContext() failed: ${t.javaClass.simpleName}: ${t.message}; " +
                            "continuing graph startup without a parent GL context",
                    )
                }
            }

            g.startRunningGraph()
            if (maskOutputSurface != null && requestedSurfaceOutput != null) {
                requestedSurfaceOutput.setSurface(maskOutputSurface)
                surfaceOutput = requestedSurfaceOutput
                Log.i(TAG, "ANDROID_GREENSCREEN_MEDIAPIPE_GPU_GRAPH_SURFACE_OUTPUT_ATTACHED")
            }

            graph = g
            closed.set(false)
            Log.i(TAG, "open() — graph running (modelSelection=$clampedModelSelection)")
            true
        } catch (t: Throwable) {
            Log.e(TAG, "open() failed: ${t.javaClass.simpleName}: ${t.message}", t)
            createdGraph?.let { tearDownQuietly(it) }
            false
        }
    }

    /**
     * Feeds a single RGBA-in-a-GL-texture frame into the graph's `image` input stream.
     * [onTextureReleased] fires exactly once: either when MediaPipe finishes consuming the
     * texture, or immediately if the texture was never handed off (invalid state/args, or the
     * enqueue itself failed). Never throws.
     */
    fun sendRgbaTexture2d(
        textureName: Int,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
        onTextureReleased: (() -> Unit)? = null,
    ): Boolean {
        val g = graph
        if (closed.get() || g == null) {
            Log.w(TAG, "sendRgbaTexture2d() called while graph is not live; ignoring")
            notifyTextureReleasedQuietly(onTextureReleased)
            return false
        }
        if (textureName <= 0 || widthPx <= 0 || heightPx <= 0) {
            Log.w(TAG, "sendRgbaTexture2d() invalid args textureName=$textureName ${widthPx}x$heightPx; ignoring")
            notifyTextureReleasedQuietly(onTextureReleased)
            return false
        }

        val releasedOnce = AtomicBoolean(false)
        val releaseOnce = {
            if (releasedOnce.compareAndSet(false, true)) {
                notifyTextureReleasedQuietly(onTextureReleased)
            }
        }

        var packet: Packet? = null
        return try {
            val created = PacketCreator(g).createGpuBuffer(
                textureName,
                widthPx,
                heightPx,
                TextureReleaseCallback { token ->
                    releaseOnce()
                    try { token?.release() } catch (_: Throwable) {}
                },
            )
            packet = created
            g.addConsumablePacketToInputStream(IMAGE, created, timestampUs)
            packet = null
            true
        } catch (t: Throwable) {
            Log.e(TAG, "sendRgbaTexture2d() failed: ${t.javaClass.simpleName}: ${t.message}", t)
            packet?.let { try { it.release() } catch (_: Throwable) {} }
            releaseOnce()
            false
        }
    }

    /** Releases the graph, if any. Idempotent and never throws; safe to call from any thread. */
    fun close() {
        maskTextureCallback = null
        val output = surfaceOutput
        surfaceOutput = null
        try { output?.setSurface(null) } catch (_: Throwable) {}
        if (!closed.compareAndSet(false, true)) return
        val g = graph ?: return
        graph = null
        tearDownQuietly(g)
        Log.i(TAG, "close() — graph released")
    }

    private fun notifyTextureReleasedQuietly(callback: (() -> Unit)?) {
        try {
            callback?.invoke()
        } catch (t: Throwable) {
            Log.e(TAG, "onTextureReleased threw: ${t.message}", t)
        }
    }

    private fun tearDownQuietly(g: Graph) {
        try { g.closeAllPacketSources() } catch (t: Throwable) {
            Log.w(TAG, "closeAllPacketSources() threw: ${t.message}")
        }
        try { g.waitUntilGraphDone() } catch (t: Throwable) {
            Log.w(TAG, "waitUntilGraphDone() threw: ${t.message}")
        }
        try { g.tearDown() } catch (t: Throwable) {
            Log.w(TAG, "tearDown() threw: ${t.message}")
        }
    }
}
