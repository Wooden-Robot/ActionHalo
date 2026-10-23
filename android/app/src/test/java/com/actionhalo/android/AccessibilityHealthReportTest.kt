package com.actionhalo.android

import org.junit.Assert.*
import org.junit.Test

class AccessibilityHealthReportTest {
    private val ownPackage = "com.actionhalo.android"
    private val ownClass = "$ownPackage.SelectionAccessibilityService"

    @Test fun configuredListUsesExactComponentsIncludingAndroidShortClassNames() {
        assertTrue(contains("other.app/.Reader:$ownPackage/.SelectionAccessibilityService"))
        assertTrue(contains("$ownPackage/$ownClass"))
        assertFalse(contains("$ownPackage/${ownClass}Fake"))
        assertFalse(contains("$ownPackage.fake/$ownClass"))
        assertFalse(contains("$ownPackage/$ownClass/extra"))
        assertFalse(contains("$ownPackage/SelectionAccessibilityService"))
        assertFalse(contains(null))
        assertFalse(contains(""))
    }

    @Test fun reportingPreservesConfiguredButUnboundStateInsteadOfCallingItPermissionOff() {
        val report = AccessibilityHealthReport.render(snapshot())
        assertTrue(report.contains("系统启用名单：开启"))
        assertTrue(report.contains("系统服务列表：未列出"))
        assertTrue(report.contains("当前服务连接：未连接"))
        assertTrue(report.contains("省电优化：仍受优化"))
        assertTrue(report.contains("CRASH"))
        assertTrue(report.contains("status=9"))
        assertTrue(report.contains("SETTING_OFF_OBSERVED"))
        assertTrue(report.contains("观察时间"))
    }

    @Test fun corruptHistoryCannotInjectChatTextIntoPersistedOrCopiedDiagnostics() {
        val privateBody = "PRIVATE_MESSAGE_DO_NOT_RECORD"
        val decoded = AccessibilityHealthReport.decodeEvents(
            "1:CONNECTED|2:$privateBody|3:UNBOUND|4:CRASH:$privateBody|-1:DESTROYED|bad:CONNECTED")
        assertEquals(listOf(HealthEvent(HealthEventKind.CONNECTED, 1), HealthEvent(HealthEventKind.UNBOUND, 3)), decoded)
        val encoded = AccessibilityHealthReport.encodeEvents(decoded)
        assertFalse(encoded.contains(privateBody))
        assertFalse(AccessibilityHealthReport.render(snapshot().copy(events = decoded)).contains(privateBody))
        assertFalse(AccessibilityHealthReport.render(snapshot()).contains(ownPackage))
    }

    @Test fun historyIsBoundedAndSurvivesSerializationWithOnlyKnownCategories() {
        var events = emptyList<HealthEvent>()
        (1L..40L).forEach { events = AccessibilityHealthReport.appendEvent(events, HealthEvent(HealthEventKind.CONNECTED, it)) }
        assertEquals(12, events.size)
        assertEquals(29L, events.first().timestamp)
        assertEquals(events, AccessibilityHealthReport.decodeEvents(AccessibilityHealthReport.encodeEvents(events)))
        assertEquals(events, AccessibilityHealthReport.appendEvent(events, HealthEvent(HealthEventKind.DESTROYED, -1)))
    }

    @Test fun unavailableStatusIsUnknownAndCannotBePresentedAsPermissionOff() {
        val report = AccessibilityHealthReport.render(snapshot().copy(configured = null, managerListed = null,
            battery = BatteryPolicy.UNKNOWN, processExit = null, events = emptyList()))
        assertTrue(report.contains("系统启用名单：未知"))
        assertTrue(report.contains("系统服务列表：未知"))
        assertTrue(report.contains("最近进程退出：无可用记录"))
    }

    @Test fun unavailableOrUnchangedSnapshotsDoNotInventSettingChanges() {
        assertNull(AccessibilityHealthReport.settingObservation(true, null, 100))
        assertNull(AccessibilityHealthReport.settingObservation(true, true, 100))
        assertNull(AccessibilityHealthReport.settingObservation(false, false, 100))
        assertEquals(HealthEvent(HealthEventKind.SETTING_OFF_OBSERVED, 100),
            AccessibilityHealthReport.settingObservation(true, false, 100))
        assertEquals(HealthEvent(HealthEventKind.SETTING_ON_OBSERVED, 100),
            AccessibilityHealthReport.settingObservation(null, true, 100))
    }

    private fun contains(value: String?) = AccessibilityHealthReport.containsOwnComponent(value, ownPackage, ownClass)
    private fun snapshot() = AccessibilityHealthSnapshot(
        capturedAt = 1_800_000_000_000,
        deviceModel = "vivo X200s", sdk = 35, appVersion = "0.6.0",
        configured = true, managerListed = false, connected = false,
        battery = BatteryPolicy.OPTIMIZED,
        processExit = ProcessExit(ExitReason.CRASH, 1_799_999_999_000, 9),
        events = listOf(HealthEvent(HealthEventKind.SETTING_OFF_OBSERVED, 1_799_999_998_000)),
    )
}
