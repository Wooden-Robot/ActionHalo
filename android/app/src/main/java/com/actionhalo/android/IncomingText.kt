package com.actionhalo.android

/** Bound work and Intent payloads without silently changing a user's selected text. */
internal object IncomingText {
    const val MAX_LENGTH = 32_768
    fun isUsable(text: CharSequence?): Boolean =
        text != null && text.length <= MAX_LENGTH && text.any { !it.isWhitespace() }
}
