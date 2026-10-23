package com.actionhalo.android

/** Bounds checks shared by accessibility intake and its JVM tests. */
internal object SelectionPolicy {
    const val MAX_TEXT_LENGTH = 32_768

    data class Range(val start: Int, val end: Int)

    fun range(textLength: Int, start: Int, end: Int): Range? {
        if (start < 0 || end < 0 || start > textLength || end > textLength || start == end) {
            return null
        }
        val lower = minOf(start, end)
        val upper = maxOf(start, end)
        if (upper - lower > MAX_TEXT_LENGTH) return null
        return Range(lower, upper)
    }

    fun selectedText(text: CharSequence?, selectedRange: Range): String? {
        if (text == null || range(text.length, selectedRange.start, selectedRange.end) != selectedRange) return null
        return text.subSequence(selectedRange.start, selectedRange.end).toString().takeUnless { it.isBlank() }
    }
}
