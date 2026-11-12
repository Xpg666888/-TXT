#!/usr/bin/env node
/**
 * kai — 逆向 / 破解 / 渗透 的能力内核（case + evidence + oracle 闭环）
 *
 * 设计要点：不是再堆一个工具，而是给「已有工具 + 模型」加三样东西
 *   1) 账本（case / claim / evidence）：任何结论必须挂证据，可回溯、可复现
 *   2) 判据（oracle）：probe / diff / run 产出机器可读事实，禁止口头结论
 *   3) 路由（kb / doctor）：任务该走哪条链路、本机缺什么，一眼可见
 *
 * 零依赖：只用 node 内置模块。深度分析委托给 runtime/venv 里的 python。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const KAI_ROOT = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const PY = path.join(KAI_ROOT, 'runtime', 'venv', 'Scripts', 'python.exe');
const PY_FALLBACK = path.join(KAI_ROOT, 'runtime', 'python', 'cpython-3.12.14-windows-x86_64-none', 'python.exe');
const VENDOR_SKILLS = path.join(KAI_ROOT, 'vendor', 'hack-skills', 'skills');
const CASES_DIR = path.join(KAI_ROOT, 'cases');
const DSH_HOME = process.env.DSH_HOME || 'E:\\逆向\\deepseek-harness\\.dsh';

const C = {
  reset: '\x1b[0m', dim: '\x1b[2m', bold: '\x1b[1m',
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m',
  blue: '\x1b[36m', magenta: '\x1b[35m',
};
const useColor = process.stdout.isTTY;
const paint = (c, s) => (useColor ? `${C[c]}${s}${C.reset}` : s);
const log = (...a) => console.log(...a);

// ---------------------------------------------------------------- utils

function sha256File(p) {
  const h = crypto.createHash('sha256');
  const fd = fs.openSync(p, 'r');
  const buf = Buffer.allocUnsafe(1 << 20);
  try {
    let n;
    while ((n = fs.readSync(fd, buf, 0, buf.length, null)) > 0) h.update(buf.subarray(0, n));
  } finally { fs.closeSync(fd); }
  return h.digest('hex');
}

function sha256Text(s) { return crypto.createHash('sha256').update(s).digest('hex'); }

function nowIso() { return new Date().toISOString(); }

function ensureDir(p) { fs.mkdirSync(p, { recursive: true }); return p; }

function readJsonl(p) {
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => {
    try { return JSON.parse(l); } catch { return { _corrupt: l }; }
  });
}

function appendJsonl(p, obj) {
  ensureDir(path.dirname(p));
  fs.appendFileSync(p, JSON.stringify(obj) + '\n', 'utf8');
}

function humanSize(n) {
  if (n < 1024) return `${n}B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)}KB`;
  return `${(n / 1024 ** 2).toFixed(2)}MB`;
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { out._.push(...argv.slice(i + 1)); break; }
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) { out[k] = next; i++; }
      else out[k] = true;
    } else out._.push(a);
  }
  return out;
}

function pythonExe() {
  if (fs.existsSync(PY)) return PY;
  if (fs.existsSync(PY_FALLBACK)) return PY_FALLBACK;
  return null;
}

/** 子进程统一 UTF-8，避免 Windows GBK 控制台把 JSON 打断。 */
function pyEnv() {
  return { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' };
}

// ---------------------------------------------------------------- PE section map (for diff annotation)

function peSections(buf) {
  try {
    if (buf.readUInt16LE(0) !== 0x5a4d) return null;
    const e_lfanew = buf.readUInt32LE(0x3c);
    if (buf.readUInt32LE(e_lfanew) !== 0x00004550) return null;
    const coff = e_lfanew + 4;
    const numSec = buf.readUInt16LE(coff + 2);
    const optSize = buf.readUInt16LE(coff + 16);
    const opt = coff + 20;
    const imageBase = buf.readUInt32LE(opt + 28);
    const secTab = opt + optSize;
    const secs = [];
    for (let i = 0; i < numSec; i++) {
      const o = secTab + i * 40;
      if (o + 40 > buf.length) break;
      const name = buf.subarray(o, o + 8).toString('latin1').replace(/\0+$/, '');
      const vsize = buf.readUInt32LE(o + 8);
      const vaddr = buf.readUInt32LE(o + 12);
      const rawSize = buf.readUInt32LE(o + 16);
      const rawPtr = buf.readUInt32LE(o + 20);
      secs.push({ name, vaddr, vsize, rawSize, rawPtr, imageBase });
    }
    return { secs, imageBase };
  } catch { return null; }
}

function mapOffsetToSection(pe, off) {
  if (!pe) return '?';
  for (const s of pe.secs) {
    if (off >= s.rawPtr && off < s.rawPtr + s.rawSize) {
      return `${s.name}+0x${(off - s.rawPtr).toString(16)} (va 0x${(s.imageBase + s.vaddr + (off - s.rawPtr)).toString(16)})`;
    }
  }
  return 'header/overlay';
}

// ---------------------------------------------------------------- case ledger

function caseDir(name) { return path.join(CASES_DIR, name); }

function loadCase(name) {
  const dir = caseDir(name);
  const metaPath = path.join(dir, 'case.json');
  if (!fs.existsSync(metaPath)) return null;
  return JSON.parse(fs.readFileSync(metaPath, 'utf8'));
}

function openCase(name, create = false) {
  let meta = loadCase(name);
  if (!meta) {
    if (!create) throw new Error(`case 不存在: ${name}（先 kai case init ${name}）`);
    const dir = ensureDir(caseDir(name));
    ensureDir(path.join(dir, 'artifacts'));
    meta = {
      id: name,
      created: nowIso(),
      targets: [],
      notes: '',
    };
    fs.writeFileSync(path.join(dir, 'case.json'), JSON.stringify(meta, null, 2), 'utf8');
    fs.writeFileSync(path.join(dir, 'claims.jsonl'), '', 'utf8');
    fs.writeFileSync(path.join(dir, 'evidence.jsonl'), '', 'utf8');
    fs.writeFileSync(path.join(dir, 'README.md'),
      `# case: ${name}\n\n- 账本：claims.jsonl（结论） / evidence.jsonl（证据） / artifacts/（原始产物）\n- 规则：没有 evidence_id 的 claim 不能写进报告；verified 的 claim 必须指向 evidence。\n`, 'utf8');
  }
  return meta;
}

function addEvidence(caseName, ev) {
  const dir = caseDir(caseName);
  const list = readJsonl(path.join(dir, 'evidence.jsonl'));
  const id = `E${String(list.length + 1).padStart(3, '0')}`;
  const rec = { id, ts: nowIso(), ...ev };
  appendJsonl(path.join(dir, 'evidence.jsonl'), rec);
  return rec;
}

function addClaim(caseName, text, extra = {}) {
  const dir = caseDir(caseName);
  const list = readJsonl(path.join(dir, 'claims.jsonl'));
  const id = `C${String(list.length + 1).padStart(3, '0')}`;
  const rec = { id, ts: nowIso(), claim: text, status: 'inferred', evidence: [], ...extra };
  appendJsonl(path.join(dir, 'claims.jsonl'), rec);
  return rec;
}

function updateClaim(caseName, id, patchFn) {
  const dir = caseDir(caseName);
  const p = path.join(dir, 'claims.jsonl');
  const list = readJsonl(p);
  let hit = null;
  const next = list.map((c) => {
    if (c.id === id) { hit = patchFn(c); return hit; }
    return c;
  });
  fs.writeFileSync(p, next.map((c) => JSON.stringify(c)).join('\n') + '\n', 'utf8');
  return hit;
}

// ---------------------------------------------------------------- commands

function cmdDoctor() {
  const py = pythonExe();
  const checks = [];
  // 便携工具链落在 E:\tools（NTFS）；harness 进程的 PATH 可能还是旧快照，所以直接扫目录兜底
  const TOOL_DIRS = [
    'E:\\tools\\bin', 'E:\\tools\\go\\bin', 'E:\\tools\\radare2\\bin', 'E:\\tools\\x64dbg\\release\\x64',
    'E:\\tools\\dnSpy', 'E:\\tools\\nmap', 'E:\\tools\\ffuf', 'E:\\tools\\nuclei', 'E:\\tools\\subfinder',
    'E:\\tools\\httpx', 'E:\\tools\\7zip', 'E:\\tools\\sysinternals', 'E:\\tools\\mimikatz\\x64',
    'E:\\tools\\chisel', 'E:\\tools\\dotnet-sdk', 'E:\\tools\\uv-tools\\bin', 'E:\\tools\\ghidra\\support',
    'E:\\tools\\dotnet-tools',
  ];
  const bin = (name) => {
    const r = spawnSync('where.exe', [name], { encoding: 'utf8' });
    if (r.status === 0) return r.stdout.split(/\r?\n/)[0].trim();
    for (const d of TOOL_DIRS) {
      for (const ext of ['.exe', '.cmd', '.bat']) {
        const p = path.join(d, name + ext);
        if (fs.existsSync(p)) return p;
      }
    }
    if (name.startsWith('ghidra')) {
      const base = 'E:\\tools\\ghidra';
      if (fs.existsSync(base)) {
        for (const sub of fs.readdirSync(base)) {
          const p = path.join(base, sub, 'support', 'analyzeHeadless.bat');
          if (fs.existsSync(p)) return p;
        }
      }
    }
    return null;
  };
  checks.push(['node', process.version, true]);
  checks.push(['python(venv)', py || '缺失', !!py]);
  if (py) {
    const r = spawnSync(py, ['-c', 'import pefile,capstone,lief;from elftools.elf.elffile import ELFFile;print("ok")'], { encoding: 'utf8' });
    checks.push(['py pkgs (pefile/capstone/lief/pyelftools)', (r.stdout || r.stderr).trim().slice(0, 40), r.status === 0]);
  }
  const tools = [
    ['docker', 'rikune Analyzer 容器 / CyberStrikeAI 容器'],
    ['wsl', 'rikune 需要 Linux kernel（WSL2 发行版）'],
    ['go', 'CyberStrikeAI 源码构建 / 自举工具'],
    ['git', '拉取样本仓库'],
    ['java', 'Ghidra / jadx'],
    ['analyzeHeadless', 'Ghidra 反编译（E:\\tools\\ghidra\\support）'],
    ['r2', 'radare2 快速反汇编'],
    ['rabin2', 'radare2 二进制信息'],
    ['dnSpy', '.NET 反编译 GUI'],
    ['ilspycmd', '.NET 反编译 CLI'],
    ['x64dbg', '动态调试'],
    ['frida', '动态插桩 / SSL pinning'],
    ['adb', 'Android 样本'],
    ['nmap', '渗透侦察'],
    ['sqlmap', 'SQL 注入'],
    ['ffuf', '目录/接口爆破'],
    ['nuclei', '漏洞模板扫描'],
    ['subfinder', '子域枚举'],
    ['httpx', '存活探测'],
    ['7za', '压缩包处理'],
    ['chisel', '隧道'],
    ['mimikatz', '凭据提取'],
  ];
  for (const [n, why] of tools) {
    const p = bin(n.split(' ')[0]);
    checks.push([n, p || '缺失', !!p, why]);
  }

  log(paint('bold', '\n=== kai doctor ==='));
  const pad = Math.max(...checks.map((c) => c[0].length)) + 2;
  for (const [name, val, ok, why] of checks) {
    const mark = ok ? paint('green', 'OK  ') : paint('red', '--  ');
    log(`${mark}${name.padEnd(pad)} ${String(val).slice(0, 60)}${why && !ok ? paint('dim', `   ← ${why}`) : ''}`);
  }

  const skillsDir = path.join(DSH_HOME, 'skills');
  const nSkills = fs.existsSync(skillsDir)
    ? fs.readdirSync(skillsDir).filter((d) => fs.existsSync(path.join(skillsDir, d, 'SKILL.md'))).length : 0;
  const nVendor = fs.existsSync(VENDOR_SKILLS) ? fs.readdirSync(VENDOR_SKILLS).length : 0;
  log(paint('bold', '\n=== 知识层 ==='));
  log(`   本地知识库 vendor/hack-skills : ${nVendor} skills`);
  log(`   DSH 技能根 $DSH_HOME/skills  : ${nSkills} skills  ${nSkills === 0 ? paint('yellow', '(kai skills install 一键注入)') : ''}`);

  const missingCritical = checks.filter((c) => !c[2]).map((c) => c[0]);
  log(paint('bold', '\n=== 结论 ==='));
  log(`   可用链路：${py ? '本地静态闭环 (probe/dis/diff/patch)' : '仅 JS 回退链路'}`);
  log(`   缺口：${missingCritical.join(', ') || '无'}`);
  log(paint('dim', '   安装建议：winget install Docker.DockerDesktop  |  wsl --install -d Ubuntu  |  uv tool install frida-tools  |  pip install pwntools angr'));
  log('');
}

function cmdProbe(args) {
  const file = args._[0];
  if (!file) throw new Error('用法: kai probe <file> [--case NAME] [--json]');
  const abs = path.resolve(file);
  const py = pythonExe();
  if (!py) throw new Error('缺少 python venv：先运行 kai install（或 uv venv + uv pip install pefile capstone lief pyelftools）');
  const argv = [path.join(KAI_ROOT, 'py', 'probe.py'), abs, '--strings'];
  const r = spawnSync(py, argv, { encoding: 'utf8', maxBuffer: 64 << 20, env: pyEnv() });
  if (r.status !== 0) throw new Error(`probe 失败: ${r.stderr || r.stdout}`);
  const report = JSON.parse(r.stdout);

  if (args.case) {
    const dir = ensureDir(path.join(caseDir(args.case), 'artifacts'));
    const artName = `probe-${path.basename(abs)}-${report.sha256.slice(0, 12)}.json`;
    const artPath = path.join(dir, artName);
    fs.writeFileSync(artPath, JSON.stringify(report, null, 2), 'utf8');
    const meta = openCase(args.case, true);
    if (!meta.targets.find((t) => t.sha256 === report.sha256)) {
      meta.targets.push({ path: abs, sha256: report.sha256, size: report.size, kind: report.kind });
      fs.writeFileSync(path.join(caseDir(args.case), 'case.json'), JSON.stringify(meta, null, 2), 'utf8');
    }
    const ev = addEvidence(args.case, {
      kind: 'probe',
      file: abs,
      sha256: report.sha256,
      artifact: path.relative(caseDir(args.case), artPath),
      summary: {
        kind: report.kind,
        findings: report.findings.length,
        severity_max: report.severity_max,
        sections: (report.sections || []).length,
        imports: report.import_func_count ?? null,
      },
    });
    log(paint('green', `evidence ${ev.id} 已入账`) + paint('dim', ` → ${path.relative(KAI_ROOT, artPath)}`));
  }

  if (args.json) { log(JSON.stringify(report, null, 2)); return; }

  log(paint('bold', `\n=== ${path.basename(abs)} ===`));
  log(`kind=${report.kind}  size=${humanSize(report.size)}  entropy=${report.file_entropy}`);
  log(`sha256=${report.sha256}`);
  if (report.pe) {
    const p = report.pe;
    log(`arch=${p.machine_name}  imagebase=${p.image_base}  entry=${p.entry_point_rva}  imphash=${p.imphash}`);
    log(`aslr=${p.aslr} dep=${p.dep} cfg=${p.cfg} signed=${report.has_signature} tls=${report.has_tls}`);
  }
  if (report.sections) {
    log(paint('bold', '\n-- sections --'));
    for (const s of report.sections) {
      const flags = [s.exec ? 'X' : '-', s.write ? 'W' : '-', s.read ? 'R' : '-'].join('');
      log(`   ${String(s.name).padEnd(10)} ${flags}  raw=${String(s.raw_size).padStart(8)}  entropy=${String(s.entropy).padStart(6)}`);
    }
  }
  if (report.api_categories) {
    log(paint('bold', '\n-- API 能力 --'));
    for (const [k, v] of Object.entries(report.api_categories)) log(`   ${k.padEnd(18)} ${v.slice(0, 8).join(', ')}`);
  }
  if (report.findings?.length) {
    log(paint('bold', '\n-- findings --'));
    for (const f of report.findings) {
      const col = f.severity === 'high' ? 'red' : f.severity === 'medium' ? 'yellow' : 'dim';
      log(`   ${paint(col, `[${f.severity}]`.padEnd(9))} ${f.title}${f.detail ? paint('dim', ` — ${f.detail}`) : ''}`);
    }
  }
  if (report.strings) {
    const s = report.strings;
    log(paint('bold', '\n-- strings --'));
    log(`   total=${s.total}  urls=${s.urls.length}  win_paths=${s.win_paths.length}  interesting=${s.interesting.length}`);
    for (const u of s.urls.slice(0, 6)) log(paint('dim', `   url  ${u}`));
    for (const i of s.interesting.slice(0, 14)) log(paint('dim', `   hit  ${i.slice(0, 140)}`));
  }
  log('');
}

function cmdDis(args) {
  const file = args._[0];
  if (!file) throw new Error('用法: kai dis <file> --rva 0x.. | --offset 0x.. [--len N] [--arch x64]');
  const py = pythonExe();
  if (!py) throw new Error('缺少 python venv');
  const argv = [path.join(KAI_ROOT, 'py', 'disasm.py'), path.resolve(file)];
  for (const k of ['rva', 'offset', 'len', 'arch', 'base']) if (args[k] !== undefined) argv.push(`--${k}`, String(args[k]));
  const r = spawnSync(py, argv, { encoding: 'utf8', maxBuffer: 32 << 20, env: pyEnv() });
  if (r.status !== 0) throw new Error(r.stderr || r.stdout);
  const out = JSON.parse(r.stdout);
  for (const i of out.insns) log(`   ${i.addr.padEnd(12)} ${i.bytes.padEnd(24)} ${i.mnemonic} ${i.op_str}`);
  log(paint('dim', `\n   ${out.count} insns @ ${out.offset}`));
}

/** 把参数原样透传给 python 脚本（emu / solve 这类多值参数不适合通用 parseArgs）。 */
function runPyRaw(script, rawArgs) {
  const py = pythonExe();
  if (!py) throw new Error('缺少 python venv：先 kai install');
  const r = spawnSync(py, [path.join(KAI_ROOT, 'py', script), ...rawArgs], {
    encoding: 'utf8',
    maxBuffer: 64 << 20,
    timeout: 900000,
    env: pyEnv(),
  });
  const out = (r.stdout || '').trim();
  const err = (r.stderr || '').trim();
  if (!out && err) throw new Error(err);
  try {
    const j = JSON.parse(out);
    log(JSON.stringify(j, null, 2));
    if (j.error) log(paint('yellow', `\n   emu error: ${j.error}`));
  } catch {
    if (out) log(out);
    if (err) log(paint('dim', err.slice(0, 800)));
  }
  return r.status;
}

function cmdEmu(raw) {
  if (!raw.length) throw new Error('用法: kai emu <file> --rva 0x.. [--reg rcx=0x..] [--write 0xADDR:hex] [--dump 0xADDR:len] [--arch x64] [--max-insns N]');
  return runPyRaw('emu.py', raw);
}

function cmdSolve(raw) {
  if (!raw.length) throw new Error('用法: kai solve <file> --find 0xADDR [--avoid 0xADDR] [--mode stdin|argv] [--length N] [--charset alnum]');
  return runPyRaw('solve.py', raw);
}

function cmdMem(raw) {
  if (!raw.length) throw new Error('用法: kai mem (--pid N | --name proc.exe) mods|scan|next|read|write|aob ...');
  return runPyRaw('mem.py', raw);
}

function cmdDiff(args) {
  const [a, b] = args._;
  if (!a || !b) throw new Error('用法: kai diff <orig> <patched> [--case NAME] [--limit N]');
  const pa = path.resolve(a), pb = path.resolve(b);
  const A = fs.readFileSync(pa), B = fs.readFileSync(pb);
  const n = Math.min(A.length, B.length);
  const ranges = [];
  let cur = null;
  for (let i = 0; i < n; i++) {
    if (A[i] !== B[i]) {
      if (cur && i === cur.end + 1) cur.end = i;
      else { cur = { start: i, end: i }; ranges.push(cur); }
    }
  }
  const peA = peSections(A), peB = peSections(B);
  const limit = args.limit ? parseInt(args.limit, 10) : 200;
  const shaA = sha256File(pa), shaB = sha256File(pb);

  log(paint('bold', `\n=== diff ===`));
  log(`orig    ${path.basename(pa)}  ${humanSize(A.length)}  ${shaA}`);
  log(`patched ${path.basename(pb)}  ${humanSize(B.length)}  ${shaB}`);
  log(`changed bytes: ${ranges.reduce((s, r) => s + (r.end - r.start + 1), 0)} in ${ranges.length} range(s)`);
  if (A.length !== B.length) log(paint('yellow', `size differs: ${A.length} → ${B.length} (插入/截断，注意 PE 校验与对齐)`));

  const table = ranges.slice(0, limit).map((r) => {
    const len = r.end - r.start + 1;
    return {
      offset: `0x${r.start.toString(16)}`,
      len,
      section: mapOffsetToSection(peA, r.start),
      from: A.subarray(r.start, Math.min(r.end + 1, r.start + 16)).toString('hex'),
      to: B.subarray(r.start, Math.min(r.end + 1, r.start + 16)).toString('hex'),
    };
  });
  log(paint('bold', '\n-- ranges --'));
  for (const t of table) {
    log(`   ${t.offset.padEnd(12)} len=${String(t.len).padEnd(4)} ${t.section}`);
    log(paint('dim', `      - ${t.from}`));
    log(paint('green', `      + ${t.to}`));
  }
  if (ranges.length > limit) log(paint('dim', `   ... 还有 ${ranges.length - limit} 段，用 --limit 调整`));

  if (args.case) {
    const dir = ensureDir(path.join(caseDir(args.case), 'artifacts'));
    const art = path.join(dir, `diff-${shaA.slice(0, 8)}-${shaB.slice(0, 8)}.json`);
    fs.writeFileSync(art, JSON.stringify({ orig: pa, patched: pb, shaA, shaB, ranges, table }, null, 2), 'utf8');
    openCase(args.case, true);
    const ev = addEvidence(args.case, {
      kind: 'diff',
      orig: pa, patched: pb, shaA, shaB,
      ranges: ranges.length,
      changed_bytes: ranges.reduce((s, r) => s + (r.end - r.start + 1), 0),
      artifact: path.relative(caseDir(args.case), art),
    });
    log(paint('green', `\nevidence ${ev.id} 已入账`) + paint('dim', ` → ${path.relative(KAI_ROOT, art)}`));
  }
  log('');
}

function cmdPatch(args) {
  const file = args._[0];
  if (!file) throw new Error('用法: kai patch <file> --offset 0x.. --bytes "90 90" --out <file> [--case NAME]');
  const off = args.offset !== undefined ? Number(args.offset) : NaN;
  if (Number.isNaN(off)) throw new Error('需要 --offset');
  const bytes = String(args.bytes || '').replace(/[^0-9a-fA-F]/g, '');
  if (!bytes.length || bytes.length % 2) throw new Error('--bytes 需要十六进制，如 "90 90" 或 "EB"');
  const buf = Buffer.from(fs.readFileSync(path.resolve(file)));
  const patch = Buffer.from(bytes, 'hex');
  if (off < 0 || off + patch.length > buf.length) throw new Error('offset 越界');
  const before = buf.subarray(off, off + patch.length).toString('hex');
  patch.copy(buf, off);
  const out = path.resolve(args.out || file.replace(/(\.[^.]+)$/, '.patched$1'));
  fs.writeFileSync(out, buf);
  log(paint('bold', '\n=== patch ==='));
  log(`   ${path.basename(file)} @ 0x${off.toString(16)}`);
  log(paint('dim', `   - ${before}`));
  log(paint('green', `   + ${patch.toString('hex')}`));
  log(`   → ${out}`);
  if (args.case) {
    openCase(args.case, true);
    const ev = addEvidence(args.case, {
      kind: 'patch', file: path.resolve(file), offset: `0x${off.toString(16)}`,
      before, after: patch.toString('hex'), out, out_sha256: sha256File(out),
    });
    log(paint('green', `evidence ${ev.id} 已入账`));
  }
  log('');
}

function cmdRun(args) {
  const cmd = args._;
  if (!cmd.length) throw new Error('用法: kai run [--case NAME] -- <command...>');
  const t0 = Date.now();
  const r = spawnSync(cmd[0], cmd.slice(1), { encoding: 'utf8', maxBuffer: 32 << 20, shell: false });
  const dur = Date.now() - t0;
  const stdout = r.stdout || '', stderr = r.stderr || '';
  log(paint('bold', `\n=== run ===`));
  log(`   ${cmd.join(' ')}`);
  log(`   exit=${r.status}  ${dur}ms  stdout=${stdout.length}B stderr=${stderr.length}B`);
  if (stdout) log(paint('dim', stdout.split('\n').slice(0, 30).join('\n')));
  if (stderr) log(paint('yellow', stderr.split('\n').slice(0, 15).join('\n')));
  if (args.case) {
    openCase(args.case, true);
    const dir = ensureDir(path.join(caseDir(args.case), 'artifacts'));
    const art = path.join(dir, `run-${Date.now()}.log`);
    fs.writeFileSync(art, `$ ${cmd.join(' ')}\nexit=${r.status}\n\n[stdout]\n${stdout}\n\n[stderr]\n${stderr}\n`, 'utf8');
    const ev = addEvidence(args.case, {
      kind: 'run', cmd: cmd.join(' '), exit: r.status, duration_ms: dur,
      stdout_sha256: sha256Text(stdout), artifact: path.relative(caseDir(args.case), art),
    });
    log(paint('green', `evidence ${ev.id} 已入账`));
  }
  log('');
  process.exitCode = r.status === 0 ? 0 : 0; // 记录而非中断
}

function cmdCase(args) {
  const sub = args._[0];
  if (sub === 'init') {
    const name = args._[1];
    if (!name) throw new Error('用法: kai case init <name>');
    const meta = openCase(name, true);
    log(paint('green', `case ${name} 就绪 → ${caseDir(name)}`));
    log(paint('dim', `  targets=${meta.targets.length}`));
    return;
  }
  if (sub === 'list') {
    if (!fs.existsSync(CASES_DIR)) return log('(还没有 case)');
    for (const d of fs.readdirSync(CASES_DIR)) {
      const m = loadCase(d);
      if (!m) continue;
      const claims = readJsonl(path.join(caseDir(d), 'claims.jsonl'));
      const evs = readJsonl(path.join(caseDir(d), 'evidence.jsonl'));
      log(`${d.padEnd(28)} targets=${m.targets.length} claims=${claims.length} (verified=${claims.filter((c) => c.status === 'verified').length}) evidence=${evs.length}`);
    }
    return;
  }
  if (sub === 'show') {
    const name = args._[1];
    const m = openCase(name);
    const claims = readJsonl(path.join(caseDir(name), 'claims.jsonl'));
    const evs = readJsonl(path.join(caseDir(name), 'evidence.jsonl'));
    log(paint('bold', `\ncase ${name}  (${m.created})`));
    log(paint('bold', '\n-- targets --'));
    for (const t of m.targets) log(`   ${t.kind.padEnd(5)} ${humanSize(t.size).padStart(8)}  ${t.sha256.slice(0, 16)}  ${t.path}`);
    log(paint('bold', '\n-- claims --'));
    for (const c of claims) {
      const col = c.status === 'verified' ? 'green' : c.status === 'refuted' ? 'red' : 'yellow';
      log(`   ${c.id} ${paint(col, `[${c.status}]`.padEnd(11))} ${c.claim}  ${paint('dim', c.evidence.join(','))}`);
    }
    log(paint('bold', '\n-- evidence --'));
    for (const e of evs) log(`   ${e.id} ${e.kind.padEnd(8)} ${JSON.stringify(e.summary || e.cmd || e.artifact || '').slice(0, 110)}`);
    log('');
    return;
  }
  throw new Error('用法: kai case init|list|show');
}

function cmdClaim(args) {
  const sub = args._[0];
  if (sub === 'add') {
    const name = args.case;
    if (!name) throw new Error('需要 --case NAME');
    openCase(name, true);
    const text = args._.slice(1).join(' ');
    if (!text) throw new Error('用法: kai claim add --case NAME "结论文字" [--evidence E001]');
    const ev = args.evidence ? String(args.evidence).split(',') : [];
    const rec = addClaim(name, text, { evidence: ev, status: ev.length ? 'supported' : 'inferred' });
    log(`${paint('green', rec.id)} ${rec.claim}  ${paint('dim', `[${rec.status}]`)}`);
    return;
  }
  if (sub === 'list') {
    const name = args.case;
    for (const c of readJsonl(path.join(caseDir(name), 'claims.jsonl'))) {
      log(`${c.id} [${c.status}] ${c.claim} ${c.evidence.join(',')}`);
    }
    return;
  }
  throw new Error('用法: kai claim add|list');
}

function cmdVerify(args) {
  const id = args._[0];
  const name = args.case;
  if (!id || !name) throw new Error('用法: kai verify <C001> --case NAME --evidence E001[,E002] [--note "复现命令"]');
  const evIds = String(args.evidence || '').split(',').filter(Boolean);
  if (!evIds.length) throw new Error('verify 必须给出 --evidence（没有证据的结论只能是 inferred）');
  const evs = readJsonl(path.join(caseDir(name), 'evidence.jsonl'));
  const missing = evIds.filter((e) => !evs.find((x) => x.id === e));
  if (missing.length) throw new Error(`证据不存在: ${missing.join(',')}`);
  const rec = updateClaim(name, id, (c) => ({
    ...c,
    status: 'verified',
    evidence: [...new Set([...(c.evidence || []), ...evIds])],
    verified_at: nowIso(),
    verify_note: args.note || '',
  }));
  if (!rec) throw new Error(`claim 不存在: ${id}`);
  log(paint('green', `✓ ${id} → verified`) + paint('dim', `  evidence ${evIds.join(',')}`));
}

function cmdReport(args) {
  const name = args.case;
  if (!name) throw new Error('用法: kai report --case NAME [--out file.md]');
  const m = openCase(name);
  const claims = readJsonl(path.join(caseDir(name), 'claims.jsonl'));
  const evs = readJsonl(path.join(caseDir(name), 'evidence.jsonl'));
  const L = [];
  L.push(`# 分析报告 — ${name}`);
  L.push('');
  L.push(`生成时间：${nowIso()}`);
  L.push('');
  L.push('## 样本');
  L.push('');
  L.push('| 类型 | 大小 | SHA-256 | 路径 |');
  L.push('|---|---|---|---|');
  for (const t of m.targets) L.push(`| ${t.kind} | ${humanSize(t.size)} | \`${t.sha256}\` | ${t.path} |`);
  L.push('');
  L.push('## 结论（只收录有证据的）');
  L.push('');
  const verified = claims.filter((c) => c.status === 'verified');
  const pending = claims.filter((c) => c.status !== 'verified');
  if (!verified.length) L.push('_（暂无 verified 结论）_');
  for (const c of verified) {
    L.push(`- **${c.id}** ${c.claim}`);
    L.push(`  - 证据：${c.evidence.join(', ')}`);
    if (c.verify_note) L.push(`  - 复现：\`${c.verify_note}\``);
  }
  L.push('');
  if (pending.length) {
    L.push('## 待验证假设');
    L.push('');
    for (const c of pending) L.push(`- ${c.id} [${c.status}] ${c.claim}`);
    L.push('');
  }
  L.push('## 证据清单');
  L.push('');
  L.push('| ID | 类型 | 摘要 | 产物 |');
  L.push('|---|---|---|---|');
  for (const e of evs) {
    const sum = e.summary ? JSON.stringify(e.summary) : (e.cmd || e.before ? `${e.before ?? ''} → ${e.after ?? ''}` : '');
    L.push(`| ${e.id} | ${e.kind} | ${String(sum).replace(/\|/g, '\\|').slice(0, 120)} | ${e.artifact || ''} |`);
  }
  L.push('');
  const md = L.join('\n');
  const out = args.out ? path.resolve(args.out) : path.join(caseDir(name), 'report.md');
  fs.writeFileSync(out, md, 'utf8');
  log(md);
  log(paint('green', `\n→ ${out}`));
}

// ---------------------------------------------------------------- knowledge base bridge

function loadSkillIndex() {
  if (!fs.existsSync(VENDOR_SKILLS)) return [];
  const out = [];
  for (const d of fs.readdirSync(VENDOR_SKILLS)) {
    const p = path.join(VENDOR_SKILLS, d, 'SKILL.md');
    if (!fs.existsSync(p)) continue;
    const text = fs.readFileSync(p, 'utf8');
    const fm = text.match(/^---\n([\s\S]*?)\n---/);
    let name = d, description = '';
    if (fm) {
      const nm = fm[1].match(/^name:\s*(.+)$/m);
      const de = fm[1].match(/^description:\s*([\s\S]*?)(?=\n\w+:|\n---)/m);
      if (nm) name = nm[1].trim();
      if (de) description = de[1].replace(/\s+/g, ' ').trim();
    }
    if (!description) {
      const firstPara = text.replace(/^---[\s\S]*?---/, '').split('\n').find((l) => l.trim() && !l.startsWith('#'));
      description = (firstPara || '').trim();
    }
    out.push({ id: d, name, description, path: p, text });
  }
  return out;
}

/** 中文任务词 → 知识库英文关键词（hack-skills 正文是英文，直接搜中文会空手而归）。 */
const CN_TERMS = {
  '卡密': ['license', 'serial', 'activation', 'keygen'],
  '注册码': ['serial', 'license', 'keygen'],
  '激活': ['activation', 'license'],
  '破解': ['crack', 'patch', 'bypass', 'keygen'],
  '脱壳': ['unpack', 'packer', 'packed', 'upx'],
  '加壳': ['packer', 'packed', 'upx'],
  '加固': ['packer', 'obfuscat', 'protection'],
  '免杀': ['av-evasion', 'amsi', 'etw', 'edr', 'shellcode'],
  '反调试': ['anti-debug', 'debugger', 'ptrace', 'peb'],
  '反虚拟机': ['anti-vm', 'virtual machine', 'sandbox'],
  '混淆': ['obfuscat', 'control flow', 'opaque'],
  '虚拟化': ['vmprotect', 'virtual machine', 'bytecode'],
  '提权': ['privilege escalation', 'privesc', 'suid'],
  '内网': ['lateral', 'pivot', 'tunnel', 'internal'],
  '隧道': ['tunnel', 'pivot', 'chisel', 'socks'],
  '注入': ['injection', 'sqli', 'xss', 'ssti', 'cmdi'],
  '渗透': ['pentest', 'recon', 'attack surface'],
  '信息收集': ['recon', 'osint', 'asset'],
  '抓包': ['traffic', 'pcap', 'proxy'],
  '爆破': ['brute', 'wordlist', 'password'],
  '上传': ['upload'],
  '越权': ['idor', 'authorization', 'bola'],
  '认证': ['auth', 'jwt', 'oauth', 'session'],
  '安卓': ['android', 'apk', 'frida'],
  '漏洞': ['vulnerab', 'exploit', 'cve'],
  '浏览器': ['browser', 'v8', 'sandbox escape'],
  '密码学': ['crypto', 'rsa', 'aes', 'lattice'],
  '取证': ['forensic', 'volatility', 'memory'],
  '样本分析': ['malware', 'triage', 'unpack'],
};

function expandTerms(q) {
  const terms = [q];
  for (const [cn, ens] of Object.entries(CN_TERMS)) {
    if (q.includes(cn)) terms.push(...ens);
  }
  return [...new Set(terms.map((t) => t.toLowerCase()))];
}

function cmdKb(args) {
  const q = args._.join(' ').toLowerCase();
  const idx = loadSkillIndex();
  if (!q) {
    log(`本地知识库：${idx.length} 个 skill（${VENDOR_SKILLS}）`);
    for (const s of idx.sort((a, b) => a.id.localeCompare(b.id))) log(`   ${s.id}`);
    return;
  }
  const terms = expandTerms(q);
  // 英文词按“词边界”匹配，避免 serial 命中 de-serial-ization 这类假阳性
  const countWord = (hay, term) => {
    if (!/^[\x20-\x7e]+$/.test(term)) return hay.split(term).length - 1;
    const esc = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = new RegExp(`(^|[^a-z0-9_])${esc}([^a-z0-9_]|$)`, 'g');
    let n = 0;
    while (re.exec(hay)) n++;
    return n;
  };
  const scored = idx.map((s) => {
    const id = s.id.toLowerCase();
    const desc = s.description.toLowerCase();
    const heads = (s.text.match(/^#+ .+$/gm) || []).join(' ').toLowerCase();
    const body = s.text.toLowerCase();
    let best = 0, matched = [];
    for (const t of terms) {
      let score = 0;
      if (id === t) score += 200;
      else if (countWord(id, t)) score += 80;
      if (countWord(s.name.toLowerCase(), t)) score += 30;
      if (countWord(desc, t)) score += 25;
      if (countWord(heads, t)) score += 15;
      score += Math.min(countWord(body, t), 4);
      if (score > 0) matched.push(t);
      best = Math.max(best, score);
    }
    const total = best + Math.max(0, matched.length - 1) * 2;
    return { s, score: total, matched };
  }).filter((x) => x.score > 0).sort((a, b) => b.score - a.score);

  if (!scored.length) { log(paint('yellow', `没有命中 "${q}"，试试 kai kb 列出全部`)); return; }
  log(paint('bold', `\n-- 命中 ${scored.length} 个（按相关度）--`));
  log(paint('dim', `   检索词：${terms.join(', ')}`));
  for (const { s, score, matched } of scored.slice(0, args.limit ? +args.limit : 8)) {
    log(`\n${paint('blue', s.id)}  ${paint('dim', `score=${score} via ${matched.slice(0, 5).join('/')}`)}`);
    log(`  ${s.description.slice(0, 220)}`);
    log(paint('dim', `  ${s.path}`));
  }
  log('');
}

function cmdSkill(args) {
  const id = args._[0];
  if (!id) throw new Error('用法: kai skill <id> [--full]');
  const p = path.join(VENDOR_SKILLS, id, 'SKILL.md');
  if (!fs.existsSync(p)) {
    const idx = loadSkillIndex().filter((s) => s.id.includes(id) || s.name.includes(id));
    log(`未找到 "${id}"，相近：${idx.map((s) => s.id).join(', ') || '无'}`);
    return;
  }
  const text = fs.readFileSync(p, 'utf8');
  if (args.full) { log(text); return; }
  const heads = text.match(/^#+ .+$/gm) || [];
  log(paint('bold', `\n${id}  ${paint('dim', p)}`));
  log(paint('dim', `行数=${text.split('\n').length}`));
  for (const h of heads) log(`   ${h}`);
  log(paint('dim', '\n用 --full 输出全文'));
}

const CURATED = [
  'hack', 'recon-for-sec', 'recon-and-methodology', 'attack-surface-mapping',
  'anti-debugging-techniques', 'code-obfuscation-deobfuscation', 'vm-and-bytecode-reverse',
  'symbolic-execution-tools', 'binary-protection-bypass', 'windows-av-evasion',
  'reverse-shell-techniques', 'tunneling-and-pivoting', 'upload-insecure-files',
  'path-traversal-lfi', 'sqli-sql-injection', 'xss-cross-site-scripting',
  'ssrf-server-side-request-forgery', 'deserialization-insecure', 'cmdi-command-injection',
  'jwt-oauth-token-attacks', 'idor-broken-object-authorization', 'authbypass-authentication-flaws',
  'waf-bypass-techniques', '401-403-bypass-techniques', 'linux-privilege-escalation',
  'windows-privilege-escalation', 'active-directory-kerberos-attacks',
  'hash-attack-techniques', 'android-pentesting-tricks', 'mobile-ssl-pinning-bypass',
];

function cmdSkills(args) {
  const sub = args._[0] || 'list';
  const idx = loadSkillIndex();
  const localDir = path.join(KAI_ROOT, 'skills');
  const locals = fs.existsSync(localDir)
    ? fs.readdirSync(localDir).filter((d) => fs.existsSync(path.join(localDir, d, 'SKILL.md'))) : [];
  if (sub === 'list') {
    for (const s of idx.sort((a, b) => a.id.localeCompare(b.id))) log(`   ${s.id}`);
    log(paint('bold', '\n   本地内核技能：'));
    for (const d of locals) log(`   ${d}`);
    return;
  }
  if (sub === 'install') {
    const dest = ensureDir(path.join(DSH_HOME, 'skills'));
    const want = args.all ? idx.map((s) => s.id) : CURATED.filter((id) => idx.find((s) => s.id === id));
    const copyTree = (src, dst) => {
      ensureDir(dst);
      for (const f of fs.readdirSync(src)) {
        const sp = path.join(src, f);
        if (fs.statSync(sp).isFile()) fs.copyFileSync(sp, path.join(dst, f));
        else if (fs.statSync(sp).isDirectory()) copyTree(sp, path.join(dst, f));
      }
    };
    let n = 0;
    for (const id of want) { copyTree(path.join(VENDOR_SKILLS, id), path.join(dest, id)); n++; }
    for (const d of locals) { copyTree(path.join(localDir, d), path.join(dest, d)); n++; }
    log(paint('green', `已注入 ${n} 个技能 → ${dest}`) + paint('dim', `（vendor ${want.length} + 内核 ${locals.length}）`));
    log(paint('dim', '   DSH 的 skill-filesystem 会监听该根，技能目录即时刷新，原生 skill 工具可直接加载。'));
    log(paint('dim', `   全量注入用 kai skills install --all（${idx.length} 个，会显著占目录 token）`));
    return;
  }
  throw new Error('用法: kai skills list|install [--all]');
}

// ---------------------------------------------------------------- main

const HELP = `kai — 逆向 / 破解 / 渗透 能力内核

  kai doctor                                   环境体检 + 缺口清单
  kai probe <file> [--case N] [--json]         静态深挖（PE/ELF：节区熵、导入、加壳、字符串、能力矩阵）
  kai dis <file> --rva 0x..|--offset 0x..      反汇编字节区间（capstone）
  kai diff <orig> <patched> [--case N]         字节级 diff + 节区/VA 映射
  kai patch <file> --offset 0x.. --bytes HEX --out F   打补丁并记录证据
  kai run [--case N] -- <cmd...>               执行并把 stdout/exit 入账（动态判据）
  kai case init|list|show <name>               case 账本
  kai claim add --case N "结论" [--evidence E] 记录结论（默认 inferred）
  kai verify <C001> --case N --evidence E001   结论升级为 verified（必须有证据）
  kai report --case N                          只输出有证据的结论
  kai kb [关键词]                              检索本地 hack-skills 知识库（103 个）
  kai skill <id> [--full]                      查看某个技能
  kai skills install [--all]                   把精选技能注入 $DSH_HOME/skills
`;

function main() {
  const [, , cmd, ...rest] = process.argv;
  const args = parseArgs(rest);
  try {
    switch (cmd) {
      case 'doctor': cmdDoctor(); break;
      case 'probe': cmdProbe(args); break;
      case 'dis': cmdDis(args); break;
      case 'mem': process.exitCode = cmdMem(rest); break;
      case 'emu': process.exitCode = cmdEmu(rest); break;
      case 'solve': process.exitCode = cmdSolve(rest); break;
      case 'diff': cmdDiff(args); break;
      case 'patch': cmdPatch(args); break;
      case 'run': cmdRun(args); break;
      case 'case': cmdCase(args); break;
      case 'claim': cmdClaim(args); break;
      case 'verify': cmdVerify(args); break;
      case 'report': cmdReport(args); break;
      case 'kb': cmdKb(args); break;
      case 'skill': cmdSkill(args); break;
      case 'skills': cmdSkills(args); break;
      default: log(HELP);
    }
  } catch (e) {
    console.error(paint('red', `kai: ${e.message}`));
    process.exit(2);
  }
}

main();




