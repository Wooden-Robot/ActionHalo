package com.actionhalo.android

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.SystemClock
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.Switch
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

class SettingsPagesTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val preferences = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
    private var previous: Map<String, *> = emptyMap<String, Any?>()

    @Before fun isolate() { previous = preferences.all.toMap(); assertTrue(preferences.edit().clear().commit()) }
    @After fun restore() {
        val edit = preferences.edit().clear()
        previous.forEach { (key, value) -> when (value) {
            is Boolean -> edit.putBoolean(key, value)
            is Int -> edit.putInt(key, value)
            is Long -> edit.putLong(key, value)
            is Float -> edit.putFloat(key, value)
            is String -> edit.putString(key, value)
        } }
        assertTrue(edit.commit())
    }

    @Test fun homeStaysCompactAndEachDestinationOwnsItsControls() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            val views = descendants(activity.window.decorView)
            assertEquals(listOf(activity.getString(R.string.auto_title)), views.filterIsInstance<Switch>().map { it.text.toString() })
            listOf(R.string.page_actions, R.string.page_appearance, R.string.page_triggers, R.string.page_diagnostics, R.string.page_about)
                .forEach { label -> assertTrue(views.filterIsInstance<Button>().any { it.text.toString() == activity.getString(label) }) }
            assertFalse(views.filterIsInstance<Button>().any { it.text.toString() == activity.getString(R.string.health_copy_button) })
        } }
        listOf(MainActivity.Page.ACTIONS to R.string.add_action, MainActivity.Page.APPEARANCE to R.string.halo_reset,
            MainActivity.Page.TRIGGERS to R.string.auto_title, MainActivity.Page.DIAGNOSTICS to R.string.health_copy_button,
            MainActivity.Page.ABOUT to R.string.update_check).forEach { (page, label) ->
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, page)).use { scenario ->
                scenario.recreate()
                scenario.onActivity { activity -> assertTrue(descendants(activity.window.decorView).filterIsInstance<TextView>()
                    .any { it.text.toString() == activity.getString(label) }) }
            }
        }
    }

    @Test fun appearanceSettingsAreSharedValidatedAndResetDoesNotRevokePermissions() {
        assertEquals(400, HaloAppearance.menuSizeDp(context))
        assertTrue(HaloAppearance.hapticsEnabled(context))
        for (size in HaloAppearance.MENU_SIZES) {
            HaloAppearance.setMenuSizeDp(context, size)
            assertEquals(size, HaloAppearance.menuSizeDp(context.applicationContext))
        }
        HaloAppearance.setDimPercent(context, 0)
        assertEquals(0f, HaloAppearance.dimAmount(context), 0.0001f)
        val transparent = Bitmap.createBitmap(32, 64, Bitmap.Config.ARGB_8888)
        try {
            for (blurred in listOf(false, true)) {
                HaloAppearance.gtaBackdrop(context, blurred).apply { setBounds(0, 0, 32, 64); draw(Canvas(transparent)) }
                assertTrue("Zero dimming must leave every backdrop layer transparent",
                    (0 until transparent.height).all { y -> (0 until transparent.width).all { x ->
                        Color.alpha(transparent.getPixel(x, y)) == 0
                    } })
            }
        } finally { transparent.recycle() }
        HaloAppearance.setDimPercent(context, 80)
        assertEquals(0.8f, HaloAppearance.dimAmount(context), 0.0001f)
        HaloAppearance.setHapticsEnabled(context, false)
        assertFalse(HaloAppearance.hapticsEnabled(context))
        listOf(-1, 81).forEach { value ->
            try { HaloAppearance.setDimPercent(context, value); fail("Invalid dim") } catch (_: IllegalArgumentException) { }
        }
        try { HaloAppearance.setMenuSizeDp(context, 1); fail("Invalid size") } catch (_: IllegalArgumentException) { }
        assertTrue(preferences.edit().putBoolean("accessibility_consent", true).putBoolean("auto_popup_enabled", true).commit())
        HaloAppearance.reset(context)
        assertEquals(400, HaloAppearance.menuSizeDp(context))
        assertTrue(HaloAppearance.hapticsEnabled(context))
        assertTrue(preferences.getBoolean("accessibility_consent", false))
        assertTrue(preferences.getBoolean("auto_popup_enabled", false))
        assertTrue(preferences.edit().putString(HaloAppearance.MENU_SIZE_KEY, "480").putInt(HaloAppearance.DIM_KEY, 900).commit())
        assertEquals(400, HaloAppearance.menuSizeDp(context))
        assertEquals(HaloAppearance.GTA_DIM_AMOUNT, HaloAppearance.dimAmount(context), 0.0001f)
        val shaded = Bitmap.createBitmap(96, 192, Bitmap.Config.ARGB_8888)
        try {
            HaloAppearance.gtaBackdrop(context).apply { setBounds(0, 0, 96, 192); draw(Canvas(shaded)) }
            val centerAlpha = Color.alpha(shaded.getPixel(48, 96))
            assertTrue("The GTA backdrop must shade the top and bottom more than its center",
                Color.alpha(shaded.getPixel(48, 1)) > centerAlpha + 80 &&
                    Color.alpha(shaded.getPixel(48, 190)) > centerAlpha + 80)
        } finally { shaded.recycle() }
    }

    @Test fun gtaBlurUsesSystemSupportAndPreservesNormalModeAndZeroDimming() {
        for (gta in listOf(true, false)) for (dim in listOf(0, 58)) {
            HaloAppearance.setGtaModeEnabled(context, gta)
            HaloAppearance.setDimPercent(context, dim)
            val incoming = Intent(context, HaloActivity::class.java).apply {
                action = Intent.ACTION_SEND
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, "GTA background fixture")
            }
            ActivityScenario.launch<HaloActivity>(incoming).use { scenario -> scenario.onActivity { activity ->
                val params = activity.window.attributes
                val blurred = gta && Build.VERSION.SDK_INT >= 31 &&
                    activity.getSystemService(WindowManager::class.java).isCrossWindowBlurEnabled
                assertEquals(blurred, params.flags and WindowManager.LayoutParams.FLAG_BLUR_BEHIND != 0)
                if (Build.VERSION.SDK_INT >= 31) {
                    assertEquals(if (blurred) HaloUi.dp(activity, 28) else 0, params.blurBehindRadius)
                }
                assertEquals(dim / 100f * if (blurred) 0.55f else 1f, params.dimAmount, 0.0001f)
                val menu = descendants(activity.window.decorView).filterIsInstance<RadialMenuView>().single()
                assertEquals(gta, (menu.parent as View).background != null)
            } }
        }
    }

    @Test fun openingTheAppRemovesOnlyObsoleteModelsAndPreservesSettings() {
        val oldModels = File(context.noBackupFilesDir, "com.google.mlkit.translate.models")
        val oldModel = File(oldModels, "temp/en_zh/cleanup-test-model")
        oldModel.parentFile!!.mkdirs()
        oldModel.writeText("Obsolete model fixture")
        val keep = File(context.noBackupFilesDir, "cleanup-test-keep")
        keep.writeText("Unrelated data")
        HaloAppearance.setMenuSizeDp(context, 480)
        HaloAppearance.setDimPercent(context, 50)
        val saved = preferences.all.toMap()
        try {
            ActivityScenario.launch(MainActivity::class.java).use {
                val deadline = SystemClock.uptimeMillis() + 5_000
                while (oldModels.exists() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
                assertFalse(oldModels.exists())
                assertEquals("Unrelated data", keep.readText())
                assertEquals(saved, preferences.all)
            }
        } finally { keep.delete(); oldModels.deleteRecursively() }
    }

    private fun descendants(view: View): List<View> = listOf(view) + if (view is ViewGroup)
        (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()
}
