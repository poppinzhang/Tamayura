package dev.tamayura.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
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
        if (!sharing.isEnabled()) { stopSharing(); return START_NOT_STICKY }
        try {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "后台共享", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "显示此设备的局域网媒体共享状态"
                })
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            if (wakeLock == null) {
                val lock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Tamayura:BackgroundSharing")
                wakeLock = lock
                lock.setReferenceCounted(false)
                // The user explicitly controls this duration with the switch/notification action.
                // Doze/OEM policy can still suspend network access without a battery exemption.
                lock.acquire()
            }
            // Publish before executing Dart, so a cold sticky restart sees an acknowledged service.
            sharing.started(this)
            startRuntime()
            sharing.ready()
            return START_STICKY
        } catch (failure: Exception) {
            sharing.failed(failure.message ?: "后台共享启动失败")
            stopSharing()
            return START_NOT_STICKY
        }
    }

    protected open fun startRuntime() { AndroidRuntime.get(applicationContext).engine() }

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

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, NOTIFICATION_ID,
            Intent(this, BackgroundSharingService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("玉响 · 后台共享已开启")
            .setContentText("锁屏后继续通过局域网共享媒体，点击停止可恢复省电")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "停止共享", stop).build())
            .setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
    }

    companion object {
        internal const val CHANNEL = "tamayura.background_sharing"
        internal const val NOTIFICATION_ID = 4203
        internal const val ACTION_STOP = "dev.tamayura.app.STOP_SHARING"
    }
}
