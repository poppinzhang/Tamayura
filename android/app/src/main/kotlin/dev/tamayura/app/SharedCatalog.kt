package dev.tamayura.app

import java.io.FileNotFoundException
import java.util.concurrent.CancellationException

internal class CatalogChangedException :
    CancellationException("Shared directories changed"), LocalizedText {
    override val textId = R.string.error_scan_cancelled
}

internal class NotSharingException : SecurityException("No directory is shared"), LocalizedText {
    override val textId = R.string.error_no_shared_directory
}

internal class UnsharedFileException : FileNotFoundException("The file is not shared"), LocalizedText {
    override val textId = R.string.error_shared_file_missing
}

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
        if (scan != ticket) throw CatalogChangedException()
    }

    @Synchronized fun publish(ticket: Long, entries: Map<String, Entry<T>>) {
        assertScan(ticket)
        if (entries.values.any { it.directory.isBlank() }) {
            throw InvalidArgumentException(R.string.error_shared_file_authorization,
                "Shared files must keep their directory grant")
        }
        this.entries = entries.toMap()
        published = true
    }

    /** A failed current scan leaves nothing servable, as a revoked grant would. */
    @Synchronized fun failScan(ticket: Long) {
        if (scan == ticket) clear()
    }

    @Synchronized fun lookup(id: String): Snapshot<T> {
        if (!published) throw NotSharingException()
        val entry = entries[id] ?: throw UnsharedFileException()
        return Snapshot(generation, entry.directory, entry.value)
    }

    /** A read may finish only while sharing continues and its file stays published. */
    @Synchronized fun assertCurrent(id: String, snapshot: Snapshot<T>) {
        if (!isCurrent(id, snapshot)) throw CatalogChangedException()
    }

    /** Only a failure from a still-published file can revoke sharing. */
    @Synchronized fun revoke(id: String, snapshot: Snapshot<T>) {
        if (isCurrent(id, snapshot)) clear()
    }

    // Call only while holding this catalogue's monitor.
    private fun isCurrent(id: String, snapshot: Snapshot<T>): Boolean =
        generation == snapshot.generation && entries[id] == Entry(snapshot.directory, snapshot.entry)
}
