# corne-v4-dev

Dev kit for a **foostan Corne v4.1 standard (3×6)** with custom Vial firmware (`vial_layers`): per-layer RGB while keeping Vial remapping and base-layer lighting from Vial’s Lighting tab (EEPROM).

| Piece | Location |
|-------|----------|
| Firmware source | Git submodule [`vial-qmk`](https://github.com/icalvo/vial-qmk) (fork of [vial-kb/vial-qmk](https://github.com/vial-kb/vial-qmk)), keymap `vial_layers` |
| Build | Docker (`Dockerfile` + `docker-compose.yml`) mounting that submodule |
| Rollback / flash assets | UF2s, flash dumps, `.vil`, `tools/` (picotool, Zadig) |

**8 Vial layers** (`DYNAMIC_KEYMAP_LAYER_COUNT 8`). Layer colors:

| Layer | Behavior |
|-------|----------|
| 0 Base | Vial Lighting (global EEPROM via Vial app) |
| 1–7 | Solid HSV from **user EEPROM** (defaults: green / orange / white / blue / cyan / magenta / yellow) |
| other | Purple (fixed) |

Change layers 1–7 **without reflashing** with `tools/layer_rgb_tool.py` (close Vial first):

```powershell
pip install -r tools/requirements-layer-rgb.txt
python tools/layer_rgb_tool.py list
python tools/layer_rgb_tool.py set 2 20 255 200 --save
```

Keymap / protocol live in the submodule:

`vial-qmk/keyboards/crkbd/keymaps/vial_layers/` (`layer_rgb.c`, HID cmd `0xFC`)

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

## Build + flash from Windows (recommended)

From PowerShell in this repo (Docker Desktop running, submodule initialized once):

```powershell
.\scripts\build-and-flash.ps1
```

That script:

1. Compiles via `docker compose run --rm qmk` → `out\crkbd_rev4_1_standard_vial_layers.uf2`
2. Tells you to enter bootloader on the **left** half (hold **Q** + plug USB) and waits for `RPI-RP2`
3. Copies the UF2, then repeats for the **right** half (hold **P**)
4. Prints reassembly steps (TRRS, USB, Vial)

Useful flags:

```powershell
.\scripts\build-and-flash.ps1 -SkipBuild          # flash existing out\ UF2 only
.\scripts\build-and-flash.ps1 -TimeoutSec 600     # longer wait for RPI-RP2
```

## Build with Docker only

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

Object files build under `/tmp/qmk-build` inside the container (avoids Dropbox locking `.build` on the host). Cold compiles are slower; the UF2 is still copied to `./out/`.

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
  tools/                    # picotool, Zadig, layer_rgb_tool.py
  *.uf2 / *.bin / *.vil     # rollback and reference firmware
  README.md
```

---

## Layer RGB CLI

Firmware stores HSV for layers **1–4** in the QMK user EEPROM datablock. Layer **0** still follows Vial Lighting.

| Command | Effect |
|---------|--------|
| `list` / `get N` | Read current RAM colors (layers 1–7) |
| `set N H S V` | Change color immediately (RAM) |
| `set … --save` / `save` | Persist to EEPROM |
| `load` | Reload EEPROM → RAM |

Requires the custom `vial_layers` UF2 (HID command `0xFC`). Close the Vial app before running the tool. First flash of this EEPROM layout resets layer colors to defaults (config version bump).

---

## Related repos

- Firmware fork: https://github.com/icalvo/vial-qmk  
- Upstream Vial QMK: https://github.com/vial-kb/vial-qmk  
