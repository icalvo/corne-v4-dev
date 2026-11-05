#!/usr/bin/env bash
set -euo pipefail

VQ="${VIAL_QMK_DIR:-/workspace/vial-qmk}"
OUT="${OUT_DIR:-/workspace/out}"
KB="${KEYBOARD:-crkbd/rev4_1/standard}"
KM="${KEYMAP:-vial_layers}"

if [[ ! -d "$VQ" ]]; then
  echo "error: vial-qmk not mounted at $VQ" >&2
  echo "Run from corne-v4-dev with the submodule initialized, e.g.:" >&2
  echo "  git submodule update --init --recursive" >&2
  echo "  docker compose run --rm qmk" >&2
  exit 1
fi

if [[ ! -f "$VQ/Makefile" && ! -f "$VQ/builddefs/build_keyboard.mk" ]]; then
  echo "error: $VQ does not look like a vial-qmk checkout" >&2
  exit 1
fi

if [[ ! -d "$VQ/lib/pico-sdk/src" ]]; then
  echo "error: vial-qmk submodules missing (need lib/pico-sdk, etc.)." >&2
  echo "On the host, from corne-v4-dev:" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi

export PATH="/opt/uv/tools/qmk/bin:${PATH:-}"

cd "$VQ"

cmd="${1:-compile}"
shift || true

case "$cmd" in
  compile)
    echo "Compiling -kb $KB -km $KM ..."
    qmk compile -kb "$KB" -km "$KM" "$@"
    mkdir -p "$OUT"
    uf2=".build/$(echo "${KB}_${KM}" | tr '/' '_').uf2"
    # QMK names: crkbd_rev4_1_standard_vial_layers.uf2
    built=".build/crkbd_rev4_1_standard_vial_layers.uf2"
    if [[ -f "$built" ]]; then
      cp -f "$built" "$OUT/"
      echo "Copied $built -> $OUT/"
    else
      echo "warning: expected UF2 not found at $built; listing .build:" >&2
      ls -la .build/*.uf2 2>/dev/null || true
      exit 1
    fi
    ;;
  shell)
    exec bash -l
    ;;
  qmk)
    exec qmk "$@"
    ;;
  *)
    exec "$cmd" "$@"
    ;;
esac
