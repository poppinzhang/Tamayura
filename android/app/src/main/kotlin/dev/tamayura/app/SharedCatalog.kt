package dev.tamayura.app

import java.io.FileNotFoundException
import java.util.concurrent.CancellationException

/** Small independently testable boundary between a scan and file serving. */
internal class SharedCatalog<T> {
    data class Entry<T>(val directory: String, val value: T)
    data class Snapshot<T>(val generation: Long, val directory: String, val entry: T)

    private var generation = 0L
    private var published = false
    private var entries: Map<String, Entry<T>> = emptyMap()

    @Synchronized fun clear(): Long {
        generation += 1
        published = false
        entries = emptyMap()
        return generation
    }

    @Synchronized fun assertGeneration(expected: Long) {
        if (generation != expected) throw CancellationException("共享目录已改变，请重新扫描")
    }

    @Synchronized fun publish(expected: Long, entries: Map<String, Entry<T>>) {
        assertGeneration(expected)
        require(entries.values.all { it.directory.isNotBlank() }) { "共享文件必须保留所属目录授权" }
        this.entries = entries.toMap()
        published = true
    }

    @Synchronized fun lookup(id: String): Snapshot<T> {
        if (!published) throw SecurityException("当前没有共享目录")
        val entry = entries[id] ?: throw FileNotFoundException("文件已删除或不在当前共享目录中")
        return Snapshot(generation, entry.directory, entry.value)
    }

    @Synchronized fun revoke(expected: Long) {
        // Authorization failure from an old request cannot cancel a new scan.
        if (generation == expected) clear()
    }
}
