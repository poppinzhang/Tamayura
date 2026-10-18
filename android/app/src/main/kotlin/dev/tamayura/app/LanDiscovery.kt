package dev.tamayura.app

import android.content.Context
import android.net.nsd.DiscoveryRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.util.IdentityHashMap

/** Android 16 NSD with continuously updated service information. */
internal class LanDiscovery(private val context: Context) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val executor = context.mainExecutor
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var epoch = 0L
    private var selfId = ""
    private val present = mutableSetOf<String>()
    private val callbacks = mutableMapOf<String, NsdManager.ServiceInfoCallback>()
    private val known = mutableMapOf<String, Map<String, Any>>()
    private val browserStops = IdentityHashMap<NsdManager.DiscoveryListener, Int>()
    private val unregisters = IdentityHashMap<NsdManager.RegistrationListener, Int>()

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        known.values.forEach { events.success(it) }
    }

    override fun onCancel(arguments: Any?) { sink = null }

    fun start(id: String, name: String, port: Int) {
        require(port in 1..65535) { AppText.get(context, R.string.error_invalid_port) }
        require(id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { AppText.get(context, R.string.error_invalid_device_id) }
        stop()
        selfId = id
        val current = epoch
        try {
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) { if (current != epoch) unregister(this) }
                override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                    unregisters.remove(this)
                    if (current == epoch) { registration = null; error("register", code) }
                }
                override fun onServiceUnregistered(info: NsdServiceInfo) { unregisters.remove(this) }
                override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) { retryUnregister(this, code) }
            }
            registration = listener
            val service = NsdServiceInfo().apply {
                // Keep the full Android identity while respecting the 63-byte DNS label limit.
                serviceName = "Tamayura-${id.take(54)}"
                serviceType = SERVICE_TYPE
                this.port = port
                setAttribute("id", id)
                setAttribute("name", utf8Prefix(name, 180))
                setAttribute("version", "4")
            }
            manager.registerService(service, NsdManager.PROTOCOL_DNS_SD, executor, listener)
            val browser = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) { if (current != epoch) stopBrowser(this) }
                override fun onDiscoveryStopped(type: String) { browserStops.remove(this) }
                override fun onStartDiscoveryFailed(type: String, code: Int) {
                    if (current == epoch) { error("discover", code); stop() }
                }
                override fun onStopDiscoveryFailed(type: String, code: Int) { retryStopBrowser(this, code) }
                override fun onServiceFound(info: NsdServiceInfo) {
                    if (current != epoch || info.serviceType?.trimEnd('.') != SERVICE_TYPE.trimEnd('.')) return
                    if (present.add(info.serviceName)) watch(info, current)
                }
                override fun onServiceLost(info: NsdServiceInfo) {
                    if (current != epoch) return
                    present.remove(info.serviceName)
                    callbacks.remove(info.serviceName)?.let(::unwatch)
                    lost(info.serviceName)
                }
            }
            discovery = browser
            manager.discoverServices(DiscoveryRequest.Builder(SERVICE_TYPE).build(), executor, browser)
        } catch (error: Exception) { stop(); throw error }
    }

    private fun watch(service: NsdServiceInfo, current: Long, attempt: Int = 1) {
        if (current != epoch || service.serviceName !in present) return
        val key = service.serviceName
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(code: Int) {
                if (current != epoch || callbacks[key] !== this) return
                callbacks.remove(key)
                if (attempt < 3) main.postDelayed({ watch(service, current, attempt + 1) }, 300)
                else error("resolve", code)
            }
            override fun onServiceInfoCallbackUnregistered() { if (callbacks[key] === this) callbacks.remove(key) }
            override fun onServiceLost() { if (current == epoch && callbacks[key] === this) lost(key) }
            override fun onServiceUpdated(info: NsdServiceInfo) {
                if (current != epoch || callbacks[key] !== this) { unwatch(this); return }
                try {
                    val id = info.attributes["id"]?.toString(Charsets.UTF_8)
                    val name = info.attributes["name"]?.toString(Charsets.UTF_8) ?: info.serviceName
                    val address = info.hostAddresses.firstOrNull { it is java.net.Inet4Address }
                        ?: info.hostAddresses.firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                    val host = address?.hostAddress
                    if (!id.isNullOrBlank() && id.length <= 128 && id != selfId && host != null && info.port in 1..65535) {
                        val event = mapOf("type" to "found", "id" to id, "name" to name.take(128),
                            "host" to host, "port" to info.port)
                        if (known[key] != event) { known[key] = event; sink?.success(event) }
                    }
                } catch (exception: Exception) { error("resolve", -1, exception.message) }
            }
        }
        callbacks[key] = callback
        try { manager.registerServiceInfoCallback(service, executor, callback) }
        catch (exception: Exception) { callbacks.remove(key); error("resolve", -1, exception.message) }
    }

    private fun lost(key: String) { known.remove(key)?.let { sink?.success(it + ("type" to "lost")) } }

    fun stop() {
        epoch += 1
        discovery?.let(::stopBrowser)
        registration?.let(::unregister)
        discovery = null
        registration = null
        callbacks.values.toList().forEach(::unwatch)
        callbacks.clear()
        present.clear()
        known.clear()
    }

    private fun unwatch(callback: NsdManager.ServiceInfoCallback) {
        try { manager.unregisterServiceInfoCallback(callback) } catch (_: RuntimeException) { }
    }

    private fun stopBrowser(listener: NsdManager.DiscoveryListener) {
        browserStops[listener] = (browserStops[listener] ?: 0) + 1
        try { manager.stopServiceDiscovery(listener) }
        catch (_: IllegalArgumentException) { browserStops.remove(listener) }
        catch (_: RuntimeException) { retryStopBrowser(listener, -1) }
    }

    private fun unregister(listener: NsdManager.RegistrationListener) {
        unregisters[listener] = (unregisters[listener] ?: 0) + 1
        try { manager.unregisterService(listener) }
        catch (_: IllegalArgumentException) { unregisters.remove(listener) }
        catch (_: RuntimeException) { retryUnregister(listener, -1) }
    }

    private fun retryStopBrowser(listener: NsdManager.DiscoveryListener, code: Int) {
        if ((browserStops[listener] ?: 0) < 3) main.postDelayed({ stopBrowser(listener) }, 300)
        else { browserStops.remove(listener); error("stop", code) }
    }

    private fun retryUnregister(listener: NsdManager.RegistrationListener, code: Int) {
        if ((unregisters[listener] ?: 0) < 3) main.postDelayed({ unregister(listener) }, 300)
        else { unregisters.remove(listener); error("unregister", code) }
    }

    private fun error(stage: String, code: Int, detail: String? = null) {
        sink?.success(mapOf("type" to "error", "stage" to stage, "code" to code,
            "message" to (detail ?: AppText.get(context, R.string.discovery_failed, stage, code))))
    }

    private fun utf8Prefix(value: String, maxBytes: Int): String {
        var result = value.take(100)
        while (result.toByteArray(Charsets.UTF_8).size > maxBytes) result = result.dropLast(1)
        return result
    }

    companion object { private const val SERVICE_TYPE = "_tamayura._tcp." }
}
