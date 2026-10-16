package dev.tamayura.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StoragePathsTest {
    @Test fun sameParentAndChildAreRejectedInEitherSelectionOrder() {
        assertTrue(StoragePaths.externalStorageOverlap("primary:DCIM", "primary:DCIM")!!)
        assertTrue(StoragePaths.externalStorageOverlap("primary:DCIM", "primary:DCIM/Camera/2026")!!)
        assertTrue(StoragePaths.externalStorageOverlap("primary:DCIM/Camera", "primary:DCIM")!!)
        assertTrue(StoragePaths.externalStorageOverlap("primary:", "primary:Pictures")!!)
    }

    @Test fun sharedPrefixesAndSiblingPathsRemainDistinct() {
        assertFalse(StoragePaths.externalStorageOverlap("primary:DCIM", "primary:DCIM-copy")!!)
        assertFalse(StoragePaths.externalStorageOverlap("primary:DCIM/Camera", "primary:DCIM/Screenshots")!!)
        assertFalse(StoragePaths.externalStorageOverlap("primary:DCIM", "ABCD-1234:DCIM")!!)
    }

    @Test fun removableStorageCaseAliasesAreRejected() {
        assertTrue(StoragePaths.externalStorageOverlap("ABCD-1234:Pictures", "abcd-1234:pictures/Camera")!!)
    }

    @Test fun opaqueOrMalformedDocumentIdsCannotBeGuessed() {
        listOf("1234", ":DCIM", "primary:/DCIM", "primary:DCIM/../Pictures", "primary:DCIM//Camera")
            .forEach { assertNull(StoragePaths.externalStorageOverlap(it, "primary:DCIM")) }
    }

    @Test fun relativeHierarchyIncludesFileAndKeepsDuplicateBasenamesSeparate() {
        assertEquals("2026/旅行/photo.jpg", StoragePaths.relativePath("2026/旅行", "photo.jpg"))
        assertEquals("Camera/photo.jpg", StoragePaths.relativePath("Camera", "photo.jpg"))
        assertEquals("photo.jpg", StoragePaths.relativePath("", "photo.jpg"))
    }

    @Test fun rejectsTraversalSeparatorsAndControlsInsteadOfRewritingPaths() {
        listOf("", " ", ".", "..", "../photo.jpg", "a/b", "a\\b", "a\u0000b", "a\nb")
            .forEach { bad ->
                assertThrows(IllegalArgumentException::class.java) { StoragePaths.requireSegment(bad) }
                assertThrows(IllegalArgumentException::class.java) { StoragePaths.relativePath("Camera", bad) }
            }
        assertEquals("旅行 2026", StoragePaths.requireSegment("旅行 2026"))
    }

    @Test fun existingFilesReceiveUniqueNamesWithoutChangingExtensions() {
        assertEquals("photo.jpg", StoragePaths.availableFileName("photo.jpg", emptySet()))
        assertEquals("photo (3).jpg", StoragePaths.availableFileName(
            "photo.jpg", setOf("PHOTO.JPG", "photo (2).jpg")))
        assertEquals("video (2)", StoragePaths.availableFileName("video", setOf("video")))
        assertEquals(".hidden (2)", StoragePaths.availableFileName(".hidden", setOf(".hidden")))
    }
}
