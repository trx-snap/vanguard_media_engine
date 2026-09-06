package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.os.Handler
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.camera.AndroidCamera2CapabilityProbe
import com.connects.vanguard_media_engine.camera.AndroidCamera2ConcurrentSessionValidator
import com.connects.vanguard_media_engine.camera.AndroidCamera2HardwareBufferFrameSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2ImageReaderFrameSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2NativeRenderFrameSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2NativeRenderLoopSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2OpenCloseSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2ThermalFpsActionSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2ThermalListenerSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2ThermalResolutionReconfigureSmokeHarness
import com.connects.vanguard_media_engine.export.AndroidAudioFoundationSmokeHarness
import com.connects.vanguard_media_engine.export.AndroidPassthroughRemuxCapabilityProbe
import com.connects.vanguard_media_engine.export.AndroidPassthroughRemuxSampleIntegritySmokeHarness
import com.connects.vanguard_media_engine.export.AndroidPassthroughRemuxSmokeHarness
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import com.connects.vanguard_media_engine.thermal.AndroidThermalStateBridge
import io.flutter.plugin.common.MethodChannel

/**
 * Diagnostic MethodChannel coordinator for the Android True-DAG smoke routes.
 *
 * Owns the diagnostic-only smoke methods previously routed inline by
 * VanguardMediaEnginePlugin (Phase 2O2B3/2O2B4/2Q/3C/4A/5) plus the
 * Export/Audio Unit B audio foundation smoke and the Phase 3-Unit A Camera2
 * capability probe. Every route runs on a background Thread and posts exactly
 * one result.success/result.error to [mainHandler].
 *
 * Diagnostic only: no production export, playback, or UI wiring lives here.
 */
class AndroidDagDiagnosticsCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
    private val thermalBridge: AndroidThermalStateBridge,
) {
    companion object {
        private val OWNED_METHODS = setOf(
            "runAndroidDagPhase2O2B3PhysicalSmoke",
            "runAndroidDagPhase2O2B4MultiFrameSmoke",
            "runAndroidDagPhase2QCapabilityProbe",
            "runAndroidDagPhase1GpuBlacklistNativeSmoke",
            "runAndroidDagPhase1DagMultinodeExecutionPlanSmoke",
            "runAndroidDagPhase1HardwareBufferSourceNodeSmoke",
            "runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke",
            "runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke",
            "runAndroidDagPhase6StreamSourceNodeSmoke",
            "runAndroidDagPhase3CameraFrameSourceNodeSmoke",
            "runAndroidDagPhase1DagMultinodeTopologyCompositionSmoke",
            "runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke",
            "runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke",
            "runAndroidDagPhase3CEvalRenderSmoke",
            "runAndroidDagPhase4ADecoderSmoke",
            "runAndroidDagPhase5EncoderSurfaceSmoke",
            "runAndroidDagAudioFoundationSmoke",
            "runAndroidAudioDirectCopyFallbackSmoke",
            "runAndroidPassthroughRemuxNativeSmoke",
            "runAndroidPassthroughRemuxSampleIntegritySmoke",
            "runAndroidPassthroughRemuxCapabilityProbeSmoke",
            "runAndroidDagPhase3UnitACameraCapabilityProbe",
            "runAndroidDagPhase3UnitFConcurrentSessionValidation",
            "runAndroidDagPhase3UnitHCameraOpenCloseSmoke",
            "runAndroidDagPhase3UnitIImageReaderFrameSmoke",
            "runAndroidDagPhase3UnitJHardwareBufferFrameSmoke",
            "runAndroidDagPhase3UnitKCameraNativeRenderSmoke",
            "runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke",
            "runAndroidDagPhase1UGlesBackendSmoke",
            "runAndroidDagPhase1VGlesSurfaceSmoke",
            "runAndroidDagPhase1WGlesWindowPresentSmoke",
            "runAndroidDagPhase1XGlesShaderQuadSmoke",
            "runAndroidDagPhase1YGlesImportSmoke",
            "runAndroidDagPhase1ZGlesRenderFrameSmoke",
            "runAndroidDagPhase1ABGlesReadPixelsSmoke",
            "runAndroidDagPhase1ACGlesRenderFrameContentSmoke",
            "runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke",
            "runAndroidDagPhase1AEGlesAcquireFenceSmoke",
            "runAndroidDagPhase1AFGlesRgbxRenderFrameContentSmoke",
            "runAndroidDagPhase1AGGlesImportGuardSmoke",
            "runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke",
            "runAndroidDagPhase1AIGlesExtensionCapabilitySmoke",
            "runAndroidDagPhase1AJGlesNativeFenceFdSmoke",
            "runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke",
            "runAndroidDagPhase1ALGlesReleaseNullFenceSmoke",
            "runAndroidDagPhase1AMGlesRenderFenceChainSmoke",
            "runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke",
            "runAndroidDagPhase1ARGlesExternalTextureSmoke",
            "runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke",
            "runAndroidDagPhase1ATGlesMixedTextureCompositorSmoke",
            "runAndroidDagPhase1AVGlesEvalRenderSmoke",
            "runAndroidDagPhase3UnitTThermalListenerSmoke",
            "runAndroidDagPhase3ThermalFpsActionSmoke",
            "runAndroidDagPhase3ThermalResolutionReconfigureSmoke",
            "runAndroidVulkanExportNativeSeamSmoke",
            "runAndroidVulkanExportProductionWiringSmoke",
            "runAndroidGlesExportFitGeometrySmoke",
            "runAndroidTimelineColorMatrixExportSmoke",
            "runAndroidStillImageColorMatrixExportSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "runAndroidDagPhase2O2B3PhysicalSmoke" -> runPhase2O2B3PhysicalSmoke(args, result)
            "runAndroidDagPhase2O2B4MultiFrameSmoke" -> runPhase2O2B4MultiFrameSmoke(args, result)
            "runAndroidDagPhase2QCapabilityProbe" -> runPhase2QCapabilityProbe(result)
            "runAndroidDagPhase1GpuBlacklistNativeSmoke" -> runPhase1GpuBlacklistNativeSmoke(result)
            "runAndroidDagPhase1DagMultinodeExecutionPlanSmoke" -> runPhase1DagMultinodeExecutionPlanSmoke(result)
            "runAndroidDagPhase1HardwareBufferSourceNodeSmoke" -> runPhase1HardwareBufferSourceNodeSmoke(result)
            "runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke" ->
                runPhase2DecodedMediaFrameSourceNodeSmoke(result)
            "runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke" -> runPhase1PreviewSurfaceSinkNodeSmoke(result)
            "runAndroidDagPhase6StreamSourceNodeSmoke" -> runPhase6StreamSourceNodeSmoke(result)
            "runAndroidDagPhase3CameraFrameSourceNodeSmoke" -> runPhase3CameraFrameSourceNodeSmoke(result)
            "runAndroidDagPhase1DagMultinodeTopologyCompositionSmoke" ->
                runPhase1DagMultinodeTopologyCompositionSmoke(result)
            "runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke" ->
                runPhase1DagMultinodeGpuFrameTokenSmoke(result)
            "runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke" ->
                runPhase1DagMultinodeExecutionDispatcherSmoke(result)
            "runAndroidDagPhase3CEvalRenderSmoke" -> runPhase3CEvalRenderSmoke(args, result)
            "runAndroidDagPhase4ADecoderSmoke" -> runPhase4ADecoderSmoke(args, result)
            "runAndroidDagPhase5EncoderSurfaceSmoke" -> runPhase5EncoderSurfaceSmoke(args, result)
            "runAndroidDagAudioFoundationSmoke" -> runAudioFoundationSmoke(args, result)
            "runAndroidAudioDirectCopyFallbackSmoke" -> runAudioDirectCopyFallbackSmoke(args, result)
            "runAndroidPassthroughRemuxNativeSmoke" -> runPassthroughRemuxNativeSmoke(args, result)
            "runAndroidPassthroughRemuxSampleIntegritySmoke" ->
                runPassthroughRemuxSampleIntegritySmoke(args, result)
            "runAndroidPassthroughRemuxCapabilityProbeSmoke" ->
                runPassthroughRemuxCapabilityProbeSmoke(args, result)
            "runAndroidDagPhase3UnitACameraCapabilityProbe" -> runPhase3UnitACameraCapabilityProbe(result)
            "runAndroidDagPhase3UnitFConcurrentSessionValidation" ->
                runPhase3UnitFConcurrentSessionValidation(args, result)
            "runAndroidDagPhase3UnitHCameraOpenCloseSmoke" ->
                runPhase3UnitHCameraOpenCloseSmoke(args, result)
            "runAndroidDagPhase3UnitIImageReaderFrameSmoke" ->
                runPhase3UnitIImageReaderFrameSmoke(args, result)
            "runAndroidDagPhase3UnitJHardwareBufferFrameSmoke" ->
                runPhase3UnitJHardwareBufferFrameSmoke(args, result)
            "runAndroidDagPhase3UnitKCameraNativeRenderSmoke" ->
                runPhase3UnitKCameraNativeRenderSmoke(args, result)
            "runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke" ->
                runPhase3UnitLCameraNativeRenderLoopSmoke(args, result)
            "runAndroidDagPhase1UGlesBackendSmoke" -> runPhase1UGlesBackendSmoke(result)
            "runAndroidDagPhase1VGlesSurfaceSmoke" -> runPhase1VGlesSurfaceSmoke(args, result)
            "runAndroidDagPhase1WGlesWindowPresentSmoke" -> runPhase1WGlesWindowPresentSmoke(args, result)
            "runAndroidDagPhase1XGlesShaderQuadSmoke" -> runPhase1XGlesShaderQuadSmoke(args, result)
            "runAndroidDagPhase1YGlesImportSmoke" -> runPhase1YGlesImportSmoke(args, result)
            "runAndroidDagPhase1ZGlesRenderFrameSmoke" -> runPhase1ZGlesRenderFrameSmoke(args, result)
            "runAndroidDagPhase1ABGlesReadPixelsSmoke" -> runPhase1ABGlesReadPixelsSmoke(args, result)
            "runAndroidDagPhase1ACGlesRenderFrameContentSmoke" -> runPhase1ACGlesRenderFrameContentSmoke(args, result)
            "runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke" -> runPhase1ADGlesRenderFrameTransformMappingSmoke(args, result)
            "runAndroidDagPhase1AEGlesAcquireFenceSmoke" -> runPhase1AEGlesAcquireFenceSmoke(args, result)
            "runAndroidDagPhase1AFGlesRgbxRenderFrameContentSmoke" -> runPhase1AFGlesRgbxRenderFrameContentSmoke(args, result)
            "runAndroidDagPhase1AGGlesImportGuardSmoke" -> runPhase1AGGlesImportGuardSmoke(args, result)
            "runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke" -> runPhase1AHGlesYcbcrImportGuardSmoke(args, result)
            "runAndroidDagPhase1AIGlesExtensionCapabilitySmoke" -> runPhase1AIGlesExtensionCapabilitySmoke(result)
            "runAndroidDagPhase1AJGlesNativeFenceFdSmoke" -> runPhase1AJGlesNativeFenceFdSmoke(result)
            "runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke" -> runPhase1AKGlesReleaseFenceProductionSmoke(args, result)
            "runAndroidDagPhase1ALGlesReleaseNullFenceSmoke" -> runPhase1ALGlesReleaseNullFenceSmoke(args, result)
            "runAndroidDagPhase1AMGlesRenderFenceChainSmoke" -> runPhase1AMGlesRenderFenceChainSmoke(args, result)
            "runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke" -> runPhase1ANGlesAcquireFenceRenderContentSmoke(args, result)
            "runAndroidDagPhase1ARGlesExternalTextureSmoke" -> runPhase1ARGlesExternalTextureSmoke(args, result)
            "runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke" -> runPhase1ASGlesTwoTextureCompositorSmoke(args, result)
            "runAndroidDagPhase1ATGlesMixedTextureCompositorSmoke" -> runPhase1ATGlesMixedTextureCompositorSmoke(args, result)
            "runAndroidDagPhase1AVGlesEvalRenderSmoke" -> runPhase1AVGlesEvalRenderSmoke(args, result)
            "runAndroidDagPhase3UnitTThermalListenerSmoke" -> runPhase3UnitTThermalListenerSmoke(result)
            "runAndroidDagPhase3ThermalFpsActionSmoke" -> runPhase3ThermalFpsActionSmoke(args, result)
            "runAndroidDagPhase3ThermalResolutionReconfigureSmoke" ->
                runPhase3ThermalResolutionReconfigureSmoke(args, result)
            "runAndroidVulkanExportNativeSeamSmoke" -> runAndroidVulkanExportNativeSeamSmoke(args, result)
            "runAndroidVulkanExportProductionWiringSmoke" -> runAndroidVulkanExportProductionWiringSmoke(args, result)
            "runAndroidGlesExportFitGeometrySmoke" -> runAndroidGlesExportFitGeometrySmoke(args, result)
            "runAndroidTimelineColorMatrixExportSmoke" -> runAndroidTimelineColorMatrixExportSmoke(args, result)
            "runAndroidStillImageColorMatrixExportSmoke" -> runAndroidStillImageColorMatrixExportSmoke(args, result)
            else -> return false
        }
        return true
    }

    private fun runPhase2O2B3PhysicalSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.run(width, height)
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase2O2B4MultiFrameSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 30
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runMultiFrame(width, height, frameCount)
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase2QCapabilityProbe(result: MethodChannel.Result) {
        Thread {
            val probeResult = AndroidDagRenderSmokeHarness.runCapabilityProbe()
            mainHandler.post { result.success(probeResult) }
        }.start()
    }

    // ── P1-GPU-BLACKLIST-NATIVE-RULE-PROOF: native GPU driver blacklist rule
    // evaluator diagnostic. Runs synthetic native lanes only; does not read
    // or mutate the production (zero-entry) rule table. Proof boundary:
    // diagnostic native evaluator and probe-route semantics only — no fleet
    // data, no product/app/editor wiring, no Vulkan/GLES lifecycle changes.
    private fun runPhase1GpuBlacklistNativeSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase1GpuBlacklistNativeSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "diagnostic_native_gpu_driver_blacklist_rule_evaluator_and_probe_route_semantics_only",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GPU_BLACKLIST_NATIVE_SMOKE_FAILED",
                        "runAndroidDagPhase1GpuBlacklistNativeSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P1-DAG-MULTINODE-CORE-EXEC-PLAN: bounded engine-only
    // GraphExecutionPlanner diagnostic. Runs synthetic native lanes only,
    // driving vanguard::graph::BuildGraphExecutionPlan() over TU-local
    // synthetic DAGs, including no-active-sink fail-closed and unchanged
    // Graph cycle rejection. Proof boundary: diagnostic-only engine
    // execution plan - no production timeline playback, no product/editor/
    // app/ConnectsApp wiring, no SurfaceProducer production path.
    private fun runPhase1DagMultinodeExecutionPlanSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase1DagMultinodeExecutionPlanSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "diagnostic_only_engine_execution_plan_no_production_timeline_playback_" +
                        "no_product_editor_app_connectsapp_wiring_no_surfaceproducer_production_path",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "DAG_MULTINODE_EXECUTION_PLAN_SMOKE_FAILED",
                        "runAndroidDagPhase1DagMultinodeExecutionPlanSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P1-DAG-MULTINODE-HARDWARE-BUFFER-SOURCE-NODE: platform-neutral
    // logical DAG HardwareBufferSourceNode diagnostic. Runs synthetic native
    // lanes only (construction validation, identity/port shape, timeline-
    // window semantics, real GraphExecutionPlan source->sink pass). Proof
    // boundary: platform-neutral logical DAG source - no AHardwareBuffer
    // ownership, no Android lifecycle, no product/app/editor wiring.
    private fun runPhase1HardwareBufferSourceNodeSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase1HardwareBufferSourceNodeSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "platform_neutral_hardware_buffer_source_node_logical_dag_source_no_ahardwarebuffer_" +
                        "ownership_no_android_lifecycle_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "HARDWARE_BUFFER_SOURCE_NODE_SMOKE_FAILED",
                        "runAndroidDagPhase1HardwareBufferSourceNodeSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P2-DECODED-MEDIA-FRAME-SOURCE-NODE-A: platform-neutral
    // logical DAG DecodedMediaFrameSourceNode diagnostic. Runs native lanes over
    // the real DecodedMediaFrameSourceNode plus a TU-local sink (construction
    // validation, identity/port shape, dimension accessors, timeline-window
    // semantics, real GraphExecutionPlan source->sink pass).
    // Proof boundary: platform-neutral logical DAG source - no decoder/framebuffer
    // ownership, no Android lifecycle, no product/app/editor wiring.
    private fun runPhase2DecodedMediaFrameSourceNodeSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "platform_neutral_decoded_media_frame_source_node_logical_dag_source_no_decoder_framebuffer_" +
                        "ownership_no_android_lifecycle_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "DECODED_MEDIA_FRAME_SOURCE_NODE_SMOKE_FAILED",
                        "runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE: platform-neutral
    // logical DAG PreviewSurfaceSinkNode diagnostic. Runs synthetic native
    // lanes only (construction validation, identity/port shape, default
    // timeline semantics, real GraphExecutionPlan source->sink pass against
    // the real HardwareBufferSourceNode, missing-input fail-closed, stale-
    // generation rejection). Proof boundary: platform-neutral logical DAG
    // sink - no Surface ownership, no Android lifecycle, no product/app/
    // editor wiring.
    private fun runPhase1PreviewSurfaceSinkNodeSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "platform_neutral_preview_surface_sink_node_logical_dag_sink_no_surface_" +
                        "ownership_no_android_lifecycle_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "PREVIEW_SURFACE_SINK_NODE_SMOKE_FAILED",
                        "runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P6-STREAM-SOURCE-NODE-A: platform-neutral logical DAG
    // StreamSourceNode diagnostic. Runs native lanes over the real
    // StreamSourceNode plus the real PreviewSurfaceSinkNode (construction
    // validation, identity/port shape, streamId/live accessors, dimension
    // accessors, timeline-window semantics, real GraphExecutionPlan
    // source->sink pass). Proof boundary: platform-neutral logical DAG
    // source - no network SDK, no decoder/framebuffer ownership, no Android
    // lifecycle, no product/app/editor wiring.
    private fun runPhase6StreamSourceNodeSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase6StreamSourceNodeSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "platform_neutral_stream_source_node_logical_dag_source_no_network_sdk_no_decoder_" +
                        "framebuffer_ownership_no_android_lifecycle_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "STREAM_SOURCE_NODE_SMOKE_FAILED",
                        "runAndroidDagPhase6StreamSourceNodeSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P3-CAMERA-FRAME-SOURCE-NODE-A: platform-neutral logical DAG
    // CameraFrameSourceNode diagnostic. Runs native lanes over the real
    // CameraFrameSourceNode plus the real PreviewSurfaceSinkNode
    // (construction validation, identity/port shape, cameraId/orientation/
    // mirror/live accessors, dimension accessors, timeline-window
    // semantics, real GraphExecutionPlan source->sink pass). Proof
    // boundary: platform-neutral logical DAG source - no camera hardware
    // ownership, no Android lifecycle, no product/app/editor wiring.
    private fun runPhase3CameraFrameSourceNodeSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase3CameraFrameSourceNodeSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "platform_neutral_camera_frame_source_node_logical_dag_source_no_camera_hardware_" +
                        "ownership_no_android_lifecycle_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_FRAME_SOURCE_NODE_SMOKE_FAILED",
                        "runAndroidDagPhase3CameraFrameSourceNodeSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P1-DAG-MULTINODE-TOPOLOGY-COMPOSITION: real multi-node DAG topology
    // diagnostic. Runs synthetic native lanes only, driving
    // vanguard::graph::BuildGraphExecutionPlan() over a real four-node
    // topology built from concrete platform-neutral node classes (two
    // HardwareBufferSourceNode instances -> MultiCamCompositorNode ->
    // PreviewSurfaceSinkNode, no TU-local Node subclasses). Proof boundary:
    // real-node multinode topology composition - diagnostic-only, no
    // rendering, no GPU transport, no product/app/editor wiring.
    private fun runPhase1DagMultinodeTopologyCompositionSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase1DagMultinodeTopologyCompositionSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "real_node_multinode_topology_composition_diagnostic_only_no_render_no_gpu_" +
                        "transport_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "DAG_MULTINODE_TOPOLOGY_COMPOSITION_SMOKE_FAILED",
                        "runAndroidDagPhase1DagMultinodeTopologyCompositionSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P1-DAG-MULTINODE-GPU-FRAME-TOKEN-CONTRACT: platform-neutral,
    // non-owning GPU frame token identity/binding contract diagnostic. Runs
    // synthetic native lanes only, driving
    // vanguard::graph::GpuFrameTokenSession publish/resolve over
    // vanguard::graph::BuildGraphExecutionPlan()'s ExecutionInputBinding
    // values across the same real four-node topology used by the topology
    // composition route above (two HardwareBufferSourceNode instances ->
    // MultiCamCompositorNode -> PreviewSurfaceSinkNode, no TU-local Node
    // subclasses). Proof boundary: platform-neutral GPU frame token binding
    // contract - diagnostic-only, no OS/GPU resource ownership, no
    // rendering, no GPU transport, no product/app/editor wiring.
    private fun runPhase1DagMultinodeGpuFrameTokenSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "platform_neutral_gpu_frame_token_binding_contract_diagnostic_only_no_os_" +
                        "resource_ownership_no_render_no_gpu_transport_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "DAG_MULTINODE_GPU_FRAME_TOKEN_SMOKE_FAILED",
                        "runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P1-DAG-MULTINODE-EXECUTION-DISPATCHER: bounded platform-neutral
    // graph-layer execution dispatcher diagnostic. Runs synthetic native
    // lanes only, driving vanguard::graph::GraphExecutionDispatcher over the
    // same real four-node topology used by the routes above (two
    // HardwareBufferSourceNode instances -> MultiCamCompositorNode ->
    // PreviewSurfaceSinkNode, no TU-local Node subclasses except in the one
    // lane that needs a mixed GPU/non-GPU input-binding shape). Proof
    // boundary: platform-neutral DAG execution dispatcher - diagnostic-only,
    // no Node::execute, no OS/GPU resource ownership, no rendering, no GPU
    // transport, no product/app/editor wiring.
    private fun runPhase1DagMultinodeExecutionDispatcherSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                val raw = nativeBridge.runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke()
                val pass = raw.startsWith("status=PASS;")
                val smokeResult = mapOf<String, Any?>(
                    "pass" to pass,
                    "raw" to raw,
                    "proofBoundary" to
                        "platform_neutral_dag_execution_dispatcher_diagnostic_only_no_node_execute_no_os_" +
                        "resource_ownership_no_render_no_gpu_transport_no_product_app_editor_wiring",
                    "totalLanes" to parseIntField(raw, "totalLanes="),
                    "passedLanes" to parseIntField(raw, "passedLanes="),
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "DAG_MULTINODE_EXECUTION_DISPATCHER_SMOKE_FAILED",
                        "runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun parseIntField(raw: String, key: String): Int {
        val idx = raw.indexOf(key)
        if (idx < 0) return 0
        val start = idx + key.length
        val end = raw.indexOf(';', start).let { if (it < 0) raw.length else it }
        return raw.substring(start, end).toIntOrNull() ?: 0
    }

    private fun runPhase3CEvalRenderSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width           = (args?.get("width")           as? Number)?.toInt()  ?: 64
        val height          = (args?.get("height")          as? Number)?.toInt()  ?: 64
        val frameCount      = (args?.get("frameCount")      as? Number)?.toInt()  ?: 30
        val frameDurationUs = (args?.get("frameDurationUs") as? Number)?.toLong() ?: 33333L
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runDagEvaluationSmoke(
                width, height, frameCount, frameDurationUs,
            )
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase4ADecoderSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val path       = args?.get("path")       as? String
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 10
        if (path == null) {
            result.error("INVALID_ARG", "runAndroidDagPhase4ADecoderSmoke: path required", null)
            return
        }
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runDecoderSmoke(
                videoPath  = path,
                frameCount = frameCount,
            )
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase5EncoderSurfaceSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val outputPath = args?.get("outputPath") as? String
        if (outputPath.isNullOrBlank()) {
            result.error("INVALID_ARG", "runAndroidDagPhase5EncoderSurfaceSmoke: outputPath required", null)
            return
        }
        val width           = (args["width"]           as? Number)?.toInt()  ?: 64
        val height          = (args["height"]          as? Number)?.toInt()  ?: 64
        val frameCount      = (args["frameCount"]      as? Number)?.toInt()  ?: 10
        val frameDurationUs = (args["frameDurationUs"] as? Number)?.toLong() ?: 33333L
        val bitrate         = (args["bitrate"]         as? Number)?.toInt()  ?: 1_000_000
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runEncoderSurfaceSmoke(
                width           = width,
                height          = height,
                frameCount      = frameCount,
                frameDurationUs = frameDurationUs,
                bitrate         = bitrate,
                outputPath      = outputPath,
            )
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runAndroidVulkanExportNativeSeamSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val outputPath = args?.get("outputPath") as? String
        if (outputPath.isNullOrBlank()) {
            result.error("INVALID_ARG", "runAndroidVulkanExportNativeSeamSmoke: outputPath required", null)
            return
        }
        val width           = (args["width"]           as? Number)?.toInt()  ?: 64
        val height          = (args["height"]          as? Number)?.toInt()  ?: 64
        val frameCount      = (args["frameCount"]      as? Number)?.toInt()  ?: 10
        val frameDurationUs = (args["frameDurationUs"] as? Number)?.toLong() ?: 33333L
        val bitrate         = (args["bitrate"]         as? Number)?.toInt()  ?: 1_000_000
        Thread {
            try {
                val smokeResult = AndroidVulkanExportNativeSeamSmokeHarness.runSmoke(
                    width           = width,
                    height          = height,
                    frameCount      = frameCount,
                    frameDurationUs = frameDurationUs,
                    bitrate         = bitrate,
                    outputPath      = outputPath,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "VULKAN_EXPORT_NATIVE_SEAM_SMOKE_FAILED",
                        "runAndroidVulkanExportNativeSeamSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Export/Audio Unit B: two-pass audio foundation smoke ─────────────────
    private fun runAudioFoundationSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val videoPath = args?.get("videoPath") as? String
        val audioPath = args?.get("audioPath") as? String
        val outputDir = args?.get("outputDir") as? String
        if (videoPath.isNullOrBlank() || audioPath.isNullOrBlank() || outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidDagAudioFoundationSmoke: videoPath, audioPath, and outputDir required",
                null,
            )
            return
        }
        Thread {
            // The harness catches its own failures and returns a fail map; this
            // guard guarantees exactly one MethodChannel result regardless.
            try {
                val smokeResult = AndroidAudioFoundationSmokeHarness.run(
                    videoPath = videoPath,
                    audioPath = audioPath,
                    outputDir = outputDir,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "AUDIO_FOUNDATION_SMOKE_FAILED",
                        "runAndroidDagAudioFoundationSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Android True-DAG Pass-2 Audio Direct-Copy Failure Fallback smoke ─────
    private fun runAudioDirectCopyFallbackSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val sourcePath = args?.get("sourcePath") as? String
        val outputDir = args?.get("outputDir") as? String
        if (sourcePath.isNullOrBlank() || outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidAudioDirectCopyFallbackSmoke: sourcePath and outputDir required",
                null,
            )
            return
        }
        Thread {
            try {
                val smokeResult = AndroidAudioDirectCopyFallbackSmokeHarness.run(
                    sourcePath = sourcePath,
                    outputDir = outputDir,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "AUDIO_DIRECT_COPY_FALLBACK_SMOKE_FAILED",
                        "runAndroidAudioDirectCopyFallbackSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 2-Unit X: Android native passthrough remux diagnostic smoke ────
    private fun runPassthroughRemuxNativeSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val sourcePath = args?.get("sourcePath") as? String
        val outputDir = args?.get("outputDir") as? String
        if (sourcePath.isNullOrBlank() || outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidPassthroughRemuxNativeSmoke: sourcePath and outputDir required",
                null,
            )
            return
        }
        Thread {
            try {
                val smokeResult = AndroidPassthroughRemuxSmokeHarness.run(
                    sourcePath = sourcePath,
                    outputDir = outputDir,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "PASSTHROUGH_REMUX_NATIVE_SMOKE_FAILED",
                        "runAndroidPassthroughRemuxNativeSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 2-Unit Y: Android passthrough remux sample-integrity smoke ─────
    private fun runPassthroughRemuxSampleIntegritySmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val sourcePath = args?.get("sourcePath") as? String
        val outputDir = args?.get("outputDir") as? String
        val secondSourcePath = args?.get("secondSourcePath") as? String
        if (sourcePath.isNullOrBlank() || outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidPassthroughRemuxSampleIntegritySmoke: sourcePath and outputDir required",
                null,
            )
            return
        }
        Thread {
            try {
                val smokeResult = AndroidPassthroughRemuxSampleIntegritySmokeHarness.run(
                    sourcePath = sourcePath,
                    secondSourcePath = secondSourcePath,
                    outputDir = outputDir,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_SMOKE_FAILED",
                        "runAndroidPassthroughRemuxSampleIntegritySmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 2-Unit Z: Android native passthrough remux capability probe smoke ──
    private fun runPassthroughRemuxCapabilityProbeSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        val sourcePath = args?.get("sourcePath") as? String
        if (sourcePath.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidPassthroughRemuxCapabilityProbeSmoke: sourcePath required",
                null,
            )
            return
        }
        Thread {
            try {
                val probeResult = AndroidPassthroughRemuxCapabilityProbe.probe(sourcePath)
                mainHandler.post { result.success(probeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "PASSTHROUGH_REMUX_CAPABILITY_PROBE_FAILED",
                        "runAndroidPassthroughRemuxCapabilityProbeSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit A: Android Camera2 capability probe ─────────────────────
    private fun runPhase3UnitACameraCapabilityProbe(result: MethodChannel.Result) {
        Thread {
            try {
                val probeResult = AndroidCamera2CapabilityProbe(context).probe()
                mainHandler.post { result.success(probeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_CAPABILITY_PROBE_FAILED",
                        "runAndroidDagPhase3UnitACameraCapabilityProbe: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit F: Android Camera2 guarded concurrent SessionConfiguration validation ──
    private fun runPhase3UnitFConcurrentSessionValidation(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val validationResult = AndroidCamera2ConcurrentSessionValidator(context).validate(args)
                mainHandler.post { result.success(validationResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CONCURRENT_SESSION_VALIDATION_FAILED",
                        "runAndroidDagPhase3UnitFConcurrentSessionValidation: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit H: Android Camera2 single-camera open/close lifecycle smoke ──
    private fun runPhase3UnitHCameraOpenCloseSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2OpenCloseSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_OPEN_CLOSE_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitHCameraOpenCloseSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit I: Android Camera2 single-camera ImageReader frame smoke ──
    private fun runPhase3UnitIImageReaderFrameSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2ImageReaderFrameSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_IMAGE_READER_FRAME_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitIImageReaderFrameSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit J: Android Camera2 single-camera PRIVATE ImageReader HardwareBuffer frame smoke ──
    private fun runPhase3UnitJHardwareBufferFrameSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2HardwareBufferFrameSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_HARDWARE_BUFFER_FRAME_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitJHardwareBufferFrameSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit K: Android Camera2 PRIVATE ImageReader HardwareBuffer native-render frame smoke ──
    private fun runPhase3UnitKCameraNativeRenderSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2NativeRenderFrameSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_NATIVE_RENDER_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitKCameraNativeRenderSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit L: Android Camera2 PRIVATE ImageReader HardwareBuffer native-render multi-frame render loop smoke ──
    private fun runPhase3UnitLCameraNativeRenderLoopSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2NativeRenderLoopSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_NATIVE_RENDER_LOOP_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit U: Android GLES backend offscreen EGL lifecycle smoke ──
    private fun runPhase1UGlesBackendSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesBackendSmoke()
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_BACKEND_SMOKE_FAILED",
                        "runAndroidDagPhase1UGlesBackendSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit V: Android GLES backend window-surface attach/detach smoke ──
    private fun runPhase1VGlesSurfaceSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesSurfaceSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_SURFACE_SMOKE_FAILED",
                        "runAndroidDagPhase1VGlesSurfaceSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit W: Android GLES backend window-surface clear/swap presentation diagnostic ──
    private fun runPhase1WGlesWindowPresentSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesWindowPresentSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_WINDOW_PRESENT_SMOKE_FAILED",
                        "runAndroidDagPhase1WGlesWindowPresentSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit X: Android GLES backend window-surface shader-quad draw/swap presentation diagnostic ──
    private fun runPhase1XGlesShaderQuadSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesShaderQuadSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_SHADER_QUAD_SMOKE_FAILED",
                        "runAndroidDagPhase1XGlesShaderQuadSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit Y: Android GLES backend AHardwareBuffer RGBA import foundation smoke ──
    private fun runPhase1YGlesImportSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesImportSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_IMPORT_SMOKE_FAILED",
                        "runAndroidDagPhase1YGlesImportSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit Z: Android GLES backend identity renderFrame textured-quad presentation smoke ──
    private fun runPhase1ZGlesRenderFrameSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesRenderFrameSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RENDER_FRAME_SMOKE_FAILED",
                        "runAndroidDagPhase1ZGlesRenderFrameSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AB: Android GLES backend diagnostic read-pixels physical smoke ──
    private fun runPhase1ABGlesReadPixelsSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesReadPixelsSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_READ_PIXELS_SMOKE_FAILED",
                        "runAndroidDagPhase1ABGlesReadPixelsSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AC: Android GLES renderFrame texture-content readback physical smoke ──
    private fun runPhase1ACGlesRenderFrameContentSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesRenderFrameContentSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RENDER_FRAME_CONTENT_SMOKE_FAILED",
                        "runAndroidDagPhase1ACGlesRenderFrameContentSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AD: Android GLES renderFrame asymmetric UV mapping physical smoke ──
    private fun runPhase1ADGlesRenderFrameTransformMappingSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesRenderFrameTransformMappingSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RENDER_FRAME_TRANSFORM_MAPPING_SMOKE_FAILED",
                        "runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AE: Android GLES backend AHardwareBuffer acquire-fence wait/close foundation smoke ──
    private fun runPhase1AEGlesAcquireFenceSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesAcquireFenceSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_ACQUIRE_FENCE_SMOKE_FAILED",
                        "runAndroidDagPhase1AEGlesAcquireFenceSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AF: Android GLES RGBX AHardwareBuffer renderFrame content readback physical smoke ──
    private fun runPhase1AFGlesRgbxRenderFrameContentSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesRgbxRenderFrameContentSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RGBX_RENDER_FRAME_CONTENT_SMOKE_FAILED",
                        "runAndroidDagPhase1AFGlesRgbxRenderFrameContentSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AG: Android GLES AHardwareBuffer import guard fail-closed physical smoke ──
    private fun runPhase1AGGlesImportGuardSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesImportGuardSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_IMPORT_GUARD_SMOKE_FAILED",
                        "runAndroidDagPhase1AGGlesImportGuardSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AH: Android GLES YCBCR_420_888 AHardwareBuffer import guard physical smoke (superseded by Unit AR) ──
    private fun runPhase1AHGlesYcbcrImportGuardSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesExternalTextureSmokeHarness.runGlesExternalTextureSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_YCBCR_IMPORT_GUARD_SMOKE_FAILED",
                        "runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AI: Android GLES/EGL extension and native-fence capability inventory physical proof ──
    private fun runPhase1AIGlesExtensionCapabilitySmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val smokeResult = AndroidGlesCapabilitySmokeHarness.runGlesExtensionCapabilitySmoke()
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_EXTENSION_CAPABILITY_SMOKE_FAILED",
                        "runAndroidDagPhase1AIGlesExtensionCapabilitySmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AJ: Android GLES EGL native-fence FD lifecycle physical proof ──
    private fun runPhase1AJGlesNativeFenceFdSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val smokeResult = AndroidGlesFenceSmokeHarness.runGlesNativeFenceFdSmoke()
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_NATIVE_FENCE_FD_SMOKE_FAILED",
                        "runAndroidDagPhase1AJGlesNativeFenceFdSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AK: Android GLES releaseHardwareBuffer live release-fence output physical proof ──
    private fun runPhase1AKGlesReleaseFenceProductionSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesReleaseFenceProductionSmokeHarness.runGlesReleaseFenceProductionSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RELEASE_FENCE_PRODUCTION_SMOKE_FAILED",
                        "runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AL: Android GLES releaseHardwareBuffer nullptr release-fence output physical proof ──
    private fun runPhase1ALGlesReleaseNullFenceSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesFenceSmokeHarness.runGlesReleaseNullFenceSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RELEASE_NULL_FENCE_SMOKE_FAILED",
                        "runAndroidDagPhase1ALGlesReleaseNullFenceSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AM: Android GLES renderFrame -> EGL native-fence GPU chain physical proof ──
    private fun runPhase1AMGlesRenderFenceChainSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesFenceSmokeHarness.runGlesRenderFenceChainSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RENDER_FENCE_CHAIN_SMOKE_FAILED",
                        "runAndroidDagPhase1AMGlesRenderFenceChainSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AN: Android GLES acquire-fence import -> renderFrame content physical proof ──
    private fun runPhase1ANGlesAcquireFenceRenderContentSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesFenceSmokeHarness.runGlesAcquireFenceRenderContentSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_ACQUIRE_FENCE_RENDER_CONTENT_SMOKE_FAILED",
                        "runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AR: Android GLES external texture YCBCR_420_888 AHardwareBuffer import foundation physical smoke ──
    private fun runPhase1ARGlesExternalTextureSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesExternalTextureSmokeHarness.runGlesExternalTextureSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_EXTERNAL_TEXTURE_SMOKE_FAILED",
                        "runAndroidDagPhase1ARGlesExternalTextureSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AS: Android GLES two-texture compositor RGBA blend foundation smoke ──
    private fun runPhase1ASGlesTwoTextureCompositorSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesTwoTextureCompositorSmokeHarness.runGlesTwoTextureCompositorSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_TWO_TEXTURE_COMPOSITOR_SMOKE_FAILED",
                        "runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AT: Android GLES mixed external/OES two-texture composition foundation physical proof ──
    private fun runPhase1ATGlesMixedTextureCompositorSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidGlesTwoTextureCompositorSmokeHarness.runGlesMixedTextureCompositorSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_MIXED_TEXTURE_COMPOSITOR_SMOKE_FAILED",
                        "runAndroidDagPhase1ATGlesMixedTextureCompositorSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AV: Android GLES DAG playhead evaluation + multi-frame render smoke ──
    private fun runPhase1AVGlesEvalRenderSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width           = (args?.get("width")           as? Number)?.toInt()  ?: 64
        val height          = (args?.get("height")          as? Number)?.toInt()  ?: 64
        val frameCount      = (args?.get("frameCount")      as? Number)?.toInt()  ?: 30
        val frameDurationUs = (args?.get("frameDurationUs") as? Number)?.toLong() ?: 33333L
        Thread {
            try {
                val smokeResult = AndroidGlesDagEvalSmokeHarness.runGlesDagEvalRenderSmoke(
                    width, height, frameCount, frameDurationUs,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_DAG_EVAL_RENDER_SMOKE_FAILED",
                        "runAndroidDagPhase1AVGlesEvalRenderSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit T: Android Camera2 dynamic thermal listener & fallback telemetry smoke ──
    private fun runPhase3UnitTThermalListenerSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val smokeResult = AndroidCamera2ThermalListenerSmokeHarness(thermalBridge).run()
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "THERMAL_LISTENER_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitTThermalListenerSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── P3-CAM-THERMAL-ACT-FPS-REQUEST-ACTION: Android Camera2 repeating-request AE FPS range mutation smoke ──
    private fun runPhase3ThermalFpsActionSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2ThermalFpsActionSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "THERMAL_FPS_ACTION_SMOKE_FAILED",
                        "runAndroidDagPhase3ThermalFpsActionSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // -- P3-CAM-THERMAL-ACT-RESOLUTION-RECONFIG-DIAGNOSTIC: Android Camera2 single-camera resolution session reconfigure smoke --
    private fun runPhase3ThermalResolutionReconfigureSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2ThermalResolutionReconfigureSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "THERMAL_RESOLUTION_RECONFIGURE_SMOKE_FAILED",
                        "runAndroidDagPhase3ThermalResolutionReconfigureSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Vulkan-first export production wiring smoke harness ─────────────────
    private fun runAndroidVulkanExportProductionWiringSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val sourcePath = args?.get("sourcePath") as? String
        val outputDir = args?.get("outputDir") as? String
        val useSyntheticSource = (args?.get("useSyntheticSource") as? Boolean) ?: sourcePath.isNullOrBlank()

        if (outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidVulkanExportProductionWiringSmoke: outputDir required",
                null,
            )
            return
        }

        if (!useSyntheticSource && sourcePath.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidVulkanExportProductionWiringSmoke: sourcePath required when useSyntheticSource is false",
                null,
            )
            return
        }

        val width = (args["width"] as? Number)?.toInt() ?: 1280
        val height = (args["height"] as? Number)?.toInt() ?: 720
        val outputWidth = (args["outputWidth"] as? Number)?.toInt() ?: width
        val outputHeight = (args["outputHeight"] as? Number)?.toInt() ?: height
        val fps = (args["fps"] as? Number)?.toInt() ?: 30
        val bitrateBps = (args["bitrateBps"] as? Number)?.toInt() ?: 4_000_000
        val trimEndSeconds = (args["trimEndSeconds"] as? Number)?.toDouble() ?: 1.0
        val sourceRotationDegrees = (args["sourceRotationDegrees"] as? Number)?.toInt() ?: 0
        val oracleMode = (args["oracleMode"] as? String) ?: "gles_pixel_parity"
        val scenarioMode = (args["scenarioMode"] as? String) ?: "single_clip"

        Thread {
            try {
                val smokeResult = AndroidVulkanExportProductionWiringSmokeHarness.run(
                    context = context,
                    sourcePath = sourcePath,
                    outputDir = outputDir,
                    useSyntheticSource = useSyntheticSource,
                    width = width,
                    height = height,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
                    fps = fps,
                    bitrateBps = bitrateBps,
                    trimEndSeconds = trimEndSeconds,
                    sourceRotationDegrees = sourceRotationDegrees,
                    oracleMode = oracleMode,
                    scenarioMode = scenarioMode,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "VULKAN_EXPORT_PRODUCTION_WIRING_SMOKE_FAILED",
                        "runAndroidVulkanExportProductionWiringSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── GLES fallback 90/270 fit geometry smoke harness ─────────────────────
    private fun runAndroidGlesExportFitGeometrySmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val outputDir = args?.get("outputDir") as? String
        if (outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidGlesExportFitGeometrySmoke: outputDir required",
                null,
            )
            return
        }
        val fps = (args["fps"] as? Number)?.toInt() ?: 30
        val bitrateBps = (args["bitrateBps"] as? Number)?.toInt() ?: 4_000_000

        Thread {
            try {
                val smokeResult = AndroidGlesExportFitGeometrySmokeHarness.run(
                    outputDir = outputDir,
                    fps = fps,
                    bitrateBps = bitrateBps,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_EXPORT_FIT_GEOMETRY_SMOKE_FAILED",
                        "runAndroidGlesExportFitGeometrySmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── GLES fallback colorMatrix export smoke harness ──────────────────────
    private fun runAndroidTimelineColorMatrixExportSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val outputDir = args?.get("outputDir") as? String
        if (outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidTimelineColorMatrixExportSmoke: outputDir required",
                null,
            )
            return
        }
        val width = (args["width"] as? Number)?.toInt() ?: 1280
        val height = (args["height"] as? Number)?.toInt() ?: 720
        val outputWidth = (args["outputWidth"] as? Number)?.toInt() ?: width
        val outputHeight = (args["outputHeight"] as? Number)?.toInt() ?: height
        val fps = (args["fps"] as? Number)?.toInt() ?: 30
        val bitrateBps = (args["bitrateBps"] as? Number)?.toInt() ?: 4_000_000
        val trimEndSeconds = (args["trimEndSeconds"] as? Number)?.toDouble() ?: 1.0

        Thread {
            try {
                val smokeResult = AndroidTimelineColorMatrixExportSmokeHarness.run(
                    context = context,
                    outputDir = outputDir,
                    width = width,
                    height = height,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
                    fps = fps,
                    bitrateBps = bitrateBps,
                    trimEndSeconds = trimEndSeconds,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "TIMELINE_COLOR_MATRIX_EXPORT_SMOKE_FAILED",
                        "runAndroidTimelineColorMatrixExportSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── GLES still-image colorMatrix export smoke harness ───────────────────
    private fun runAndroidStillImageColorMatrixExportSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val outputDir = args?.get("outputDir") as? String
        if (outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidStillImageColorMatrixExportSmoke: outputDir required",
                null,
            )
            return
        }
        val width = (args["width"] as? Number)?.toInt() ?: 1280
        val height = (args["height"] as? Number)?.toInt() ?: 720
        val fps = (args["fps"] as? Number)?.toInt() ?: 30
        val bitrateBps = (args["bitrateBps"] as? Number)?.toInt() ?: 4_000_000
        val durationSeconds = (args["durationSeconds"] as? Number)?.toDouble() ?: 1.0

        Thread {
            try {
                val smokeResult = AndroidStillImageColorMatrixExportSmokeHarness.run(
                    context = context,
                    outputDir = outputDir,
                    width = width,
                    height = height,
                    fps = fps,
                    bitrateBps = bitrateBps,
                    durationSeconds = durationSeconds,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "STILL_IMAGE_COLOR_MATRIX_EXPORT_SMOKE_FAILED",
                        "runAndroidStillImageColorMatrixExportSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }
}
