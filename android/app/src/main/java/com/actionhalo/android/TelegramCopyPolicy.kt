package com.actionhalo.android

/** Recognize a copy command, never infer selected text from a message's accessibility label. */
internal object TelegramCopyPolicy {
    const val SETTING = "telegram_copy_popup_enabled"
    const val STANDARD_MENU_SETTING = "standard_selection_menu_enabled"
    const val STANDARD_MENU_CONTAINER_ID = "android:id/floating_popup_container"
    const val STANDARD_MENU_ITEM_ID = "android:id/floating_toolbar_menu_item_text"
    const val MAX_EVENT_AGE_MS = 4_000L
    private val packages = setOf("org.telegram.messenger", "org.telegram.messenger.web")
    private val buttonClasses = setOf(
        "android.widget.LinearLayout", "android.widget.FrameLayout", "android.widget.TextView",
        "android.widget.Button", "android.widget.ImageButton",
    )
    // Telegram can use custom language packs. Unknown labels intentionally require the manual tile.
    private val copyLabels = setOf("Copy", "COPY", "复制", "複製", "拷貝")

    fun supportsPackage(packageName: String?): Boolean = packageName in packages

    fun supportsSource(packageName: String?, className: String?): Boolean =
        supportsPackage(packageName) && supportsButtonClass(className)

    fun supportsButtonClass(className: String?): Boolean = className in buttonClasses

    fun isCopyLabel(label: String, systemCopyLabel: String): Boolean =
        label.trim() in copyLabels || (systemCopyLabel.isNotBlank() && label.trim() == systemCopyLabel)

    fun isCopyClick(packageName: String?, className: String?, labels: List<String>, systemCopyLabel: String): Boolean {
        fun isCopy(label: String) = isCopyLabel(label, systemCopyLabel)
        return supportsSource(packageName, className) && labels.any(::isCopy) &&
            labels.all { it.isBlank() || isCopy(it) }
    }

    fun isRecentEvent(eventUptime: Long, nowUptime: Long): Boolean =
        eventUptime > 0 && nowUptime - eventUptime in 0..MAX_EVENT_AGE_MS

    /** The clip must postdate this menu window, as well as be close to its Copy click. */
    fun isFreshClip(clipTimestamp: Long, eventWallTime: Long, menuOpenedWallTime: Long): Boolean =
        clipTimestamp > 0 && menuOpenedWallTime > 0 && menuOpenedWallTime <= eventWallTime &&
            clipTimestamp > menuOpenedWallTime && clipTimestamp - eventWallTime in -2_000..250

    /** A user-requested Copy must write during that action, never before it began. */
    fun isFreshAssistedClip(clipTimestamp: Long, copyStartedWallTime: Long, copyFinishedWallTime: Long): Boolean =
        copyStartedWallTime > 0 && copyFinishedWallTime >= copyStartedWallTime &&
            copyFinishedWallTime - copyStartedWallTime <= MAX_EVENT_AGE_MS &&
            clipTimestamp in copyStartedWallTime..copyFinishedWallTime
}
