package dev.tamayura.app

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Each UIDT job owns a headless Dart isolate, independent of MainActivity. */
class BackgroundTransferService : JobService() {
    private val main = Handler(Looper.getMainLooper())
    private val sessions = mutableMapOf<Int, Session>()
    private val waitingStarts = mutableMapOf<Int, JobParameters>()

    private class Session(val params: JobParameters, val taskId: String, val token: Long) {
        val stopping = AtomicBoolean(false)
        val io = Executors.newSingleThreadExecutor()
        var engine: FlutterEngine? = null
        var workerChannel: MethodChannel? = null
        var platformChannel: MethodChannel? = null
        var ioCount = 0
        var engineDestroyed = false
        var jobStopped = false
        var terminal = false
        var ready = false
        var cancelled = false
        var name = "媒体文件"
        var received = 0L
        var total = 0L
        var lastNotification = 0L
    }

    override fun onStartJob(params: JobParameters): Boolean {
        val taskId = params.extras.getString(TransferScheduler.TASK_ID) ?: return false
        val token = gate.acquire(taskId)
        if (token == null) {
            // A previous engine can still be draining a document-provider write.
            return try {
                TransferScheduler.ensureNotificationChannel(this)
                setNotification(params, params.jobId,
                    basicNotification(params.jobId, "等待上一下载停止", "正在保存下载进度"),
                    JOB_END_NOTIFICATION_POLICY_REMOVE)
                waitingStarts[params.jobId] = params
                whenIdle(taskId) {
                    if (waitingStarts.remove(params.jobId) === params) jobFinished(params, true)
                }
                true
            } catch (_: Exception) { false }
        }
        val session = Session(params, taskId, token)
        sessions[params.jobId] = session
        running[taskId] = this to session
        try {
            TransferScheduler.ensureNotificationChannel(this)
            publish(session, "正在准备局域网下载", true)
            // Notify synchronously, then initialize Flutter after returning to JobScheduler.
            main.post { if (isCurrent(session) && !session.stopping.get()) startEngine(session) }
        } catch (error: Exception) {
            finish(session, false, error.message ?: "无法启动后台下载")
        }
        return true
    }

    private fun startEngine(session: Session) {
        try {
            val engine = FlutterEngine(applicationContext, null, true)
            session.engine = engine
            val worker = MethodChannel(engine.dartExecutor.binaryMessenger, "tamayura/background")
            session.workerChannel = worker
            worker.setMethodCallHandler { call, result -> handleWorker(session, call, result) }
            val platform = MethodChannel(engine.dartExecutor.binaryMessenger, "tamayura/platform")
            session.platformChannel = platform
            val media = SafMediaStore(applicationContext)
            platform.setMethodCallHandler { call, result -> handlePlatform(session, media, call, result) }
            val loader = FlutterInjector.instance().flutterLoader()
            // The annotated top-level entrypoint is exported from lib/main.dart.
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundTransferMain"))
            main.postDelayed({
                if (isCurrent(session) && !session.ready && !session.stopping.get()) {
                    finish(session, false, "后台下载入口未响应，请重新打开应用重试")
                }
            }, 30_000)
        } catch (error: Exception) { finish(session, false, error.message ?: "后台下载启动失败") }
    }

