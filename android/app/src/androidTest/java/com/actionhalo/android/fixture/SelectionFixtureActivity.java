package com.actionhalo.android.fixture;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.accessibility.AccessibilityEvent;
import android.view.inputmethod.InputMethodManager;
import android.webkit.WebView;
import android.widget.EditText;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.PopupWindow;
import android.widget.TextView;

/** Foreign APK activity deliberately needs no runtime supplied only by the target APK. */
public class SelectionFixtureActivity extends Activity {
    public static final String EXTRA_SELECT_ALL = "select_all";
    public static final String EXTRA_TEXT = "fixture_text";
    public static final String EXTRA_MODE = "fixture_mode";
    public static final String EXTRA_RANGE_RACE = "range_race";
    public static final String RACE_STALE_COLLAPSED = "stale_collapsed";
    public static final String RACE_STALE_NONEMPTY = "stale_nonempty";
    public static final String MODE_READONLY = "readonly";
    public static final String MODE_WEB = "web";
    public static final String MODE_COPY_POPUP = "copy_button_popup";
    public static final String SAMPLE_TEXT = "Selection fixture: 你好，ActionHalo 🌍";
    public static final String FOCUS_DIALOG_TITLE = "Temporary selection focus fixture";
    private EditText editor;
    private boolean requestedSelection;
    private int touchDownCount;
    private PopupWindow copyPopup;

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent.getBooleanExtra("repeat_selection_event", false) && editor != null) {
            sendSelectionSnapshot(editor.getSelectionStart(), editor.getSelectionEnd());
            return;
        }
        if (intent.getBooleanExtra("show_keyboard", false) && editor != null) {
            editor.setShowSoftInputOnFocus(true);
            editor.requestFocus();
            editor.post(() -> getSystemService(InputMethodManager.class)
                .showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT));
            return;
        }
        if (!intent.getBooleanExtra("show_focus_dialog", false)) return;
        AlertDialog dialog = new AlertDialog.Builder(this)
            .setMessage(FOCUS_DIALOG_TITLE)
            .setPositiveButton("Close temporary focus fixture", (window, which) -> window.dismiss())
            .create();
        dialog.show();
        dialog.getWindow().setTitle(FOCUS_DIALOG_TITLE);
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        setTitle("ActionHalo selection fixture");
        String mode = getIntent().getStringExtra(EXTRA_MODE);
        if (MODE_COPY_POPUP.equals(mode)) {
            TextView title = new TextView(this);
            configureText(title, "Ordinary Copy button popup fixture");
            showFixture(title);
            Button copy = new Button(this);
            copy.setText(android.R.string.copy);
            copy.setOnClickListener(view -> {
                getSystemService(ClipboardManager.class).setPrimaryClip(
                    ClipData.newPlainText("Ordinary button fixture", "Unexpected ordinary Copy click"));
                copyPopup.dismiss();
            });
            float density = getResources().getDisplayMetrics().density;
            copyPopup = new PopupWindow(copy, (int) (240 * density), (int) (96 * density), false);
            copyPopup.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
            title.post(() -> copyPopup.showAtLocation(title, Gravity.CENTER, 0, 0));
            return;
        }
        if (MODE_WEB.equals(mode)) {
            WebView web = new WebView(this);
            web.setId(View.generateViewId());
            web.loadDataWithBaseURL("https://actionhalo.test/",
                "<!doctype html><html><head><meta name='viewport' content='width=device-width, initial-scale=1'></head>" +
                "<body style='margin:24px;font:26px sans-serif;line-height:1.6'>" +
                "<p>Selection fixture: Alpha beta gamma delta. 你好，ActionHalo 🌍</p></body></html>",
                "text/html", "UTF-8", null);
            showFixture(web);
            return;
        }
        String supplied = getIntent().getStringExtra(EXTRA_TEXT);
        String text = supplied == null ? SAMPLE_TEXT : supplied;
        if (getIntent().getBooleanExtra("multiline_selection", false)) {
            for (int line = 0; line < 10; line++) text += "\nAlpha beta gamma delta";
        }
        if (MODE_READONLY.equals(mode)) {
            TextView readOnly = new TextView(this);
            configureText(readOnly, text);
            readOnly.setTextIsSelectable(true);
            showFixture(readOnly);
            return;
        }
        editor = new EditText(this) {
            @Override protected void onSelectionChanged(int start, int end) {
                super.onSelectionChanged(start, end);
                post(() -> publishHandleGeometry(this));
            }
        };
        configureText(editor, text);
        editor.setContentDescription("Foreign selection fixture; touchDowns=" + touchDownCount);
        editor.setMinLines(3);
        editor.setShowSoftInputOnFocus(false);
        if (getIntent().getBooleanExtra("mute_selection_events", false)) {
            editor.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                @Override public void sendAccessibilityEventUnchecked(View host, AccessibilityEvent event) {
                    if (event.getEventType() != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) {
                        super.sendAccessibilityEventUnchecked(host, event);
                    }
                }
            });
        }
        showFixture(editor);
        editor.requestFocus();
    }

    private void publishHandleGeometry(EditText view) {
        if (!getIntent().getBooleanExtra("selection_handles", false) || view.getLayout() == null ||
                view.getSelectionStart() < 0 || view.getSelectionEnd() <= view.getSelectionStart()) return;
        android.content.res.TypedArray attributes = getTheme().obtainStyledAttributes(
            new int[] { android.R.attr.textSelectHandleRight });
        android.graphics.drawable.Drawable handle;
        try { handle = attributes.getDrawable(0); } finally { attributes.recycle(); }
        if (handle == null) return;
        int[] location = new int[2];
        view.getLocationOnScreen(location);
        android.text.Layout layout = view.getLayout();
        int end = view.getSelectionEnd();
        int target = Math.min(18, view.length());
        float x = location[0] + view.getTotalPaddingLeft() - view.getScrollX() + layout.getPrimaryHorizontal(end);
        float y = location[1] + view.getTotalPaddingTop() - view.getScrollY() +
            layout.getLineBottom(layout.getLineForOffset(end));
        float shift = layout.getPrimaryHorizontal(target) - layout.getPrimaryHorizontal(end);
        view.setContentDescription("Foreign selection fixture; touchDowns=" + touchDownCount +
            "; handle=" + (x + handle.getIntrinsicWidth() / 4f) + "," + (y + handle.getIntrinsicHeight() / 2f) +
            "; drag=" + shift + "; range_end=" + end);
    }

    @Override protected void onDestroy() {
        if (copyPopup != null) copyPopup.dismiss();
        super.onDestroy();
    }

    private void configureText(TextView view, String text) {
        // Framework TextView requires an ID before it offers ACTION_PROCESS_TEXT.
        view.setId(View.generateViewId());
        view.setText(text);
        view.setTextSize(22f);
        view.setGravity(Gravity.TOP | Gravity.START);
        view.setPadding(32, 32, 32, 32);
    }

    private void showFixture(View child) {
        // The target-36 foreign APK is edge-to-edge; keep all selection targets below system UI.
        FrameLayout root = new FrameLayout(this);
        root.setPadding(0, 160, 0, 0);
        root.addView(child, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
    }

    @Override public boolean dispatchTouchEvent(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
            touchDownCount++;
            if (editor != null) editor.setContentDescription("Foreign selection fixture; touchDowns=" + touchDownCount);
        }
        return super.dispatchTouchEvent(event);
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        String race = getIntent().getStringExtra(EXTRA_RANGE_RACE);
        if (editor != null && hasFocus && !requestedSelection && race != null) {
            requestedSelection = true;
            editor.postDelayed(() -> {
                if (isFinishing()) return;
                editor.setSelection(0, 9);
                editor.postDelayed(() -> {
                    if (isFinishing()) return;
                    if (RACE_STALE_COLLAPSED.equals(race)) {
                        // Model a delayed collapsed event while the fresh node still has 0:9.
                        sendSelectionSnapshot(1, 1);
                    } else if (RACE_STALE_NONEMPTY.equals(race)) {
                        // Model the inverse: a stale nonempty event after a real cancellation.
                        editor.setSelection(1, 1);
                        editor.postDelayed(() -> sendSelectionSnapshot(0, 9), 50);
                    }
                }, 75);
            }, 1_100);
            return;
        }
        if (editor != null && hasFocus && !requestedSelection && getIntent().getBooleanExtra(EXTRA_SELECT_ALL, false)) {
            requestedSelection = true;
            editor.postDelayed(() -> {
                if (isFinishing()) return;
                if (getIntent().getBooleanExtra("refine_selection", false)) {
                    editor.setSelection(0, Math.min(9, editor.length()));
                    editor.postDelayed(() -> {
                        if (!isFinishing()) editor.setSelection(0, editor.length());
                    }, 350);
                } else editor.setSelection(0, editor.length());
            }, 300);
        }
    }

    /** Controlled event race through the real framework, without changing the node's selection. */
    @SuppressWarnings("deprecation")
    private void sendSelectionSnapshot(int start, int end) {
        if (isFinishing() || editor.getParent() == null) return;
        AccessibilityEvent event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED);
        event.setSource(editor);
        event.setClassName(editor.getAccessibilityClassName());
        event.setPackageName(getPackageName());
        event.setEventTime(SystemClock.uptimeMillis());
        event.setFromIndex(start);
        event.setToIndex(end);
        event.setItemCount(editor.length());
        // Parent dispatch preserves the intentionally old event range; initializing a new
        // TextView event would replace it with the current range and erase the experiment.
        editor.getParent().requestSendAccessibilityEvent(editor, event);
    }
}
