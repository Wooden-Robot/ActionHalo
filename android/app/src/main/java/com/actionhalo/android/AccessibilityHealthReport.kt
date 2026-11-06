package com.actionhalo.android

import java.time.Instant
import java.time.format.DateTimeFormatter

/** This model deliberately cannot carry selected text, chat text, service lists, or exceptions. */
internal data class AccessibilityHealthSnapshot(
    val capturedAt: Long,
    val deviceModel: String,
    val sdk: Int,
    val appVersion: String,
    val configured: Boolean?,
    val managerListed: Boolean?,
    val connected: Boolean,
    val battery: BatteryPolicy,
    val processExit: ProcessExit?,
    val events: List<HealthEvent>,
)

internal enum class BatteryPolicy { UNRESTRICTED, OPTIMIZED, UNKNOWN }
internal enum class HealthEventKind { CONNECTED, UNBOUND, DESTROYED, SCREEN_OFF, SETTING_ON_OBSERVED, SETTING_OFF_OBSERVED }
internal data class HealthEvent(val kind: HealthEventKind, val timestamp: Long)
internal data class ProcessExit(val reason: ExitReason, val timestamp: Long, val status: Int)
internal enum class ExitReason {
    UNKNOWN, SELF_EXIT, SIGNAL, LOW_MEMORY, CRASH, CRASH_NATIVE, ANR, INITIALIZATION_FAILURE,
    PERMISSION_CHANGE, EXCESSIVE_RESOURCE_USAGE, USER_REQUESTED, USER_STOPPED, DEPENDENCY_DIED,
    OTHER, FREEZER, PACKAGE_STATE_CHANGE, PACKAGE_UPDATED,
}

internal object AccessibilityHealthReport {
    const val MAX_EVENTS = 12

    fun containsOwnComponent(raw: String?, packageName: String, className: String): Boolean =
        raw?.split(':')?.any { component ->
            val parts = component.split('/')
            if (parts.size != 2 || parts[0] != packageName) return@any false
            val expanded = if (parts[1].startsWith('.')) packageName + parts[1] else parts[1]
            expanded == className
        } == true

    fun decodeEvents(raw: String?): List<HealthEvent> = raw?.split('|')?.mapNotNull { item ->
        val parts = item.split(':')
        if (parts.size != 2) return@mapNotNull null
        val timestamp = parts[0].toLongOrNull()?.takeIf { it > 0 } ?: return@mapNotNull null
        val kind = HealthEventKind.entries.firstOrNull { it.name == parts[1] } ?: return@mapNotNull null
        HealthEvent(kind, timestamp)
    }?.takeLast(MAX_EVENTS) ?: emptyList()

    fun encodeEvents(events: List<HealthEvent>): String = events.filter { it.timestamp > 0 }
        .takeLast(MAX_EVENTS).joinToString("|") { "${it.timestamp}:${it.kind.name}" }

    fun appendEvent(events: List<HealthEvent>, event: HealthEvent): List<HealthEvent> =
        if (event.timestamp <= 0) events.takeLast(MAX_EVENTS) else (events + event).takeLast(MAX_EVENTS)

    fun settingObservation(previous: Boolean?, current: Boolean?, timestamp: Long): HealthEvent? {
        if (current == null || current == previous || timestamp <= 0) return null
        return HealthEvent(if (current) HealthEventKind.SETTING_ON_OBSERVED else HealthEventKind.SETTING_OFF_OBSERVED, timestamp)
    }

    fun render(snapshot: AccessibilityHealthSnapshot): String = buildString {
        appendLine("ActionHalo 服务诊断（本机生成）")
        appendLine("检查时间：${time(snapshot.capturedAt)}")
        appendLine("机型：${oneLine(snapshot.deviceModel)}；SDK=${snapshot.sdk}；App=${oneLine(snapshot.appVersion)}")
        appendLine("系统启用名单：${state(snapshot.configured, "开启", "关闭")}")
        appendLine("系统服务列表：${state(snapshot.managerListed, "已列出", "未列出")}")
        appendLine("当前服务连接：${if (snapshot.connected) "已连接" else "未连接"}")
        appendLine("省电优化：${when (snapshot.battery) {
            BatteryPolicy.UNRESTRICTED -> "已豁免"
            BatteryPolicy.OPTIMIZED -> "仍受优化"
            BatteryPolicy.UNKNOWN -> "未知"
        }}")
        appendLine("最近进程退出：${snapshot.processExit?.let {
            "${it.reason.name}；${time(it.timestamp)}；status=${it.status}"
        } ?: "无可用记录"}")
        appendLine("服务记录（最多 $MAX_EVENTS 条；开关记录为观察时间，不代表实际关闭时刻）：")
        val events = snapshot.events.filter { it.timestamp > 0 }.takeLast(MAX_EVENTS)
        if (events.isEmpty()) appendLine("无记录")
        events.forEach { appendLine("${time(it.timestamp)} ${it.kind.name}") }
        append("不含选文、消息、剪贴板、其他应用名单或设备标识；未上传。")
    }

    private fun state(value: Boolean?, yes: String, no: String) = when (value) {
        true -> yes
        false -> no
        null -> "未知"
    }

    private fun oneLine(value: String) = value.filterNot { it.isISOControl() }.take(100)
    private fun time(timestamp: Long): String = if (timestamp > 0) {
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(timestamp))
    } else "未知"
}
