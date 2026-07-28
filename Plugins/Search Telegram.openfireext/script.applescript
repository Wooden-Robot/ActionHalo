use framework "AppKit"
use scripting additions

property NSPasteboard : a reference to current application's NSPasteboard
property NSPasteboardItem : a reference to current application's NSPasteboardItem
property NSPasteboardTypeString : a reference to current application's NSPasteboardTypeString
property NSMutableArray : a reference to current application's NSMutableArray
property NSUUID : a reference to current application's NSUUID
property transactionMarkerType : "com.openfire.private.clipboard-transaction"

set envText to (system attribute "OPENFIRE_TEXT")

if envText is "" or envText is missing value then return

set maxLaunchAttempts to 50
set telegramWasRunning to false
set readyStreak to 0
set clipboardWasCaptured to false
set clipboardWasReplaced to false
set oldClipboard to {}
set oldClipboardChangeCount to missing value
set temporaryClipboardChangeCount to missing value
set transactionMarker to ((NSUUID's UUID()'s UUIDString()) as text)

try
    tell application "System Events"
        set telegramWasRunning to (exists process "Telegram")
    end tell

    tell application "Telegram"
        activate
    end tell

    tell application "System Events"
        repeat with attempt from 1 to maxLaunchAttempts
            if exists process "Telegram" then
                tell process "Telegram"
                    try
                        set frontmost to true
                    end try

                    if (exists window 1) then
                        try
                            if enabled of menu item "Global Search" of menu 1 of menu bar item "Edit" of menu bar 1 then
                                set readyStreak to readyStreak + 1
                            else
                                set readyStreak to 0
                            end if
                        on error
                            set readyStreak to 0
                        end try

                        if readyStreak ≥ 2 then exit repeat
                    else
                        set readyStreak to 0
                    end if
                end tell
            end if
            delay 0.1
        end repeat

        if not (exists process "Telegram") then error "Telegram process not found"
    end tell

    if telegramWasRunning then
        delay 0.1
    else
        delay 0.6
    end if

    -- Capture immediately before the temporary write. Capturing before Telegram
    -- launches leaves a multi-second window in which a user's new copy can be lost.
    set capturedClipboard to captureClipboardSnapshot()
    set oldClipboard to item 1 of capturedClipboard
    set oldClipboardChangeCount to item 2 of capturedClipboard
    set clipboardWasCaptured to true

    tell application "System Events"
        tell process "Telegram"
            set frontmost to true
            set temporaryClipboardChangeCount to my replaceClipboardWithText(envText, transactionMarker, oldClipboardChangeCount, oldClipboard)
            set clipboardWasReplaced to true

            click menu item "Global Search" of menu 1 of menu bar item "Edit" of menu bar 1
            delay 0.22

            keystroke "F" using {command down, shift down}
            delay 0.32

            try
                keystroke "a" using {command down}
                delay 0.05
                key code 51
                delay 0.05
            end try

            keystroke "v" using {command down}
        end tell
    end tell

    delay 0.2
on error errorMessage number errorNumber
    if clipboardWasCaptured and clipboardWasReplaced then
        try
            restoreClipboardSnapshotIfOwned(oldClipboard, temporaryClipboardChangeCount, transactionMarker)
        end try
    end if
    error errorMessage number errorNumber
end try

if clipboardWasCaptured and clipboardWasReplaced then
    restoreClipboardSnapshotIfOwned(oldClipboard, temporaryClipboardChangeCount, transactionMarker)
end if

on captureClipboardSnapshot()
    set clipboardSnapshot to {}
    set pasteboard to NSPasteboard's generalPasteboard()
    set initialChangeCount to (pasteboard's changeCount()) as integer
    set pasteboardItems to pasteboard's pasteboardItems()

    -- NSPasteboard returns nil when the clipboard has no items.
    if pasteboardItems is missing value then return {clipboardSnapshot, initialChangeCount}

    repeat with rawPasteboardItem in pasteboardItems
        set pasteboardItem to contents of rawPasteboardItem
        set itemSnapshot to {}

        repeat with rawPasteboardType in (pasteboardItem's types())
            set pasteboardType to contents of rawPasteboardType
            set itemData to pasteboardItem's dataForType:pasteboardType
            if itemData is missing value then error "Unable to capture every clipboard representation."
            set end of itemSnapshot to {pasteboardType, itemData}
        end repeat

        set end of clipboardSnapshot to itemSnapshot
    end repeat

    if ((pasteboard's changeCount()) as integer) is not initialChangeCount then
        error "The clipboard changed while it was being captured."
    end if
    return {clipboardSnapshot, initialChangeCount}
end captureClipboardSnapshot

on replaceClipboardWithText(newText, transactionMarker, expectedChangeCount, clipboardSnapshot)
    set pasteboard to NSPasteboard's generalPasteboard()
    if ((pasteboard's changeCount()) as integer) is not expectedChangeCount then
        error "The clipboard changed before OpenFire could use it."
    end if

    set temporaryItem to NSPasteboardItem's alloc()'s init()
    if not (temporaryItem's setString:newText forType:NSPasteboardTypeString) then
        error "Unable to prepare the temporary clipboard text."
    end if
    if not (temporaryItem's setString:transactionMarker forType:transactionMarkerType) then
        error "Unable to prepare the clipboard transaction marker."
    end if

    set temporaryItems to NSMutableArray's array()
    temporaryItems's addObject:temporaryItem
    pasteboard's clearContents()
    if not (pasteboard's writeObjects:temporaryItems) then
        try
            restoreClipboardSnapshot(clipboardSnapshot)
        end try
        error "Unable to write the temporary clipboard text."
    end if
    return (pasteboard's changeCount()) as integer
end replaceClipboardWithText

on restoreClipboardSnapshotIfOwned(clipboardSnapshot, expectedChangeCount, transactionMarker)
    if expectedChangeCount is missing value then return false

    set pasteboard to NSPasteboard's generalPasteboard()
    if ((pasteboard's changeCount()) as integer) is not expectedChangeCount then return false

    set pasteboardItems to pasteboard's pasteboardItems()
    if pasteboardItems is missing value then return false
    if ((pasteboardItems's |count|()) as integer) is not 1 then return false

    set temporaryItem to pasteboardItems's objectAtIndex:0
    set currentMarker to temporaryItem's stringForType:transactionMarkerType
    if currentMarker is missing value then return false
    if (currentMarker as text) is not transactionMarker then return false

    restoreClipboardSnapshot(clipboardSnapshot)
    return true
end restoreClipboardSnapshotIfOwned

on restoreClipboardSnapshot(clipboardSnapshot)
    set restoredItems to NSMutableArray's array()

    repeat with rawItemSnapshot in clipboardSnapshot
        set itemSnapshot to contents of rawItemSnapshot
        set restoredItem to NSPasteboardItem's alloc()'s init()

        repeat with rawTypeAndData in itemSnapshot
            set typeAndData to contents of rawTypeAndData
            set pasteboardType to item 1 of typeAndData
            set itemData to item 2 of typeAndData
            if not (restoredItem's setData:itemData forType:pasteboardType) then error "Unable to restore every clipboard representation."
        end repeat

        restoredItems's addObject:restoredItem
    end repeat

    set pasteboard to NSPasteboard's generalPasteboard()
    pasteboard's clearContents()
    if (restoredItems's |count|()) > 0 then
        if not (pasteboard's writeObjects:restoredItems) then error "Unable to restore the clipboard."
    end if
end restoreClipboardSnapshot
