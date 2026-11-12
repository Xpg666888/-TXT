#!/usr/bin/env python3
"""kai dis — disassemble a byte range of a PE/ELF file with capstone.

Usage:
  python dis.py SAMPLE --rva 0x1234 --len 128 [--arch x64|x86|arm64] [--base 0x140000000]

RVA is translated through the PE section table; pass --offset to address a raw
file offset directly (needed for overlay / packed regions).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import capstone

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def resolve_rva_pe(path, rva):
    import pefile  # type: ignore
    pe = pefile.PE(path, fast_load=True)
    return pe.get_offset_from_rva(rva)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--rva", type=lambda x: int(x, 0))
    g.add_argument("--offset", type=lambda x: int(x, 0))
    ap.add_argument("--len", type=lambda x: int(x, 0), default=128)
    ap.add_argument("--arch", default="x64", choices=["x64", "x86", "arm64", "arm"])
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0)
    args = ap.parse_args()

    path = os.path.abspath(args.file)
    if args.offset is not None:
        off = args.offset
    else:
        off = resolve_rva_pe(path, args.rva)

    with open(path, "rb") as f:
        f.seek(off)
        code = f.read(args.len)

    mode = {
        "x64": (capstone.CS_ARCH_X86, capstone.CS_MODE_64),
        "x86": (capstone.CS_ARCH_X86, capstone.CS_MODE_32),
        "arm64": (capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM),
        "arm": (capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM),
    }[args.arch]
    md = capstone.Cs(*mode)
    md.detail = True
    addr = args.base if args.base else (args.rva or 0)
    insns = []
    for ins in md.disasm(code, addr):
        insns.append({
            "addr": hex(ins.address),
            "bytes": ins.bytes.hex(),
            "mnemonic": ins.mnemonic,
            "op_str": ins.op_str,
        })
    print(json.dumps({
        "file": path,
        "offset": hex(off),
        "count": len(insns),
        "insns": insns,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
