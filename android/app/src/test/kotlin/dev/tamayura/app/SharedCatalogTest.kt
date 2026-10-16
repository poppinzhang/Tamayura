package dev.tamayura.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.FileNotFoundException
import java.util.concurrent.CancellationException

class SharedCatalogTest {
    @Test fun multiFolderSnapshotKeepsEachFilesAuthorizationTree() {
        val catalog = SharedCatalog<String>()
        val generation = catalog.clear()
        catalog.publish(generation, mapOf(
            "a" to SharedCatalog.Entry("tree-a", "file-a"),
            "b" to SharedCatalog.Entry("tree-b", "file-b")))
        assertEquals("tree-a", catalog.lookup("a").directory)
        assertEquals("tree-b", catalog.lookup("b").directory)
        assertEquals("file-b", catalog.lookup("b").entry)
    }

    @Test fun clearingMultiFolderSnapshotRevokesEveryRoot() {
        val catalog = SharedCatalog<String>()
        val generation = catalog.clear()
        catalog.publish(generation, mapOf(
            "a" to SharedCatalog.Entry("tree-a", "file-a"),
            "b" to SharedCatalog.Entry("tree-b", "file-b")))
        catalog.clear()
        assertThrows(SecurityException::class.java) { catalog.lookup("a") }
        assertThrows(SecurityException::class.java) { catalog.lookup("b") }
    }

    @Test fun invalidRootCannotPartiallyPublishNewCatalogue() {
        val catalog = SharedCatalog<String>()
        val generation = catalog.clear()
        assertThrows(IllegalArgumentException::class.java) {
            catalog.publish(generation, mapOf(
                "a" to SharedCatalog.Entry("tree-a", "file-a"),
                "b" to SharedCatalog.Entry("", "file-b")))
        }
        assertThrows(SecurityException::class.java) { catalog.lookup("a") }
    }

    @Test fun replacingMultipleRootsRemovesUnsharedFiles() {
        val catalog = SharedCatalog<String>()
        val first = catalog.clear()
        catalog.publish(first, mapOf(
            "a" to SharedCatalog.Entry("tree-a", "file-a"),
            "b" to SharedCatalog.Entry("tree-b", "file-b")))
        val second = catalog.beginScan(setOf("tree-a", "tree-b"))
        catalog.publish(second, mapOf("b" to SharedCatalog.Entry("tree-b", "file-b")))
        assertThrows(FileNotFoundException::class.java) { catalog.lookup("a") }
        assertEquals("tree-b", catalog.lookup("b").directory)
    }

    @Test fun rescanKeepsServingRetainedRootsUntilPublication() {
        val catalog = SharedCatalog<String>()
        val first = catalog.clear()
        catalog.publish(first, mapOf(
            "a" to SharedCatalog.Entry("tree-a", "first"),
            "b" to SharedCatalog.Entry("tree-b", "removed")))
        val read = catalog.lookup("a")
        catalog.beginScan(setOf("tree-a"))
        // A transfer in progress and new reads both continue during the scan.
        catalog.assertCurrent("a", read)
        assertEquals("first", catalog.lookup("a").entry)
        // A root removed from sharing stops immediately.
        assertThrows(FileNotFoundException::class.java) { catalog.lookup("b") }
    }

    @Test fun republishingTheSameFileKeepsItsReadValid() {
        val catalog = SharedCatalog<String>()
        catalog.publish(catalog.clear(), mapOf("a" to SharedCatalog.Entry("tree-a", "same")))
        val read = catalog.lookup("a")
        val ticket = catalog.beginScan(setOf("tree-a"))
        catalog.publish(ticket, mapOf("a" to SharedCatalog.Entry("tree-a", "same")))
        catalog.assertCurrent("a", read)
    }

    @Test fun readEndsWhenItsFileIsChangedOrRemovedByRescan() {
        val catalog = SharedCatalog<String>()
        catalog.publish(catalog.clear(), mapOf(
            "a" to SharedCatalog.Entry("tree-a", "old"),
            "b" to SharedCatalog.Entry("tree-a", "kept")))
        val changed = catalog.lookup("a")
        val removed = catalog.lookup("b")
        val ticket = catalog.beginScan(setOf("tree-a"))
        catalog.publish(ticket, mapOf("a" to SharedCatalog.Entry("tree-a", "new")))
        assertThrows(CancellationException::class.java) { catalog.assertCurrent("a", changed) }
        assertThrows(CancellationException::class.java) { catalog.assertCurrent("b", removed) }
    }

    @Test fun staleScanCannotPublishAfterNewScanStarts() {
        val catalog = SharedCatalog<String>()
        val first = catalog.beginScan(emptySet())
        val second = catalog.beginScan(emptySet())
        assertThrows(CancellationException::class.java) {
            catalog.publish(first, mapOf("a" to SharedCatalog.Entry("folder-a", "first")))
        }
        catalog.publish(second, mapOf("b" to SharedCatalog.Entry("folder-b", "second")))
        assertEquals("folder-b", catalog.lookup("b").directory)
        assertThrows(FileNotFoundException::class.java) { catalog.lookup("a") }
    }

    @Test fun failedCurrentScanRevokesButStaleFailureDoesNot() {
        val catalog = SharedCatalog<String>()
        catalog.publish(catalog.clear(), mapOf("a" to SharedCatalog.Entry("folder-a", "first")))
        val stale = catalog.beginScan(setOf("folder-a"))
        val current = catalog.beginScan(setOf("folder-a"))
        catalog.failScan(stale)
        assertEquals("first", catalog.lookup("a").entry)
        catalog.failScan(current)
        assertThrows(SecurityException::class.java) { catalog.lookup("a") }
    }

