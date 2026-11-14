package com.actionhalo.android

/** Volatile process-local metadata only: never retains selected text, apps, or browsing history. */
internal object SelectionDiagnostics {
    enum class Trace {
        SOURCE_PASSWORD, SOURCE_HIDDEN, SOURCE_SENSITIVE, SOURCE_OWN_APP, SOURCE_ACCESS_DENIED,
        MENU_CHECK_BLOCKED, MENU_NO_FOREGROUND, MENU_FOREGROUND_UNREADABLE, MENU_APP_DISABLED,
        MENU_NO_CHILD_WINDOW, MENU_SOURCE_MISMATCH, MENU_UNREADABLE, MENU_NO_COPY, MENU_AMBIGUOUS,
        MENU_MATCHED, MENU_STALE, MENU_ACCESS_DENIED, MENU_LONG_PRESS, MENU_RANGE_UNAVAILABLE,
        MENU_COLLAPSED, MENU_RESET, MENU_HOST_OBSCURED, MENU_HOST_REPLACED, MENU_MISSING,
        MENU_NO_ACTIONS, HALO_ATTACHED, HALO_DETACHED, HALO_OUTSIDE_TOUCH,
        HALO_WAITING_MENU, HALO_NO_SPACE, HALO_HANDLE_PASSTHROUGH, HALO_VISIBLE, HALO_USER_CLOSED,
    }
    private val traces = ArrayDeque<Pair<Trace, Long>>()
    enum class MenuRejection { HIDDEN, PASSWORD, EDITABLE, SENSITIVE, UNSUPPORTED_CONTROL, TRUNCATED }
    private var menuRejections: Set<MenuRejection> = emptySet()
    private var menuProbe: Trace? = null
    private var menuProbeAt = 0L

    fun trace(value: Trace) {
        if (traces.lastOrNull()?.first == value) traces.removeLast()
        traces.addLast(value to System.nanoTime())
        while (traces.size > 24) traces.removeFirst()
    }

    fun menuProbe(value: Trace, rejections: Set<MenuRejection> = emptySet()) {
        if (menuProbe != value) trace(value)
        menuProbe = value
        menuProbeAt = System.nanoTime()
        menuRejections = rejections.toSet()
    }

    fun triggerReport(): String {
        val now = System.nanoTime()
        fun age(time: Long) = ((now - time) / 1_000_000).coerceAtLeast(0)
        return buildString {
            appendLine("menu_probe=${menuProbe?.name ?: "NONE"}")
            appendLine("menu_probe_age_ms=${if (menuProbe == null) -1 else age(menuProbeAt)}")
            appendLine("menu_node_rejections=" + menuRejections.joinToString(",") { it.name })
            appendLine("trigger_recent_ms_ago=" + traces.joinToString(">") { (value, time) -> "${age(time)}:${value.name}" })
        }
    }

    enum class Result(val message: Int) {
        WAITING(R.string.diagnostic_waiting),
        APP_DISABLED(R.string.advice_app_disabled_title),
        APP_PAUSED(R.string.source_app_paused),
        RECEIVED(R.string.diagnostic_received),
        LONG_PRESS_ONLY(R.string.selection_long_press_only),
        NO_SOURCE(R.string.diagnostic_no_source),
        NO_TEXT(R.string.diagnostic_no_text),
        NO_RANGE(R.string.diagnostic_no_range),
        FILTERED(R.string.diagnostic_filtered),
        COLLAPSED(R.string.diagnostic_collapsed),
        STALE(R.string.diagnostic_stale),
        WINDOW_CHANGED(R.string.diagnostic_window_changed),
        NO_ACTIONS(R.string.no_actions),
        TEST_SHOWN(R.string.diagnostic_test_shown),
        COPY_RECEIVED(R.string.diagnostic_copy_received),
        COPY_SHOWN(R.string.diagnostic_copy_shown),
        COPY_UNCONFIRMED(R.string.diagnostic_copy_unconfirmed),
        SHOWN(R.string.diagnostic_shown),
        BLOCKED(R.string.diagnostic_blocked),
    }

    var updatedAt: Long = 0L
        private set
    var selectionEvents: Int = 0
        private set
    var result: Result = Result.WAITING
        private set
    var eventRange: Pair<Int, Int>? = null
        private set
    var nodeRange: Pair<Int, Int>? = null
        private set
    var nonemptyEventRanges: Int = 0
        private set
    var nonemptyNodeRanges: Int = 0
        private set

    fun received() {
        selectionEvents += 1
    }

    fun inspectRanges(eventStart: Int, eventEnd: Int, nodeStart: Int?, nodeEnd: Int?) {
        val eventNonempty = eventStart >= 0 && eventEnd >= 0 && eventStart != eventEnd
        val nodeNonempty = nodeStart != null && nodeEnd != null && nodeStart >= 0 && nodeEnd >= 0 && nodeStart != nodeEnd
        if (eventNonempty) nonemptyEventRanges += 1
        if (nodeNonempty) nonemptyNodeRanges += 1
        // Returning to the launcher often generates a collapse event. Retain only the most
        // recent nonempty range metadata, so that cleanup does not hide the useful sample.
        if (eventNonempty || nodeNonempty) {
            eventRange = eventStart to eventEnd
            nodeRange = if (nodeStart != null && nodeEnd != null) nodeStart to nodeEnd else null
        }
    }

    fun record(result: Result) {
        // Leaving the browser often collapses its selection. Keep the useful outcome visible
        // when the user returns here, instead of overwriting it with that expected cleanup.
        if (result == Result.COLLAPSED && this.result != Result.WAITING && this.result != Result.RECEIVED &&
            this.result != Result.TEST_SHOWN) return
        this.result = result
        updatedAt = System.nanoTime()
    }

    fun reset() {
        traces.clear()
        menuProbe = null
        menuProbeAt = 0L
        menuRejections = emptySet()
        updatedAt = 0L
        selectionEvents = 0
        result = Result.WAITING
        eventRange = null
        nodeRange = null
        nonemptyEventRanges = 0
        nonemptyNodeRanges = 0
    }
}
