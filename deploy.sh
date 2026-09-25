#!/usr/bin/env sh
# Schiebt die netboot-Artefakte in den netbootxyz-Pod.
#
# Erwartet:
#   KUBE_NAMESPACE   Standard: netbootxyz
#   KUBE_SELECTOR    Standard: app.kubernetes.io/name=netbootxyz
#   ASSET_DIR        Standard: /assets/arch-kiosk
#   OUT_DIR          Standard: out
#   INSTALL_DIR      Standard: arch   (install_dir aus profiledef.sh)
#
# Zugangsdaten kommen ueber KUBECONFIG als GitLab-CI-File-Variable.

set -eu

NS="${KUBE_NAMESPACE:-netbootxyz}"
SEL="${KUBE_SELECTOR:-app.kubernetes.io/name=netbootxyz}"
ASSETS="${ASSET_DIR:-/assets/arch-kiosk}"
OUT="${OUT_DIR:-out}"
IDIR="${INSTALL_DIR:-arch}"

POD="${KUBE_POD:-$(kubectl -n "$NS" get pod -l "$SEL" \
        -o jsonpath='{.items[0].metadata.name}')}"
[ -n "$POD" ] || { echo "kein Pod gefunden (Selector: $SEL)" >&2; exit 1; }
echo "Ziel-Pod: $NS/$POD"

kern="$OUT/$IDIR/boot/x86_64/vmlinuz-linux"
init="$OUT/$IDIR/boot/x86_64/initramfs-linux.img"
sfs="$OUT/$IDIR/x86_64/airootfs.sfs"
sha="$OUT/$IDIR/x86_64/airootfs.sha512"
for f in "$kern" "$init" "$sfs" "$sha"; do
    [ -f "$f" ] || { echo "Artefakt fehlt: $f" >&2; exit 1; }
done

echo "Erstelle verzeichnisse im pod (falls missing)"
kubectl -n "$NS" exec "$POD" -- mkdir -p "$ASSETS/x86_64"

# Erst neben das Ziel legen, dann umbenennen. Ein halb uebertragenes initrd
# waere ein nicht bootender Kiosk.
echo "Kopiere vmlinuz"
kubectl -n "$NS" cp "$kern" "$POD:$ASSETS/vmlinuz.new"
echo "Kopiere initrd"
kubectl -n "$NS" cp "$init" "$POD:$ASSETS/initrd.new"
echo "Kopiere airootfs.sfs"
kubectl -n "$NS" cp "$sfs"  "$POD:$ASSETS/x86_64/airootfs.sfs.new"
echo "Kopiere airootfs.sha512"
kubectl -n "$NS" cp "$sha"  "$POD:$ASSETS/x86_64/airootfs.sha512.new"

# Pruefsummen vergleichen, bevor irgendwas aktiv wird.
echo "Prüfe checksums"
for pair in "vmlinuz.new:$kern" "initrd.new:$init" "x86_64/airootfs.sfs.new:$sfs" "x86_64/airootfs.sha512.new:$sha"; do
    remote="${pair%%:*}"; local_file="${pair#*:}"
    want="$(sha256sum "$local_file" | cut -d' ' -f1)"
    got="$(kubectl -n "$NS" exec "$POD" -- sha256sum "$ASSETS/$remote" | cut -d' ' -f1)"
    if [ "$want" != "$got" ]; then
        echo "sha256 stimmt nicht fuer $remote ($want != $got)" >&2
        kubectl -n "$NS" exec "$POD" -- rm -f "$ASSETS/$remote"
        exit 1
    fi
    echo "ok  $remote  $want"
done

# Atomar aktivieren und Ownership setzen - dnsmasq laeuft mit --tftp-secure
# und liefert nur Dateien des nbxyz-Users aus.
echo "Aktiviere dateien (mv)"
kubectl -n "$NS" exec "$POD" -- sh -c "
set -e
cd '$ASSETS'
mv vmlinuz.new vmlinuz
mv initrd.new initrd
mv x86_64/airootfs.sfs.new x86_64/airootfs.sfs
mv x86_64/airootfs.sha512.new x86_64/airootfs.sha512
chown -R nbxyz:nbxyz '$ASSETS'
ls -la '$ASSETS' '$ASSETS/x86_64'"
echo "Deploy fertig."
