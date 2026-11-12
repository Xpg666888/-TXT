#!/usr/bin/env python3
"""kai solve -- angr symbolic execution: automatically recover the input that reaches a success branch.

Usage (stdin):
  python solve.py SAMPLE.exe --find 0x401234 --avoid 0x401256 --mode stdin --length 16

Usage (argv[1]):
  python solve.py SAMPLE.exe --find 0x401234 --avoid 0x401256 --mode argv --length 12
"""
from __future__ import annotations

import argparse
import json
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

CHARSETS = {
    "alnum": b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "printable": bytes(range(32, 127)),
    "hex": b"0123456789abcdef",
    "digits": b"0123456789",
}


def addr_list(text):
    return [int(x, 16) for x in text.split(",") if x.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--find", required=True)
    ap.add_argument("--avoid", default="")
    ap.add_argument("--start", default="")
    ap.add_argument("--mode", default="stdin", choices=["stdin", "argv"])
    ap.add_argument("--length", type=int, default=16)
    ap.add_argument("--charset", default="alnum", choices=list(CHARSETS) + ["none"])
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()

    import angr
    import claripy
    from claripy import And, Or

    find = addr_list(args.find)
    avoid = addr_list(args.avoid)

    proj = angr.Project(args.file, auto_load_libs=False)
    sym = claripy.BVS("input", args.length * 8)

    charset = CHARSETS.get(args.charset)
    constraints = None
    if charset:
        clauses = []
        for i in range(args.length):
            byte = sym.get_byte(i)
            clauses.append(Or(*[byte == c for c in charset]))
        constraints = And(*clauses)

    start = int(args.start, 16) if args.start else None
    if args.mode == "argv":
        state = proj.factory.entry_state(args=[proj.filename or "a.exe", sym])
    else:
        state = proj.factory.entry_state(stdin=sym)
    if start is not None:
        state = proj.factory.call_state(start, sym)
    if constraints is not None:
        state.solver.add(constraints)

    simgr = proj.factory.simulation_manager(state)
    simgr.use_technique(angr.exploration_techniques.Timeout(args.timeout))
    simgr.explore(find=find, avoid=avoid, num_find=1)

    out = {
        "tool": "kai.solve/1",
        "file": args.file,
        "find": [hex(x) for x in find],
        "avoid": [hex(x) for x in avoid],
        "mode": args.mode,
        "length": args.length,
        "found": bool(simgr.found),
        "deadended": len(simgr.deadended),
        "active": len(simgr.active),
        "errored": len(simgr.errored),
    }
    if simgr.found:
        st = simgr.found[0]
        try:
            sol = st.solver.eval(sym, cast_to=bytes)
            out["solution_hex"] = sol.hex()
            out["solution_ascii"] = "".join(chr(b) if 32 <= b < 127 else "." for b in sol)
        except Exception as exc:
            out["solution_error"] = str(exc)
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if simgr.found else 2


if __name__ == "__main__":
    sys.exit(main())
