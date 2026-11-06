package com.actionhalo.android

import java.net.URI
import java.net.URLDecoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class TelegramSearchTest {
    @Test fun queryPreservesChineseEmojiAndLiteralPercentWithOneEncodingPass() {
        assertEquals(
            "tg://search?query=%E4%B8%89%E4%BD%93%20%F0%9F%9A%80%20%252F%20%2B",
            TelegramSearch.appUri("三体 🚀 %2F +"),
        )
    }

    @Test fun selectedTextCannotChangeTheRouteOrInjectSendParameters() {
        val selected = "hello&text=send&domain=someone#fragment?query=x\n中文"
        val uri = URI(TelegramSearch.appUri(selected))
        assertEquals("tg", uri.scheme)
        assertEquals("search", uri.host)
        assertEquals("", uri.path)
        assertEquals(null, uri.fragment)
        assertFalse(uri.rawQuery.contains('&'))
        assertEquals(selected, URLDecoder.decode(uri.rawQuery.removePrefix("query="), "UTF-8"))
    }

    @Test fun targetsOnlyOfficialAndroidPackagesInPreferredOrder() {
        assertEquals(
            listOf("org.telegram.messenger", "org.telegram.messenger.web"),
            TelegramSearch.packages,
        )
        assertFalse(ActionUrls.validateTemplate("tg://search?query={text}"))
    }
}
