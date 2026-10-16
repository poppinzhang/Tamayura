package dev.tamayura.app

import org.junit.Assert.*
import org.junit.Test

class DeviceIdentityTest {
    @Test fun identityUsesTheSystemValueAndNormalizesHexCase() {
        assertEquals("android-a1b2c3d4e5f60708", DeviceIdentity.read { " A1B2C3D4E5F60708 " })
        assertEquals("android-1", DeviceIdentity.read { "1" })
    }

    @Test fun repeatedReadsRemainStableWithoutApplicationState() {
        val first = DeviceIdentity.read { "a1b2c3d4e5f60708" }
        val restarted = DeviceIdentity.read { "a1b2c3d4e5f60708" }
        assertEquals(first, restarted)
        assertNotEquals(first, DeviceIdentity.read { "a1b2c3d4e5f60709" })
    }

    @Test fun missingAndMalformedIdsFailInsteadOfGeneratingNewIdentities() {
        for (value in listOf(null, "", "   ", "null", "not-hex", "a".repeat(17))) {
            assertThrows(DeviceIdentityUnavailableException::class.java) {
                DeviceIdentity.read { value }
            }
        }
    }

    @Test fun systemReadFailuresHaveAnIdentitySpecificError() {
        val cause = SecurityException("unavailable")
        val error = assertThrows(DeviceIdentityUnavailableException::class.java) {
            DeviceIdentity.read { throw cause }
        }
        assertSame(cause, error.cause)
    }

    @Test fun systemDeviceNameIsUsedForPeopleAndCanChangeIndependently() {
        assertEquals("我的手机", DeviceIdentity.displayName(" 我的手机 ", "Google", "Pixel"))
        assertEquals("旅行手机", DeviceIdentity.displayName("旅行手机", "Google", "Pixel"))
        assertEquals("android-a1b2c3d4e5f60708", DeviceIdentity.read { "a1b2c3d4e5f60708" })
    }

    @Test fun missingDeviceNamesUseManufacturerAndModel() {
        assertEquals("Google Pixel", DeviceIdentity.displayName(null, "Google", "Pixel"))
        assertEquals("Pixel", DeviceIdentity.displayName(" ", "Pixel", "Pixel"))
        assertEquals("Pixel", DeviceIdentity.displayName(null, " ", "Pixel"))
        assertEquals("Android", DeviceIdentity.displayName(null, null, null))
    }
}
