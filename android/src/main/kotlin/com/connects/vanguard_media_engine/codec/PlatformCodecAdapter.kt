package com.connects.vanguard_media_engine.codec

import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics

interface PlatformCodecAdapter {
    fun describeCapabilities(): CodecAdapterCapabilities
    fun close()
}

data class CodecAdapterCapabilities(
    val available: Boolean,
    val notes: List<String> = emptyList()
)
