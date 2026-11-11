#!/usr/bin/env python3
"""GUI to edit Corne v4 vial_layers per-layer RGB colors over VIA raw HID.

Layer 0 uses VialRGB lighting EEPROM (same protocol as Vial's Lighting tab).
Layers 1-9 use the custom 0xFC user-EEPROM protocol.

Loads colors on start; picking a swatch writes SET+SAVE immediately.

Close Vial first — it holds the raw HID interface.

  pip install -r tools/requirements-layer-rgb.txt
  python tools/layer_rgb_tool.py
"""

from __future__ import annotations

import colorsys
import sys
import time
import tkinter as tk
from tkinter import colorchooser, messagebox, ttk

try:
    import hid
except ImportError:
    print("Missing dependency: pip install hidapi", file=sys.stderr)
    sys.exit(1)

VID = 0x4653
PID = 0x0004
USAGE_PAGE = 0xFF60
REPORT_LEN = 32

# Custom layer-color protocol (layers 1-9)
CMD = 0xFC
SUB_GET = 0x01
SUB_SET = 0x02
SUB_SAVE = 0x03
SUB_LOAD = 0x04

# VIA / VialRGB lighting (layer 0 / base)
ID_LIGHTING_SET = 0x07
ID_LIGHTING_GET = 0x08
ID_LIGHTING_SAVE = 0x09
VIALRGB_GET_MODE = 0x41
VIALRGB_SET_MODE = 0x41
VIALRGB_EFFECT_OFF = 0
VIALRGB_EFFECT_SOLID_COLOR = 2  # enum: OFF=0, DIRECT=1, SOLID_COLOR=2

LAYER_FIRST = 0
LAYER_LAST = 9

LAYER_NAMES = {
    0: "Base (Vial)",
    1: "Lower",
    2: "Raise",
    3: "Adjust",
    4: "Layer 4",
    5: "Layer 5",
    6: "Layer 6",
    7: "Layer 7",
    8: "Layer 8",
    9: "Layer 9",
}

SWATCHES: list[tuple[str, str]] = [
    ("Red", "#ff0000"),
    ("Orange", "#ff8000"),
    ("Yellow", "#ffff00"),
    ("Lime", "#80ff00"),
    ("Green", "#00ff00"),
    ("Teal", "#00ff80"),
    ("Cyan", "#00ffff"),
    ("Azure", "#0080ff"),
    ("Blue", "#0000ff"),
    ("Purple", "#8000ff"),
    ("Magenta", "#ff00ff"),
    ("Pink", "#ff0080"),
    ("White", "#ffffff"),
    ("Warm white", "#fff2e0"),
    ("Soft gray", "#c0c0c0"),
    ("Dim", "#404040"),
]


def rgb_to_qmk_hsv(r: int, g: int, b: int) -> tuple[int, int, int]:
    h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
    return int(round(h * 255)), int(round(s * 255)), int(round(v * 255))


def qmk_hsv_to_rgb(h: int, s: int, v: int) -> tuple[int, int, int]:
    r, g, b = colorsys.hsv_to_rgb(h / 255.0, s / 255.0, v / 255.0)
    return int(round(r * 255)), int(round(g * 255)), int(round(b * 255))


def hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    h = hex_color.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def rgb_to_hex(r: int, g: int, b: int) -> str:
    return f"#{r:02x}{g:02x}{b:02x}"


