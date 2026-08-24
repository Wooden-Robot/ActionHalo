#!/bin/bash
# A simple example shell script.
# Selected text is always available through ACTIONHALO_TEXT_FILE. ACTIONHALO_TEXT
# remains a convenience for small, NUL-free values.

{
    printf 'ActionHalo triggered this script!\n'
    printf 'Selected text was: '
    if [[ -n "${ACTIONHALO_TEXT_FILE:-}" && -r "$ACTIONHALO_TEXT_FILE" ]]; then
        cat -- "$ACTIONHALO_TEXT_FILE"
    else
        printf '%s' "${ACTIONHALO_TEXT:-}"
    fi
    printf '\n'
} >> "$HOME/Desktop/actionhalo.log"
