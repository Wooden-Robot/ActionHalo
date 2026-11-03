package com.actionhalo.android

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.ClipboardManager
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inspector.WindowInspector
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.actionhalo.android.fixture.ClipboardOverlayHostActivity
import com.actionhalo.android.fixture.SelectionFixtureActivity
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in framework experiment. Reads fixed fixture data, never a user's clipboard. */
@RunWith(AndroidJUnit4::class)
class FocusedClipboardOverlayTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val testPackage: String get() = instrumentation.context.packageName
    private val component: ComponentName get() = ComponentName(context, SelectionAccessibilityService::class.java)
    private lateinit var automation: UiAutomation
    private lateinit var service: SelectionAccessibilityService
    private var oldServices: String? = null
    private var oldAccessibility: String? = null
    private val savedPreferences = linkedMapOf<String, Map<String, Any?>>()
    private val panels = mutableListOf<View>()
    private val productionOverlays = mutableListOf<ClipboardHaloOverlay>()
    private var seedStartedUptime = 0L
    private var seedStartedWall = 0L
    private var seedFinishedWall = 0L
    private var seedHostWindowId = -1
    private var restoreRequired = false

    @Before fun configureEmulatorOnly() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("focused_clipboard_overlay") == "true")
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        assertDisposableEmulator()
        assertNotEquals("Clipboard producer must use a different UID", context.applicationInfo.uid,
            instrumentation.context.applicationInfo.uid)
        automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        }
        oldServices = shell("settings get secure enabled_accessibility_services").trim()
        oldAccessibility = shell("settings get secure accessibility_enabled").trim()
        listOf("actionhalo_settings", "halo_actions", "accessibility_health", "app_rules").forEach { name ->
            savedPreferences[name] = context.getSharedPreferences(name, Context.MODE_PRIVATE).all.mapValues { (_, value) ->
                if (value is Set<*>) value.toSet() else value
            }
        }
        restoreRequired = true
        val otherServices = serviceNames(oldServices).filterNot { ComponentName.unflattenFromString(it) == component }
        writeSecure("enabled_accessibility_services", otherServices.joinToString(":"))
        await("Old service registration must be removed before rebinding") {
            context.getSystemService(AccessibilityManager::class.java)
                .getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
                .none { ComponentName.unflattenFromString(it.id) == component } && connectedService() == null
        }
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", false).putBoolean(TelegramCopyPolicy.SETTING, false)
            .putBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false).commit())
        assertTrue(context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE).edit()
            .putBoolean("enabled_copy", true).commit())
        writeSecure("enabled_accessibility_services", (otherServices + component.flattenToString()).joinToString(":"))
        writeSecure("accessibility_enabled", "1")
        await("The real service must bind") { connectedService() != null }
        service = checkNotNull(connectedService())
        seedStartedUptime = SystemClock.uptimeMillis()
        seedStartedWall = System.currentTimeMillis()
        shell("am start -W -S -n $testPackage/${ClipboardOverlayHostActivity::class.java.name}")
        await("Different-UID host must gain focus and seed the fixed clip") {
            seedHostWindowId = focusedSeedHostWindowId() ?: -1
            seedHostWindowId >= 0
        }
        seedFinishedWall = System.currentTimeMillis()
    }

    @After fun restoreEmulator() {
        if (!restoreRequired) return
        try {
            instrumentation.runOnMainSync {
                productionOverlays.forEach { it.dismiss() }
                productionOverlays.clear()
                if (::service.isInitialized) {
                    val manager = service.getSystemService(WindowManager::class.java)
                    panels.toList().asReversed().forEach { panel ->
                        if (panel.isAttachedToWindow) manager.removeViewImmediate(panel)
                    }
                }
                panels.clear()
            }
            shell("am force-stop $testPackage")
        } finally {
            try {
                writeSecure("enabled_accessibility_services", oldServices)
                writeSecure("accessibility_enabled", oldAccessibility)
                val wasConnected = oldAccessibility == "1" && serviceNames(oldServices).any {
                    ComponentName.unflattenFromString(it) == component
                }
                await("Service connection must return to its prior state") { (connectedService() != null) == wasConnected }
            } finally {
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
                    assertTrue(editor.commit())
                }
            }
        }
    }

    @Test fun nonFocusableOverlayCannotReadTheForeignClipboard() {
        val panel = showPanel(focusable = false, readOnFocus = false)
        SystemClock.sleep(400)
        assertTrue("Foreign host must remain focused", hostFocusedAndSeeded())
        instrumentation.runOnMainSync {
            assertFalse(panel.hasWindowFocus())
            // Deliberate denied-read control, confined to this opt-in framework test.
            panel.readFixedFixture()
        }
        assertEquals(0, panel.focusGains)
        assertEquals(1, panel.reads)
        assertNull("NOT_FOCUSABLE must not give the service clipboard access", panel.text)
        Log.i(TAG, "not_focusable focus=false reads=1 clipboard_unavailable=true")
    }

    @Test fun focusedOverlayReadsExactUnicodeOnceAfterWindowFocus() {
        val panel = showPanel(focusable = true, readOnFocus = true)
        await("Focusable accessibility overlay must gain real window focus and read") { panel.reads == 1 }
        assertTrue(panel.readHadFocus)
        assertEquals(ClipboardOverlayHostActivity.SAMPLE, panel.text)
        assertFalse("The foreign host must lose focus", hostFocusedAndSeeded())

        // Another real window makes the first one lose focus; do not invoke callbacks manually.
        val blocker = showPanel(focusable = true, readOnFocus = false)
        await("The second real window must take focus") { blocker.focusGains > 0 }
        instrumentation.runOnMainSync {
            assertFalse(panel.hasWindowFocus())
            service.getSystemService(WindowManager::class.java).removeViewImmediate(blocker)
            panels.remove(blocker)
        }
        await("The original overlay must regain focus") { panel.focusGains >= 2 }
        assertEquals("Refocusing must not read the clip again", 1, panel.reads)
        assertEquals(ClipboardOverlayHostActivity.SAMPLE, panel.text)
        Log.i(TAG, "focusable focus_gains=${panel.focusGains} reads=1 exact_unicode=true service_context=true")
    }

    @Test fun productionOverlayExecutesExactUnicodeAndCloses() {
        val fixture = productionFixture()
        instrumentation.runOnMainSync { fixture.show() }
        await("The production window must execute after real focus") { fixture.executions.size == 1 }
        assertEquals(fixture.copy, fixture.executions.single().first)
        assertEquals(ClipboardOverlayHostActivity.SAMPLE, fixture.executions.single().second)
        await("Completed production window must close") { !isShowing(fixture.overlay) }
        SystemClock.sleep(250)
        assertEquals(1, fixture.executions.size)
    }

    @Test fun explicitDiagnosticSampleWorksWithMenuCompatibilityWithoutReadingTheSourceOrClipboard() {
        setMenuModes(standard = true, telegram = false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", false).putBoolean("accessibility_consent", false).commit())
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync { assertTrue(SelectionAccessibilityService.checkOverlay()) }
        await("The explicit fixed sample must be shown") { ordinaryHaloWindowId() != null }
        val menu = selectionMenu(standard = false)
        instrumentation.runOnMainSync {
            assertEquals(HaloUi.localizedContext(service).getString(R.string.sample_text), menu.selectedText)
            menu.onDismiss!!.invoke()
        }
        assertSeedClipboardUnchanged()
    }

    @Test fun initialNativeSelectionStaysQuietAndAnAdjustedHaloCanPauseOnlyItsSourceApp() {
        setMenuModes(standard = false, telegram = false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true).commit())
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host --ez select_all true")
        assertNoMenuHaloForSettlement()
        assertNull("The initial native selection must not add an Open halo button", selectionHelperWindowId())
        adjustFixtureSelection(0, 9)
        await("Adjusting the selection must directly open the wheel") { ordinaryHaloWindowId() != null }
        assertNull(selectionHelperWindowId())
        val halo = checkNotNull(ordinaryHaloWindowId())
        assertTrue(clickHaloAction(halo, context.getString(R.string.source_app_options)))
        instrumentation.waitForIdleSync()
        saveSelectionScreenshot("daily-source-options")
        assertTrue(clickHaloAction(halo, context.getString(R.string.source_pause_app)))
        await("Only the source app must become temporarily paused and its overlay must close") {
            AppRulesStore(context).appPauseRemainingMillis(testPackage) > 0 && ordinaryHaloWindowId() == null && selectionHelperWindowId() == null
        }
        assertFalse(AppRulesStore(context).isPaused())
        adjustFixtureSelection(0, 18)
        assertNoMenuHaloForSettlement()
        assertNull(selectionHelperWindowId())
        AppRulesStore(context).resumeApp(testPackage)
        adjustFixtureSelection(0, 27)
        assertNoMenuHaloForSettlement()
        assertNull("Resuming must keep the next initial selection quiet", selectionHelperWindowId())
        adjustFixtureSelection(0, SelectionFixtureActivity.SAMPLE_TEXT.length)
        await("After resuming, adjusting the new selection must directly open the wheel") { ordinaryHaloWindowId() != null }
        val resumed = checkNotNull(ordinaryHaloWindowId())
        assertTrue(clickHaloAction(resumed, context.getString(R.string.source_app_options)))
        assertTrue(clickHaloAction(resumed, context.getString(R.string.source_pause_visit)))
        await("A visit pause must survive while the source remains foreground") { AppRulesStore(context).isVisitPaused(testPackage) }
        shell("am start -W -n ${context.packageName}/.MainActivity")
        await("Leaving the verified source must end its visit pause") { !AppRulesStore(context).isVisitPaused(testPackage) }
    }

    @Test fun copyingCanKeepTheFocusedSnapshotAndTheNextActionNeverReadsANewerClipboard() {
        context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, true).commit()
        val reads = AtomicInteger()
        val executions = CopyOnWriteArrayList<Pair<HaloAction, String>>()
        val reference = AtomicReference<ClipboardHaloOverlay>()
        instrumentation.runOnMainSync {
            val overlay = ClipboardHaloOverlay(service, { true }, executeAction = { _, action, text ->
                executions.add(action to text); true
            }, readClipboard = { source -> reads.incrementAndGet(); source.getSystemService(ClipboardManager::class.java).primaryClip })
            productionOverlays.add(overlay)
            reference.set(overlay)
            overlay.show(seedStartedUptime, seedStartedWall, seedFinishedWall,
                ActionStore(service).actions().single { it.id == "copy" }, seedHostWindowId)
        }
        val overlay = reference.get()
        await("Copy must complete while retaining its wheel") { executions.size == 1 && isShowing(overlay) }
        assertEquals(1, reads.get())
        val blocker = showPanel(focusable = true, readOnFocus = false)
        await("The temporary panel must really own focus") { blocker.focusGains > 0 }
        instrumentation.runOnMainSync {
            service.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Replacement fixture", "Do not use this newer clip"))
        }
        removePanel(blocker)
        instrumentation.runOnMainSync {
            val root = ClipboardHaloOverlay::class.java.getDeclaredField("current").apply { isAccessible = true }.get(overlay) as android.view.ViewGroup
            val menu = (0 until root.childCount).map(root::getChildAt).filterIsInstance<RadialMenuView>().single()
            assertEquals(ClipboardOverlayHostActivity.SAMPLE, menu.selectedText)
            menu.onActionSelected!!.invoke(ActionStore(service).actions().single { it.id == "google" })
        }
        await("A different chosen action must execute and close") { executions.size == 2 && !isShowing(overlay) }
        assertEquals(listOf("copy", "google"), executions.map { it.first.id })
        assertEquals(List(2) { ClipboardOverlayHostActivity.SAMPLE }, executions.map { it.second })
        assertEquals("The second operation must reuse the first snapshot", 1, reads.get())
    }

    @Test fun standardSelectionToolbarCopiesOnlyTheSelectedFragmentThroughTheRealHalo() {
        setMenuModes(standard = true, telegram = false)
        val selected = longPressStandardSelection()
        await("The real standard selection toolbar must directly show its halo") { ordinaryHaloWindowId() != null }
        val halo = checkNotNull(ordinaryHaloWindowId())
        val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
        assertTrue("Copy must be selected through the real halo button", clickHaloAction(halo, title))
        await("The production Copy action must complete and close its windows") {
            TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED &&
                ordinaryHaloWindowId() == null && !actionWindowExists()
        }
        val reader = showPanel(focusable = true, readOnFocus = true)
        await("A real focused window must read the copied fragment") { reader.reads == 1 }
        assertTrue(reader.readHadFocus)
        assertEquals(selected, reader.text)
        assertEquals("ActionHalo", reader.label)
    }

    @Test fun initialLongPressStaysQuietAndHandleAdjustmentRemainsUsable() {
        for ((native, muted, buttonMode) in listOf(Triple(true, false, false), Triple(false, false, false),
                Triple(false, true, false), Triple(false, true, true))) {
            AppRulesStore(context).setProfile(testPackage, AppRulesStore.Profile(
                if (buttonMode) AppRulesStore.TriggerMode.BUTTON else AppRulesStore.TriggerMode.DEFAULT))
            setMenuModes(standard = !native, telegram = false)
            assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
                .putBoolean("auto_popup_enabled", native).putBoolean("accessibility_consent", native).commit())
            val initial = longPressStandardSelection(handleGeometry = true, muteSelectionEvents = muted, activate = false)
            if (muted && !buttonMode) await("Menu-only mode must show its bounded wheel before adjusting") { ordinaryHaloWindowId() != null }
            else assertNoMenuHaloForSettlement()
            if (buttonMode) await("The explicitly chosen button mode must provide its helper") { selectionHelperWindowId() != null }
            else assertNull("Automatic mode must not add a helper button", selectionHelperWindowId())
            if (!muted && !buttonMode) {
                adjustFixtureSelection(0, 10)
                await("Refining the initial range must show a bounded wheel before further dragging") { ordinaryHaloWindowId() != null }
            }
            val originalMenu = if (!buttonMode) selectionMenu(standard = !native) else null
            val originalWindow = if (originalMenu != null) ordinaryHaloWindowId() else null
            val source = checkNotNull(findSelectionEditor())
            val geometry = try {
                checkNotNull(Regex("handle=([0-9.]+),([0-9.]+); drag=([0-9.]+)")
                    .find(source.contentDescription.toString())).groupValues.drop(1).map { it.toFloat() }
            } finally { recycle(source) }
            val (x, y, shift) = geometry
            Log.i(TAG, "selection_adjustment native=$native muted=$muted initialLength=${initial.length} handle=$x,$y shift=$shift windows=${ownOverlayWindows()}")
            saveSelectionScreenshot("initial-selection-$native-$muted-$buttonMode-before")
            assertTrue(shift > 0)
            val down = SystemClock.uptimeMillis()
            fun touch(action: Int, offset: Float) {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x + offset, y, 0)
                    .apply { this.source = InputDevice.SOURCE_TOUCHSCREEN }
                try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            }
            touch(MotionEvent.ACTION_DOWN, 0f)
            for (step in 1..16) {
                SystemClock.sleep(40)
                touch(MotionEvent.ACTION_MOVE, shift * step / 16)
            }
            SystemClock.sleep(80)
            touch(MotionEvent.ACTION_UP, shift)
            instrumentation.waitForIdleSync()
            val finalSource = checkNotNull(findSelectionEditor())
            val selected = try {
                assertTrue(finalSource.refresh())
                finalSource.text.toString().substring(finalSource.textSelectionStart, finalSource.textSelectionEnd)
            } finally { recycle(finalSource) }
            Log.i(TAG, "selection_adjustment native=$native muted=$muted finalLength=${selected.length} windows=${ownOverlayWindows()}")
            saveSelectionScreenshot("initial-selection-$native-$muted-after")
            assertTrue("Dragging the real handle must extend the initially quiet selection", selected.length > initial.length)
            val released = SystemClock.uptimeMillis()
            if (buttonMode) {
                assertNoMenuHaloForSettlement()
                openSelectionHelper()
            } else {
                await("The adjusted selection must be usable without an idle countdown") { ordinaryHaloWindowId() != null }
                assertTrue("Updating the wheel must not introduce a 1.5-second wait", SystemClock.uptimeMillis() - released < 1_000)
            }
            if (originalMenu != null) {
                assertEquals("Dragging a real selection handle must not replace its wheel window", originalWindow, ordinaryHaloWindowId())
                assertSame("Dragging a real selection handle must not reset its wheel", originalMenu, selectionMenu(standard = !native))
            }
            val halo = checkNotNull(ordinaryHaloWindowId())
            val operationMenu = selectionMenu(standard = !native)
            instrumentation.runOnMainSync {
                val execute = checkNotNull(operationMenu.onActionSelected)
                operationMenu.onActionSelected = { action ->
                    Log.i(TAG, "selection_adjustment native=$native physicalAction=${action.id}")
                    execute(action)
                }
            }
            val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
            val target = checkNotNull(haloButtonBounds(halo, title))
            saveSelectionScreenshot("direct-selection-$native-$muted")
            val actionDown = SystemClock.uptimeMillis()
            fun press(action: Int) {
                val event = MotionEvent.obtain(actionDown, SystemClock.uptimeMillis(), action,
                    target.exactCenterX(), target.exactCenterY(), 0).apply { this.source = InputDevice.SOURCE_TOUCHSCREEN }
                try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            }
            press(MotionEvent.ACTION_DOWN)
            instrumentation.waitForIdleSync()
            val activeMenu = selectionMenu(standard = !native)
            instrumentation.runOnMainSync {
                val params = (activeMenu.parent as View).layoutParams as WindowManager.LayoutParams
                assertEquals(WindowManager.LayoutParams.MATCH_PARENT, params.width)
                assertTrue("Operating the wheel must restore the GTA backdrop", params.flags and WindowManager.LayoutParams.FLAG_DIM_BEHIND != 0)
                assertTrue((activeMenu.parent as View).background != null)
            }
            press(MotionEvent.ACTION_UP)
            try {
                await("The same first tap must copy and close its windows") {
                    ordinaryHaloWindowId() == null && !actionWindowExists() &&
                        (native || TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED)
                }
            } catch (failure: AssertionError) {
                throw AssertionError("native=$native ${TelegramCopyDiagnostics.report(context)} overlays=${ownOverlayWindows()}", failure)
            }
            val reader = showPanel(focusable = true, readOnFocus = true)
            await("The focused verifier must read the adjusted fragment") { reader.reads == 1 }
            assertEquals(selected, reader.text)
            assertEquals("ActionHalo", reader.label)
            removePanel(reader)
        }
    }

    @Test fun multilineSelectionHandleCanBeRegrabbedWithoutOperatingTheWheel() =
        exerciseMultilineHandle(native = true, muted = false)

    @Test fun firstNativeHandleAdjustmentShowsTheWheelOnlyAfterRelease() {
        val overlay = SelectionAccessibilityService::class.java.getDeclaredField("overlay").apply { isAccessible = true }
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true).commit())
        longPressStandardSelection(handleGeometry = true, activate = false)
        assertNoMenuHaloForSettlement()
        val source = checkNotNull(findSelectionEditor())
        val geometry = try {
            checkNotNull(Regex("handle=([0-9.]+),([0-9.]+); drag=([0-9.]+)")
                .find(source.contentDescription.toString())).groupValues.drop(1).map { it.toFloat() }
        } finally { recycle(source) }
        val (x, y, shift) = geometry
        val down = SystemClock.uptimeMillis()
        fun touch(action: Int, offset: Float) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x + offset, y, 0)
                .apply { this.source = InputDevice.SOURCE_TOUCHSCREEN }
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            instrumentation.waitForIdleSync()
        }
        touch(MotionEvent.ACTION_DOWN, 0f)
        try {
            for (step in 1..16) touch(MotionEvent.ACTION_MOVE, shift * step / 16)
            SystemClock.sleep(600)
            instrumentation.runOnMainSync {
                assertFalse("The first refinement must stay hidden while its handle is still held",
                    (overlay.get(service) as? RadialMenuView)?.isShown == true)
            }
        } finally { touch(MotionEvent.ACTION_UP, shift) }
        await("The first refined selection must show its wheel after release") {
            val visible = AtomicBoolean()
            instrumentation.runOnMainSync { visible.set((overlay.get(service) as? RadialMenuView)?.isShown == true) }
            visible.get() && ordinaryHaloWindowId() != null
        }
        assertSeedClipboardUnchanged()
    }

    @Test fun standardMenuMultilineHandleCanBeRegrabbedWithoutOperatingTheWheel() =
        exerciseMultilineHandle(native = false, muted = false)

    @Test fun menuOnlyMultilineHandleCanBeRegrabbedWithoutOperatingTheWheel() =
        exerciseMultilineHandle(native = false, muted = true)

    private fun exerciseMultilineHandle(native: Boolean, muted: Boolean) {
        setMenuModes(standard = !native, telegram = false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", native).putBoolean("accessibility_consent", native).commit())
        longPressStandardSelection(handleGeometry = true, multiline = true, muteSelectionEvents = muted, activate = !muted)
        await("The refined multiline selection must expose its wheel") { ordinaryHaloWindowId() != null }
        val menu = selectionMenu(standard = !native)
        val originalFrame = AtomicReference<Rect>()
        instrumentation.runOnMainSync {
            val origin = IntArray(2).also(menu::getLocationOnScreen)
            originalFrame.set(Rect(origin[0], origin[1], origin[0] + menu.width, origin[1] + menu.height))
        }
        var point: Pair<Float, Float>? = null
        var selectedEnd = -1
        for (line in 1..8) {
            val end = SelectionFixtureActivity.SAMPLE_TEXT.length + 1 + "Alpha beta gamma delta\n".length * line + 5
            adjustFixtureSelection(0, end)
            await("The real handle geometry must follow the new multiline selection") {
                val source = findSelectionEditor() ?: return@await false
                try {
                    source.refresh()
                    val description = source.contentDescription.toString()
                    if (!description.endsWith("range_end=$end")) return@await false
                    val match = Regex("handle=([0-9.]+),([0-9.]+)").find(description) ?: return@await false
                    point = match.groupValues[1].toFloat() to match.groupValues[2].toFloat()
                    true
                } finally { recycle(source) }
            }
            val (x, y) = checkNotNull(point)
            if (originalFrame.get().contains(x.toInt(), y.toInt())) { selectedEnd = end; break }
        }
        assertTrue("The larger selection must reach the wheel's original touch area", selectedEnd >= 0)
        val (x, y) = checkNotNull(point)
        saveSelectionScreenshot("multiline-handle-$native-$muted-before")
        val down = SystemClock.uptimeMillis()
        fun touch(action: Int, offset: Float) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x + offset, y, 0)
                .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            instrumentation.waitForIdleSync()
        }
        touch(MotionEvent.ACTION_DOWN, 0f)
        val expanded = AtomicBoolean()
        instrumentation.runOnMainSync {
            expanded.set(((menu.parent as View).layoutParams as WindowManager.LayoutParams).width == WindowManager.LayoutParams.MATCH_PARENT)
        }
        if (expanded.get()) touch(MotionEvent.ACTION_CANCEL, 0f)
        assertFalse("Regrabbing a text selection handle must not activate the wheel or GTA backdrop", expanded.get())
        try {
            for (step in 1..8) {
                touch(MotionEvent.ACTION_MOVE, context.resources.displayMetrics.density * 48 * step / 8)
                if (step >= 2) {
                    val visible = AtomicBoolean()
                    instrumentation.runOnMainSync { visible.set(menu.isShown) }
                    assertFalse("Moving a selection handle must hide the wheel until release", visible.get())
                    instrumentation.runOnMainSync {
                        val params = (menu.parent as View).layoutParams as WindowManager.LayoutParams
                        assertTrue("A hidden wheel must pass touches to the source", params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE != 0)
                        assertEquals(0, params.flags and WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                    }
                }
            }
            SystemClock.sleep(500)
            instrumentation.runOnMainSync {
                assertFalse("Pausing a held handle must not bring the wheel back", menu.isShown)
            }
        } finally { touch(MotionEvent.ACTION_UP, context.resources.displayMetrics.density * 48) }
        val source = checkNotNull(findSelectionEditor())
        try {
            assertTrue(source.refresh())
            assertTrue("The source handle must still extend the selection", source.textSelectionEnd > selectedEnd)
        } finally { recycle(source) }
        await("Releasing a selection handle must restore the wheel") {
            val visible = AtomicBoolean()
            instrumentation.runOnMainSync { visible.set(menu.isShown) }
            visible.get() && ordinaryHaloWindowId() != null
        }
        assertSame("Adjusting source handles must retain the same wheel", menu, selectionMenu(standard = !native))
        instrumentation.runOnMainSync {
            assertEquals("Selection handle movement must not shrink the wheel", originalFrame.get().width(), menu.width)
        }
        assertFalse(actionWindowExists())
        saveSelectionScreenshot("multiline-handle-$native-$muted-after")
        assertSeedClipboardUnchanged()
    }

    @Test fun nativeRangeChangesPreserveTheWheelAndItsFirstTouchAnchor() =
        exerciseSelectionPosition(native = true)

    @Test fun toolbarRangeChangesPreserveTheWheelAndItsFirstTouchAnchor() =
        exerciseSelectionPosition(native = false)

    private fun exerciseSelectionPosition(native: Boolean) {
        setMenuModes(standard = !native, telegram = false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", native).putBoolean("accessibility_consent", native).commit())
        longPressStandardSelection()
        await("The refined selection must show its wheel") { ordinaryHaloWindowId() != null }
        val window = checkNotNull(ordinaryHaloWindowId())
        val menu = selectionMenu(standard = !native)
        fun frame(): Rect {
            val result = AtomicReference<Rect>()
            instrumentation.runOnMainSync {
                val origin = IntArray(2).also(menu::getLocationOnScreen)
                result.set(Rect(origin[0], origin[1], origin[0] + menu.width, origin[1] + menu.height))
            }
            return result.get()
        }
        val anchored = frame()
        for (end in listOf(9, 18, 27)) {
            adjustFixtureSelection(0, end)
            SystemClock.sleep(800)
            assertEquals("Changing only the selection range must retain the same window", window, ordinaryHaloWindowId())
            assertSame("Changing only the selection range must not recreate the wheel", menu, selectionMenu(standard = !native))
            assertEquals("Moving a selection handle must preserve the user's anchor", anchored, frame())
            if (native) assertEquals(SelectionFixtureActivity.SAMPLE_TEXT.substring(0, end), menu.selectedText)
        }
        val firstTouch = RadialMenuView::class.java.getDeclaredField("touchAnchorSet").apply { isAccessible = true }
        instrumentation.runOnMainSync {
            assertFalse("Editing a selection must not consume the wheel's first-touch gesture", firstTouch.getBoolean(menu))
        }
        val x = anchored.left + anchored.width() * .20f
        val y = anchored.top + anchored.height() * .20f
        val down = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0)
                .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            instrumentation.waitForIdleSync()
        }
        instrumentation.runOnMainSync { assertTrue(firstTouch.getBoolean(menu)) }
        val selected = SelectionFixtureActivity.SAMPLE_TEXT.substring(0, 27)
        val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
        assertTrue(clickHaloAction(window, title))
        await("The unchanged wheel must execute the latest selection and close") {
            ordinaryHaloWindowId() == null && !actionWindowExists() &&
                (native || TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED)
        }
        val reader = showPanel(focusable = true, readOnFocus = true)
        await("The focused verifier must read the updated selection") { reader.reads == 1 }
        assertEquals("An old range must never be copied from the retained wheel", selected, reader.text)
        assertEquals("ActionHalo", reader.label)
    }

    @Test fun tappingTheSourceOutsideABoundedWheelStillCancelsWithoutAnAction() {
        for ((native, muted) in listOf(true to false, false to false, false to true)) {
            setMenuModes(standard = !native, telegram = false)
            assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
                .putBoolean("auto_popup_enabled", native).putBoolean("accessibility_consent", native).commit())
            longPressStandardSelection(muteSelectionEvents = muted, activate = !muted)
            await("The selected source must have its bounded wheel") { ordinaryHaloWindowId() != null }
            val source = checkNotNull(findSelectionEditor())
            val bounds = Rect()
            try { source.getBoundsInScreen(bounds) } finally { recycle(source) }
            val x = bounds.left + 64f
            val y = bounds.top + 64f
            val menu = selectionMenu(standard = !native)
            instrumentation.runOnMainSync {
                val origin = IntArray(2).also(menu::getLocationOnScreen)
                assertFalse("The source tap must be outside the bounded wheel", Rect(origin[0], origin[1],
                    origin[0] + menu.width, origin[1] + menu.height).contains(x.toInt(), y.toInt()))
            }
            val down = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0)
                    .apply { this.source = InputDevice.SOURCE_TOUCHSCREEN }
                try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            }
            await("Cancelling the source selection must still close its bounded wheel") {
                ordinaryHaloWindowId() == null && selectionHelperWindowId() == null
            }
            assertFalse("A source tap must not launch a clipboard action", actionWindowExists())
            val reader = showPanel(focusable = true, readOnFocus = true)
            try {
                await("The fixed clipboard seed must remain unchanged after a source tap") { reader.reads == 1 }
                assertEquals(ClipboardOverlayHostActivity.SAMPLE, reader.text)
                assertNotEquals("ActionHalo", reader.label)
            } finally { removePanel(reader) }
        }
    }

    @Test fun initialStandardSelectionStaysQuietWithoutOpeningOrCopying() {
        setMenuModes(standard = true, telegram = false)
        longPressStandardSelection(activate = false)
        assertNoMenuHaloForSettlement()
        assertNull("A range-aware initial selection must not add an Open halo button", selectionHelperWindowId())
        assertFalse(actionWindowExists())
        assertSeedClipboardUnchanged()
    }

    @Test fun menuWithoutSelectionEventsShowsDirectHaloAndCopiesTheAdjustedFragment() =
        exerciseMenuOnlySelection(native = false)

    @Test fun longClickRangeWithoutSelectionEventsDoesNotBlockTheDirectMenuHalo() =
        exerciseMenuOnlySelection(native = true)

    @Test fun telegramMenuWithoutSelectionEventsUsesItsOwnConsentAndCopiesTheExactFragment() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("telegram_menu_fixture") == "true")
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo("org.telegram.messenger", 0)
        assertEquals("Only the separately installed synthetic Telegram fixture is allowed", "fixture-1", info.versionName)
        setMenuModes(standard = false, telegram = true)
        try {
            shell("am start -W -S -n org.telegram.messenger/.CopyFixtureActivity --es fixture_mode nonfocusable")
            await("Telegram's verified nonstandard Copy menu must show the wheel directly") {
                ownOverlayWindows().any { it.second == "ActionHalo Telegram actions" }
            }
            assertNull(selectionHelperWindowId())
            assertFalse(actionWindowExists())
            val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
            val halo = checkNotNull(ordinaryHaloWindowId())
            assertTrue(haloButtonBounds(halo, title) != null)
            saveSelectionScreenshot("menu-only-telegram-direct")
            assertTrue(clickHaloAction(halo, title))
            await("The actual Telegram-only route must dispatch and close") {
                TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED &&
                    ordinaryHaloWindowId() == null && !actionWindowExists()
            }
            val reader = showPanel(focusable = true, readOnFocus = true)
            await("The fixed Telegram fragment must be readable after focus is granted") { reader.reads == 1 }
            assertEquals("中文 🚀 café — selected fragment", reader.text)
            assertEquals("ActionHalo", reader.label)
        } finally { shell("am force-stop org.telegram.messenger") }
    }

    private fun exerciseMenuOnlySelection(native: Boolean) {
        setMenuModes(standard = true, telegram = false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", native).putBoolean("accessibility_consent", native).commit())
        longPressStandardSelection(muteSelectionEvents = true, activate = false)
        await("A verified Copy menu without selection events must show the wheel directly") { ordinaryHaloWindowId() != null }
        assertNull("Menu-only compatibility must not require an extra button", selectionHelperWindowId())
        assertFalse("Showing the wheel must not start a clipboard reader", actionWindowExists())
        saveSelectionScreenshot("menu-only-generic-direct-$native")
        val untouched = showPanel(focusable = true, readOnFocus = true)
        await("The fixed seed must remain untouched until an action is chosen") { untouched.reads == 1 }
        assertEquals(ClipboardOverlayHostActivity.SAMPLE, untouched.text)
        assertNotEquals("ActionHalo", untouched.label)
        removePanel(untouched)
        adjustFixtureSelection(0, 18)
        await("The wheel must remain usable after adjusting an unreported range") { ordinaryHaloWindowId() != null }
        val menu = selectionMenu(standard = true)
        instrumentation.runOnMainSync {
            val params = (menu.parent as View).layoutParams as WindowManager.LayoutParams
            assertEquals("Selection handles must remain outside a bounded, nonmodal wheel", 0,
                params.flags and WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        }
        val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
        assertTrue(clickHaloAction(checkNotNull(ordinaryHaloWindowId()), title))
        await("Copy must complete and close the menu-only wheel") {
            TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED &&
                ordinaryHaloWindowId() == null && !actionWindowExists()
        }
        val reader = showPanel(focusable = true, readOnFocus = true)
        await("The focused verifier must read the final adjusted selection") { reader.reads == 1 }
        assertEquals(SelectionFixtureActivity.SAMPLE_TEXT.substring(0, 18), reader.text)
        assertEquals("ActionHalo", reader.label)
    }

    @Test fun explicitlyChosenMenuButtonModeOpensTheHaloWithoutCopyingBeforeAnActionIsChosen() {
        AppRulesStore(context).setProfile(testPackage, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON))
        setMenuModes(standard = true, telegram = false)
        longPressStandardSelection(activate = false)
        assertNoMenuHaloForSettlement()
        openSelectionHelper(physical = true)
        await("The explicit helper tap must open the real circle") { ordinaryHaloWindowId() != null }
        assertFalse("Opening the circle must not launch a clipboard reader", actionWindowExists())
        assertSeedClipboardUnchanged()
    }

    @Test fun standardMenuCancellationResetsReadinessForTheNextInitialSelection() {
        setMenuModes(standard = true, telegram = false)
        longPressStandardSelection(activate = false)
        assertNoMenuHaloForSettlement()
        assertNull(selectionHelperWindowId())
        adjustFixtureSelection(0, 18)
        await("A real range change must display the menu halo") { ordinaryHaloWindowId() != null }
        adjustFixtureSelection(1, 1)
        await("Collapsing the original selection must clear its circle") { ordinaryHaloWindowId() == null }
        adjustFixtureSelection(0, 9)
        assertNoMenuHaloForSettlement()
        assertNull(selectionHelperWindowId())
        assertSeedClipboardUnchanged()
    }

    @Test fun standardToolbarOpensWebTranslationWithOnlyTheCopiedFragment() {
        val launches = CopyOnWriteArrayList<Intent>()
        val monitor = object : android.app.Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): android.app.Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_VIEW) return null
                launches.add(Intent(intent))
                return android.app.Instrumentation.ActivityResult(android.app.Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            setMenuModes(standard = true, telegram = false)
            val selected = longPressStandardSelection()
            await("The real toolbar must show the halo") { ordinaryHaloWindowId() != null }
            val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "translate" }.title
            assertTrue(clickHaloAction(checkNotNull(ordinaryHaloWindowId()), title))
            await("The production copy bridge must open the website and close its windows") {
                launches.size == 1 && TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED &&
                    ordinaryHaloWindowId() == null && !actionWindowExists()
            }
            val launched = launches.single()
            assertEquals("translate.google.com", launched.data?.host)
            assertEquals(selected, launched.data?.getQueryParameter("text"))
            assertEquals("auto", launched.data?.getQueryParameter("sl"))
            assertTrue(launched.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
            assertNull(launched.component)
        } finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun unknownToolbarTextAllowsExplicitOpenLinkThenRejectsNonLinkInsideWheel() {
        setMenuModes(standard = true, telegram = false)
        val selected = longPressStandardSelection()
        await("The standard toolbar must show its unknown-text halo") { ordinaryHaloWindowId() != null }
        val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "open_url" }.title
        assertTrue("Unknown selection must allow an explicit link request", clickHaloAction(checkNotNull(ordinaryHaloWindowId()), title))
        await("A non-link must fail within the recovery wheel") {
            TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_FAILED && actionWindowExists()
        }
        val delegate = SelectionAccessibilityService::class.java.getDeclaredField("clipboardHaloOverlay\$delegate")
            .apply { isAccessible = true }.get(service) as Lazy<*>
        val overlay = delegate.value as ClipboardHaloOverlay
        instrumentation.runOnMainSync {
            val current = ClipboardHaloOverlay::class.java.getDeclaredField("current").apply { isAccessible = true }
                .get(overlay) as android.view.ViewGroup
            val menu = (0 until current.childCount).map(current::getChildAt).filterIsInstance<RadialMenuView>().single()
            assertTrue(menu.selectionTextKnown)
            assertEquals(selected, menu.selectedText)
            val open = (0 until menu.childCount).map(menu::getChildAt).single { it.contentDescription?.toString() == title }
            assertFalse("Known non-links cannot execute Open link", open.isEnabled)
            menu.onDismiss!!.invoke()
        }
        await("Cancelling recovery must remove every action window") { !actionWindowExists() }
    }

    @Test fun standardToolbarHaloReanchorsAtAnOutsidePressAndCopiesTheExactFragmentOnce() {
        HaloAppearance.setGtaModeEnabled(context, true)
        ActionStore(HaloUi.localizedContext(context)).moveTo("copy", 0)
        setMenuModes(standard = true, telegram = false)
        val selected = longPressStandardSelection()
        await("The standard toolbar must expose its production halo") { ordinaryHaloWindowId() != null }
        dragReanchoredHaloToCopy(selected, standardMenu = true)
        assertEquals(TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED, TelegramCopyDiagnostics.stage)
    }

    @Test fun standardToolbarHaloAnchorsOnlyOnceAfterCancellationAndClosesFromAnOutsideTap() {
        HaloAppearance.setGtaModeEnabled(context, true)
        setMenuModes(standard = true, telegram = false)
        val selected = longPressStandardSelection()
        await("The standard toolbar must show its real halo") { ordinaryHaloWindowId() != null }
        val halo = checkNotNull(ordinaryHaloWindowId())
        val closeLabel = HaloUi.localizedContext(context).getString(R.string.radial_close_menu)
        val original = checkNotNull(haloButtonBounds(halo, closeLabel))
        val density = context.resources.displayMetrics.density
        val initialMenu = selectionMenu(standard = true)
        val point = AtomicReference<Pair<Float, Float>>()
        instrumentation.runOnMainSync {
            val origin = IntArray(2)
            initialMenu.getLocationOnScreen(origin)
            point.set(origin[0] + initialMenu.width * 0.20f to origin[1] + initialMenu.height * 0.20f)
        }
        val (x, y) = point.get()
        var down = SystemClock.uptimeMillis()
        fun touch(action: Int, px: Float, py: Float) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, px, py, 0).apply {
                source = InputDevice.SOURCE_TOUCHSCREEN
            }
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
            instrumentation.waitForIdleSync()
        }
        var anchored: Rect? = null
        fun anchorIsFixed(): Boolean = haloButtonBounds(halo, closeLabel) == anchored

        touch(MotionEvent.ACTION_DOWN, x, y)
        await("The expanded window must publish the new center before testing later gestures") {
            val actual = AtomicReference<Rect>()
            instrumentation.runOnMainSync {
                val center = RadialMenuView::class.java.getDeclaredField("centerButton").apply { isAccessible = true }.get(initialMenu) as View
                val location = IntArray(2).also(center::getLocationOnScreen)
                actual.set(Rect(location[0], location[1], location[0] + center.width, location[1] + center.height))
            }
            val observed = haloButtonBounds(halo, closeLabel)
            if (observed == original || observed != actual.get()) false
            else { anchored = observed; true }
        }
        assertTrue("The center must remain on screen", anchored!!.left >= 0 && anchored!!.top >= 0)
        touch(MotionEvent.ACTION_CANCEL, x, y)
        assertTrue("Cancelling the first gesture must preserve its anchor", anchorIsFixed())
        down = SystemClock.uptimeMillis()
        touch(MotionEvent.ACTION_DOWN, original.exactCenterX(), y)
        assertTrue("A later press must not move the halo again", anchorIsFixed())
        touch(MotionEvent.ACTION_CANCEL, original.exactCenterX(), y)
        val outsideDistance = 240 * density
        val screenHeight = context.resources.displayMetrics.heightPixels
        val anchorY = anchored!!.exactCenterY()
        val outsideY = if (anchorY + outsideDistance < screenHeight - 48 * density) {
            anchorY + outsideDistance
        } else anchorY - outsideDistance
        assertTrue("The outside tap must stay clear of system bars", outsideY in 48 * density..screenHeight - 48 * density)
        down = SystemClock.uptimeMillis()
        touch(MotionEvent.ACTION_DOWN, x, outsideY)
        assertTrue("An outside press must retain the fixed center until release", anchorIsFixed())
        touch(MotionEvent.ACTION_UP, x, outsideY)
        await("An outside tap must dismiss the real halo without executing an action") {
            ordinaryHaloWindowId() == null && !actionWindowExists()
        }
        val editor = checkNotNull(findSelectionEditor())
        try {
            assertTrue(editor.refresh())
            assertEquals("Dismissal must leave the original source selection intact", selected,
                editor.text.toString().substring(editor.textSelectionStart, editor.textSelectionEnd))
        } finally { recycle(editor) }
        assertNoMenuHaloForSettlement()
        assertSeedClipboardUnchanged()
    }

    @Test fun ordinarySelectionHaloReanchorsAtAnOutsidePressAndCopiesTheExactFragmentOnce() {
        HaloAppearance.setGtaModeEnabled(context, false)
        ActionStore(HaloUi.localizedContext(context)).moveTo("copy", 0)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true).commit())
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host")
        await("The foreign source editor must be exposed") {
            findSelectionEditor()?.let { recycle(it); true } ?: false
        }
        val start = SelectionFixtureActivity.SAMPLE_TEXT.indexOf("你好")
        val source = checkNotNull(findSelectionEditor())
        try {
            assertTrue(source.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, 9)
            }))
            assertNoMenuHaloForSettlement()
            assertTrue(source.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, SelectionFixtureActivity.SAMPLE_TEXT.length)
            }))
        } finally { recycle(source) }
        val selected = SelectionFixtureActivity.SAMPLE_TEXT.substring(start)
        await("The actual partial selection must expose its ordinary halo") { ordinaryHaloWindowId() != null }
        dragReanchoredHaloToCopy(selected, standardMenu = false)
    }

    @Test fun telegramConsentAloneDoesNotHandleAnotherAppsStandardSelectionToolbar() {
        setMenuModes(standard = false, telegram = true)
        longPressStandardSelection()
        assertNoMenuHaloForSettlement()
        assertSeedClipboardUnchanged()
    }

    @Test fun withdrawingStandardMenuConsentClearsItsHaloEvenWithTelegramEnabled() {
        setMenuModes(standard = true, telegram = true)
        longPressStandardSelection()
        await("The standard toolbar must show a halo before consent is revoked") { ordinaryHaloWindowId() != null }
        setMenuModes(standard = false, telegram = true)
        await("Revoking this menu's own consent must clear it") { ordinaryHaloWindowId() == null }
        assertNoMenuHaloForSettlement()
        assertSeedClipboardUnchanged()
    }

    @Test fun ordinaryCopyButtonPopupWithoutStandardToolbarIdentityIsIgnored() {
        setMenuModes(standard = true, telegram = false)
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host --es fixture_mode ${SelectionFixtureActivity.MODE_COPY_POPUP}")
        await("A real child application popup must expose its ordinary Copy button") { fixtureCopyPopupShown() }
        assertNull("The ordinary popup must not claim the framework toolbar identity", standardToolbarWindowId())
        assertNoMenuHaloForSettlement()
        assertSeedClipboardUnchanged()
    }

    @Test fun nativeSelectionOwnsTheToolbarAndDismissalUntilTheActualRangeChanges() {
        setMenuModes(standard = true, telegram = false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true).commit())
        instrumentation.waitForIdleSync()
        val selected = longPressStandardSelection()
        await("Native selection must replace its helper with exactly one halo") { ordinaryHaloWindowId() != null && ownOverlayWindows().size == 1 }
        val nativeHalo = assertOnlyNativeHaloForSettlement()
        val closeLabel = HaloUi.localizedContext(context).getString(R.string.radial_close_menu_with_selection, selected)
        assertTrue("The actual native center button must dismiss its selection", clickHaloAction(nativeHalo, closeLabel))
        await("Dismissing the native selection must remove the halo") { ordinaryHaloWindowId() == null }
        assertNoMenuHaloForSettlement()

        val toolbar = checkNotNull(standardToolbarWindowId())
        // Generate real window events without making Android dismiss its toolbar on focus loss.
        val interruption = showPanel(focusable = false, readOnFocus = false)
        await("The real nonfocusable window must be attached") { interruption.isAttachedToWindow }
        SystemClock.sleep(300)
        assertEquals("Only the test window may appear after cancellation", 1, ownOverlayWindows().size)
        assertEquals("ActionHalo focused clipboard framework fixture", ownOverlayWindows().single().second)
        removePanel(interruption)
        assertEquals("The same real selection toolbar must survive the window change", toolbar, standardToolbarWindowId())
        assertNoMenuHaloForSettlement()

        val editor = checkNotNull(findSelectionEditor())
        try {
            assertTrue(editor.refresh())
            assertEquals("The cancelled selection itself must remain unchanged", selected,
                editor.text.toString().substring(editor.textSelectionStart, editor.textSelectionEnd))
            val start = SelectionFixtureActivity.SAMPLE_TEXT.indexOf("你好")
            assertTrue(editor.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, SelectionFixtureActivity.SAMPLE_TEXT.length)
            }))
        } finally { recycle(editor) }
        await("A genuinely new source selection must become usable again") { ordinaryHaloWindowId() != null && ownOverlayWindows().size == 1 }
        assertOnlyNativeHaloForSettlement()
        assertSeedClipboardUnchanged()
    }

    @Test fun productionOverlayWaitsForTemporaryFocusLossThenExecutesOnce() {
        val fixture = productionFixture()
        val blocker = showBlocked(fixture)
        // Deliberately exceed the previous 1.5-second focus timeout. This must wait,
        // not silently discard the pending user-selected action.
        SystemClock.sleep(1_800)
        assertTrue("Pending session must survive a temporary focus owner", isShowing(fixture.overlay))
        assertOperationWheel(fixture.overlay, visible = true)
        assertTrue(fixture.executions.isEmpty())
        removePanel(blocker)
        await("Restoring real focus must resume the selected action") { fixture.executions.size == 1 }
        assertEquals(ClipboardOverlayHostActivity.SAMPLE, fixture.executions.single().second)
        await("Resumed action must close its window") { !isShowing(fixture.overlay) }
        val secondBlocker = showPanel(focusable = true, readOnFocus = false)
        await("Another real window must obtain focus") { secondBlocker.focusGains > 0 }
        removePanel(secondBlocker)
        SystemClock.sleep(300)
        assertEquals("Later focus changes must not repeat the action", 1, fixture.executions.size)
    }

    @Test fun productionOverlayKeepsVisibleHostButCancelsWhenHostCloses() {
        val fixture = productionFixture()
        val blocker = showBlocked(fixture)
        assertTrue("The original host remains visible beneath the temporary focus window", seedHostWindowExists())
        instrumentation.runOnMainSync { fixture.overlay.onWindowsChanged() }
        assertTrue("Another window owning focus must not cancel a visible source host", isShowing(fixture.overlay))
        assertTrue(fixture.executions.isEmpty())

        shell("am force-stop $testPackage")
        await("The real source application window must disappear") { !seedHostWindowExists() }
        await("Closing the source host must cancel its pending action") {
            instrumentation.runOnMainSync { fixture.overlay.onWindowsChanged() }
            !isShowing(fixture.overlay)
        }
        removePanel(blocker)
        SystemClock.sleep(250)
        assertTrue("Restoring focus after the host closes must not execute the action", fixture.executions.isEmpty())
        assertFalse(actionWindowExists())
    }

    @Test fun ordinarySelectionSurvivesAppDialogButCancelsWithSelectionOrHost() {
        HaloAppearance.setGtaModeEnabled(context, false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true).commit())
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host --ez select_all true --ez refine_selection true")
        await("A real foreign text selection must show the ordinary halo") { ordinaryHaloWindowId() != null }
        val haloId = ordinaryHaloWindowId()
        val editor = checkNotNull(findSelectionEditor())
        try {
            assertTrue(editor.refresh())
            assertEquals(0, editor.textSelectionStart)
            assertEquals(SelectionFixtureActivity.SAMPLE_TEXT.length, editor.textSelectionEnd)
            val sourceWindowId = editor.windowId

            shell("am start -W --activity-single-top -n $host --ez show_focus_dialog true")
            await("The real application dialog must own focus") { fixtureDialogFocused() }
            // Allow the separate service connection to consume the real window event.
            SystemClock.sleep(300)
            assertEquals("A temporary application dialog must not discard the selection halo", haloId, ordinaryHaloWindowId())

            shell("input keyevent 4")
            await("Closing the dialog must expose the original source window again") {
                !fixtureDialogFocused() && windowExists(sourceWindowId)
            }
            assertEquals("Restoring the original source must preserve the same selection halo", haloId, ordinaryHaloWindowId())
            assertTrue(editor.refresh())
            assertTrue(editor.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 1)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, 1)
            }))
            await("Collapsing the actual source selection must clear the retained halo") { ordinaryHaloWindowId() == null }

            adjustFixtureSelection(0, 9)
            assertNoMenuHaloForSettlement()
            assertTrue(editor.refresh())
            assertTrue(editor.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, SelectionFixtureActivity.SAMPLE_TEXT.length)
            }))
            await("A new real selection must show a fresh halo") { ordinaryHaloWindowId() != null }
            shell("am force-stop $testPackage")
            await("Closing the real source host must remove its halo") { ordinaryHaloWindowId() == null }
        } finally { recycle(editor) }
    }

    @Test fun ordinarySelectionDefersCopyUntilTheRealDialogCloses() {
        HaloAppearance.setGtaModeEnabled(context, false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true).commit())
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host --ez select_all true --ez refine_selection true")
        await("A real foreign selection must open the ordinary halo") { ordinaryHaloWindowId() != null }
        val haloId = checkNotNull(ordinaryHaloWindowId())
        shell("am start -W --activity-single-top -n $host --ez show_focus_dialog true")
        await("The real application dialog must own focus") { fixtureDialogFocused() }
        SystemClock.sleep(300)
        val copyTitle = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
        assertTrue("Copy must be chosen through the real halo accessibility button", clickHaloAction(haloId, copyTitle))
        assertEquals("The selected action must wait while the dialog obscures its source", haloId, ordinaryHaloWindowId())

        shell("input keyevent 4")
        await("The deferred action must finish after the source returns") {
            !fixtureDialogFocused() && ordinaryHaloWindowId() == null
        }
        val reader = showPanel(focusable = true, readOnFocus = true)
        await("A real focused window must read the copied result") { reader.reads == 1 }
        assertTrue(reader.readHadFocus)
        assertEquals("The deferred action must copy the selected source, not the earlier seed", SelectionFixtureActivity.SAMPLE_TEXT, reader.text)
    }

    @Test fun deniedNativeCopyKeepsTheUnfocusedWheelAndRetriesOnlyWhenChosenAgain() {
        HaloAppearance.setGtaModeEnabled(context, false)
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true)
            .putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, false).commit())
        val originalMode = Regex("(?:WRITE_CLIPBOARD: |Default mode: )(\\w+)")
            .find(shell("cmd appops get ${context.packageName} WRITE_CLIPBOARD"))?.groupValues?.get(1)
            ?: error("The original clipboard write mode must be known before changing it")
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host --ez select_all true --ez refine_selection true")
        await("A real foreign selection must open the ordinary halo") { ordinaryHaloWindowId() != null }
        val halo = checkNotNull(ordinaryHaloWindowId())
        val title = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
        val menu = selectionMenu(false)
        try {
            shell("cmd appops set ${context.packageName} WRITE_CLIPBOARD ignore")
            instrumentation.runOnMainSync { assertFalse(menu.hasWindowFocus()) }
            assertTrue(clickHaloAction(halo, title))
            instrumentation.waitForIdleSync()
            assertEquals("A denied write must not close the nonfocusable selection wheel", halo, ordinaryHaloWindowId())
            val unchanged = showPanel(focusable = true, readOnFocus = true)
            await("The focused probe must verify the previous clipboard survived") { unchanged.reads == 1 }
            assertEquals(ClipboardOverlayHostActivity.SAMPLE, unchanged.text)
            removePanel(unchanged)
            shell("cmd appops set ${context.packageName} WRITE_CLIPBOARD allow")
            assertTrue("Only another explicit Copy retries the write", clickHaloAction(halo, title))
            await("The confirmed retry must close the wheel") { ordinaryHaloWindowId() == null }
            val copied = showPanel(focusable = true, readOnFocus = true)
            await("The focused probe must read the retried copy") { copied.reads == 1 }
            assertEquals(SelectionFixtureActivity.SAMPLE_TEXT, copied.text)
            assertEquals("ActionHalo", copied.label)
        } finally { shell("cmd appops set ${context.packageName} WRITE_CLIPBOARD $originalMode") }
    }

    @Test fun ordinaryPendingSelectionWaitsForModalBeforeShowingHalo() {
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true).commit())
        val pendingField = SelectionAccessibilityService::class.java.getDeclaredField("pending").apply { isAccessible = true }
        val handlerField = SelectionAccessibilityService::class.java.getDeclaredField("handler").apply { isAccessible = true }
        val runnableField = SelectionAccessibilityService::class.java.getDeclaredField("showPending").apply { isAccessible = true }
        val capturedPending = AtomicReference<Any>()
        val delayedShow = AtomicReference<Runnable>()
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host --ez select_all true")
        assertNoMenuHaloForSettlement()
        assertNull(selectionHelperWindowId())
        adjustFixtureSelection(0, 9)
        val deadline = SystemClock.uptimeMillis() + 6_000
        while (capturedPending.get() == null && SystemClock.uptimeMillis() < deadline) {
            instrumentation.runOnMainSync {
                val selection = pendingField.get(service)
                if (selection != null) {
                    // Pause only the real debounce callback; the source and event come from the foreign EditText.
                    val show = runnableField.get(service) as Runnable
                    (handlerField.get(service) as Handler).removeCallbacks(show)
                    capturedPending.set(selection)
                    delayedShow.set(show)
                }
            }
            if (capturedPending.get() == null) SystemClock.sleep(5)
        }
        assertTrue("The actual selection must be captured during its debounce interval", capturedPending.get() != null)
        assertNull(ordinaryHaloWindowId())

        shell("am start -W --activity-single-top -n $host --ez show_focus_dialog true")
        await("The real modal dialog must own focus before the delayed show runs") { fixtureDialogFocused() }
        SystemClock.sleep(300)
        instrumentation.runOnMainSync {
            delayedShow.get().run()
            assertSame("An obscured source must retain its actual pending selection", capturedPending.get(), pendingField.get(service))
        }
        assertNull("The halo must wait until its source becomes accessible again", ordinaryHaloWindowId())

        shell("input keyevent 4")
        await("Restoring the source must automatically display the pending selection") {
            !fixtureDialogFocused() && ordinaryHaloWindowId() != null
        }
        instrumentation.runOnMainSync { assertNull(pendingField.get(service)) }
    }

    @Test fun productionOverlayKeepsTheFirstSnapshotAcrossRealFocusLoss() {
        val executions = CopyOnWriteArrayList<Pair<HaloAction, String>>()
        val reads = AtomicInteger()
        val pendingActions = ConcurrentLinkedQueue<Runnable>()
        val overlayReference = AtomicReference<ClipboardHaloOverlay>()
        instrumentation.runOnMainSync {
            val copy = ActionStore(HaloUi.localizedContext(service)).actions().single { it.id == "copy" }
            val overlay = ClipboardHaloOverlay(service, { true }, executeAction = { _, action, text ->
                executions.add(action to text)
                true
            }, readClipboard = { readContext ->
                val clip = readContext.getSystemService(ClipboardManager::class.java).primaryClip
                reads.incrementAndGet()
                clip
            }, postAction = { _, action -> pendingActions.add(action) })
            productionOverlays.add(overlay)
            overlayReference.set(overlay)
            overlay.show(seedStartedUptime, seedStartedWall, seedFinishedWall, copy, seedHostWindowId)
        }
        val overlay = overlayReference.get()
        await("The real clipboard snapshot must be captured before its action is released") { pendingActions.isNotEmpty() }
        assertEquals(1, reads.get())
        assertOperationWheel(overlay, visible = false)

        // Control only callback scheduling: focus callbacks and clipboard access remain real.
        // Waiting for first layout avoids assuming a new window wins focus before the next frame.
        val blocker = showPanel(focusable = true, readOnFocus = false)
        await("The second real window must gain focus before the queued action runs") { blocker.focusGains > 0 }
        instrumentation.runOnMainSync { checkNotNull(pendingActions.poll()).run() }
        assertTrue("The snapshot must remain pending while another window owns focus", isShowing(overlay))
        assertTrue("The action must not run underneath the temporary focus owner", executions.isEmpty())
        instrumentation.runOnMainSync {
            assertTrue(blocker.hasWindowFocus())
            // The service UID now owns this real window and can replace its clipboard.
            // A second production read after resuming would incorrectly consume this text.
            service.getSystemService(ClipboardManager::class.java).setPrimaryClip(
                ClipData.newPlainText("Fixed replacement fixture", "新剪贴板不应替换原选文 🪁"))
        }
        removePanel(blocker)
        await("Restoring real focus must enqueue the retained snapshot") { pendingActions.isNotEmpty() }
        instrumentation.runOnMainSync { checkNotNull(pendingActions.poll()).run() }
        await("Returning focus must execute the retained snapshot") { executions.size == 1 }
        assertEquals(ClipboardOverlayHostActivity.SAMPLE, executions.single().second)
        assertEquals("Focus restoration must reuse the first read", 1, reads.get())
        await("Completed snapshot action must close") { !isShowing(overlay) }
        SystemClock.sleep(250)
        assertEquals(1, executions.size)
        Log.i(TAG, "production_snapshot controlled_dispatch=true real_focus_loss=true real_clip_replaced=true reads=1 executions=1 original_unicode=true")
    }

    @Test fun failedActionKeepsOneSnapshotAndRetriesOnlyAfterAnotherExplicitChoice() {
        val reads = AtomicInteger()
        val attempts = AtomicInteger()
        val reference = AtomicReference<ClipboardHaloOverlay>()
        val selected = AtomicReference<HaloAction>()
        val texts = CopyOnWriteArrayList<String>()
        instrumentation.runOnMainSync {
            val copy = ActionStore(service).actions().single { it.id == "copy" }
            selected.set(copy)
            val overlay = ClipboardHaloOverlay(service, { true }, executeAction = { _, _, text ->
                texts.add(text)
                attempts.incrementAndGet() >= 3
            }, readClipboard = { context ->
                reads.incrementAndGet()
                context.getSystemService(ClipboardManager::class.java).primaryClip
            })
            reference.set(overlay)
            productionOverlays.add(overlay)
            overlay.show(seedStartedUptime, seedStartedWall, seedFinishedWall, copy, seedHostWindowId)
        }
        val overlay = reference.get()
        await("The first failed request must retain a recovery wheel") { attempts.get() == 1 && isShowing(overlay) }
        val menuReference = AtomicReference<RadialMenuView>()
        fun recoveryMenu(): RadialMenuView {
            val field = ClipboardHaloOverlay::class.java.getDeclaredField("current").apply { isAccessible = true }
            val root = field.get(overlay) as android.view.ViewGroup
            return (0 until root.childCount).map { root.getChildAt(it) }.filterIsInstance<RadialMenuView>().single()
        }
        instrumentation.runOnMainSync {
            menuReference.set(recoveryMenu())
            assertEquals(ClipboardOverlayHostActivity.SAMPLE, menuReference.get().selectedText)
        }
        val blocker = showPanel(focusable = true, readOnFocus = false)
        await("A temporary panel must gain focus") { blocker.focusGains > 0 }
        removePanel(blocker)
        await("The retry surface must regain real input focus") {
            val focused = AtomicBoolean()
            instrumentation.runOnMainSync { focused.set(menuReference.get().hasWindowFocus()) }
            focused.get()
        }
        SystemClock.sleep(200)
        assertEquals("Regaining focus must not retry a failed action automatically", 1, attempts.get())
        assertEquals(1, reads.get())
        instrumentation.runOnMainSync {
            menuReference.get().onActionSelected!!.invoke(selected.get())
            assertEquals(2, attempts.get())
            assertSame("A second failure preserves the exact wheel and its finger anchor", menuReference.get(), recoveryMenu())
            recoveryMenu().onActionSelected!!.invoke(selected.get())
        }
        await("The explicit successful retry must close the retained request") { !isShowing(overlay) }
        assertEquals(3, attempts.get())
        assertEquals(1, reads.get())
        assertEquals(List(3) { ClipboardOverlayHostActivity.SAMPLE }, texts.toList())
    }

    @Test fun productionOverlayRejectsAnOlderClipWithoutExecuting() {
        val fixture = productionFixture()
        instrumentation.runOnMainSync {
            // The only clip was seeded before seedFinishedWall. This artificial
            // action interval cannot contain it, even with millisecond ties.
            fixture.overlay.show(SystemClock.uptimeMillis(), seedFinishedWall + 1,
                seedFinishedWall + 2, fixture.copy, seedHostWindowId)
        }
        await("Old clip must be rejected") { !isShowing(fixture.overlay) }
        assertTrue(fixture.executions.isEmpty())
        assertEquals(TelegramCopyDiagnostics.Stage.CLIP_NOT_FRESH, TelegramCopyDiagnostics.stage)
    }

    @Test fun productionOverlayRechecksPermissionBeforeExecuting() {
        val fixture = productionFixture()
        val blocker = showBlocked(fixture)
        fixture.allowed.set(false)
        removePanel(blocker)
        await("Revoked consent must cancel the pending action") { !isShowing(fixture.overlay) }
        assertTrue(fixture.executions.isEmpty())
    }

    @Test fun productionOverlayDismissCancelsWithoutResidualAction() {
        val fixture = productionFixture()
        val blocker = showBlocked(fixture)
        instrumentation.runOnMainSync { fixture.overlay.dismiss() }
        removePanel(blocker)
        SystemClock.sleep(400)
        assertFalse(isShowing(fixture.overlay))
        assertTrue(fixture.executions.isEmpty())
        assertFalse("Cancelled action window must be removed", actionWindowExists())
    }

    @Test fun productionOverlayNewRequestCancelsThePreviousPendingRequest() {
        val fixture = productionFixture()
        val blocker = showBlocked(fixture)
        instrumentation.runOnMainSync {
            // Replace the fresh pending request with an intentionally stale one.
            // A queued focus callback from the first request must not execute it.
            fixture.overlay.show(SystemClock.uptimeMillis(), seedFinishedWall + 1,
                seedFinishedWall + 2, fixture.copy, seedHostWindowId)
        }
        await("Replacement stale request must be rejected") { !isShowing(fixture.overlay) }
        removePanel(blocker)
        SystemClock.sleep(300)
        assertTrue(fixture.executions.isEmpty())
        assertFalse(actionWindowExists())
    }

    @Test fun telegramAssistantIgnoresTogglesAfterRealServiceUnbinds() {
        val otherServices = serviceNames(shell("settings get secure enabled_accessibility_services").trim())
            .filterNot { ComponentName.unflattenFromString(it) == component }
        writeSecure("enabled_accessibility_services", otherServices.joinToString(":"))
        await("The real accessibility service must unbind") { connectedService() == null }
        instrumentation.runOnMainSync {
            assertNull("The retained service reference must no longer have framework service info", service.serviceInfo)
            val assistant = TelegramCopyAssistant(service, { Rect(0, 0, 1, 1) }, { false }, {},
                { _, _, _, _, _, _ -> })
            try {
                assistant.setEnabled(true)
                assertFalse(assistant.isShowing)
                assistant.setEnabled(false)
                assertFalse(assistant.isShowing)
            } finally { assistant.clear() }
        }
    }

    private inner class ProductionFixture {
        val allowed = AtomicBoolean(true)
        val executions = CopyOnWriteArrayList<Pair<HaloAction, String>>()
        val copy = ActionStore(HaloUi.localizedContext(service)).actions().single { it.id == "copy" }
        val overlay = ClipboardHaloOverlay(service, allowed::get, executeAction = { _, action, text ->
            executions.add(action to text)
            true
        })
        fun show() = overlay.show(seedStartedUptime, seedStartedWall, seedFinishedWall, copy, seedHostWindowId)
    }

    private fun productionFixture(): ProductionFixture {
        val result = AtomicReference<ProductionFixture>()
        instrumentation.runOnMainSync {
            TelegramCopyDiagnostics.reset()
            val fixture = ProductionFixture()
            productionOverlays.add(fixture.overlay)
            result.set(fixture)
        }
        return result.get()
    }

    private fun showBlocked(fixture: ProductionFixture): ProbePanel {
        val result = AtomicReference<ProbePanel>()
        instrumentation.runOnMainSync {
            fixture.show()
            result.set(addPanelOnMain(focusable = true, readOnFocus = false))
        }
        val blocker = result.get()
        await("The second real window must own focus before the production action runs") { blocker.focusGains > 0 }
        assertTrue("The pending action must still exist", isShowing(fixture.overlay))
        assertTrue("The obscured production window must not execute", fixture.executions.isEmpty())
        return blocker
    }

    private fun removePanel(panel: View) {
        instrumentation.runOnMainSync {
            if (panel.isAttachedToWindow) service.getSystemService(WindowManager::class.java).removeViewImmediate(panel)
            panels.remove(panel)
        }
    }

    private fun isShowing(overlay: ClipboardHaloOverlay): Boolean {
        val result = AtomicBoolean()
        instrumentation.runOnMainSync { result.set(overlay.isShowing) }
        return result.get()
    }

    private fun assertOperationWheel(overlay: ClipboardHaloOverlay, visible: Boolean) {
        instrumentation.runOnMainSync {
            val field = ClipboardHaloOverlay::class.java.getDeclaredField("current").apply { isAccessible = true }
            val root = field.get(overlay) as android.view.ViewGroup
            val menus = (0 until root.childCount).map(root::getChildAt).filterIsInstance<RadialMenuView>()
            assertEquals(if (visible) 1 else 0, menus.size)
            if (visible) {
                val labels = (0 until menus.single().childCount).map(menus.single()::getChildAt)
                    .filterIsInstance<TextView>().map { it.text.toString() }
                assertTrue(labels.contains(HaloUi.localizedContext(context).getString(R.string.operation_waiting_focus)))
                assertFalse(labels.contains(context.getString(R.string.copy_action_continue)))
            }
        }
    }

    private fun actionWindowExists(): Boolean =
        ownOverlayWindows().any { it.second == "ActionHalo selected text action" }


    private fun showPanel(focusable: Boolean, readOnFocus: Boolean): ProbePanel {
        val result = AtomicReference<ProbePanel>()
        instrumentation.runOnMainSync {
            result.set(addPanelOnMain(focusable, readOnFocus))
        }
        return result.get()
    }

    private fun addPanelOnMain(focusable: Boolean, readOnFocus: Boolean): ProbePanel {
        val panel = ProbePanel(readOnFocus)
        val density = service.resources.displayMetrics.density
        val flags = WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            (if (focusable) 0 else WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        val params = WindowManager.LayoutParams((280 * density).toInt(), (100 * density).toInt(),
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, flags, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.CENTER
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN
            title = "ActionHalo focused clipboard framework fixture"
        }
        service.getSystemService(WindowManager::class.java).addView(panel, params)
        panels.add(panel)
        return panel
    }

    private inner class ProbePanel(private val readOnFocus: Boolean) : FrameLayout(service) {
        @Volatile var focusGains = 0
        @Volatile var reads = 0
        @Volatile var readHadFocus = false
        @Volatile var text: String? = null
        @Volatile var label: String? = null

        init {
            isFocusableInTouchMode = true
            setBackgroundColor(Color.DKGRAY)
            addView(TextView(service).apply {
                setTextColor(Color.WHITE)
                text = "Visible clipboard framework fixture"
                textSize = 20f
                setPadding(20, 20, 20, 20)
            })
        }

        override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
            super.onWindowFocusChanged(hasWindowFocus)
            if (!hasWindowFocus) return
            focusGains++
            if (readOnFocus && reads == 0) readFixedFixture()
        }

        fun readFixedFixture() {
            readHadFocus = hasWindowFocus()
            val clip = try { service.getSystemService(ClipboardManager::class.java).primaryClip }
                catch (_: SecurityException) { null }
            text = if (clip?.itemCount == 1) clip.getItemAt(0).text?.toString() else null
            label = clip?.description?.label?.toString()
            reads++
        }
    }

    private fun setMenuModes(standard: Boolean, telegram: Boolean) {
        assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE).edit()
            .putBoolean("auto_popup_enabled", false)
            .putBoolean(TelegramCopyPolicy.SETTING, telegram)
            .putBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, standard).commit())
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync { TelegramCopyDiagnostics.reset() }
    }

    private fun longPressStandardSelection(handleGeometry: Boolean = false, muteSelectionEvents: Boolean = false,
        activate: Boolean = true, multiline: Boolean = false): String {
        val host = "$testPackage/${SelectionFixtureActivity::class.java.name}"
        shell("am start -W -S -n $host --ez selection_handles $handleGeometry --ez mute_selection_events $muteSelectionEvents --ez multiline_selection $multiline")
        await("The foreign editor must be exposed") {
            findSelectionEditor()?.let { recycle(it); true } ?: false
        }
        SystemClock.sleep(500)
        val editor = checkNotNull(findSelectionEditor())
        val bounds = Rect()
        try { editor.getBoundsInScreen(bounds) } finally { recycle(editor) }
        val down = SystemClock.uptimeMillis()
        fun touch(action: Int) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                bounds.left + 64f, bounds.top + 64f, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
        touch(MotionEvent.ACTION_DOWN)
        SystemClock.sleep(900)
        touch(MotionEvent.ACTION_UP)
        await("Long press must create a real framework FloatingToolbar child window") { standardToolbarWindowId() != null }
        val selected = AtomicReference<String>()
        await("The foreign editor must expose a real nonempty partial selection") {
            val source = findSelectionEditor() ?: return@await false
            try {
                if (!source.refresh()) return@await false
                val start = source.textSelectionStart
                val end = source.textSelectionEnd
                val text = source.text?.toString() ?: return@await false
                if (start < 0 || end <= start || end > text.length || end - start == text.length) return@await false
                selected.set(text.substring(start, end))
                true
            } finally { recycle(source) }
        }
        if (activate) {
            val settings = context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
            if (AppRulesStore(context).triggerMode(testPackage) == AppRulesStore.TriggerMode.BUTTON) openSelectionHelper()
            else if ((settings.getBoolean("auto_popup_enabled", false) && settings.getBoolean("accessibility_consent", false)) ||
                settings.getBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false)) {
                // Settle and verify the initial interaction before issuing an instantaneous programmatic refinement.
                assertNoMenuHaloForSettlement()
                val range = checkNotNull(findSelectionEditor())
                try {
                    assertTrue(range.refresh())
                    val start = range.textSelectionStart
                    val end = (range.textSelectionEnd + 9).coerceAtMost(range.text.length)
                    adjustFixtureSelection(start, end)
                    selected.set(range.text.toString().substring(start, end))
                } finally { recycle(range) }
            }
        }
        return selected.get()
    }

    private fun adjustFixtureSelection(start: Int, end: Int) {
        var available: AccessibilityNodeInfo? = null
        await("The foreign editor must be available before requesting a new fixture selection") {
            available = findSelectionEditor()
            available != null
        }
        val source = checkNotNull(available)
        try {
            assertTrue(source.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
            }))
        } finally { recycle(source) }
        instrumentation.waitForIdleSync()
    }

    private fun selectionHelperWindowId(): Int? = ownOverlayWindows().firstOrNull {
        it.second == "ActionHalo selection helper"
    }?.first

    private fun openSelectionHelper(physical: Boolean = false) {
        await("The manual selection helper must be available") { selectionHelperWindowId() != null }
        val id = checkNotNull(selectionHelperWindowId())
        val label = context.getString(R.string.selection_open_halo)
        if (physical) {
            val bounds = checkNotNull(haloButtonBounds(id, label))
            val down = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                    bounds.exactCenterX(), bounds.exactCenterY(), 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
                instrumentation.waitForIdleSync()
            }
        } else assertTrue(clickHaloAction(id, label))
        await("The requested circle must finish publishing its window") { ordinaryHaloWindowId() != null }
    }

    private fun standardToolbarWindowId(): Int? {
        val local = localWindowIds()
        val windows = automation.windows
        try {
            for (window in windows) {
                if (window.id in local || window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val parent = window.parent ?: continue
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT < 33) parent.recycle()
                val root = window.root ?: continue
                try {
                    if (root.packageName?.toString() != testPackage) continue
                    val containers = root.findAccessibilityNodeInfosByViewId(TelegramCopyPolicy.STANDARD_MENU_CONTAINER_ID) +
                        root.findAccessibilityNodeInfosByViewId(TelegramCopyPolicy.STANDARD_MENU_ITEM_ID)
                    try { if (containers.isNotEmpty()) return window.id }
                    finally { containers.forEach(::recycle) }
                } finally { recycle(root) }
            }
            return null
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }

    private fun fixtureCopyPopupShown(): Boolean {
        val local = localWindowIds()
        val windows = automation.windows
        try {
            for (window in windows) {
                if (window.id in local || window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val parent = window.parent ?: continue
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT < 33) parent.recycle()
                val root = window.root ?: continue
                try {
                    if (root.packageName?.toString() != testPackage) continue
                    val buttons = root.findAccessibilityNodeInfosByText(context.getString(android.R.string.copy))
                    try { if (buttons.any { it.isClickable }) return true }
                    finally { buttons.forEach(::recycle) }
                } finally { recycle(root) }
            }
            return false
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }

    private fun assertNoMenuHaloForSettlement() {
        val deadline = SystemClock.uptimeMillis() + 800
        do {
            assertNull("No menu halo may appear without an eligible, consented toolbar", ordinaryHaloWindowId())
            assertFalse(actionWindowExists())
            SystemClock.sleep(40)
        } while (SystemClock.uptimeMillis() < deadline)
    }

    private fun assertOnlyNativeHaloForSettlement(): Int {
        val halo = checkNotNull(ordinaryHaloWindowId())
        val deadline = SystemClock.uptimeMillis() + 800
        do {
            val windows = ownOverlayWindows()
            assertEquals("Native and standard-menu modes must not show duplicate halos", 1, windows.size)
            assertEquals(halo, windows.single().first)
            assertNotEquals("The native selection must retain priority over its menu", "ActionHalo selection menu actions", windows.single().second)
            SystemClock.sleep(40)
        } while (SystemClock.uptimeMillis() < deadline)
        return halo
    }

    private fun assertSeedClipboardUnchanged() {
        val reader = showPanel(focusable = true, readOnFocus = true)
        await("The visible probe must obtain focus before checking the unchanged seed") { reader.reads == 1 }
        assertTrue(reader.readHadFocus)
        assertEquals(ClipboardOverlayHostActivity.SAMPLE, reader.text)
        assertNotEquals("ActionHalo", reader.label)
    }

    /** Test-only access to the existing bound instance; no production endpoint or lifecycle simulation. */
    private fun connectedService(): SelectionAccessibilityService? {
        val result = AtomicReference<SelectionAccessibilityService?>()
        instrumentation.runOnMainSync {
            val field = SelectionAccessibilityService::class.java.getDeclaredField("connectedService")
            field.isAccessible = true
            result.set((field.get(null) as? WeakReference<*>)?.get() as? SelectionAccessibilityService)
        }
        return result.get()
    }

    private fun selectionMenu(standard: Boolean): RadialMenuView {
        val result = AtomicReference<RadialMenuView>()
        instrumentation.runOnMainSync {
            if (standard) {
                val delegate = SelectionAccessibilityService::class.java.getDeclaredField("telegramCopyAssistant\$delegate")
                    .apply { isAccessible = true }.get(service) as Lazy<*>
                result.set(TelegramCopyAssistant::class.java.getDeclaredField("radial").apply { isAccessible = true }
                    .get(delegate.value) as RadialMenuView)
            } else result.set(SelectionAccessibilityService::class.java.getDeclaredField("overlay").apply { isAccessible = true }
                .get(service) as RadialMenuView)
        }
        return result.get()
    }

    private fun saveSelectionScreenshot(name: String) {
        automation.takeScreenshot()?.let { bitmap ->
            java.io.FileOutputStream(java.io.File(context.cacheDir, "$name.png")).use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }
    }

    private fun hostFocusedAndSeeded(): Boolean = focusedSeedHostWindowId() != null

    private fun focusedSeedHostWindowId(): Int? {
        val local = localWindowIds()
        val windows = automation.windows
        try {
            for (window in windows) {
                if (window.id in local || window.type != AccessibilityWindowInfo.TYPE_APPLICATION || !window.isFocused) continue
                val root = window.root ?: continue
                try {
                    if (root.packageName?.toString() != testPackage) continue
                    val markers = root.findAccessibilityNodeInfosByText(ClipboardOverlayHostActivity.SEEDED)
                    try { if (markers.isNotEmpty()) return window.id } finally { markers.forEach(::recycle) }
                } finally { recycle(root) }
            }
            return null
        } finally {
            if (Build.VERSION.SDK_INT < 33) {
                @Suppress("DEPRECATION")
                windows.forEach { it.recycle() }
            }
        }
    }

    private fun seedHostWindowExists(): Boolean = windowExists(seedHostWindowId)

    private fun windowExists(id: Int): Boolean {
        val windows = automation.windows
        try { return windows.any { it.id == id } }
        finally {
            if (Build.VERSION.SDK_INT < 33) {
                @Suppress("DEPRECATION")
                windows.forEach { it.recycle() }
            }
        }
    }

    private fun ordinaryHaloWindowId(): Int? {
        val owned = ownOverlayWindows().filter { it.second != "ActionHalo selection helper" }.map { it.first }
        return inspectLocalWindows { roots ->
            owned.firstOrNull { id ->
                roots.firstOrNull { localWindowId(it) == id }?.let { root ->
                    findLocalAccessibleView(root) { it.className?.toString() == "android.widget.Button" } != null
                } == true
            }
        }
    }

    private fun ownOverlayWindows(): List<Pair<Int, String?>> = inspectLocalWindows { roots ->
        roots.mapNotNull { root ->
            val params = root.layoutParams as? WindowManager.LayoutParams ?: return@mapNotNull null
            if (params.type != WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY) return@mapNotNull null
            val id = localWindowId(root)
            if (id < 0) null else id to params.title?.toString()?.takeIf { it.isNotEmpty() }
        }
    }

    // Android 11 shares one AccessibilityCache between UiAutomation and the real service.
    // Caching our own nodes lets UiAutomation refresh them while holding the cache lock,
    // blocking the main thread that must answer that refresh. Inspect the attached Views
    // on their own thread, including LayoutParams: the shared window cache can also omit
    // a restored, visible overlay after selection dragging. Foreign-app nodes and window
    // metadata still use UiAutomation.
    private fun <T> inspectLocalWindows(inspect: (List<View>) -> T): T {
        val result = AtomicReference<T>()
        instrumentation.runOnMainSync {
            result.set(inspect(WindowInspector.getGlobalWindowViews().filter { it.isAttachedToWindow }))
        }
        return result.get()
    }

    private fun localWindowIds(): Set<Int> = inspectLocalWindows { roots -> roots.map(::localWindowId).toSet() }

    private fun localWindowId(root: View): Int {
        val node = root.createAccessibilityNodeInfo()
        return try { node.windowId } finally { recycle(node) }
    }

    private fun findLocalAccessibleView(root: View, depth: Int = 0,
        matches: (AccessibilityNodeInfo) -> Boolean): View? {
        if (depth > 8 || !root.isShown) return null
        val node = root.createAccessibilityNodeInfo()
        try {
            if (!node.isVisibleToUser) return null
            if (matches(node)) return root
        } finally { recycle(node) }
        val children = arrayListOf<View>()
        root.addChildrenForAccessibility(children)
        for (child in children) {
            findLocalAccessibleView(child, depth + 1, matches)?.let { return it }
        }
        return null
    }

    private fun findLocalHaloButton(roots: List<View>, windowId: Int, label: String): View? {
        val root = roots.firstOrNull { localWindowId(it) == windowId } ?: return null
        return findLocalAccessibleView(root) {
            it.isClickable && (it.contentDescription?.toString() == label || it.text?.toString() == label)
        }
    }

    private fun fixtureDialogFocused(): Boolean {
        val windows = automation.windows
        try { return windows.any { it.isFocused && it.title?.toString() == SelectionFixtureActivity.FOCUS_DIALOG_TITLE } }
        finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }

    private fun clickHaloAction(windowId: Int, label: String): Boolean {
        return inspectLocalWindows { roots ->
            findLocalHaloButton(roots, windowId, label)
                ?.performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, null) == true
        }
    }

    private fun haloButtonBounds(windowId: Int, label: String): Rect? {
        return inspectLocalWindows { roots ->
            val button = findLocalHaloButton(roots, windowId, label) ?: return@inspectLocalWindows null
            val node = button.createAccessibilityNodeInfo()
            try { Rect().also(node::getBoundsInScreen) } finally { recycle(node) }
        }
    }

    private fun dragReanchoredHaloToCopy(selected: String, standardMenu: Boolean) {
        val haloId = checkNotNull(ordinaryHaloWindowId())
        val executions = AtomicInteger()
        val press = AtomicReference<Pair<Float, Float>>()
        val density = context.resources.displayMetrics.density
        instrumentation.runOnMainSync {
            // Observe the existing callback without replacing its production action or window lifecycle.
            val menu = if (standardMenu) {
                val delegate = SelectionAccessibilityService::class.java.getDeclaredField("telegramCopyAssistant\$delegate")
                    .apply { isAccessible = true }.get(service) as Lazy<*>
                TelegramCopyAssistant::class.java.getDeclaredField("radial").apply { isAccessible = true }
                    .get(delegate.value) as RadialMenuView
            } else {
                SelectionAccessibilityService::class.java.getDeclaredField("overlay").apply { isAccessible = true }
                    .get(service) as RadialMenuView
            }
            val original = checkNotNull(menu.onActionSelected)
            menu.onActionSelected = { action ->
                assertEquals("The physical gesture must choose Copy", "copy", action.id)
                executions.incrementAndGet()
                original(action)
            }
            val origin = IntArray(2)
            menu.getLocationOnScreen(origin)
            // A blank corner belongs to the compact window while remaining outside the wheel.
            press.set(origin[0] + menu.width * 0.20f to origin[1] + menu.height * 0.20f)
        }
        val localized = HaloUi.localizedContext(context)
        val centerLabel = if (standardMenu) localized.getString(R.string.radial_close_menu)
            else localized.getString(R.string.radial_close_menu_with_selection, selected)
        val (x, y) = press.get()
        val down = SystemClock.uptimeMillis()
        fun touch(action: Int, px: Float, py: Float) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, px, py, 0).apply {
                source = InputDevice.SOURCE_TOUCHSCREEN
            }
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
            instrumentation.waitForIdleSync()
        }
        var anchored: Rect? = null
        fun anchorIsAtPress(): Boolean = haloButtonBounds(haloId, centerLabel) == anchored
        fun assertSourceSelection() {
            val editor = checkNotNull(findSelectionEditor())
            try {
                assertTrue(editor.refresh())
                assertTrue("The nonfocusable halo must preserve source focus", editor.isFocused)
                assertEquals("Reanchoring must preserve the exact source range", selected,
                    editor.text.toString().substring(editor.textSelectionStart, editor.textSelectionEnd))
            } finally { recycle(editor) }
        }
        touch(MotionEvent.ACTION_DOWN, x, y)
        Log.i(TAG, "corner_press standard=$standardMenu point=$x,$y center=${haloButtonBounds(haloId, centerLabel)} windows=${ownOverlayWindows()}")
        val expectedCenter = AtomicReference<Pair<Float, Float>>()
        val anchoredMenu = selectionMenu(standardMenu)
        instrumentation.runOnMainSync {
            val menu = anchoredMenu
            val origin = requireNotNull(menu.screenOriginForAnchor).invoke()
            expectedCenter.set(origin.first + menu.width / 2f to origin.second + menu.height / 2f)
        }
        await("The expanded window must publish its final safe anchor before the drag continues") {
            haloButtonBounds(haloId, centerLabel)?.let { rect ->
                abs(rect.exactCenterX() - expectedCenter.get().first) <= 2f &&
                    abs(rect.exactCenterY() - expectedCenter.get().second) <= 2f
            } == true
        }
        anchored = checkNotNull(haloButtonBounds(haloId, centerLabel))
        assertTrue("The safe anchor must remain visible", anchored!!.left >= 0 && anchored!!.top >= 0)
        assertSourceSelection()
        assertEquals("Pressing the new center must not execute an action", 0, executions.get())
        touch(MotionEvent.ACTION_MOVE, x + 80 * density, y)
        assertTrue("Moving the finger must keep the new center fixed: before=$anchored after=${haloButtonBounds(haloId, centerLabel)}", anchorIsAtPress())
        val copyTitle = ActionStore(HaloUi.localizedContext(context)).actions().single { it.id == "copy" }.title
        val copy = checkNotNull(haloButtonBounds(haloId, copyTitle))
        touch(MotionEvent.ACTION_MOVE, copy.exactCenterX(), copy.exactCenterY())
        assertTrue("Turning toward Copy must retain the same center: before=$anchored after=${haloButtonBounds(haloId, centerLabel)}", anchorIsAtPress())
        assertSourceSelection()
        assertEquals("Moving must only preview the action", 0, executions.get())
        touch(MotionEvent.ACTION_UP, copy.exactCenterX(), copy.exactCenterY())
        await("Releasing Copy must finish its real production action") {
            executions.get() == 1 && ordinaryHaloWindowId() == null && !actionWindowExists() &&
                (!standardMenu || TelegramCopyDiagnostics.stage == TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED)
        }
        val reader = showPanel(focusable = true, readOnFocus = true)
        await("The focused reader must read the exact copied fragment") { reader.reads == 1 }
        assertTrue(reader.readHadFocus)
        assertEquals(selected, reader.text)
        assertEquals("ActionHalo", reader.label)
        SystemClock.sleep(250)
        assertEquals("Later focus changes must not execute Copy again", 1, executions.get())
    }

    private fun findSelectionEditor(): AccessibilityNodeInfo? {
        val local = localWindowIds()
        val windows = automation.windows
        try {
            for (window in windows) {
                if (window.id in local || window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val root = window.root ?: continue
                try {
                    if (root.packageName?.toString() != testPackage) continue
                    val matches = root.findAccessibilityNodeInfosByText(SelectionFixtureActivity.SAMPLE_TEXT)
                    val editor = matches.firstOrNull { it.className?.toString() == "android.widget.EditText" }
                    matches.filterNot { it === editor }.forEach(::recycle)
                    if (editor != null) return editor
                } finally { recycle(root) }
            }
            return null
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }

    private fun serviceNames(value: String?): List<String> = value?.takeUnless { it == "null" || it.isBlank() }
        ?.split(':')?.filter { it.isNotBlank() }.orEmpty()

    private fun writeSecure(key: String, value: String?) {
        if (value == null || value == "null" || value.isBlank()) shell("settings delete secure $key")
        else {
            require(value.matches(Regex("[A-Za-z0-9_./:$]+")))
            shell("settings put secure $key $value")
        }
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 6_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(40)
        }
        throw AssertionError(message)
    }

    @Suppress("DEPRECATION")
    private fun recycle(node: AccessibilityNodeInfo) { if (Build.VERSION.SDK_INT < 33) node.recycle() }
    private fun shell(command: String): String = automation.executeShellCommand(command).use {
        android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().use { reader -> reader.readText() }
    }

    companion object { private const val TAG = "FocusedClipboardProbe" }
}
