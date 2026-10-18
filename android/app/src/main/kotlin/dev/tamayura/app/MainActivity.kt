package dev.tamayura.app

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newFixedThreadPool(2)
    private val runtime get() = AndroidRuntime.get(applicationContext)
    private var pickerResult: MethodChannel.Result? = null
    private var alive = true

    override fun provideFlutterEngine(context: Context): FlutterEngine = runtime.engine()

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // AndroidRuntime registered plugins and channels before executing Dart.
        runtime.activity = this
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (runtime.activity === this) runtime.activity = null
    }

    override fun onResume() {
        super.onResume()
        BackgroundSharing.get(applicationContext).restore()
        AppUpdateInstaller.get(applicationContext).resumed(this)
    }

    override fun onPause() {
        AppUpdateInstaller.get(applicationContext).paused(this)
        super.onPause()
    }

    // Kept as the Activity-facing entry for callers that need an attached UI.
    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) =
        runtime.handleMethod(call, result, this)

    internal fun handleUiMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDirectory" -> pickDirectory(result)
            "share", "open" -> launchDocument(call.requiredString("uri"),
                call.requiredString("mimeType"), call.method == "share", result)
            "openBatteryOptimizationSettings" -> {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    internal fun requestSharingNotificationPermission() {
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
        }
    }

    private fun text(id: Int): String = AppText.get(this, id)

    private fun MethodCall.requiredString(key: String): String = argument<String>(key)
        ?.takeIf { it.isNotBlank() } ?: throw IllegalArgumentException("Missing $key")

    @Suppress("DEPRECATION")
    private fun pickDirectory(result: MethodChannel.Result) {
        check(pickerResult == null) { text(R.string.error_picker_open) }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        pickerResult = result
        try { startActivityForResult(intent, DIRECTORY_REQUEST) }
        catch (error: Exception) { pickerResult = null; throw error }
    }

    @Deprecated("Android activity result callback required by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != DIRECTORY_REQUEST) return
        val result = pickerResult ?: return
        pickerResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        try {
            val flags = (data?.flags ?: 0) and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            require(flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
                text(R.string.error_directory_unreadable)
            }
            contentResolver.takePersistableUriPermission(uri, flags)
            runtime.background(result) {
                mapOf("uri" to uri.toString(), "name" to runtime.media.directoryName(uri))
            }
        } catch (error: Exception) { runtime.report(result, error) }
    }

    private fun launchDocument(value: String, mimeType: String, share: Boolean, result: MethodChannel.Result) {
        workers.execute {
            try {
                val uri = Uri.parse(value)
                require(uri.scheme == "content" && DocumentsContract.isDocumentUri(this, uri)) {
                    text(R.string.error_document_uri)
                }
                // A chooser can open even when its URI is stale. Validate before
                // reporting success so Dart can discard stale download records.
                val descriptor = contentResolver.openFileDescriptor(uri, "r")
                    ?: throw java.io.FileNotFoundException(text(R.string.error_download_missing))
                descriptor.use { /* Opening verifies existence and current read permission. */ }
                val intent = if (share) Intent(Intent.ACTION_SEND).apply {
                    type = mimeType
                    putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = ClipData.newRawUri("media", uri)
                } else Intent(Intent.ACTION_VIEW).apply { setDataAndType(uri, mimeType) }
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                main.post {
                    if (alive) {
                        try {
                            startActivity(if (share) {
                                Intent.createChooser(intent, text(R.string.share_chooser_title))
                            } else intent)
                            result.success(null)
                        } catch (error: Exception) { runtime.report(result, error) }
                    } else result.error("ACTIVITY_CLOSED", text(R.string.error_activity_closed), null)
                }
            } catch (error: Exception) {
                main.post { runtime.report(result, error) }
            }
        }
    }

    override fun onDestroy() {
        alive = false
        AppUpdateInstaller.get(applicationContext).paused(this)
        pickerResult?.error("ACTIVITY_CLOSED", text(R.string.error_activity_closed), null)
        pickerResult = null
        workers.shutdown()
        // The service can continue using media, discovery and the process-owned engine.
        super.onDestroy()
    }

    companion object {
        private const val DIRECTORY_REQUEST = 4201
        private const val NOTIFICATION_REQUEST = 4202
    }
}
