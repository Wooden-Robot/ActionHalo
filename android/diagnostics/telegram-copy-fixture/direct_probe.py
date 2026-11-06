#!/usr/bin/env python3
"""Real-touch 0.6.1 direct-circle probe; requires a prepared disposable fixture emulator."""
import argparse
import json
import math
import pathlib
import re
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET


DIRECT_TITLE = "ActionHalo Telegram actions"
ACTION_TITLE = "ActionHalo selected text action"
DIALOG_TITLE = "ActionHalo fixture focus dialog"
DEFAULT_ACTIONS = ("copy", "google", "translate", "open_url", "share", "baidu", "douban")


def window_bounds(windows, title):
    match = re.search(
        r"A11yWindow\[AccessibilityWindowInfo\[title=" + re.escape(title)
        + r"(?:,|\])[^\n]*?bounds=Rect\((-?\d+), (-?\d+) - (-?\d+), (-?\d+)\)", windows)
    return tuple(map(int, match.groups())) if match else None


def gta_copy_point(bounds, density):
    # Mirror RadialMenuView + RadialGeometry; config is checked before sending input.
    left, top, right, bottom = bounds
    diameter = min(int(400 * density), right - left - int(16 * density), bottom - top - int(16 * density))
    assert diameter > 0 and density > 0, "No usable circle geometry"
    outer = max(diameter / 2 - 60 * density, diameter * 0.25)
    radius = (outer + outer * 85 / 130) / 2
    angle = math.radians(-90 + (360 / len(DEFAULT_ACTIONS) - math.degrees(0.04)) / 2)
    return (round((left + right) / 2 + math.cos(angle) * radius),
            round((top + bottom) / 2 + math.sin(angle) * radius))


def check_preferences(actions_xml, settings_xml):
    actions = {item.get("name"): item for item in ET.fromstring(actions_xml)}
    settings = {item.get("name"): item for item in ET.fromstring(settings_xml)}
    for name in DEFAULT_ACTIONS:
        item = actions.get("enabled_" + name)
        assert item is None or (item.tag == "boolean" and item.get("value") == "true"), \
            "Require all seven default actions enabled; no input sent"
    custom = actions.get("custom_actions")
    assert custom is None or (custom.tag == "string" and json.loads(custom.text or "[]") == []), \
        "Require no custom actions; no input sent"
    gta = settings.get("gta_mode_enabled")
    assert gta is None or (gta.tag == "boolean" and gta.get("value") == "true"), \
        "Require GTA mode; no input sent"
    consent = settings.get("telegram_copy_popup_enabled")
    assert consent is not None and consent.tag == "boolean" and consent.get("value") == "true", \
        "Enable Telegram selection circle in ActionHalo first"


def counters(log):
    matches = re.findall(r"counters copy_calls=(\d+) writes=(\d+) translations=(\d+)", log)
    return tuple(map(int, matches[-1])) if matches else (0, 0, 0)


