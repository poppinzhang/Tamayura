package dev.tamayura.app

internal class DirectoryOverlapException : IllegalArgumentException("此目录已共享，或与现有共享目录存在父子关系")
internal class DirectoryRelationException : IllegalArgumentException("无法确认目录是否重复，请选择能够验证目录层级的本机存储目录")

/** Rules kept independent of Android so traversal and overlap boundaries are testable. */
internal object StoragePaths {
    fun requireSegment(value: String): String {
        require(value.isNotBlank() && value != "." && value != ".." &&
            value.none { it == '/' || it == '\\' || it.isISOControl() }) { "无效的文件或目录名称" }
        return value
    }

    fun relativePath(parent: String, name: String): String {
        requireSegment(name)
        return if (parent.isEmpty()) name else "$parent/$name"
    }

    /** ExternalStorageProvider IDs have a documented volume:path structure. */
    fun externalStorageOverlap(firstId: String, secondId: String): Boolean? {
        fun parse(id: String): Pair<String, List<String>>? {
            val separator = id.indexOf(':')
            if (separator <= 0) return null
            val volume = id.substring(0, separator)
            val path = id.substring(separator + 1)
            val segments = if (path.isEmpty()) emptyList() else path.split('/')
            if (segments.any { it.isEmpty() || it == "." || it == ".." ||
                    it.any { char -> char == '\\' || char.isISOControl() } }) return null
            return volume to segments
        }
        val first = parse(firstId) ?: return null
        val second = parse(secondId) ?: return null
        if (!first.first.equals(second.first, ignoreCase = true)) return false
        // A conservative case-insensitive comparison also covers removable FAT volumes.
        return first.second.zip(second.second).all { (a, b) -> a.equals(b, ignoreCase = true) }
    }

    fun availableFileName(requested: String, existing: Set<String>): String {
        requireSegment(requested)
        val names = existing.map { it.lowercase(java.util.Locale.ROOT) }.toSet()
        if (requested.lowercase(java.util.Locale.ROOT) !in names) return requested
        val dot = requested.lastIndexOf('.').takeIf { it > 0 } ?: requested.length
        val stem = requested.substring(0, dot)
        val extension = requested.substring(dot)
        var suffix = 2
        while (true) {
            val candidate = "$stem ($suffix)$extension"
            if (candidate.lowercase(java.util.Locale.ROOT) !in names) return candidate
            suffix += 1
        }
    }
}
