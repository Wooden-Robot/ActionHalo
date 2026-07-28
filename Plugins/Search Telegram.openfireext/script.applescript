use framework "AppKit"
use scripting additions

property NSPasteboard : a reference to current application's NSPasteboard
property NSPasteboardItem : a reference to current application's NSPasteboardItem
property NSMutableArray : a reference to current application's NSMutableArray

set envText to (system attribute "OPENFIRE_TEXT")

if envText is "" or envText is missing value then return

set maxLaunchAttempts to 50
set telegramWasRunning to false
set readyStreak to 0
set clipboardWasCaptured to false

try
    set oldClipboard to captureClipboardSnapshot()
    set clipboardWasCaptured to true
on error
    set clipboardWasCaptured to false
end try
if not clipboardWasCaptured then return

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

    tell application "System Events"
        tell process "Telegram"
            set frontmost to true
            set the clipboard to envText

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
    if clipboardWasCaptured then
        try
            restoreClipboardSnapshot(oldClipboard)
        end try
    end if
    error errorMessage number errorNumber
end try

if clipboardWasCaptured then restoreClipboardSnapshot(oldClipboard)

on captureClipboardSnapshot()
    set clipboardSnapshot to {}
    set pasteboardItems to NSPasteboard's generalPasteboard()'s pasteboardItems()

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

    return clipboardSnapshot
end captureClipboardSnapshot

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
