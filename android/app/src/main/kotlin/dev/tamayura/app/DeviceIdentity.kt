package dev.tamayura.app

import java.util.Locale

internal class DeviceIdentityUnavailableException(cause: Exception? = null) :
    IllegalStateException("Cannot read the Android device identifier", cause), LocalizedText {
    override val textId = R.string.error_device_id
}

/** The system owns Android identity; app data and display names never determine it. */
internal object DeviceIdentity {
    fun read(readAndroidId: () -> String?): String {
        val value = try { readAndroidId() }
        catch (error: Exception) { throw DeviceIdentityUnavailableException(error) }
        val androidId = value?.trim()?.lowercase(Locale.ROOT)
        if (androidId == null || !androidId.matches(Regex("[0-9a-f]{1,16}"))) {
            throw DeviceIdentityUnavailableException()
        }
        return "android-$androidId"
    }

    fun displayName(systemName: String?, manufacturer: String?, model: String?): String =
        systemName?.trim()?.takeIf { it.isNotEmpty() }
            ?: listOfNotNull(manufacturer, model).map { it.trim() }
                .filter { it.isNotEmpty() }.distinct().joinToString(" ")
                .ifEmpty { "Android" }
}
