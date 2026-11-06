package com.actionhalo.android

import org.junit.Assert.*
import org.junit.Test

class AndroidVersionTest {
    @Test fun comparesNumericComponentsRatherThanStrings() {
        assertTrue(AndroidVersion.parse("0.10.0")!! > AndroidVersion.parse("0.9.99")!!)
        assertTrue(AndroidVersion.parse("1.0.0")!! > AndroidVersion.parse("0.999.999")!!)
        assertEquals(0, AndroidVersion.parse("0.8.0")!!.compareTo(AndroidVersion.parse("0.8.0")!!))
    }

    @Test fun rejectsAmbiguousPrereleaseAndOverflowValues() {
        listOf("v0.8.0", "0.8", "0.8.0-debug", "01.8.0", "0.-1.0", "0.8.9999999999999999999999", " 0.8.0").forEach {
            assertNull(it, AndroidVersion.parse(it))
        }
    }
}
