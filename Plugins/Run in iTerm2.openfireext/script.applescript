set commandText to (system attribute "OPENFIRE_TEXT")

if commandText is "" or commandText is missing value then return

tell application "iTerm2"
    activate
    try
        if (count of windows) = 0 then
            create window with default profile
        end if
    on error
        create window with default profile
    end try
    
    tell current window
        tell current session
            write text commandText
        end tell
    end tell
end tell