    private fun handleWorker(session: Session, call: MethodCall, result: MethodChannel.Result) {
        if (!isCurrent(session) || session.terminal) {
            result.error("TRANSFER_STOPPED", "此后台下载已结束", null)
            return
        }
        try {
            when (call.method) {
                "ready" -> {
                    session.ready = true
                    result.success(mapOf("taskId" to session.taskId))
                    if (session.stopping.get()) sendStop(session, session.params.stopReason)
                }
                "progress" -> {
                    if (!session.stopping.get()) {
                        session.received = (call.argument<Number>("received")?.toLong() ?: 0L).coerceAtLeast(0)
                        session.total = (call.argument<Number>("total")?.toLong() ?: 0L).coerceAtLeast(0)
                        session.name = call.argument<String>("name")?.take(160) ?: session.name
                        val now = SystemClock.elapsedRealtime()
                        if (now - session.lastNotification >= 500) {
                            session.lastNotification = now
                            updateEstimatedNetworkBytes(session.params, session.total, 0)
                            updateTransferredNetworkBytes(session.params, session.received, 0)
                            publish(session, "正在通过局域网下载", true)
                        }
                    }
                    result.success(null)
                }
                "complete" -> {
                    val success = call.argument<Boolean>("success") == true
                    val cancelled = call.argument<Boolean>("cancelled") == true
                    val error = call.argument<String>("error")
                    // Dart queued the task because its peer is temporarily unreachable.
                    val retry = !success && !cancelled && call.argument<Boolean>("retry") == true
                    result.success(null)
                    // Deliver the channel reply before tearing down its isolate.
                    main.post {
                        if (isCurrent(session)) finish(session, success, error, cancelled, retry)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("BACKGROUND_ERROR", error.message ?: "后台下载状态更新失败", null)
        }
    }

    private fun handlePlatform(session: Session, media: SafMediaStore, call: MethodCall, result: MethodChannel.Result) {
        if (!isCurrent(session) || session.stopping.get() || session.terminal) {
            result.error("TRANSFER_STOPPED", "后台下载已停止", null)
            return
        }
        if (call.method !in setOf("transferDirectory", "saveDownload", "transferSpace")) { result.notImplemented(); return }
        session.ioCount += 1
        session.io.execute {
            var value: Any? = null
            var failure: Exception? = null
            try {
                if (session.stopping.get()) throw java.util.concurrent.CancellationException("下载已停止")
                value = when (call.method) {
                    "transferDirectory" -> TransferScheduler.directory(applicationContext)
                    "transferSpace" -> media.transferSpace(call.requiredString("directoryUri"))
                    else -> media.saveDownload(
                        call.argument<List<String>>("sourcePaths") ?: throw IllegalArgumentException("Missing sourcePaths"),
                        call.argument<Number>("expectedSize")?.toLong() ?: throw IllegalArgumentException("Missing expectedSize"),
                        call.requiredString("directoryUri"),
                        call.requiredString("name"), call.requiredString("mimeType"),
                        call.argument<List<String>>("directories")
                            ?: throw IllegalArgumentException("Missing directories"),
                        cancelled = { session.stopping.get() || Thread.currentThread().isInterrupted })
                }
            } catch (error: Exception) { failure = error }
            main.post {
                session.ioCount -= 1
                if (!session.engineDestroyed) {
                    val error = failure
                    if (error == null) result.success(value)
                    else result.error(when (error) {
                        is SecurityException -> "PERMISSION_LOST"
                        is java.util.concurrent.CancellationException -> "TRANSFER_STOPPED"
                        is java.io.FileNotFoundException -> "FILE_NOT_FOUND"
                        else -> "PLATFORM_ERROR"
                    }, error.message, null)
                }
                releaseIfDrained(session)
            }
        }
    }

    private fun MethodCall.requiredString(key: String): String = argument<String>(key)
        ?.takeIf { it.isNotBlank() } ?: throw IllegalArgumentException("Missing $key")

    override fun onStopJob(params: JobParameters): Boolean {
        if (waitingStarts.remove(params.jobId) != null) {
            return params.stopReason != JobParameters.STOP_REASON_CANCELLED_BY_APP &&
                params.stopReason != JobParameters.STOP_REASON_USER
        }
        val session = sessions[params.jobId] ?: return false
        if (session.params.extras.getString(TransferScheduler.RUN_ID) !=
            params.extras.getString(TransferScheduler.RUN_ID)) return false
        session.jobStopped = true
        val cancelled = params.stopReason == JobParameters.STOP_REASON_CANCELLED_BY_APP ||
            params.stopReason == JobParameters.STOP_REASON_USER || session.cancelled
        requestStop(session, cancelled, params.stopReason)
        return !cancelled
    }

    private fun requestStop(session: Session, cancelled: Boolean, reason: Int) {
        if (!isCurrent(session) || session.terminal) return
        session.cancelled = session.cancelled || cancelled
        if (!session.stopping.compareAndSet(false, true)) return
        sendStop(session, reason)
        try { publish(session, if (session.cancelled) "下载已暂停" else "下载暂停，等待局域网恢复", false) }
        catch (_: Exception) { }
        main.postDelayed({
            if (isCurrent(session)) finish(session, false, null, session.cancelled)
        }, 2_000)
    }

    private fun sendStop(session: Session, reason: Int) {
        session.workerChannel?.invokeMethod("stop", mapOf("reason" to reason, "cancelled" to session.cancelled))
    }

    private fun finish(session: Session, success: Boolean, error: String?, cancelled: Boolean = false,
                       retry: Boolean = false) {
        if (!isCurrent(session) || session.terminal) return
        session.terminal = true
        val paused = session.stopping.get() && !session.cancelled && !cancelled
        val text = when {
            cancelled || session.cancelled -> "下载已暂停"
            paused -> "下载暂停，等待局域网恢复"
            success -> "下载完成，可以打开应用查看或分享"
            retry -> RETRY_TEXT
            else -> error?.take(200) ?: "下载失败，请打开应用重试"
        }
        try { publish(session, text, false) } catch (_: Exception) { }
        // A reschedule uses the job's exponential backoff; the Dart worker bounds
        // the total outage and then records a failure instead of asking again.
        if (!session.jobStopped) jobFinished(session.params, retry && !session.cancelled)
        session.stopping.set(true)
        destroyEngine(session)
    }

    private fun destroyEngine(session: Session) {
        if (session.engineDestroyed) return
        session.workerChannel?.setMethodCallHandler(null)
        session.platformChannel?.setMethodCallHandler(null)
        session.engine?.destroy()
        session.engine = null
        session.engineDestroyed = true
        // Let queued operations observe the stop flag and decrement ioCount.
        session.io.shutdown()
        releaseIfDrained(session)
    }

    private fun releaseIfDrained(session: Session) {
        if (!session.engineDestroyed || session.ioCount != 0 || !isCurrent(session)) return
        sessions.remove(session.params.jobId)
        running.remove(session.taskId)
        if (gate.release(session.taskId, session.token)) {
            val callbacks = waiting.remove(session.taskId).orEmpty()
            callbacks.forEach { it() }
        }
    }

    private fun isCurrent(session: Session): Boolean = sessions[session.params.jobId] === session

    private fun basicNotification(id: Int, title: String, text: String): Notification {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(this, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, TransferScheduler.CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title).setContentText(text).setContentIntent(pending)
            .setCategory(Notification.CATEGORY_PROGRESS).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).build()
    }

    private fun publish(session: Session, text: String, active: Boolean) {
        val notification = Notification.Builder.recoverBuilder(this,
            basicNotification(session.params.jobId, session.name, text))
            .setOngoing(active).setAutoCancel(!active)
            .setProgress(if (active) 1000 else 0,
                if (active) TransferPolicy.progress(session.received, session.total) else 0,
                active && session.total <= 0)
            .build()
        if (session.jobStopped) {
            if (TransferScheduler.notificationsEnabled(this)) {
                getSystemService(NotificationManager::class.java).notify(session.params.jobId, notification)
            }
        } else {
            // UIDT always requires an associated notification, even when permission is denied.
            // Android respects the user's permission/channel settings for notification visibility.
            setNotification(session.params, session.params.jobId, notification, JOB_END_NOTIFICATION_POLICY_DETACH)
        }
    }

    override fun onDestroy() {
        waitingStarts.clear()
        sessions.values.toList().forEach { session ->
            session.jobStopped = true
            requestStop(session, session.cancelled, JobParameters.STOP_REASON_SYSTEM_PROCESSING)
        }
        super.onDestroy()
    }

    companion object {
        internal const val RETRY_TEXT = "对端暂时不可用，稍后自动重试"
        private val gate = TransferRunGate()
        private val running = mutableMapOf<String, Pair<BackgroundTransferService, Session>>()
        private val waiting = mutableMapOf<String, MutableList<() -> Unit>>()

        // All callers and JobService callbacks run on the process main thread.
        fun whenIdle(taskId: String, callback: () -> Unit) {
            if (!gate.active(taskId)) callback()
            else waiting.getOrPut(taskId) { mutableListOf() }.add(callback)
        }

        fun isStopping(taskId: String): Boolean = running[taskId]?.second?.stopping?.get() == true

        fun cancelRunning(taskId: String) {
            running[taskId]?.let { (service, session) ->
                service.requestStop(session, true, JobParameters.STOP_REASON_CANCELLED_BY_APP)
            }
        }
    }
}