    @Test fun clearingCancelsRunningScan() {
        val catalog = SharedCatalog<String>()
        val ticket = catalog.beginScan(setOf("folder-a"))
        catalog.clear()
        assertThrows(CancellationException::class.java) { catalog.assertScan(ticket) }
    }

    @Test fun stalePermissionFailureCannotRevokeCurrentScan() {
        val catalog = SharedCatalog<String>()
        catalog.publish(catalog.clear(), mapOf("a" to SharedCatalog.Entry("folder-a", "first")))
        val oldRead = catalog.lookup("a")
        val second = catalog.clear()
        catalog.revoke("a", oldRead)
        catalog.publish(second, mapOf("b" to SharedCatalog.Entry("folder-b", "second")))
        catalog.revoke("a", oldRead)
        assertEquals("second", catalog.lookup("b").entry)
    }

    @Test fun permissionFailureOnRemovedRootCannotRevokeRetainedRoots() {
        val catalog = SharedCatalog<String>()
        catalog.publish(catalog.clear(), mapOf(
            "a" to SharedCatalog.Entry("folder-a", "kept"),
            "b" to SharedCatalog.Entry("folder-b", "removed")))
        val removedRead = catalog.lookup("b")
        catalog.beginScan(setOf("folder-a"))
        catalog.revoke("b", removedRead)
        assertEquals("kept", catalog.lookup("a").entry)
    }

    @Test fun permissionFailureOnRemovedFileCannotRevokeRetainedRootOrNextScan() {
        val catalog = SharedCatalog<String>()
        catalog.publish(catalog.clear(), mapOf(
            "a" to SharedCatalog.Entry("folder", "removed"),
            "b" to SharedCatalog.Entry("folder", "kept")))
        val removedRead = catalog.lookup("a")
        val entries = mapOf("b" to SharedCatalog.Entry("folder", "kept"))
        catalog.publish(catalog.beginScan(setOf("folder")), entries)
        val nextScan = catalog.beginScan(setOf("folder"))

        catalog.revoke("a", removedRead)

        assertEquals("kept", catalog.lookup("b").entry)
        catalog.publish(nextScan, entries)
        assertThrows(FileNotFoundException::class.java) { catalog.lookup("a") }
    }

    @Test fun permissionFailureOnReplacedFileCannotRevokeItsReplacement() {
        val catalog = SharedCatalog<String>()
        catalog.publish(catalog.clear(), mapOf("a" to SharedCatalog.Entry("folder", "old")))
        val oldRead = catalog.lookup("a")
        catalog.publish(catalog.beginScan(setOf("folder")),
            mapOf("a" to SharedCatalog.Entry("folder", "replacement")))

        catalog.revoke("a", oldRead)

        assertEquals("replacement", catalog.lookup("a").entry)
    }

    @Test fun currentPermissionFailureRevokesAllCurrentFiles() {
        val catalog = SharedCatalog<String>()
        val entries = mapOf(
            "a" to SharedCatalog.Entry("folder-a", "first"),
            "b" to SharedCatalog.Entry("folder-b", "second"))
        catalog.publish(catalog.clear(), entries)
        val read = catalog.lookup("a")
        // Unchanged files remain current across a successful rescan.
        catalog.publish(catalog.beginScan(setOf("folder-a", "folder-b")), entries)
        val nextScan = catalog.beginScan(setOf("folder-a", "folder-b"))
        catalog.revoke("a", read)
        assertThrows(SecurityException::class.java) { catalog.lookup("a") }
        assertThrows(SecurityException::class.java) { catalog.lookup("b") }
        assertThrows(CancellationException::class.java) { catalog.assertCurrent("a", read) }
        assertThrows(CancellationException::class.java) { catalog.assertScan(nextScan) }
    }

    @Test fun publicationCopiesTheInputMap() {
        val catalog = SharedCatalog<String>()
        val current = catalog.clear()
        val files = mutableMapOf("a" to SharedCatalog.Entry("folder-a", "first"))
        catalog.publish(current, files)
        files["a"] = SharedCatalog.Entry("folder-a", "changed")
        files["b"] = SharedCatalog.Entry("folder-a", "new")
        assertEquals("first", catalog.lookup("a").entry)
        assertThrows(FileNotFoundException::class.java) { catalog.lookup("b") }
    }

    @Test fun lightweightMetadataCatalogueHasNoOld2000ItemLimit() {
        val catalog = SharedCatalog<Int>()
        val generation = catalog.clear()
        catalog.publish(generation, (0 until 10_000).associate { "media-$it" to SharedCatalog.Entry("photos", it) })
        assertEquals(9999, catalog.lookup("media-9999").entry)
        assertEquals(0, catalog.lookup("media-0").entry)
    }

    @Test fun thumbnailOrRangeSnapshotCannotReturnAfterSharingStops() {
        val catalog = SharedCatalog<String>()
        val generation = catalog.clear()
        catalog.publish(generation, mapOf("id" to SharedCatalog.Entry("photos", "uri")))
        val read = catalog.lookup("id")
        catalog.clear()
        assertThrows(CancellationException::class.java) { catalog.assertCurrent("id", read) }
    }
}
