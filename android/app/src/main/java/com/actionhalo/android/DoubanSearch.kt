package com.actionhalo.android

/** Fixed first-party routes; custom actions continue to accept HTTP(S) templates only. */
object DoubanSearch {
    const val PACKAGE_NAME = "com.douban.frodo"

    // Published by https://m.douban.com/rexxar/api/v2/chart/hot_search_board.
    fun appUri(text: String): String =
        "douban://douban.com/search/result?q=${ActionUrls.encodeTextComponent(text)}"

    fun webTemplate(type: ActionType = ActionType.DOUBAN_SEARCH): String = when (type) {
        ActionType.DOUBAN_SEARCH -> "https://m.douban.com/search/?query={text}"
        ActionType.DOUBAN_BOOK_SEARCH -> "https://search.douban.com/book/subject_search?search_text={text}"
        ActionType.DOUBAN_MOVIE_SEARCH -> "https://search.douban.com/movie/subject_search?search_text={text}"
        else -> throw IllegalArgumentException("Not a Douban search: $type")
    }

    fun webUrl(text: String, type: ActionType = ActionType.DOUBAN_SEARCH): String =
        webTemplate(type).replace("{text}", ActionUrls.encodeTextComponent(text))
}
