package dev.tamayura.app

import java.io.FileNotFoundException
import java.util.concurrent.CancellationException

/** Small independently testable boundary between a scan and file serving. */
internal class SharedCatalog<T> {
    data class Entry<T>(val directory: String, val value: T)
    data class Snapshot<T>(val generation: Long, val directory: String, val entry: T)

    // Changes only when sharing stops or a grant fails; every read then ends.
    private var generation = 0L
    // The latest scan ticket; starting another scan or clearing cancels older ones.
    private var scan = 0L
    private var published = false
    private var entries: Map<String, Entry<T>> = emptyMap()

    /** Stops serving every file and cancels running scans. */
    @Synchronized fun clear(): Long {
        generation += 1
        scan += 1
        published = false
        entries = emptyMap()
        return scan
    }

    /**
     * Starts a rescan while the previous catalogue keeps serving, so peers'
     * transfers survive a refresh. Roots that are no longer shared stop at once.
     */
    @Synchronized fun beginScan(directories: Set<String>): Long {
        scan += 1
        entries = entries.filterValues { it.directory in directories }
        return scan
    }

    @Synchronized fun assertScan(ticket: Long) {
        if (scan != ticket) throw CancellationException("共享目录已改变，请重新扫描")
    }

    @Synchronized fun publish(ticket: Long, entries: Map<String, Entry<T>>) {
        assertScan(ticket)
        require(entries.values.all { it.directory.isNotBlank() }) { "共享文件必须保留所属目录授权" }
        this.entries = entries.toMap()
        published = true
    }

    /** A failed current scan leaves nothing servable, as a revoked grant would. */
    @Synchronized fun failScan(ticket: Long) {
        if (scan == ticket) clear()
    }

    @Synchronized fun lookup(id: String): Snapshot<T> {
        if (!published) throw SecurityException("当前没有共享目录")
        val entry = entries[id] ?: throw FileNotFoundException("文件已删除或不在当前共享目录中")
        return Snapshot(generation, entry.directory, entry.value)
    }

    /** A read may finish only while sharing continues and its file stays published. */
    @Synchronized fun assertCurrent(id: String, snapshot: Snapshot<T>) {
        if (!isCurrent(id, snapshot)) {
            throw CancellationException("共享目录已改变，请重新扫描")
        }
    }

    /** Only a failure from a still-published file can revoke sharing. */
    @Synchronized fun revoke(id: String, snapshot: Snapshot<T>) {
        if (isCurrent(id, snapshot)) clear()
    }

    // Call only while holding this catalogue's monitor.
    private fun isCurrent(id: String, snapshot: Snapshot<T>): Boolean =
        generation == snapshot.generation && entries[id] == Entry(snapshot.directory, snapshot.entry)
}
