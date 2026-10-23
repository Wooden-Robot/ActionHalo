package com.actionhalo.android

import android.app.Instrumentation
import android.view.Choreographer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue

internal fun Instrumentation.settleInput() {
    // Two frames let older Android finish motion resampling before the next synthetic event.
    val frame = CountDownLatch(1)
    runOnMainSync {
        Choreographer.getInstance().postFrameCallback {
            Choreographer.getInstance().postFrameCallback { frame.countDown() }
        }
    }
    assertTrue("Injected input must reach a real display frame", frame.await(5, TimeUnit.SECONDS))
    waitForIdleSync()
}
