package dev.tamayura.app

import android.content.ActivityNotFoundException
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.Executors

/** Process-owned engine and platform resources survive an Activity being detached or destroyed. */
internal class AndroidRuntime private constructor(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newFixedThreadPool(4)
    val media = SafMediaStore(context)
    private val discovery = LanDiscovery(context)
    private val sharing = BackgroundSharing.get(context)
    private var flutterEngine: FlutterEngine? = null
    var activity: MainActivity? = null
    private data class TransferRequest(val taskId: String, val ticket: Long, val result: MethodChannel.Result)

    fun engine(): FlutterEngine {
        flutterEngine?.let { return it }
        val engine = FlutterEngine(context)
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, "tamayura/platform")
                .setMethodCallHandler { call, result -> handleMethod(call, result) }
            MethodChannel(engine.dartExecutor.binaryMessenger, "tamayura/updates")
                .setMethodCallHandler { call, result -> AppUpdateInstaller.get(context).handle(call, result) }
            EventChannel(engine.dartExecutor.binaryMessenger, "tamayura/discovery")
                .setStreamHandler(discovery)
            EventChannel(engine.dartExecutor.binaryMessenger, "tamayura/sharing")
                .setStreamHandler(sharing)
            val loader = FlutterInjector.instance().flutterLoader()
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(), "main"))
            flutterEngine = engine
            return engine
        } catch (error: Exception) {
            engine.destroy()
            throw error
        }
    }

    fun handleMethod(call: MethodCall, result: MethodChannel.Result, host: MainActivity? = activity) {
        try {
            when (call.method) {
                "pickDirectory", "share", "open", "openBatteryOptimizationSettings" -> {
                    val current = host ?: throw IllegalStateException("请先打开应用页面")
                    current.handleUiMethod(call, result)
                }
                "scanDirectoriesMetadata" -> {
                    val directories = call.argument<List<Map<String, String>>>("directories")
                        ?.map { directory ->
                            SafMediaStore.SharedDirectory(
                                directory["id"] ?: throw IllegalArgumentException("Missing directory id"),
                                directory["uri"] ?: throw IllegalArgumentException("Missing directory uri"),
                                directory["name"] ?: throw IllegalArgumentException("Missing directory name"))
                        } ?: throw IllegalArgumentException("Missing directories")
                    // Cancel older scans and drop removed roots before queuing slow provider
                    // work; retained files keep serving peers until this scan publishes.
                    val ticket = media.beginScan(directories)
                    background(result) { media.scanMetadata(directories, ticket) }
                }
                "validateSharedDirectory" -> background(result) {
                    media.validateSharedDirectory(call.requiredString("uri"),
                        call.argument<List<String>>("existingUris")
                            ?: throw IllegalArgumentException("Missing existingUris"))
                    null
                }
                "thumbnail" -> background(result) { media.thumbnail(call.requiredString("id")) }
                "readPreview" -> background(result) {
                    media.readPreview(call.requiredString("uri"),
                        call.argument<Number>("maxDimension")?.toInt() ?: 2560)
                }
                "clearSharedDirectory" -> { media.clear(); result.success(null) }
                "readRange" -> background(result) {
                    media.readRange(call.requiredString("id"),
                        call.requiredNumber("offset").toLong(), call.requiredNumber("length").toInt())
                }
                "saveDownload" -> background(result) {
                    media.saveDownload(call.argument<List<String>>("sourcePaths")
                            ?: throw IllegalArgumentException("Missing sourcePaths"),
                        call.requiredNumber("expectedSize").toLong(),
                        call.requiredString("directoryUri"), call.requiredString("name"),
                        call.requiredString("mimeType"), call.argument<List<String>>("directories")
                            ?: throw IllegalArgumentException("Missing directories"))
                }
                "deleteDownload" -> background(result) {
                    media.deleteDownload(call.requiredString("uri"))
                    null
                }
                "transferSpace" -> background(result) { media.transferSpace(call.requiredString("directoryUri")) }
                "temporaryDirectory" -> result.success(context.cacheDir.absolutePath)
                "transferDirectory" -> background(result) { TransferScheduler.directory(context) }
                "scheduleTransfer" -> requestTransfer(call.requiredString("taskId"), result)
                "cancelTransfer" -> {
                    val taskId = call.requiredString("taskId")
                    TransferScheduler.cancel(context, taskId)
                    BackgroundTransferService.whenIdle(taskId) { result.success(null) }
                }
                "scheduledTransferIds" -> result.success(TransferScheduler.scheduledIds(context))
                "deviceId" -> background(result) {
                    DeviceIdentity.read {
                        Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
                    }
                }
                "localInfo" -> background(result) { localInfo() }
                "sharingStatus" -> result.success(sharing.status())
                "reportSharingReady" -> result.success(sharing.ready(call.requiredString("sessionId")))
                "reportSharingFailure" -> result.success(sharing.failed(
                    call.requiredString("sessionId"), call.requiredString("error")))
                "setBackgroundSharing" -> {
                    val enabled = call.argument<Boolean>("enabled")
                        ?: throw IllegalArgumentException("Missing enabled")
                    if (enabled) host?.requestSharingNotificationPermission()
                    sharing.setEnabled(enabled, result)
                }
                "startDiscovery" -> {
                    discovery.start(call.requiredString("id"), call.requiredString("name"),
                        call.requiredNumber("port").toInt())
                    result.success(null)
                }
                "stopDiscovery" -> { discovery.stop(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { report(result, error) }
    }

    private fun requestTransfer(taskId: String, result: MethodChannel.Result) {
        require(taskId.isNotBlank() && taskId.length <= 200) { "无效的下载任务 ID" }
        val request = TransferRequest(taskId, TransferScheduler.requestTicket(taskId), result)
        // Notification permission controls visibility, not permission to download.
        scheduleTransfer(request)
    }

    private fun scheduleTransfer(request: TransferRequest) {
        val (taskId, ticket, result) = request
        if (!TransferScheduler.requestCurrent(taskId, ticket)) {
            result.error("TRANSFER_CANCELLED", "下载已取消", null)
            return
        }
        if (taskId in TransferScheduler.scheduledIds(context) &&
            !BackgroundTransferService.isStopping(taskId)) {
            result.success(null)
            return
        }
        BackgroundTransferService.whenIdle(taskId) {
            if (!TransferScheduler.requestCurrent(taskId, ticket)) {
                result.error("TRANSFER_CANCELLED", "下载已取消", null)
            } else try {
                TransferScheduler.schedule(context, taskId)
                result.success(null)
            } catch (error: Exception) {
                result.error("TRANSFER_SCHEDULE_FAILED", error.message ?: "下载任务调度失败", null)
            }
        }
    }

    private fun MethodCall.requiredString(key: String): String =
        argument<String>(key)?.takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("Missing $key")

    private fun MethodCall.requiredNumber(key: String): Number =
        argument<Number>(key) ?: throw IllegalArgumentException("Missing $key")

    fun background(result: MethodChannel.Result, operation: () -> Any?) {
        workers.execute {
            try {
                val value = operation()
                main.post { result.success(value) }
            } catch (error: Exception) {
                main.post { report(result, error) }
            }
        }
    }

    fun report(result: MethodChannel.Result, error: Exception) {
        val code = when (error) {
            is DeviceIdentityUnavailableException -> "DEVICE_ID_UNAVAILABLE"
            is DirectoryOverlapException -> "DIR_OVERLAP"
            is DirectoryRelationException -> "DIR_RELATION_UNKNOWN"
            is SecurityException -> "PERMISSION_LOST"
            is java.io.FileNotFoundException -> "FILE_NOT_FOUND"
            is IllegalArgumentException -> "INVALID_ARGUMENT"
            is ActivityNotFoundException -> "NO_COMPATIBLE_APP"
            is java.util.concurrent.CancellationException -> "SCAN_CANCELLED"
            else -> "PLATFORM_ERROR"
        }
        result.error(code, error.message ?: "Android operation failed", null)
    }

    private fun localInfo(): Map<String, Any> {
        val addresses = Collections.list(NetworkInterface.getNetworkInterfaces())
            .filter { it.isUp && !it.isLoopback }
            .flatMap { Collections.list(it.inetAddresses) }
            .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress && it is java.net.Inet4Address }
            .mapNotNull { it.hostAddress }
            .distinct()
        val systemName = try { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }
        catch (_: Exception) { null }
        val deviceName = DeviceIdentity.displayName(systemName, Build.MANUFACTURER, Build.MODEL)
        return mapOf("name" to deviceName, "addresses" to addresses)
    }

    companion object {
        private var instance: AndroidRuntime? = null

        // FlutterActivity, platform channels and Service lifecycle all run on the main thread.
        fun get(context: Context): AndroidRuntime {
            val app = context.applicationContext
            return instance?.takeIf { it.context === app }
                ?: AndroidRuntime(app).also { instance = it }
        }
    }
}
