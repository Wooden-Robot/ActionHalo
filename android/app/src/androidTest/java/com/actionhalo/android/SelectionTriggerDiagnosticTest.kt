package com.actionhalo.android

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.content.ComponentName
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.actionhalo.android.fixture.SelectionFixtureActivity
import java.util.Collections
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in emulator diagnosis: real long presses, live service, and text-free event metadata. */
@RunWith(AndroidJUnit4::class)
class SelectionTriggerDiagnosticTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var automation: UiAutomation
    private var oldServices: String? = null
    private var oldAccessibility: String? = null
    private var oldAutomatic: Boolean? = null
    private var oldConsent: Boolean? = null
    private var oldStandardMenu: Boolean? = null
    private val events = Collections.synchronizedList(mutableListOf<String>())
    private val selectionSamples = Collections.synchronizedList(mutableListOf<SelectionSample>())
    private var started = false
    private var launchedBrowser = false

    @Before fun configureEmulatorOnly() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("selection_diagnostics") == "true")
        assertDisposableEmulator()
        // The default UiAutomation suppresses other services and invalidates this experiment.
        automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        oldServices = shell("settings get secure enabled_accessibility_services").trim()
        oldAccessibility = shell("settings get secure accessibility_enabled").trim()
        val prefs = instrumentation.targetContext.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
        oldAutomatic = if (prefs.contains("auto_popup_enabled")) prefs.getBoolean("auto_popup_enabled", false) else null
        oldConsent = if (prefs.contains("accessibility_consent")) prefs.getBoolean("accessibility_consent", false) else null
        oldStandardMenu = if (prefs.contains(TelegramCopyPolicy.STANDARD_MENU_SETTING))
            prefs.getBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false) else null
        started = true
        // Instrumentation can restart an enabled service's process; remove its stale binding first.
        setServiceEnabled(false)
        await("The previous service must unbind") { !SelectionAccessibilityService.isConnected() }
        assertTrue(prefs.edit().putBoolean("auto_popup_enabled", true).putBoolean("accessibility_consent", true)
            .putBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false).commit())
        setServiceEnabled(true)
        shell("settings put secure accessibility_enabled 1")
        await("The real accessibility service must bind") { SelectionAccessibilityService.isConnected() }
        automation.serviceInfo = automation.serviceInfo.apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        }
        automation.setOnAccessibilityEventListener { event ->
            if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED ||
                event.eventType == AccessibilityEvent.TYPE_VIEW_LONG_CLICKED ||
                event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED ||
                event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
                val source = event.source
                val refreshed = if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) source?.refresh() else null
                if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED &&
                    event.packageName?.toString() == FIXTURE_PACKAGE) {
                    selectionSamples.add(SelectionSample(event.fromIndex, event.toIndex,
                        source?.textSelectionStart, source?.textSelectionEnd, refreshed == true))
                }
                val metadata = "t=${event.eventType} observedAt=${SystemClock.uptimeMillis()} eventAt=${event.eventTime} pkg=${event.packageName} window=${event.windowId}" +
                    " eventRange=${event.fromIndex}:${event.toIndex} source=${source != null}" +
                    " class=${source?.className} nodeRange=${source?.textSelectionStart}:${source?.textSelectionEnd}" +
                    " nodeId=${source?.hashCode()} result=${SelectionDiagnostics.result}" +
                    " refreshed=$refreshed" +
                    " textLength=${source?.text?.length} visible=${source?.isVisibleToUser}" +
                    " sensitive=${if (Build.VERSION.SDK_INT >= 34) source?.isAccessibilityDataSensitive else false}" +
                    " windows=${windowMetadata()}"
                events.add(metadata)
                Log.i(TAG, metadata)
            }
        }
    }

    @After fun restoreEmulator() {
        if (!started) return
        automation.setOnAccessibilityEventListener(null)
        shell("am force-stop $FIXTURE_PACKAGE")
        if (launchedBrowser) shell("am force-stop mark.via")
        val prefs = instrumentation.targetContext.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (oldAutomatic == null) remove("auto_popup_enabled") else putBoolean("auto_popup_enabled", oldAutomatic!!)
            if (oldConsent == null) remove("accessibility_consent") else putBoolean("accessibility_consent", oldConsent!!)
            if (oldStandardMenu == null) remove(TelegramCopyPolicy.STANDARD_MENU_SETTING)
            else putBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, oldStandardMenu!!)
        }.commit()
        restoreSecure("enabled_accessibility_services", oldServices)
        restoreSecure("accessibility_enabled", oldAccessibility)
    }

    @Test fun editableLongPressAutomaticallyOpensHalo() = diagnose("edit")
    @Test fun readOnlyLongPressAutomaticallyOpensHalo() = diagnose("readonly")
    @Test fun webLongPressAutomaticallyOpensHalo() = diagnose("web", launchCommand =
        "am start -W -n $FIXTURE --es fixture_mode web --ez editable_web true")

    @Test fun initialSelectionStaysQuietAndOnlyAnAdjustedRangeOpensTheHalo() {
        shell("am start -W -S -n $FIXTURE")
        awaitTextNode(FIXTURE_PACKAGE).let(::recycle)
        changeFixtureSelection(0, 9)
        assertNoAutomaticEntryForSettlement()
        val received = SelectionDiagnostics.selectionEvents
        shell("am start -W --activity-single-top -n $FIXTURE --ez repeat_selection_event true")
        await("The duplicate real accessibility event must be delivered") { SelectionDiagnostics.selectionEvents > received }
        assertNoAutomaticEntryForSettlement()
        changeFixtureSelection(0, 18)
        await("Refining the initial range must show its halo") { overlayShown() }
        changeFixtureSelection(1, 1)
        assertNoAutomaticEntryForSettlement()
        changeFixtureSelection(0, 9)
        assertNoAutomaticEntryForSettlement()
        changeFixtureSelection(0, 18)
        await("A new selection session must also wait for adjustment") { overlayShown() }
    }

    @Test fun refiningAnOpenNativeSelectionPreservesItsWindowAndUpdatesTheText() {
        launchSelectedFixture()
        val original = currentNativeHalo() as RadialMenuView
        val originalPosition = IntArray(2)
        instrumentation.runOnMainSync { original.getLocationOnScreen(originalPosition) }
        for (end in listOf(18, 27)) {
            changeFixtureSelection(0, end)
            SystemClock.sleep(500)
            assertTrue("Refining the same selection must reuse its wheel", currentNativeHalo() === original)
            instrumentation.runOnMainSync {
                val position = IntArray(2).also(original::getLocationOnScreen)
                assertEquals(originalPosition.toList(), position.toList())
                assertEquals(SelectionFixtureActivity.SAMPLE_TEXT.substring(0, end), original.selectedText)
            }
        }
        changeFixtureSelection(1, 1)
        assertNoAutomaticEntryForSettlement()
    }

    @Test fun perAppButtonModeLeavesInitialSelectionEditableUntilTheHelperIsTapped() {
        val rules = AppRulesStore(instrumentation.targetContext)
        val previous = rules.profile(FIXTURE_PACKAGE)
        try {
            rules.setProfile(FIXTURE_PACKAGE, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON, listOf("copy")))
            instrumentation.waitForIdleSync()
            shell("am start -W -S -n $FIXTURE")
            // API 26 publishes the text tree before the activity entrance makes it visible.
            await("The fixture must be visible before selecting its initial range") {
                val node = awaitTextNode(FIXTURE_PACKAGE)
                try { node.refresh() && node.isVisibleToUser } finally { recycle(node) }
            }
            changeFixtureSelection(0, 9)
            await("Button mode must offer a helper on the initial selection") { automation.windows.any(::isSelectionHelper) }
            assertNoOverlayForSettlement()
            changeFixtureSelection(0, 18)
            await("Adjusting selection must keep a helper in button mode") { automation.windows.any(::isSelectionHelper) }
            assertNoOverlayForSettlement()
            val helper = checkNotNull(automation.windows.first(::isSelectionHelper).root)
            try { assertTrue(helper.performAction(AccessibilityNodeInfo.ACTION_CLICK)) } finally { recycle(helper) }
            await("Explicit helper tap must open the current selection wheel") { overlayShown() }
            instrumentation.runOnMainSync {
                val field = SelectionAccessibilityService::class.java.getDeclaredField("connectedService").apply { isAccessible = true }
                val service = (field.get(null) as java.lang.ref.WeakReference<*>).get()
                val menu = SelectionAccessibilityService::class.java.getDeclaredField("overlay").apply { isAccessible = true }.get(service) as RadialMenuView
                assertEquals(SelectionFixtureActivity.SAMPLE_TEXT.substring(0, 18), menu.selectedText)
            }
        } finally { rules.setProfile(FIXTURE_PACKAGE, previous) }
    }

    @Test fun perAppOffAndTemporaryPauseSuppressEntryWithoutDisablingTheService() {
        val rules = AppRulesStore(instrumentation.targetContext)
        val previous = rules.profile(FIXTURE_PACKAGE)
        try {
            rules.setProfile(FIXTURE_PACKAGE, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
            instrumentation.waitForIdleSync()
            shell("am start -W -S -n $FIXTURE")
            awaitTextNode(FIXTURE_PACKAGE).let(::recycle)
            changeFixtureSelection(0, 9)
            changeFixtureSelection(0, 18)
            assertNoOverlayForSettlement()
            assertFalse(automation.windows.any(::isSelectionHelper))
            rules.setProfile(FIXTURE_PACKAGE, AppRulesStore.Profile(AppRulesStore.TriggerMode.AUTO))
            assertTrue(instrumentation.targetContext.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
                .edit().putBoolean("auto_popup_enabled", false).commit())
            instrumentation.waitForIdleSync()
            changeFixtureSelection(1, 1)
            changeFixtureSelection(0, 9)
            assertNoOverlayForSettlement()
            changeFixtureSelection(0, 18)
            await("A per-app automatic rule must override the global trigger switch") { overlayShown() }
            rules.pauseFor(AppRulesStore.TEN_MINUTES)
            await("Pause must dismiss the current wheel") { !overlayShown() }
            changeFixtureSelection(0, 20)
            assertNoOverlayForSettlement()
            assertTrue(SelectionAccessibilityService.isConnected())
            rules.resume()
            instrumentation.waitForIdleSync()
            changeFixtureSelection(1, 1)
            changeFixtureSelection(0, 9)
            assertNoOverlayForSettlement()
            changeFixtureSelection(0, 18)
            await("Resume must restore the rule without a service restart") { overlayShown() }
        } finally { rules.resume(); rules.setProfile(FIXTURE_PACKAGE, previous) }
    }

    @Test fun disabledAppsChecklistDismissesCurrentWheelAndBlocksFutureSelectionsUntilRemoved() {
        val context = instrumentation.targetContext
        val preferences = context.getSharedPreferences(AppRulesStore.PREFERENCES, Context.MODE_PRIVATE)
        val previousProfiles = preferences.getString(AppRulesStore.PROFILES, null)
        val rules = AppRulesStore(context)
        try {
            rules.setProfile(FIXTURE_PACKAGE,
                AppRulesStore.Profile(AppRulesStore.TriggerMode.AUTO, listOf("copy")))
            instrumentation.waitForIdleSync()
            launchSelectedFixture()

            rules.setDisabledPackages(rules.disabledPackages() + FIXTURE_PACKAGE)
            await("Disabling the source app must dismiss its current wheel") { !overlayShown() }
            changeFixtureSelection(1, 1)
            changeFixtureSelection(0, 9)
            assertNoAutomaticEntryForSettlement()
            changeFixtureSelection(0, 18)
            assertNoAutomaticEntryForSettlement()
            assertTrue("Disabling one app must keep the service connected", SelectionAccessibilityService.isConnected())

            rules.setDisabledPackages(rules.disabledPackages() - FIXTURE_PACKAGE)
            assertEquals("Removing the app must restore global triggers and preserve its actions",
                AppRulesStore.Profile(AppRulesStore.TriggerMode.DEFAULT, listOf("copy")),
                rules.profile(FIXTURE_PACKAGE))
            instrumentation.waitForIdleSync()
            changeFixtureSelection(1, 1)
            changeFixtureSelection(0, 9)
            assertNoOverlayForSettlement()
            changeFixtureSelection(0, 18)
            await("Removing the app must restore automatic triggering without a service restart") { overlayShown() }
        } finally {
            preferences.edit().apply {
                if (previousProfiles == null) remove(AppRulesStore.PROFILES)
                else putString(AppRulesStore.PROFILES, previousProfiles)
            }.commit()
        }
    }

    @Test fun selectionWindowStaysClearUntilTheFirstActionTapAndThatTapStillExecutes() {
        launchSelectedFixture()
        val menu = currentNativeHalo() as RadialMenuView
        var target: android.view.View? = null
        instrumentation.runOnMainSync {
            val root = menu.parent as android.view.View
            val params = root.layoutParams as android.view.WindowManager.LayoutParams
            assertTrue("The initial selection window must leave the rest of the app touchable", params.width > 0 && params.height > 0)
            assertEquals(0, params.flags and android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            assertEquals(0f, params.dimAmount, 0f)
            assertTrue(root.background == null)
            val copy = ActionStore(menu.context).actions().single { it.id == "copy" }.title
            target = (0 until menu.childCount).map { menu.getChildAt(it) }.single { it.contentDescription == copy }
        }
        val button = checkNotNull(target)
        val origin = IntArray(2)
        instrumentation.runOnMainSync { button.getLocationOnScreen(origin) }
        val x = origin[0] + button.width / 2f
        val y = origin[1] + button.height / 2f
        val firstDraw = java.util.concurrent.atomic.AtomicReference<FloatArray>()
        instrumentation.runOnMainSync {
            val root = menu.parent as android.view.View
            root.viewTreeObserver.addOnPreDrawListener(object : android.view.ViewTreeObserver.OnPreDrawListener {
                override fun onPreDraw(): Boolean {
                    val params = root.layoutParams as android.view.WindowManager.LayoutParams
                    if (params.width == android.view.WindowManager.LayoutParams.MATCH_PARENT) {
                        val point = IntArray(2).also(button::getLocationOnScreen)
                        firstDraw.compareAndSet(null, floatArrayOf(point[0] + button.width * button.scaleX / 2,
                            point[1] + button.height * button.scaleY / 2))
                        root.viewTreeObserver.removeOnPreDrawListener(this)
                    }
                    return true
                }
            })
        }
        val down = SystemClock.uptimeMillis()
        inject(down, down, MotionEvent.ACTION_DOWN, x, y)
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            val root = menu.parent as android.view.View
            val params = root.layoutParams as android.view.WindowManager.LayoutParams
            assertEquals(android.view.WindowManager.LayoutParams.MATCH_PARENT, params.width)
            assertTrue(params.flags and android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND != 0)
            if (menu.gtaModeEnabled) assertTrue(root.background != null)
        }
        await("The first expanded frame must be ready to draw") { firstDraw.get() != null }
        val newOrigin = firstDraw.get()
        assertTrue("The first drawn frame must keep the pressed icon center under the finger: $x,$y -> ${newOrigin.toList()}",
            kotlin.math.abs(x - newOrigin[0]) <= 1 && kotlin.math.abs(y - newOrigin[1]) <= 1)
        inject(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y)
        await("The same first touch must execute Copy and close the halo") { !overlayShown() }
    }

    @Test fun longPressingAnotherWordStartsANewQuietInitialSelection() {
        shell("am start -W -S -n $FIXTURE")
        val source = awaitTextNode(FIXTURE_PACKAGE)
        val bounds = Rect().also(source::getBoundsInScreen)
        try {
            longPress(bounds.left + 64f, bounds.top + 64f)
            assertNoOverlayForSettlement()
            assertTrue(source.refresh())
            val firstStart = source.textSelectionStart
            longPress(bounds.left + 120 * instrumentation.targetContext.resources.displayMetrics.density,
                bounds.top + 64f)
            assertNoOverlayForSettlement()
            assertTrue(source.refresh())
            assertTrue("The second real long press must select another word", source.textSelectionStart != firstStart)
            changeFixtureSelection(0, 18)
            await("Adjusting that new long-press selection must still trigger") { overlayShown() }
        } finally { recycle(source) }
    }

    @Test fun explicitButtonModeSupportsLegacyWebViewWithoutSelectionTextOrRanges() {
        val rules = AppRulesStore(instrumentation.targetContext)
        val previous = rules.profile(FIXTURE_PACKAGE)
        try {
            rules.setProfile(FIXTURE_PACKAGE, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON))
            assertTrue(instrumentation.targetContext.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
                .edit().putBoolean("auto_popup_enabled", false).putBoolean("accessibility_consent", false)
                .putBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, true).commit())
            diagnose("web", standardMenu = true)
        } finally { rules.setProfile(FIXTURE_PACKAGE, previous) }
    }

    @Test fun standardMenuOpensDirectlyWhenWebViewPublishesNoRanges() {
        val rules = AppRulesStore(instrumentation.targetContext)
        val previous = rules.profile(FIXTURE_PACKAGE)
        try {
            rules.setProfile(FIXTURE_PACKAGE, AppRulesStore.Profile())
            assertTrue(instrumentation.targetContext.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
                .edit().putBoolean("auto_popup_enabled", false).putBoolean("accessibility_consent", false)
                .putBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, true).commit())
            diagnose("web", standardMenu = true, buttonMode = false)
        } finally { rules.setProfile(FIXTURE_PACKAGE, previous) }
    }

    @Test fun disabledAppsChecklistAlsoSuppressesStandardMenuHelpers() {
        val context = instrumentation.targetContext
        val preferences = context.getSharedPreferences(AppRulesStore.PREFERENCES, Context.MODE_PRIVATE)
        val previousProfiles = preferences.getString(AppRulesStore.PROFILES, null)
        val rules = AppRulesStore(context)
        fun selectWebFixture() {
            shell("am force-stop $FIXTURE_PACKAGE")
            shell("am start -W -n $FIXTURE --es fixture_mode web")
            SystemClock.sleep(800)
            val node = awaitTextNode(FIXTURE_PACKAGE)
            try {
                val bounds = Rect().also(node::getBoundsInScreen)
                longPress(bounds.left + 45f,
                    bounds.top + 20f * context.resources.displayMetrics.density)
            } finally { recycle(node) }
        }
        try {
            rules.setProfile(FIXTURE_PACKAGE, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON))
            assertTrue(context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
                .edit().putBoolean("auto_popup_enabled", false).putBoolean("accessibility_consent", false)
                .putBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, true).commit())
            selectWebFixture()
            await("The standard selection menu must first offer its helper") {
                automation.windows.any(::isSelectionHelper)
            }
            rules.setDisabledPackages(rules.disabledPackages() + FIXTURE_PACKAGE)
            await("Disabling the app must dismiss its existing standard-menu helper") {
                automation.windows.none(::isSelectionHelper)
            }
            selectWebFixture()
            assertNoAutomaticEntryForSettlement()
            rules.setDisabledPackages(rules.disabledPackages() - FIXTURE_PACKAGE)
            selectWebFixture()
            await("Restoring default mode must restore the direct menu-only wheel") { overlayShown() }
            assertFalse(automation.windows.any(::isSelectionHelper))
            rules.setProfile(FIXTURE_PACKAGE, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON))
            selectWebFixture()
            await("Explicitly restoring button mode must show its standard-menu helper") {
                automation.windows.any(::isSelectionHelper)
            }
        } finally {
            preferences.edit().apply {
                if (previousProfiles == null) remove(AppRulesStore.PROFILES)
                else putString(AppRulesStore.PROFILES, previousProfiles)
            }.commit()
        }
    }

    @Test fun keyboardAppearancePreservesSelectionAndTheHaloCopiesTheExactText() {
        launchSelectedFixture()
        val haloId = automation.windows.first { it.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY }.id
        val oldKeyboard = shell("settings get secure show_ime_with_hard_keyboard").trim()
        try {
            restoreSecure("show_ime_with_hard_keyboard", "1")
            shell("am start -W --activity-single-top -n $FIXTURE --ez show_keyboard true")
            await("A real input-method window must appear") {
                automation.windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            }
            assertTrue("Showing the keyboard must preserve the same selection halo",
                automation.windows.any { it.id == haloId })
            assertFreshNodeRange(0, SelectionFixtureActivity.SAMPLE_TEXT.length)
            val copyTitle = ActionStore(HaloUi.localizedContext(instrumentation.targetContext)).actions().single { it.id == "copy" }.title
            val root = checkNotNull(automation.windows.first { it.id == haloId }.root)
            try {
                val matches = root.findAccessibilityNodeInfosByText(copyTitle)
                try {
                    assertTrue("Copy must work through the real halo while the keyboard is open",
                        matches.any { it.isClickable && it.performAction(AccessibilityNodeInfo.ACTION_CLICK) })
                } finally { matches.forEach(::recycle) }
            } finally { recycle(root) }
            await("Copy must close the halo") { !overlayShown() }
            val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            try {
                await("The clipboard verifier must have real window focus") { activity.hasWindowFocus() }
                instrumentation.runOnMainSync {
                    val clip = activity.getSystemService(ClipboardManager::class.java).primaryClip
                    assertEquals(SelectionFixtureActivity.SAMPLE_TEXT, clip?.getItemAt(0)?.text?.toString())
                    assertEquals("ActionHalo", clip?.description?.label?.toString())
                }
            } finally { instrumentation.runOnMainSync { activity.finish() } }
        } finally { restoreSecure("show_ime_with_hard_keyboard", oldKeyboard) }
    }

    @Test fun screenOffClearsTheOldHaloAndNewSelectionWorksAfterWake() {
        launchSelectedFixture()
        val power = instrumentation.targetContext.getSystemService(PowerManager::class.java)
        val halo = currentNativeHalo()
        try {
            shell("input keyevent 223") // KEYCODE_SLEEP, never toggle an unknown power state.
            await("The emulator must really turn its screen off") { !power.isInteractive }
            await("Screen off must detach the actual old halo window") {
                var attached = true
                instrumentation.runOnMainSync {
                    attached = halo.isAttachedToWindow
                }
                !attached
            }
        } finally {
            shell("input keyevent 224")
            shell("wm dismiss-keyguard")
        }
        await("The emulator must wake and keep its accessibility connection") {
            power.isInteractive && SelectionAccessibilityService.isConnected()
        }
        assertNoOverlayForSettlement()
        changeFixtureSelection(1, 1)
        changeFixtureSelection(0, 9)
        assertNoOverlayForSettlement()
        changeFixtureSelection(0, SelectionFixtureActivity.SAMPLE_TEXT.length)
        await("A fresh selection after wake must display a new halo") { overlayShown() }
    }

    @Test fun serviceDisconnectClearsTheHaloAndReconnectionHandlesNewSelection() {
        launchSelectedFixture()
        setServiceEnabled(false)
        await("The real service must disconnect and remove its window") {
            !SelectionAccessibilityService.isConnected() && !overlayShown()
        }
        changeFixtureSelection(1, 1)
        changeFixtureSelection(0, 9)
        assertNoOverlayForSettlement()
        changeFixtureSelection(0, SelectionFixtureActivity.SAMPLE_TEXT.length)
        assertNoOverlayForSettlement()
        setServiceEnabled(true)
        shell("settings put secure accessibility_enabled 1")
        await("The real service must reconnect") { SelectionAccessibilityService.isConnected() }
        changeFixtureSelection(1, 1)
        changeFixtureSelection(0, 9)
        assertNoOverlayForSettlement()
        changeFixtureSelection(0, SelectionFixtureActivity.SAMPLE_TEXT.length)
        await("A new selection after reconnection must display its halo") { overlayShown() }
    }
    @Test fun nativeSelectionOpensWebTranslationAndClosesTheHalo() {
        val launches = java.util.concurrent.CopyOnWriteArrayList<Intent>()
        val monitor = object : android.app.Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): android.app.Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_VIEW) return null
                launches.add(Intent(intent))
                return android.app.Instrumentation.ActivityResult(android.app.Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            launchSelectedFixture()
            val halo = currentNativeHalo() as RadialMenuView
            instrumentation.runOnMainSync {
                halo.onActionSelected?.invoke(ActionStore(halo.context).actions().single { it.id == "translate" })
            }
            await("The translation website must launch and the halo must close") { launches.size == 1 && !overlayShown() }
            val launched = launches.single()
            assertEquals("translate.google.com", launched.data?.host)
            assertEquals(SelectionFixtureActivity.SAMPLE_TEXT, launched.data?.getQueryParameter("text"))
            assertEquals("auto", launched.data?.getQueryParameter("sl"))
            assertTrue(launched.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
            assertTrue(launched.component == null)
        } finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun viaLongPressAutomaticallyOpensHalo() {
        val url = InstrumentationRegistry.getArguments().getString("diagnostic_browser_url")
        assumeTrue(url == "http://127.0.0.1:8800/fixture.html")
        launchedBrowser = true
        diagnose("via", "mark.via", "am start -W -a android.intent.action.VIEW -d $url -p mark.via")
    }

    @Test fun freshNonemptySourceSurvivesDelayedCollapsedEvent() {
        launchRangeRace("stale_collapsed")
        awaitRangeMismatch(1, 1, 0, 9)
        assertFreshNodeRange(0, 9)
        assertNoOverlayForSettlement()
        changeFixtureSelection(0, 18)
        val deadline = SystemClock.uptimeMillis() + 2_000
        while (SystemClock.uptimeMillis() < deadline && !overlayShown()) SystemClock.sleep(40)
        assertTrue("A fresh nonempty 0:9 source must survive a delayed 1:1 event. ${eventSummary()}", overlayShown())
    }

    @Test fun freshCollapsedSourceRejectsDelayedNonemptyEvent() {
        launchRangeRace("stale_nonempty")
        awaitRangeMismatch(0, 9, 1, 1)
        assertFreshNodeRange(1, 1)
        // Wait beyond the debounce interval so a rejected stale event cannot reopen the halo.
        val deadline = SystemClock.uptimeMillis() + 800
        while (SystemClock.uptimeMillis() < deadline) {
            assertFalse("A fresh collapsed 1:1 source must reject a delayed 0:9 event. ${eventSummary()}", overlayShown())
            SystemClock.sleep(40)
        }
    }

    private fun launchRangeRace(race: String) {
        events.clear()
        selectionSamples.clear()
        shell("am force-stop $FIXTURE_PACKAGE")
        instrumentation.runOnMainSync { SelectionDiagnostics.reset() }
        shell("am start -W -n $FIXTURE_PACKAGE/com.actionhalo.android.fixture.SelectionFixtureActivity --es range_race $race")
    }

    private fun awaitRangeMismatch(eventStart: Int, eventEnd: Int, nodeStart: Int, nodeEnd: Int) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (synchronized(selectionSamples) { selectionSamples.any {
                it.eventStart == eventStart && it.eventEnd == eventEnd &&
                    it.nodeStart == nodeStart && it.nodeEnd == nodeEnd && it.refreshed
            } }) return
            SystemClock.sleep(40)
        }
        throw AssertionError("The controlled event/node range mismatch was not observed. ${eventSummary()}")
    }

    private fun assertFreshNodeRange(start: Int, end: Int) {
        val node = awaitTextNode(FIXTURE_PACKAGE)
        try {
            assertTrue("The selection source must still refresh", node.refresh())
            assertEquals(start, node.textSelectionStart)
            assertEquals(end, node.textSelectionEnd)
        } finally { recycle(node) }
    }

    private fun launchSelectedFixture() {
        shell("am start -W -S -n $FIXTURE")
        SystemClock.sleep(800) // Older systems publish nodes before the activity entrance finishes.
        awaitTextNode(FIXTURE_PACKAGE).let(::recycle)
        changeFixtureSelection(1, 1)
        instrumentation.settleInput()
        changeFixtureSelection(0, 9)
        assertNoOverlayForSettlement()
        changeFixtureSelection(0, SelectionFixtureActivity.SAMPLE_TEXT.length)
        try {
            await("The foreign fixture's real selection must show a halo") { overlayShown() }
        } catch (failure: AssertionError) {
            throw AssertionError("${failure.message}; result=${SelectionDiagnostics.result}, events=${SelectionDiagnostics.selectionEvents}, eventRange=${SelectionDiagnostics.eventRange}, nodeRange=${SelectionDiagnostics.nodeRange}", failure)
        }
        assertFreshNodeRange(0, SelectionFixtureActivity.SAMPLE_TEXT.length)
    }

    private fun currentNativeHalo(): android.view.View {
        var halo: android.view.View? = null
        instrumentation.runOnMainSync {
            val field = SelectionAccessibilityService::class.java.getDeclaredField("connectedService").apply { isAccessible = true }
            val service = (field.get(null) as java.lang.ref.WeakReference<*>).get()
            halo = SelectionAccessibilityService::class.java.getDeclaredField("overlay").apply { isAccessible = true }
                .get(service) as android.view.View
        }
        return checkNotNull(halo)
    }

    private fun changeFixtureSelection(start: Int, end: Int) {
        val node = awaitTextNode(FIXTURE_PACKAGE)
        try {
            assertTrue(node.refresh())
            assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
            }))
        } finally { recycle(node) }
        await("The real source selection must change") {
            val updated = awaitTextNode(FIXTURE_PACKAGE)
            try { updated.textSelectionStart == start && updated.textSelectionEnd == end }
            finally { recycle(updated) }
        }
    }

    private fun assertNoOverlayForSettlement() {
        val deadline = SystemClock.uptimeMillis() + 800
        while (SystemClock.uptimeMillis() < deadline) {
            assertFalse("An old selection must not reopen a cancelled halo", overlayShown())
            SystemClock.sleep(40)
        }
    }

    private fun assertNoAutomaticEntryForSettlement() {
        val deadline = SystemClock.uptimeMillis() + 800
        while (SystemClock.uptimeMillis() < deadline) {
            assertFalse("This selection must not show a wheel", overlayShown())
            assertFalse("This selection must not show a helper button", automation.windows.any(::isSelectionHelper))
            SystemClock.sleep(40)
        }
    }

    private fun setServiceEnabled(enabled: Boolean) {
        val component = ComponentName(instrumentation.targetContext, SelectionAccessibilityService::class.java)
        val others = shell("settings get secure enabled_accessibility_services").trim().split(':')
            .filter { it.isNotBlank() && it != "null" && ComponentName.unflattenFromString(it) != component }
        restoreSecure("enabled_accessibility_services", (others + if (enabled) listOf(component.flattenToString()) else emptyList()).joinToString(":"))
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

    private fun overlayShown(): Boolean = automation.windows.any { window ->
        if (window.type != AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) return@any false
        if (isSelectionHelper(window)) return@any false
        // The framework can retain a rootless window entry after the actual view was removed.
        val root = window.root ?: return@any false
        try { root.packageName?.toString() == instrumentation.targetContext.packageName }
        finally { recycle(root) }
    }

    private fun isSelectionHelper(window: AccessibilityWindowInfo): Boolean {
        if (window.title?.toString() == "ActionHalo selection helper") return true
        if (window.type != AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) return false
        // API 26 can omit an overlay's window title; identify our single-button root instead.
        val root = window.root ?: return false
        return try { root.packageName?.toString() == instrumentation.targetContext.packageName &&
            root.className?.toString() == "android.widget.Button" &&
            (root.text?.toString() == instrumentation.targetContext.getString(R.string.selection_open_halo) ||
                root.contentDescription?.toString() == instrumentation.targetContext.getString(R.string.selection_open_halo)) }
        finally { recycle(root) }
    }

    private fun eventSummary(): String = synchronized(events) { events.joinToString(" | ") }

    private data class SelectionSample(
        val eventStart: Int, val eventEnd: Int,
        val nodeStart: Int?, val nodeEnd: Int?, val refreshed: Boolean,
    )

    private fun diagnose(mode: String, hostPackage: String = FIXTURE_PACKAGE, launchCommand: String? = null,
        standardMenu: Boolean = false, buttonMode: Boolean = true) {
        events.clear()
        shell("am force-stop $FIXTURE_PACKAGE")
        shell(launchCommand ?: "am start -W -n $FIXTURE_PACKAGE/com.actionhalo.android.fixture.SelectionFixtureActivity --es fixture_mode $mode")
        SystemClock.sleep(800) // Wait for the activity's entrance animation before reading screen bounds.
        val node = awaitTextNode(hostPackage)
        if (mode == "web" && !standardMenu) {
            assertTrue("The editable WebView fixture must expose its selection text",
                node.text != null)
        }
        var expectedSelection: String? = null
        val bounds = Rect().also(node::getBoundsInScreen)
        // Select the first rendered word, keeping the coordinates independent of toolbar labels.
        val browser = mode == "web" || mode == "via"
        val x = if (browser) bounds.left + 45f else bounds.left + 64f
        val y = if (browser) bounds.top + 20f * instrumentation.targetContext.resources.displayMetrics.density else bounds.top + 64f
        Log.i(TAG, "mode=$mode longPress bounds=$bounds point=$x,$y before=${windowMetadata()}")
        longPress(x, y)
        if (!standardMenu || buttonMode) assertNoOverlayForSettlement()
        if (standardMenu && !buttonMode) {
            await("A WebView menu without ranges must directly display the circle") { overlayShown() }
            assertFalse(automation.windows.any(::isSelectionHelper))
        } else if (standardMenu) {
            await("The initial unsupported selection must offer its manual helper") {
                automation.windows.any(::isSelectionHelper)
            }
            val helper = checkNotNull(automation.windows.first(::isSelectionHelper).root)
            try {
                val buttons = helper.findAccessibilityNodeInfosByText(instrumentation.targetContext.getString(R.string.selection_open_halo))
                try { assertTrue(buttons.any { it.isClickable && it.performAction(AccessibilityNodeInfo.ACTION_CLICK) }) }
                finally { buttons.forEach(::recycle) }
            } finally { recycle(helper) }
        } else {
            assertTrue(node.refresh())
            val eventRange = synchronized(selectionSamples) {
                selectionSamples.lastOrNull { it.eventStart >= 0 && it.eventEnd > it.eventStart }
            }
            val start = if (node.textSelectionStart >= 0) node.textSelectionStart else eventRange?.eventStart ?: -1
            val end = if (node.textSelectionEnd >= 0) node.textSelectionEnd else eventRange?.eventEnd ?: -1
            val length = checkNotNull(node.text).length
            assertTrue("The long press must expose its actual initial range", start >= 0 && end > start)
            if (mode == "web") assertEquals("Selection", node.text!!.subSequence(start, end).toString())
            val newStart = if (end == length) start + 1 else start
            val newEnd = (end + 1).coerceAtMost(length)
            Log.i(TAG, "mode=$mode refine=$newStart:$newEnd actions=${node.actionList.map { it.id }}")
            if (node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_SELECTION }) {
                if (mode == "web") expectedSelection = node.text!!.subSequence(newStart, newEnd).toString()
                assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newStart)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newEnd)
                }))
            } else {
                // Chromium exposes ranges in events; drag its actual right-hand popup handle.
                val density = instrumentation.targetContext.resources.displayMetrics.density
                val handles = automation.windows.mapNotNull { window ->
                    if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) return@mapNotNull null
                    val parent = window.parent ?: return@mapNotNull null
                    val sameHost = try { parent.id == node.windowId } finally {
                        @Suppress("DEPRECATION")
                        if (Build.VERSION.SDK_INT < 33) parent.recycle()
                    }
                    val rect = Rect().also(window::getBoundsInScreen)
                    if (sameHost && rect.width() in 1..(64 * density).toInt() &&
                        rect.height() in 1..(64 * density).toInt()) rect else null
                }
                Log.i(TAG, "mode=$mode selectionHandleWindows=$handles")
                val handle = checkNotNull(handles.maxByOrNull { it.centerX() })
                val x = handle.exactCenterX()
                // The floating toolbar may overlap the handle's lower portion.
                val y = handle.top + minOf(handle.height() / 4f, 4 * density)
                val shift = 96 * density
                val down = SystemClock.uptimeMillis()
                inject(down, down, MotionEvent.ACTION_DOWN, x, y)
                for (step in 1..16) {
                    SystemClock.sleep(40)
                    inject(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_MOVE, x + shift * step / 16, y)
                }
                inject(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x + shift, y)
            }
        }
        recycle(node)
        val deadline = SystemClock.uptimeMillis() + 4_000
        var overlay = false
        while (SystemClock.uptimeMillis() < deadline) {
            overlay = overlayShown()
            if (overlay) break
            SystemClock.sleep(40)
        }
        Log.i(TAG, "mode=$mode overlay=$overlay final=${windowMetadata()}")
        automation.takeScreenshot()?.let { bitmap ->
            java.io.FileOutputStream(java.io.File(instrumentation.targetContext.cacheDir, "trigger-$mode.png")).use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }
        assertTrue("$mode adjusted or explicitly requested selection must display its halo. " +
            "Observed metadata: ${synchronized(events) { events.joinToString(" | ") }}", overlay)
        if (expectedSelection != null) {
            val menu = currentNativeHalo() as RadialMenuView
            await("The halo must contain the expanded selection") {
                var selected: String? = null
                instrumentation.runOnMainSync { selected = menu.selectedText }
                selected == expectedSelection
            }
        }
    }

    private fun awaitTextNode(hostPackage: String): AccessibilityNodeInfo {
        // A newly installed browser may initialize its Chromium accessibility tree after rendering.
        val deadline = SystemClock.uptimeMillis() + if (hostPackage == "mark.via") 10_000 else 4_000
        while (SystemClock.uptimeMillis() < deadline) {
            val node = automation.windows.asSequence().mapNotNull { it.root }
                .flatMap { descendants(it) }.firstOrNull {
                    it.packageName?.toString() == hostPackage &&
                        (it.text?.toString()?.startsWith("Selection fixture:") == true ||
                            it.contentDescription?.toString()?.startsWith("Selection fixture:") == true)
                }
            if (node != null) return node
            SystemClock.sleep(80)
        }
        automation.takeScreenshot()?.let { bitmap ->
            java.io.FileOutputStream(java.io.File(instrumentation.targetContext.cacheDir, "missing-fixture-node.png")).use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }
        val nodes = automation.windows.asSequence().mapNotNull { it.root }.flatMap { descendants(it) }
            .filter { it.packageName?.toString() == hostPackage }
            .joinToString(",") { "${it.className}/textLength=${it.text?.length}/children=${it.childCount}" }
        throw AssertionError("Fixture text node was not exposed; windows=${windowMetadata()}; nodes=$nodes")
    }

    private fun descendants(node: AccessibilityNodeInfo): Sequence<AccessibilityNodeInfo> = sequence {
        yield(node)
        for (index in 0 until node.childCount) node.getChild(index)?.let { yieldAll(descendants(it)) }
    }

    private fun longPress(x: Float, y: Float) {
        val down = SystemClock.uptimeMillis()
        inject(down, down, MotionEvent.ACTION_DOWN, x, y)
        SystemClock.sleep(900)
        inject(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y)
    }

    private fun inject(down: Long, time: Long, action: Int, x: Float, y: Float) {
        val event = MotionEvent.obtain(down, time, action, x, y, 0).apply {
            source = InputDevice.SOURCE_TOUCHSCREEN
        }
        try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
    }

    private fun windowMetadata(): String = automation.windows.joinToString(",") {
        "${it.id}/${it.type}/title=${it.title}/active=${it.isActive}/focus=${it.isFocused}/pkg=${it.root?.packageName}"
    }

    private fun restoreSecure(key: String, value: String?) {
        if (value == null || value == "null" || value.isEmpty()) shell("settings delete secure $key")
        else {
            // UiAutomation executes the command directly; shell quotes become literal data.
            require(value.matches(Regex("[A-Za-z0-9_./:$]+"))) { "Unexpected secure-setting token" }
            shell("settings put secure $key $value")
        }
    }

    private fun shell(command: String): String = automation.executeShellCommand(command).use {
        java.io.FileInputStream(it.fileDescriptor).bufferedReader().use { reader -> reader.readText() }
    }

    companion object {
        private const val TAG = "ActionHaloTriggerProbe"
        private const val FIXTURE_PACKAGE = "com.actionhalo.android.test"
        private const val FIXTURE = "$FIXTURE_PACKAGE/com.actionhalo.android.fixture.SelectionFixtureActivity"
    }
}
