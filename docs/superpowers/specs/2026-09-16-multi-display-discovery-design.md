# Mehrere Monitore automatisch bespielen (Discovery im PXE-Image)

**Status:** Entwurf
**Datum:** 2026-09-16
**Betrifft:** kiosk-pxe (Image-Glue), nutzt miniclientcontrols Multi-Display-Feature

## Was und warum

miniclientcontrol kann jetzt mehrere Displays aus einem Prozess treiben (siehe
`miniclientcontrol/docs/superpowers/specs/2026-09-12-multi-display-design.md`).
Das Modell dort ist **deklariert, nicht entdeckt**: der Betrieb gibt
`--display <name>` pro Screen, und der Window-Manager (sway) platziert die
Fenster per `app_id`. Discovery wurde dort bewusst aus dem Controller
herausgehalten, weil Compositor-Wissen nicht in den Controller gehoert und das
Platzieren Sache des WM ist.

Das PXE-Image hat aber keine Per-Geraet-Config im Image (read-only, ein Image
fuer alle Geraete) - Per-Geraet-Zustand kommt vom USB-Datentraeger (Rotation,
SSH-Keys, Zeitzone). Es soll auf **beliebig viele Monitore** gehen, **ohne pro
Geraet** Display-Namen festzulegen.

Aufloesung: die Discovery gehoert nicht in miniclientcontrol (dort verworfen) und
nicht ins statische Image, sondern als **Glue in `kiosk-session`**, die beim
Session-Start die Outputs von sway erfragt und miniclientcontrol die passenden
`--display`-Flags mitgibt. miniclientcontrol bleibt deklariert; das Glue liefert
die Deklaration zur Laufzeit.

## Entscheidungen (abgestimmt)

1. **Displays sind unterscheidbar, eine Playlist je Monitor.** Der Operator
   ordnet im Admin pro Display eine Playlist zu (Foyer zeigt anderes als
   Werkstatt). Das braucht eine stabile Identitaet pro Monitor.

2. **Identitaet = sway-Connector** (`HDMI-A-1`, `DP-1`, `eDP-1`). Stabil solange
   die Verkabelung fix ist - Kiosk ist eine feste Installation. Zwei baugleiche
   Monitore kollidieren nicht (verschiedene Ports). Kabel umstecken verschiebt
   die Zuordnung; das ist der akzeptierte Preis. Das menschenlesbare Label
   (Foyer, Werkstatt) ist das `label`-Feld, das die `displays`-Tabelle schon hat,
   und wird im Admin einmal vergeben. Connector-Namen sind alphanumerisch plus
   `-`, also gueltige miniclientcontrol-Display-Namen ohne Sanitizing
   (`validate_display_name`).

3. **Nur beim Boot entdeckt, kein Hotplug.** Monitore muessen beim Boot
   angeschlossen sein. miniclientcontrol baut seine Display-Map einmal beim Start;
   ein spaeter angesteckter Monitor braucht einen Reboot. Passt zur festen
   Installation ("a third screen is a once-per-installation act").

4. **Ein-Monitor-Schwelle: bei genau einem Output bleibt das Legacy-Verhalten.**
   Bei genau einem aktiven Output startet `kiosk-session` miniclientcontrol
   **ohne** `--display`, exakt wie heute (implizites Display `default`, App-Modus
   moeglich). Erst ab **zwei** Outputs greift die Discovery mit
   `--display <connector>` je Output. Grund: bestehende Ein-Monitor-Kioske laufen
   unveraendert - der App-/Inset-Modus (Scheibe) setzt den `app_id` auf
   `chrome-…`, und die DB kennt das Display `default`. Wuerde man auch bei einem
   Monitor `--display HDMI-A-1` erzwingen, kippte der `app_id` auf
   `miniclientcontrol-HDMI-A-1` und die Inset-Regel sowie die DB-Identitaet
   braechen.

5. **App-/Inset-Modus bleibt Ein-Monitor-only.** Multi-Display nutzt das normale
   `--kiosk` (fullscreen je Output). Der Scheiben-/App-Modus-Hack ist ein
   Ein-Monitor-Sonderfall; die Faelle schliessen sich praktisch aus.

6. **Rotation und Inset bleiben Stick-Overrides.** `sway.d/*.conf` auf dem
   Datentraeger kann pro Connector drehen (`output HDMI-A-1 transform 90`),
   orthogonal zur Discovery. Wer Per-Monitor-Rotation will, benennt den Connector
   dort - das ist bewusst getrennt vom Discovery-Automatismus.

7. **`jq` kommt ins Image.** `swaymsg -t get_outputs` liefert JSON; im Image ist
   kein jq/python. Robustes Parsing (welcher Output ist aktiv) per `jq` statt
   fragilem bash/awk-JSON-Zerlegen. `jq` ist ~1 MB - bei einem Kiosk, der
   zuverlaessig booten muss, ist Robustheit den Platz wert. Aufnahme in
   `packages.x86_64`.

## Mechanik

`kiosk-session` bekommt vor dem `exec miniclientcontrol` einen Discovery-Block:

