package dev.tamayura.app

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.Signature
import android.content.pm.SigningInfo
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
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
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
@LooperMode(LooperMode.Mode.PAUSED)
class AppUpdateInstallerTest {
    private lateinit var application: Application
    private lateinit var updates: AppUpdateInstaller
    private lateinit var activity: Activity
    private lateinit var apk: File
    private lateinit var request: AppUpdateInstaller.Request

    @Before fun setUp() {
        application = RuntimeEnvironment.getApplication()
        updates = AppUpdateInstaller.get(application)
        application.getSharedPreferences("app-update", Context.MODE_PRIVATE).edit().clear().commit()
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        updates.resumed(activity)
        apk = File(updates.directory(), "update-fixture/Tamayura-0.8.0-android.apk").apply {
            parentFile!!.mkdirs()
            writeBytes(byteArrayOf(1, 2, 3, 4))
        }
        request = AppUpdateInstaller.Request(apk.path, checksum(apk), "0.8.0", 12)
        val installed = packageInfo("0.7.0", 11)
        shadowOf(application.packageManager).installPackage(installed)
        shadowOf(application.packageManager).setPackageArchiveInfo(apk.path, packageInfo("0.8.0", 12))
        shadowOf(application.packageManager).setCanRequestPackageInstalls(true)
    }

    @Test fun acceptsOnlyVerifiedNewerApkFromPrivateUpdateDirectory() {
        assertEquals(apk, updates.validate(request))
        val sibling = File(application.cacheDir, "elsewhere.apk").apply { writeBytes(apk.readBytes()) }
        assertFailure("UPDATE_INVALID_PACKAGE") { updates.validate(request.copy(path = sibling.path)) }
        val nested = File(updates.directory(), "nested/update.apk").apply {
            parentFile!!.mkdirs()
            writeBytes(apk.readBytes())
        }
        assertFailure("UPDATE_INVALID_PACKAGE") { updates.validate(request.copy(path = nested.path)) }
    }

    @Test fun rejectsSymlinksMissingFilesEmptyFilesAndInvalidHash() {
        val link = File(updates.directory(), "link.apk")
        Files.createSymbolicLink(link.toPath(), apk.toPath())
        assertFailure("UPDATE_INVALID_PACKAGE") { updates.validate(request.copy(path = link.path)) }
        val linkedDirectory = File(updates.directory(), "update-link")
        Files.createSymbolicLink(linkedDirectory.toPath(), apk.parentFile!!.toPath())
        assertFailure("UPDATE_INVALID_PACKAGE") {
            updates.validate(request.copy(path = File(linkedDirectory, apk.name).path))
        }
        assertFailure("UPDATE_CHECKSUM_MISMATCH") { updates.validate(request.copy(sha256 = "0".repeat(64))) }
        apk.writeBytes(byteArrayOf())
        assertFailure("UPDATE_INVALID_PACKAGE") { updates.validate(request) }
        apk.delete()
        assertFailure("UPDATE_INVALID_PACKAGE") { updates.validate(request) }
    }

    @Test fun rejectsAnotherApplicationWrongVersionAndWrongBuild() {
        val installed = packageInfo("0.7.0", 11)
        assertFailure("UPDATE_INVALID_PACKAGE") {
            AppUpdateInstaller.validateIdentity(request,
                packageInfo("0.8.0", 12).apply { packageName = "other.app" }, installed)
        }
        assertFailure("UPDATE_VERSION_MISMATCH") {
            AppUpdateInstaller.validateIdentity(request, packageInfo("0.8.1", 12), installed)
        }
        assertFailure("UPDATE_VERSION_MISMATCH") {
            AppUpdateInstaller.validateIdentity(request, packageInfo("0.8.0", 13), installed)
        }
        assertFailure("UPDATE_VERSION_MISMATCH") {
            AppUpdateInstaller.validateIdentity(request, packageInfo("0.8.0", 12), packageInfo("0.8.0", 12))
        }
    }

    @Test fun rejectsDifferentOrMissingSigningCertificates() {
        assertFailure("UPDATE_SIGNATURE_MISMATCH") {
            AppUpdateInstaller.validateIdentity(request,
                packageInfo("0.8.0", 12, "bbaa"), packageInfo("0.7.0", 11))
        }
        assertFailure("UPDATE_SIGNATURE_MISMATCH") {
            AppUpdateInstaller.validateIdentity(request,
                packageInfo("0.8.0", 12).apply { signingInfo = null }, packageInfo("0.7.0", 11))
        }
    }

