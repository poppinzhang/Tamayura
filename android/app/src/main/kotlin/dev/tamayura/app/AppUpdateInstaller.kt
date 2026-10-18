package dev.tamayura.app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.concurrent.Executors

internal class AppUpdateInstaller private constructor(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val preferences = context.getSharedPreferences("app-update", Context.MODE_PRIVATE)
    private val installer get() = context.packageManager.packageInstaller
    private var foreground: Activity? = null
    private var preparing = false
    private var pendingAction: Intent? = null
    private var confirmationLaunched = false
    private var committedSession: Int? = null
    private var cleanupScheduled = false

    private fun text(id: Int): String = AppText.get(context, id)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "updateDirectory" -> worker.execute {
                    try {
                        val path = directory().absolutePath
                        main.post { result.success(path) }
                    } catch (_: Exception) {
                        main.post { result.error("UPDATE_STORAGE_FAILED", text(R.string.update_error_storage_directory), null) }
                    }
                }
                "updateStatus" -> result.success(status())
                "installUpdate" -> install(Request.from(call), result)
                else -> result.notImplemented()
            }
        } catch (error: UpdateException) {
            result.error(error.code, AppText.message(context, error), null)
        } catch (_: Exception) {
            result.error("UPDATE_FAILED", text(R.string.update_error_failed), null)
        }
    }

    fun resumed(activity: Activity) {
        foreground = activity
        try { status() } catch (_: Exception) { }
        launchPendingAction()
    }

    fun paused(activity: Activity) {
        if (foreground === activity) foreground = null
    }

    fun directory(): File {
        val directory = File(context.cacheDir, "app-updates")
        if ((!directory.exists() && !directory.mkdirs()) ||
            !Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            throw UpdateException("UPDATE_STORAGE_FAILED", R.string.update_error_storage_directory)
        }
        return directory.canonicalFile
    }

    fun validate(request: Request): File {
        val file = File(request.path)
        if (!validSourceLocation(file) || !Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) ||
            file.length() <= 0 || file.extension.lowercase() != "apk") {
            throw UpdateException("UPDATE_INVALID_PACKAGE", R.string.update_error_invalid_file)
        }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        if (digest.digest().hex() != request.sha256) {
            throw UpdateException("UPDATE_CHECKSUM_MISMATCH", R.string.update_error_checksum)
        }
        val flags = PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong())
        @Suppress("DEPRECATION")
        val archive = context.packageManager.getPackageArchiveInfo(file.absolutePath,
            PackageManager.GET_SIGNING_CERTIFICATES)
            ?: throw UpdateException("UPDATE_INVALID_PACKAGE", R.string.update_error_unrecognized)
        val installed = context.packageManager.getPackageInfo(context.packageName, flags)
        validateIdentity(request, archive, installed)
        return file
    }

    private fun validSourceLocation(file: File): Boolean {
        val root = directory()
        val parent = file.parentFile
        val canonicalParent = parent?.canonicalFile
        return parent != null &&
            Files.isDirectory(parent.toPath(), LinkOption.NOFOLLOW_LINKS) &&
            parent.absoluteFile.toPath().normalize() == canonicalParent?.toPath() &&
            (canonicalParent == root || (canonicalParent?.parentFile == root &&
                canonicalParent.name.startsWith("update-")))
    }

    private fun install(request: Request, result: MethodChannel.Result) {
        val state = status()["state"]
        if (preparing || state == "started" || state == "pendingUserAction") {
            throw UpdateException("UPDATE_IN_PROGRESS", R.string.update_error_in_progress)
        }
        requireForeground()
        preparing = true
        worker.execute {
            try {
                val file = validate(request)
                main.post { afterValidation(request, file, result) }
            } catch (error: Exception) {
                main.post { fail(result, error) }
            }
        }
    }

    private fun afterValidation(request: Request, file: File, result: MethodChannel.Result) {
        try {
            val activity = requireForeground()
            if (!context.packageManager.canRequestPackageInstalls()) {
                setState("permissionRequired", text(R.string.update_permission_required))
                activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")))
                preparing = false
                result.error("UPDATE_PERMISSION_REQUIRED", text(R.string.update_permission_required), null)
                return
            }
            worker.execute {
                var sessionId: Int? = null
                try {
                    installer.mySessions.forEach { abandon(it.sessionId) }
                    val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                        setAppPackageName(context.packageName)
                        setSize(file.length())
                        setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE)
                        setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                    }
                    val created = installer.createSession(params)
                    sessionId = created
                    installer.openSession(created).use { session ->
                        session.openWrite("base.apk", 0, file.length()).use { output ->
                            val digest = MessageDigest.getInstance("SHA-256")
                            file.inputStream().use { input ->
                                val buffer = ByteArray(128 * 1024)
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    output.write(buffer, 0, count)
                                    digest.update(buffer, 0, count)
                                }
                            }
                            if (digest.digest().hex() != request.sha256) {
                                throw UpdateException("UPDATE_CHECKSUM_MISMATCH", R.string.update_error_file_changed)
                            }
                            session.fsync(output)
                        }
                    }
                    main.post { commit(created, request, result) }
                } catch (error: Exception) {
                    sessionId?.let { abandon(it) }
                    main.post { fail(result, error) }
                }
            }
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun commit(sessionId: Int, request: Request, result: MethodChannel.Result) {
        try {
            requireForeground()
            val callback = PendingIntent.getBroadcast(context, sessionId,
                Intent(context, AppUpdateResultReceiver::class.java).setAction(RESULT_ACTION),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            if (!preferences.edit().clear().putInt("sessionId", sessionId)
                    .putLong("buildNumber", request.buildNumber).putString("version", request.version)
                    .putString("sourcePath", request.path)
                    .putString("state", "started").commit()) {
                throw UpdateException("UPDATE_STORAGE_FAILED", R.string.update_error_state_storage)
            }
            installer.openSession(sessionId).use { it.commit(callback.intentSender) }
            committedSession = sessionId
            preparing = false
            result.success("started")
        } catch (error: Exception) {
            abandon(sessionId)
            fail(result, error)
        }
    }

    fun receive(intent: Intent) {
        if (intent.action != RESULT_ACTION ||
            !preferences.contains("sessionId") ||
            intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != preferences.getInt("sessionId", -2)) return
        val state = preferences.getString("state", "idle")
        if (state != "started" && state != "pendingUserAction") return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                pendingAction = intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                confirmationLaunched = false
                if (pendingAction == null) {
                    abandon(preferences.getInt("sessionId", -1))
                    setState("failed", text(R.string.update_error_no_confirmation))
                } else {
                    setState("pendingUserAction", text(R.string.update_pending_user_action))
                    launchPendingAction()
                }
            }
            PackageInstaller.STATUS_SUCCESS -> setState("succeeded", text(R.string.update_installed_reopen))
            PackageInstaller.STATUS_FAILURE_ABORTED -> setState("failed", text(R.string.update_install_aborted))
            PackageInstaller.STATUS_FAILURE_STORAGE -> setState("failed", text(R.string.update_install_storage))
            PackageInstaller.STATUS_FAILURE_CONFLICT -> setState("failed", text(R.string.update_install_conflict))
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> setState("failed", text(R.string.update_install_incompatible))
            PackageInstaller.STATUS_FAILURE_BLOCKED -> setState("failed", text(R.string.update_install_blocked))
            else -> setState("failed", text(R.string.update_install_failed))
        }
        if (preferences.getString("state", null) == "failed") {
            abandon(preferences.getInt("sessionId", -1))
        }
    }

    private fun launchPendingAction() {
        val activity = foreground?.takeUnless { it.isFinishing || it.isDestroyed } ?: return
        val intent = pendingAction ?: return
        try {
            activity.startActivity(intent)
            pendingAction = null
            confirmationLaunched = true
        } catch (_: Exception) {
            pendingAction = null
            abandon(preferences.getInt("sessionId", -1))
            setState("failed", text(R.string.update_error_confirmation_launch))
        }
    }

    fun status(): Map<String, String> {
        val state = preferences.getString("state", "idle") ?: "idle"
        if (!preparing && (state == "started" || state == "pendingUserAction")) {
            val expected = preferences.getLong("buildNumber", Long.MAX_VALUE)
            val installed = context.packageManager.getPackageInfo(context.packageName,
                PackageManager.PackageInfoFlags.of(0)).longVersionCode
            val sessionId = preferences.getInt("sessionId", -1)
            val session = installer.getSessionInfo(sessionId)
            if (installed >= expected) {
                setState("succeeded", text(R.string.update_installed))
            } else if (session == null) {
                setState("failed", text(R.string.update_install_interrupted))
            } else if (!session.isSealed && committedSession != sessionId) {
                abandon(sessionId)
                setState("failed", text(R.string.update_preparation_interrupted))
            } else if (state == "pendingUserAction" && pendingAction == null && !confirmationLaunched) {
                abandon(preferences.getInt("sessionId", -1))
                setState("failed", text(R.string.update_confirmation_interrupted))
            }
        }
        cleanupSuccessfulSource()
        return buildMap {
            put("state", preferences.getString("state", "idle") ?: "idle")
            preferences.getString("message", null)?.let { put("message", it) }
        }
    }

    private fun requireForeground(): Activity = foreground?.takeUnless { it.isFinishing || it.isDestroyed }
        ?: throw UpdateException("UPDATE_ACTIVITY_UNAVAILABLE", R.string.update_error_activity_unavailable)

    private fun setState(state: String, message: String) {
        if (state != "pendingUserAction") {
            pendingAction = null
            confirmationLaunched = false
        }
        preferences.edit().putString("state", state).putString("message", message).commit()
        cleanupSuccessfulSource()
    }

    private fun cleanupSuccessfulSource() {
        if (cleanupScheduled || preferences.getString("state", null) != "succeeded") return
        val path = preferences.getString("sourcePath", null) ?: return
        cleanupScheduled = true
        worker.execute {
            try {
                val file = File(path)
                if (validSourceLocation(file) && (!Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                        (Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) && file.delete()))) {
                    val parent = file.parentFile
                    if (parent != null && parent.canonicalFile != directory() && parent.list()?.isEmpty() == true) {
                        parent.delete()
                    }
                    preferences.edit().remove("sourcePath").commit()
                }
            } catch (_: Exception) { }
            finally { main.post { cleanupScheduled = false } }
        }
    }

    private fun fail(result: MethodChannel.Result, error: Exception) {
        preparing = false
        val known = error as? UpdateException
        val message = known?.let { AppText.message(context, it) } ?: text(R.string.update_error_prepare)
        setState("failed", message)
        result.error(known?.code ?: "UPDATE_FAILED", message, null)
    }

    private fun abandon(sessionId: Int) {
        if (sessionId >= 0) try { installer.abandonSession(sessionId) } catch (_: Exception) { }
    }

    data class Request(val path: String, val sha256: String, val version: String, val buildNumber: Long) {
        companion object {
            fun from(call: MethodCall): Request {
                val path = call.argument<String>("path")
                val sha256 = call.argument<String>("sha256")?.lowercase()
                val version = call.argument<String>("version")
                val buildNumber = call.argument<Number>("buildNumber")?.toLong()
                if (path.isNullOrBlank() || sha256 == null || !sha256.matches(Regex("[a-f0-9]{64}")) ||
                    version.isNullOrBlank() || buildNumber == null || buildNumber <= 0) {
                    throw UpdateException("UPDATE_INVALID_ARGUMENT", R.string.update_error_invalid_argument)
                }
                return Request(path, sha256, version, buildNumber)
            }
        }
    }

    companion object {
        const val RESULT_ACTION = "dev.tamayura.app.UPDATE_RESULT"
        private var instance: AppUpdateInstaller? = null

        fun get(context: Context): AppUpdateInstaller {
            val application = context.applicationContext
            return instance?.takeIf { it.context === application }
                ?: AppUpdateInstaller(application).also { instance = it }
        }

        fun validateIdentity(request: Request, archive: PackageInfo, installed: PackageInfo) {
            if (archive.packageName != installed.packageName) {
                throw UpdateException("UPDATE_INVALID_PACKAGE", R.string.update_error_wrong_package)
            }
            if (archive.versionName != request.version || archive.longVersionCode != request.buildNumber ||
                archive.longVersionCode <= installed.longVersionCode) {
                throw UpdateException("UPDATE_VERSION_MISMATCH", R.string.update_error_version)
            }
            val expected = installed.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet()
            val actual = archive.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet()
            if (expected.isNullOrEmpty() || actual.isNullOrEmpty() || expected != actual) {
                throw UpdateException("UPDATE_SIGNATURE_MISMATCH", R.string.update_error_signature)
            }
        }

        private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
    }
}

/** The code is reported to Dart; the text is resolved in the interface language. */
internal class UpdateException(val code: String, override val textId: Int) : Exception(code), LocalizedText

class AppUpdateResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AppUpdateInstaller.get(context).receive(intent)
    }
}
