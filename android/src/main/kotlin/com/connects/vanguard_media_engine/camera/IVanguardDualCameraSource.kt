package com.connects.vanguard_media_engine.camera

/**
 * Common lifecycle interface for dual-camera preview capture sources.
 *
 * Implemented by:
 * - [VanguardDualCameraSource]: CameraX ConcurrentCamera implementation for
 *   devices that advertise concurrent camera IDs in HAL.
 * - [VanguardGenericDualCamera2Source]: Direct Camera2 implementation for
 *   devices that support concurrent camera capture at hardware level but do not
 *   advertise concurrent IDs in HAL (e.g. Samsung, Xiaomi, OnePlus).
 */
interface IVanguardDualCameraSource {
    val running: Boolean
    val frontTextureId: Long
    val backTextureId: Long

    fun start(
        onStarted: (Map<String, Any>) -> Unit,
        onError: (Exception) -> Unit,
    )

    fun stop()
}
