package com.actionhalo.android

/** Portable vector counterparts of the desktop action symbols. */
object ActionIcons {
    internal const val CLIPBOARD_RETRY_ID = "clipboard_read_retry"
    val options: Map<String, Int> = linkedMapOf(
        "copy" to R.drawable.ic_action_copy,
        "globe" to R.drawable.ic_action_globe,
        "link" to R.drawable.ic_action_link,
        "share" to R.drawable.ic_action_share,
        "search" to R.drawable.ic_action_search,
        "book" to R.drawable.ic_action_book,
        "film" to R.drawable.ic_action_film,
        "books" to R.drawable.ic_action_books,
        "earth" to R.drawable.ic_action_earth,
        "telegram" to R.drawable.ic_action_telegram,
        "google" to R.drawable.ic_action_google,
        "translate" to R.drawable.ic_action_translate,
        "baidu" to R.drawable.ic_action_baidu,
        "douban" to R.drawable.ic_action_douban,
    )

    fun resource(action: HaloAction): Int = when {
        action.id == CLIPBOARD_RETRY_ID -> R.drawable.ic_action_retry
        action.type == ActionType.EDIT_TEXT -> R.drawable.ic_action_edit
        else -> options.getValue(key(action))
    }

    fun key(action: HaloAction): String = action.icon?.takeIf { it in options } ?: when (action.id) {
        "google" -> "google"
        "translate" -> "translate"
        "baidu" -> "baidu"
        "douban" -> "douban"
        "douban_book" -> "book"
        "douban_movie" -> "film"
        "neodb", "neodb_book" -> "books"
        "github" -> "earth"
        else -> when (action.type) {
            ActionType.COPY -> "copy"
            ActionType.SHARE -> "share"
            ActionType.DOUBAN_SEARCH -> "search"
            ActionType.DOUBAN_BOOK_SEARCH -> "book"
            ActionType.DOUBAN_MOVIE_SEARCH -> "film"
            ActionType.TELEGRAM_SEARCH -> "telegram"
            ActionType.URL, ActionType.OPEN_URL, ActionType.EDIT_TEXT -> "link"
        }
    }

    fun sizeDp(actionCount: Int): Float = when {
        actionCount <= 6 -> 32f
        actionCount <= 8 -> 30f
        actionCount <= 12 -> 26f
        else -> 22f
    }
}
