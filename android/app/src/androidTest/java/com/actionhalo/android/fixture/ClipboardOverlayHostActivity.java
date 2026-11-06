package com.actionhalo.android.fixture;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Bundle;
import android.widget.TextView;

/** Test APK, different UID from the service. Only writes this fixed synthetic clip. */
public final class ClipboardOverlayHostActivity extends Activity {
    public static final String SAMPLE = "只复制所选：你好 🌍 café e\u0301 & こんにちは\n第二行 👨‍👩‍👧‍👦";
    public static final String SEEDED = "Clipboard overlay fixture seeded";
    private boolean seeded;
    private TextView status;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        status = new TextView(this);
        status.setText("Clipboard overlay fixture waiting for focus");
        status.setTextSize(22);
        status.setPadding(24, 80, 24, 24);
        setContentView(status);
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || seeded) return;
        seeded = true;
        getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("Fixed overlay fixture", SAMPLE));
        status.setText(SEEDED);
    }
}
