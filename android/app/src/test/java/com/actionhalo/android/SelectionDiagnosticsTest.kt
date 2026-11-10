package com.actionhalo.android

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class SelectionDiagnosticsTest {
    @Before fun before() = SelectionDiagnostics.reset()
    @After fun after() = SelectionDiagnostics.reset()

    @Test fun triggerHistoryIsBoundedAndContainsOnlyFixedReasonsAndRelativeTimes() {
        repeat(30) {
            SelectionDiagnostics.trace(if (it % 2 == 0) SelectionDiagnostics.Trace.HALO_OUTSIDE_TOUCH
                else SelectionDiagnostics.Trace.HALO_WAITING_MENU)
        }
        SelectionDiagnostics.trace(SelectionDiagnostics.Trace.HALO_WAITING_MENU)
        val entries = SelectionDiagnostics.triggerReport().lineSequence()
            .single { it.startsWith("trigger_recent_ms_ago=") }.substringAfter('=').split('>')
        assertEquals(24, entries.size)
        assertTrue(entries.all { it.matches(Regex("[0-9]+:HALO_(OUTSIDE_TOUCH|WAITING_MENU)")) })
    }

    @Test fun menuProbeKeepsItsOwnSnapshotAndResetRemovesPriorAttempt() {
        val rejected = mutableSetOf(SelectionDiagnostics.MenuRejection.UNSUPPORTED_CONTROL)
        SelectionDiagnostics.menuProbe(SelectionDiagnostics.Trace.MENU_NO_COPY, rejected)
        rejected.clear()
        val report = SelectionDiagnostics.triggerReport()
        assertTrue(report.contains("menu_probe=MENU_NO_COPY\n"))
        assertTrue(report.contains("menu_node_rejections=UNSUPPORTED_CONTROL\n"))
        SelectionDiagnostics.reset()
        assertEquals("menu_probe=NONE\nmenu_probe_age_ms=-1\nmenu_node_rejections=\ntrigger_recent_ms_ago=\n",
            SelectionDiagnostics.triggerReport())
    }
}
