package dev.tamayura.app

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.Context
import android.net.NetworkCapabilities
import android.os.PersistableBundle
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.LooperMode
import org.robolectric.annotation.RealObject
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowJobService
import org.robolectric.shadows.ShadowNetworkCapabilities
import org.robolectric.shadows.ShadowJobScheduler.ShadowJobSchedulerImpl
import org.robolectric.util.ReflectionHelpers

/** Exercise the real platform handler without starting a native Flutter engine. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@Config(sdk = [36], shadows = [RecordingJobServiceShadow::class, NamespacedJobSchedulerShadow::class])
@LooperMode(LooperMode.Mode.PAUSED)
class TransferNotificationTest(private val access: NotificationAccess) {
    enum class NotificationAccess { DENIED_PERMISSION, DISABLED_APP, DISABLED_CHANNEL, ALLOWED }

    private lateinit var application: Application
    private lateinit var activity: MainActivity
    private lateinit var scheduler: JobScheduler
    private lateinit var notifications: NotificationManager
    private var service: BackgroundTransferService? = null

    @Before fun setUp() {
        application = RuntimeEnvironment.getApplication()
        // Assertions use the Simplified Chinese resources.
        AppText.setLanguage(application, "zh")
        notifications = application.getSystemService(NotificationManager::class.java)
        if (access == NotificationAccess.DENIED_PERMISSION) {
            shadowOf(application).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        }
        shadowOf(notifications).setNotificationsEnabled(
            access != NotificationAccess.DENIED_PERMISSION && access != NotificationAccess.DISABLED_APP)
        notifications.createNotificationChannel(NotificationChannel(
            TransferScheduler.CHANNEL, "媒体下载",
            if (access == NotificationAccess.DISABLED_CHANNEL) NotificationManager.IMPORTANCE_NONE
            else NotificationManager.IMPORTANCE_LOW))
        scheduler = (application.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler)
            .forNamespace("tamayura.transfers")
        // Attach the Activity, but do not enter FlutterActivity.onCreate/native initialization.
        activity = Robolectric.buildActivity(MainActivity::class.java).get()
    }

    @After fun tearDown() {
        service?.let { current ->
            // Drain the service's bookkeeping without running the queued native engine startup.
            val sessions = ReflectionHelpers.getField<Map<Int, Any>>(current, "sessions")
            sessions.values.toList().forEach { session ->
                finish(current, session, success = false, error = null, cancelled = true, retry = false)
            }
        }
        scheduler.cancelAll()
    }

    @Test fun scheduleSucceedsWithoutRequestingNotificationPermission() {
        call("scheduleTransfer", "download").assertSuccess()

        val job = scheduler.allPendingJobs.single()
        assertEquals("download", job.extras.getString(TransferScheduler.TASK_ID))
        assertTrue(job.isUserInitiated)
        assertFalse(job.extras.getString(TransferScheduler.RUN_ID).isNullOrEmpty())
        assertNull(shadowOf(activity).lastRequestedPermission)
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())
    }

    @Test fun duplicateScheduleThenCancellationAndRetryRemainUsable() {
        call("scheduleTransfer", "download").assertSuccess()
        val original = scheduler.allPendingJobs.single()
        call("scheduleTransfer", "download").assertSuccess()
        assertEquals(1, scheduler.allPendingJobs.size)

        call("cancelTransfer", "download").assertSuccess()
        assertTrue(scheduler.allPendingJobs.isEmpty())
        call("scheduleTransfer", "download").assertSuccess()

        val retry = scheduler.allPendingJobs.single()
        assertEquals(original.id, retry.id)
        assertNotEquals(original.extras.getString(TransferScheduler.RUN_ID),
            retry.extras.getString(TransferScheduler.RUN_ID))
        assertNull(shadowOf(activity).lastRequestedPermission)
    }

    @Test fun downloadNetworkAcceptsLanWithOrWithoutVpnButNotCellular() {
        call("scheduleTransfer", "network-matching").assertSuccess()
        val request = requireNotNull(scheduler.allPendingJobs.single().requiredNetwork)

        fun network(transport: Int?, vpn: Boolean): NetworkCapabilities =
            ShadowNetworkCapabilities.newInstance().also { capabilities ->
                shadowOf(capabilities).apply {
                    addCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
                    addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                    // A normal LAN is not managed by Android's carrier VCN.
                    addCapability(ReflectionHelpers.getStaticField<Int>(
                        NetworkCapabilities::class.java, "NET_CAPABILITY_NOT_VCN_MANAGED"))
                    transport?.let { addTransportType(it) }
                    if (vpn) {
                        addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                        removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    } else {
                        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    }
                    // LAN transfers also work without validated Internet access.
                    removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                }
            }

        for (transport in listOf(NetworkCapabilities.TRANSPORT_WIFI,
                NetworkCapabilities.TRANSPORT_ETHERNET)) {
            val direct = network(transport, vpn = false)
            assertTrue("$request must accept $direct", request.canBeSatisfiedBy(direct))
            // Android reports the VPN transport together with its underlying LAN.
            assertTrue("VPN over LAN must not leave a download queued",
                request.canBeSatisfiedBy(network(transport, vpn = true)))
        }
        for (vpn in listOf(false, true)) {
            assertFalse(request.canBeSatisfiedBy(network(NetworkCapabilities.TRANSPORT_CELLULAR, vpn)))
        }
        assertFalse(request.canBeSatisfiedBy(network(null, vpn = true)))
        assertFalse(request.canBeSatisfiedBy(null))
    }

    @Test fun systemRejectionStillReportsSchedulingFailure() {
        val id = TransferPolicy.jobId("rejected", emptyMap())
        shadowOf(scheduler).failOnJob(id)

        val result = call("scheduleTransfer", "rejected")

        assertEquals(1, result.replies)
        assertEquals("TRANSFER_SCHEDULE_FAILED", result.errorCode)
        assertTrue(result.errorMessage?.contains("系统未接受下载任务") == true)
        assertTrue(scheduler.allPendingJobs.isEmpty())
        assertNull(shadowOf(activity).lastRequestedPermission)
    }

    @Test fun cancelReplyWaitsUntilTheOldNativeWriterIsDrained() {
        val current = Robolectric.buildService(BackgroundTransferService::class.java).create().get()
        service = current
        val params = Shadow.newInstanceOf(JobParameters::class.java).apply {
            ReflectionHelpers.setField(this, "jobId", 74)
            ReflectionHelpers.setField(this, "extras", PersistableBundle().apply {
                putString(TransferScheduler.TASK_ID, "draining-download")
                putString(TransferScheduler.RUN_ID, "run-1")
            })
        }
        assertTrue(current.onStartJob(params))
        val session = ReflectionHelpers.getField<Map<Int, Any>>(current, "sessions").getValue(74)
        ReflectionHelpers.setField(session, "ioCount", 1)
        val result = call("cancelTransfer", "draining-download")
        assertEquals(0, result.replies)
        finish(current, session, success = false, error = null, cancelled = true, retry = false)
        assertEquals("Engine disposal alone must not release a running save", 0, result.replies)
        ReflectionHelpers.setField(session, "ioCount", 0)
        current.javaClass.getDeclaredMethod("releaseIfDrained", session.javaClass)
            .apply { isAccessible = true }.invoke(current, session)
        result.assertSuccess()
    }

    @Test fun activeJobAlwaysAssociatesNotificationAndStoppedJobRespectsVisibility() {
        val current = Robolectric.buildService(BackgroundTransferService::class.java).create().get()
        service = current
        val params = Shadow.newInstanceOf(JobParameters::class.java).apply {
            ReflectionHelpers.setField(this, "jobId", 71)
            ReflectionHelpers.setField(this, "extras", PersistableBundle().apply {
                putString(TransferScheduler.TASK_ID, "service-download")
                putString(TransferScheduler.RUN_ID, "run-1")
            })
            ReflectionHelpers.setField(this, "mStopReason", JobParameters.STOP_REASON_CONSTRAINT_CONNECTIVITY)
        }

        assertTrue(current.onStartJob(params))

        val jobService = Shadow.extract<RecordingJobServiceShadow>(current)
        assertEquals(1, jobService.associations.size)
        val association = jobService.associations.single()
        assertSame(params, association.params)
        assertEquals(71, association.id)
        assertEquals(TransferScheduler.CHANNEL, association.notification.channelId)
        assertTrue(association.notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())

        assertTrue(current.onStopJob(params))

        assertEquals(1, jobService.associations.size)
        val visible = shadowOf(notifications).getNotification(71)
        if (access == NotificationAccess.ALLOWED) {
            assertNotNull(visible)
            assertEquals("下载暂停，等待局域网恢复", visible.extras.getString(Notification.EXTRA_TEXT))
        } else {
            assertNull(visible)
        }
    }

    @Test fun peerOutageAsksJobSchedulerToRetryWithBackoff() {
        val current = Robolectric.buildService(BackgroundTransferService::class.java).create().get()
        service = current
        val params = Shadow.newInstanceOf(JobParameters::class.java).apply {
            ReflectionHelpers.setField(this, "jobId", 72)
            ReflectionHelpers.setField(this, "extras", PersistableBundle().apply {
                putString(TransferScheduler.TASK_ID, "outage-download")
                putString(TransferScheduler.RUN_ID, "run-1")
            })
        }
        assertTrue(current.onStartJob(params))
        val session = ReflectionHelpers.getField<Map<Int, Any>>(current, "sessions").getValue(72)

        finish(current, session, success = false, error = "暂时连不上这台设备；稍后会自动重试",
            cancelled = false, retry = true)

        val jobService = Shadow.extract<RecordingJobServiceShadow>(current)
        assertTrue(jobService.getIsJobFinished())
        assertTrue("A temporarily unreachable peer must use JobScheduler backoff",
            jobService.getIsRescheduleNeeded())
        assertEquals("对端暂时不可用，稍后自动重试",
            jobService.associations.last().notification.extras.getString(Notification.EXTRA_TEXT))
        assertTrue(ReflectionHelpers.getField<Map<Int, Any>>(current, "sessions").isEmpty())
    }

    @Test fun ordinaryFailureFinishesWithoutReschedule() {
        val current = Robolectric.buildService(BackgroundTransferService::class.java).create().get()
        service = current
        val params = Shadow.newInstanceOf(JobParameters::class.java).apply {
            ReflectionHelpers.setField(this, "jobId", 73)
            ReflectionHelpers.setField(this, "extras", PersistableBundle().apply {
                putString(TransferScheduler.TASK_ID, "failed-download")
                putString(TransferScheduler.RUN_ID, "run-1")
            })
        }
        assertTrue(current.onStartJob(params))
        val session = ReflectionHelpers.getField<Map<Int, Any>>(current, "sessions").getValue(73)

        finish(current, session, success = false, error = "对端文件已删除或不可访问，请刷新相册",
            cancelled = false, retry = false)

        val jobService = Shadow.extract<RecordingJobServiceShadow>(current)
        assertTrue(jobService.getIsJobFinished())
        assertFalse(jobService.getIsRescheduleNeeded())
    }

    private fun finish(service: BackgroundTransferService, session: Any, success: Boolean, error: String?,
                       cancelled: Boolean, retry: Boolean) {
        val flag = Boolean::class.javaPrimitiveType
        service.javaClass.getDeclaredMethod("finish", session.javaClass, flag, String::class.java, flag, flag)
            .apply { isAccessible = true }.invoke(service, session, success, error, cancelled, retry)
    }

    private fun call(method: String, taskId: String): Result = Result().also { result ->
        MainActivity::class.java.getDeclaredMethod("handleMethod", MethodCall::class.java,
            MethodChannel.Result::class.java).apply { isAccessible = true }
            .invoke(activity, MethodCall(method, mapOf("taskId" to taskId)), result)
    }

    private class Result : MethodChannel.Result {
        var replies = 0
        var errorCode: String? = null
        var errorMessage: String? = null

        override fun success(result: Any?) { replies += 1 }
        override fun error(code: String, message: String?, details: Any?) {
            replies += 1
            errorCode = code
            errorMessage = message
        }
        override fun notImplemented() { fail("Unexpected unimplemented platform method") }
        fun assertSuccess() {
            assertEquals("The download must resolve immediately without a permission callback", 1, replies)
            assertNull(errorMessage, errorCode)
        }
    }

    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun parameters(): List<Array<Any>> = NotificationAccess.entries.map { arrayOf(it) }
    }
}

/** Observe the mandatory UIDT association separately from ordinary NotificationManager posts. */
@Implements(JobService::class)
class RecordingJobServiceShadow : ShadowJobService() {
    data class Association(val params: JobParameters, val id: Int, val notification: Notification)
    val associations = mutableListOf<Association>()

    @Implementation
    override fun setNotification(params: JobParameters, id: Int, notification: Notification, policy: Int) {
        associations.add(Association(params, id, notification))
    }
}

/** Robolectric 4.16 models job storage per instance but does not yet shadow forNamespace. */
@Implements(className = "android.app.JobSchedulerImpl", isInAndroidSdk = false)
class NamespacedJobSchedulerShadow : ShadowJobSchedulerImpl() {
    @RealObject private lateinit var scheduler: JobScheduler
    private val namespaces = mutableMapOf<String, JobScheduler>()

    @Implementation
    fun forNamespace(namespace: String): JobScheduler = namespaces.getOrPut(namespace) {
        Shadow.newInstanceOf(scheduler.javaClass)
    }
}
