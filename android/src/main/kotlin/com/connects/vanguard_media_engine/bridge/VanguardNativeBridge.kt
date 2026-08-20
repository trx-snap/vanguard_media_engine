package com.connects.vanguard_media_engine.bridge

import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.diagnostics.BackendCapabilityReport
import com.connects.vanguard_media_engine.codec.PlatformCodecAdapter

class VanguardNativeBridge(
    private val lifecycleObserver: VanguardLifecycleObserver,
    private val diagnostics: VanguardDiagnostics,
    private val codecAdapter: PlatformCodecAdapter?
) {
    
    init {
        // Assume library is loaded by the main plugin class
    }

    external fun probeCapabilities(): BackendCapabilityReport

    fun initialize() {
        val report = probeCapabilities()
        diagnostics.logCapabilities(report)
    }
}
