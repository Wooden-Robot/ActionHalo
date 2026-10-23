package com.actionhalo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ActionUrlsTest {
    @Test fun acceptsPathQueryAndFragmentTemplates() {
        assertTrue(ActionUrls.validateTemplate("https://example.com/search?q={text}"))
        assertTrue(ActionUrls.validateTemplate("https://example.com/{text}"))
        assertTrue(ActionUrls.validateTemplate("http://example.com/#text={text}"))
        assertTrue(ActionUrls.validateTemplate("https://example.com?q={text}"))
        assertTrue(ActionUrls.validateTemplate("https://actionhaloselectedtext.com?q={text}"))
    }

    @Test fun rejectsExecutableSchemesMissingPlaceholderAndDynamicHost() {
        listOf(
            "javascript:alert('{text}')",
            "file:///sdcard/{text}",
            "intent://example.com/{text}",
            "https://example.com/search",
            "https://{text}.example.com/search",
            "https://user:pass@example.com/search?q={text}",
            "https://example.com/search?q={text}\n",
            "https://example.com:70000/?q={text}",
            "https://example.com/{other}?q={text}",
        ).forEach { assertFalse(it, ActionUrls.validateTemplate(it)) }
    }

    @Test fun percentEncodesTextOnceWithoutAllowingQueryInjection() {
        assertEquals(
            "https://example.com/?q=%E4%BD%A0%E5%A5%BD%20%26x%3D1%2F%23%3F%25%2B",
            ActionUrls.build("https://example.com/?q={text}", "你好 &x=1/#?%+"),
        )
    }

    @Test fun preservesLiteralPercentEncodedInputAsText() {
        assertEquals("https://example.com/?q=a%2520b", ActionUrls.build("https://example.com/?q={text}", "a%20b"))
    }

    @Test fun encodesRepeatedPlaceholderAndPathSegments() {
        assertEquals(
            "https://example.com/a%2Fb?copy=a%2Fb",
            ActionUrls.build("https://example.com/{text}?copy={text}", "a/b"),
        )
    }

    @Test fun expandsBareDomainAndKeepsExplicitHttp() {
        assertEquals("https://example.com/docs?q=test", ActionUrls.normalizeOpenUrl(" example.com/docs?q=test "))
        assertEquals("http://example.com/a", ActionUrls.normalizeOpenUrl("http://example.com/a"))
        assertEquals("https://example.com:8443/a", ActionUrls.normalizeOpenUrl("example.com:8443/a"))
    }

    @Test fun rejectsNonLinksAndNonWebSchemes() {
        listOf(
            "", "some selected text", "hello", "javascript:alert(1)",
            "file:///sdcard/a", "intent://example.com", "mailto:me@example.com", "custom.app://example.com",
            "https://user@example.com", "https://example.com\\@evil.com",
            "https://example.com/\nsecret", "https://example.com:70000/",
        ).forEach { assertNull(it, ActionUrls.normalizeOpenUrl(it)) }
    }
}
