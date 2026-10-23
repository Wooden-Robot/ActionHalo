package com.actionhalo.android

import android.os.Build
import org.junit.Assert.assertTrue

/** Older Google images use a different model name; never change physical-device settings. */
internal fun assertDisposableEmulator() {
    assertTrue("Settings diagnostics require a disposable Android emulator",
        Build.HARDWARE in listOf("ranchu", "goldfish") &&
            (Build.MODEL.startsWith("sdk_gphone") || Build.MODEL.startsWith("Android SDK built for")))
}
