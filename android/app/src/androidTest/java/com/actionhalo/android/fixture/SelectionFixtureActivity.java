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
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.InputMethodManager;
import android.webkit.WebView;
import android.widget.EditText;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.GridLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.PopupWindow;
import android.widget.ScrollView;
import android.widget.TextView;

/** Foreign APK activity deliberately needs no runtime supplied only by the target APK. */
public class SelectionFixtureActivity extends Activity {
    public static final String IME_VISIBLE_NODE_EXTRA = "com.actionhalo.android.fixture.IME_VISIBLE";
    public static final String EXTRA_SELECT_ALL = "select_all";
    public static final String EXTRA_TEXT = "fixture_text";
    public static final String EXTRA_MODE = "fixture_mode";
    public static final String EXTRA_RANGE_RACE = "range_race";
    public static final String RACE_STALE_COLLAPSED = "stale_collapsed";
    public static final String RACE_STALE_NONEMPTY = "stale_nonempty";
    public static final String MODE_READONLY = "readonly";
    public static final String MODE_WEB = "web";
    public static final String MODE_COPY_POPUP = "copy_button_popup";
    public static final String MODE_COMMENTS = "comments";
    public static final String MODE_CUSTOM_MENU = "custom_selection_menu";
    public static final String CUSTOM_MENU_TEXT = "中文 🚀 café — selected fragment";
    public static final String SAMPLE_TEXT = "Selection fixture: 你好，ActionHalo 🌍";
    public static final String FOCUS_DIALOG_TITLE = "Temporary selection focus fixture";
    private EditText editor;
    private boolean requestedSelection;
    private int touchDownCount;
    private PopupWindow copyPopup;
    private TextView customSource;
    private boolean hideMenuMetadata;

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (editor != null && intent.getBooleanExtra("show_controlled_copy_toolbar", false)) {
            showControlledCopyToolbar(intent.getBooleanExtra("defer_copy_contents", false));
            return;
        }
        if (intent.hasExtra("hide_menu_accessibility") && copyPopup != null) {
            View menu = copyPopup.getContentView();
            Runnable update = () -> {
                hideMenuMetadata = intent.getBooleanExtra("hide_menu_accessibility", false);
                menu.sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
            };
            int delay = intent.getIntExtra("menu_metadata_delay_ms", 0);
            if (delay > 0) menu.postDelayed(update, delay); else update.run();
            return;
        }
        if (intent.getBooleanExtra("dismiss_menu", false) && copyPopup != null) {
            copyPopup.dismiss();
            return;
        }
        if (intent.hasExtra("custom_text_event") && customSource != null) {
            String kind = intent.getStringExtra("custom_text_event");
            boolean contentOnly = "content".equals(kind);
            if (contentOnly) customSource.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                @Override public void sendAccessibilityEventUnchecked(View host, AccessibilityEvent event) {
                    if (event.getEventType() != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED) {
                        super.sendAccessibilityEventUnchecked(host, event);
                    }
                }
            });
            if ("view".equals(kind) || contentOnly) {
                customSource.setTextKeepState(customSource.getText().toString().replace("中文", "替换"));
            }
            View source = "menu".equals(kind) ? copyPopup.getContentView() : customSource;
            AccessibilityEvent event = AccessibilityEvent.obtain("view".equals(kind)
                ? AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED : AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
            event.setSource(source);
            event.setPackageName(getPackageName());
            event.setClassName(source.getAccessibilityClassName());
            event.setEventTime(SystemClock.uptimeMillis());
            if ("view".equals(kind)) {
                event.setFromIndex(9);
                event.setAddedCount(2);
                event.setRemovedCount(2);
            } else if (!"generic".equals(kind)) event.setContentChangeTypes(AccessibilityEvent.CONTENT_CHANGE_TYPE_TEXT);
            source.getParent().requestSendAccessibilityEvent(source, event);
            return;
        }
        if (intent.hasExtra("custom_selection_start") && customSource != null) {
            if (intent.getBooleanExtra("replace_custom_selection_node", false)) {
                TextView replacement = new TextView(this);
                configureText(replacement, customSource.getText().toString());
                ViewGroup parent = (ViewGroup) customSource.getParent();
                int index = parent.indexOfChild(customSource);
                ViewGroup.LayoutParams params = customSource.getLayoutParams();
                parent.removeView(customSource);
                parent.addView(replacement, index, params);
                customSource = replacement;
            }
            customSource.setTextIsSelectable(true);
            int start = intent.getIntExtra("custom_selection_start", 0);
            int end = intent.getIntExtra("custom_selection_end", start);
            android.text.Selection.setSelection((android.text.Spannable) customSource.getText(), start, end);
            customSource.postDelayed(() -> sendSelectionSnapshot(customSource, start, end), 100);
            return;
        }
        if (intent.getBooleanExtra("unknown_selection_event", false) && customSource != null) {
            AccessibilityEvent event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED);
            event.setSource(customSource);
            event.setFromIndex(-1);
            event.setToIndex(-1);
            customSource.sendAccessibilityEventUnchecked(event);
            return;
        }
        if (intent.hasExtra("native_text_event") && editor != null) {
            String kind = intent.getStringExtra("native_text_event");
            boolean changed = "same_length_change".equals(kind) || "length_change".equals(kind);
            int previousLength = editor.length();
            if (changed) {
                String original = editor.getText().toString();
                editor.setTextKeepState("same_length_change".equals(kind)
                    ? original.replace("Selection", "Different") : original + " changed");
            }
            // Programmatic text setters need not publish TYPE_VIEW_TEXT_CHANGED
            // on every SDK. Deliver the probe after the actual value/range update.
            View source = "other_node".equals(kind) ? editor.getRootView() : editor;
            AccessibilityEvent event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED);
            event.setSource(source);
            event.setPackageName(getPackageName());
            event.setClassName(source.getAccessibilityClassName());
            event.setEventTime(SystemClock.uptimeMillis());
            event.setFromIndex(0);
            event.setAddedCount(editor.length());
            event.setRemovedCount(changed ? previousLength : 0);
            event.setPassword("password_metadata".equals(kind));
            source.getParent().requestSendAccessibilityEvent(source, event);
            return;
        }
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
        if (MODE_CUSTOM_MENU.equals(mode)) {
            TextView title = new TextView(this) {
                @Override protected void onSelectionChanged(int start, int end) {
                    super.onSelectionChanged(start, end);
                    post(() -> publishHandleGeometry(this));
                }
            };
            boolean persistentMenu = getIntent().getBooleanExtra("persistent_selection_menu", false);
            customSource = title;
            configureText(title, "Before — " + CUSTOM_MENU_TEXT + " — after");
            showFixture(title);
            String kind = getIntent().getStringExtra("custom_menu_kind");
            boolean chatMenu = kind != null && kind.startsWith("chat");
            boolean menuGeometry = getIntent().getBooleanExtra("menu_geometry", false);
            int rowHeight = getIntent().getIntExtra("menu_row_dp", 72);
            String[] labels = "incomplete".equals(kind) ? new String[] { "复制", "转发" } :
                chatMenu ? new String[] { "复制", "转发", "收藏", "删除", "多选",
                "引用", "提醒", "翻译", "搜一搜", "连续朗读" } :
                new String[] { "拨号", "小V写作", "剪切", "复制" };
            GridLayout menu = new GridLayout(this);
            int columns = chatMenu ? 5 : 4;
            menu.setColumnCount(columns);
            float density = getResources().getDisplayMetrics().density;
            for (int index = 0; index < labels.length; index++) {
                String label = labels[index];
                View button;
                if ("chat_nested".equals(kind)) {
                    LinearLayout item = new LinearLayout(this);
                    TextView text = new TextView(this);
                    text.setText(label);
                    text.setTextSize(12f);
                    text.setGravity(Gravity.CENTER);
                    item.addView(text, new LinearLayout.LayoutParams(-1, -1));
                    button = item;
                } else {
                    Button control = new Button(this);
                    control.setText(label);
                    control.setTextSize(12f);
                    control.setMinWidth(0);
                    control.setPadding(0, 0, 0, 0);
                    button = control;
                }
                button.setOnClickListener(view -> {
                    if (menuGeometry) title.setContentDescription("menu_action=" + label);
                    if ("复制".equals(label)) {
                        CharSequence copied = persistentMenu || customSource.getSelectionStart() >= 0
                            ? customSource.getText().subSequence(customSource.getSelectionStart(), customSource.getSelectionEnd())
                            : CUSTOM_MENU_TEXT;
                        getSystemService(ClipboardManager.class).setPrimaryClip(
                            ClipData.newPlainText("Custom menu fixture", copied));
                        copyPopup.dismiss();
                    } else if (menuGeometry) copyPopup.dismiss();
                });
                if (menuGeometry) button.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                    @Override public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
                        super.onInitializeAccessibilityNodeInfo(host, info);
                        if (hideMenuMetadata) {
                            info.setText(null);
                            info.setContentDescription(null);
                        }
                        int[] point = new int[2];
                        host.getLocationOnScreen(point);
                        info.getExtras().putFloat("fixture_menu_touch_x", point[0] + host.getWidth() / 2f);
                        info.getExtras().putFloat("fixture_menu_touch_y", point[1] + host.getHeight() / 2f);
                    }
                });
                if (getIntent().getBooleanExtra("filter_menu_overlay", false)) button.setOnTouchListener((view, event) -> {
                    return (event.getFlags() & (MotionEvent.FLAG_WINDOW_IS_OBSCURED | MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED)) != 0;
                });
                if ("chat_unsupported".equals(kind)) {
                    button.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                        @Override public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
                            super.onInitializeAccessibilityNodeInfo(host, info);
                            info.setClassName("fixture.UnsupportedMenuControl");
                        }
                    });
                }
                GridLayout.LayoutParams params = new GridLayout.LayoutParams(
                    GridLayout.spec(index / columns), GridLayout.spec(index % columns, 1f));
                params.width = 0;
                params.height = (int) (rowHeight * density);
                menu.addView(button, params);
            }
            int screenWidth = getResources().getDisplayMetrics().widthPixels;
            View content = menu;
            if ("chat_horizontal".equals(kind)) {
                HorizontalScrollView overflow = new HorizontalScrollView(this);
                menu.setMinimumWidth(screenWidth * 4 / 3);
                overflow.addView(menu);
                content = overflow;
            }
            copyPopup = new PopupWindow(content, screenWidth - (int) (32 * density),
                (int) (((chatMenu ? 2 : 1) * rowHeight + 8) * density), false);
            copyPopup.setBackgroundDrawable(new ColorDrawable(Color.LTGRAY));
            if (persistentMenu) {
                title.setTextIsSelectable(true);
                title.setCustomSelectionActionModeCallback(new android.view.ActionMode.Callback() {
                    @Override public boolean onCreateActionMode(android.view.ActionMode mode, android.view.Menu menu) {
                        menu.clear();
                        title.post(() -> copyPopup.showAtLocation(title, Gravity.CENTER, 0, 0));
                        return true;
                    }
                    @Override public boolean onPrepareActionMode(android.view.ActionMode mode, android.view.Menu menu) {
                        menu.clear();
                        return true;
                    }
                    @Override public boolean onActionItemClicked(android.view.ActionMode mode, android.view.MenuItem item) { return false; }
                    @Override public void onDestroyActionMode(android.view.ActionMode mode) { copyPopup.dismiss(); }
                });
            } else title.post(() -> copyPopup.showAtLocation(title, Gravity.CENTER, 0, 0));
            return;
        }
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
            // A plain text control exposes its value and selection on the same accessibility node.
            String text = "Selection fixture: Alpha beta gamma delta. 你好，ActionHalo 🌍";
            String content = getIntent().getBooleanExtra("editable_web", false)
                ? "<textarea style='font:inherit;line-height:inherit;padding:0;border:0;width:100%;height:300px'>" + text + "</textarea>"
                : "<p>" + text + "</p>";
            web.loadDataWithBaseURL("https://actionhalo.test/",
                "<!doctype html><html><head><meta name='viewport' content='width=device-width, initial-scale=1'></head>" +
                "<body style='margin:24px;font:26px sans-serif;line-height:1.6'>" +
                content + "</body></html>",
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
            @Override public void onInitializeAccessibilityNodeInfo(android.view.accessibility.AccessibilityNodeInfo info) {
                super.onInitializeAccessibilityNodeInfo(info);
                android.view.WindowInsets insets = getRootWindowInsets();
                if (android.os.Build.VERSION.SDK_INT >= 30 && insets != null) {
                    info.getExtras().putBoolean(IME_VISIBLE_NODE_EXTRA,
                        insets.isVisible(android.view.WindowInsets.Type.ime()));
                }
            }

            @Override protected void onSelectionChanged(int start, int end) {
                super.onSelectionChanged(start, end);
                post(() -> publishHandleGeometry(this));
            }
        };
        configureText(editor, text);
        if (getIntent().getBooleanExtra("controlled_copy_toolbar", false)) {
            editor.setCustomSelectionActionModeCallback(new android.view.ActionMode.Callback() {
                @Override public boolean onCreateActionMode(android.view.ActionMode mode, android.view.Menu menu) { menu.clear(); return true; }
                @Override public boolean onPrepareActionMode(android.view.ActionMode mode, android.view.Menu menu) { menu.clear(); return true; }
                @Override public boolean onActionItemClicked(android.view.ActionMode mode, android.view.MenuItem item) { return false; }
                @Override public void onDestroyActionMode(android.view.ActionMode mode) {}
            });
        }
        editor.setContentDescription("Foreign selection fixture; touchDowns=" + touchDownCount);
        editor.setMinLines(3);
        editor.setShowSoftInputOnFocus(false);
        if (getIntent().getBooleanExtra("mute_selection_events", false) ||
                getIntent().getBooleanExtra("hide_character_locations", false)) {
            editor.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                @Override public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
                    super.onInitializeAccessibilityNodeInfo(host, info);
                    if (getIntent().getBooleanExtra("hide_character_locations", false)) {
                        info.setAvailableExtraData(java.util.Collections.emptyList());
                    }
                }
                @Override public void sendAccessibilityEventUnchecked(View host, AccessibilityEvent event) {
                    if (!getIntent().getBooleanExtra("mute_selection_events", false) ||
                            event.getEventType() != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) {
                        super.sendAccessibilityEventUnchecked(host, event);
                    }
                }
            });
        }
        showFixture(editor);
        editor.requestFocus();
        if (MODE_COMMENTS.equals(mode)) {
            int panelHeight = getResources().getDisplayMetrics().heightPixels / 3;
            ScrollView comments = new ScrollView(this);
            LinearLayout rows = new LinearLayout(this);
            rows.setOrientation(LinearLayout.VERTICAL);
            comments.addView(rows);
            TextView first = new TextView(this);
            first.setText("Replies");
            rows.addView(first, -1, panelHeight);
            for (String label : new String[] { "复制", "转发", "收藏" }) {
                Button action = new Button(this);
                action.setText(label);
                rows.addView(action);
            }
            copyPopup = new PopupWindow(comments, -1, panelHeight, false);
            copyPopup.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
            editor.post(() -> copyPopup.showAtLocation(editor, Gravity.CENTER, 0, 0));
        }
    }

    private void publishHandleGeometry(TextView view) {
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

    private void showControlledCopyToolbar(boolean deferContents) {
        if (copyPopup != null) copyPopup.dismiss();
        FrameLayout contents = new FrameLayout(this);
        contents.setContentDescription("Publish Copy toolbar contents");
        float density = getResources().getDisplayMetrics().density;
        PopupWindow popup = new PopupWindow(contents, (int) (240 * density), (int) (96 * density), false);
        popup.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
        copyPopup = popup;
        Runnable addCopy = () -> {
            contents.setOnClickListener(null);
            contents.setClickable(false);
            Button copy = new Button(this);
            copy.setText(android.R.string.copy);
            copy.setOnClickListener(view -> getSystemService(ClipboardManager.class).setPrimaryClip(
                ClipData.newPlainText("Controlled selection", editor.getText().subSequence(
                    editor.getSelectionStart(), editor.getSelectionEnd()))));
            contents.addView(copy, new FrameLayout.LayoutParams(-1, -1));
        };
        if (deferContents) contents.setOnClickListener(view -> addCopy.run()); else addCopy.run();
        popup.showAtLocation(editor, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL, 0, (int) (24 * density));
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
        if (child instanceof WebView && getIntent().getBooleanExtra("mute_selection_events", false)) {
            root.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                @Override public boolean onRequestSendAccessibilityEvent(ViewGroup host, View child, AccessibilityEvent event) {
                    return event.getEventType() != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED &&
                        super.onRequestSendAccessibilityEvent(host, child, event);
                }
            });
        }
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
                editor.setSelection(0, editor.length());
            }, 300);
        }
    }

    /** Controlled event race through the real framework, without changing the node's selection. */
    private void sendSelectionSnapshot(int start, int end) {
        sendSelectionSnapshot(editor, start, end);
    }

    @SuppressWarnings("deprecation")
    private void sendSelectionSnapshot(TextView source, int start, int end) {
        if (isFinishing() || source.getParent() == null) return;
        AccessibilityEvent event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED);
        event.setSource(source);
        event.setClassName(source.getAccessibilityClassName());
        event.setPackageName(getPackageName());
        event.setEventTime(SystemClock.uptimeMillis());
        event.setFromIndex(start);
        event.setToIndex(end);
        event.setItemCount(source.length());
        // Parent dispatch preserves the intentionally old event range; initializing a new
        // TextView event would replace it with the current range and erase the experiment.
        source.getParent().requestSendAccessibilityEvent(source, event);
    }
}
