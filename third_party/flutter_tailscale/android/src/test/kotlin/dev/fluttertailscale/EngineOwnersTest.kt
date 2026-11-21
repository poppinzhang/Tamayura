package dev.fluttertailscale

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class EngineOwnersTest {
    @Test fun detachReleasesEveryAttachedOwnerExactlyOnce() {
        val owners = EngineOwners()
        assertTrue(owners.register("foreground"))
        assertTrue(owners.register("foreground"))
        assertTrue(owners.register("task"))
        assertEquals(listOf("foreground", "task"), owners.detach().sorted())
        assertTrue(owners.detach().isEmpty())
        assertFalse(owners.register("late"))
    }

    @Test fun normalDartDisposeRemovesOwnerFromDetachCleanup() {
        val owners = EngineOwners()
        owners.register("task")
        owners.unregister("task")
        assertTrue(owners.detach().isEmpty())
    }

    @Test fun repeatedDisposeLeavesOtherOwnersForEngineCleanup() {
        val owners = EngineOwners()
        owners.register("foreground")
        owners.register("task")

        owners.unregister("foreground")
        owners.unregister("foreground")

        assertTrue(owners.isAttached())
        assertEquals(listOf("task"), owners.detach())
    }

    @Test fun nativeInitializationReturningAfterDetachMustBeDisposed() {
        val owners = EngineOwners()
        val started = CountDownLatch(1)
        val allowReturn = CountDownLatch(1)
        val disposed = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val initialization = executor.submit {
                assertTrue(owners.isAttached())
                started.countDown()
                assertTrue(allowReturn.await(3, TimeUnit.SECONDS))
                if (!owners.register("created-during-detach")) disposed.countDown()
            }
            assertTrue(started.await(3, TimeUnit.SECONDS))
            assertTrue(owners.detach().isEmpty())
            allowReturn.countDown()
            initialization.get(3, TimeUnit.SECONDS)
            assertTrue(disposed.await(3, TimeUnit.SECONDS))
        } finally { executor.shutdownNow() }
    }

    @Test fun detachAfterRegistrationStillOwnsCleanupBeforeReplyDelivery() {
        val owners = EngineOwners()
        assertTrue(owners.register("initialized"))
        assertEquals(listOf("initialized"), owners.detach())
        assertFalse(owners.isAttached())
    }
}
