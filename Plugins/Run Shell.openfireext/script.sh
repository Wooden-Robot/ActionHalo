#!/bin/bash
# A simple example shell script.
# Selected text is always available through OPENFIRE_TEXT_FILE. OPENFIRE_TEXT
# remains a convenience for small, NUL-free values.

{
    printf 'OpenFire triggered this script!\n'
    printf 'Selected text was: '
    if [[ -n "${OPENFIRE_TEXT_FILE:-}" && -r "$OPENFIRE_TEXT_FILE" ]]; then
        cat -- "$OPENFIRE_TEXT_FILE"
    else
        printf '%s' "${OPENFIRE_TEXT:-}"
    fi
    printf '\n'
} >> "$HOME/Desktop/openfire.log"