    @Test fun rejectsInvalidArgumentsAndUnavailableForeground() {
        val invalid = Result()
        updates.handle(MethodCall("installUpdate", mapOf("path" to apk.path)), invalid)
        assertEquals("UPDATE_INVALID_ARGUMENT", invalid.code)
        updates.paused(activity)
        val background = install()
        assertEquals("UPDATE_ACTIVITY_UNAVAILABLE", background.code)
        assertTrue(application.packageManager.packageInstaller.mySessions.isEmpty())
    }

    @Test fun permissionRequestIsVisibleAndCanBeRetriedAfterAuthorization() {
        shadowOf(application.packageManager).setCanRequestPackageInstalls(false)
        val denied = install().await()
        assertEquals("UPDATE_PERMISSION_REQUIRED", denied.code)
        assertEquals("permissionRequired", updates.status()["state"])
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            shadowOf(activity).nextStartedActivity.action)
        assertTrue(application.packageManager.packageInstaller.mySessions.isEmpty())
        shadowOf(application.packageManager).setCanRequestPackageInstalls(true)
        assertEquals("started", install().await().value)
    }

    @Test fun commitsOneSessionAndRejectsConcurrentInstallAttempts() {
        val first = install()
        assertEquals("UPDATE_IN_PROGRESS", install().code)
        assertEquals("started", first.await().value)
        assertEquals(1, application.packageManager.packageInstaller.mySessions.size)
        assertEquals("UPDATE_IN_PROGRESS", install().code)
        assertEquals("started", updates.status()["state"])
    }

    @Test fun leavingForegroundDuringValidationDoesNotCommitSession() {
        val result = install()
        updates.paused(activity)
        assertEquals("UPDATE_ACTIVITY_UNAVAILABLE", result.await().code)
        assertTrue(application.packageManager.packageInstaller.mySessions.isEmpty())
    }

    @Test fun pendingConfirmationWaitsForForegroundThenLaunchesSystemUi() {
        install().await()
        updates.paused(activity)
        val confirmation = Intent("test.confirm.install")
        updates.receive(callback(PackageInstaller.STATUS_PENDING_USER_ACTION)
            .putExtra(Intent.EXTRA_INTENT, confirmation))
        assertEquals("pendingUserAction", updates.status()["state"])
        assertNull(shadowOf(activity).nextStartedActivity)
        updates.resumed(activity)
        assertEquals(confirmation.action, shadowOf(activity).nextStartedActivity.action)
        updates.resumed(activity)
        assertNull(shadowOf(activity).nextStartedActivity)
    }

    @Test fun cancellationAndInstallationErrorsArePersistentVisibleAndRetryable() {
        install().await()
        AppUpdateResultReceiver().onReceive(application, callback(PackageInstaller.STATUS_FAILURE_ABORTED))
        assertEquals("failed", updates.status()["state"])
        assertTrue(updates.status().getValue("message").contains("取消"))
        assertTrue(apk.isFile)
        assertEquals("started", install().await().value)
        updates.receive(callback(PackageInstaller.STATUS_FAILURE_STORAGE)
            .putExtra(PackageInstaller.EXTRA_STATUS_MESSAGE, "private path must never be shown"))
        assertTrue(updates.status().getValue("message").contains("空间不足"))
        assertFalse(updates.status().getValue("message").contains("private"))
    }

    @Test fun unknownAndStaleCallbacksCannotChangeCurrentUpdateState() {
        install().await()
        updates.receive(callback(PackageInstaller.STATUS_FAILURE).setAction("untrusted.action"))
        updates.receive(callback(PackageInstaller.STATUS_FAILURE)
            .putExtra(PackageInstaller.EXTRA_SESSION_ID, Int.MAX_VALUE))
        assertEquals("started", updates.status()["state"])
        updates.receive(callback(PackageInstaller.STATUS_FAILURE_ABORTED))
        updates.receive(callback(PackageInstaller.STATUS_SUCCESS))
        assertEquals("failed", updates.status()["state"])
    }

    @Test fun missingConfirmationIntentAbandonsSessionAndAllowsRetry() {
        install().await()
        updates.receive(callback(PackageInstaller.STATUS_PENDING_USER_ACTION))
        assertEquals("failed", updates.status()["state"])
        assertTrue(application.packageManager.packageInstaller.mySessions.isEmpty())
        assertEquals("started", install().await().value)
    }

    @Test fun restoredProcessRecoversSuccessfulOrInterruptedInstallation() {
        install().await()
        val preferences = application.getSharedPreferences("app-update", Context.MODE_PRIVATE)
        val sessionId = preferences.getInt("sessionId", -1)
        preferences.edit().putString("state", "pendingUserAction").commit()
        assertEquals("failed", updates.status()["state"])
        assertNull(application.packageManager.packageInstaller.getSessionInfo(sessionId))
        preferences.edit().putString("state", "started").commit()
        shadowOf(application.packageManager).installPackage(packageInfo("0.8.0", 12))
        assertEquals("succeeded", updates.status()["state"])
    }

    @Test fun missingSessionIsReportedAsInterruptedInsteadOfWaitingForever() {
        install().await()
        val session = application.packageManager.packageInstaller.mySessions.single()
        application.packageManager.packageInstaller.abandonSession(session.sessionId)
        assertEquals("failed", updates.status()["state"])
        assertTrue(updates.status().getValue("message").contains("中断"))
    }

    @Test fun successfulInstallationCleansOnlyItsOwnSourceAndEmptyStagingDirectory() {
        val unrelated = File(updates.directory(), "unrelated.apk").apply { writeBytes(byteArrayOf(5)) }
        install().await()
        updates.receive(callback(PackageInstaller.STATUS_SUCCESS))
        val deadline = System.nanoTime() + 10_000_000_000L
        while (apk.parentFile!!.exists() && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        assertEquals("succeeded", updates.status()["state"])
        assertFalse(apk.exists())
        assertFalse(apk.parentFile!!.exists())
        assertTrue(unrelated.isFile)
    }

    @Test fun processInterruptionBeforeSessionCommitCanBeRetried() {
        install().await()
        ReflectionHelpers.setField(updates, "committedSession", null)
        assertEquals("failed", updates.status()["state"])
        assertTrue(application.packageManager.packageInstaller.mySessions.isEmpty())
        assertTrue(apk.isFile)
        assertEquals("started", install().await().value)
    }

    private fun packageInfo(version: String, build: Long, signer: String = "aabb"): PackageInfo =
        PackageInfo().apply {
            packageName = application.packageName
            versionName = version
            setLongVersionCode(build)
            signingInfo = ReflectionHelpers.callConstructor(SigningInfo::class.java).also {
                shadowOf(it).setSignatures(arrayOf(Signature(signer)))
            }
        }

    private fun install(): Result = Result().also {
        updates.handle(MethodCall("installUpdate", mapOf("path" to request.path,
            "sha256" to request.sha256, "version" to request.version,
            "buildNumber" to request.buildNumber)), it)
    }

    private fun callback(status: Int): Intent = Intent(AppUpdateInstaller.RESULT_ACTION)
        .putExtra(PackageInstaller.EXTRA_SESSION_ID,
            application.getSharedPreferences("app-update", Context.MODE_PRIVATE).getInt("sessionId", -1))
        .putExtra(PackageInstaller.EXTRA_STATUS, status)

    private fun checksum(file: File): String = MessageDigest.getInstance("SHA-256")
        .digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    private fun assertFailure(code: String, operation: () -> Unit) {
        try {
            operation()
            fail("Expected $code")
        } catch (error: UpdateException) {
            assertEquals(code, error.code)
        }
    }

    private class Result : MethodChannel.Result {
        var value: Any? = null
        var code: String? = null
        var replies = 0

        override fun success(result: Any?) { value = result; replies++ }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            code = errorCode
            replies++
        }
        override fun notImplemented() { fail("Unexpected method") }

        fun await(): Result {
            val deadline = System.nanoTime() + 10_000_000_000L
            while (replies == 0 && System.nanoTime() < deadline) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(10)
            }
            assertEquals("Exactly one platform reply", 1, replies)
            return this
        }
    }
}
