#!/usr/bin/env python3
"""kai mem -- 进程内存扫描/读写（外挂与逆向的底层原语）。

不依赖 Cheat Engine：用 pymem 直接读写目标进程，扫描结果落盘，支持"首次扫描 → 过滤"的经典流程。

用法：
  # 模块列表（拿基址）
  python mem.py --name game.exe mods

  # 首次扫描：找 int32 == 100 的地址
  python mem.py --name game.exe scan --type int32 --value 100

  # 过滤：在上次结果里找现在等于 90 的
  python mem.py --name game.exe next --value 90

  # 读 / 写
  python mem.py --name game.exe read --addr 0x1A2B3C40 --len 16
  python mem.py --name game.exe write --addr 0x1A2B3C40 --bytes 39300000

  # 特征码扫描（AOB，?? 为通配）
  python mem.py --name game.exe aob --pattern "48 8B 05 ?? ?? ?? ?? 48 85 C0"
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

STATE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "cases", "mem")

PACK = {
    "int32": ("<i", 4),
    "uint32": ("<I", 4),
    "int64": ("<q", 8),
    "float": ("<f", 4),
    "double": ("<d", 8),
    "bytes": (None, 0),
}


def pack_value(kind, value):
    if kind == "bytes":
        return bytes.fromhex(value)
    fmt, _ = PACK[kind]
    if kind == "float":
        return struct.pack(fmt, float(value))
    return struct.pack(fmt, int(value, 0))


def unpack_value(kind, raw):
    fmt, size = PACK[kind]
    if kind == "bytes":
        return raw.hex()
    if len(raw) < size:
        return None
    v = struct.unpack(fmt, raw[:size])[0]
    if kind == "float":
        return round(v, 6)
    return v


def open_proc(args):
    import pymem
    if args.pid:
        return pymem.Pymem(args.pid)
    return pymem.Pymem(args.name)


def state_file(pid):
    os.makedirs(STATE_DIR, exist_ok=True)
    return os.path.join(STATE_DIR, f"{pid}.json")


def iter_regions(pm):
    """遍历可读区域（模块 + 私有内存），跳过 guard/noaccess。"""
    import pymem.memory as mem
    addr = 0
    max_addr = 0x7FFFFFFFFFFF
    while addr < max_addr:
        try:
            mbi = mem.virtual_query(pm.process_handle, addr)
        except Exception:
            break
        if not mbi:
            break
        base = mbi.BaseAddress or addr
        size = mbi.RegionSize or 0x1000
        if size <= 0:
            break
        prot = mbi.Protect or 0
        readable = bool(prot & 0xEE) and not (prot & 0x100)  # 排除 PAGE_GUARD
        if readable and (mbi.State == 0x1000):
            yield base, size
        addr = base + size


def cmd_mods(pm, args):
    out = []
    for mod in pm.list_modules():
        out.append({"name": mod.name, "base": hex(mod.lpBaseOfDll), "size": hex(mod.SizeOfImage)})
    print(json.dumps({"tool": "kai.mem/1", "action": "mods", "pid": pm.process_id, "modules": out}, ensure_ascii=False, indent=2))


def cmd_scan(pm, args):
    needle = pack_value(args.type, args.value)
    hits = []
    scanned = 0
    for base, size in iter_regions(pm):
        try:
            buf = pm.read_bytes(base, size)
        except Exception:
            continue
        scanned += size
        start = 0
        while True:
            idx = buf.find(needle, start)
            if idx < 0:
                break
            hits.append(base + idx)
            start = idx + 1
            if len(hits) >= args.max:
                break
        if len(hits) >= args.max:
            break
    state = {"pid": pm.process_id, "type": args.type, "value": args.value, "addrs": [hex(h) for h in hits]}
    with open(state_file(pm.process_id), "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps({"tool": "kai.mem/1", "action": "scan", "pid": pm.process_id, "type": args.type,
                      "value": args.value, "hits": len(hits), "scanned_mb": round(scanned / 1048576, 1),
                      "sample": [hex(h) for h in hits[:20]], "state": state_file(pm.process_id)},
                     ensure_ascii=False, indent=2))


def cmd_next(pm, args):
    sf = state_file(pm.process_id)
    if not os.path.exists(sf):
        print(json.dumps({"error": "没有上次扫描结果，先 scan"}))
        return
    with open(sf, encoding="utf-8") as f:
        state = json.load(f)
    kind = args.type or state.get("type", "int32")
    needle = pack_value(kind, args.value)
    kept = []
    for a in state.get("addrs", []):
        addr = int(a, 16)
        try:
            raw = pm.read_bytes(addr, max(len(needle), 8))
        except Exception:
            continue
        if raw.startswith(needle):
            kept.append(hex(addr))
    state["addrs"] = kept
    state["type"] = kind
    state["value"] = args.value
    with open(sf, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps({"tool": "kai.mem/1", "action": "next", "pid": pm.process_id, "value": args.value,
                      "kept": len(kept), "addrs": kept[:50]}, ensure_ascii=False, indent=2))


def cmd_read(pm, args):
    raw = pm.read_bytes(int(args.addr, 0), args.len)
    print(json.dumps({"tool": "kai.mem/1", "action": "read", "addr": args.addr, "len": args.len,
                      "hex": raw.hex(), "int32": unpack_value("int32", raw),
                      "ascii": "".join(chr(b) if 32 <= b < 127 else "." for b in raw)}, ensure_ascii=False, indent=2))


def cmd_write(pm, args):
    data = bytes.fromhex(args.bytes)
    addr = int(args.addr, 0)
    before = pm.read_bytes(addr, len(data))
    pm.write_bytes(addr, data, len(data))
    after = pm.read_bytes(addr, len(data))
    print(json.dumps({"tool": "kai.mem/1", "action": "write", "addr": args.addr,
                      "before": before.hex(), "after": after.hex()}, ensure_ascii=False, indent=2))


def parse_pattern(text):
    """'48 8B ?? 05' → (bytes, mask)"""
    parts = text.split()
    pat = bytearray()
    mask = []
    for p in parts:
        if p in ("??", "?", "**"):
            pat.append(0)
            mask.append(False)
        else:
            pat.append(int(p, 16))
            mask.append(True)
    return bytes(pat), mask


def find_pattern(buf, pat, mask):
    n, m = len(buf), len(pat)
    if m == 0 or m > n:
        return -1
    first = pat[0]
    i = 0
    while True:
        idx = buf.find(bytes([first]), i)
        if idx < 0 or idx + m > n:
            return -1
        ok = True
        for j in range(m):
            if mask[j] and buf[idx + j] != pat[j]:
                ok = False
                break
        if ok:
            return idx
        i = idx + 1


def cmd_ptrscan(pm, args):
    """在内存里找"指向 target 附近的指针"（一级或多级），外挂定位稳定地址的核心。"""
    target = int(args.target, 0)
    lo, hi = target - args.range, target + args.range
    results = []
    for base, size in iter_regions(pm):
        if size > 512 * 1024 * 1024:
            continue
        try:
            buf = pm.read_bytes(base, size)
        except Exception:
            continue
        for off in range(0, len(buf) - 8, 8):
            val = int.from_bytes(buf[off:off + 8], "little")
            if lo <= val <= hi:
                results.append(hex(base + off))
                if len(results) >= args.max:
                    break
        if len(results) >= args.max:
            break
    print(json.dumps({"tool": "kai.mem/1", "action": "ptrscan", "pid": pm.process_id,
                      "target": args.target, "range": args.range,
                      "hits": len(results), "addrs": results}, ensure_ascii=False, indent=2))


def cmd_aob(pm, args):
    pat, mask = parse_pattern(args.pattern)
    hits = []
    for base, size in iter_regions(pm):
        if size > 256 * 1024 * 1024:
            continue
        try:
            buf = pm.read_bytes(base, size)
        except Exception:
            continue
        off = find_pattern(buf, pat, mask)
        while off >= 0 and len(hits) < args.max:
            hits.append(hex(base + off))
            nxt = find_pattern(buf[off + 1:], pat, mask)
            off = -1 if nxt < 0 else off + 1 + nxt
        if len(hits) >= args.max:
            break
    print(json.dumps({"tool": "kai.mem/1", "action": "aob", "pattern": args.pattern,
                      "hits": len(hits), "addrs": hits}, ensure_ascii=False, indent=2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int)
    ap.add_argument("--name")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("mods")

    s = sub.add_parser("scan")
    s.add_argument("--type", default="int32", choices=list(PACK))
    s.add_argument("--value", required=True)
    s.add_argument("--max", type=int, default=500)

    n = sub.add_parser("next")
    n.add_argument("--value", required=True)
    n.add_argument("--type", default="")

    r = sub.add_parser("read")
    r.add_argument("--addr", required=True)
    r.add_argument("--len", type=int, default=16)

    w = sub.add_parser("write")
    w.add_argument("--addr", required=True)
    w.add_argument("--bytes", required=True)

    p = sub.add_parser("ptrscan")
    p.add_argument("--target", required=True)
    p.add_argument("--range", type=lambda x: int(x, 0), default=0x1000)
    p.add_argument("--max", type=int, default=200)

    a = sub.add_parser("aob")
    a.add_argument("--pattern", required=True)
    a.add_argument("--max", type=int, default=50)

    args = ap.parse_args()
    if not args.pid and not args.name:
        print(json.dumps({"error": "需要 --pid 或 --name"}))
        return 2
    pm = open_proc(args)
    handler = {"mods": cmd_mods, "scan": cmd_scan, "next": cmd_next, "ptrscan": cmd_ptrscan,
               "read": cmd_read, "write": cmd_write, "aob": cmd_aob}[args.cmd]
    handler(pm, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
