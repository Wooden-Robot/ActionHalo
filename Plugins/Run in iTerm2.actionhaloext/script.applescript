set commandText to (system attribute "ACTIONHALO_TEXT")

if commandText is "" or commandText is missing value then return

do shell script "/usr/bin/logger '[ActionHalo-Script] iTerm2 run start'"

tell application "iTerm2"
    activate
    delay 0.1
    try
        if (count of windows) = 0 then
            create window with default profile
        end if
    on error
        create window with default profile
    end try
    
    tell current window
        tell current session
            do shell script "/usr/bin/logger '[ActionHalo-Script] iTerm2 write text once'"
            write text commandText
        end tell
    end tell
end tell

do shell script "/usr/bin/logger '[ActionHalo-Script] iTerm2 run end'"
