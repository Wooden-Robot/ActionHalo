package com.actionhalo.android

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

/** Opens a focused activity after a tile tap; this service never reads the clipboard. */
class ClipboardTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            label = HaloUi.localizedContext(this@ClipboardTileService).getString(R.string.clipboard_tile_label)
            icon = Icon.createWithResource(this@ClipboardTileService, R.drawable.ic_clipboard_halo)
            state = Tile.STATE_INACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { openCopiedText() }
        else openCopiedText()
    }

    @Suppress("DEPRECATION")
    @SuppressLint("StartActivityAndCollapseDeprecated") // Intent is used only on API 26–33; PendingIntent arrived in 34.
    private fun openCopiedText() {
        val intent = ClipboardHaloActivity.requestIntent(this)
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(
                    this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                ))
            } else {
                startActivityAndCollapse(intent)
            }
        } catch (_: RuntimeException) {
            Toast.makeText(HaloUi.localizedContext(this), R.string.clipboard_open_unavailable, Toast.LENGTH_SHORT).show()
        }
    }
}
