#!/bin/bash
# A simple example shell script.
# Any text selected by the user is passed in the $OPENFIRE_TEXT environment variable.

echo "OpenFire triggered this script!" >> ~/Desktop/openfire.log
echo "Selected text was: $OPENFIRE_TEXT" >> ~/Desktop/openfire.log
