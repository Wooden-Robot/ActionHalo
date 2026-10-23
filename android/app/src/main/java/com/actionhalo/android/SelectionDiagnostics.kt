package com.actionhalo.android

/** Volatile process-local metadata only: never retains selected text, apps, or browsing history. */
internal object SelectionDiagnostics {
    enum class Result(val message: Int) {
        WAITING(R.string.diagnostic_waiting),
        APP_DISABLED(R.string.advice_app_disabled_title),
        APP_PAUSED(R.string.source_app_paused),
        RECEIVED(R.string.diagnostic_received),
        INITIAL_SELECTION(R.string.selection_initial_waiting),
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
        updatedAt = 0L
        selectionEvents = 0
        result = Result.WAITING
        eventRange = null
        nodeRange = null
        nonemptyEventRanges = 0
        nonemptyNodeRanges = 0
    }
}
