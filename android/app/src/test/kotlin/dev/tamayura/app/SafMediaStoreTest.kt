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
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.CancellationException
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

    @Test fun unnamedMediaAndDirectoriesAreSkippedWithoutWithholdingOtherFiles() {
        for (mime in listOf("image/jpeg", "video/mp4", Document.MIME_TYPE_DIR)) {
            provider.children["root"] = listOf(Row("unnamed", null, mime, 10L), Row("photo", "photo.jpg", "image/jpeg", 12L))
            assertEquals(listOf("photo.jpg"), scan().map { it["relativePath"] })
        }
        assertTrue(provider.openedDocuments.isEmpty())
    }

    @Test fun unsafeMediaAndDirectoryNamesAreSkippedWithoutWithholdingOtherFiles() {
        for (mime in listOf("image/jpeg", "video/mp4", Document.MIME_TYPE_DIR)) {
            for (name in listOf("", " ", ".", "..", "a/b.jpg", "a\\b.jpg", "a\nb.jpg")) {
                provider.children["root"] = listOf(Row("invalid", name, mime, 10L), Row("photo", "photo.jpg", "image/jpeg", 12L))
                provider.children["invalid"] = listOf(Row("inside", "inside.jpg", "image/jpeg", 1L))
                assertEquals(listOf("photo.jpg"), scan().map { it["relativePath"] })
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

    @Test fun mediaWithUnknownSizeOrUnopenableDescriptorIsSkipped() {
        val kept = Row("kept", "kept.jpg", "image/jpeg", 4L)
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg"), kept)
        provider.files["photo"] = null

        assertEquals(listOf("kept.jpg"), scan().map { it["relativePath"] })
        assertEquals(listOf("photo"), provider.openedDocuments)

        provider.children["root"] = listOf(Row("video", "video.mp4", "video/mp4", -1L), kept)
        assertEquals(listOf("kept.jpg"), scan().map { it["relativePath"] })

        provider.children["root"] = listOf(Row("gone", "gone.jpg", "image/jpeg"), kept)
        provider.onOpen = { throw FileNotFoundException("Deleted during the scan") }
        assertEquals(listOf("kept.jpg"), scan().map { it["relativePath"] })
    }

    @Test fun rangeReadsAcceptAtMostTwoMebibytes() {
        assertEquals(2 * 1024 * 1024, SafMediaStore.MAX_RANGE_BYTES)
        assertThrows(IllegalArgumentException::class.java) {
            store.readRange("any-id", 0, SafMediaStore.MAX_RANGE_BYTES + 1)
        }
        // A valid length reaches the catalog, which has nothing published yet.
        assertThrows(SecurityException::class.java) {
            store.readRange("any-id", 0, SafMediaStore.MAX_RANGE_BYTES)
        }
    }

    @Test fun permissionLossWhileSizingAFileStillFailsTheScan() {
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg"))
        provider.onOpen = { throw SecurityException("Grant revoked") }

        assertThrows(SecurityException::class.java) { scan() }
        assertThrows(SecurityException::class.java) { store.readRange("any-id", 0, 0) }
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

    @Test fun unreadableRootFailsButUnreadableNestedDirectoryIsSkipped() {
        provider.children["root"] = null
        assertThrows(FileNotFoundException::class.java) { scan() }
        assertThrows(SecurityException::class.java) { store.readRange("any-id", 0, 0) }

        provider.children["root"] = listOf(
            Row("photo", "photo.jpg", "image/jpeg", 10L),
            Row("nested", "旅行", Document.MIME_TYPE_DIR),
            Row("broken", "损坏", Document.MIME_TYPE_DIR),
        )
        provider.children["nested"] = null
        provider.children["broken"] = listOf()
        provider.failingDirectories += "broken"
        assertEquals(listOf("photo.jpg"), scan().map { it["relativePath"] })

        provider.onQuery = { throw SecurityException("Provider denied directory access") }
        assertThrows(SecurityException::class.java) { scan() }
    }

    @Test fun rootDisappearingDuringTheScanPublishesNothing() {
        val media = temporaryFolder.newFile("photo.jpg").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg", 4L))
        provider.files["photo"] = media
        val id = scan().single()["id"] as String
        assertEquals(listOf("root"), provider.queriedDocuments)

        provider.children["root"] = listOf(
            Row("photo", "photo.jpg", "image/jpeg", 4L),
            Row("nested", "旅行", Document.MIME_TYPE_DIR),
        )
        provider.children["nested"] = null
        provider.missingDocuments += "root"
        assertThrows(FileNotFoundException::class.java) { store.scanMetadata(shared, store.beginScan(shared)) }
        assertThrows(SecurityException::class.java) { store.readRange(id, 0, 4) }
    }

    @Test fun rescanKeepsServingPreviousFilesUntilItPublishes() {
        val media = temporaryFolder.newFile("photo.jpg").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg", 4L))
        provider.files["photo"] = media
        val id = scan().single()["id"] as String

        // A peer's read arriving while the provider is still listing must not fail.
        var duringScan: ByteArray? = null
        provider.onQuery = { duringScan = store.readRange(id, 1, 2) }
        store.scanMetadata(shared, store.beginScan(shared))

        assertArrayEquals(byteArrayOf(2, 3), duringScan)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), store.readRange(id, 0, 4))
    }

    @Test fun removedRootStopsAtOnceAndFailedRescanRevokesEverything() {
        val media = temporaryFolder.newFile("photo.jpg").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        provider.children["root"] = listOf(Row("photo", "photo.jpg", "image/jpeg", 4L))
        provider.files["photo"] = media
        val id = scan().single()["id"] as String

        store.beginScan(emptyList())
        assertThrows(FileNotFoundException::class.java) { store.readRange(id, 0, 4) }

        assertEquals(id, scan().single()["id"])
        provider.children["root"] = null
        assertThrows(FileNotFoundException::class.java) { store.scanMetadata(shared, store.beginScan(shared)) }
        assertThrows(SecurityException::class.java) { store.readRange(id, 0, 4) }
    }

    @Test fun latePermissionFailureForRemovedFilePreservesRescannedFilesAndNextScan() {
        val kept = Row("kept", "kept.jpg", "image/jpeg", 4L)
        provider.children["root"] = listOf(Row("moved", "moved.jpg", "image/jpeg", 4L), kept)
        provider.files["kept"] = temporaryFolder.newFile("kept.jpg").apply {
            writeBytes(byteArrayOf(1, 2, 3, 4))
        }
        val ids = scan().associate { it["name"] to it["id"] as String }
        var nextScan = -1L
        provider.onOpen = { documentId ->
            assertEquals("moved", documentId)
            provider.onOpen = null
            // Model a document moved outside its tree while its old open call
            // is in flight. DocumentsProvider can deny that document alone.
            provider.children["root"] = listOf(kept)
            store.scanMetadata(shared, store.beginScan(shared))
            nextScan = store.beginScan(shared)
            throw SecurityException("Document moved is not a descendant of root")
        }

        assertThrows(SecurityException::class.java) { store.readRange(ids.getValue("moved.jpg"), 0, 4) }

        assertArrayEquals(byteArrayOf(1, 2, 3, 4), store.readRange(ids.getValue("kept.jpg"), 0, 4))
        assertEquals(listOf("kept.jpg"), store.scanMetadata(shared, nextScan).map { it["name"] })
        assertThrows(FileNotFoundException::class.java) { store.readRange(ids.getValue("moved.jpg"), 0, 4) }
    }

    @Test fun currentReadLosingItsGrantRevokesAllFilesAndPendingScan() {
        provider.children["root"] = listOf(
            Row("photo", "photo.jpg", "image/jpeg", 4L),
            Row("other", "other.jpg", "image/jpeg", 4L))
        provider.files["photo"] = temporaryFolder.newFile("photo.jpg").apply {
            writeBytes(byteArrayOf(1, 2, 3, 4))
        }
        val ids = scan().associate { it["name"] to it["id"] as String }
        val nextScan = store.beginScan(shared)
        provider.onOpen = {
            provider.onOpen = null
            application.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        assertThrows(SecurityException::class.java) { store.readRange(ids.getValue("photo.jpg"), 0, 4) }

        assertThrows(SecurityException::class.java) { store.readRange(ids.getValue("other.jpg"), 0, 4) }
        assertThrows(CancellationException::class.java) { store.scanMetadata(shared, nextScan) }
    }

    private fun allowSaving() {
        application.contentResolver.takePersistableUriPermission(tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        provider.children["root"] = emptyList()
    }

    private fun part(name: String, bytes: ByteArray) = File(application.filesDir, name).apply { writeBytes(bytes) }

    @Test fun saveWritesOrderedPartsWithoutAnIntermediateFile() {
        allowSaving()
        val a = part("a.part", byteArrayOf(1, 2))
        val b = part("b.part", byteArrayOf(3, 4, 5))
        val uri = store.saveDownload(listOf(a.path, b.path), 5, tree.toString(), "photo.jpg", "image/jpeg", emptyList())
        val id = DocumentsContract.getDocumentId(Uri.parse(uri))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5), provider.files.getValue(id)!!.readBytes())
        assertTrue(a.exists() && b.exists())
        assertEquals(listOf("photo.jpg"), provider.children.getValue("root")!!.map { it.name })

        val next = store.saveDownload(listOf(a.path, b.path), 5, tree.toString(), "photo.jpg", "image/jpeg", emptyList())
        assertNotEquals(uri, next)
        assertEquals(listOf("photo.jpg", "photo (2).jpg"), provider.children.getValue("root")!!.map { it.name })
    }

    @Test fun saveValidatesAllPartsAndSupportsEmptyFiles() {
        allowSaving()
        val a = part("a.part", byteArrayOf(1, 2))
        for (size in listOf(-1L, 1L, 3L)) {
            assertThrows(IllegalArgumentException::class.java) {
                store.saveDownload(listOf(a.path), size, tree.toString(), "bad.jpg", "image/jpeg", emptyList())
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            store.saveDownload(listOf(temporaryFolder.newFile("external.part").path), 0,
                tree.toString(), "outside.jpg", "image/jpeg", emptyList())
        }
        assertTrue(provider.files.isEmpty())
        val empty = part("empty.part", byteArrayOf())
        val uri = store.saveDownload(listOf(empty.path), 0, tree.toString(), "empty.jpg", "image/jpeg", emptyList())
        assertEquals(0L, provider.files.getValue(DocumentsContract.getDocumentId(Uri.parse(uri)))!!.length())
    }

    @Test fun cancellationAndLateSourceChangesDeleteTheNewDocument() {
        allowSaving()
        val a = part("a.part", byteArrayOf(1, 2))
        val b = part("b.part", byteArrayOf(3, 4))
        provider.onOpen = { b.writeBytes(byteArrayOf(3)) }
        assertThrows(IllegalArgumentException::class.java) {
            store.saveDownload(listOf(a.path, b.path), 4, tree.toString(), "changed.jpg", "image/jpeg", emptyList())
        }
        assertTrue(provider.files.isEmpty())
        b.writeBytes(byteArrayOf(3, 4))
        var cancelled = false
        provider.onOpen = { cancelled = true }
        assertThrows(CancellationException::class.java) {
            store.saveDownload(listOf(a.path, b.path), 4, tree.toString(), "cancelled.jpg", "image/jpeg", emptyList()) { cancelled }
        }
        assertTrue(provider.files.isEmpty())
        assertTrue(provider.children.getValue("root")!!.isEmpty())
        assertTrue(a.exists() && b.exists())
    }

    @Test fun spaceReportsPrivateCapacityWithoutGuessingSafCapacity() {
        allowSaving()
        val space = store.transferSpace(tree.toString())
        assertTrue((space["stagingAvailableBytes"] as Long) >= 0)
        assertFalse(space.containsKey("destinationAvailableBytes"))
        assertFalse(space.containsKey("sameVolume"))
        application.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        assertThrows(SecurityException::class.java) { store.transferSpace(tree.toString()) }
    }

    @Test fun deleteRemovesOnlyTheSavedDocumentAndKeepsFoldersAndSharedCatalog() {
        allowSaving()
        val source = part("source.part", byteArrayOf(1, 2, 3))
        val uri = store.saveDownload(listOf(source.path), 3, tree.toString(), "saved.jpg", "image/jpeg", emptyList())
        provider.children["root"] = provider.children.getValue("root").orEmpty() +
            Row("shared", "shared.jpg", "image/jpeg", 0L)
        val sharedId = scan().single { it["name"] == "shared.jpg" }["id"] as String
        val documentId = DocumentsContract.getDocumentId(Uri.parse(uri))
        val saved = provider.files.getValue(documentId)!!

        store.deleteDownload(uri)

        assertFalse(saved.exists())
        assertTrue(source.exists())
        assertEquals(listOf(documentId), provider.deletedDocuments)
        assertEquals(listOf("shared"), provider.children.getValue("root")!!.map { it.id })
        assertArrayEquals(byteArrayOf(), store.readRange(sharedId, 0, 0))
    }

    @Test fun deletingAnAlreadyMissingDocumentSucceedsWithoutCallingDeleteAgain() {
        allowSaving()
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, "gone").toString()
        provider.absentDocuments += "gone"

        store.deleteDownload(uri)
        store.deleteDownload(uri)

        assertEquals(listOf("gone", "gone"), provider.queriedDocuments)
        assertTrue(provider.deletedDocuments.isEmpty())
    }

    @Test fun deleteRequiresPersistedReadAndWritePermission() {
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, "photo").toString()
        assertThrows(SecurityException::class.java) { store.deleteDownload(uri) }
        allowSaving()
        application.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        assertThrows(SecurityException::class.java) { store.deleteDownload(uri) }
        assertTrue(provider.queriedDocuments.isEmpty())
        assertTrue(provider.deletedDocuments.isEmpty())
    }

    @Test fun deleteRejectsMalformedUrisAndTheReceivingTreeRoot() {
        allowSaving()
        val invalid = listOf(
            "file:///download/photo.jpg",
            "content://$AUTHORITY/photo",
            DocumentsContract.buildDocumentUri(AUTHORITY, "photo").toString(),
            DocumentsContract.buildChildDocumentsUriUsingTree(tree, "album").toString(),
            tree.toString(),
            DocumentsContract.buildDocumentUriUsingTree(tree, "root").toString(),
        )
        for (uri in invalid) {
            assertThrows(IllegalArgumentException::class.java) { store.deleteDownload(uri) }
        }
        assertTrue(provider.queriedDocuments.isEmpty())
        assertTrue(provider.deletedDocuments.isEmpty())
    }

    @Test fun deleteRejectsDirectoriesAndUnconfirmedDocumentTypes() {
        allowSaving()
        provider.children["root"] = listOf(
            Row("directory", "album", Document.MIME_TYPE_DIR),
            Row("unknown", "photo.jpg", null))
        val directory = DocumentsContract.buildDocumentUriUsingTree(tree, "directory").toString()
        val unknown = DocumentsContract.buildDocumentUriUsingTree(tree, "unknown").toString()

        assertThrows(IllegalArgumentException::class.java) { store.deleteDownload(directory) }
        assertThrows(java.io.IOException::class.java) { store.deleteDownload(unknown) }
        assertTrue(provider.deletedDocuments.isEmpty())
        assertEquals(2, provider.children.getValue("root")!!.size)
    }

    @Test fun deleteDoesNotTreatUnavailableProviderAsMissingDocument() {
        allowSaving()
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, "photo").toString()
        provider.missingDocuments += "photo" // A null cursor is not an empty cursor.

        assertThrows(java.io.IOException::class.java) { store.deleteDownload(uri) }
        assertTrue(provider.deletedDocuments.isEmpty())
    }

    @Test fun deletePropagatesProviderQueryErrorsRatherThanDiscardingSavedRecord() {
        allowSaving()
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, "photo").toString()
        for (error in listOf(SecurityException("Access denied"),
            FileNotFoundException("Document unavailable"), IllegalStateException("Provider failed"))) {
            provider.onDocumentQuery = { throw error }
            assertThrows(error.javaClass) { store.deleteDownload(uri) }
        }
        assertTrue(provider.deletedDocuments.isEmpty())
    }

    @Test fun deleteRechecksGrantAfterLookupIncludingAnEmptyResult() {
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, "photo").toString()
        for (absent in listOf(false, true)) {
            allowSaving()
            if (absent) provider.absentDocuments += "photo"
            provider.onDocumentQuery = {
                application.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            assertThrows(SecurityException::class.java) { store.deleteDownload(uri) }
        }
        assertTrue(provider.deletedDocuments.isEmpty())
    }

    @Test fun failedDeletePreservesTheDocumentAndReportsTheProviderError() {
        allowSaving()
        val source = part("source.part", byteArrayOf(1, 2, 3))
        val uri = store.saveDownload(listOf(source.path), 3, tree.toString(), "saved.mp4", "video/mp4", emptyList())
        val documentId = DocumentsContract.getDocumentId(Uri.parse(uri))
        for (error in listOf(SecurityException("Access denied"),
            FileNotFoundException("Document unavailable"), IllegalStateException("Provider failed"))) {
            provider.onDelete = { throw error }
            // DocumentsContract may turn a provider's checked exception into false.
            val expected = if (error is FileNotFoundException) java.io.IOException::class.java else error.javaClass
            assertThrows(expected) { store.deleteDownload(uri) }
            assertTrue(provider.files.getValue(documentId)!!.exists())
        }
        assertTrue(provider.deletedDocuments.isEmpty())
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
        val queriedDocuments = mutableListOf<String>()
        val missingDocuments = mutableSetOf<String>()
        val absentDocuments = mutableSetOf<String>()
        val failingDirectories = mutableSetOf<String>()
        val openedDocuments = mutableListOf<String>()
        val deletedDocuments = mutableListOf<String>()
        var onQuery: (() -> Unit)? = null
        var onDocumentQuery: (() -> Unit)? = null
        var onOpen: ((String) -> Unit)? = null
        var onDelete: (() -> Unit)? = null

        override fun onCreate() = true

        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                           selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
            if (uri.lastPathSegment != "children") {
                // The scanner confirms each shared root still exists before publishing.
                val document = DocumentsContract.getDocumentId(uri)
                queriedDocuments.add(document)
                onDocumentQuery?.invoke()
                if (document in missingDocuments) return null
                val columns = requireNotNull(projection)
                return MatrixCursor(columns).apply {
                    if (document !in absentDocuments) {
                        val row = children.values.filterNotNull().flatten().firstOrNull { it.id == document }
                            ?: Row(document, document, if (document in children) Document.MIME_TYPE_DIR else "image/jpeg")
                        addRow(columns.map(row::value))
                    }
                }
            }
            val parent = DocumentsContract.getDocumentId(uri)
            queriedDirectories.add(parent)
            onQuery?.invoke()
            if (parent in failingDirectories) throw IllegalStateException("Provider failed to list $parent")
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
            onOpen?.invoke(id)
            check(files.containsKey(id)) { "Unexpected file read: $id" }
            return files[id]?.let { ParcelFileDescriptor.open(it, ParcelFileDescriptor.parseMode(mode)) }
        }

        override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
            val uri = extras?.getParcelable("uri", Uri::class.java) ?: error("Missing document URI")
            val id = DocumentsContract.getDocumentId(uri)
            return when (method) {
                "android:createDocument" -> {
                    val child = "saved-${files.size}-${System.nanoTime()}"
                    val name = requireNotNull(extras.getString(Document.COLUMN_DISPLAY_NAME))
                    val mime = requireNotNull(extras.getString(Document.COLUMN_MIME_TYPE))
                    children[id] = children.getValue(id).orEmpty() + Row(child, name, mime)
                    files[child] = File.createTempFile("saved-", ".bin", requireNotNull(context).cacheDir)
                    Bundle().apply { putParcelable("uri", DocumentsContract.buildDocumentUriUsingTree(uri, child)) }
                }
                "android:deleteDocument" -> {
                    onDelete?.invoke()
                    deletedDocuments.add(id)
                    files.remove(id)?.delete()
                    children.keys.toList().forEach { parent -> children[parent] = children[parent]?.filter { it.id != id } }
                    absentDocuments.add(id)
                    Bundle()
                }
                else -> error("Unexpected provider call: $method")
            }
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
