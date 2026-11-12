#!/usr/bin/env python3
"""kai emu —— 用 unicorn 模拟执行一段函数（Windows PE / x64 或 x86）。

不需要虚拟机、不需要装调试器：把镜像按 ImageBase 映射进 unicorn，设好寄存器和栈，
从指定 RVA 开始跑，遇到 ret 停下，输出寄存器与内存。

典型用途：
  · 跑解密/解压 stub，直接 dump 出明文
  · 跑授权校验函数，观察返回值（EAX/RAX）而不启动整个程序
  · 跑混淆过的哈希/序列号算法，配合爆破脚本

用法：
  python emu.py SAMPLE.exe --rva 0x1234 --arch x64 \
      --reg rcx=0x401000 --reg rdx=8 --max-insns 200000 \
      --dump 0x401000:64
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

from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_MODE_64, UC_HOOK_CODE, UC_HOOK_MEM_READ_UNMAPPED, UC_HOOK_MEM_WRITE_UNMAPPED, UC_HOOK_MEM_FETCH_UNMAPPED
from unicorn.x86_const import (
    UC_X86_REG_RAX, UC_X86_REG_RBX, UC_X86_REG_RCX, UC_X86_REG_RDX,
    UC_X86_REG_RSI, UC_X86_REG_RDI, UC_X86_REG_RBP, UC_X86_REG_RSP,
    UC_X86_REG_R8, UC_X86_REG_R9, UC_X86_REG_R10, UC_X86_REG_R11,
    UC_X86_REG_R12, UC_X86_REG_R13, UC_X86_REG_R14, UC_X86_REG_R15,
    UC_X86_REG_RIP, UC_X86_REG_EFLAGS,
    UC_X86_REG_EAX, UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX,
    UC_X86_REG_ESI, UC_X86_REG_EDI, UC_X86_REG_EBP, UC_X86_REG_ESP,
    UC_X86_REG_EIP,
)

REG = {
    "rax": UC_X86_REG_RAX, "rbx": UC_X86_REG_RBX, "rcx": UC_X86_REG_RCX, "rdx": UC_X86_REG_RDX,
    "rsi": UC_X86_REG_RSI, "rdi": UC_X86_REG_RDI, "rbp": UC_X86_REG_RBP, "rsp": UC_X86_REG_RSP,
    "r8": UC_X86_REG_R8, "r9": UC_X86_REG_R9, "r10": UC_X86_REG_R10, "r11": UC_X86_REG_R11,
    "r12": UC_X86_REG_R12, "r13": UC_X86_REG_R13, "r14": UC_X86_REG_R14, "r15": UC_X86_REG_R15,
    "rip": UC_X86_REG_RIP, "eflags": UC_X86_REG_EFLAGS,
    "eax": UC_X86_REG_EAX, "ebx": UC_X86_REG_EBX, "ecx": UC_X86_REG_ECX, "edx": UC_X86_REG_EDX,
    "esi": UC_X86_REG_ESI, "edi": UC_X86_REG_EDI, "ebp": UC_X86_REG_EBP, "esp": UC_X86_REG_ESP,
    "eip": UC_X86_REG_EIP,
}

PAGE = 0x1000
STACK_BASE = 0x0000000000100000
STACK_SIZE = 0x100000
STUB_BASE = 0x0000000000200000   # 导入函数桩
STUB_SIZE = 0x10000
HEAP_BASE = 0x0000000000300000
HEAP_SIZE = 0x100000


def align_down(x):
    return x & ~(PAGE - 1)


def align_up(x):
    return (x + PAGE - 1) & ~(PAGE - 1)


def load_pe(path):
    import pefile
    pe = pefile.PE(path, fast_load=True)
    base = pe.OPTIONAL_HEADER.ImageBase
    size = pe.OPTIONAL_HEADER.SizeOfImage
    sections = []
    for s in pe.sections:
        sections.append({
            "name": s.Name.rstrip(b"\x00").decode("latin-1", "replace"),
            "va": base + s.VirtualAddress,
            "data": s.get_data(),
            "vsize": s.Misc_VirtualSize,
        })
    return {
        "base": base,
        "size": size,
        "sections": sections,
        "entry": base + pe.OPTIONAL_HEADER.AddressOfEntryPoint,
        "bits": 32 if pe.FILE_HEADER.Machine == 0x14C else 64,
        "imports": collect_imports(pe),
    }


def collect_imports(pe):
    out = []
    for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []) or []:
        dll = entry.dll.decode("latin-1", "replace")
        for imp in entry.imports:
            name = imp.name.decode("latin-1", "replace") if imp.name else f"ord_{imp.ordinal}"
            out.append({"dll": dll, "name": name, "iat": imp.address})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--rva", type=lambda x: int(x, 0), help="从这个 RVA 开始跑（默认入口点）")
    ap.add_argument("--arch", default="x64", choices=["x64", "x86"])
    ap.add_argument("--reg", action="append", default=[], help="寄存器初值，如 rcx=0x401000，可多次")
    ap.add_argument("--mem", action="append", default=[], help="额外内存，如 0x500000:0x1000")
    ap.add_argument("--write", action="append", default=[], help="写内存，如 0x401000:48656c6c6f")
    ap.add_argument("--max-insns", type=int, default=200000)
    ap.add_argument("--dump", action="append", default=[], help="结束时 dump，如 0x401000:64")
    ap.add_argument("--ret-value", type=lambda x: int(x, 0), default=0, help="导入桩的返回值（默认 0）")
    args = ap.parse_args()

    info = load_pe(args.file)
    bits = 64 if args.arch == "x64" else 32
    mode = UC_MODE_64 if bits == 64 else UC_MODE_32

    uc = Uc(UC_ARCH_X86, mode)
    base = info["base"]
    uc.mem_map(align_down(base), align_up(info["size"]) or PAGE)
    for s in info["sections"]:
        if not s["data"]:
            continue
        addr = align_down(s["va"])
        try:
            uc.mem_write(s["va"], s["data"])
        except Exception:
            pass

    uc.mem_map(STACK_BASE, STACK_SIZE)
    uc.mem_map(STUB_BASE, STUB_SIZE)
    uc.mem_map(HEAP_BASE, HEAP_SIZE)
    for spec in args.mem:
        a, n = spec.split(":")
        a = int(a, 0); n = int(n, 0)
        uc.mem_map(align_down(a), align_up(n))
    for spec in args.write:
        a, hexstr = spec.split(":")
        uc.mem_write(int(a, 0), bytes.fromhex(hexstr))

    rsp = STACK_BASE + STACK_SIZE - 0x1000
    # 返回地址指向桩区，ret 时命中桩 → 停下
    ret_addr = STUB_BASE + STUB_SIZE - 0x10
    uc.mem_write(ret_addr, b"\xc3")  # ret
    if bits == 64:
        uc.reg_write(UC_X86_REG_RSP, rsp)
        uc.mem_write(rsp, ret_addr.to_bytes(8, "little"))
        uc.reg_write(UC_X86_REG_RBP, rsp)
    else:
        uc.reg_write(UC_X86_REG_ESP, rsp)
        uc.mem_write(rsp, ret_addr.to_bytes(4, "little"))
        uc.reg_write(UC_X86_REG_EBP, rsp)

    for spec in args.reg:
        k, v = spec.split("=")
        k = k.strip().lower()
        if k not in REG:
            continue
        uc.reg_write(REG[k], int(v, 0))

    start = base + args.rva if args.rva is not None else info["entry"]
    if args.rva is not None:
        uc.reg_write(UC_X86_REG_RIP if bits == 64 else UC_X86_REG_EIP, start)

    insns = {"count": 0, "last": 0, "stop": ""}
    stub_hits = []

    def hook_code(uc, address, size, user_data):
        insns["count"] += 1
        insns["last"] = address
        if insns["count"] > args.max_insns:
            uc.emu_stop()
            insns["stop"] = "max-insns"
            return
        if address == ret_addr:
            uc.emu_stop()
            insns["stop"] = "ret"
            return
        try:
            code = uc.mem_read(address, 1)[0]
        except Exception:
            return
        if code == 0xC3:  # ret
            uc.emu_stop()
            insns["stop"] = "ret"
        elif code == 0xCC:
            stub_hits.append(hex(address))

    def map_lazy(uc, access, address, size, value, user_data):
        """未映射的内存按页补零，避免一读数据就崩。"""
        try:
            uc.mem_map(align_down(address), PAGE)
        except Exception:
            return False
        return True

    uc.hook_add(UC_HOOK_CODE, hook_code)
    uc.hook_add(UC_HOOK_MEM_READ_UNMAPPED, map_lazy)
    uc.hook_add(UC_HOOK_MEM_WRITE_UNMAPPED, map_lazy)

    error = ""
    try:
        uc.emu_start(start, ret_addr, count=args.max_insns)
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"

    regs = {}
    for name, rid in REG.items():
        try:
            regs[name] = hex(uc.reg_read(rid))
        except Exception:
            pass

    dumps = {}
    for spec in args.dump:
        a, n = spec.split(":")
        a = int(a, 0); n = int(n, 0)
        try:
            raw = bytes(uc.mem_read(a, n))
            dumps[hex(a)] = {"hex": raw.hex(), "ascii": "".join(chr(b) if 32 <= b < 127 else "." for b in raw)}
        except Exception as exc:
            dumps[hex(a)] = {"error": str(exc)}

    out = {
        "tool": "kai.emu/1",
        "file": args.file,
        "arch": args.arch,
        "start": hex(start),
        "stop_reason": insns["stop"] or ("error" if error else "end"),
        "insns": insns["count"],
        "regs": regs,
        "ret_rax": regs.get("rax") if bits == 64 else regs.get("eax"),
        "dumps": dumps,
        "error": error,
    }
    # 布尔返回：x86/x64 的 bool 在 AL，函数常直接 sete al，此时 RAX 高位仍是入参指针
    try:
        rax = int(regs.get("rax", "0x0"), 16) if bits == 64 else int(regs.get("eax", "0x0"), 16)
        out["al"] = hex(rax & 0xFF)
        out["bool_ret"] = rax & 0xFF
    except Exception:
        pass
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if not error else 1


if __name__ == "__main__":
    sys.exit(main())