```
# Aktive Connector holen (sway liefert JSON, jq filtert die aktiven).
mapfile -t outputs < <(swaymsg -t get_outputs | jq -r '.[] | select(.active) | .name')

display_flags=()
if (( ${#outputs[@]} >= 2 )); then
    for out in "${outputs[@]}"; do
        display_flags+=(--display "${out}")
        # Regel muss stehen, bevor mc das Fenster oeffnet - sonst landet es
        # kurz auf dem falschen Output.
        swaymsg "for_window [app_id=\"miniclientcontrol-${out}\"] move container to output ${out}"
    done
fi
# Bei 0 oder 1 Output bleibt display_flags leer -> Legacy-Verhalten.

exec /usr/local/bin/miniclientcontrol \
    --assets-dir "${DATA}/assets" \
    --database-path "${DATA}/miniclient.db" \
    --chromium-arg=--no-sandbox \
    --chromium-arg=--ozone-platform=wayland \
    "${display_flags[@]}" \
    "${extra[@]}"
```

Ablauf: sway ist beim `exec kiosk-session` schon oben und kennt die Outputs.
Das Glue setzt pro Connector die `for_window`-Platzierungsregel, dann startet
miniclientcontrol mit einem `--display` je Connector. miniclientcontrol spawnt
je Display ein Chromium mit `app_id=miniclientcontrol-<connector>`; sway schiebt
jedes auf seinen Output, dort geht `--kiosk` fullscreen.

## Migration: Umstieg Ein-Monitor -> Mehr-Monitor

Ein bestehendes Geraet hat eine DB mit dem Display `default` und einer daran
zugeordneten Playlist. Beim ersten Multi-Boot deklariert das Glue die
Connector-Displays; miniclientcontrols `display::register` legt je Connector eine
neue `displays`-Zeile an (leere Playlist -> Idle-Screen). Die alte
`default`-Zeile bleibt bestehen, ungenutzt.

Der Operator ordnet die Playlist(s) den neuen Connector-Displays im Admin zu -
eine einmalige Aktion pro Geraet, genau die Zuordnung, fuer die
`displays.html` (Dropdown je Display) gebaut ist. Neue Geraete haben eine leere
DB und den Fall gar nicht.

**Keine automatische Uebernahme der `default`-Zuordnung.** Welcher Connector die
alte Playlist erben soll, kann das Glue nicht wissen (welcher Monitor ist "der
richtige"?), und ein geratenes Ergebnis waere schlechter als ein sichtbarer
Idle-Screen, der zur Zuordnung auffordert.

## Wechselwirkung mit den Stick-Overlays

- **Rotation/Inset** (`sway.d/*.conf`): laufen weiter. Bei mehreren Monitoren
  kann der Operator pro Connector drehen. Die globale `output * transform`-Form
  dreht weiterhin alle.
- **App-/Inset-Modus** (`miniclientcontrol.env`, `NO_KIOSK` + `--app`): bleibt
  Ein-Monitor-Sonderfall. Das Glue schaltet ihn bei mehreren Outputs nicht
  automatisch ab - noetig ist das nicht, weil "Scheibe vor dem Panel + mehrere
  Monitore" real nicht vorkommt. Dokumentieren, nicht erzwingen.

## Edge Cases

- **0 Outputs:** kann nicht auftreten, solange sway laeuft (mind. ein Output).
  Defensiv faellt der Block auf Legacy (kein `--display`).
- **1 Output:** Legacy, siehe Entscheidung 4.
- **Timing (Bau-/Testphase):** Sind beim `exec kiosk-session` schon alle Outputs
  aktiv? Bei mehreren Monitoren am selben Boot in der Regel ja (Enumeration vor
  `exec`). Ein langsam aufwachender Monitor faellt unter Boot-only: Reboot.
- **`--kiosk` vs. `move to output` (Bau-/Testphase):** landet jedes Fenster auf
  dem richtigen Output, bevor `--kiosk` es fullscreen macht? Die `for_window`-
  Regel greift beim Mappen des Fensters. Real auf einem Zwei-Output-Geraet zu
  pruefen (`.151` hat `HDMI-A-1` + `eDP-1`). Falls fullscreen dem Move zuvorkommt:
  Fallback ist, die Groesse/Position explizit in der `for_window`-Regel zu setzen
  statt `--kiosk` zu vertrauen.

## Nicht im Scope

- **Hotplug** (Entscheidung 3).
- **Per-Monitor-Rotation automatisch** - bleibt manueller Stick-Override.
- **Per-Display-Casting** - haengt an miniclientcontrol-Subprojekt 3, nicht an
  diesem Glue.
- **Automatische Playlist-Uebernahme** beim Umstieg (siehe Migration).

## Verifiziert (fuer dieses Design real geprueft, `.151`, sway 1.12)

- `swaymsg -t get_outputs` liefert je Output `name` (Connector) und `active`.
- `swaymsg 'for_window [app_id="…"] move container to output HDMI-A-1'` wird zur
  Laufzeit akzeptiert (`success`).
- Kein jq/python im Image (daher Entscheidung 7).

## Test

Real auf `.151` (zwei aktive Outputs, `HDMI-A-1` + `eDP-1`):

- Zwei Displays werden deklariert, je ein Chromium landet auf seinem Output und
  geht fullscreen.
- Die DB-Migration Ein-Monitor -> Zwei-Monitor durchspielen: neue
  Connector-Displays erscheinen, Playlist neu zuordenbar, alter `default`-Eintrag
  stoert nicht.
- Ein Output pro Reboot weniger/mehr: bei einem Output Legacy, bei zwei Discovery.
- `jq`-Parsing gegen die reale get_outputs-Ausgabe.
