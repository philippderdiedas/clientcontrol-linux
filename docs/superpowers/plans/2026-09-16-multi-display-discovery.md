# Multi-Display-Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das PXE-Image bespielt beim Boot automatisch alle angeschlossenen Monitore, indem `kiosk-session` die aktiven sway-Outputs entdeckt und miniclientcontrol ein `--display` je Connector mitgibt.

**Architecture:** Ein kleines Filter-Script (`kiosk-discover-displays`) liest die `swaymsg -t get_outputs`-JSON und gibt die aktiven Connector aus — aber nur ab zwei Monitoren (darunter Legacy-Ein-Monitor-Pfad). `kiosk-session` baut daraus `--display`-Flags, setzt pro Connector eine sway-`for_window`-Platzierungsregel und startet miniclientcontrol. Platzierung bleibt sways Job (`app_id=miniclientcontrol-<connector>`).

**Tech Stack:** bash, jq, sway 1.12 (`swaymsg`), archiso, miniclientcontrol.

## Global Constraints

- Kein jq/python im Image bisher; `jq` wird als Paket aufgenommen (`packages.x86_64`).
- Connector-Namen (`HDMI-A-1`, `eDP-1`, `DP-1`) sind die Display-Identität — alphanumerisch plus `-`, gültige miniclientcontrol-Display-Namen, **kein Sanitizing**.
- **Ein-Monitor-Schwelle:** bei 0 oder 1 aktivem Output läuft miniclientcontrol **ohne** `--display` (Legacy, wie heute). Erst ab **2** greift Discovery.
- miniclientcontrol leitet aus `--display <name>` den `app_id=miniclientcontrol-<name>` ab; die sway-Regel muss darauf matchen.
- Kommentare deutsch (Repo-Konvention).
- Boot-only, kein Hotplug.
- `kiosk-session` läuft mit `set -euo pipefail`.
- Neue ausführbare Dateien brauchen einen `file_permissions`-Eintrag in `profiledef.sh` (`0:0:755`), sonst gehören sie im Image einer fremden UID.

---

### Task 1: jq ins Image aufnehmen

**Files:**
- Modify: `packages.x86_64`

**Interfaces:**
- Produces: `jq` ist im gebauten Image verfügbar (nutzen Task 2 und 3).

- [ ] **Step 1: jq in die Paketliste eintragen**

In `packages.x86_64`, in der Sektion der System-Werkzeuge (bei den anderen CLI-Tools), eine Zeile ergänzen. Falls eine passende Kategorie-Überschrift existiert, darunter; sonst ans Ende vor die Browser-Sektion. Genau eine Zeile:

```
jq
```

- [ ] **Step 2: Eintrag prüfen**

Run: `grep -n '^jq$' packages.x86_64`
Expected: genau eine Trefferzeile.

- [ ] **Step 3: Paket existiert im Arch-Repo (kein Tippfehler)**

Run: `pacman -Si jq >/dev/null 2>&1 && echo OK || echo FEHLT`
Expected: `OK` (jq ist im offiziellen `extra`-Repo).

- [ ] **Step 4: Commit**

```bash
git add packages.x86_64
git commit -m "jq ins Image aufnehmen (Multi-Display-Discovery braucht JSON-Parsing)"
```

---

### Task 2: Discovery-Filter `kiosk-discover-displays`

Kapselt die einzige nicht-triviale Entscheidung — die Ein-Monitor-Schwelle und den Aktiv-Filter — als eigenständiges stdin→stdout-Script, damit sie ohne sway und ohne `kiosk-session`-Sourcing testbar ist.

**Files:**
- Create: `airootfs/usr/local/bin/kiosk-discover-displays`
- Modify: `profiledef.sh` (file_permissions)
- Test: `tests/kiosk-discover-displays.test.sh`

**Interfaces:**
- Consumes: `swaymsg -t get_outputs`-JSON auf stdin.
- Produces: aktive Connector-Namen auf stdout, einer pro Zeile, **nur wenn ≥2 aktiv** sind; sonst leere Ausgabe. Exit 0 in beiden Fällen. `kiosk-session` (Task 3) liest das per `mapfile`.

- [ ] **Step 1: Test-Script schreiben (schlägt fehl, Script fehlt noch)**

