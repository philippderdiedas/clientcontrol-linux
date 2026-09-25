#!/usr/bin/env bash
# Baut das Kiosk-Image. Zwei Schritte:
#   1. miniclientcontrol (Rust-Submodule) kompilieren und die Binary in
#      airootfs/usr/local/bin/ ablegen
#   2. mkarchiso laufen lassen
#
# Schritt 2 braucht root (pacstrap mountet /proc, /sys, /dev in den Chroot).
# Deshalb laeuft der Build auf einem host-Runner als root, nicht im Container -
# siehe .forgejo/workflows/build.yml.
#
# Umgebung:
#   BUILDMODE   netboot (Standard) | iso
#   WORK_DIR    Arbeitsverzeichnis, Standard: work
#   OUT_DIR     Ausgabeverzeichnis, Standard: out
#   SKIP_RUST   =1 ueberspringt den Rust-Build (nutzt eine vorhandene Binary)

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

BUILDMODE="${BUILDMODE:-netboot}"
WORK_DIR="${WORK_DIR:-work}"
OUT_DIR="${OUT_DIR:-out}"
SUBMODULE_DIR="miniclientcontrol"
BINARY_NAME="miniclientcontrol"
TARGET_PATH="airootfs/usr/local/bin/${BINARY_NAME}"

msg() { printf '\n==> %s\n' "$*"; }
die() { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }

# --- 1. Rust-Komponente ---------------------------------------------------

if [[ "${SKIP_RUST:-0}" != 1 ]]; then
    [[ -f "${SUBMODULE_DIR}/Cargo.toml" ]] ||
        die "${SUBMODULE_DIR}/Cargo.toml fehlt. Submodule initialisiert? git submodule update --init --recursive"

    msg "Baue ${BINARY_NAME} (release)"
    cargo build --release --locked --manifest-path "${SUBMODULE_DIR}/Cargo.toml"

    built="${SUBMODULE_DIR}/target/release/${BINARY_NAME}"
    if [[ ! -x "${built}" ]]; then
        printf 'Vorhandene Artefakte in %s/target/release:\n' "${SUBMODULE_DIR}" >&2
        find "${SUBMODULE_DIR}/target/release" -maxdepth 1 -type f -executable \
            -printf '  %f\n' 2>/dev/null >&2 || true
        die "${built} nicht gefunden - heisst die Binary anders? BINARY_NAME anpassen."
    fi

    msg "Kopiere Binary nach ${TARGET_PATH}"
    install -Dm755 -- "${built}" "${TARGET_PATH}"
    # Dynamisch gelinkte Binary braucht ihre Libs im Image. Statisch gebaut
    # (musl) ist es egal - hier nur melden, entschieden wird im Dockerfile.
    ldd "${TARGET_PATH}" 2>/dev/null | sed 's/^/    /' || true
else
    msg "SKIP_RUST=1, ueberspringe Rust-Build"
    [[ -x "${TARGET_PATH}" ]] || die "${TARGET_PATH} fehlt und SKIP_RUST=1 gesetzt"
fi

# --- 2. Image ------------------------------------------------------------

[[ "${EUID}" -eq 0 ]] || die "mkarchiso braucht root. Mit sudo aufrufen."

msg "mkarchiso -m ${BUILDMODE}"
rm -rf -- "${WORK_DIR}" "${OUT_DIR}"
mkarchiso -v -m "${BUILDMODE}" -w "${WORK_DIR}" -o "${OUT_DIR}" .

msg "Fertig. Ergebnis in ${OUT_DIR}/"
find "${OUT_DIR}" -type f -printf '%10s  %p\n' | sort -k2
