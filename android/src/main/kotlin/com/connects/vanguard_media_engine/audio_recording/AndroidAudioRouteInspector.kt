package com.connects.vanguard_media_engine.audio_recording

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager

// ── AndroidAudioRouteInspector (Phase 4-Unit H / Phase 5-Unit AC) ────────────
//
// Captures a route snapshot for startAudioRecording, mirroring the Dart
// VGAudioRouteSnapshotResult contract (lib/vg_audio_recording_models.dart).
// Android has no AVAudioSession equivalent -- this queries AudioManager's
// currently-attached input/output devices instead.
//
// activeInputType is frozen to one of: builtInMic, headsetMic, bluetoothHfp,
// usbAudio, lineIn, other, none. activeInputUID is always "" -- Android does
// not expose a stable per-device UID the way AVAudioSessionPortDescription does.
object AndroidAudioRouteInspector {

    data class RouteSnapshot(
        val activeInputType: String,
        val activeInputName: String,
        val activeInputUID: String,
        val activeInputDataSourceName: String?,
        val availableInputTypes: List<String>,
        val activeOutputTypes: List<String>,
        val hasHeadphoneOutput: Boolean,
        val activeInputIsExternal: Boolean,
        val inputAvailable: Boolean,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "activeInputType" to activeInputType,
            "activeInputName" to activeInputName,
            "activeInputUID" to activeInputUID,
            "activeInputDataSourceName" to activeInputDataSourceName,
            "availableInputTypes" to availableInputTypes,
            "activeOutputTypes" to activeOutputTypes,
            "hasHeadphoneOutput" to hasHeadphoneOutput,
            "activeInputIsExternal" to activeInputIsExternal,
            "inputAvailable" to inputAvailable,
        )
    }

    private val NO_INPUT_SNAPSHOT = RouteSnapshot(
        activeInputType = "none",
        activeInputName = "",
        activeInputUID = "",
        activeInputDataSourceName = null,
        availableInputTypes = emptyList(),
        activeOutputTypes = emptyList(),
        hasHeadphoneOutput = false,
        activeInputIsExternal = false,
        inputAvailable = false,
    )

    // Preference order when more than one input is attached -- external/wired
    // sources win over the built-in mic, mirroring typical OS routing behavior.
    private val INPUT_PRIORITY = listOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_BUILTIN_MIC,
    )

    fun capture(context: Context): RouteSnapshot {
        val audioManager =
            context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                ?: return NO_INPUT_SNAPSHOT

        val inputs = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)

        if (inputs.isEmpty()) return NO_INPUT_SNAPSHOT

        val availableInputTypes = inputs
            .map { normalizeInputType(it.type) }
            .distinct()
            .sorted()

        val activeInput = choosePreferredInput(inputs)
        val activeInputType = normalizeInputType(activeInput.type)

        val activeOutputTypes = outputs
            .map { normalizeOutputType(it.type) }
            .distinct()
            .sorted()
        val hasHeadphoneOutput = outputs.any { isHeadphoneOutputType(it.type) }

        return RouteSnapshot(
            activeInputType = activeInputType,
            activeInputName = activeInput.productName?.toString() ?: "",
            activeInputUID = "",
            activeInputDataSourceName = null,
            availableInputTypes = availableInputTypes,
            activeOutputTypes = activeOutputTypes,
            hasHeadphoneOutput = hasHeadphoneOutput,
            activeInputIsExternal = activeInputType != "builtInMic" && activeInputType != "none",
            inputAvailable = true,
        )
    }

    private fun choosePreferredInput(inputs: Array<AudioDeviceInfo>): AudioDeviceInfo {
        for (type in INPUT_PRIORITY) {
            inputs.firstOrNull { it.type == type }?.let { return it }
        }
        return inputs.first()
    }

    private fun normalizeInputType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtInMic"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "headsetMic"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetoothHfp"
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usbAudio"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "lineIn"
        else -> "other"
    }

    private fun normalizeOutputType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "builtInSpeaker"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wiredHeadphones"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetoothHfp"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetoothA2dp"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usbAudio"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetoothLe"
        else -> "other"
    }

    private fun isHeadphoneOutputType(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_BLE_HEADSET -> true
        else -> false
    }
}
