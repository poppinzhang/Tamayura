package dev.tamayura.app

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

/** Scan provider cursors through the real ContentResolver and persisted tree grant. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class SafMediaStoreTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    private lateinit var application: Application
    private lateinit var provider: ScanDocumentsProvider
    private lateinit var store: SafMediaStore
    private val tree = DocumentsContract.buildTreeDocumentUri(AUTHORITY, "root")
    private val shared get() = listOf(SafMediaStore.SharedDirectory("album", tree.toString(), "相册"))

    @Before fun setUp() {
        application = RuntimeEnvironment.getApplication()
        provider = ScanDocumentsProvider()
        provider.attachInfo(application, ProviderInfo().apply {
            authority = AUTHORITY
            exported = true
            grantUriPermissions = true
        })
        ShadowContentResolver.registerProviderInternal(AUTHORITY, provider)
        application.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        store = SafMediaStore(application)
    }

    @Test fun mixedAlbumKeepsPhotosVideosAndNestedMediaWithoutOpeningOtherFiles() {
        provider.children["root"] = listOf(
            Row("photo", "photo.jpg", "image/jpeg", 12L, 1234L),
            Row("video", "video.mp4", "video/mp4", 34L),
            Row("nested", "旅行", Document.MIME_TYPE_DIR),
            Row("text", "notes.txt", "text/plain"),
            Row("nomedia", ".nomedia", "application/octet-stream"),
            Row("sidecar", "photo.xmp", "application/rdf+xml"),
            Row("audio", "voice.mp3", "audio/mpeg"),
            Row("unknown", "cache.unknown", null),
        )
        provider.children["nested"] = listOf(
            Row("nested-photo", "photo.jpg", "image/jpeg", 56L),
            Row("nested-sidecar", "photo.xmp", "application/octet-stream"),
        )

        val entries = scan()

        assertEquals(listOf("photo.jpg", "video.mp4", "旅行/photo.jpg"), entries.map { it["relativePath"] })
        assertEquals(listOf("image/jpeg", "video/mp4", "image/jpeg"), entries.map { it["mimeType"] })
        assertEquals(listOf(12L, 34L, 56L), entries.map { it["size"] })
        assertEquals(1234L, entries.first()["modifiedMs"])
        assertEquals(0L, entries.last()["modifiedMs"])
        assertTrue(entries.all { it["sharedFolderId"] == "album" && it["sharedFolderName"] == "相册" })
        assertEquals(3, entries.map { it["id"] }.toSet().size)
        assertEquals(listOf("root", "nested"), provider.queriedDirectories)
        assertTrue(provider.openedDocuments.isEmpty())
        // Successfully scanned media is published even when unwanted entries surround it.
        assertArrayEquals(byteArrayOf(), store.readRange(entries.first()["id"] as String, 0, 0))
    }

    @Test fun malformedNonMediaNamesAreSkippedBeforePathValidation() {
        provider.children["root"] = listOf(
            Row("missing-name", null, "text/plain"),
            Row("unknown-missing-name", null, null),
            Row("empty-name", "", "application/octet-stream"),
            Row("blank-name", " ", "audio/mpeg"),
            Row("backslash", "metadata\\cache.txt", "text/plain"),
            Row("newline", "metadata\ncache.xmp", "application/rdf+xml"),
            Row("slash", "metadata/cache.bin", "application/octet-stream"),
            Row("control", "cache\u0000.bin", null),
            Row("photo", "photo.jpg", "image/jpeg", 12L),
        )

        assertEquals(listOf("photo.jpg"), scan().map { it["relativePath"] })
        assertTrue(provider.openedDocuments.isEmpty())
    }

    @Test fun albumContainingOnlyNonMediaSuccessfullyPublishesAnEmptyCatalog() {
        provider.children["root"] = listOf(
            Row("text", "notes.txt", "text/plain"),
            Row("nomedia", ".nomedia", null),
            Row("missing-name", null, "application/octet-stream"),
            Row("nested", "metadata", Document.MIME_TYPE_DIR),
        )
        provider.children["nested"] = listOf(Row("sidecar", "photo.xmp", "application/rdf+xml"))

        assertTrue(scan().isEmpty())
        assertEquals(listOf("root", "nested"), provider.queriedDirectories)
        assertTrue(provider.openedDocuments.isEmpty())
        assertThrows(FileNotFoundException::class.java) { store.readRange("not-shared", 0, 0) }
    }

    @Test fun missingOrGenericMimeTypesUseCaseInsensitiveMediaExtensions() {
        provider.children["root"] = listOf(
            Row("jpeg", "photo.JpG", "application/octet-stream", 10L),
            Row("png", "image.PNG", null, 20L),
            Row("mp4", "video.MP4", "application/octet-stream", 30L),
            Row("text-with-image-name", "notes.jpg", "text/plain"),
            Row("unknown", "unknown.xyzxyz", "application/octet-stream"),
        )

        val entries = scan()

        assertEquals(listOf("photo.JpG", "image.PNG", "video.MP4"), entries.map { it["name"] })
        assertEquals(listOf("image/jpeg", "image/png", "video/mp4"), entries.map { it["mimeType"] })
        assertTrue(provider.openedDocuments.isEmpty())
    }

    @Test fun missingNamesStillFailForMediaAndDirectories() {
        for (mime in listOf("image/jpeg", "video/mp4", Document.MIME_TYPE_DIR)) {
            provider.children["root"] = listOf(Row("unnamed", null, mime, 10L))
            assertThrows(IOException::class.java) { scan() }
        }
        assertTrue(provider.openedDocuments.isEmpty())
    }

    @Test fun unsafeMediaAndDirectoryPathsStillFail() {
        for (mime in listOf("image/jpeg", "video/mp4", Document.MIME_TYPE_DIR)) {
            for (name in listOf("", " ", ".", "..", "a/b.jpg", "a\\b.jpg", "a\nb.jpg")) {
                provider.children["root"] = listOf(Row("invalid", name, mime, 10L))
                assertThrows(IllegalArgumentException::class.java) { scan() }
            }
        }
        assertTrue(provider.openedDocuments.isEmpty())
    }

    @Test fun mediaWithoutCursorSizeCanUseItsFileDescriptorSize() {
        val media = temporaryFolder.newFile("photo.jpg").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg"))
        provider.files["photo"] = media

        assertEquals(4L, scan().single()["size"])
        assertEquals(listOf("photo"), provider.openedDocuments)
    }

    @Test fun mediaWithUnknownSizeStillFails() {
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg"))
        provider.files["photo"] = null

        assertThrows(IllegalStateException::class.java) { scan() }
        assertEquals(listOf("photo"), provider.openedDocuments)

        provider.children["root"] = listOf(Row("video", "video.mp4", "video/mp4", -1L))
        assertThrows(IllegalStateException::class.java) { scan() }
    }

    @Test fun revokedDirectoryPermissionStillFailsBeforeQuerying() {
        application.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)

        assertThrows(SecurityException::class.java) { scan() }
        assertTrue(provider.queriedDirectories.isEmpty())
    }

    @Test fun permissionRevokedDuringScanStillPreventsPublishing() {
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg", 10L))
        provider.onQuery = {
            application.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        assertThrows(SecurityException::class.java) { scan() }
        assertThrows(SecurityException::class.java) { store.readRange("any-id", 0, 0) }
    }

    @Test fun unreadableRootOrNestedDirectoryStillFailsTheScan() {
        provider.children["root"] = null
        assertThrows(FileNotFoundException::class.java) { scan() }

        provider.children["root"] = listOf(
            Row("photo", "photo.jpg", "image/jpeg", 10L),
            Row("nested", "旅行", Document.MIME_TYPE_DIR),
        )
        provider.children["nested"] = null
        assertThrows(FileNotFoundException::class.java) { scan() }
        assertThrows(SecurityException::class.java) { store.readRange("any-id", 0, 0) }

        provider.onQuery = { throw SecurityException("Provider denied directory access") }
        assertThrows(SecurityException::class.java) { scan() }
    }

    private fun scan() = store.scanMetadata(shared, store.clear())

    private data class Row(
        val id: String,
        val name: String?,
        val mimeType: String?,
        val size: Long? = null,
        val modified: Long? = null,
    ) {
        fun value(column: String): Any? = when (column) {
            Document.COLUMN_DOCUMENT_ID -> id
            Document.COLUMN_DISPLAY_NAME -> name
            Document.COLUMN_MIME_TYPE -> mimeType
            Document.COLUMN_SIZE -> size
            Document.COLUMN_LAST_MODIFIED -> modified
            else -> error("Unexpected requested column: $column")
        }
    }

    private class ScanDocumentsProvider : ContentProvider() {
        val children = mutableMapOf<String, List<Row>?>()
        val files = mutableMapOf<String, File?>()
        val queriedDirectories = mutableListOf<String>()
        val openedDocuments = mutableListOf<String>()
        var onQuery: (() -> Unit)? = null

        override fun onCreate() = true

        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                           selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
            check(uri.lastPathSegment == "children") { "Unexpected query: $uri" }
            val parent = DocumentsContract.getDocumentId(uri)
            queriedDirectories.add(parent)
            onQuery?.invoke()
            check(children.containsKey(parent)) { "Unexpected directory: $parent" }
            val rows = children[parent] ?: return null
            val columns = requireNotNull(projection)
            return MatrixCursor(columns).apply {
                rows.forEach { row -> addRow(columns.map(row::value)) }
            }
        }

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
            val id = DocumentsContract.getDocumentId(uri)
            openedDocuments.add(id)
            check(files.containsKey(id)) { "Unexpected file read: $id" }
            return files[id]?.let { ParcelFileDescriptor.open(it, ParcelFileDescriptor.MODE_READ_ONLY) }
        }

        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Unexpected insert")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
            error("Unexpected update")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = error("Unexpected delete")
    }

    companion object {
        private const val AUTHORITY = "dev.tamayura.test.documents"
    }
}