Create `tests/kiosk-discover-displays.test.sh`:

```bash
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

# Zwei aktive Outputs -> beide Namen, eine Zeile pro Name.
check "zwei aktive" \
    '[{"name":"HDMI-A-1","active":true},{"name":"eDP-1","active":true}]' \
    $'HDMI-A-1\neDP-1'

# Ein aktiver Output -> leer (Legacy-Schwelle).
check "ein aktiver -> leer" \
    '[{"name":"eDP-1","active":true}]' \
    ''

# Inaktive werden gefiltert; bleibt einer aktiv -> leer.
check "inaktiver gefiltert" \
    '[{"name":"eDP-1","active":true},{"name":"HDMI-A-1","active":false}]' \
    ''

# Drei aktive -> alle drei.
check "drei aktive" \
    '[{"name":"DP-1","active":true},{"name":"DP-2","active":true},{"name":"HDMI-A-1","active":true}]' \
    $'DP-1\nDP-2\nHDMI-A-1'

# Zwei aktive, einer inaktiv dazwischen -> nur die zwei aktiven.
check "gemischt" \
    '[{"name":"DP-1","active":true},{"name":"DP-2","active":false},{"name":"HDMI-A-1","active":true}]' \
    $'DP-1\nHDMI-A-1'

# Leere Liste -> leer.
check "keine outputs" '[]' ''

if (( fails > 0 )); then
    printf '\n%d Test(s) fehlgeschlagen\n' "$fails"
    exit 1
fi
printf '\nalle Tests bestanden\n'
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `bash tests/kiosk-discover-displays.test.sh`
Expected: FAIL — das Script existiert noch nicht (`No such file or directory`, non-zero exit).

- [ ] **Step 3: Discovery-Filter schreiben**

Create `airootfs/usr/local/bin/kiosk-discover-displays`:

```bash
#!/usr/bin/env bash
# Liest die Ausgabe von "swaymsg -t get_outputs" (JSON) von stdin und gibt die
# aktiven Connector-Namen aus, einen pro Zeile - aber nur, wenn mindestens zwei
# aktiv sind. Bei 0 oder 1 aktivem Output bleibt die Ausgabe leer: das ist das
# Signal fuer den Legacy-Ein-Monitor-Pfad in kiosk-session, wo miniclientcontrol
# ohne --display startet und alles bleibt wie heute.
#
# Connector-Namen (HDMI-A-1, eDP-1, DP-1) sind zugleich die Display-Namen fuer
# miniclientcontrol. Sie sind alphanumerisch plus '-', also ohne Sanitizing
# gueltig.
set -euo pipefail

active="$(jq -r '.[] | select(.active) | .name')"

# Nicht-leere Zeilen zaehlen. Bei leerer Eingabe ist $active leer -> 0.
if [[ -z "${active}" ]]; then
    exit 0
fi
count="$(grep -c . <<<"${active}")"
if (( count >= 2 )); then
    printf '%s\n' "${active}"
fi
exit 0
```

- [ ] **Step 4: Ausführbar machen (für den lokalen Test)**

Run: `chmod +x airootfs/usr/local/bin/kiosk-discover-displays`
Expected: kein Output, Exit 0.

- [ ] **Step 5: Test laufen lassen, bestätigen dass er besteht**

Run: `bash tests/kiosk-discover-displays.test.sh`
Expected: `alle Tests bestanden`, Exit 0.

- [ ] **Step 6: Dateirechte in profiledef.sh eintragen**

In `profiledef.sh`, im `file_permissions`-Array, nach der Zeile für `kiosk-data-mount` eine Zeile ergänzen:

```bash
  ["/usr/local/bin/kiosk-discover-displays"]="0:0:755"
