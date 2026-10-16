package dev.tamayura.app

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** User preference and acknowledged service state. All mutations happen on the main thread. */
internal class BackgroundSharing private constructor(private val context: Context) : EventChannel.StreamHandler {
    private val preferences = context.getSharedPreferences("background_sharing", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var service: BackgroundSharingService? = null
    private var starting = false
    private var generation = 0L
    private var error: String? = null
    private val waiting = mutableListOf<MethodChannel.Result>()
    private val enabled get() = preferences.getBoolean("enabled", false)

    fun status(): Map<String, Any?> = mapOf(
        "enabled" to enabled,
        "running" to (service != null),
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
            generation += 1
            starting = false
            error = null
            service?.stopSharing()
            context.stopService(Intent(context, BackgroundSharingService::class.java))
            publish()
            finishWaiting(null)
            result?.success(status())
            return
        }
        error = null
        if (service != null) { result?.success(status()); publish(); return }
        result?.let(waiting::add)
        if (starting) return
        preferences.edit().putBoolean("enabled", true).apply()
        starting = true
        val current = ++generation
        publish()
        try {
            check(context.startForegroundService(Intent(context, BackgroundSharingService::class.java)) != null) {
                "系统未接受后台共享服务"
            }
            main.postDelayed({
                if (generation == current && starting) {
                    failed("后台共享服务启动超时，请重新打开应用后重试")
                    context.stopService(Intent(context, BackgroundSharingService::class.java))
                }
            }, 10_000)
        } catch (failure: Exception) { failed(failure.message ?: "无法启动后台共享") }
    }

    /** Restore only while the user has an Activity in the foreground; no boot auto-start. */
    fun restore() {
        if (enabled && service == null && !starting) setEnabled(true)
        else publish() // Battery exemption can have changed in system settings.
    }

    fun isEnabled(): Boolean = enabled

    fun started(current: BackgroundSharingService) {
        if (!enabled) { current.stopSharing(); return }
        service = current
        starting = false
        generation += 1
        error = null
        publish()
    }

    fun ready() { finishWaiting(null) }

    fun stopped(current: BackgroundSharingService) {
        if (service !== current) return
        service = null
        publish()
    }

    fun failed(message: String) {
        preferences.edit().putBoolean("enabled", false).apply()
        starting = false
        generation += 1
        error = message
        service?.stopSharing()
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
