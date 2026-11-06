package com.actionhalo.android

import java.net.URI
import java.net.URLEncoder

enum class ActionType { COPY, URL, OPEN_URL, SHARE, DOUBAN_SEARCH, DOUBAN_BOOK_SEARCH, DOUBAN_MOVIE_SEARCH, TELEGRAM_SEARCH, EDIT_TEXT }

data class HaloAction(
    val id: String,
    val title: String,
    val symbol: String,
    val type: ActionType,
    val template: String? = null,
    val icon: String? = null,
)

/** URL handling is deliberately independent of Android so its boundary rules can be tested. */
object ActionUrls {
    private const val PLACEHOLDER = "{text}"
    private const val VALIDATION_TEXT = "actionhaloselectedtext"

    fun validateTemplate(template: String): Boolean {
        if (!template.contains(PLACEHOLDER)) return false
        parseWebUrl(template.replace(PLACEHOLDER, VALIDATION_TEXT)) ?: return false
        // Selected text may be a path/query/fragment component, never the destination host.
        val authorityStart = template.indexOf("://") + 3
        val authorityEnd = template.indexOfAny(charArrayOf('/', '?', '#'), authorityStart)
            .let { if (it < 0) template.length else it }
        return !template.substring(authorityStart, authorityEnd).contains(PLACEHOLDER)
    }

    fun build(template: String, text: String): String? {
        if (!validateTemplate(template)) return null
        return parseWebUrl(template.replace(PLACEHOLDER, encodeTextComponent(text)))?.toASCIIString()
    }

    internal fun encodeTextComponent(text: String): String = URLEncoder.encode(text, "UTF-8")
            .replace("+", "%20")
            .replace("*", "%2A")
            .replace("%7E", "~")

    fun normalizeOpenUrl(text: String): String? {
        val input = text.trim()
        if (input.isEmpty()) return null
        val explicitHttp = input.startsWith("https://", ignoreCase = true) ||
            input.startsWith("http://", ignoreCase = true)
        if (!explicitHttp && input.contains("://")) return null
        val uri = parseWebUrl(if (explicitHttp) input else "https://$input") ?: return null
        if (!explicitHttp && !uri.host.contains('.') && uri.host != "localhost" &&
            !uri.host.startsWith('[')
        ) return null
        return uri.toASCIIString()
    }

    private fun parseWebUrl(value: String): URI? {
        if (value.any { it.isWhitespace() || it.isISOControl() }) return null
        val uri = try {
            URI(value)
        } catch (_: Exception) {
            return null
        }
        if (!uri.scheme.equals("http", ignoreCase = true) &&
            !uri.scheme.equals("https", ignoreCase = true)
        ) return null
        if (uri.host.isNullOrBlank() || uri.rawUserInfo != null) return null
        if (uri.port != -1 && uri.port !in 1..65535) return null
        return uri
    }
}