```

- [ ] **Step 7: Eintrag prüfen**

Run: `grep -n 'kiosk-discover-displays' profiledef.sh`
Expected: eine Zeile mit `="0:0:755"`.

- [ ] **Step 8: Commit**

```bash
git add airootfs/usr/local/bin/kiosk-discover-displays tests/kiosk-discover-displays.test.sh profiledef.sh
git commit -m "kiosk-discover-displays: aktive Connector ab zwei Monitoren, mit Test"
```

---

### Task 3: Discovery in kiosk-session einbauen

**Files:**
- Modify: `airootfs/usr/local/bin/kiosk-session`

**Interfaces:**
- Consumes: `kiosk-discover-displays` (Task 2) auf stdout die aktiven Connector.
- Produces: miniclientcontrol wird mit einem `--display <connector>` je Monitor gestartet (ab zwei), plus je Connector eine `for_window`-Platzierungsregel in sway.

- [ ] **Step 1: Discovery-Block vor dem `exec` einsetzen**

In `airootfs/usr/local/bin/kiosk-session`, unmittelbar **vor** dem abschließenden `exec /usr/local/bin/miniclientcontrol …`-Aufruf, diesen Block einfügen:

```bash
# --- Multi-Display-Discovery --------------------------------------------
# sway ist hier schon oben (kiosk-session laeuft aus der sway-Config per exec),
# also kennt es seine Outputs. kiosk-discover-displays gibt die aktiven Connector
# aus, aber nur ab zwei Monitoren - bei einem bleibt die Liste leer und
# miniclientcontrol startet ohne --display, exakt wie bisher (Legacy).
#
# Pro Connector wird VOR dem Start eine Platzierungsregel gesetzt: das Fenster
# mit app_id "miniclientcontrol-<connector>" (den app_id leitet
# miniclientcontrol aus dem Display-Namen ab) wandert auf genau diesen Output.
# Die Regel muss stehen, bevor miniclientcontrol das Fenster oeffnet, sonst
# erscheint es kurz auf dem falschen Monitor.
display_flags=()
mapfile -t kiosk_displays < <(swaymsg -t get_outputs | kiosk-discover-displays)
for out in "${kiosk_displays[@]}"; do
    display_flags+=(--display "${out}")
    swaymsg "for_window [app_id=\"miniclientcontrol-${out}\"] move container to output ${out}"
    log "Display ${out} deklariert und auf Output ${out} gebunden"
