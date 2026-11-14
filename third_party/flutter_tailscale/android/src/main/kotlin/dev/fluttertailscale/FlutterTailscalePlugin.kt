package dev.fluttertailscale

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService
import org.json.JSONObject

/** Supplies Android's supported interface APIs to Go instead of blocked netlink.
 * Each engine owns only its observer; the native library owns the shared node.
 */
class FlutterTailscalePlugin : FlutterPlugin {
    private var method: MethodChannel? = null
    private var events: EventChannel? = null
    private var connectivity: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var owners = EngineOwners()
    private var worker: ExecutorService? = null
    private external fun requestNative(request: ByteArray): ByteArray?

    private fun nativeRequest(request: String): String =
        String(requestNative(request.toByteArray(Charsets.UTF_8))
            ?: throw IllegalStateException("Native response unavailable"), Charsets.UTF_8)

    private fun disposeOwner(owner: String) {
        try {
            nativeRequest(JSONObject().put("id", 0).put("method", "dispose")
                .put("params", JSONObject().put("ownerId", owner)).toString())
        } catch (_: Throwable) { /* process teardown or absent library */ }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ownerRegistry = EngineOwners().also { owners = it }
        val controlWorker = Executors.newSingleThreadExecutor { action ->
            Thread(action, "FlutterTailscaleControl").apply { isDaemon = true }
        }.also { worker = it }
        connectivity = binding.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        method = MethodChannel(binding.binaryMessenger, "dev.fluttertailscale/network").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "initialize") {
                    val request = call.arguments as? String
                    if (request == null || request.toByteArray(Charsets.UTF_8).size > 1024 * 1024) {
                        result.error("invalidRequest", "Invalid initialization request", null)
                        return@setMethodCallHandler
                    }
                    controlWorker.execute {
                        if (!ownerRegistry.isAttached()) return@execute
                        try {
                            System.loadLibrary("flutter_tailscale")
                            val response = nativeRequest(request)
                            val owner = JSONObject(response).optJSONObject("result")?.optString("ownerId")
                            if (!owner.isNullOrEmpty() && !ownerRegistry.register(owner)) {
                                disposeOwner(owner)
                                return@execute
                            }
                            main.post {
                                if (ownerRegistry.isAttached()) result.success(response)
                            }
                        } catch (_: Throwable) {
                            main.post {
                                if (ownerRegistry.isAttached()) result.error("runtimeUnavailable", "Native runtime unavailable", null)
                            }
                        }
                    }
                } else if (call.method == "unregisterOwner") {
                    (call.arguments as? String)?.let(ownerRegistry::unregister)
                    result.success(null)
                } else if (call.method == "snapshot") {
                    try { result.success(snapshot()) }
                    catch (_: Exception) { result.error("networkUnavailable", "Network snapshot unavailable", null) }
                } else {
                    result.notImplemented()
                }
            }
        }
        events = EventChannel(binding.binaryMessenger, "dev.fluttertailscale/network_changes").also { channel ->
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                    sink = eventSink
                    if (callback == null) {
                        val observer = object : ConnectivityManager.NetworkCallback() {
                            override fun onAvailable(network: Network) = changed()
                            override fun onLost(network: Network) = changed()
                            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = changed()
                        }
                        try {
                            connectivity?.registerDefaultNetworkCallback(observer)
                            callback = observer
                        } catch (_: Exception) { eventSink.error("networkUnavailable", "Network observer unavailable", null) }
                    }
                }
                override fun onCancel(arguments: Any?) { stopObserver() }
            })
        }
    }

    private fun changed() { main.post { sink?.success(null) } }

    private fun snapshot(): Map<String, Any> {
        val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces()).map { network ->
            var flags = 0
            if (network.isUp) flags = flags or 1 or 32
            if (network.interfaceAddresses.any { it.broadcast != null }) flags = flags or 2
            if (network.isLoopback) flags = flags or 4
            if (network.isPointToPoint) flags = flags or 8
            if (network.supportsMulticast()) flags = flags or 16
            mapOf("index" to network.index, "name" to network.name,
                "mtu" to network.mtu, "flags" to flags,
                "addresses" to network.interfaceAddresses.mapNotNull {
                    it.address?.hostAddress?.substringBefore('%')?.let { address ->
                        "$address/${it.networkPrefixLength}"
                    }
                })
        }.filter { (it["index"] as Int) > 0 }
        val manager = connectivity
        val properties = manager?.activeNetwork?.let { manager.getLinkProperties(it) }
        val gateway = properties?.routes?.firstOrNull { it.isDefaultRoute }?.gateway?.hostAddress?.substringBefore('%') ?: ""
        return mapOf("interfaces" to interfaces,
            "defaultInterface" to (properties?.interfaceName ?: ""), "gateway" to gateway)
    }

    private fun stopObserver() {
        callback?.let { try { connectivity?.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        callback = null
        sink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val abandoned = owners.detach()
        worker?.execute { abandoned.forEach(::disposeOwner) }
        worker?.shutdown()
        worker = null
        stopObserver()
        method?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        method = null
        events = null
        connectivity = null
    }
}
