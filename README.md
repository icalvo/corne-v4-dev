# corne-v4-dev

Dev kit for a **foostan Corne v4.1 standard (3×6)** with custom Vial firmware (`vial_layers`): per-layer RGB while keeping Vial remapping and base-layer lighting from Vial’s Lighting tab (EEPROM).

| Piece | Location |
|-------|----------|
| Firmware source | Git submodule [`vial-qmk`](https://github.com/icalvo/vial-qmk) (fork of [vial-kb/vial-qmk](https://github.com/vial-kb/vial-qmk)), keymap `vial_layers` |
| Build | Docker (`Dockerfile` + `docker-compose.yml`) mounting that submodule |
| Rollback / flash assets | UF2s, flash dumps, `.vil`, `tools/` (picotool, Zadig) |

Layer colors (firmware; edit in the submodule):

| Layer | Behavior |
|-------|----------|
| 0 Base | Vial Lighting (`rgb_matrix_reload_from_eeprom`) |
| 1 Lower | Green |
| 2 Raise | Orange |
| 3 Adjust | White |
| 4 | Blue |
| other | Purple |

Keymap path in the submodule:

`vial-qmk/keyboards/crkbd/keymaps/vial_layers/`

---

## Clone

```bash
git clone --recurse-submodules https://github.com/icalvo/corne-v4-dev.git
cd corne-v4-dev
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

`vial-qmk` is large once lib/pico-sdk and friends are initialized; that is required for RP2040 builds.

---

## Build with Docker

Requires Docker Desktop (or equivalent) running.

```bash
# First time / after Dockerfile changes
docker compose build

# Compile crkbd/rev4_1/standard : vial_layers
docker compose run --rm qmk

# UF2 appears in ./out/
ls out/crkbd_rev4_1_standard_vial_layers.uf2
```

Interactive shell inside the image (submodule still mounted):

```bash
docker compose run --rm qmk shell
```

Override keyboard/keymap:

```bash
docker compose run --rm -e KEYBOARD=crkbd/rev4_1/standard -e KEYMAP=vial_layers qmk compile
```

### What the image provides

- Based on `qmkfm/qmk_cli`
- `PATH` includes the image’s `qmk` CLI
- Entrypoint mounts expectations: host `./vial-qmk` → `/workspace/vial-qmk`, `./out` → `/workspace/out`
- A small `git` wrapper so QMK version generation does not break when submodule `.git` gitdir paths are invalid inside the container (common with Docker Desktop bind mounts)

Edit firmware on the host (e.g. Windows Neovim on this repo). Rebuild with `docker compose run --rm qmk`.

First Docker compile over a Dropbox/synced path can be slow; later builds reuse object files in the mounted `vial-qmk/.build`.

---

## Bootloader (no case BOOT/RESET)

1. Unplug USB (prefer disconnecting TRRS too).
2. **Left:** hold **Q** while plugging USB → `RPI-RP2`.
3. **Right:** hold **P** while plugging USB.

Windows `picotool` needs **WinUSB** on `RP2 Boot (Interface 1)` once (Zadig in `tools/`). Drag-and-drop to `RPI-RP2` works without that.

---

## Flash

### Drag-and-drop

Copy `out/crkbd_rev4_1_standard_vial_layers.uf2` (or a file under this repo) onto `RPI-RP2`. Repeat for the other half (same UF2).

### picotool (Windows)

```powershell
$picotool = "$PWD\tools\picotool\picotool\picotool.exe"
$uf2 = "$PWD\out\crkbd_rev4_1_standard_vial_layers.uf2"
& $picotool info
& $picotool load -f $uf2
& $picotool reboot
```

---

## Rollback

Prefer exact pre-custom dumps:

- `dumped-current-firmware-left.uf2` / `dumped-current-firmware-right.uf2`  
  (on this board they were identical)

Or published foostan stock (not byte-identical to the dump):

- `crkbd_rev4_1_standard_vial.uf2`

Then in Vial: **File → Load from file…** → `corne-v4-layout-backup.vil`.

Full 2MB images: `dumped-flash-all-*.bin`.

---

## Repo layout

```text
corne-v4-dev/
  Dockerfile
  docker-compose.yml
  scripts/docker-entrypoint.sh
  vial-qmk/                 # submodule → icalvo/vial-qmk @ vial
  out/                      # gitignored build output
  tools/                    # picotool, Zadig
  *.uf2 / *.bin / *.vil     # rollback and reference firmware
  README.md
```

---

## Related repos

- Firmware fork: https://github.com/icalvo/vial-qmk  
- Upstream Vial QMK: https://github.com/vial-kb/vial-qmk  
