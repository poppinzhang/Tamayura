package dev.tamayura.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager

/** Keeps the source device's Dart gRPC server alive independently of its Activity. */
open class BackgroundSharingService : Service() {
    private val sharing get() = BackgroundSharing.get(applicationContext)
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            sharing.setEnabled(false)
            stopSharing()
            return START_NOT_STICKY
        }
        if (!sharing.canStartService()) { stopSharing(); return START_NOT_STICKY }
        try {
            createChannel(this)
            getSystemService(NotificationManager::class.java).cancel(FAILURE_NOTIFICATION_ID)
            startForeground(NOTIFICATION_ID, notification(sharing.isRunning(this)),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            if (wakeLock == null) {
                val lock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Tamayura:BackgroundSharing")
                wakeLock = lock
                lock.setReferenceCounted(false)
                // Doze/OEM policy can still suspend networking without a battery exemption.
                lock.acquire()
            }
            // Cold Dart startup can now serve in the background, but is not reported as ready.
            sharing.started(this) ?: return START_NOT_STICKY
            startRuntime()
            return START_STICKY
        } catch (failure: Exception) {
            sharing.failedToStart(this, failure.message ?: "后台共享启动失败")
            return START_NOT_STICKY
        }
    }

    protected open fun startRuntime() { AndroidRuntime.get(applicationContext).engine() }

    internal fun showReadyNotification() = bestEffortNotification {
        notify(this, NOTIFICATION_ID, notification(true))
    }

    internal fun stopSharing() {
        releaseResources()
        sharing.stopped(this)
        stopSelf()
    }

    private fun releaseResources() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        releaseResources()
        sharing.stopped(this)
        super.onDestroy()
    }

    private fun notification(ready: Boolean): Notification {
        val stop = PendingIntent.getService(this, NOTIFICATION_ID,
            Intent(this, BackgroundSharingService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return notificationBuilder(this)
            .setContentTitle(if (ready) "玉响 · 后台共享运行中" else "玉响 · 后台共享正在启动")
            .setContentText(if (ready) "锁屏后继续通过局域网共享媒体，点击停止可恢复省电"
                else "正在初始化共享服务，请稍候")
            .addAction(Notification.Action.Builder(null, "停止共享", stop).build())
            .setOngoing(true)
            .build()
    }

    companion object {
        internal const val CHANNEL = "tamayura.background_sharing"
        internal const val NOTIFICATION_ID = 4203
        internal const val FAILURE_NOTIFICATION_ID = 4204
        internal const val ACTION_STOP = "dev.tamayura.app.STOP_SHARING"

        private fun createChannel(context: Context) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "后台共享", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "显示此设备的局域网媒体共享状态"
                })
        }

        private fun notificationBuilder(context: Context): Notification.Builder {
            val open = PendingIntent.getActivity(context, NOTIFICATION_ID,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentIntent(open)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
        }

        private fun notify(context: Context, id: Int, notification: Notification) {
            context.getSystemService(NotificationManager::class.java).notify(id, notification)
        }

        private inline fun bestEffortNotification(operation: () -> Unit) {
            try { operation() }
            catch (_: RuntimeException) {
                // Notification permission/system failures must not block status or pending replies.
                // The durable error remains available in the app.
            }
        }

        internal fun showFailureNotification(context: Context, message: String) = bestEffortNotification {
            createChannel(context)
            notify(context, FAILURE_NOTIFICATION_ID, notificationBuilder(context)
                .setContentTitle("玉响 · 后台共享启动失败")
                .setContentText("$message；点击打开应用重试")
                .setStyle(Notification.BigTextStyle().bigText("$message；点击打开应用重试"))
                .setAutoCancel(true)
                .build())
        }

        internal fun clearNotification(context: Context) = bestEffortNotification {
            context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
            context.getSystemService(NotificationManager::class.java).cancel(FAILURE_NOTIFICATION_ID)
        }
    }
}
