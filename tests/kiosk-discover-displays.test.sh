#!/usr/bin/env bash
# Testet airootfs/usr/local/bin/kiosk-discover-displays gegen Beispiel-JSON,
# wie es "swaymsg -t get_outputs" liefert. Braucht jq lokal.
set -uo pipefail

SCRIPT="$(dirname "$0")/../airootfs/usr/local/bin/kiosk-discover-displays"
fails=0

check() {
    local name="$1" json="$2" expected="$3" got
    got="$(printf '%s' "$json" | "$SCRIPT")"
    if [[ "$got" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"
    else
        printf 'FAIL: %s\n  erwartet: %q\n  bekommen: %q\n' "$name" "$expected" "$got"
        fails=$((fails + 1))
    fi
}

check "zwei aktive" \
    '[{"name":"HDMI-A-1","active":true},{"name":"eDP-1","active":true}]' \
    $'HDMI-A-1\neDP-1'

check "ein aktiver -> leer" \
    '[{"name":"eDP-1","active":true}]' \
    ''

check "inaktiver gefiltert" \
    '[{"name":"eDP-1","active":true},{"name":"HDMI-A-1","active":false}]' \
    ''

check "drei aktive" \
    '[{"name":"DP-1","active":true},{"name":"DP-2","active":true},{"name":"HDMI-A-1","active":true}]' \
    $'DP-1\nDP-2\nHDMI-A-1'

check "gemischt" \
    '[{"name":"DP-1","active":true},{"name":"DP-2","active":false},{"name":"HDMI-A-1","active":true}]' \
    $'DP-1\nHDMI-A-1'

check "keine outputs" '[]' ''

if (( fails > 0 )); then
    printf '\n%d Test(s) fehlgeschlagen\n' "$fails"
    exit 1
fi
printf '\nalle Tests bestanden\n'
