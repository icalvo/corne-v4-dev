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

# Bind-mounted git submodules often have broken .git gitdir paths inside Docker.
# QMK generate-version-h then prints git fatals on stdout and Make fails with
# "multiple target patterns". Wrap git so describe never poisons Make — do NOT
# delete the host-mounted .git directories.
mkdir -p /tmp/qmk-bin
cat > /tmp/qmk-bin/git << 'EOF'
#!/bin/bash
real_git=/usr/bin/git
if [[ ! -x "$real_git" ]]; then
  real_git=$(command -v -p git 2>/dev/null || true)
fi
# First-arg describe (what QMK version generation uses)
if [[ "${1:-}" == "describe" ]]; then
  echo "docker-build"
  exit 0
fi
# If the real git cannot run (broken gitdir), fail quietly on stdout
out="$("$real_git" "$@" 2>/dev/null)" && { printf '%s\n' "$out"; exit 0; }
exit 0
EOF
chmod +x /tmp/qmk-bin/git
export PATH="/tmp/qmk-bin:/opt/uv/tools/qmk/bin:${PATH}"

cmd="${1:-compile}"
shift || true

case "$cmd" in
  compile)
    # Keep object files off the host bind mount (Dropbox locks .td→.d renames).
    BUILD_DIR="${QMK_BUILD_DIR:-/tmp/qmk-build}"
    mkdir -p "$BUILD_DIR"
    echo "Compiling -kb $KB -km $KM (BUILD_DIR=$BUILD_DIR) ..."
    qmk compile -kb "$KB" -km "$KM" -e "BUILD_DIR=$BUILD_DIR" "$@"
    mkdir -p "$OUT"
    built="$BUILD_DIR/crkbd_rev4_1_standard_vial_layers.uf2"
    if [[ -f "$built" ]]; then
      cp -f "$built" "$OUT/"
      echo "Copied $built -> $OUT/"
    else
      echo "warning: expected UF2 not found at $built; listing $BUILD_DIR:" >&2
      ls -la "$BUILD_DIR"/*.uf2 2>/dev/null || true
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
