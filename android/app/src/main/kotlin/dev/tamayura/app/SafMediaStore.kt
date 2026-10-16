package dev.tamayura.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.webkit.MimeTypeMap
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.CancellationException

/** Only a successfully scanned, currently authorized tree can serve file bytes. */
internal class SafMediaStore(private val context: Context) {
    private val resolver = context.contentResolver
    private val catalog = SharedCatalog<SharedFile>()

    private data class SharedFile(val uri: Uri, val size: Long, val mimeType: String)
    data class SharedDirectory(val id: String, val uri: String, val name: String)
    private data class PendingDirectory(val documentId: String, val relativePath: String)
    private data class ChildDocument(val id: String, val name: String, val mimeType: String)

    fun clear(): Long = catalog.clear()

    private fun assertGeneration(expected: Long) {
        catalog.assertGeneration(expected)
        if (Thread.currentThread().isInterrupted) {
            throw CancellationException("共享目录已改变，请重新扫描")
        }
    }

    private fun authorizedTree(value: String, write: Boolean = false): Uri {
        val uri = Uri.parse(value)
        require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri)) { "无效的目录 URI" }
        val authorized = resolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && (!write || it.isWritePermission)
        }
        if (!authorized) throw SecurityException("目录授权已失效，请重新选择目录")
        return uri
    }

    fun directoryName(tree: Uri): String {
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        resolver.query(document, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0) ?: "已选择目录"
        }
        return "已选择目录"
    }

    fun validateSharedDirectory(value: String, existing: List<String>) {
        val candidate = authorizedTree(value)
        existing.forEach { directory ->
            if (treesOverlap(candidate, authorizedTree(directory))) throw DirectoryOverlapException()
        }
    }

    private fun treesOverlap(first: Uri, second: Uri): Boolean {
        // Separate providers may expose aliases of the same physical storage.
        if (first.authority != second.authority) throw DirectoryRelationException()
        val firstId = DocumentsContract.getTreeDocumentId(first)
        val secondId = DocumentsContract.getTreeDocumentId(second)
        if (firstId == secondId) return true
        val firstDocument = DocumentsContract.buildDocumentUriUsingTree(first, firstId)
        val secondDocument = DocumentsContract.buildDocumentUriUsingTree(second, secondId)
        val external = if (first.authority == "com.android.externalstorage.documents") {
            StoragePaths.externalStorageOverlap(firstId, secondId)
        } else null
        return try {
            DocumentsContract.isChildDocument(resolver, firstDocument, secondDocument) ||
                DocumentsContract.isChildDocument(resolver, secondDocument, firstDocument) || external == true
        } catch (error: SecurityException) {
            // Recheck grants before falling back: permission loss must still revoke the scan.
            authorizedTree(first.toString())
            authorizedTree(second.toString())
            external ?: throw DirectoryRelationException()
        } catch (_: UnsupportedOperationException) {
            external ?: throw DirectoryRelationException()
        } catch (_: IllegalArgumentException) {
            external ?: throw DirectoryRelationException()
        } catch (_: FileNotFoundException) {
            external ?: throw DirectoryRelationException()
        }
    }

    fun scanMetadata(shared: List<SharedDirectory>, expected: Long): List<Map<String, Any>> {
        assertGeneration(expected)
        require(shared.all { it.id.isNotBlank() && it.name.isNotBlank() }) { "共享目录缺少标识或名称" }
        require(shared.map { it.id }.toSet().size == shared.size) { "共享目录标识重复" }
        shared.forEachIndexed { index, directory ->
            validateSharedDirectory(directory.uri, shared.take(index).map { it.uri })
        }
        val entries = mutableListOf<Map<String, Any>>()
        val nextFiles = mutableMapOf<String, SharedCatalog.Entry<SharedFile>>()
        shared.forEach { directory ->
            val tree = authorizedTree(directory.uri)
            val directories = ArrayDeque<PendingDirectory>()
            val visited = mutableSetOf<String>()
            directories.add(PendingDirectory(DocumentsContract.getTreeDocumentId(tree), ""))
            while (!directories.isEmpty()) {
                assertGeneration(expected)
                val current = directories.removeFirst()
                if (!visited.add(current.documentId)) continue
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, current.documentId)
                val cursor = resolver.query(children, COLUMNS, null, null, null)
                    ?: throw FileNotFoundException("无法读取目录，请检查目录是否仍存在")
                cursor.use {
                    while (it.moveToNext()) {
                        assertGeneration(expected)
                        val documentId = it.getString(0) ?: continue
                        val name = it.getString(1)
                        var mimeType = it.getString(2) ?: "application/octet-stream"
                        if (mimeType == "application/octet-stream" && name != null) {
                            val extension = name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
                            mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: mimeType
                        }
                        // Ignore non-media before validating paths or opening files for their size.
                        if (mimeType != Document.MIME_TYPE_DIR &&
                            !mimeType.startsWith("image/") && !mimeType.startsWith("video/")) continue
                        if (name == null) throw java.io.IOException("文档提供方返回了缺少名称的文件")
                        val relativePath = StoragePaths.relativePath(current.relativePath, name)
                        if (mimeType == Document.MIME_TYPE_DIR) {
                            directories.add(PendingDirectory(documentId, relativePath))
                            continue
                        }
                        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
                        val size = if (it.isNull(3)) resolver.openFileDescriptor(uri, "r")?.use { file -> file.statSize }
                            ?: -1L else it.getLong(3)
                        if (size < 0) throw IllegalStateException("无法确定 $name 的大小，请选择本机媒体目录")
                        val modified = if (it.isNull(4)) 0L else it.getLong(4)
                        val id = MessageDigest.getInstance("SHA-256")
                            .digest("${directory.id}\u0000$documentId".toByteArray(Charsets.UTF_8))
                            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
                        nextFiles[id] = SharedCatalog.Entry(directory.uri, SharedFile(uri, size, mimeType))
                        entries.add(mapOf("id" to id, "name" to name, "mimeType" to mimeType,
                            "size" to size, "modifiedMs" to modified, "sharedFolderId" to directory.id,
                            "sharedFolderName" to directory.name, "relativePath" to relativePath))
                    }
                }
            }
        }
        // Publish all roots together; a failure in any root leaves nothing servable.
        shared.forEach { authorizedTree(it.uri) }
        catalog.publish(expected, nextFiles)
        return entries
    }

    fun thumbnail(id: String): ByteArray {
        val (expected, directory, file) = catalog.lookup(id)
        return try {
            authorizedTree(directory)
            assertGeneration(expected)
            val bytes = createThumbnail(file.uri, file.mimeType)
            authorizedTree(directory)
            assertGeneration(expected)
            bytes
        } catch (error: SecurityException) {
            catalog.revoke(expected)
            throw error
        }
    }

    fun readRange(id: String, offset: Long, length: Int): ByteArray {
        require(offset >= 0 && length in 0..MAX_RANGE_BYTES) { "无效的文件分块范围" }
        val (expected, directory, file) = catalog.lookup(id)
        val tree = Uri.parse(directory)
        return try {
            readAuthorizedRange(tree, file, expected, offset, length)
        } catch (error: SecurityException) {
            catalog.revoke(expected)
            throw error
        }
    }

    private fun readAuthorizedRange(tree: Uri, file: SharedFile, expected: Long, offset: Long, length: Int): ByteArray {
        authorizedTree(tree.toString())
        require(offset <= file.size) { "请求偏移量超出文件大小" }
        val count = minOf(length.toLong(), file.size - offset).toInt()
        if (count == 0) return ByteArray(0)
        val bytes = ByteArray(count)
        val descriptor = resolver.openFileDescriptor(file.uri, "r")
            ?: throw FileNotFoundException("文件已不可用，请刷新相册")
        descriptor.use {
            if (it.statSize >= 0 && it.statSize != file.size) {
                throw IllegalStateException("文件大小已改变，请刷新相册")
            }
            try {
                var read = 0
                while (read < count) {
                    assertGeneration(expected)
                    val size = Os.pread(it.fileDescriptor, bytes, read, count - read, offset + read)
                    if (size <= 0) throw java.io.EOFException("文件提前结束，请刷新相册")
                    read += size
                }
            } catch (error: ErrnoException) {
                if (error.errno != OsConstants.ESPIPE) throw error
                // Some providers expose pipes. Reopen each range to avoid sharing a cursor.
                resolver.openInputStream(file.uri)?.use { stream ->
                    var remaining = offset
                    val skipBuffer = ByteArray(16 * 1024)
                    while (remaining > 0) {
                        assertGeneration(expected)
                        val skipped = stream.skip(remaining)
                        if (skipped > 0) { remaining -= skipped; continue }
                        val consumed = stream.read(skipBuffer, 0, minOf(remaining, skipBuffer.size.toLong()).toInt())
                        if (consumed <= 0) throw java.io.EOFException("文件提前结束")
                        remaining -= consumed
                    }
                    var read = 0
                    while (read < count) {
                        assertGeneration(expected)
                        val size = stream.read(bytes, read, count - read)
                        if (size <= 0) throw java.io.EOFException("文件提前结束")
                        read += size
                    }
                } ?: throw FileNotFoundException("无法打开媒体文件")
            }
        }
        // Do not return an old read that completed after sharing was revoked or changed.
        authorizedTree(tree.toString())
        assertGeneration(expected)
        return bytes
    }

    private fun childDocuments(tree: Uri, parent: Uri): List<ChildDocument> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        val cursor = resolver.query(children,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE),
            null, null, null) ?: throw java.io.IOException("无法读取接收目录")
        return cursor.use {
            buildList {
                while (it.moveToNext()) add(ChildDocument(
                    it.getString(0) ?: throw java.io.IOException("接收目录返回了无效的文档"),
                    it.getString(1) ?: throw java.io.IOException("接收目录返回了无效的名称"),
                    it.getString(2) ?: "application/octet-stream"))
            }
        }
    }

    fun saveDownload(sourcePath: String, directoryUri: String, name: String, mimeType: String,
                     directories: List<String>,
                     cancelled: () -> Boolean = { Thread.currentThread().isInterrupted }): String {
        fun checkCancelled() {
            if (cancelled()) throw CancellationException("下载保存已取消")
        }
        checkCancelled()
        StoragePaths.requireSegment(name)
        directories.forEach(StoragePaths::requireSegment)
        val source = File(sourcePath).canonicalFile
        val roots = listOf(context.cacheDir, context.filesDir, context.noBackupFilesDir)
        require(roots.any { source.path.startsWith(it.canonicalPath + File.separator) }) {
            "下载源文件必须在应用私有目录中"
        }
        require(source.isFile) { "下载临时文件不存在" }
        val tree = authorizedTree(directoryUri, write = true)
        // The lock spans all SafMediaStore instances, including headless transfer engines.
        // Reserve the final document before allowing another save to inspect this path.
        val document = synchronized(destinationLock) {
            var parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            directories.forEach { segment ->
                checkCancelled()
                val matching = childDocuments(tree, parent).filter { it.name == segment }
                if (matching.size > 1 || matching.any { it.mimeType != Document.MIME_TYPE_DIR }) {
                    throw java.io.IOException("接收路径中的 $segment 已被同名文件或重复目录占用")
                }
                parent = if (matching.isEmpty()) {
                    DocumentsContract.createDocument(resolver, parent, Document.MIME_TYPE_DIR, segment)
                        ?: throw java.io.IOException("无法创建接收子目录 $segment")
                } else DocumentsContract.buildDocumentUriUsingTree(tree, matching.single().id)
            }
            checkCancelled()
            val existing = childDocuments(tree, parent)
            val availableName = StoragePaths.availableFileName(name, existing.map { it.name }.toSet())
            val created = DocumentsContract.createDocument(resolver, parent, mimeType, availableName)
                ?: throw java.io.IOException("无法在接收目录创建文件")
            if (existing.any { it.id == DocumentsContract.getDocumentId(created) }) {
                throw java.io.IOException("文档提供方没有创建独立文件，已拒绝覆盖现有文件")
            }
            created
        }
        try {
            val output = resolver.openOutputStream(document, "w")
                ?: throw java.io.IOException("无法写入接收目录")
            output.use { target -> source.inputStream().use { input ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    checkCancelled()
                    val count = input.read(buffer)
                    if (count < 0) break
                    target.write(buffer, 0, count)
                }
            } }
            checkCancelled()
            return document.toString()
        } catch (error: Exception) {
            try { DocumentsContract.deleteDocument(resolver, document) } catch (_: Exception) { }
            throw error
        }
    }

    fun readPreview(value: String, maximum: Int): ByteArray {
        require(maximum in 1..2560) { "预览尺寸必须在 1 至 2560 之间" }
        val uri = Uri.parse(value)
        require(uri.scheme == "content" && DocumentsContract.isDocumentUri(context, uri)) {
            "需要有效的已下载文档 URI"
        }
        var bitmap = decodeImage(uri, maximum)
        try {
            while (true) {
                val data = ByteArrayOutputStream().use { bytes ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 88, bytes)
                    bytes.toByteArray()
                }
                if (data.size <= 8 * 1024 * 1024) return data
                val smaller = Bitmap.createScaledBitmap(bitmap,
                    maxOf(1, bitmap.width / 2), maxOf(1, bitmap.height / 2), true)
                if (smaller === bitmap) throw java.io.IOException("预览图过大")
                bitmap.recycle()
                bitmap = smaller
            }
        } finally { bitmap.recycle() }
    }

    private fun decodeImage(uri: Uri, maximum: Int): Bitmap =
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
            val (width, height) = TransferPolicy.previewSize(info.size.width, info.size.height, maximum)
            decoder.setTargetSize(width, height)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.memorySizePolicy = ImageDecoder.MEMORY_POLICY_LOW_RAM
        }

    private fun createThumbnail(uri: Uri, mimeType: String): ByteArray {
        var bitmap: Bitmap? = null
        try {
            try { bitmap = resolver.loadThumbnail(uri, Size(256, 256), null) }
            catch (error: SecurityException) { throw error }
            catch (_: Exception) { /* Many local providers do not implement thumbnails. */ }
            if (bitmap == null && mimeType.startsWith("image/")) {
                bitmap = decodeImage(uri, 256)
            } else if (bitmap == null && mimeType.startsWith("video/")) {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(context, uri)
                    bitmap = retriever.getScaledFrameAtTime(
                        0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 256, 256)
                } finally { retriever.release() }
            }
            val original = bitmap ?: return ByteArray(0)
            val longest = maxOf(original.width, original.height)
            if (longest > 256) {
                val scaled = Bitmap.createScaledBitmap(original,
                    maxOf(1, original.width * 256 / longest), maxOf(1, original.height * 256 / longest), true)
                if (scaled !== original) { original.recycle(); bitmap = scaled }
            }
            return ByteArrayOutputStream().use { output ->
                bitmap!!.compress(Bitmap.CompressFormat.JPEG, 80, output)
                output.toByteArray()
            }
        } catch (error: SecurityException) { throw error }
        catch (_: Exception) { return ByteArray(0) }
        finally { bitmap?.takeUnless { it.isRecycled }?.recycle() }
    }

    companion object {
        private val destinationLock = Any()
        private const val MAX_RANGE_BYTES = 256 * 1024
        private val COLUMNS = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED)
    }
}
