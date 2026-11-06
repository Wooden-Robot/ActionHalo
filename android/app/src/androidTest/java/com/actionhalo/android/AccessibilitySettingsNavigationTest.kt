package com.actionhalo.android

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.Instrumentation
import android.app.UiAutomation
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityManager
import android.widget.Switch
import android.widget.Button
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in: exercises consent with a real bound service, never on a physical device. */
@RunWith(AndroidJUnit4::class)
class AccessibilitySettingsNavigationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val service: ComponentName get() = ComponentName(context, SelectionAccessibilityService::class.java)
    private lateinit var automation: UiAutomation
    private var oldServices: String? = null
    private var oldAccessibility: String? = null
    private val savedPreferences = linkedMapOf<String, Map<String, Any?>>()
    private var restoreRequired = false

    @Before fun configureEmulatorOnly() {
        // Keep the assumption first: the ordinary suite must not touch device settings.
        assumeTrue(InstrumentationRegistry.getArguments().getString("accessibility_settings_diagnostics") == "true")
        assertDisposableEmulator()
        automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        oldServices = shell("settings get secure enabled_accessibility_services").trim()
        oldAccessibility = shell("settings get secure accessibility_enabled").trim()
        listOf("actionhalo_settings", "halo_actions", "accessibility_health").forEach { name ->
            savedPreferences[name] = context.getSharedPreferences(name, Context.MODE_PRIVATE).all.mapValues { (_, value) ->
                if (value is Set<*>) value.toSet() else value
            }
        }
        // Also restore when any later setup assertion fails.
        restoreRequired = true
        // Starting instrumentation can kill the app process while its service remains enabled.
        // Android then keeps it in the crashed set; writing the same enabled list cannot rebind it.
        // Normalize only our component after taking the restoration snapshot.
        setOwnServiceEnabled(false)
        await("Android must process removal of our old service before a test reenables it") {
            context.getSystemService(AccessibilityManager::class.java)
                .getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
                .none { ComponentName.unflattenFromString(it.id) == service } && !serviceConnected()
        }
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", false)
            .putBoolean("accessibility_consent", false)
            .putBoolean(TelegramCopyPolicy.SETTING, false)
            .commit())
    }

    @After fun restoreEmulator() {
        if (!restoreRequired) return
        try {
            restoreSecure("enabled_accessibility_services", oldServices)
        } finally {
            try {
                restoreSecure("accessibility_enabled", oldAccessibility)
                val wasConnected = oldAccessibility == "1" && serviceNames(oldServices).any {
                    ComponentName.unflattenFromString(it) == service
                }
                awaitConnection(wasConnected)
            } finally {
                // Restore after lifecycle callbacks so diagnostic records cannot overwrite this snapshot.
                savedPreferences.forEach { (name, values) ->
                    val editor = context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear()
                    values.forEach { (key, value) ->
                        when (value) {
                            is Boolean -> editor.putBoolean(key, value)
                            is String -> editor.putString(key, value)
                            is Int -> editor.putInt(key, value)
                            is Long -> editor.putLong(key, value)
                            is Float -> editor.putFloat(key, value)
                            is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
                        }
                    }
                    assertTrue("Restore $name", editor.commit())
                }
            }
        }
    }

    @Test fun firstAutomaticConsentDoesNotOpenSettingsWhenServiceIsAlreadyConnected() {
        consentAndCaptureSettings(true, R.string.auto_title, "auto_popup_enabled") { intents ->
            assertTrue("Already authorized automatic mode must remain on the home screen: ${intents.map { it.action }}", intents.isEmpty())
            assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
                .getBoolean("accessibility_consent", false))
            assertTrue(serviceConnected())
        }
    }

    @Test fun telegramConsentDoesNotOpenSettingsWhenServiceIsAlreadyConnected() {
        consentAndCaptureSettings(true, R.string.telegram_copy_popup_title, TelegramCopyPolicy.SETTING) { intents ->
            assertTrue("Already authorized Telegram copy must remain on the home screen: ${intents.map { it.action }}", intents.isEmpty())
            assertTrue(serviceConnected())
        }
    }

    @Test fun firstAutomaticConsentRequestsPublicSettingsWhenPermissionIsMissing() {
        consentAndCaptureSettings(false, R.string.auto_title, "auto_popup_enabled", ::assertPublicOverviewOnly)
    }

    @Test fun telegramConsentRequestsPublicSettingsWhenPermissionIsMissing() {
        consentAndCaptureSettings(false, R.string.telegram_copy_popup_title, TelegramCopyPolicy.SETTING, ::assertPublicOverviewOnly)
    }

    @Test fun alreadyEnabledSettingsEntryRequiresConfirmationBeforeOpeningOverview() {
        alreadyEnabledSettingsEntry(confirm = true)
    }

    @Test fun cancellingAlreadyEnabledSettingsEntryDoesNotOpenSettings() {
        alreadyEnabledSettingsEntry(confirm = false)
    }

    private fun alreadyEnabledSettingsEntry(confirm: Boolean) {
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true)
            .putBoolean("accessibility_consent", true)
            .commit())
        val intents = CopyOnWriteArrayList<Intent>()
        val monitor = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                if (intent.action?.startsWith("android.settings.") != true) return null
                intents.add(Intent(intent))
                return Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.TRIGGERS)).use { scenario ->
                setOwnServiceEnabled(true)
                scenario.onActivity { activity ->
                    descendants(activity.window.decorView).filterIsInstance<Button>().single {
                        it.text.toString() == activity.getString(R.string.access_settings)
                    }.performClick()
                }
                await("An already authorized service must prompt before entering system settings") {
                    automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(
                        context.getString(R.string.access_already_enabled_title)
                    )?.any { it.isVisibleToUser } == true
                }
                instrumentation.waitForIdleSync()
                assertTrue("Settings must not open before a separate confirmation", intents.isEmpty())
                assertTrue(serviceConnected())
                scenario.onActivity { activity ->
                    assertTrue("The choice dialog must not finish the home activity", !activity.isFinishing && !activity.isDestroyed)
                }
                if (confirm) {
                    clickPositiveButton(R.string.access_overview)
                    await("Explicit confirmation must request the overview") { intents.size == 1 }
                    assertPublicOverviewOnly(intents.toList())
                } else {
                    clickDialogButton("android:id/button2", null)
                    await("Cancelling must dismiss the choice dialog") {
                        automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(
                            context.getString(R.string.access_already_enabled_title)
                        )?.none { it.isVisibleToUser } == true
                    }
                    instrumentation.waitForIdleSync()
                    assertTrue("Cancelling must remain in the application", intents.isEmpty())
                    assertTrue(serviceConnected())
                }
            }
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }

    private fun consentAndCaptureSettings(serviceEnabled: Boolean, switchLabel: Int, preference: String, verify: (List<Intent>) -> Unit) {
        val intents = CopyOnWriteArrayList<Intent>()
        val monitor = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                if (intent.action?.startsWith("android.settings.") == true ||
                    intent.component?.packageName == "com.android.settings") {
                    intents.add(Intent(intent))
                    // Capture the application's navigation decision without leaving the consent test.
                    return Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
                }
                return null
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.TRIGGERS)).use { scenario ->
                // An instrumentation process alone does not clear the installed app's stopped
                // state. Start its real activity before asking Android to bind the service.
                setOwnServiceEnabled(serviceEnabled)
                scenario.onActivity { activity ->
                    val toggle = descendants(activity.window.decorView).filterIsInstance<Switch>().single {
                        it.text.toString() == activity.getString(switchLabel)
                    }
                    // CompoundButton reports only its click-listener result; the checked listener
                    // still opens the dialog even when performClick() itself returns false.
                    toggle.performClick()
                }
                clickConsentButton()
                await("Consent must enable $preference") {
                    context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).getBoolean(preference, false)
                }
                instrumentation.waitForIdleSync()
                verify(intents.toList())
                scenario.onActivity { activity ->
                    assertTrue("Consent must leave the application activity alive", !activity.isFinishing && !activity.isDestroyed)
                }
            }
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }

    private fun assertPublicOverviewOnly(intents: List<Intent>) {
        assertEquals("Request public accessibility settings exactly once", 1, intents.size)
        assertEquals(Settings.ACTION_ACCESSIBILITY_SETTINGS, intents.single().action)
    }

    private fun clickConsentButton() = clickPositiveButton(R.string.consent_accept)

    private fun clickPositiveButton(label: Int) = clickDialogButton("android:id/button1", label)

    private fun clickDialogButton(viewId: String, label: Int?) {
        await("The real dialog must expose the expected button") {
            val root = automation.rootInActiveWindow ?: return@await false
            val button = root.findAccessibilityNodeInfosByViewId(viewId)
                .firstOrNull { it.isVisibleToUser && it.isEnabled &&
                    (label == null || it.text?.toString()?.equals(context.getString(label), ignoreCase = true) == true) }
            button?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
        }
    }

    private fun setOwnServiceEnabled(enabled: Boolean) {
        // Preserve other emulator services, and only add/remove our component.
        val names = serviceNames(oldServices).filterNot { ComponentName.unflattenFromString(it) == service }.toMutableList()
        if (enabled) names.add(service.flattenToString())
        restoreSecure("enabled_accessibility_services", names.joinToString(":"))
        if (enabled || names.isNotEmpty()) shell("settings put secure accessibility_enabled 1")
        else shell("settings put secure accessibility_enabled 0")
        awaitConnection(enabled)
    }

    private fun awaitConnection(expected: Boolean) {
        try {
            await("Service connected state must become $expected") { serviceConnected() == expected }
        } catch (failure: AssertionError) {
            throw AssertionError("${failure.message}; ${ownConnectionDiagnostics()}", failure)
        }
    }

    private fun ownConnectionDiagnostics(): String {
        val configured = serviceNames(shell("settings get secure enabled_accessibility_services").trim())
            .any { ComponentName.unflattenFromString(it) == service }
        val managerListed = context.getSystemService(AccessibilityManager::class.java)
            .getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            .any { ComponentName.unflattenFromString(it.id) == service }
        val dump = shell("dumpsys accessibility")
        val framework = listOf("Enabled", "Bound", "Binding", "Crashed").joinToString(",") { kind ->
            val state = frameworkListsOwnService(dump, kind)?.toString() ?: "unknown"
            "${kind.lowercase()}=$state"
        }
        return "ownSecureGrant=$configured,ownManagerListed=$managerListed,ownFramework=[$framework],ownConnected=${serviceConnected()}"
    }

    private fun frameworkListsOwnService(dump: String, kind: String): Boolean? {
        val body = Regex("(?m)^[ \\t]*$kind services:[ \\t]*([^\\n]*)").find(dump)?.groupValues?.get(1)
            ?: return null
        val own = Regex("[\\w.]+/[\\w.$]+").findAll(body).any {
            ComponentName.unflattenFromString(it.value) == service
        }
        return if (own) true else if (body.trim().endsWith("}")) false else null
    }

    private fun serviceConnected(): Boolean {
        val connected = AtomicBoolean()
        instrumentation.runOnMainSync { connected.set(SelectionAccessibilityService.isConnected()) }
        return connected.get()
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 6_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        throw AssertionError(message)
    }

    private fun descendants(view: View): Sequence<View> = sequence {
        yield(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) yieldAll(descendants(view.getChildAt(index)))
    }

    private fun serviceNames(value: String?): List<String> = value?.takeUnless { it == "null" || it.isBlank() }
        ?.split(':')?.filter { it.isNotBlank() }.orEmpty()

    private fun restoreSecure(key: String, value: String?) {
        if (value == null || value == "null" || value.isEmpty()) shell("settings delete secure $key")
        else {
            // UiAutomation executes this command directly, rather than through a shell.
            // Quotes would become part of the stored component and prevent service binding.
            require(value.matches(Regex("[A-Za-z0-9_./:$]+"))) { "Unexpected secure-setting token" }
            shell("settings put secure $key $value")
        }
    }

    private fun shell(command: String): String = automation.executeShellCommand(command).use {
        java.io.FileInputStream(it.fileDescriptor).bufferedReader().use { reader -> reader.readText() }
    }
}
