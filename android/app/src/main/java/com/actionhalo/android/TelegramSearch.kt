package com.actionhalo.android

object TelegramSearch {
    val packages = listOf("org.telegram.messenger", "org.telegram.messenger.web")

    // Telegram Android 12.10.6 handles this route in LaunchActivity; it does not compose a message.
    fun appUri(text: String): String =
        "tg://search?query=${ActionUrls.encodeTextComponent(text)}"
}
