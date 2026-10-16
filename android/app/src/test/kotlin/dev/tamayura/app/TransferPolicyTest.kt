package dev.tamayura.app

import org.junit.Assert.*
import org.junit.Test

class TransferPolicyTest {
    @Test fun taskIdentifiersRemainStableAcrossRestarts() {
        val initial = TransferPolicy.jobId("task-1", emptyMap())
        assertTrue(initial > 0)
        assertEquals(initial, TransferPolicy.jobId("task-1", emptyMap()))
        assertEquals(initial, TransferPolicy.jobId("task-1", mapOf(initial to "task-1")))
    }

    @Test fun hashCollisionsNeverOverwriteAnotherTask() {
        assertEquals(124, TransferPolicy.jobId("new-task", mapOf(123 to "existing-task")) { 123 })
        assertEquals(1, TransferPolicy.jobId("new-task", mapOf(Int.MAX_VALUE to "existing-task")) { Int.MAX_VALUE })
    }

    @Test fun persistedCollisionChoiceWinsOverHash() {
        assertEquals(456, TransferPolicy.jobId("task", mapOf(456 to "task")) { 123 })
    }

    @Test fun emptyOrUnboundedTaskIdentifiersAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { TransferPolicy.jobId("", emptyMap()) }
        assertThrows(IllegalArgumentException::class.java) { TransferPolicy.jobId("x".repeat(201), emptyMap()) }
    }

    @Test fun notificationProgressHandlesLargeFilesAndInvalidTotals() {
        assertEquals(500, TransferPolicy.progress(5_000_000_000, 10_000_000_000))
        assertEquals(0, TransferPolicy.progress(100, 0))
        assertEquals(0, TransferPolicy.progress(-1, 100))
        assertEquals(1000, TransferPolicy.progress(101, 100))
    }

    @Test fun imagePreviewPreservesAspectRatioAndNeverUpscales() {
        assertEquals(2560 to 1280, TransferPolicy.previewSize(8000, 4000, 2560))
        assertEquals(1280 to 2560, TransferPolicy.previewSize(4000, 8000, 2560))
        assertEquals(40 to 20, TransferPolicy.previewSize(40, 20, 2560))
        assertEquals(1 to 2560, TransferPolicy.previewSize(1, Int.MAX_VALUE, 2560))
    }

    @Test fun previewRejectsUnboundedDecodeDimensions() {
        assertThrows(IllegalArgumentException::class.java) { TransferPolicy.previewSize(8000, 8000, 2561) }
        assertThrows(IllegalArgumentException::class.java) { TransferPolicy.previewSize(0, 1, 2560) }
    }

    @Test fun sameTaskCannotRestartBeforeItsOldEngineAndIoDrain() {
        val gate = TransferRunGate()
        val first = gate.acquire("task")!!
        assertNull(gate.acquire("task"))
        assertTrue(gate.active("task"))
        assertTrue(gate.release("task", first))
        val second = gate.acquire("task")!!
        assertNotEquals(first, second)
        assertFalse(gate.release("task", first))
        assertTrue(gate.active("task"))
        assertTrue(gate.release("task", second))
    }

    @Test fun independentTasksCanOwnSeparateEngines() {
        val gate = TransferRunGate()
        val first = gate.acquire("first")!!
        val second = gate.acquire("second")!!
        assertTrue(gate.release("first", first))
        assertTrue(gate.active("second"))
        assertTrue(gate.release("second", second))
    }

    @Test fun cancellationDuringEngineDrainInvalidatesOnlyOldRequests() {
        val gate = TransferRequestGate()
        val oldRequest = gate.ticket("task")
        val otherRequest = gate.ticket("other")
        gate.cancel("task")
        assertFalse(gate.current("task", oldRequest))
        assertTrue(gate.current("other", otherRequest))
        val retry = gate.ticket("task")
        assertTrue(gate.current("task", retry))
    }
}
