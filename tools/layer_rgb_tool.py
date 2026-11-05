#!/usr/bin/env python3
"""Get/set Corne v4 vial_layers per-layer RGB colors over VIA raw HID (no reflash).

Protocol (32-byte report, Windows often prefixes report ID 0x00 on write):
  [0]=0xFC
  [1]=subcmd  01=get 02=set 03=save 04=load
  [2]=layer (1-4 for get/set)
  [3]=h  [4]=s  [5]=v  (set only)

Close Vial before running — it holds the raw HID interface.

Examples:
  python tools/layer_rgb_tool.py list
  python tools/layer_rgb_tool.py get 2
  python tools/layer_rgb_tool.py set 2 20 255 180
  python tools/layer_rgb_tool.py save
  python tools/layer_rgb_tool.py set 4 170 255 255 --save
"""

from __future__ import annotations

import argparse
import sys
import time

try:
    import hid
except ImportError:
    print("Missing dependency: pip install hidapi", file=sys.stderr)
    sys.exit(1)

VID = 0x4653
PID = 0x0004
USAGE_PAGE = 0xFF60
REPORT_LEN = 32

CMD = 0xFC
SUB_GET = 0x01
SUB_SET = 0x02
SUB_SAVE = 0x03
SUB_LOAD = 0x04

LAYER_DEFAULT_NAMES = {
    1: "Lower",
    2: "Raise",
    3: "Adjust",
    4: "Layer4",
}


def find_path() -> bytes:
    for d in hid.enumerate(VID, PID):
        if d.get("usage_page") == USAGE_PAGE:
            return d["path"]
    # Fallback: any interface on this VID/PID
    for d in hid.enumerate(VID, PID):
        return d["path"]
    raise SystemExit(
        f"No Corne Vial device found (VID={VID:#06x} PID={PID:#06x}). "
        "Plug in the keyboard and close the Vial app."
    )


def open_device() -> hid.device:
    path = find_path()
    dev = hid.device()
    dev.open_path(path)
    return dev


def transact(dev: hid.device, payload: list[int], retries: int = 3) -> list[int]:
    buf = bytearray(REPORT_LEN)
    for i, b in enumerate(payload[:REPORT_LEN]):
        buf[i] = b & 0xFF

    # Windows HID: leading report ID 0
    out = b"\x00" + bytes(buf)
    last_err = None
    for _ in range(retries):
        try:
            dev.write(out)
            time.sleep(0.02)
            raw = dev.read(REPORT_LEN + 1, timeout_ms=1000)
            if not raw:
                continue
            data = list(raw)
            # Drop report ID if present
            if len(data) == REPORT_LEN + 1:
                data = data[1:]
            return data
        except OSError as e:
            last_err = e
            time.sleep(0.05)
    raise SystemExit(f"HID transfer failed: {last_err}")


def cmd_get(dev: hid.device, layer: int) -> tuple[int, int, int]:
    resp = transact(dev, [CMD, SUB_GET, layer, 0, 0, 0])
    if resp[0] != CMD or resp[1] == 0xFF:
        raise SystemExit(f"get failed for layer {layer} (is custom firmware flashed?)")
    return resp[3], resp[4], resp[5]


def cmd_set(dev: hid.device, layer: int, h: int, s: int, v: int) -> None:
    resp = transact(dev, [CMD, SUB_SET, layer, h, s, v])
    if resp[0] != CMD or resp[1] != SUB_SET:
        raise SystemExit(f"set failed for layer {layer}")


def cmd_save(dev: hid.device) -> None:
    resp = transact(dev, [CMD, SUB_SAVE, 0, 0, 0, 0])
    if resp[0] != CMD or resp[1] != SUB_SAVE:
        raise SystemExit("save failed")


def cmd_load(dev: hid.device) -> None:
    resp = transact(dev, [CMD, SUB_LOAD, 0, 0, 0, 0])
    if resp[0] != CMD or resp[1] != SUB_LOAD:
        raise SystemExit("load failed")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="action", required=True)

    sub.add_parser("list", help="Show HSV for layers 1-4")
    g = sub.add_parser("get", help="Get one layer")
    g.add_argument("layer", type=int, choices=range(1, 5))

    s = sub.add_parser("set", help="Set one layer HSV (RAM; use --save to persist)")
    s.add_argument("layer", type=int, choices=range(1, 5))
    s.add_argument("h", type=int)
    s.add_argument("s", type=int)
    s.add_argument("v", type=int)
    s.add_argument("--save", action="store_true", help="Also write EEPROM")

    sub.add_parser("save", help="Write current RAM colors to EEPROM")
    sub.add_parser("load", help="Reload colors from EEPROM into RAM")

    return p.parse_args()


def main() -> None:
    args = parse_args()
    for name in ("h", "s", "v"):
        if hasattr(args, name):
            val = getattr(args, name)
            if not 0 <= val <= 255:
                raise SystemExit(f"{name} must be 0-255, got {val}")

    dev = open_device()
    try:
        if args.action == "list":
            for layer in range(1, 5):
                h, s, v = cmd_get(dev, layer)
                name = LAYER_DEFAULT_NAMES.get(layer, "")
                print(f"layer {layer} ({name}): HSV({h}, {s}, {v})")
        elif args.action == "get":
            h, s, v = cmd_get(dev, args.layer)
            print(f"layer {args.layer}: HSV({h}, {s}, {v})")
        elif args.action == "set":
            cmd_set(dev, args.layer, args.h, args.s, args.v)
            print(f"set layer {args.layer} -> HSV({args.h}, {args.s}, {args.v})")
            if args.save:
                cmd_save(dev)
                print("saved to EEPROM")
        elif args.action == "save":
            cmd_save(dev)
            print("saved to EEPROM")
        elif args.action == "load":
            cmd_load(dev)
            print("loaded from EEPROM")
    finally:
        dev.close()


if __name__ == "__main__":
    main()
