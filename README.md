# corne-v4-dev

Dev kit for a **foostan Corne v4.1 standard (3×6)** with custom Vial firmware (`vial_layers`): per-layer RGB while keeping Vial remapping and base-layer lighting from Vial’s Lighting tab (EEPROM).

| Piece | Location |
|-------|----------|
| Firmware source | Git submodule [`vial-qmk`](https://github.com/icalvo/vial-qmk) (fork of [vial-kb/vial-qmk](https://github.com/vial-kb/vial-qmk)), keymap `vial_layers` |
| Build | Docker (`Dockerfile` + `docker-compose.yml`) mounting that submodule |
| Rollback / flash assets | UF2s, flash dumps, `.vil`, `tools/` (picotool, Zadig) |

**10 Vial layers** (`DYNAMIC_KEYMAP_LAYER_COUNT 10`). Layer colors:

| Layer | Behavior |
|-------|----------|
| 0 Base | Vial Lighting (global EEPROM via Vial app) |
| 1–9 | Solid HSV from **user EEPROM** (defaults: green / orange / white / blue / cyan / magenta / yellow / red / pink) |

Change layers 1–9 **without reflashing** with the GUI (close Vial first):

```powershell
pip install -r tools/requirements-layer-rgb.txt
python tools/layer_rgb_tool.py
```

It loads EEPROM colors on start (layer 0 via Vial Lighting EEPROM; 1–9 via user EEPROM). Click a layer swatch, pick a color — the keyboard is updated and saved immediately. Layer 0 picks force **Solid Color** mode (same HSV store Vial uses).

Keymap / protocol live in the submodule:

`vial-qmk/keyboards/crkbd/keymaps/vial_layers/` (`keymap.c`, `layer_rgb.c`, HID cmd `0xFC`)

### Dual-hold Adjust (layers 6 / 7 / 8)

In addition to the usual QMK Tri Layer keys (`TL_LOWR` / `TL_UPPR` → layers **1** / **2**, both held → **3**), this keymap adds a second trio via `update_tri_layer_state` in `layer_state_set_user`:

| Hold | Result |
|------|--------|
| `MO(6)` | Layer 6 |
| `MO(7)` | Layer 7 |
| `MO(6)` **and** `MO(7)` | Layers 6 + 7 + **8** (Adjust) |

Assign `MO(6)` and `MO(7)` in Vial on the keys you want to dual-hold; put Adjust bindings on layer **8**. The two trios are independent — `TL_*` still drives 1/2/3 only.

Caveat: the hook turns layer **8** off whenever 6 and 7 are not both on, so `TG(8)` / `TO(8)` alone will not stay active.

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
2. Flashes **right** (hold **P**) then **left** (hold **Q**) into BOOTSEL
3. Prints reassembly steps

Stock Corne firmware clears EEPROM on Q/P-on-plug (Bootmagic). **`vial_layers` disables that wipe** so cased boards can still use Q/P without BOOT/RESET buttons. Flash this keymap once first; after that, Q/P is safe.

Builds pin a stable `VIAL_BUILD_ID` (`0xC7D845`). Optional `-PreserveEeprom` backups/restores the wear-leveling region via picotool (needs WinUSB on `RP2 Boot (Interface 1)` once — Zadig in `tools/`).

Useful flags:

```powershell
.\scripts\build-and-flash.ps1 -FlashOnly          # flash existing out\ UF2 only (alias: -SkipBuild)
.\scripts\build-and-flash.ps1 -TimeoutSec 600     # longer wait for RPI-RP2
.\scripts\build-and-flash.ps1 -PreserveEeprom     # picotool backup/restore EEPROM around each flash
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

Object files live in a **Docker volume** (`qmk-build` → `/qmk-build`), not on the Dropbox bind mount and not in ephemeral `/tmp`. The first compile is still slow (~20+ min over a synced path); later rebuilds are incremental and much faster. Wipe the cache if the build looks stale or corrupt:

```bash
docker compose run --rm qmk clean-build
```

If you only need to flash an existing UF2: `.\scripts\build-and-flash.ps1 -FlashOnly`.

---

## Bootloader

1. Unplug USB (prefer disconnecting TRRS too).
2. **Left:** hold **Q** while plugging USB → `RPI-RP2`.
3. **Right:** hold **P** while plugging USB.

With **`vial_layers`**, that does **not** clear EEPROM. Stock Corne / other keymaps still wipe on Q/P — intentional wipe: Vial reset / `EE_CLR`. Adjust layer also has `QK_BOOT` (Tab / Backspace) for a software jump while the board is running.

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

## Layer RGB GUI

Firmware stores HSV for layers **1–9** in the QMK user EEPROM datablock. Layer **0** still follows Vial Lighting.

`python tools/layer_rgb_tool.py` opens a small Tk GUI: reload from EEPROM, pick swatches (or a custom color). Each pick issues HID SET+SAVE so the change sticks without a separate save step.

- **Layer 0:** VIA/VialRGB lighting (`0x07`/`0x08`/`0x09`) — same store as Vial’s Lighting tab; swatch sets Solid Color + HSV
- **Layers 1–9:** custom HID `0xFC` user EEPROM

Requires the custom `vial_layers` UF2 and `hidapi`. Close the Vial app before running. First flash after an EEPROM layout version bump resets layer 1–9 colors to defaults (layer 0 lighting EEPROM is separate).

---

## Related repos

- Firmware fork: https://github.com/icalvo/vial-qmk  
- Upstream Vial QMK: https://github.com/vial-kb/vial-qmk  
