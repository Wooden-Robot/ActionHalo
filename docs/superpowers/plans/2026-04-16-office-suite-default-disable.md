# Office Suite Default Disable Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Default-disable OpenFire inside iWork, Microsoft Office, and WPS for both fresh installs and upgrades while preserving user opt-in changes after the migration runs once.

**Architecture:** Add a one-time startup migration in `AppDelegate` that merges a fixed office-suite bundle-id set into `ExcludedApps` and records a migration version marker. Keep runtime suppression logic unchanged so the existing status bar toggle and blacklist window remain the single source of truth.

**Tech Stack:** Swift, AppKit, UserDefaults, XCTest

---

### Task 1: Add The One-Time Office-App Migration

**Files:**
- Modify: `/Users/woodenrobot/code/github/OpenFire/Sources/App/App/AppDelegate.swift`

- [ ] **Step 1: Write the failing test**

Add coverage in `AppDelegateTests` for a helper that:
- returns the full office-suite bundle-id set on first migration
- merges into an existing exclusion list without duplicates
- does nothing after the migration marker is current

```swift
func testMigrateDefaultExcludedAppsAddsOfficeSuitesOnFirstRun() {
    let migrated = AppDelegate.migratedExcludedApps(
        existingExcludedApps: [],
        storedMigrationVersion: 0
    )

    XCTAssertEqual(Set(migrated.apps), Set(AppDelegate.defaultOfficeSuiteExcludedApps))
    XCTAssertEqual(migrated.newMigrationVersion, AppDelegate.defaultOfficeSuiteExcludedAppsMigrationVersion)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter 'AppDelegateTests'
```

Expected:
- FAIL because `migratedExcludedApps`, `defaultOfficeSuiteExcludedApps`, and the migration version constant do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add a small migration API in `AppDelegate` and call it during launch.

```swift
static let defaultOfficeSuiteExcludedAppsMigrationVersion = 1
static let defaultOfficeSuiteExcludedAppsMigrationKey = "DefaultOfficeAppsExcludedMigrationVersion"
static let defaultOfficeSuiteExcludedApps: [String] = [
    "com.apple.Pages",
    "com.apple.Numbers",
    "com.apple.Keynote",
    "com.apple.iWork.Pages",
    "com.apple.iWork.Numbers",
    "com.apple.iWork.Keynote",
    "com.microsoft.Word",
    "com.microsoft.Excel",
    "com.microsoft.Powerpoint",
    "com.kingsoft.wpsoffice.mac"
]

static func migratedExcludedApps(
    existingExcludedApps: [String],
    storedMigrationVersion: Int
) -> (apps: [String], newMigrationVersion: Int) {
    guard storedMigrationVersion < defaultOfficeSuiteExcludedAppsMigrationVersion else {
        return (existingExcludedApps, storedMigrationVersion)
    }

    var merged = existingExcludedApps
    for bundleID in defaultOfficeSuiteExcludedApps where !merged.contains(bundleID) {
        merged.append(bundleID)
    }
    return (merged, defaultOfficeSuiteExcludedAppsMigrationVersion)
}
```

Then call a small launch helper that reads/writes `ExcludedApps` and the migration marker.

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
swift test --filter 'AppDelegateTests'
```

Expected:
- PASS with the new migration tests green.

- [ ] **Step 5: Commit**

```bash
git add /Users/woodenrobot/code/github/OpenFire/Sources/App/App/AppDelegate.swift /Users/woodenrobot/code/github/OpenFire/Tests/OpenFireTests/AppDelegateTests.swift
git commit -m "Add office-suite default exclusion migration"
```

### Task 2: Cover Merge And Upgrade Edge Cases

**Files:**
- Modify: `/Users/woodenrobot/code/github/OpenFire/Tests/OpenFireTests/AppDelegateTests.swift`

- [ ] **Step 1: Write the failing test**

Add edge-case tests for:
- preserving unrelated exclusions
- no duplicate bundle ids
- not re-adding office apps after migration version is current

```swift
func testMigrateDefaultExcludedAppsDoesNotReAddAfterMigrationAlreadyRan() {
    let migrated = AppDelegate.migratedExcludedApps(
        existingExcludedApps: ["com.apple.Safari"],
        storedMigrationVersion: AppDelegate.defaultOfficeSuiteExcludedAppsMigrationVersion
    )

    XCTAssertEqual(migrated.apps, ["com.apple.Safari"])
    XCTAssertEqual(migrated.newMigrationVersion, AppDelegate.defaultOfficeSuiteExcludedAppsMigrationVersion)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter 'AppDelegateTests'
```

Expected:
- FAIL until the merge behavior and ordering/duplicate handling exactly match the new assertions.

- [ ] **Step 3: Write minimal implementation**

Keep the helper deterministic by:
- preserving existing order
- appending only missing office-suite bundle ids
- leaving the list untouched when the stored migration version is already current

```swift
for bundleID in defaultOfficeSuiteExcludedApps where !merged.contains(bundleID) {
    merged.append(bundleID)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
swift test --filter 'AppDelegateTests|TextSelectionMonitorTests'
```

Expected:
- PASS
- no regression in app suppression behavior

- [ ] **Step 5: Commit**

```bash
git add /Users/woodenrobot/code/github/OpenFire/Tests/OpenFireTests/AppDelegateTests.swift
git commit -m "Test office-suite exclusion migration edge cases"
```
