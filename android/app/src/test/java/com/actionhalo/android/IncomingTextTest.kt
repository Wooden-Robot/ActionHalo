package com.actionhalo.android

import org.junit.Assert.*
import org.junit.Test

class IncomingTextTest {
    @Test fun rejectsMissingBlankAndOversizePayloads() {
        assertFalse(IncomingText.isUsable(null))
        assertFalse(IncomingText.isUsable(" \n\t"))
        assertFalse(IncomingText.isUsable("a".repeat(IncomingText.MAX_LENGTH + 1)))
    }

    @Test fun acceptsUnicodeAndExactLimit() {
        assertTrue(IncomingText.isUsable(" 中文 😀\n"))
        assertTrue(IncomingText.isUsable("a".repeat(IncomingText.MAX_LENGTH)))
    }
}
