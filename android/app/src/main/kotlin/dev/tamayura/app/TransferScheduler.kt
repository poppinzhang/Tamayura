package dev.tamayura.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.PersistableBundle
import java.io.File

internal object TransferScheduler {
    const val CHANNEL = "tamayura-transfers"
    const val TASK_ID = "taskId"
    const val RUN_ID = "runId"
    private const val NAMESPACE = "tamayura.transfers"
    private val requests = TransferRequestGate()

    fun requestTicket(taskId: String): Long = requests.ticket(taskId)
    fun requestCurrent(taskId: String, ticket: Long): Boolean = requests.current(taskId, ticket)

    private fun scheduler(context: Context): JobScheduler =
        (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).forNamespace(NAMESPACE)

    // Recreating an existing channel renames it in the current language.
    fun ensureNotificationChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,
            AppText.get(context, R.string.transfer_channel_name), NotificationManager.IMPORTANCE_LOW).apply {
            description = AppText.get(context, R.string.transfer_channel_description)
        })
    }

    fun notificationsEnabled(context: Context): Boolean {
        ensureNotificationChannel(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        return manager.areNotificationsEnabled() &&
            manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    @Synchronized private fun jobId(context: Context, taskId: String): Int {
        val preferences = context.getSharedPreferences("tamayura-transfer-identifiers", Context.MODE_PRIVATE)
        val allocated = preferences.all.mapNotNull { (key, value) ->
            key.removePrefix("job_").toIntOrNull()?.let { id -> (value as? String)?.let { id to it } }
        }.toMap()
        val id = TransferPolicy.jobId(taskId, allocated)
        if (allocated[id] != taskId) {
            check(preferences.edit().putString("job_$id", taskId).commit()) {
                AppText.get(context, R.string.transfer_error_job_id)
            }
        }
        return id
    }

    /** Called from the visible Activity, including after an old engine drains. */
    fun schedule(context: Context, taskId: String) {
        val id = jobId(context, taskId)
        val scheduler = scheduler(context)
        if (scheduler.getPendingJob(id)?.extras?.getString(TASK_ID) == taskId) return
        val network = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            .build()
        val job = JobInfo.Builder(id, ComponentName(context, BackgroundTransferService::class.java))
            .setUserInitiated(true)
            .setRequiredNetwork(network)
            .setExtras(PersistableBundle().apply {
                putString(TASK_ID, taskId)
                putString(RUN_ID, java.util.UUID.randomUUID().toString())
            })
            .setBackoffCriteria(10_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .build()
        check(scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS) {
            AppText.get(context, R.string.transfer_error_rejected)
        }
    }

    fun cancel(context: Context, taskId: String) {
        require(taskId.isNotBlank() && taskId.length <= 200)
        requests.cancel(taskId)
        BackgroundTransferService.cancelRunning(taskId)
        val scheduler = scheduler(context)
        scheduler.allPendingJobs.filter { it.extras.getString(TASK_ID) == taskId }
            .forEach { scheduler.cancel(it.id) }
    }

    fun scheduledIds(context: Context): List<String> = scheduler(context).allPendingJobs
        .mapNotNull { it.extras.getString(TASK_ID) }.distinct()

    fun directory(context: Context): String {
        val path = File(context.filesDir, "transfer-staging")
        check(path.isDirectory || path.mkdirs()) { AppText.get(context, R.string.transfer_error_staging) }
        return path.absolutePath
    }
}