done
if (( ${#display_flags[@]} == 0 )); then
    log "ein Monitor oder keiner - Legacy-Start ohne --display"
fi
```

- [ ] **Step 2: Den `exec`-Aufruf um die Display-Flags erweitern**

Im selben File den `exec`-Aufruf so ändern, dass `"${display_flags[@]}"` vor `"${extra[@]}"` mitgegeben wird:

```bash
exec /usr/local/bin/miniclientcontrol \
    --assets-dir "${DATA}/assets" \
    --database-path "${DATA}/miniclient.db" \
    --chromium-arg=--no-sandbox \
    --chromium-arg=--ozone-platform=wayland \
    "${display_flags[@]}" \
    "${extra[@]}"
```

- [ ] **Step 3: bash-Syntax prüfen**

Run: `bash -n airootfs/usr/local/bin/kiosk-session && echo "SYNTAX OK"`
Expected: `SYNTAX OK`.

- [ ] **Step 4: Leere-Liste-Verhalten unter `set -u` absichern (Trockenlauf)**

`mapfile` in eine leere Liste und `"${display_flags[@]}"` bei leerem Array müssen unter `set -u` sauber sein. Verifizieren mit einem Mini-Trockenlauf:

```bash
bash -c 'set -euo pipefail; display_flags=(); mapfile -t x < <(printf ""); for o in "${x[@]:-}"; do :; done; echo "leer ok: [${display_flags[*]}]"'
```
Expected: `leer ok: []` (kein "unbound variable"-Fehler).

- [ ] **Step 5: Commit**

```bash
git add airootfs/usr/local/bin/kiosk-session
git commit -m "kiosk-session: Multi-Display-Discovery vor miniclientcontrol-Start"
```

---

### Task 4: Realer Boot-Test auf .151 (zwei Outputs) inkl. DB-Migration

`.151` hat zwei aktive Outputs (`HDMI-A-1` + `eDP-1`) und ist das reale Testgerät. Dieser Task baut, deployt und prüft am laufenden Gerät. Kein lokaler Unit-Test — die Deliverable ist ein Gerät, das zwei Chromium-Fenster korrekt platziert.

**Files:** keine (Verifikation am Gerät).

**Interfaces:**
- Consumes: die gebauten Änderungen aus Task 1–3.

- [ ] **Step 1: Image bauen (Rust überspringen, nur Image-Glue geändert)**

Run: `sudo SKIP_RUST=1 ./build.sh`
Expected: Build endet mit „Fertig. Ergebnis in out/", `jq` ist im Paketstand.

- [ ] **Step 2: Deployen**

Run: `./deploy.sh`
Expected: „Deploy fertig.", Prüfsummen ok.

- [ ] **Step 3: .151 rebooten**

```bash
timeout 20 ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_rsa.pub root@10.124.101.151 'systemctl reboot'
```
Expected: reboot ausgelöst; PXE-Boot dauert mehrere Minuten (langsam), danach per SSH wieder erreichbar.

- [ ] **Step 4: Zwei Displays deklariert, je ein Chromium pro Output**

Nach dem Boot per SSH (`-F /dev/null … -i ~/.ssh/id_rsa.pub root@10.124.101.151`):

```bash
export SWAYSOCK=$(ls -t /run/user/0/sway-ipc.* | head -1)
# Zwei miniclientcontrol-Fenster, je eines pro Output:
swaymsg -t get_tree | jq -r '.. | objects | select(.app_id? // "" | startswith("miniclientcontrol-")) | "\(.app_id) auf output \(.output // "?")"' 2>/dev/null \
  || swaymsg -t get_tree -r | grep -E '"app_id": "miniclientcontrol-'
# Prozesse: zwei Chromium mit unterschiedlicher --class:
ps -eo args | grep -o 'class=miniclientcontrol-[A-Za-z0-9-]*' | sort -u
```
Expected: zwei `app_id`s `miniclientcontrol-HDMI-A-1` und `miniclientcontrol-eDP-1`, jeder auf seinem Output; zwei Chromium-Klassen.

- [ ] **Step 5: `--kiosk` vs. `move to output` — Timing real prüfen**

Am Gerät sichtbar (oder über get_tree `rect`): landet jedes Fenster auf dem richtigen Output und ist fullscreen? Falls ein Fenster auf dem falschen Output fullscreen ging (Race), Fallback umsetzen: in Task 3 die `for_window`-Regel um explizite Position/Größe ergänzen statt `--kiosk` zu vertrauen, dann Task 4 wiederholen.

Run (Rechtecke der beiden Fenster):
```bash
swaymsg -t get_tree -r | grep -A6 '"app_id": "miniclientcontrol-' | grep -E '"(x|y|width|height)"'
```
Expected: zwei disjunkte Rechtecke, je eines die volle Fläche eines Outputs.

- [ ] **Step 6: DB-Migration Ein-Monitor → Zwei-Monitor durchspielen**

Auf `.151` existiert eine DB, die bisher das implizite Display `default` fuhr. Nach dem Multi-Boot legt miniclientcontrol die Connector-Displays an. Prüfen und Playlist neu zuordnen:

```bash
# Displays, die der Controller jetzt kennt:
curl -s http://127.0.0.1:3000/api/displays | jq .
```
Expected: Einträge für `HDMI-A-1` und `eDP-1` (neu, Playlist evtl. leer) neben ggf. altem `default`. Danach im Admin (oder per `PUT /api/displays/<name>`) je eine Playlist zuordnen und prüfen, dass der jeweilige Monitor sie zeigt statt Idle.

- [ ] **Step 7: Ein-Monitor-Legacy bleibt unberührt (Regressionsgedanke)**

Bestätigen, dass bei einem einzigen Output kein `--display` gesetzt würde — der Filter gibt bei einem aktiven Output leer aus (in Task 2 getestet). Am Zwei-Output-Gerät nicht direkt reproduzierbar; die Absicherung ist der Unit-Test aus Task 2. Notieren, dass ein echtes Ein-Monitor-Gerät weiterhin `default` fährt.

- [ ] **Step 8: Abschluss festhalten**

Kein Code-Commit (reiner Verifikationstask). Ergebnis der Timing-Prüfung (Step 5) und der Migration (Step 6) in der PR-/Commit-Beschreibung der Serie vermerken. Falls Step 5 den Fallback nötig machte, ist der zugehörige Commit in Task 3 entstanden.
