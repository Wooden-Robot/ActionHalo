#!/usr/bin/env python3
"""Real-touch copy probe for an already prepared, disposable fixture emulator only."""
import argparse
import json
import pathlib
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--serial", required=True)
parser.add_argument("--mode", choices=(
    "partial", "nonfocusable", "animator-copy", "animator-hide", "animator-dismiss",
    "animator-copy-no-write", "animator-copy-menu-stale",
), required=True)
parser.add_argument("--trigger", choices=("native", "helper"), default="native")
parser.add_argument("--scale", choices=("0", "1"), default="1")
parser.add_argument("--expect", choices=("halo", "detached", "rejected"), required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument("--adb", default="/Users/woodenrobot/Library/Android/sdk/platform-tools/adb")
args = parser.parse_args()


def adb(*command):
    return subprocess.check_output([args.adb, "-s", args.serial, *command], text=True)


def window_bounds(windows, title):
    match = re.search(
        r"A11yWindow\[AccessibilityWindowInfo\[title=" + re.escape(title)
        + r"(?:,|\])[^\n]*?bounds=Rect\((-?\d+), (-?\d+) - (-?\d+), (-?\d+)\)", windows)
    return tuple(map(int, match.groups())) if match else None


def top_activity(activities, name):
    return any("topResumedActivity=" in line and name in line for line in activities.splitlines())


def fixture_log(pid):
    return adb("shell", "logcat", "-d", "--pid=" + pid, "-s", "TelegramCopyFixture:I", "*:S")


assert adb("shell", "getprop", "ro.kernel.qemu").strip() == "1", "Disposable emulator required"
assert "SelectionAccessibilityService" in adb("shell", "dumpsys", "accessibility"), "Enable the test service first"
previous_scale = adb("shell", "settings", "get", "global", "animator_duration_scale").strip()
args.output.mkdir(parents=True, exist_ok=True)
try:
    adb("shell", "settings", "put", "global", "animator_duration_scale", args.scale)
    adb("shell", "am", "start", "-W", "-S", "-n", "org.telegram.messenger/.CopyFixtureActivity", "--es", "fixture_mode", args.mode)
    pid = adb("shell", "pidof", "org.telegram.messenger").strip()
    target_title = "ActionHalo Telegram copy" if args.trigger == "helper" else "Popup Window"
    bounds = None
    stable_bounds = None
    bounds_stable_since = None
    bounds_stable_ms = 0
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        windows = adb("shell", "dumpsys", "accessibility")
        bounds = window_bounds(windows, target_title)
        now = time.monotonic()
        if bounds is None or bounds != stable_bounds:
            stable_bounds = bounds
            bounds_stable_since = now if bounds else None
        elif bounds_stable_since is not None and now - bounds_stable_since >= 0.25:
            # A newly exposed helper can still be moving from its initial frame to
            # its final layout. Read stable geometry first, then allow input setup
            # to settle, and recheck instead of compensating with another tap.
            time.sleep(0.15)
            windows = adb("shell", "dumpsys", "accessibility")
            confirmed_bounds = window_bounds(windows, target_title)
            if confirmed_bounds == bounds:
                bounds_stable_ms = round((time.monotonic() - bounds_stable_since) * 1000)
                break
            stable_bounds = confirmed_bounds
            bounds = confirmed_bounds
            bounds_stable_since = time.monotonic() if bounds else None
        time.sleep(0.1)
    (args.output / "windows-before.txt").write_text(windows)
    assert bounds and bounds_stable_ms >= 250, f"Expected {target_title!r} window did not settle"

    if args.mode == "animator-copy-menu-stale":
        deadline = time.monotonic() + 3
        while "seed_after_menu=true" not in fixture_log(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        assert "seed_after_menu=true" in fixture_log(pid), "The after-menu stale clip was not seeded"
        # Ensure this timestamp cannot tie the helper's ACTION_CLICK request millisecond.
        time.sleep(0.2)

    left, top, right, bottom = bounds
    divisor = 3 if args.trigger == "helper" else 4
    tap_x, tap_y = left + (right - left) // divisor, (top + bottom) // 2
    (args.output / "screen-before.png").write_bytes(subprocess.check_output(
        [args.adb, "-s", args.serial, "exec-out", "screencap", "-p"]))
    windows = adb("shell", "dumpsys", "accessibility")
    (args.output / "windows-before.txt").write_text(windows)
    assert window_bounds(windows, target_title) == bounds, "Target moved before the single tap; no input was sent"
    (args.output / "touch.json").write_text(json.dumps({
        "trigger": args.trigger, "window_title": target_title,
        "stable_bounds": list(bounds), "bounds_stable_ms": bounds_stable_ms,
        "input_settle_delay_ms": 150, "tap": [tap_x, tap_y], "tap_count": 1,
    }, indent=2) + "\n")
    adb("shell", "input", "tap", str(tap_x), str(tap_y))
    shown = False
    stable_since = None
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        activities = adb("shell", "dumpsys", "activity", "activities")
        now = time.monotonic()
        if top_activity(activities, "ClipboardHaloActivity"):
            stable_since = stable_since or now
            if now - stable_since >= 0.6:
                shown = True
                if args.expect == "halo":
                    break
        else:
            stable_since = None
        time.sleep(0.1)

    log = fixture_log(pid)
    (args.output / "events.log").write_text(log)
    (args.output / "activity-after.txt").write_text(activities)
    (args.output / "windows-after.txt").write_text(adb("shell", "dumpsys", "accessibility"))
    (args.output / "screen-after.png").write_bytes(subprocess.check_output(
        [args.adb, "-s", args.serial, "exec-out", "screencap", "-p"]))
    counters = re.findall(r"counters copy_calls=(\d+) writes=(\d+) translations=(\d+)", log)
    assert counters, "Copy listener was not called; the intended control was not activated"
    copy_calls, writes, translations = map(int, counters[-1])
    assert copy_calls == 1 and translations == 0, f"Expected exactly one Copy call: {counters[-1]}"
    print(f"mode={args.mode} trigger={args.trigger} scale={args.scale} stable_halo={shown} "
          f"copy_calls={copy_calls} writes={writes}")
    if args.expect == "halo":
        assert shown and writes == 1, "Copy did not write once and produce a stable halo"
        if args.trigger == "helper":
            assert "act=com.actionhalo.android.TELEGRAM_COPY_ASSISTED " in activities, \
                "Expected the assisted request, not a duplicate native Copy request"
        if args.trigger == "native":
            assert "click package=" in log, "Native trigger did not produce the expected click event"
    elif args.expect == "detached":
        assert not shown and writes == 1 and "attached=false" in log and "click package=" not in log, \
            "Missing-copy-event boundary not reproduced"
    else:
        assert not shown and writes == 0 and top_activity(activities, "CopyFixtureActivity"), \
            "No-write Copy did not reject the stale clipboard and return to the fixture"
    if args.trigger == "helper" and args.mode.startswith("animator-copy"):
        assert "attached=false" in log and "click package=" not in log, \
            "Helper test did not exercise the known detached/no-click-event boundary"
    print("PASS: expected observation confirmed; exact halo text requires the documented round-trip check")
finally:
    if previous_scale == "null":
        adb("shell", "settings", "delete", "global", "animator_duration_scale")
    else:
        adb("shell", "settings", "put", "global", "animator_duration_scale", previous_scale)
