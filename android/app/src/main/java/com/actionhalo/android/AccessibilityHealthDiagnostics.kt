package com.actionhalo.android

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.accessibility.AccessibilityManager

/** Read-only service health checks. No clipboard, accessibility node, or chat content is read. */
internal object AccessibilityHealthDiagnostics {
    private const val PREFERENCES = "accessibility_health"
    private const val EVENTS = "events"
    private const val OBSERVED_SETTING = "observed_setting"
    private val lock = Any()

    fun snapshot(context: Context, connected: Boolean): AccessibilityHealthSnapshot {
        val own = ComponentName(context, SelectionAccessibilityService::class.java)
        val configured = safe {
            val raw = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            AccessibilityHealthReport.containsOwnComponent(raw, own.packageName, own.className)
        }
        val managerListed = safe {
            val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
            manager.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK).any {
                ComponentName.unflattenFromString(it.id) == own
            }
        }
        val capturedAt = System.currentTimeMillis()
        observeSetting(context, configured, capturedAt)
        val battery = safe {
            val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (power.isIgnoringBatteryOptimizations(context.packageName)) BatteryPolicy.UNRESTRICTED else BatteryPolicy.OPTIMIZED
        } ?: BatteryPolicy.UNKNOWN
        @Suppress("DEPRECATION")
        val version = safe { context.packageManager.getPackageInfo(context.packageName, 0).versionName } ?: "unknown"
        return AccessibilityHealthSnapshot(
            capturedAt, "${Build.MANUFACTURER} ${Build.MODEL}", Build.VERSION.SDK_INT, version,
            configured, managerListed, connected, battery, latestExit(context), readEvents(context),
        )
    }

    fun recordConnected(context: Context) = record(context, HealthEventKind.CONNECTED)
    fun recordUnbound(context: Context) = record(context, HealthEventKind.UNBOUND)
    fun recordDestroyed(context: Context) = record(context, HealthEventKind.DESTROYED)
    fun recordScreenOff(context: Context) = record(context, HealthEventKind.SCREEN_OFF)

    fun renderReport(snapshot: AccessibilityHealthSnapshot): String = AccessibilityHealthReport.render(snapshot)

    fun renderStatus(context: Context, snapshot: AccessibilityHealthSnapshot): String {
        fun state(value: Boolean?, yes: Int, no: Int) = context.getString(when (value) {
            true -> yes
            false -> no
            null -> R.string.health_unknown
        })
        return context.getString(R.string.health_status,
            state(snapshot.configured, R.string.health_on, R.string.health_off),
            state(snapshot.managerListed, R.string.health_listed, R.string.health_not_listed),
            context.getString(if (snapshot.connected) R.string.health_connected else R.string.health_disconnected),
            context.getString(when (snapshot.battery) {
                BatteryPolicy.UNRESTRICTED -> R.string.health_battery_unrestricted
                BatteryPolicy.OPTIMIZED -> R.string.health_battery_optimized
                BatteryPolicy.UNKNOWN -> R.string.health_unknown
            }),
        )
    }

    private fun record(context: Context, kind: HealthEventKind) = synchronized(lock) {
        safe {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val events = AccessibilityHealthReport.appendEvent(
                AccessibilityHealthReport.decodeEvents(preferences.getString(EVENTS, null)),
                HealthEvent(kind, System.currentTimeMillis()),
            )
            preferences.edit().putString(EVENTS, AccessibilityHealthReport.encodeEvents(events)).apply()
        }
        Unit
    }

    private fun observeSetting(context: Context, configured: Boolean?, timestamp: Long) = synchronized(lock) {
        if (configured == null) return@synchronized
        safe {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val previous = if (preferences.contains(OBSERVED_SETTING)) preferences.getBoolean(OBSERVED_SETTING, false) else null
            AccessibilityHealthReport.settingObservation(previous, configured, timestamp)?.let { event ->
                val events = AccessibilityHealthReport.appendEvent(
                    AccessibilityHealthReport.decodeEvents(preferences.getString(EVENTS, null)), event,
                )
                preferences.edit().putBoolean(OBSERVED_SETTING, configured)
                    .putString(EVENTS, AccessibilityHealthReport.encodeEvents(events)).apply()
            }
        }
    }

    private fun readEvents(context: Context): List<HealthEvent> = synchronized(lock) {
        safe { AccessibilityHealthReport.decodeEvents(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(EVENTS, null)) } ?: emptyList()
    }

    private fun latestExit(context: Context): ProcessExit? {
        if (Build.VERSION.SDK_INT < 30) return null
        return safe {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            // Scope to our package and request only the latest entry. Do not read descriptions or traces.
            manager.getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull()?.let {
                ProcessExit(exitReason(it.reason), it.timestamp, it.status)
            }
        }
    }

    private fun exitReason(reason: Int): ExitReason = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> ExitReason.SELF_EXIT
        ApplicationExitInfo.REASON_SIGNALED -> ExitReason.SIGNAL
        ApplicationExitInfo.REASON_LOW_MEMORY -> ExitReason.LOW_MEMORY
        ApplicationExitInfo.REASON_CRASH -> ExitReason.CRASH
        ApplicationExitInfo.REASON_CRASH_NATIVE -> ExitReason.CRASH_NATIVE
        ApplicationExitInfo.REASON_ANR -> ExitReason.ANR
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> ExitReason.INITIALIZATION_FAILURE
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> ExitReason.PERMISSION_CHANGE
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> ExitReason.EXCESSIVE_RESOURCE_USAGE
        ApplicationExitInfo.REASON_USER_REQUESTED -> ExitReason.USER_REQUESTED
        ApplicationExitInfo.REASON_USER_STOPPED -> ExitReason.USER_STOPPED
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> ExitReason.DEPENDENCY_DIED
        ApplicationExitInfo.REASON_OTHER -> ExitReason.OTHER
        ApplicationExitInfo.REASON_FREEZER -> ExitReason.FREEZER
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> ExitReason.PACKAGE_STATE_CHANGE
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> ExitReason.PACKAGE_UPDATED
        else -> ExitReason.UNKNOWN
    }

    // A vendor API or unavailable system service must not crash the service we are diagnosing.
    // Neither the exception message nor its stack trace is retained in the report.
    private inline fun <T> safe(block: () -> T): T? = try { block() } catch (_: Exception) { null }
}
