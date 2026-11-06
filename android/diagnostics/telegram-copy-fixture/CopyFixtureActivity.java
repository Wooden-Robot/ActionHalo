package org.telegram.messenger;

import android.app.Activity;
import android.app.AlertDialog;
import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityEvent;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.PopupWindow;
import android.widget.ScrollView;
import android.widget.TextView;

/** Standalone synthetic fixture. Never include this package in an ActionHalo release. */
public final class CopyFixtureActivity extends Activity {
    public static final String FRAGMENT = "中文 🚀 café — selected fragment";
    public static final String WHOLE_MESSAGE = "Unselected prefix | " + FRAGMENT + " | unselected suffix";
    private TextView status;
    private LinearLayout screen;
    private PopupWindow popup;
    private int copyCalls;
    private int writes;
    private int translations;
    private String pendingMode;
    private long seededAt;
    private boolean popupFocusable = true;
    private String animationMode;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        screen = new LinearLayout(this);
        screen.setOrientation(LinearLayout.VERTICAL);
        screen.setPadding(dp(20), dp(36), dp(20), dp(24));
        scroll.addView(screen);
        setContentView(scroll);
        text("Telegram copy fixture — synthetic data only", 21);
        text("Message: " + WHOLE_MESSAGE, 17);
        text("Selected fragment: " + FRAGMENT, 17);
        status = text("Writes=0; translations=0", 16);
        control("Open partial selection toolbar", () -> showToolbar(false, true, getString(android.R.string.copy)));
        control("Partial toolbar: 复制", () -> showToolbar(false, true, "复制"));
        control("Partial toolbar: 複製", () -> showToolbar(false, true, "複製"));
        control("Partial toolbar: 拷貝", () -> showToolbar(false, true, "拷貝"));
        control("Open whole-message menu (FrameLayout)", () -> showToolbar(true, true, "Copy"));
        control("Seed stale clipboard, then wait at least 3 seconds", this::seedStale);
        control("Open Copy without write toolbar", () -> showToolbar(false, false, "Copy"));
        control("Verify clipboard equals selected fragment", this::verifyFragment);
        pendingMode = getIntent().getStringExtra("fixture_mode");
    }

    @Override public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (!intent.getBooleanExtra("show_focus_dialog", false)) return;
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("ActionHalo fixture focus dialog")
                .setMessage("Temporary focus interruption")
                .setPositiveButton("Close", (ignored, which) -> {})
                .create();
        dialog.setOnDismissListener(ignored -> Log.i("TelegramCopyFixture", "focus_dialog_dismissed=true"));
        dialog.show();
        dialog.getWindow().setTitle("ActionHalo fixture focus dialog");
        dialog.getWindow().setLayout(dp(260), ViewGroup.LayoutParams.WRAP_CONTENT);
        Log.i("TelegramCopyFixture", "focus_dialog_shown=true");
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || pendingMode == null) return;
        String mode = pendingMode;
        pendingMode = null;
        animationMode = mode.startsWith("animator-") ? mode : null;
        popupFocusable = !"nonfocusable".equals(mode) && animationMode == null;
        screen.post(() -> {
            if ("seed".equals(mode)) seedStale();
            else if ("verify".equals(mode)) verifyFragment();
            else {
                if ("fresh-stale".equals(mode) || "animator-copy-no-write".equals(mode)) seedStale();
                showToolbar("frame".equals(mode), !"stale".equals(mode) && !"fresh-stale".equals(mode)
                                && !"animator-copy-no-write".equals(mode) && !"animator-copy-menu-stale".equals(mode),
                        getIntent().hasExtra("fixture_label") ? getIntent().getStringExtra("fixture_label") : getString(android.R.string.copy));
                if ("animator-copy-menu-stale".equals(mode)) {
                    // This clip deliberately postdates the menu, but predates the explicit
                    // helper click. Merely testing against menu time must not accept it.
                    screen.postDelayed(() -> {
                        seedStale();
                        Log.i("TelegramCopyFixture", "seed_after_menu=true");
                    }, 100);
                }
            }
        });
    }

    private TextView text(String value, int size) {
        TextView label = new TextView(this);
        label.setText(value);
        label.setTextSize(size);
        label.setTextColor(Color.BLACK);
        label.setPadding(0, dp(8), 0, dp(8));
        screen.addView(label, new LinearLayout.LayoutParams(-1, -2));
        return label;
    }

    private void control(String title, Runnable action) {
        Button button = new Button(this);
        button.setText(title);
        button.setAllCaps(false);
        button.setOnClickListener(view -> action.run());
        screen.addView(button, new LinearLayout.LayoutParams(-1, -2));
    }

    private void showToolbar(boolean frame, boolean write, String copyLabel) {
        if (popup != null) popup.dismiss();
        ObservedPanel panel = new ObservedPanel();
        panel.setOrientation(LinearLayout.HORIZONTAL);
        panel.setPadding(dp(12), dp(8), dp(12), dp(8));
        panel.setBackgroundColor(Color.WHITE);
        // Telegram FloatingToolbar defaults to a non-focusable PopupWindow. Retain the
        // old focused mode as a control so window tracking can be compared explicitly.
        popup = new PopupWindow(panel, -2, -2, popupFocusable);
        popup.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
        popup.setAnimationStyle(0);
        popup.setOutsideTouchable(true);
        popup.setElevation(dp(12));
        PopupWindow thisPopup = popup;
        panel.addView(menuButton(frame, copyLabel, () -> {
            copyCalls++;
            if (write) {
                ClipboardManager clipboard = getSystemService(ClipboardManager.class);
                clipboard.setPrimaryClip(ClipData.newPlainText("fixture", frame ? WHOLE_MESSAGE : FRAGMENT));
                writes++;
            }
            status.setText("Writes=" + writes + "; translations=" + translations + "; last=" + (write ? "copy wrote" : "copy without write"));
            logCounters();
            dismissAnimated(panel, thisPopup);
        }));
        panel.addView(menuButton(frame, "Translate", () -> {
            translations++;
            status.setText("Writes=" + writes + "; translations=" + translations + "; last=translate");
            logCounters();
            dismissAnimated(panel, thisPopup);
        }));
        popup.showAtLocation(screen, Gravity.CENTER, 0, 0);
    }

    private View menuButton(boolean frame, String title, Runnable action) {
        ViewGroup button = frame ? new FrameLayout(this) : new LinearLayout(this);
        button.setMinimumWidth(dp(110));
        button.setMinimumHeight(dp(56));
        button.setPadding(dp(16), 0, dp(16), 0);
        button.setBackgroundColor(0xffeeeeee);
        TextView label = new TextView(this);
        label.setText(title);
        label.setTextSize(18);
        label.setTextColor(Color.BLACK);
        label.setGravity(Gravity.CENTER);
        label.setSingleLine(true);
        label.setFocusable(false);
        label.setFocusableInTouchMode(false);
        label.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        button.addView(label, new ViewGroup.LayoutParams(-2, dp(56)));
        // Intentionally no ID, contentDescription, delegate, or custom accessibility event.
        button.setOnClickListener(view -> {
            Log.i("TelegramCopyFixture", "listener start mode=" + animationMode);
            action.run();
            Log.i("TelegramCopyFixture", "listener returned mode=" + animationMode
                    + " attached=" + view.isAttachedToWindow());
        });
        return button;
    }

    private void dismissAnimated(View panel, PopupWindow window) {
        if (animationMode != null) {
            if (animationMode.startsWith("animator-copy")) {
                // TextSelectionHelper.copyText(): hideActions() -> clear(true) ->
                // finish() -> dismiss(). FloatingToolbar.dismiss cancels its hide
                // animator, whose end listener also dismisses the PopupWindow.
                AnimatorSet hide = exitAnimation(panel, window, 0, false);
                hide.start();
                hide.cancel();
                exitAnimation(panel, window, 150, true).start();
            } else {
                exitAnimation(panel, window, "animator-dismiss".equals(animationMode) ? 150 : 0,
                        "animator-dismiss".equals(animationMode)).start();
            }
            return;
        }
        // Keep the popup attached through the click event. Telegram also dismisses at
        // animation completion, but its hide/dismiss AnimatorSet timings differ.
        panel.animate().alpha(0f).setDuration(150).withEndAction(window::dismiss).start();
    }

    private AnimatorSet exitAnimation(View panel, PopupWindow window, int delay, boolean removeViews) {
        AnimatorSet animation = new AnimatorSet();
        animation.playTogether(ObjectAnimator.ofFloat(panel, View.ALPHA, 1, 0).setDuration(100));
        animation.setStartDelay(delay);
        animation.addListener(new AnimatorListenerAdapter() {
            @Override public void onAnimationEnd(Animator animator) {
                Log.i("TelegramCopyFixture", "animator end mode=" + animationMode + " delay=" + delay);
                // NotificationCenter.doOnIdle runs inline when no other app animation is active.
                window.dismiss();
                if (removeViews) ((ViewGroup) panel).removeAllViews();
            }
        });
        return animation;
    }

    private void seedStale() {
        getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("fixture stale", "STALE synthetic clip"));
        seededAt = SystemClock.uptimeMillis();
        Log.i("TelegramCopyFixture", "seed uptime=" + seededAt);
        status.setText("Seeded stale synthetic clip; wait at least 3 seconds before Copy without write");
    }

    private void logCounters() {
        Log.i("TelegramCopyFixture", "counters copy_calls=" + copyCalls + " writes=" + writes
                + " translations=" + translations);
    }

    private void verifyFragment() {
        ClipData clip = getSystemService(ClipboardManager.class).getPrimaryClip();
        boolean exact = clip != null && clip.getItemCount() == 1 && FRAGMENT.contentEquals(
                clip.getItemAt(0).getText() == null ? "" : clip.getItemAt(0).getText());
        status.setText("Clipboard equals exact selected fragment=" + exact);
        Log.i("TelegramCopyFixture", "verify exact_selected_fragment=" + exact
                + " actionhalo_label=" + (clip != null && "ActionHalo".contentEquals(clip.getDescription().getLabel())));
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    /** Observes already-populated events without changing button event generation or delivery. */
    private final class ObservedPanel extends LinearLayout {
        ObservedPanel() { super(CopyFixtureActivity.this); }

        @Override public boolean onRequestSendAccessibilityEvent(View child, AccessibilityEvent event) {
            if (event.getEventType() == AccessibilityEvent.TYPE_VIEW_CLICKED) {
                String label = "other";
                if (event.getText().size() == 1) {
                    String candidate = event.getText().get(0).toString();
                    if (candidate.equals(getString(android.R.string.copy)) || candidate.equals("Copy") ||
                            candidate.equals("复制") || candidate.equals("複製") || candidate.equals("拷貝") || candidate.equals("Translate")) label = candidate;
                }
                Log.i("TelegramCopyFixture", "click package=" + event.getPackageName() + " class=" + event.getClassName()
                        + " label=" + label + " textCount=" + event.getText().size()
                        + " descriptionNull=" + (event.getContentDescription() == null) + " viewHasId=" + (child.getId() != View.NO_ID)
                        + " windowId=" + event.getWindowId()
                        + " hostWindowId=" + screen.createAccessibilityNodeInfo().getWindowId()
                        + " sinceSeedMs=" + (seededAt == 0 ? -1 : SystemClock.uptimeMillis() - seededAt));
            }
            return super.onRequestSendAccessibilityEvent(child, event);
        }
    }
}
