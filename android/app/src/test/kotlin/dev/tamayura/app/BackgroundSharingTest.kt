package dev.tamayura.app

import android.app.Application
import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Looper
import io.flutter.plugin.common.EventChannel
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
import org.robolectric.annotation.LooperMode
import org.robolectric.shadows.ShadowPowerManager
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

    @Test fun enableAcknowledgesServiceWithNotificationAndReleasesEverythingOnDisable() {
        val result = Result()
        sharing.setEnabled(true, result)
        assertEquals(0, result.replies)
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        val service = newService()
        assertEquals(Service.START_STICKY, service.onStartCommand(Intent(), 0, 1))
        result.assertSuccess(true, true)
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertEquals(1, service.runtimeStarts)
        val notification = shadowOf(service).lastForegroundNotification
        assertEquals(BackgroundSharingService.CHANNEL, notification.channelId)
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals("停止共享", notification.actions.single().title)
        assertEquals(true, service.statusAtRuntimeStart?.get("running"))
        val disabled = Result()
        sharing.setEnabled(false, disabled)
        disabled.assertSuccess(false, false)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertTrue(shadowOf(service).isForegroundStopped)
        assertEquals(false, events.last()["enabled"])
        assertEquals(false, events.last()["running"])
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

    @Test fun stickyRestartRestoresAnEnabledServiceAndItsLock() {
        sharing.setEnabled(true)
        val original = newService()
        original.onStartCommand(Intent(), 0, 1)
        original.onDestroy()
        assertEquals(true, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        val restarted = newService()
        assertEquals(Service.START_STICKY, restarted.onStartCommand(null, 0, 2))
        assertEquals(true, sharing.status()["running"])
        assertEquals(1, restarted.runtimeStarts)
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
    }

    @Test fun failedRuntimeStartupRollsBackAndReportsSingleError() {
        val result = Result()
        sharing.setEnabled(true, result)
        val service = newService().apply { failStartup = true }
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertEquals(1, result.replies)
        assertEquals("BACKGROUND_SHARING_FAILED", result.errorCode)
        assertEquals(false, sharing.status()["enabled"])
        assertEquals(false, sharing.status()["running"])
        assertEquals("runtime failed", sharing.status()["error"])
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertTrue(shadowOf(service).isForegroundStopped)
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

    @Test fun serviceStartTimeoutRollsBackAndDoesNotLeavePendingMethodCalls() {
        val result = Result()
        sharing.setEnabled(true, result)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(11))
        assertEquals(1, result.replies)
        assertEquals("BACKGROUND_SHARING_FAILED", result.errorCode)
        assertEquals(false, sharing.status()["enabled"])
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
        val lock = ShadowPowerManager.getLatestWakeLock()
        service.onStartCommand(Intent(), 0, 2)
        assertSame(lock, ShadowPowerManager.getLatestWakeLock())
        first.assertSuccess(true, true)
        second.assertSuccess(true, true)
        sharing.setEnabled(false)
        assertFalse(lock.isHeld)
    }

    private fun newService(): TestSharingService =
        Robolectric.buildService(TestSharingService::class.java).create().get().also(services::add)

    private class Result : MethodChannel.Result {
        var replies = 0
        var value: Map<*, *>? = null
        var errorCode: String? = null
        override fun success(result: Any?) { replies += 1; value = result as Map<*, *> }
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
