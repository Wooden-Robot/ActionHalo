package com.actionhalo.android

import android.app.AlertDialog
import android.graphics.drawable.Icon
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Pauses automatic entry points; explicit share and clipboard actions remain available. */
class PauseTileService : TileService() {
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = Runnable { updateState() }
    override fun onStartListening() { super.onStartListening(); updateState() }
    override fun onStopListening() { handler.removeCallbacks(refresh); super.onStopListening() }
    override fun onDestroy() { handler.removeCallbacks(refresh); super.onDestroy() }
    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { choosePause() } else choosePause()
    }
    private fun choosePause() {
        val context = HaloUi.localizedContext(this)
        val store = AppRulesStore(this)
        if (store.isPaused()) { store.resume(); updateState(); return }
        val dialog = AlertDialog.Builder(context).setTitle(R.string.pause_title)
            .setItems(arrayOf(context.getString(R.string.pause_ten_minutes), context.getString(R.string.pause_one_hour))) { _, index ->
                store.pauseFor(if (index == 0) AppRulesStore.TEN_MINUTES else AppRulesStore.ONE_HOUR)
                updateState()
            }.setNegativeButton(android.R.string.cancel, null).create()
        try { showDialog(dialog) }
        catch (_: RuntimeException) { android.widget.Toast.makeText(context, R.string.pause_tile_manual, android.widget.Toast.LENGTH_LONG).show() }
    }
    private fun updateState() {
        handler.removeCallbacks(refresh)
        val context = HaloUi.localizedContext(this)
        val remaining = AppRulesStore(this).pauseRemainingMillis()
        qsTile?.apply {
            icon = Icon.createWithResource(this@PauseTileService, R.drawable.ic_clipboard_halo)
            label = context.getString(if (remaining > 0) R.string.pause_tile_paused else R.string.pause_tile_label)
            state = if (remaining > 0) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
            updateTile()
        }
        if (remaining > 0) handler.postDelayed(refresh, remaining + 50L)
    }
}
