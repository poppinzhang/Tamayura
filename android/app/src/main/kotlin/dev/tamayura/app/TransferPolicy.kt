package dev.tamayura.app

import java.security.MessageDigest

/** Pure helpers shared by scheduling/notifications and JVM tests. */
internal object TransferPolicy {
    fun jobId(taskId: String, allocated: Map<Int, String>, hash: (String) -> Int = ::hashId): Int {
        require(taskId.isNotBlank() && taskId.length <= 200) { "无效的下载任务 ID" }
        allocated.entries.firstOrNull { it.value == taskId }?.let { return it.key }
        var candidate = hash(taskId) and Int.MAX_VALUE
        if (candidate == 0) candidate = 1
        while (allocated.containsKey(candidate)) {
            candidate = if (candidate == Int.MAX_VALUE) 1 else candidate + 1
        }
        return candidate
    }

    private fun hashId(value: String): Int {
        val bytes = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return java.nio.ByteBuffer.wrap(bytes).int
    }

    fun progress(received: Long, total: Long): Int {
        if (total <= 0) return 0
        return (received.coerceIn(0, total).toDouble() / total * 1000).toInt()
    }

    fun previewSize(width: Int, height: Int, maximum: Int): Pair<Int, Int> {
        require(width > 0 && height > 0 && maximum in 1..2560) { "无效的预览尺寸" }
        val scale = minOf(1.0, maximum.toDouble() / maxOf(width, height))
        return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
    }
}

/** An old engine cannot release a newer run of the same task. */
internal class TransferRunGate {
    private var nextToken = 0L
    private val runs = mutableMapOf<String, Long>()

    @Synchronized fun acquire(taskId: String): Long? {
        if (runs.containsKey(taskId)) return null
        val token = ++nextToken
        runs[taskId] = token
        return token
    }

    @Synchronized fun release(taskId: String, token: Long): Boolean {
        if (runs[taskId] != token) return false
        runs.remove(taskId)
        return true
    }

    @Synchronized fun active(taskId: String): Boolean = runs.containsKey(taskId)
}

/** Cancelling while engine-drain callbacks are pending invalidates them. */
internal class TransferRequestGate {
    private val generations = mutableMapOf<String, Long>()
    @Synchronized fun ticket(taskId: String): Long = generations[taskId] ?: 0L
    @Synchronized fun cancel(taskId: String) { generations[taskId] = ticket(taskId) + 1 }
    @Synchronized fun current(taskId: String, expected: Long): Boolean = ticket(taskId) == expected
}
