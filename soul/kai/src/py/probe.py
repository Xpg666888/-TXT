#!/usr/bin/env python3
"""kai probe — deep static triage for PE / ELF / Mach-O.

Emits one JSON object on stdout. No network, no execution of the sample.
Designed as the evidence producer of the kai kernel: every field is a fact
that a later claim can cite.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import struct
import sys
from collections import Counter, OrderedDict

try:  # Windows 控制台默认 GBK，JSON 必须走 UTF-8
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# ---------------------------------------------------------------- helpers


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def entropy(data: bytes) -> float:
    if not data:
        return 0.0
    counts = Counter(data)
    n = len(data)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


PRINTABLE = re.compile(rb"[\x20-\x7e]{4,}")
WIDE = re.compile(rb"(?:[\x20-\x7e]\x00){4,}")

INTERESTING = [
    "license", "licence", "serial", "activ", "regist", "trial", "expire",
    "卡密", "激活", "授权", "注册", "试用", "到期", "续费",
    "key", "token", "secret", "password", "passwd", "admin",
    "http://", "https://", "ftp://", "ws://", "api/", "/v1/", "/v2/",
    "reg open", "software\\", "currentversion", "machineguid", "wmic",
    "cmd.exe", "powershell", "schtasks", "runonce", "appdata",
    "select ", "insert into", "sqlite", "aes", "rsa", "hmac",
]

SUSPICIOUS_APIS = {
    "process_injection": [
        "VirtualAllocEx", "WriteProcessMemory", "CreateRemoteThread",
        "NtUnmapViewOfSection", "QueueUserAPC", "SetThreadContext",
        "NtCreateThreadEx", "RtlCreateUserThread", "MapViewOfFile",
    ],
    "anti_debug": [
        "IsDebuggerPresent", "CheckRemoteDebuggerPresent",
        "NtQueryInformationProcess", "OutputDebugStringA",
        "OutputDebugStringW", "GetThreadContext", "NtSetInformationThread",
        "QueryPerformanceCounter", "GetTickCount", "GetTickCount64",
        "NtQuerySystemInformation", "CreateToolhelp32Snapshot",
    ],
    "hooking": [
        "SetWindowsHookEx", "GetAsyncKeyState", "GetKeyState",
        "RegisterHotKey", "GetForegroundWindow", "GetWindowTextA",
        "GetWindowTextW", "GetClipboardData",
    ],
    "network": [
        "InternetOpenA", "InternetOpenW", "InternetOpenUrlA",
        "InternetReadFile", "WinHttpOpen", "WinHttpSendRequest",
        "HttpSendRequestA", "URLDownloadToFileA", "URLDownloadToFileW",
        "WSASocketA", "WSAConnect", "connect", "send", "recv",
        "getaddrinfo", "gethostbyname",
    ],
    "persistence": [
        "RegSetValueExA", "RegSetValueExW", "RegCreateKeyExA",
        "CreateServiceA", "CreateServiceW", "StartServiceA",
        "schtasks", "ShellExecuteA", "ShellExecuteW", "WinExec",
    ],
    "crypto": [
        "CryptEncrypt", "CryptDecrypt", "CryptGenKey", "CryptAcquireContext",
        "BCryptEncrypt", "BCryptDecrypt", "CryptHashData",
    ],
    "file_system": [
        "CreateFileA", "CreateFileW", "WriteFile", "DeleteFileA",
        "MoveFileA", "CopyFileA", "FindFirstFileA", "SetFileAttributesA",
    ],
    "dynamic_code": [
        "LoadLibraryA", "LoadLibraryW", "GetProcAddress", "LdrLoadDll",
        "VirtualProtect", "VirtualAlloc", "NtAllocateVirtualMemory",
    ],
}

PACKER_SECTION_HINTS = {
    "UPX0": "UPX", "UPX1": "UPX", "UPX2": "UPX",
    ".aspack": "ASPack", ".adata": "ASPack",
    ".themida": "Themida/WinLicense", ".vmp0": "VMProtect", ".vmp1": "VMProtect",
    ".enigma1": "Enigma", ".enigma2": "Enigma",
    ".petite": "Petite", ".mpress1": "MPRESS", ".mpress2": "MPRESS",
    ".packed": "generic packer", ".boom": "The Boomerang",
    ".nsp0": "NsPack", ".nsp1": "NsPack", ".nsp2": "NsPack",
}

SEVERITY_ORDER = {"info": 0, "low": 1, "medium": 2, "high": 3}


def add(found, sev, ident, title, detail=""):
    found.append({"id": ident, "severity": sev, "title": title, "detail": detail})


def collect_strings(path: str, limit_bytes: int = 64 << 20):
    with open(path, "rb") as f:
        data = f.read(limit_bytes)
    out = []
    for m in PRINTABLE.finditer(data):
        out.append(m.group().decode("latin-1"))
    for m in WIDE.finditer(data):
        try:
            s = m.group().decode("utf-16-le", "ignore")
        except Exception:
            continue
        if len(s) >= 4:
            out.append(s)
    return out, data


# ---------------------------------------------------------------- PE


def probe_pe(path: str, report, found):
    import pefile  # type: ignore

    pe = pefile.PE(path, fast_load=False)
    hdr = OrderedDict()
    hdr["machine"] = hex(pe.FILE_HEADER.Machine)
    hdr["machine_name"] = {
        0x14c: "x86", 0x8664: "x64", 0x1c0: "arm", 0xaa64: "arm64",
    }.get(pe.FILE_HEADER.Machine, "unknown")
    hdr["characteristics"] = hex(pe.FILE_HEADER.Characteristics)
    hdr["timestamp"] = pe.FILE_HEADER.TimeDateStamp
    hdr["subsystem"] = pe.OPTIONAL_HEADER.Subsystem
    hdr["dll"] = bool(pe.FILE_HEADER.Characteristics & 0x2000)
    hdr["image_base"] = hex(pe.OPTIONAL_HEADER.ImageBase)
    hdr["entry_point_rva"] = hex(pe.OPTIONAL_HEADER.AddressOfEntryPoint)
    hdr["size_of_image"] = pe.OPTIONAL_HEADER.SizeOfImage
    hdr["checksum"] = hex(pe.OPTIONAL_HEADER.CheckSum)
    hdr["dll_characteristics"] = hex(pe.OPTIONAL_HEADER.DllCharacteristics)
    hdr["aslr"] = bool(pe.OPTIONAL_HEADER.DllCharacteristics & 0x40)
    hdr["dep"] = bool(pe.OPTIONAL_HEADER.DllCharacteristics & 0x100)
    hdr["cfg"] = bool(pe.OPTIONAL_HEADER.DllCharacteristics & 0x4000)
    hdr["imphash"] = pe.get_imphash()
    report["pe"] = hdr

    sections = []
    for s in pe.sections:
        name = s.Name.rstrip(b"\x00").decode("latin-1", "replace")
        raw = s.get_data()
        ent = entropy(raw)
        flags = s.Characteristics
        sections.append({
            "name": name,
            "vaddr": hex(s.VirtualAddress),
            "vsize": s.Misc_VirtualSize,
            "raw_offset": hex(s.PointerToRawData),
            "raw_size": s.SizeOfRawData,
            "entropy": round(ent, 3),
            "exec": bool(flags & 0x20000000),
            "write": bool(flags & 0x80000000),
            "read": bool(flags & 0x40000000),
        })
        if ent > 7.2 and s.SizeOfRawData > 4096:
            add(found, "medium", "high-entropy-section",
                f"section {name} entropy {ent:.2f}",
                "packed / encrypted / compressed payload")
        if (flags & 0x20000000) and (flags & 0x80000000):
            add(found, "high", "wx-section", f"section {name} is RWX",
                "self-modifying or unpacking stub")
        if name in PACKER_SECTION_HINTS:
            add(found, "high", "packer-section-name",
                f"section {name} => {PACKER_SECTION_HINTS[name]}",
                "known packer signature")
    report["sections"] = sections

    # imports
    imports = OrderedDict()
    api_hits = OrderedDict((k, []) for k in SUSPICIOUS_APIS)
    for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []) or []:
        dll = entry.dll.decode("latin-1", "replace")
        funcs = []
        for imp in entry.imports:
            if imp.name:
                fn = imp.name.decode("latin-1", "replace")
                funcs.append(fn)
                for cat, names in SUSPICIOUS_APIS.items():
                    if fn in names and fn not in api_hits[cat]:
                        api_hits[cat].append(fn)
            elif imp.ordinal:
                funcs.append(f"ord_{imp.ordinal}")
        imports[dll] = funcs
    report["imports"] = imports
    report["import_dll_count"] = len(imports)
    report["import_func_count"] = sum(len(v) for v in imports.values())
    report["api_categories"] = {k: v for k, v in api_hits.items() if v}

    if report["import_func_count"] == 0:
        add(found, "high", "no-imports", "no import table",
            "typical of packed/protected or manually-resolving binaries")
    for cat in ("process_injection", "anti_debug", "hooking"):
        if api_hits[cat]:
            add(found, "medium", f"api-{cat}",
                f"{cat} APIs: {', '.join(api_hits[cat][:6])}",
                "capability present; judge intent from call sites")

    exports = []
    for e in getattr(pe, "DIRECTORY_ENTRY_EXPORT", []).symbols if hasattr(pe, "DIRECTORY_ENTRY_EXPORT") else []:
        try:
            exports.append(e.name.decode("latin-1", "replace") if e.name else f"ord_{e.ordinal}")
        except Exception:
            pass
    report["exports"] = exports[:200]
    report["export_count"] = len(exports)

    # overlay
    overlay = pe.get_overlay_data_start_offset()
    if overlay is not None:
        size = os.path.getsize(path) - overlay
        report["overlay"] = {"offset": hex(overlay), "size": size}
        if size > 4096:
            add(found, "medium", "overlay", f"overlay {size} bytes at {hex(overlay)}",
                "appended data: installer payload / signature blob / dropper stage")

    # debug / pdb
    try:
        if hasattr(pe, "DIRECTORY_ENTRY_DEBUG"):
            pdb = []
            for d in pe.DIRECTORY_ENTRY_DEBUG:
                if hasattr(d, "entry") and hasattr(d.entry, "PdbFileName"):
                    pdb.append(d.entry.PdbFileName.rstrip(b"\x00").decode("latin-1", "replace"))
            if pdb:
                report["pdb"] = pdb
                add(found, "info", "pdb-path", f"debug path {pdb[0]}",
                    "symbol path leaks build environment")
    except Exception:
        pass

    # resources / version info
    vi = {}
    try:
        if hasattr(pe, "FileInfo"):
            for fileinfo in pe.FileInfo:
                for entry in fileinfo:
                    if getattr(entry, "Key", b"") == b"StringFileInfo":
                        for st in entry.StringTable:
                            for k, v in st.entries.items():
                                vi[k.decode("latin-1", "replace")] = v.decode("latin-1", "replace")
    except Exception:
        pass
    if vi:
        report["version_info"] = vi

    # tls / rich / signature
    report["has_tls"] = hasattr(pe, "DIRECTORY_ENTRY_TLS")
    report["has_rich_header"] = hasattr(pe, "RICH_HEADER") and bool(getattr(pe, "RICH_HEADER", None))
    report["has_signature"] = bool(pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].Size) if len(pe.OPTIONAL_HEADER.DATA_DIRECTORY) > 4 else False
    if report["has_signature"]:
        add(found, "info", "authenticode", "Authenticode signature directory present",
            "signature may be invalid after patching — verify with signtool")
    if report["has_tls"]:
        add(found, "low", "tls-callbacks", "TLS directory present",
            "TLS callbacks run before entry point: check for anti-debug/packing")

    # entry point bytes
    try:
        ep_rva = pe.OPTIONAL_HEADER.AddressOfEntryPoint
        ep_off = pe.get_offset_from_rva(ep_rva)
        with open(path, "rb") as f:
            f.seek(ep_off)
            report["entry_bytes"] = f.read(32).hex()
    except Exception:
        pass

    # .NET / Go / Rust heuristics
    dll_names = " ".join(imports.keys()).lower()
    if "mscoree.dll" in dll_names or "_cormain" in " ".join(
            sum(imports.values(), [])).lower():
        add(found, "info", "dotnet", ".NET assembly", "use dnSpy/ilspy, not native RE")
    for s in sections:
        if s["name"] == ".text" and s["entropy"] > 6.4 and "go" in path.lower():
            pass
    if any("runtime.morestack" in x for x in []) :
        pass

    return pe


# ---------------------------------------------------------------- ELF


def probe_elf(path: str, report, found):
    from elftools.elf.elffile import ELFFile  # type: ignore
    from elftools.elf.sections import SymbolTableSection  # type: ignore

    with open(path, "rb") as f:
        elf = ELFFile(f)
        hdr = OrderedDict()
        hdr["class"] = elf.elfclass
        hdr["endian"] = elf.little_endian
        hdr["type"] = elf.header.e_type
        hdr["machine"] = elf.header.e_machine
        hdr["entry"] = hex(elf.header.e_entry)
        report["elf"] = hdr
        sections = []
        for sec in elf.iter_sections():
            try:
                data = sec.data()
            except Exception:
                data = b""
            ent = entropy(data) if data else 0.0
            sections.append({
                "name": sec.name,
                "type": sec["sh_type"],
                "addr": hex(sec["sh_addr"]),
                "size": sec["sh_size"],
                "entropy": round(ent, 3),
            })
            if ent > 7.2 and sec["sh_size"] > 4096:
                add(found, "medium", "high-entropy-section",
                    f"section {sec.name} entropy {ent:.2f}", "packed/encrypted")
        report["sections"] = sections

        imports, exports = [], []
        for sec in elf.iter_sections():
            if isinstance(sec, SymbolTableSection):
                for sym in sec.iter_symbols():
                    if not sym.name:
                        continue
                    if sym["st_info"]["bind"] == "STB_GLOBAL" and sym["st_shndx"] == "SHN_UNDEF":
                        imports.append(sym.name)
                    elif sym["st_info"]["type"] in ("STT_FUNC",) and sym["st_shndx"] != "SHN_UNDEF":
                        exports.append(sym.name)
        report["imports"] = sorted(set(imports))[:400]
        report["exports"] = sorted(set(exports))[:400]
        report["import_func_count"] = len(set(imports))
        report["export_count"] = len(set(exports))
        hits = []
        for fn in set(imports):
            for cat, names in SUSPICIOUS_APIS.items():
                if fn in names:
                    hits.append(f"{cat}:{fn}")
        if hits:
            add(found, "medium", "api-categories", ", ".join(hits[:8]), "capability present")
        if not imports:
            add(found, "high", "no-imports", "no dynamic imports",
                "static binary, stripped, or packed")


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--strings", action="store_true", help="include string summary")
    ap.add_argument("--max-strings", type=int, default=4000)
    args = ap.parse_args()

    path = os.path.abspath(args.file)
    if not os.path.isfile(path):
        print(json.dumps({"error": f"not a file: {path}"}))
        return 2

    size = os.path.getsize(path)
    with open(path, "rb") as f:
        magic = f.read(4)

    report = OrderedDict()
    report["tool"] = "kai.probe/1"
    report["file"] = path
    report["size"] = size
    report["sha256"] = sha256(path)
    report["md5"] = md5(path)
    found = []

    if magic[:2] == b"MZ":
        report["kind"] = "pe"
        try:
            probe_pe(path, report, found)
        except Exception as exc:  # noqa: BLE001
            add(found, "info", "pe-parse-error", f"pefile failed: {exc}")
    elif magic == b"\x7fELF":
        report["kind"] = "elf"
        try:
            probe_elf(path, report, found)
        except Exception as exc:  # noqa: BLE001
            add(found, "info", "elf-parse-error", f"pyelftools failed: {exc}")
    elif magic[:4] in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        report["kind"] = "macho"
    else:
        report["kind"] = "unknown"
        add(found, "info", "unknown-format", f"magic {magic.hex()}",
            "not PE/ELF/Mach-O; try strings/binwalk/firmware triage")

    # whole-file entropy
    with open(path, "rb") as f:
        whole = f.read(min(size, 16 << 20))
    report["file_entropy"] = round(entropy(whole), 3)
    if report["file_entropy"] > 7.4 and report["kind"] != "pe":
        add(found, "medium", "high-file-entropy",
            f"file entropy {report['file_entropy']:.2f}", "encrypted or compressed container")

    if args.strings:
        strings, _ = collect_strings(path)
        interesting = []
        seen = set()
        for s in strings:
            low = s.lower()
            for kw in INTERESTING:
                if kw in low and s not in seen and len(s) < 300:
                    seen.add(s)
                    interesting.append(s)
                    break
            if len(interesting) >= args.max_strings:
                break
        urls = sorted({s for s in strings if re.match(r"^(https?|ftp|ws)://", s)})[:80]
        paths = sorted({s for s in strings if re.match(r"^[A-Za-z]:\\", s)})[:60]
        report["strings"] = {
            "total": len(strings),
            "urls": urls,
            "win_paths": paths,
            "interesting": interesting[: args.max_strings],
        }

    found.sort(key=lambda x: -SEVERITY_ORDER.get(x["severity"], 0))
    report["findings"] = found
    report["severity_max"] = found[0]["severity"] if found else "none"
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
