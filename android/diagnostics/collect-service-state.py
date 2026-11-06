#!/usr/bin/env python3
"""Read-only, bounded ADB probe for one explicitly selected device and ActionHalo only.

No settings writes, install, force-stop, clipboard access, UI tree, or full log export.
Raw service lists and logcat are filtered in memory and never written to the report.
"""
import argparse
import datetime
import json
import re
import subprocess
import time
from pathlib import Path

PACKAGE = "com.actionhalo.android"
SERVICE = PACKAGE + ".SelectionAccessibilityService"
OPS = ("BIND_ACCESSIBILITY_SERVICE", "ACCESS_ACCESSIBILITY", "ACCESS_RESTRICTED_SETTINGS")
LOG_TAGS = ("AccessibilityManagerService", "AccessibilitySecurityPolicy",
            "AccessibilityServiceConnection", "ActivityManager", "EnhancedConfirmationService")


def own_component(value):
    parts = value.split("/")
    return len(parts) == 2 and parts[0] == PACKAGE and (
        parts[1] == SERVICE or parts[1] == ".SelectionAccessibilityService")


def enabled(raw):
    return any(own_component(item) for item in raw.strip().split(":"))


def service_lists(raw):
    # Dump formats vary by Android/OEM. Missing sections are unknown, never false.
    result = {}
    for kind in ("Enabled", "Bound", "Binding", "Crashed", "Installed"):
        section = re.search(r"(?im)^[ \t]*" + kind + r" services:[ \t]*([^\n]*)", raw)
        if not section or not section[1].strip():
            result[kind.lower()] = None
            continue
        components = re.findall(r"[\w.]+/[\w.$]+", section[1])
        own = any(own_component(item) for item in components)
        complete = section[1].strip().endswith(("}", "]"))
        result[kind.lower()] = own if own or complete else None
    return result


def operation_mode(raw, op):
    match = re.search(r"(?m)^\s*(?:android:)?" + re.escape(op) +
                      r":\s*(allow|ignore|deny|default|foreground|errored)\b", raw)
    if match:
        return match[1]
    if "No operations" in raw:
        return "not_recorded"
    return "unavailable"


def log_signals(raw):
    # Export known facts only, not log messages that might contain unrelated text.
    signals = []
    for line in raw.splitlines():
        if not re.search(re.escape(PACKAGE) + r"(?=[/\s:},]|$)", line):
            continue
        if "disallowed by AppOps" in line:
            signals.append("ACCESSIBILITY_BIND_DISALLOWED_BY_APPOPS")
        elif re.search(r"Force stopping\s+" + re.escape(PACKAGE) + r"\b", line):
            signals.append("PACKAGE_FORCE_STOP")
        elif "Skipping accessibility service" in line:
            signals.append("ACCESSIBILITY_SERVICE_SKIPPED")
    return sorted(set(signals))


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


def self_test():
    assert enabled(PACKAGE + "/.SelectionAccessibilityService")
    assert enabled(PACKAGE + "/" + SERVICE)
    assert not enabled(PACKAGE + ".other/" + SERVICE)
    assert not enabled("null")
    fixture = ("Enabled services:{" + PACKAGE + "/" + SERVICE + "}\n"
               "Bound services:{}\nInstalled services:\n  private.example/.SecretService")
    states = service_lists(fixture)
    assert states["enabled"] is True and states["bound"] is False
    assert states["installed"] is None and states["crashed"] is None
    assert operation_mode("BIND_ACCESSIBILITY_SERVICE: ignore; time=secret", OPS[0]) == "ignore"
    assert operation_mode("No operations.", OPS[0]) == "not_recorded"
    signals = log_signals("I/ActivityManager: Force stopping com.actionhalo.android appid=123 private-canary\n"
                          "I/AccessibilitySecurityPolicy: Skipping accessibility service "
                          "com.actionhalo.android/.SelectionAccessibilityService disallowed by AppOps\n"
                          "I/ActivityManager: Force stopping com.actionhalo.android.other private-canary")
    assert signals == ["ACCESSIBILITY_BIND_DISALLOWED_BY_APPOPS", "PACKAGE_FORCE_STOP"]
    assert "private" not in json.dumps([states, signals])
    print("PASS: exact component matching, unknown dump sections, AppOps modes, and content-free log signals")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", help="Exact device serial; never selects a device implicitly")
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--output", type=Path, default=Path("actionhalo-service-state.json"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.serial or not 5 <= args.seconds <= 120:
        parser.error("Provide --serial and a duration between 5 and 120 seconds")

    def adb(*command):
        try:
            result = subprocess.run([args.adb, "-s", args.serial, *command], capture_output=True,
                                    text=True, timeout=10, check=False)
            return result.stdout if result.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None

    if (adb("get-state") or "").strip() != "device":
        raise SystemExit("Selected device is unavailable or USB debugging has not been authorized")

    def app_ops():
        return {op: operation_mode(adb("shell", "cmd", "appops", "get", PACKAGE, op) or "", op)
                for op in OPS}

    report = {"started_at": stamp(), "duration_seconds": args.seconds,
              "app_ops_before": app_ops(), "states": [],
              "notes": ["Only ActionHalo metadata is exported; device serials and raw logs are omitted.",
                        "Log signals may predate this capture and are not proof of the setting writer.",
                        "No state writes or app lifecycle commands were performed."]}
    processes = {}
    previous = None
    deadline = time.monotonic() + args.seconds
    print("Recording read-only state. Enable ActionHalo once, keep the screen awake, then wait.", flush=True)
    try:
        while time.monotonic() < deadline:
            raw = adb("shell", "settings", "get", "secure", "enabled_accessibility_services")
            dump = adb("shell", "dumpsys", "accessibility")
            pid = (adb("shell", "pidof", PACKAGE) or "").strip()
            if pid and pid not in processes:
                processes[pid] = len(processes) + 1
            state = {"configured": enabled(raw) if raw is not None else None,
                     "service_lists": service_lists(dump) if dump is not None else None,
                     "process_generation": processes.get(pid)}
            if state != previous:
                report["states"].append({"at": stamp(), **state})
                previous = state
                print(json.dumps(report["states"][-1]), flush=True)
            time.sleep(0.5)
    finally:
        report["app_ops_after"] = app_ops()
        log = adb("logcat", "-d", "-v", "brief", "-t", "1500", "-s",
                  *(tag + ":I" for tag in LOG_TAGS), "*:S")
        report["system_log_signals"] = log_signals(log or "")
        report["finished_at"] = stamp()
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("Saved filtered report to " + str(args.output), flush=True)


if __name__ == "__main__":
    main()
