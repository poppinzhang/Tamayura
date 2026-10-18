package dev.tamayura.app

internal class DirectoryOverlapException :
    IllegalArgumentException("The directory repeats or overlaps a shared directory"), LocalizedText {
    override val textId = R.string.error_directory_overlap
}

internal class DirectoryRelationException :
    IllegalArgumentException("Cannot verify the directory hierarchy"), LocalizedText {
    override val textId = R.string.error_directory_relation
}

/** An invalid argument whose user-facing text is a string resource. */
internal class InvalidArgumentException(override val textId: Int, diagnostic: String) :
    IllegalArgumentException(diagnostic), LocalizedText

/** Rules kept independent of Android so traversal and overlap boundaries are testable. */
internal object StoragePaths {
    fun requireSegment(value: String): String {
        if (value.isBlank() || value == "." || value == ".." ||
            value.any { it == '/' || it == '\\' || it.isISOControl() }) {
            throw InvalidArgumentException(R.string.error_invalid_name, "Invalid file or directory name")
        }
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
