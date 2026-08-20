package com.connects.vanguard_media_engine.lifecycle

import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics

class VanguardLifecycleObserver(
    private val diagnostics: VanguardDiagnostics
) {
    fun onEngineStart() {
        diagnostics.logEvent("Engine started")
    }

    fun onEngineStop() {
        diagnostics.logEvent("Engine stopped")
    }
}
