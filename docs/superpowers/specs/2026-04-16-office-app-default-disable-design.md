# Office Suites Default Disable Design

## Goal

Make ActionHalo default to disabled inside major office suites while still letting users manually re-enable them later.

This applies to:

### Apple iWork

- `com.apple.Pages`
- `com.apple.Numbers`
- `com.apple.Keynote`
- `com.apple.iWork.Pages`
- `com.apple.iWork.Numbers`
- `com.apple.iWork.Keynote`

### Microsoft Office

- `com.microsoft.Word`
- `com.microsoft.Excel`
- `com.microsoft.Powerpoint`

### WPS Office

- `com.kingsoft.wpsoffice.mac`

## Current Behavior

ActionHalo already supports per-app suppression through `ExcludedApps`.

- The trigger path reads `ExcludedApps` and blocks automatic menu presentation when the frontmost app is in that list.
- The status bar menu already lets users toggle the current app between enabled and disabled.
- The blacklist window already shows and edits `ExcludedApps`.

That means the product already has the right control surface. The missing piece is only a default value strategy.

## Decision

Use a one-time startup migration that merges the office-suite bundle identifiers into `ExcludedApps`.

This migration must run for both:

- first-time users
- existing users upgrading to the version that introduces this behavior

It must not run on every launch forever.

## Required Behavior

### First Launch

If ActionHalo is launched on a machine that has no prior exclusion list, `ExcludedApps` should be initialized to include the office-suite bundle identifiers above.

Result:

- ActionHalo is disabled in iWork, Microsoft Office, and WPS document apps by default.
- The apps appear in the existing blacklist UI immediately.

### Existing Users Upgrading

When an existing user upgrades, the migration should merge the same office-suite bundle identifiers into the current `ExcludedApps` array if they are not already present.

Result:

- existing exclusions remain untouched
- office apps become disabled by default after upgrade

### User Re-Enable Must Be Respected

After the migration has run once, ActionHalo must never silently add those apps back again on later launches.

So if a user manually removes any of these apps from the blacklist, that choice must stick.

This is the key reason to use a migration marker instead of recomputing defaults every startup.

## Migration Shape

Add a dedicated migration marker in user defaults, separate from `ExcludedApps`.

Example shape:

- key: `DefaultOfficeAppsExcludedMigrationVersion`
- initial shipped value: `1`

Startup behavior:

1. Read the migration version key.
2. If the stored version is lower than `1`, merge the office-suite bundle identifiers into `ExcludedApps`.
3. Save the updated `ExcludedApps`.
4. Save migration version `1`.

If the stored version is already `1` or higher, do nothing.

This keeps the behavior deterministic and future-proof if another default exclusion migration is needed later.

## Implementation Boundary

The migration should live in startup code, not in the trigger path.

Recommended placement:

- add a small helper in `AppDelegate`
- call it during launch before normal interaction begins

The trigger path should keep doing what it already does today:

- read `ExcludedApps`
- suppress when the current bundle id is in that list

No special-case office-app logic should be added to `TextSelectionMonitor`.

## UI Impact

No new UI is needed.

Existing UI should remain the source of truth:

- status bar menu toggle for current app
- blacklist management window

Because the migration writes into `ExcludedApps`, the UI will automatically reflect the default-disabled state without any extra presentation code.

For WPS specifically, the current design treats the Mac app as a single suite host, so disabling its host bundle identifier is sufficient to cover Writer, Spreadsheet, and Presentation inside that app.

## Testing Requirements

Add coverage for the migration helper with these cases:

1. Fresh state:
   - no prior migration marker
   - no prior `ExcludedApps`
   - result includes all office-suite bundle identifiers

2. Existing user with custom exclusions:
   - existing unrelated app ids remain
   - office-suite bundle identifiers are merged in

3. Already migrated user:
   - rerunning the helper does not change `ExcludedApps`

4. User re-enabled one office app after migration:
   - helper does not re-add it on later launches once migration version is already current

5. Duplicate safety:
   - if one or more office bundle ids are already present, the merged result contains each only once

## Non-Goals

- Do not hardcode permanent office-app suppression in the runtime trigger logic.
- Do not add a second bundle-family-specific suppression path in `TextSelectionMonitor`.
- Do not create a second office-specific settings UI.
- Do not remove the user’s ability to manually re-enable these apps.

## Summary

The change should be implemented as a one-time migration into `ExcludedApps`, not as a permanent hardcoded blacklist.

That gives the desired product behavior:

- new users get iWork, Microsoft Office, and WPS disabled by default
- old users get the same default on upgrade
- users can still opt back in manually
- their opt-in is preserved afterward
