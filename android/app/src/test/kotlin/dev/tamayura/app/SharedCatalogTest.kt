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
        val second = catalog.clear()
        catalog.publish(second, mapOf("b" to SharedCatalog.Entry("tree-b", "file-b")))
        assertThrows(FileNotFoundException::class.java) { catalog.lookup("a") }
        assertEquals("tree-b", catalog.lookup("b").directory)
    }

    @Test fun startingAnotherScanImmediatelyRevokesPreviousFiles() {
        val catalog = SharedCatalog<String>()
        val first = catalog.clear()
        catalog.publish(first, mapOf("a" to SharedCatalog.Entry("folder-a", "first")))
        assertEquals("first", catalog.lookup("a").entry)
        catalog.clear()
        assertThrows(SecurityException::class.java) { catalog.lookup("a") }
    }

    @Test fun staleScanCannotPublishAfterNewScanStarts() {
        val catalog = SharedCatalog<String>()
        val first = catalog.clear()
        val second = catalog.clear()
        assertThrows(CancellationException::class.java) {
            catalog.publish(first, mapOf("a" to SharedCatalog.Entry("folder-a", "first")))
        }
        catalog.publish(second, mapOf("b" to SharedCatalog.Entry("folder-b", "second")))
        assertEquals("folder-b", catalog.lookup("b").directory)
        assertThrows(FileNotFoundException::class.java) { catalog.lookup("a") }
    }

    @Test fun stalePermissionFailureCannotRevokeCurrentScan() {
        val catalog = SharedCatalog<String>()
        val first = catalog.clear()
        catalog.publish(first, mapOf("a" to SharedCatalog.Entry("folder-a", "first")))
        val second = catalog.clear()
        catalog.revoke(first)
        catalog.publish(second, mapOf("b" to SharedCatalog.Entry("folder-b", "second")))
        catalog.revoke(first)
        assertEquals("second", catalog.lookup("b").entry)
    }

    @Test fun currentPermissionFailureRevokesAllCurrentFiles() {
        val catalog = SharedCatalog<String>()
        val current = catalog.clear()
        catalog.publish(current, mapOf("a" to SharedCatalog.Entry("folder-a", "first")))
        catalog.revoke(current)
        assertThrows(SecurityException::class.java) { catalog.lookup("a") }
        assertThrows(CancellationException::class.java) { catalog.assertGeneration(current) }
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

    @Test fun thumbnailOrRangeSnapshotCannotReturnAfterDirectoryChanges() {
        val catalog = SharedCatalog<String>()
        val generation = catalog.clear()
        catalog.publish(generation, mapOf("id" to SharedCatalog.Entry("photos", "uri")))
        val read = catalog.lookup("id")
        catalog.clear()
        assertThrows(CancellationException::class.java) { catalog.assertGeneration(read.generation) }
    }
}
