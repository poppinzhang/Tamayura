package dev.tamayura.app

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** User preference and acknowledged service state. All mutations happen on the main thread. */
internal class BackgroundSharing private constructor(private val context: Context) : EventChannel.StreamHandler {
    private val preferences = context.getSharedPreferences("background_sharing", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var service: BackgroundSharingService? = null
    private var starting = false
    private var running = false
    private var sessionId: String? = null
    private var generation = 0L
    private var error: String? = preferences.getString("error", null)
    private var restartSuppressed = preferences.getBoolean("restartSuppressed", false)
    private val waiting = mutableListOf<MethodChannel.Result>()
    private val enabled get() = preferences.getBoolean("enabled", false)

    private fun text(id: Int): String = AppText.get(context, id)

    fun status(): Map<String, Any?> = mapOf(
        "enabled" to enabled,
        "running" to running,
        "starting" to starting,
        "sessionId" to sessionId,
        "batteryExempt" to context.getSystemService(PowerManager::class.java)
            .isIgnoringBatteryOptimizations(context.packageName),
        "error" to error)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        events.success(status())
    }

    override fun onCancel(arguments: Any?) { sink = null }

    fun setEnabled(value: Boolean, result: MethodChannel.Result? = null) {
        if (!value) {
            preferences.edit().putBoolean("enabled", false).apply()
            clearError()
            detachService()?.stopSharing()
            context.stopService(Intent(context, BackgroundSharingService::class.java))
            BackgroundSharingService.clearNotification(context)
            publish()
            finishWaiting(null)
            result?.success(status())
            return
        }
        if (running) { result?.success(status()); publish(); return }
        result?.let(waiting::add)
        if (starting) return
        preferences.edit().putBoolean("enabled", true).apply()
        clearError()
        starting = true
        val current = ++generation
        publish()
        try {
            check(context.startForegroundService(Intent(context, BackgroundSharingService::class.java)) != null) {
                text(R.string.sharing_error_rejected)
            }
            main.postDelayed({
                if (generation == current && starting && service == null) {
                    fail(text(R.string.sharing_error_start_timeout))
                }
            }, 10_000)
        } catch (failure: Exception) { fail(failure.message ?: text(R.string.sharing_error_start)) }
    }

    /** Restore only while the user has an Activity in the foreground; no boot auto-start. */
    fun restore() {
        if (enabled && service == null && !starting) setEnabled(true)
        else publish() // Battery exemption can have changed in system settings.
    }

    /** Show the current service notification in a newly chosen language. */
    fun refreshNotification() = service?.refreshNotification()

    fun canStartService(): Boolean = enabled && !restartSuppressed
    fun isRunning(current: BackgroundSharingService): Boolean = service === current && running

    /** A foreground Service permits startup; Dart must still acknowledge a usable gRPC listener. */
    fun started(current: BackgroundSharingService): String? {
        if (!canStartService()) { current.stopSharing(); return null }
        if (service === current) return sessionId
        detachService()?.stopSharing()
        service = current
        starting = true
        val session = UUID.randomUUID().toString()
        sessionId = session
        val currentGeneration = ++generation
        clearError()
        main.postDelayed({
            if (generation == currentGeneration && starting && sessionId == session) {
                fail(text(R.string.sharing_error_init_timeout))
            }
        }, 120_000)
        publish()
        return session
    }

    fun ready(session: String): Boolean {
        if (!isCurrent(session)) return false
        if (running) return true
        running = true
        starting = false
        generation += 1
        service?.showReadyNotification()
        publish()
        finishWaiting(null)
        return true
    }

    fun failed(session: String, message: String): Boolean {
        if (!isCurrent(session)) return false
        fail(message)
        return true
    }

    /** Failures before a session exists must also release resources owned by the Service. */
    fun failedToStart(current: BackgroundSharingService, message: String) {
        if (service == null || service === current) fail(message)
        current.stopSharing()
    }

    fun stopped(current: BackgroundSharingService) {
        if (service !== current) return
        // An ordinary lifecycle teardown may be followed by a system sticky restart.
        fail(text(R.string.sharing_error_stopped), suppressRestart = false, stopNativeService = false)
    }

    private fun isCurrent(session: String): Boolean =
        enabled && service != null && sessionId == session

    private fun clearError() {
        error = null
        restartSuppressed = false
        preferences.edit().remove("error").remove("restartSuppressed").apply()
    }

    private fun detachService(): BackgroundSharingService? {
        val current = service
        service = null
        starting = false
        running = false
        sessionId = null
        generation += 1
        return current
    }

    private fun fail(message: String, suppressRestart: Boolean = true, stopNativeService: Boolean = true) {
        // Preserve the user's preference so returning to the Activity can retry once.
        error = message
        restartSuppressed = suppressRestart
        preferences.edit().putString("error", message)
            .putBoolean("restartSuppressed", suppressRestart).apply()
        val current = detachService()
        if (stopNativeService) {
            current?.stopSharing()
            context.stopService(Intent(context, BackgroundSharingService::class.java))
        }
        BackgroundSharingService.showFailureNotification(context, message)
        publish()
        finishWaiting(message)
    }

    private fun finishWaiting(failure: String?) {
        val pending = waiting.toList()
        waiting.clear()
        pending.forEach {
            if (failure == null) it.success(status())
            else it.error("BACKGROUND_SHARING_FAILED", failure, status())
        }
    }

    private fun publish() { sink?.success(status()) }

    companion object {
        private var instance: BackgroundSharing? = null
        fun get(context: Context): BackgroundSharing {
            val app = context.applicationContext
            return instance?.takeIf { it.context === app }
                ?: BackgroundSharing(app).also { instance = it }
        }
    }
}