class LayerRgbHid:
    def __init__(self) -> None:
        self._dev: hid.device | None = None
        self._base_speed = 128

    def open(self) -> None:
        self.close()
        path = None
        for d in hid.enumerate(VID, PID):
            if d.get("usage_page") == USAGE_PAGE:
                path = d["path"]
                break
        if path is None:
            for d in hid.enumerate(VID, PID):
                path = d["path"]
                break
        if path is None:
            raise RuntimeError(
                f"No Corne Vial device found (VID={VID:#06x} PID={PID:#06x}). "
                "Plug in the keyboard and close the Vial app."
            )
        dev = hid.device()
        dev.open_path(path)
        self._dev = dev

    def close(self) -> None:
        if self._dev is not None:
            try:
                self._dev.close()
            except Exception:
                pass
            self._dev = None

    def _transact(self, payload: list[int], retries: int = 3) -> list[int]:
        if self._dev is None:
            raise RuntimeError("Device not open")
        buf = bytearray(REPORT_LEN)
        for i, b in enumerate(payload[:REPORT_LEN]):
            buf[i] = b & 0xFF
        out = b"\x00" + bytes(buf)
        last_err: Exception | None = None
        for _ in range(retries):
            try:
                self._dev.write(out)
                time.sleep(0.02)
                raw = self._dev.read(REPORT_LEN + 1, timeout_ms=1000)
                if not raw:
                    continue
                data = list(raw)
                if len(data) == REPORT_LEN + 1:
                    data = data[1:]
                return data
            except OSError as e:
                last_err = e
                time.sleep(0.05)
        raise RuntimeError(f"HID transfer failed: {last_err}")

    # --- layers 1-7 (custom 0xFC) ---

    def _custom_get(self, layer: int) -> tuple[int, int, int]:
        resp = self._transact([CMD, SUB_GET, layer, 0, 0, 0])
        if resp[0] != CMD or resp[1] == 0xFF:
            raise RuntimeError(f"get failed for layer {layer} (custom firmware flashed?)")
        return resp[3], resp[4], resp[5]

    def _custom_set_and_save(self, layer: int, h: int, s: int, v: int) -> None:
        resp = self._transact([CMD, SUB_SET, layer, h, s, v])
        if resp[0] != CMD or resp[1] != SUB_SET:
            raise RuntimeError(f"set failed for layer {layer}")
        resp = self._transact([CMD, SUB_SAVE, 0, 0, 0, 0])
        if resp[0] != CMD or resp[1] != SUB_SAVE:
            raise RuntimeError("save failed")

    def _custom_load(self) -> None:
        resp = self._transact([CMD, SUB_LOAD, 0, 0, 0, 0])
        if resp[0] != CMD or resp[1] != SUB_LOAD:
            raise RuntimeError("load failed")

    # --- layer 0 (VialRGB lighting EEPROM) ---

    def _lighting_get(self) -> tuple[int, int, int, int, int]:
        """Return (vialrgb_mode, speed, h, s, v)."""
        resp = self._transact([ID_LIGHTING_GET, VIALRGB_GET_MODE, 0, 0, 0, 0, 0, 0])
        if resp[0] != ID_LIGHTING_GET:
            raise RuntimeError("lighting get failed (VialRGB enabled?)")
        mode = resp[2] | (resp[3] << 8)
        speed = resp[4]
        h, s, v = resp[5], resp[6], resp[7]
        return mode, speed, h, s, v

    def _lighting_set_and_save(self, mode: int, speed: int, h: int, s: int, v: int) -> None:
        resp = self._transact(
            [
                ID_LIGHTING_SET,
                VIALRGB_SET_MODE,
                mode & 0xFF,
                (mode >> 8) & 0xFF,
                speed & 0xFF,
                h & 0xFF,
                s & 0xFF,
                v & 0xFF,
            ]
        )
        if resp[0] != ID_LIGHTING_SET:
            raise RuntimeError("lighting set failed")
        resp = self._transact([ID_LIGHTING_SAVE, 0, 0, 0, 0, 0])
        if resp[0] != ID_LIGHTING_SAVE:
            raise RuntimeError("lighting save failed")

    # --- unified API ---

    def get_base(self) -> tuple[int, int, int, int, int]:
        """Layer 0: (vialrgb_mode, speed, h, s, v) from Vial Lighting EEPROM."""
        mode, speed, h, s, v = self._lighting_get()
        self._base_speed = speed
        return mode, speed, h, s, v

    def get(self, layer: int) -> tuple[int, int, int]:
        if layer == 0:
            mode, _speed, h, s, v = self.get_base()
            if mode == VIALRGB_EFFECT_OFF:
                return 0, 0, 0
            return h, s, v
        return self._custom_get(layer)

    def set_and_save(self, layer: int, h: int, s: int, v: int) -> None:
        if layer == 0:
            # Match Vial solid-color lighting; keep current animation speed.
            self._lighting_set_and_save(VIALRGB_EFFECT_SOLID_COLOR, self._base_speed, h, s, v)
            return
        self._custom_set_and_save(layer, h, s, v)

    def load_all(self) -> None:
        """Refresh layer 1-7 RAM from user EEPROM (layer 0 is read via lighting get)."""
        self._custom_load()


