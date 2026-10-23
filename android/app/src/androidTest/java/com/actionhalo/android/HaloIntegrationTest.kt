package com.actionhalo.android

import android.app.Activity
import android.app.UiAutomation
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real device checks for text entry, touch dispatch, clipboard, and persisted action settings. */
@RunWith(AndroidJUnit4::class)
class HaloIntegrationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    @Before fun resetActions() {
        assertTrue(context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE).edit().clear().commit())
    }

    @After fun clearActions() {
        assertTrue(context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE).edit().clear().commit())
    }

    @Test fun processTextAndShareOpenWebTranslationWithTheExactSelection() {
        val selected = "你好 🌍 café &text=other#fragment + %2F"
        val launches = CopyOnWriteArrayList<Intent>()
        val monitor = object : android.app.Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): android.app.Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_VIEW) return null
                launches.add(Intent(intent))
                return android.app.Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            for (entry in listOf(Intent.ACTION_PROCESS_TEXT, Intent.ACTION_SEND)) {
                val incoming = Intent(context, HaloActivity::class.java).apply {
                    action = entry
                    type = "text/plain"
                    putExtra(if (entry == Intent.ACTION_PROCESS_TEXT) Intent.EXTRA_PROCESS_TEXT else Intent.EXTRA_TEXT, selected)
                }
                ActivityScenario.launch<HaloActivity>(incoming).use { scenario ->
                    scenario.onActivity { activity ->
                        val halo = descendants(activity.window.decorView).filterIsInstance<RadialMenuView>().single()
                        halo.onActionSelected?.invoke(ActionStore(activity).actions().single { it.id == "translate" })
                    }
                }
            }
            assertEquals(2, launches.size)
            launches.forEach {
                assertEquals("translate.google.com", it.data?.host)
                assertEquals(selected, it.data?.getQueryParameter("text"))
                assertEquals("auto", it.data?.getQueryParameter("sl"))
                assertEquals(context.getString(R.string.action_translation_target), it.data?.getQueryParameter("tl"))
                assertTrue(it.component == null)
            }
        } finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun processTextAndSharePreserveUnicodeAndCopyThroughTheRadialMenu() {
        val selected = "你好 🌍 café & こんにちは"
        // Keep our app focused after HaloActivity finishes, so Android permits reading the clip.
        ActivityScenario.launch(MainActivity::class.java).use { main ->
            val mainActivity = AtomicReference<Activity>()
            main.onActivity { mainActivity.set(it) }
            for (action in listOf(Intent.ACTION_PROCESS_TEXT, Intent.ACTION_SEND)) {
                main.onActivity { activity ->
                    activity.getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("Fixture marker", "Before $action"))
                }
                val incoming = Intent(context, HaloActivity::class.java).apply {
                    this.action = action
                    type = "text/plain"
                    putExtra(if (action == Intent.ACTION_PROCESS_TEXT) Intent.EXTRA_PROCESS_TEXT else Intent.EXTRA_TEXT, selected)
                    if (action == Intent.ACTION_PROCESS_TEXT) putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
                }
                // ActivityScenario adds CLEAR_TASK, so use startActivitySync to preserve MainActivity below Halo.
                val halo = instrumentation.startActivitySync(incoming.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as HaloActivity
                try {
                    awaitWindowFocus(halo)
                    val position = AtomicReference<TouchPosition>()
                    instrumentation.runOnMainSync {
                        val menu = descendants(halo.window.decorView).filterIsInstance<RadialMenuView>().single()
                        assertEquals(selected, menu.selectedText)
                        assertTrue(descendants(menu).filterIsInstance<Button>().any {
                            it.contentDescription?.toString()?.contains(selected) == true
                        })
                        position.set(touchPosition(menu, ActionStore(halo).actions().first().title))
                    }
                    val point = position.get()
                    touchGesture(point.topX, point.topY, point.topX, point.topY)
                    awaitWindowFocus(mainActivity.get())
                    main.onActivity { activity ->
                        val clipboard = activity.getSystemService(ClipboardManager::class.java)
                        assertEquals(selected, clipboard.primaryClip?.getItemAt(0)?.text?.toString())
                    }
                } finally {
                    instrumentation.runOnMainSync { halo.finish() }
                    instrumentation.waitForIdleSync()
                }
            }
        }
    }

    @Test fun deniedClipboardWriteKeepsTheWheelOpenAndAnExplicitRetryCopiesTheSelection() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("focused_clipboard_overlay") == "true")
        assertDisposableEmulator()
        val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        fun shell(command: String) = automation.executeShellCommand(command).use {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().use { reader -> reader.readText() }
        }
        val operation = "WRITE_CLIPBOARD"
        val originalMode = Regex("(?:$operation: |Default mode: )(\\w+)")
            .find(shell("cmd appops get ${context.packageName} $operation"))?.groupValues?.get(1)
            ?: error("The original clipboard write mode must be known before changing it")
        val settings = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        val oldKeep = settings.all[HaloAppearance.KEEP_AFTER_COPY_KEY]
        assertTrue(settings.edit().putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, false).commit())
        val selected = "New copied selection 你好 🌍"
        val previous = "Previous clipboard fixture"
        try {
            ActivityScenario.launch(MainActivity::class.java).use { main ->
                val host = AtomicReference<Activity>()
                main.onActivity { activity ->
                    host.set(activity)
                    activity.getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("Fixture marker", previous))
                }
                val incoming = Intent(context, HaloActivity::class.java).apply {
                    action = Intent.ACTION_SEND
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, selected)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                val halo = instrumentation.startActivitySync(incoming) as HaloActivity
                try {
                    awaitWindowFocus(halo)
                    shell("cmd appops set ${context.packageName} $operation ignore")
                    val position = AtomicReference<TouchPosition>()
                    instrumentation.runOnMainSync {
                        val menu = descendants(halo.window.decorView).filterIsInstance<RadialMenuView>().single()
                        position.set(touchPosition(menu, ActionStore(halo).actions().single { it.id == "copy" }.title))
                    }
                    val point = position.get()
                    touchGesture(point.topX, point.topY, point.topX, point.topY)
                    instrumentation.runOnMainSync {
                        assertEquals("The system must reject the write without replacing the previous clip", previous,
                            host.get().getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString())
                        assertFalse("An unconfirmed copy must keep the wheel available for retry", halo.isFinishing)
                        val menu = descendants(halo.window.decorView).filterIsInstance<RadialMenuView>().single()
                        assertEquals(selected, menu.selectedText)
                    }
                    shell("cmd appops set ${context.packageName} $operation allow")
                    touchGesture(point.topX, point.topY, point.topX, point.topY)
                    awaitWindowFocus(host.get())
                    main.onActivity { activity ->
                        assertEquals(selected, activity.getSystemService(ClipboardManager::class.java)
                            .primaryClip?.getItemAt(0)?.text?.toString())
                    }
                } finally {
                    instrumentation.runOnMainSync { halo.finish() }
                    instrumentation.waitForIdleSync()
                }
            }
        } finally {
            shell("cmd appops set ${context.packageName} $operation $originalMode")
            settings.edit().apply {
                if (oldKeep is Boolean) putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, oldKeep)
                else remove(HaloAppearance.KEEP_AFTER_COPY_KEY)
            }.commit()
        }
    }

    @Test fun dragReleaseExecutesOnceWhileCancellationAndDeadzoneDoNotExecute() {
        val executions = AtomicInteger()
        val dismissals = AtomicInteger()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val menuReference = AtomicReference<RadialMenuView>()
            val activityReference = AtomicReference<Activity>()
            scenario.onActivity { activity ->
                activityReference.set(activity)
                val menu = RadialMenuView(activity).apply {
                    selectedText = "Gesture fixture"
                    setActions(listOf(
                        HaloAction("fixture-copy", "Copy fixture", "⧉", ActionType.COPY),
                        HaloAction("fixture-second", "Second fixture", "2", ActionType.COPY),
                        HaloAction("fixture-third", "Third fixture", "3", ActionType.COPY),
                    ))
                    onActionSelected = { executions.incrementAndGet() }
                    onDismiss = { dismissals.incrementAndGet() }
                }
                val surface = FrameLayout(activity)
                val size = (320 * activity.resources.displayMetrics.density).toInt()
                surface.addView(menu, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
                activity.setContentView(surface)
                menuReference.set(menu)
            }
            awaitWindowFocus(activityReference.get())
            val position = AtomicReference<TouchPosition>()
            scenario.onActivity { position.set(touchPosition(menuReference.get(), "Copy fixture")) }
            val point = position.get()

            touchGesture(point.centerX, point.centerY, point.topX, point.topY)
            assertEquals(1, executions.get())
            touchGesture(point.centerX, point.centerY, point.topX, point.topY, cancel = true)
            assertEquals(1, executions.get())
            assertEquals(0, dismissals.get())
            touchGesture(point.centerX, point.centerY, point.centerX, point.centerY)
            assertEquals(1, executions.get())
            assertEquals(1, dismissals.get())
            touchGesture(point.centerX, point.centerY, point.cornerX, point.cornerY)
            assertEquals(1, executions.get())
            assertEquals("Releasing beyond the selection limit must dismiss without another action", 2, dismissals.get())
        }
    }

    @Test fun mainScreenLaunchesWithAnEditableExampleAndAnActionMenuEntry() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                val views = descendants(activity.window.decorView)
                val editor = views.filterIsInstance<EditText>().single {
                    it.contentDescription?.toString() == activity.getString(R.string.sample_hint)
                }
                assertTrue(editor.isEnabled)
                assertFalse(editor.text.isNullOrBlank())
                assertTrue(views.filterIsInstance<Button>().any {
                    it.text.toString() == activity.getString(R.string.show_halo) && it.isEnabled
                })
                assertTrue(activity.window.decorView.width > 0)
            }
        }
    }

    @Test fun additionalCustomActionsPersistWithoutDisplacingEnabledActions() {
        val store = ActionStore(context)
        val originalCount = store.actions().size
        val first = store.addCustom("  Fixture dictionary  ", "https://example.com/lookup?q={text}")
        val overflow = store.addCustom("Fixture overflow", "https://example.com/search?q={text}")
        assertEquals(7, originalCount)
        assertEquals(9, ActionStore(context).actions().size)
        assertEquals("Fixture dictionary", ActionStore(context).allActions().single { it.id == first.id }.title)
        assertEquals(first.template, ActionStore(context).allActions().single { it.id == first.id }.template)
        assertTrue(ActionStore(context).isEnabled(first.id))
        assertTrue(ActionStore(context).isEnabled(overflow.id))
        assertEquals(listOf(first.id, overflow.id), ActionStore(context).actions().takeLast(2).map { it.id })
        store.setEnabled(first.id, false)
        assertFalse(ActionStore(context).isEnabled(first.id))
        store.setEnabled(overflow.id, true)
        assertTrue(ActionStore(context).isEnabled(overflow.id))
        assertEquals(8, ActionStore(context).actions().size)
        assertTrue(store.deleteCustom(overflow.id))
        assertFalse(ActionStore(context).allActions().any { it.id == overflow.id })
        assertEquals(7, ActionStore(context).actions().size)
        assertFalse(store.deleteCustom("copy"))
        assertNotNull(ActionStore(context).allActions().find { it.id == "copy" })
    }

    @Test fun addingDoubanOnUpgradeDoesNotDisplaceExistingEnabledActions() {
        val store = ActionStore(context)
        store.setEnabled("douban", false)
        val first = store.addCustom("Existing first", "https://example.com/first?q={text}")
        val second = store.addCustom("Existing second", "https://example.com/second?q={text}")
        assertEquals(8, store.actions().size)
        // A pre-Douban version has no preference for the newly added built-in.
        assertTrue(context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE)
            .edit().remove("enabled_douban").commit())

        val upgraded = ActionStore(context)
        assertFalse(upgraded.isEnabled("douban"))
        assertTrue(upgraded.isEnabled(first.id))
        assertTrue(upgraded.isEnabled(second.id))
        assertEquals(8, upgraded.actions().size)
    }

    @Test fun newSearchActionsStayOptionalAndKeepExistingPreferences() {
        val original = ActionStore(context)
        original.setEnabled("google", false)
        val custom = original.addCustom("Existing website", "https://example.com/?q={text}")
        val previous = original.actions().map { it.id }
        val reloaded = ActionStore(context)
        val additions = listOf("douban_book", "douban_movie", "neodb", "neodb_book", "github", "telegram")
        additions.forEach { assertFalse(reloaded.isEnabled(it)) }
        assertEquals(previous, reloaded.actions().map { it.id })
        additions.forEach { reloaded.setEnabled(it, true) }
        assertEquals(previous.size + additions.size, ActionStore(context).actions().size)
        assertFalse(ActionStore(context).isEnabled("google"))
        assertTrue(ActionStore(context).isEnabled(custom.id))
        assertTrue(ActionStore(context).actions().map { it.id }.containsAll(additions))
    }

    private fun touchPosition(menu: RadialMenuView, firstActionTitle: String): TouchPosition {
        assertTrue("The radial menu must be laid out before injecting a gesture", menu.width > 0 && menu.height > 0)
        val location = IntArray(2)
        menu.getLocationOnScreen(location)
        val firstAction = descendants(menu).filterIsInstance<Button>().single {
            it.contentDescription?.toString() == firstActionTitle
        }
        val actionLocation = IntArray(2)
        firstAction.getLocationOnScreen(actionLocation)
        return TouchPosition(
            location[0] + menu.width / 2f,
            location[1] + menu.height / 2f,
            actionLocation[0] + firstAction.width / 2f,
            actionLocation[1] + firstAction.height / 2f,
            location[0] + menu.width * 0.02f,
            location[1] + menu.height * 0.02f,
        )
    }

    private fun touchGesture(startX: Float, startY: Float, endX: Float, endY: Float, cancel: Boolean = false) {
        val downTime = SystemClock.uptimeMillis()
        fun send(action: Int, x: Float, y: Float) {
            val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
        }
        send(MotionEvent.ACTION_DOWN, startX, startY)
        send(MotionEvent.ACTION_MOVE, endX, endY)
        send(if (cancel) MotionEvent.ACTION_CANCEL else MotionEvent.ACTION_UP, endX, endY)
        instrumentation.waitForIdleSync()
    }

    private fun awaitWindowFocus(activity: Activity) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            instrumentation.waitForIdleSync()
            var focused = false
            instrumentation.runOnMainSync { focused = activity.window.decorView.hasWindowFocus() }
            if (focused) return
            SystemClock.sleep(25)
        } while (SystemClock.uptimeMillis() < deadline)
        fail("Expected ${activity.javaClass.simpleName} to regain window focus")
    }

    private fun descendants(root: View): List<View> = buildList {
        add(root)
        if (root is ViewGroup) for (index in 0 until root.childCount) addAll(descendants(root.getChildAt(index)))
    }

    private data class TouchPosition(
        val centerX: Float,
        val centerY: Float,
        val topX: Float,
        val topY: Float,
        val cornerX: Float,
        val cornerY: Float,
    )
}
