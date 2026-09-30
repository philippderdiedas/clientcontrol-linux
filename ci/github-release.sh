#!/usr/bin/env bash
# Haengt die netboot-Boot-Dateien als Assets an das GitHub-Release des Tags
# (Mirror github.com/philippderdiedas/clientcontrol-linux). Von dort laedt sie
# der initContainer im netbootxyz-Deployment (k8s-flux). Wird aus
# .forgejo/workflows/build.yml aufgerufen; erwartet GH_TOKEN, GH_REPO, TAG und
# SHA in der Umgebung. Braucht curl und jq.
#
# GH_TOKEN: fine-grained PAT, nur dieses Repo, Contents read/write.
#
# Idempotent wie release.sh: Release anlegen oder wiederverwenden, gleichnamige
# Assets vor dem Upload loeschen.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN fehlt}" "${GH_REPO:?GH_REPO fehlt}" "${TAG:?TAG fehlt}" "${SHA:?SHA fehlt}"

api="https://api.github.com/repos/${GH_REPO}"
uploads="https://uploads.github.com/repos/${GH_REPO}"
auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

files=(
    out/arch/boot/x86_64/vmlinuz-linux
    out/arch/boot/x86_64/initramfs-linux.img
    out/arch/x86_64/airootfs.sfs
    out/arch/x86_64/airootfs.sha512
)
for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "Artefakt fehlt: $f" >&2; exit 1; }
done

# Der Push-Mirror hat den Tag evtl. noch nicht nach GitHub gebracht. Dann legt
# GitHub ihn beim Release an - deshalb target_commitish, sonst zeigte er auf
# den HEAD des Default-Branches statt auf den gebauten Commit.
id="$(curl -fsS "${auth[@]}" "${api}/releases/tags/${TAG}" 2>/dev/null | jq -r '.id')" \
  || id="$(curl -fsS "${auth[@]}" \
        -d "$(jq -n --arg t "$TAG" --arg c "$SHA" '{tag_name:$t, name:$t, target_commitish:$c}')" \
        "${api}/releases" | jq -r '.id')"
[[ -n "$id" && "$id" != null ]] || { echo "keine Release-id fuer ${TAG}" >&2; exit 1; }
echo "GitHub-Release ${TAG} (id ${id})"

for f in "${files[@]}"; do
    name="$(basename "$f")"
    old="$(curl -fsS "${auth[@]}" "${api}/releases/${id}/assets?per_page=100" \
            | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1)"
    if [[ -n "$old" && "$old" != null ]]; then
        curl -fsS "${auth[@]}" -X DELETE "${api}/releases/assets/${old}" >/dev/null
    fi
    echo "upload ${name}"
    # -T streamt die Datei; --data-binary @ laese die 1-GB-sfs erst in den RAM.
    curl -fsS "${auth[@]}" -H "Content-Type: application/octet-stream" \
        -X POST -T "$f" "${uploads}/releases/${id}/assets?name=${name}" >/dev/null
done
echo "Fertig."
