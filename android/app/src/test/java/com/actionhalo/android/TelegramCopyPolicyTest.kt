package com.actionhalo.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TelegramCopyPolicyTest {
    @Test fun acceptsOnlyCopyCommandsFromOfficialTelegramButtonClasses() {
        assertTrue(matches("org.telegram.messenger", "Copy"))
        assertTrue(matches("org.telegram.messenger.web", "复制"))
        assertTrue(matches("org.telegram.messenger", "複製"))
        assertFalse(matches("com.example.other", "Copy"))
        assertFalse(matches("org.telegram.messenger.fake", "Copy"))
        assertFalse(matches("org.telegram.messenger", "Copy link"))
        assertFalse(matches("org.telegram.messenger", "Translate"))
        assertFalse(matches("org.telegram.messenger", ""))
        assertFalse(TelegramCopyPolicy.isCopyClick("org.telegram.messenger",
            "org.telegram.ui.Cells.ChatMessageCell", listOf("Copy"), "Copy"))
        assertFalse(TelegramCopyPolicy.isCopyClick("org.telegram.messenger",
            "android.widget.LinearLayout", listOf("Copy", "A message"), "Copy"))
    }

    @Test fun supportsTheSystemCopyLabelWithoutGuessingUnknownTranslations() {
        assertTrue(TelegramCopyPolicy.isCopyClick("org.telegram.messenger",
            "android.widget.LinearLayout", listOf("Kopieren"), "Kopieren"))
        assertFalse(TelegramCopyPolicy.isCopyClick("org.telegram.messenger",
            "android.widget.LinearLayout", listOf("Kopieren"), "Copy"))
    }

    @Test fun menuDiscoveryUsesExactLabelsAndOfficialPackages() {
        assertTrue(TelegramCopyPolicy.supportsPackage("org.telegram.messenger"))
        assertTrue(TelegramCopyPolicy.supportsPackage("org.telegram.messenger.web"))
        assertFalse(TelegramCopyPolicy.supportsPackage(null))
        assertFalse(TelegramCopyPolicy.supportsPackage("org.telegram.messenger.fake"))
        assertTrue(TelegramCopyPolicy.isCopyLabel(" Copy ", "Copy"))
        assertTrue(TelegramCopyPolicy.isCopyLabel("复制", "Copy"))
        assertTrue(TelegramCopyPolicy.isCopyLabel("Kopieren", "Kopieren"))
        assertFalse(TelegramCopyPolicy.isCopyLabel("Copy link", "Copy"))
        assertFalse(TelegramCopyPolicy.isCopyLabel("This message says Copy", "Copy"))
        assertFalse(TelegramCopyPolicy.isCopyLabel("", ""))
    }

    @Test fun delayedOrFutureEventsDoNotReadTheClipboard() {
        assertTrue(TelegramCopyPolicy.isRecentEvent(10_000, 10_100))
        assertFalse(TelegramCopyPolicy.isRecentEvent(0, 100))
        assertFalse(TelegramCopyPolicy.isRecentEvent(10_000, 14_001))
        assertFalse(TelegramCopyPolicy.isRecentEvent(10_001, 10_000))
    }

    @Test fun failedCopyDoesNotReuseOldClipboardContent() {
        assertTrue(TelegramCopyPolicy.isFreshClip(9_990, 10_000, 9_000))
        assertTrue(TelegramCopyPolicy.isFreshClip(10_010, 10_000, 9_000))
        assertFalse(TelegramCopyPolicy.isFreshClip(0, 10_000, 9_000))
        assertFalse(TelegramCopyPolicy.isFreshClip(5_000, 10_000, 9_000))
        assertFalse(TelegramCopyPolicy.isFreshClip(11_000, 10_000, 9_000))
        assertFalse(TelegramCopyPolicy.isFreshClip(10_000, 0, 9_000))
        // A copy from a moment ago is still stale if it preceded this menu opening.
        assertFalse(TelegramCopyPolicy.isFreshClip(9_900, 10_000, 9_950))
        assertFalse(TelegramCopyPolicy.isFreshClip(9_950, 10_000, 9_950))
        assertFalse(TelegramCopyPolicy.isFreshClip(9_990, 10_000, 0))
    }

    @Test fun assistedCopyAcceptsOnlyTheInclusiveActionInterval() {
        assertTrue(TelegramCopyPolicy.isFreshAssistedClip(10_000, 10_000, 10_000))
        assertTrue(TelegramCopyPolicy.isFreshAssistedClip(10_000, 10_000, 10_010))
        assertTrue(TelegramCopyPolicy.isFreshAssistedClip(10_005, 10_000, 10_010))
        assertTrue(TelegramCopyPolicy.isFreshAssistedClip(10_010, 10_000, 10_010))
        // Even a clip just one millisecond before the user's action is stale.
        assertFalse(TelegramCopyPolicy.isFreshAssistedClip(9_999, 10_000, 10_010))
        assertFalse(TelegramCopyPolicy.isFreshAssistedClip(10_011, 10_000, 10_010))
    }

    @Test fun assistedCopyRejectsInvalidOrOverlongActionIntervals() {
        assertFalse(TelegramCopyPolicy.isFreshAssistedClip(0, 0, 10))
        assertFalse(TelegramCopyPolicy.isFreshAssistedClip(10, -1, 10))
        assertFalse(TelegramCopyPolicy.isFreshAssistedClip(10_000, 10_000, 9_999))
        assertTrue(TelegramCopyPolicy.isFreshAssistedClip(14_000, 10_000, 14_000))
        assertFalse(TelegramCopyPolicy.isFreshAssistedClip(10_001, 10_000, 14_001))
        assertFalse(TelegramCopyPolicy.isFreshAssistedClip(Long.MAX_VALUE, 1, Long.MAX_VALUE))
    }

    private fun matches(pkg: String, label: String) = TelegramCopyPolicy.isCopyClick(
        pkg, "android.widget.LinearLayout", listOf(label), "Copy")
}