class SwatchPicker(tk.Toplevel):
    def __init__(self, master: tk.Misc, title: str, on_pick) -> None:
        super().__init__(master)
        self.title(title)
        self.resizable(False, False)
        self.transient(master)
        self.grab_set()
        self._on_pick = on_pick

        frame = ttk.Frame(self, padding=10)
        frame.grid(row=0, column=0, sticky="nsew")

        ttk.Label(frame, text="Click a swatch (applies immediately):").grid(
            row=0, column=0, columnspan=4, sticky="w", pady=(0, 8)
        )

        for i, (name, hex_color) in enumerate(SWATCHES):
            r, c = divmod(i, 4)
            self._swatch_button(frame, name, hex_color).grid(
                row=r + 1, column=c, padx=4, pady=4, sticky="nsew"
            )

        ttk.Button(frame, text="Custom color…", command=self._custom).grid(
            row=6, column=0, columnspan=2, sticky="ew", pady=(10, 0), padx=4
        )
        ttk.Button(frame, text="Cancel", command=self.destroy).grid(
            row=6, column=2, columnspan=2, sticky="ew", pady=(10, 0), padx=4
        )

        self.bind("<Escape>", lambda _e: self.destroy())
        self.after(10, self._center_on_parent)

    def _center_on_parent(self) -> None:
        self.update_idletasks()
        px = self.master.winfo_rootx()
        py = self.master.winfo_rooty()
        pw = self.master.winfo_width()
        ph = self.master.winfo_height()
        w = self.winfo_width()
        h = self.winfo_height()
        self.geometry(f"+{px + (pw - w) // 2}+{py + (ph - h) // 2}")

    def _swatch_button(self, parent: ttk.Frame, name: str, hex_color: str) -> ttk.Frame:
        wrap = ttk.Frame(parent)
        btn = tk.Button(
            wrap,
            text="",
            width=6,
            height=2,
            bg=hex_color,
            activebackground=hex_color,
            relief=tk.GROOVE,
            bd=2,
            cursor="hand2",
            command=lambda hc=hex_color: self._choose(hc),
        )
        btn.pack(fill=tk.X)
        ttk.Label(wrap, text=name, anchor="center").pack(fill=tk.X)
        return wrap

    def _choose(self, hex_color: str) -> None:
        self._on_pick(hex_color)
        self.destroy()

    def _custom(self) -> None:
        result = colorchooser.askcolor(parent=self, title="Custom layer color")
        if result and result[1]:
            self._choose(result[1])


class LayerRgbApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Corne layer RGB")
        self.resizable(False, False)

        self._hid = LayerRgbHid()
        self._colors: dict[int, tuple[int, int, int]] = {}
        self._swatches: dict[int, tk.Button] = {}
        self._hsv_labels: dict[int, ttk.Label] = {}
        self._base_mode_label: ttk.Label | None = None

        root = ttk.Frame(self, padding=12)
        root.grid(row=0, column=0, sticky="nsew")

        ttk.Label(
            root,
            text="Layer 0 = Vial Lighting EEPROM (solid color). Layers 1–7 = user EEPROM.\n"
            "Close Vial before using. Picking a color writes the keyboard immediately.",
            justify=tk.LEFT,
        ).grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 10))

        header = ttk.Frame(root)
        header.grid(row=1, column=0, columnspan=3, sticky="ew", pady=(0, 6))
        ttk.Label(header, text="Layer", width=16).pack(side=tk.LEFT)
        ttk.Label(header, text="Color", width=10).pack(side=tk.LEFT, padx=(8, 0))
        ttk.Label(header, text="HSV / notes").pack(side=tk.LEFT, padx=(8, 0))

        for layer in range(LAYER_FIRST, LAYER_LAST + 1):
            row = ttk.Frame(root)
            row.grid(row=layer + 2, column=0, columnspan=3, sticky="ew", pady=3)
            name = LAYER_NAMES.get(layer, f"Layer {layer}")
            ttk.Label(row, text=f"{layer}  {name}", width=16).pack(side=tk.LEFT)
            btn = tk.Button(
                row,
                text="",
                width=8,
                height=1,
                relief=tk.GROOVE,
                bd=2,
                cursor="hand2",
                command=lambda ly=layer: self._open_picker(ly),
            )
            btn.pack(side=tk.LEFT, padx=(8, 0))
            self._swatches[layer] = btn
            hsv = ttk.Label(row, text="—", width=28)
            hsv.pack(side=tk.LEFT, padx=(12, 0))
            self._hsv_labels[layer] = hsv
            if layer == 0:
                self._base_mode_label = hsv

        btns = ttk.Frame(root)
        btns.grid(row=LAYER_LAST + 4, column=0, columnspan=3, sticky="ew", pady=(12, 0))
        ttk.Button(btns, text="Reload from EEPROM", command=self.reload_from_eeprom).pack(
            side=tk.LEFT
        )
        ttk.Button(btns, text="Reconnect", command=self.reconnect).pack(side=tk.LEFT, padx=(8, 0))

        self._status = ttk.Label(root, text="", foreground="#333333")
        self._status.grid(row=LAYER_LAST + 5, column=0, columnspan=3, sticky="w", pady=(10, 0))

        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(50, self.reconnect)

    def _set_status(self, text: str, error: bool = False) -> None:
        self._status.configure(text=text, foreground="#a40000" if error else "#333333")

    def _paint_layer(self, layer: int, h: int, s: int, v: int, note: str = "") -> None:
        self._colors[layer] = (h, s, v)
        r, g, b = qmk_hsv_to_rgb(h, s, v)
        hex_color = rgb_to_hex(r, g, b)
        btn = self._swatches[layer]
        btn.configure(bg=hex_color, activebackground=hex_color)
        luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        btn.configure(fg="#000000" if luminance > 140 else "#ffffff", text="")
        text = f"H{h} S{s} V{v}"
        if note:
            text = f"{text}  {note}"
        self._hsv_labels[layer].configure(text=text)

    def reconnect(self) -> None:
        try:
            self._hid.open()
            self.reload_from_eeprom()
        except Exception as e:
            self._set_status(str(e), error=True)
            messagebox.showerror("Keyboard not found", str(e), parent=self)

    def reload_from_eeprom(self) -> None:
        try:
            mode, _speed, h, s, v = self._hid.get_base()
            if mode == VIALRGB_EFFECT_OFF:
                self._paint_layer(0, 0, 0, 0, note="(lighting off)")
            elif mode == VIALRGB_EFFECT_SOLID_COLOR:
                self._paint_layer(0, h, s, v, note="(solid)")
            else:
                self._paint_layer(0, h, s, v, note=f"(effect {mode}; swatch → solid)")

            self._hid.load_all()
            for layer in range(1, LAYER_LAST + 1):
                hh, ss, vv = self._hid.get(layer)
                self._paint_layer(layer, hh, ss, vv)
            self._set_status("Loaded colors from EEPROM.")
        except Exception as e:
            self._set_status(str(e), error=True)
            messagebox.showerror("Load failed", str(e), parent=self)

    def _open_picker(self, layer: int) -> None:
        name = LAYER_NAMES.get(layer, f"Layer {layer}")
        SwatchPicker(self, f"Layer {layer} — {name}", lambda hc: self._apply_hex(layer, hc))

    def _apply_hex(self, layer: int, hex_color: str) -> None:
        r, g, b = hex_to_rgb(hex_color)
        h, s, v = rgb_to_qmk_hsv(r, g, b)
        try:
            self._hid.set_and_save(layer, h, s, v)
            note = "(solid)" if layer == 0 else ""
            self._paint_layer(layer, h, s, v, note=note)
            where = "Vial Lighting EEPROM" if layer == 0 else "user EEPROM"
            self._set_status(f"Layer {layer} → HSV({h}, {s}, {v}) written to {where}.")
        except Exception as e:
            self._set_status(str(e), error=True)
            messagebox.showerror("Write failed", str(e), parent=self)

    def _on_close(self) -> None:
        self._hid.close()
        self.destroy()


def main() -> None:
    app = LayerRgbApp()
    app.mainloop()


if __name__ == "__main__":
    main()
