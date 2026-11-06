package com.actionhalo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SelectionPolicyTest {
    @Test fun onlyExtractsTheSelectedSubstring() {
        val range = SelectionPolicy.range(11, 6, 11)!!
        assertEquals("world", SelectionPolicy.selectedText("hello world", range))
    }

    @Test fun normalizesReverseSelections() {
        assertEquals(SelectionPolicy.Range(2, 5), SelectionPolicy.range(6, 5, 2))
    }

    @Test fun rejectsCollapsedAndInvalidBounds() {
        assertNull(SelectionPolicy.range(6, 2, 2))
        assertNull(SelectionPolicy.range(6, -1, 2))
        assertNull(SelectionPolicy.range(6, 2, 7))
    }

    @Test fun rejectsOversizedSelectionWithoutTruncation() {
        assertNull(SelectionPolicy.range(32_769, 0, 32_769))
        assertEquals(SelectionPolicy.Range(0, 32_768), SelectionPolicy.range(32_769, 0, 32_768))
    }

    @Test fun rejectsWhitespaceAndStaleText() {
        assertNull(SelectionPolicy.selectedText(" \n ", SelectionPolicy.Range(0, 3)))
        assertNull(SelectionPolicy.selectedText("short", SelectionPolicy.Range(0, 10)))
        assertNull(SelectionPolicy.selectedText(null, SelectionPolicy.Range(0, 1)))
    }
}