def focused_dialog(windows):
    return any("title=" + DIALOG_TITLE + "," in line and "type=TYPE_APPLICATION," in line
               and "focused=true," in line for line in windows.splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--mode", required=True, choices=(
        "partial", "nonfocusable", "animator-copy", "animator-copy-no-write", "animator-copy-menu-stale"))
    parser.add_argument("--scale", choices=("0", "1"), default="1")
    parser.add_argument("--cancel", action="store_true", help="Tap the circle center and require zero Copy calls")
    parser.add_argument("--dialog", action="store_true", help="Interrupt the visible circle with a small focused dialog")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--adb", default="/Users/woodenrobot/Library/Android/sdk/platform-tools/adb")
    args = parser.parse_args()
    if args.dialog and (args.mode != "animator-copy" or args.cancel):
        parser.error("--dialog requires --mode animator-copy without --cancel")

    def adb(*command):
        return subprocess.check_output([args.adb, "-s", args.serial, *command], text=True)

    def preferences(name):
        result = subprocess.run([args.adb, "-s", args.serial, "shell", "run-as", "com.actionhalo.android",
                                 "cat", "shared_prefs/" + name + ".xml"], capture_output=True, text=True)
        if result.returncode and "No such file or directory" in result.stderr + result.stdout:
            return "<map/>"
        assert result.returncode == 0, "Cannot inspect ActionHalo debug preferences"
        return result.stdout

    def log_for(pid):
        return adb("shell", "logcat", "-d", "--pid=" + pid, "-s", "TelegramCopyFixture:I", "*:S")

    def screenshot(name):
        (args.output / name).write_bytes(subprocess.check_output(
            [args.adb, "-s", args.serial, "exec-out", "screencap", "-p"]))

    assert re.fullmatch(r"emulator-\d+", args.serial), "A named disposable emulator is required"
    assert adb("shell", "getprop", "ro.kernel.qemu").strip() == "1", "Disposable emulator required"
    package = adb("shell", "dumpsys", "package", "org.telegram.messenger")
    assert "versionName=fixture-1" in package and "CopyFixtureActivity" in package, \
        "Install the synthetic fixture only; never use this probe with real Telegram"
    initial_windows = adb("shell", "dumpsys", "accessibility")
    assert any("Bound services:" in line and "label=ActionHalo" in line
               for line in initial_windows.splitlines()), "Enable ActionHalo service first"
    check_preferences(preferences("halo_actions"), preferences("actionhalo_settings"))
    density_values = re.findall(r"(?:Physical|Override) density: (\d+)", adb("shell", "wm", "density"))
    assert density_values, "Cannot determine display density"
    density = int(density_values[-1]) / 160
    assert "ClipboardHaloActivity" not in adb("shell", "dumpsys", "activity", "activities"), \
        "Close the legacy clipboard Activity before this direct-flow test"
    previous_scale = adb("shell", "settings", "get", "global", "animator_duration_scale").strip()
    args.output.mkdir(parents=True, exist_ok=True)
    started_at = adb("shell", "date", "'+%m-%d %H:%M:%S.000'").strip()
    try:
        adb("shell", "settings", "put", "global", "animator_duration_scale", args.scale)
        adb("shell", "am", "start", "-W", "-S", "-n", "org.telegram.messenger/.CopyFixtureActivity",
            "--es", "fixture_mode", args.mode)
        pid = adb("shell", "pidof", "org.telegram.messenger").strip()
        bounds = None
        stable_since = None
        stable_ms = 0
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            windows = adb("shell", "dumpsys", "accessibility")
            found = window_bounds(windows, DIRECT_TITLE)
            now = time.monotonic()
            if found is None or found != bounds:
                bounds = found
                stable_since = now if found else None
            elif stable_since is not None and now - stable_since >= 0.4:
                stable_ms = round((now - stable_since) * 1000)
                break
            time.sleep(0.1)
        (args.output / "windows-before.txt").write_text(windows)
        assert bounds and stable_ms >= 400, "Direct circle did not reach stable visible bounds"
        assert counters(log_for(pid)) == (0, 0, 0), "Circle appearance copied without an action selection"

        if args.dialog:
            adb("shell", "am", "start", "-W", "--activity-single-top", "-n",
                "org.telegram.messenger/.CopyFixtureActivity", "--ez", "show_focus_dialog", "true")
            deadline = time.monotonic() + 4
            dialog_stable_since = None
            dialog_stable_ms = 0
            while time.monotonic() < deadline:
                windows = adb("shell", "dumpsys", "accessibility")
                now = time.monotonic()
                if focused_dialog(windows) and window_bounds(windows, DIRECT_TITLE) == bounds:
                    dialog_stable_since = dialog_stable_since or now
                    if now - dialog_stable_since >= 0.4:
                        dialog_stable_ms = round((now - dialog_stable_since) * 1000)
                        break
                else:
                    dialog_stable_since = None
                time.sleep(0.1)
            (args.output / "windows-dialog.txt").write_text(windows)
            screenshot("screen-dialog.png")
            assert focused_dialog(windows), "The modal did not gain real application window focus"
            assert window_bounds(windows, DIRECT_TITLE) == bounds, "Circle disappeared during modal focus loss"
            assert dialog_stable_ms >= 400, "Circle did not remain stable while the modal held focus"
            assert counters(log_for(pid)) == (0, 0, 0), "Opening the modal unexpectedly called Copy"

        if args.mode == "animator-copy-menu-stale":
            deadline = time.monotonic() + 3
            while "seed_after_menu=true" not in log_for(pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            assert "seed_after_menu=true" in log_for(pid), "After-menu stale clipboard was not seeded"
            time.sleep(0.2)  # Exclude a timestamp tie with the explicit action's millisecond.

        left, top, right, bottom = bounds
        tap = (round((left + right) / 2), round((top + bottom) / 2)) if args.cancel else gta_copy_point(bounds, density)
        screenshot("screen-before.png")
        windows = adb("shell", "dumpsys", "accessibility")
        (args.output / "windows-before-input.txt").write_text(windows)
        actual_bounds = window_bounds(windows, DIRECT_TITLE)
        assert actual_bounds is not None, "Circle disappeared before input; no input sent"
        assert actual_bounds == bounds, f"Circle moved from {bounds} to {actual_bounds}; no input sent"
        check_preferences(preferences("halo_actions"), preferences("actionhalo_settings"))
        (args.output / "touch.json").write_text(json.dumps({
            "mode": args.mode, "action": "cancel" if args.cancel else "copy", "density": density,
            "default_actions": DEFAULT_ACTIONS, "window_title": DIRECT_TITLE,
            "stable_bounds": bounds, "bounds_stable_ms": stable_ms, "tap": tap, "tap_count": 1,
            "before_copy_calls": 0, "dialog": args.dialog,
        }, indent=2) + "\n")
        adb("shell", "input", "tap", *map(str, tap))

        if args.dialog:
            deadline = time.monotonic() + 0.7
            while time.monotonic() < deadline:
                windows = adb("shell", "dumpsys", "accessibility")
                assert focused_dialog(windows), "The modal lost focus before the deliberate dismissal"
                assert window_bounds(windows, DIRECT_TITLE) == bounds, "Pending circle was lost behind modal"
                assert counters(log_for(pid)) == (0, 0, 0), "Copy ran while its source was obscured by modal"
                time.sleep(0.1)
            (args.output / "windows-waiting-dialog.txt").write_text(windows)
            (args.output / "events-waiting-dialog.log").write_text(log_for(pid))
            adb("shell", "input", "keyevent", "4")

        observed_legacy = False
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            activities = adb("shell", "dumpsys", "activity", "activities")
            observed_legacy |= "ClipboardHaloActivity" in activities
            windows = adb("shell", "dumpsys", "accessibility")
            time.sleep(0.1)
        log = log_for(pid)
        (args.output / "events.log").write_text(log)
        (args.output / "activity-after.txt").write_text(activities)
        (args.output / "windows-after.txt").write_text(windows)
        screenshot("screen-after.png")
        launches = adb("shell", "logcat", "-d", "-T", shlex.quote(started_at), "-s", "ActivityTaskManager:I", "*:S")
        relevant_launches = "\n".join(line for line in launches.splitlines()
                                      if "ClipboardHaloActivity" in line or "CopyFixtureActivity" in line)
        (args.output / "activity-launches.log").write_text(relevant_launches + "\n")
        assert not observed_legacy and "ClipboardHaloActivity" not in relevant_launches, \
            "Direct action unexpectedly used the legacy Activity"
        assert not window_bounds(windows, DIRECT_TITLE) and not window_bounds(windows, ACTION_TITLE), \
            "Action did not finish, or a duplicate circle appeared"
        actual = counters(log)
        if args.dialog:
            assert "focus_dialog_dismissed=true" in log and not window_bounds(windows, DIALOG_TITLE), \
                "Back did not dismiss the temporary modal"
        if args.cancel:
            assert actual == (0, 0, 0), f"Cancel must not call Copy: {actual}"
            print("PASS: direct GTA circle appeared before Copy; center cancellation copied nothing")
            return

        negative = args.mode in ("animator-copy-no-write", "animator-copy-menu-stale")
        assert actual == (1, 0 if negative else 1, 0), f"Unexpected listener counts: {actual}"
        if args.mode.startswith("animator-copy"):
            assert "attached=false" in log and "click package=" not in log, \
                "Did not exercise the detached/no-click-event boundary"
        # A fresh Activity gets real focus before comparing the fixed Unicode sample.
        adb("shell", "am", "start", "-W", "-S", "-n", "org.telegram.messenger/.CopyFixtureActivity",
            "--es", "fixture_mode", "verify")
        verify_pid = adb("shell", "pidof", "org.telegram.messenger").strip()
        deadline = time.monotonic() + 4
        verification = ""
        while time.monotonic() < deadline:
            verification = log_for(verify_pid)
            if "verify exact_selected_fragment=" in verification and "actionhalo_label=" in verification:
                break
            time.sleep(0.1)
        (args.output / "verification.log").write_text(verification)
        expected = "false" if negative else "true"
        assert "verify exact_selected_fragment=" + expected in verification, "Wrong Unicode round-trip result"
        assert "actionhalo_label=" + expected in verification, \
            "ActionHalo Copy completion was not proved; rebuild fixture with the label-only verification"
        print(f"PASS: mode={args.mode} scale={args.scale}; direct GTA circle before Copy, one original Copy, "
              + ("stale clipboard rejected" if negative else "ActionHalo executed Copy with the exact Unicode fragment"))
    finally:
        if previous_scale == "null":
            adb("shell", "settings", "delete", "global", "animator_duration_scale")
        else:
            adb("shell", "settings", "put", "global", "animator_duration_scale", previous_scale)


if __name__ == "__main__":
    main()
