# Auf tty1 direkt in die Kiosk-Session starten
if [ -z "${DISPLAY}" ] && [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR:-0}" -eq 1 ]; then
  exec sway
fi
