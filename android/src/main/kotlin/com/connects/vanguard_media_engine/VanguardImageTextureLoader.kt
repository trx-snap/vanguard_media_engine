package com.connects.vanguard_media_engine

// ── VanguardImageTextureLoader (Phase B3 — Android Media Fundamentals) ────────
//
// Android equivalent of iOS createImageTexture (CVPixelBuffer → Metal Texture).
//
// Pipeline:
//   BitmapFactory.decodeFile(imagePath)
//   → Surface.lockCanvas(null)
//   → canvas.drawBitmap(bitmap, 0, 0, null)
//   → surface.unlockCanvasAndPost()
//   → Flutter TextureRegistry.SurfaceTextureEntry (textureId)
//
// Design decisions:
//   1. Canvas blit (no EGL/GLES context) — correct for write-once static images.
//      If colour-space parity with iOS Metal path is needed, migrate to GLES in B4.
//   2. Background thread for BitmapFactory.decodeFile() — avoids main-thread I/O.
//   3. Callbacks posted on main thread (mirrors VanguardCameraSource.start() pattern).
//   4. textureEntry.release() called in dispose() — caller must call dispose() to
//      unregister the texture from Flutter's registry.
//   5. One loader per textureId — plugin keeps imageLoaders map (keyed by textureId)
//      so dispose() can look up and release by id.

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry

internal class VanguardImageTextureLoader(
    private val imagePath: String,
    textureRegistry: TextureRegistry,
) {
    private val TAG          = "VanguardImageTex"
    private val textureEntry = textureRegistry.createSurfaceTexture()

    /** The Flutter texture ID that Dart passes to `Texture(textureId: id)`. */
    val textureId: Long get() = textureEntry.id()

    /**
     * Decodes [imagePath] on a background thread and blits it into the Flutter
     * SurfaceTexture via Canvas.
     *
     * @param onLoaded Called on the main thread with the ready [textureId].
     * @param onError  Called on the main thread if decoding or blitting fails.
     *   The textureEntry is already released at this point — do NOT call dispose().
     */
    fun load(
        onLoaded: (Long) -> Unit,
        onError: (Exception) -> Unit,
    ) {
        Thread {
            try {
                val bitmap = BitmapFactory.decodeFile(imagePath)
                    ?: throw IllegalArgumentException("BitmapFactory returned null — cannot decode: $imagePath")

                // Set the SurfaceTexture buffer dimensions to match the image.
                // Must be called before lockCanvas.
                val surfaceTexture = textureEntry.surfaceTexture()
                surfaceTexture.setDefaultBufferSize(bitmap.width, bitmap.height)

                // Draw bitmap into Surface via Canvas.
                // Surface.lockCanvas(null) locks the entire surface for drawing.
                val surface = Surface(surfaceTexture)
                val canvas  = surface.lockCanvas(null)
                canvas.drawBitmap(bitmap, 0f, 0f, null)
                surface.unlockCanvasAndPost(canvas)
                surface.release()
                bitmap.recycle()

                Log.i(TAG, "load OK — textureId=$textureId (${bitmap.width}×${bitmap.height})")
                Handler(Looper.getMainLooper()).post { onLoaded(textureId) }

            } catch (e: Exception) {
                Log.e(TAG, "load failed for '$imagePath': $e")
                // Release the texture entry now — caller must NOT call dispose()
                // in the error path (there is nothing to clean up).
                textureEntry.release()
                Handler(Looper.getMainLooper()).post { onError(e) }
            }
        }.start()
    }

    /**
     * Releases the Flutter SurfaceTextureEntry.
     * Must be called when the `Texture(textureId)` widget is disposed.
     * Safe to call multiple times — subsequent calls are no-ops after the first.
     */
    fun dispose() {
        Log.i(TAG, "dispose — textureId=$textureId")
        textureEntry.release()
    }
}
