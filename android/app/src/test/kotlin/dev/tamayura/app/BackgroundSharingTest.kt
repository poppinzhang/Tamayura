package dev.tamayura.app

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.LooperMode
import org.robolectric.shadows.ShadowPowerManager
import org.robolectric.shadows.ShadowNotificationManager
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
@LooperMode(LooperMode.Mode.PAUSED)
class BackgroundSharingTest {
    private lateinit var application: Application
    private lateinit var sharing: BackgroundSharing
    private val services = mutableListOf<TestSharingService>()
    private val events = mutableListOf<Map<*, *>>()

    @Before fun setUp() {
        FailingSharingNotificationManager.failNotify = false
        FailingSharingNotificationManager.failChannel = false
        application = RuntimeEnvironment.getApplication()
        sharing = BackgroundSharing.get(application)
        sharing.setEnabled(false)
        sharing.onListen(null, object : EventChannel.EventSink {
            override fun success(value: Any?) { events.add(value as Map<*, *>) }
            override fun error(code: String, message: String?, details: Any?) { fail(message) }
            override fun endOfStream() { }
        })
    }

    @After fun tearDown() {
        sharing.setEnabled(false)
        sharing.onCancel(null)
        services.forEach { it.onDestroy() }
    }

    @Test fun defaultOffDoesNotStartRuntimeAndActivityDoesNotOwnEngine() {
        assertEquals(false, sharing.status()["enabled"])
        val service = newService()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(null, 0, 1))
        assertEquals(0, service.runtimeStarts)
        assertEquals(false, sharing.status()["running"])
        assertFalse(Robolectric.buildActivity(MainActivity::class.java).get().shouldDestroyEngineWithHost())
    }

    @Test fun enableWaitsForDartReadyBeforePublishingRunningAndReleasesEverythingOnDisable() {
        val result = Result()
        sharing.setEnabled(true, result)
        assertEquals(0, result.replies)
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertEquals(true, sharing.status()["starting"])
        assertNull(sharing.status()["sessionId"])
        val service = newService()
        assertEquals(Service.START_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertEquals(0, result.replies)
        assertEquals(false, sharing.status()["running"])
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertEquals(1, service.runtimeStarts)
        val notification = shadowOf(service).lastForegroundNotification
        assertEquals(BackgroundSharingService.CHANNEL, notification.channelId)
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals("停止共享", notification.actions.single().title)
        assertEquals("玉响 · 后台共享正在启动", notification.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(false, service.statusAtRuntimeStart?.get("running"))
        assertNotNull(service.statusAtRuntimeStart?.get("sessionId"))
        assertTrue(sharing.ready(session()))
        result.assertSuccess(true, true)
        assertEquals(false, sharing.status()["starting"])
        assertEquals("玉响 · 后台共享运行中", notification(BackgroundSharingService.NOTIFICATION_ID)
            ?.extras?.getString(Notification.EXTRA_TITLE))
        val disabled = Result()
        sharing.setEnabled(false, disabled)
        disabled.assertSuccess(false, false)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertTrue(shadowOf(service).isForegroundStopped)
        assertEquals(false, events.last()["enabled"])
        assertEquals(false, events.last()["running"])
        assertNull(sharing.status()["sessionId"])
        assertFalse(application.getSharedPreferences("background_sharing", Context.MODE_PRIVATE)
            .getBoolean("enabled", true))
    }

    @Test fun notificationStopClearsPreferenceAndPublishesState() {
        sharing.setEnabled(true)
        val service = newService()
        service.onStartCommand(Intent(), 0, 1)
        shadowOf(service).lastForegroundNotification.actions.single().actionIntent.send()
        val stop = generateSequence { shadowOf(application).nextStartedService }
            .last { it.action == BackgroundSharingService.ACTION_STOP }
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(stop, 0, 2))
        assertEquals(false, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertEquals(false, events.last()["running"])
    }

    @Test fun stickyRestartNeedsAFreshDartAcknowledgementAndRejectsOldCallbacks() {
        sharing.setEnabled(true)
        val original = newService()
        original.onStartCommand(Intent(), 0, 1)
        val previous = session()
        assertTrue(sharing.ready(previous))
        original.onDestroy()
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        val restarted = newService()
        assertEquals(Service.START_STICKY, restarted.onStartCommand(null, 0, 2))
        val current = session()
        assertNotEquals(previous, current)
        assertEquals(false, sharing.status()["running"])
        assertEquals(1, restarted.runtimeStarts)
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertFalse(sharing.ready(previous))
        assertFalse(sharing.failed(previous, "stale failure"))
        assertNull(sharing.status()["error"])
        assertTrue(sharing.ready(current))
        assertEquals(true, sharing.status()["running"])
    }

    @Test fun failedRuntimeStartupPreservesPreferenceAndReportsSingleError() {
        val result = Result()
        sharing.setEnabled(true, result)
        val service = newService().apply { failStartup = true }
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertEquals(1, result.replies)
        assertEquals("BACKGROUND_SHARING_FAILED", result.errorCode)
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertEquals("runtime failed", sharing.status()["error"])
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertTrue(shadowOf(service).isForegroundStopped)
        service.onDestroy()
        assertNotNull(notification(BackgroundSharingService.FAILURE_NOTIFICATION_ID))
    }

    @Test fun disableWhileStartPendingPreventsLateServiceFromStartingRuntime() {
        val pending = Result()
        sharing.setEnabled(true, pending)
        sharing.setEnabled(false)
        val service = newService()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
        pending.assertSuccess(false, false)
        assertEquals(0, service.runtimeStarts)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(11))
        assertNull(sharing.status()["error"])
        assertEquals(1, pending.replies)
    }

    @Test fun serviceStartTimeoutPreservesPreferenceAndDoesNotLeavePendingMethodCalls() {
        val result = Result()
        sharing.setEnabled(true, result)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(11))
        assertEquals(1, result.replies)
        assertEquals("BACKGROUND_SHARING_FAILED", result.errorCode)
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertTrue((sharing.status()["error"] as String).contains("超时"))
    }

    @Test fun duplicateStartsDoNotAcquireAnotherLockAndAllRequestsFinish() {
        val first = Result()
        val second = Result()
        sharing.setEnabled(true, first)
        sharing.setEnabled(true, second)
        val service = newService()
        service.onStartCommand(Intent(), 0, 1)
        val session = session()
        val lock = ShadowPowerManager.getLatestWakeLock()
        service.onStartCommand(Intent(), 0, 2)
        assertSame(lock, ShadowPowerManager.getLatestWakeLock())
        assertEquals(session, session())
        assertEquals(0, first.replies)
        assertTrue(sharing.ready(session))
        assertTrue(sharing.ready(session))
        first.assertSuccess(true, true)
        second.assertSuccess(true, true)
        sharing.setEnabled(false)
        assertFalse(lock.isHeld)
    }

    @Test fun coldStickyRestartCreatesAStartingSessionWithoutAnActivityOrEnableCall() {
        preferences().edit().putBoolean("enabled", true).apply()
        val restarted = newService()
        assertEquals(Service.START_STICKY, restarted.onStartCommand(null, 0, 1))
        assertEquals(true, sharing.status()["starting"])
        assertEquals(false, sharing.status()["running"])
        assertTrue(sharing.ready(session()))
        assertEquals(true, sharing.status()["running"])
    }

    @Test fun dartFailureReleasesResourcesPersistsErrorAndCanRetryWithoutRecreatingRuntime() {
        val result = Result()
        sharing.setEnabled(true, result)
        val service = startService()
        val previous = session()
        assertTrue(sharing.failed(previous, "database unavailable"))
        assertFailure(result, "database unavailable")
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertTrue(shadowOf(service).isForegroundStopped)
        assertEquals("database unavailable", preferences().getString("error", null))
        assertNotNull(notification(BackgroundSharingService.FAILURE_NOTIFICATION_ID))
        assertFalse(sharing.ready(previous))
        assertFalse(sharing.failed(previous, "late failure"))
        val retry = Result()
        sharing.setEnabled(true, retry)
        service.onStartCommand(Intent(), 0, 2)
        assertNotEquals(previous, session())
        assertNull(sharing.status()["error"])
        assertNull(preferences().getString("error", null))
        assertNull(notification(BackgroundSharingService.FAILURE_NOTIFICATION_ID))
        assertTrue(sharing.ready(session()))
        retry.assertSuccess(true, true)
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertEquals(1, result.replies)
    }

    @Test fun persistedErrorIsLoadedAfterProcessRecreationAndForegroundRestoreRetries() {
        sharing.setEnabled(true)
        startService()
        sharing.failed(session(), "initialization failed")
        BackgroundSharing::class.java.getDeclaredField("instance").apply {
            isAccessible = true
            set(null, null)
        }
        sharing = BackgroundSharing.get(application)
        assertEquals("initialization failed", sharing.status()["error"])
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        val late = newService()
        assertEquals(Service.START_NOT_STICKY, late.onStartCommand(null, 0, 1))
        assertEquals(0, late.runtimeStarts)
        sharing.restore()
        assertEquals(true, sharing.status()["starting"])
        assertNull(sharing.status()["error"])
        startService()
        assertTrue(sharing.ready(session()))
    }

    @Test fun disableDuringInitializationRejectsLateAcknowledgementsAndCancelsTimeout() {
        val pending = Result()
        sharing.setEnabled(true, pending)
        startService()
        val previous = session()
        sharing.setEnabled(false)
        pending.assertSuccess(false, false)
        assertFalse(sharing.ready(previous))
        assertFalse(sharing.failed(previous, "late"))
        idle(121)
        assertNull(sharing.status()["error"])
        assertNull(notification(BackgroundSharingService.FAILURE_NOTIFICATION_ID))
        assertEquals(1, pending.replies)
    }

    @Test fun dartReadinessTimeoutIsSeparateFromForegroundServiceDeadlineAndReleasesLock() {
        val result = Result()
        sharing.setEnabled(true, result)
        idle(9)
        val service = startService()
        val previous = session()
        idle(110)
        assertEquals(0, result.replies)
        assertEquals(true, sharing.status()["starting"])
        assertEquals(false, sharing.status()["running"])
        idle(11)
        assertFailure(result, "后台共享初始化超时，请打开应用后重试")
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertTrue(shadowOf(service).isForegroundStopped)
        assertFalse(sharing.ready(previous))
        assertNotNull(notification(BackgroundSharingService.FAILURE_NOTIFICATION_ID))
        sharing.restore()
        startService()
        assertTrue(sharing.ready(session()))
        idle(121)
        assertEquals(true, sharing.status()["running"])
    }

    @Test fun duplicateServiceStartDoesNotResetTheReadinessTimeout() {
        val pending = Result()
        sharing.setEnabled(true, pending)
        val service = startService()
        idle(100)
        service.onStartCommand(Intent(), 0, 2)
        idle(21)
        assertEquals("BACKGROUND_SHARING_FAILED", pending.errorCode)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
    }

    @Test fun unexpectedServiceDestructionFinishesPendingStartAndCanBeRestored() {
        val pending = Result()
        sharing.setEnabled(true, pending)
        val service = startService()
        service.onDestroy()
        assertFailure(pending, "后台共享服务已停止，请打开应用后重试")
        sharing.restore()
        startService()
        assertTrue(sharing.ready(session()))
    }

    @Test fun platformReadyAndFailureMethodsReturnAcceptanceAndValidateArguments() {
        sharing.setEnabled(true)
        startService()
        val runtime = AndroidRuntime.get(application)
        val ready = Result()
        runtime.handleMethod(MethodCall("reportSharingReady", mapOf("sessionId" to session())), ready)
        assertEquals(true, ready.rawValue)
        val stale = Result()
        runtime.handleMethod(MethodCall("reportSharingFailure", mapOf(
            "sessionId" to "old", "error" to "late failure")), stale)
        assertEquals(false, stale.rawValue)
        val missing = Result()
        runtime.handleMethod(MethodCall("reportSharingReady", emptyMap<String, Any>()), missing)
        assertEquals("INVALID_ARGUMENT", missing.errorCode)
        assertEquals(true, sharing.status()["running"])
    }

    @Test fun disablingFailedSharingClearsDurableErrorAndFailureNotification() {
        sharing.setEnabled(true)
        startService()
        sharing.failed(session(), "failed")
        sharing.setEnabled(false)
        assertNull(sharing.status()["error"])
        assertNull(preferences().getString("error", null))
        assertNull(notification(BackgroundSharingService.FAILURE_NOTIFICATION_ID))
        assertEquals(false, sharing.status()["enabled"])
    }

    @Test fun serviceArrivingAfterStartupTimeoutIsRejectedUntilExplicitRetry() {
        val pending = Result()
        sharing.setEnabled(true, pending)
        idle(11)
        val failure = sharing.status()["error"]
        val late = newService()
        assertEquals(Service.START_NOT_STICKY, late.onStartCommand(Intent(), 0, 1))
        assertEquals(0, late.runtimeStarts)
        assertEquals(failure, sharing.status()["error"])
        assertEquals(false, sharing.status()["running"])
        assertNull(sharing.status()["sessionId"])
        assertEquals(1, pending.replies)
        sharing.setEnabled(true)
        startService()
        assertTrue(sharing.ready(session()))
    }

    @Test fun ordinaryTeardownStillAllowsStickyRestartAfterProcessRecreation() {
        sharing.setEnabled(true)
        val original = startService()
        assertTrue(sharing.ready(session()))
        while (shadowOf(application).nextStoppedService != null) { }
        original.onDestroy()
        assertNull(shadowOf(application).nextStoppedService)
        assertFalse(shadowOf(original).isStoppedBySelf)
        BackgroundSharing::class.java.getDeclaredField("instance").apply {
            isAccessible = true
            set(null, null)
        }
        sharing = BackgroundSharing.get(application)
        val restarted = newService()
        assertEquals(Service.START_STICKY, restarted.onStartCommand(null, 0, 2))
        assertEquals(false, sharing.status()["running"])
        assertTrue(sharing.ready(session()))
    }

    @Test
    @Config(shadows = [FailingSharingNotificationManager::class])
    fun readyNotificationFailureDoesNotPreventAcknowledgement() {
        val pending = Result()
        sharing.setEnabled(true, pending)
        startService()
        FailingSharingNotificationManager.failNotify = true
        assertTrue(sharing.ready(session()))
        pending.assertSuccess(true, true)
        assertEquals(true, events.last()["running"])
    }

    @Test
    @Config(shadows = [FailingSharingNotificationManager::class])
    fun failureNotificationFailureDoesNotPreventCleanupAndErrorReply() {
        val pending = Result()
        sharing.setEnabled(true, pending)
        startService()
        FailingSharingNotificationManager.failChannel = true
        assertTrue(sharing.failed(session(), "database failed"))
        assertFailure(pending, "database failed")
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertEquals("database failed", events.last()["error"])
    }

    private fun assertFailure(result: Result, message: String) {
        assertEquals(1, result.replies)
        assertEquals("BACKGROUND_SHARING_FAILED", result.errorCode)
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertEquals(false, sharing.status()["starting"])
        assertNull(sharing.status()["sessionId"])
        assertEquals(message, sharing.status()["error"])
    }

    private fun session(): String = sharing.status()["sessionId"] as String
    private fun idle(seconds: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(seconds))
    private fun preferences() = application.getSharedPreferences("background_sharing", Context.MODE_PRIVATE)
    private fun notification(id: Int): Notification? =
        shadowOf(application.getSystemService(NotificationManager::class.java)).getNotification(id)
    private fun startService(): TestSharingService = newService().also {
        assertEquals(Service.START_STICKY, it.onStartCommand(Intent(), 0, 1))
    }
    private fun newService(): TestSharingService =
        Robolectric.buildService(TestSharingService::class.java).create().get().also(services::add)

    private class Result : MethodChannel.Result {
        var replies = 0
        var rawValue: Any? = null
        var value: Map<*, *>? = null
        var errorCode: String? = null
        override fun success(result: Any?) { replies += 1; rawValue = result; value = result as? Map<*, *> }
        override fun error(code: String, message: String?, details: Any?) { replies += 1; errorCode = code }
        override fun notImplemented() { fail("Unexpected unimplemented platform method") }
        fun assertSuccess(enabled: Boolean, running: Boolean) {
            assertEquals(1, replies)
            assertNull(errorCode)
            assertEquals(enabled, value?.get("enabled"))
            assertEquals(running, value?.get("running"))
        }
    }
}

/** Exercise the real Service lifecycle and locks without loading Flutter JNI in Robolectric. */
class TestSharingService : BackgroundSharingService() {
    var runtimeStarts = 0
    var failStartup = false
    var statusAtRuntimeStart: Map<String, Any?>? = null
    override fun startRuntime() {
        runtimeStarts += 1
        statusAtRuntimeStart = BackgroundSharing.get(applicationContext).status()
        if (failStartup) throw IllegalStateException("runtime failed")
    }
}

@Implements(NotificationManager::class)
class FailingSharingNotificationManager : ShadowNotificationManager() {
    @Implementation
    override fun notify(id: Int, notification: Notification) {
        if (failNotify) throw IllegalStateException("notification unavailable")
        super.notify(id, notification)
    }

    @Implementation
    override fun createNotificationChannel(channel: NotificationChannel) {
        if (failChannel) throw IllegalStateException("notification channel unavailable")
        super.createNotificationChannel(channel)
    }

    companion object {
        var failNotify = false
        var failChannel = false
    }
}
