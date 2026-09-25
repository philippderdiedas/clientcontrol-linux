#!/usr/bin/env bash
# Haengt die netboot-Boot-Dateien als Assets an das Forgejo-Release des Tags.
# Wird aus .forgejo/workflows/build.yml aufgerufen; erwartet TOKEN, SERVER,
# REPO, TAG in der Umgebung. Braucht curl und jq.
#
# Idempotent: Release wird angelegt oder wiederverwendet, gleichnamige Assets
# werden vor dem Upload ersetzt, damit ein erneuter Lauf desselben Tags klappt.
set -euo pipefail

: "${TOKEN:?TOKEN fehlt}" "${SERVER:?SERVER fehlt}" "${REPO:?REPO fehlt}" "${TAG:?TAG fehlt}"

api="${SERVER%/}/api/v1/repos/${REPO}"
auth=(-H "Authorization: token ${TOKEN}")

files=(
    out/arch/boot/x86_64/vmlinuz-linux
    out/arch/boot/x86_64/initramfs-linux.img
    out/arch/x86_64/airootfs.sfs
    out/arch/x86_64/airootfs.sha512
)
for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "Artefakt fehlt: $f" >&2; exit 1; }
done

# Release anlegen; wenn es den Tag schon gibt, dessen id holen.
id="$(curl -fsS "${auth[@]}" -H 'Content-Type: application/json' \
        -d "{\"tag_name\":\"${TAG}\",\"name\":\"${TAG}\"}" \
        "${api}/releases" 2>/dev/null | jq -r '.id')" \
  || id="$(curl -fsS "${auth[@]}" "${api}/releases/tags/${TAG}" | jq -r '.id')"
[[ -n "$id" && "$id" != null ]] || { echo "keine Release-id fuer ${TAG}" >&2; exit 1; }
echo "Release ${TAG} (id ${id})"

for f in "${files[@]}"; do
    name="$(basename "$f")"
    old="$(curl -fsS "${auth[@]}" "${api}/releases/${id}/assets" \
            | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1)"
    if [[ -n "$old" && "$old" != null ]]; then
        curl -fsS "${auth[@]}" -X DELETE "${api}/releases/${id}/assets/${old}" >/dev/null
    fi
    echo "upload ${name}"
    curl -fsS "${auth[@]}" -F "attachment=@${f};filename=${name}" \
        "${api}/releases/${id}/assets?name=${name}" >/dev/null
done
echo "Fertig."
