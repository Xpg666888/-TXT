#!/usr/bin/env node
/**
 * kai MCP server (stdio) — 把 kai 能力内核暴露成 MCP 工具。
 *
 * 传输：stdio，JSON-RPC 2.0，按行分隔（MCP stdio 规范）。
 * 零依赖：只用 node 内置模块；实际工作委托给 bin/kai.mjs 与 py/。
 *
 * 工具名（在 DSH 里会变成 mcp__kai__<name>）：
 *   probe  dis  diff  patch  run  case  claim  verify  report  kb  doctor
 */
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const KAI_ROOT = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const KAI = path.join(KAI_ROOT, 'bin', 'kai.mjs');
const PY = path.join(KAI_ROOT, 'runtime', 'venv', 'Scripts', 'python.exe');
const VENDOR_SKILLS = path.join(KAI_ROOT, 'vendor', 'hack-skills', 'skills');

const SERVER_INFO = { name: 'kai', version: '1.0.0' };
const PROTOCOLS = ['2026-07-28', '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

// ---------------------------------------------------------------- 执行封装

function runKai(args, timeoutMs = 180000) {
  const r = spawnSync(process.execPath, [KAI, ...args], {
    encoding: 'utf8',
    maxBuffer: 128 << 20,
    timeout: timeoutMs,
    env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' },
  });
  const out = `${r.stdout || ''}${r.stderr ? `\n[stderr]\n${r.stderr}` : ''}`.trim();
  return { ok: r.status === 0, text: out || '(no output)', exit: r.status };
}

function runCmd(cmd, cwd, timeoutMs = 120000) {
  if (!Array.isArray(cmd) || !cmd.length) return { ok: false, text: 'cmd 需要是非空字符串数组' };
  const r = spawnSync(cmd[0], cmd.slice(1), { encoding: 'utf8', maxBuffer: 64 << 20, timeout: timeoutMs, cwd: cwd || undefined });
  const text = `exit=${r.status}\n[stdout]\n${r.stdout || ''}\n[stderr]\n${r.stderr || ''}`;
  return { ok: r.status === 0, text };
}

const text = (s) => ({ content: [{ type: 'text', text: String(s) }] });
const fail = (s) => ({ content: [{ type: 'text', text: `错误：${s}` }], isError: true });

// ---------------------------------------------------------------- 工具定义

const TOOLS = [
  {
    name: 'probe',
    title: '静态深挖 (PE/ELF)',
    description: '对样本做静态 triage：哈希、节区熵/RWX、加壳指纹、导入能力矩阵、overlay、TLS、PDB、字符串（URL/路径/卡密关键词）。传 case 时自动写入 evidence。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string', description: '样本绝对路径' },
        case: { type: 'string', description: '案子名（可选，写入账本）' },
      },
      required: ['file'],
    },
    handler: (a) => runKai(['probe', a.file, ...(a.case ? ['--case', a.case] : [])]),
  },
  {
    name: 'dis',
    title: '反汇编字节区间',
    description: '用 capstone 反汇编 PE/ELF 的指定区间。rva 走节区表换算，offset 直接按文件偏移。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string' },
        rva: { type: 'string', description: '如 0x76be（与 offset 二选一）' },
        offset: { type: 'string', description: '文件偏移，如 0x1000' },
        len: { type: 'string', description: '字节数，默认 128' },
        arch: { type: 'string', enum: ['x64', 'x86', 'arm64', 'arm'] },
      },
      required: ['file'],
    },
    handler: (a) => {
      if (!a.rva && !a.offset) return { ok: false, text: '需要 rva 或 offset' };
      const args = ['dis', a.file];
      if (a.rva) args.push('--rva', String(a.rva));
      if (a.offset) args.push('--offset', String(a.offset));
      if (a.len) args.push('--len', String(a.len));
      if (a.arch) args.push('--arch', a.arch);
      return runKai(args);
    },
  },
  {
    name: 'diff',
    title: '字节级 diff + 节区/VA 映射',
    description: '对比原版与改动版，输出变更区间、每段落在哪个节区、对应 VA，以及前后字节。破解/补丁的必备判据。',
    inputSchema: {
      type: 'object',
      properties: {
        orig: { type: 'string' },
        patched: { type: 'string' },
        case: { type: 'string' },
        limit: { type: 'string' },
      },
      required: ['orig', 'patched'],
    },
    handler: (a) => runKai(['diff', a.orig, a.patched, ...(a.case ? ['--case', a.case] : []), ...(a.limit ? ['--limit', String(a.limit)] : [])]),
  },
  {
    name: 'patch',
    title: '打补丁（写入副本）',
    description: '在指定文件偏移写入十六进制字节，输出到 --out 副本，并记录 before/after 证据。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string' },
        offset: { type: 'string', description: '如 0x1000' },
        bytes: { type: 'string', description: '如 "90 90" 或 "EB"' },
        out: { type: 'string', description: '输出副本路径' },
        case: { type: 'string' },
      },
      required: ['file', 'offset', 'bytes', 'out'],
    },
    handler: (a) => runKai(['patch', a.file, '--offset', String(a.offset), '--bytes', String(a.bytes), '--out', a.out, ...(a.case ? ['--case', a.case] : [])]),
  },
  {
    name: 'run',
    title: '执行命令并入账',
    description: '执行命令并记录 exit/stdout/stderr（stdout 哈希入账）。用于“改动前拒绝 / 改动后通过”这类动态判据。不经过 shell，需传数组。',
    inputSchema: {
      type: 'object',
      properties: {
        cmd: { type: 'array', items: { type: 'string' }, description: '如 ["curl","-sS","-i","https://TARGET/"]' },
        cwd: { type: 'string' },
      },
      required: ['cmd'],
    },
    handler: (a) => runCmd(a.cmd, a.cwd),
  },
  {
    name: 'case',
    title: '案子账本',
    description: 'init / list / show。每个案子有 case.json、claims.jsonl、evidence.jsonl 与 artifacts/。',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['init', 'list', 'show'] },
        name: { type: 'string' },
      },
      required: ['action'],
    },
    handler: (a) => runKai(['case', a.action, ...(a.name ? [a.name] : [])]),
  },
  {
    name: 'claim',
    title: '记录结论',
    description: 'add / list。结论默认 inferred；给了 evidence 则 supported。只有 verify 过的结论才进报告。',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['add', 'list'] },
        case: { type: 'string' },
        claim: { type: 'string' },
        evidence: { type: 'string', description: '逗号分隔的 evidence id' },
      },
      required: ['action', 'case'],
    },
    handler: (a) => {
      const args = ['claim', a.action, '--case', a.case];
      if (a.claim) args.push(a.claim);
      if (a.evidence) args.push('--evidence', a.evidence);
      return runKai(args);
    },
  },
  {
    name: 'verify',
    title: '结论升级为 verified',
    description: '必须给 evidence（逗号分隔）。没有证据的结论不能 verified——这是账本的核心约束。',
    inputSchema: {
      type: 'object',
      properties: {
        claim: { type: 'string', description: '如 C001' },
        case: { type: 'string' },
        evidence: { type: 'string' },
        note: { type: 'string', description: '复现命令' },
      },
      required: ['claim', 'case', 'evidence'],
    },
    handler: (a) => runKai(['verify', a.claim, '--case', a.case, '--evidence', a.evidence, ...(a.note ? ['--note', a.note] : [])]),
  },
  {
    name: 'report',
    title: '生成报告',
    description: '只把 verified 结论写进“结论”章节，其余进“待验证假设”，附证据清单与产物路径。',
    inputSchema: {
      type: 'object',
      properties: { case: { type: 'string' }, out: { type: 'string' } },
      required: ['case'],
    },
    handler: (a) => runKai(['report', '--case', a.case, ...(a.out ? ['--out', a.out] : [])]),
  },
  {
    name: 'kb',
    title: '检索 hack-skills 知识库',
    description: '在本地 103 个安全技能里检索（支持中文关键词自动扩展：卡密/脱壳/免杀/提权/内网…），返回命中技能与文件路径。',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string' }, limit: { type: 'string' } },
      required: ['query'],
    },
    handler: (a) => runKai(['kb', a.query, ...(a.limit ? ['--limit', String(a.limit)] : [])]),
  },
  {
    name: 'doctor',
    title: '环境体检',
    description: '检查 python venv/包、docker、wsl、ghidra、r2、frida、nmap、sqlmap 等，输出缺口与安装建议。',
    inputSchema: { type: 'object', properties: {} },
    handler: () => runKai(['doctor']),
  },
  {
    name: 'emu',
    title: '模拟执行单个函数（unicorn）',
    description: '不需要调试器/虚拟机：把 PE 映射进 unicorn，设好寄存器从指定 RVA 跑，遇 ret 停，输出寄存器、bool_ret 与内存 dump。用于跑解密 stub、直接调用授权校验函数、验证 patch 后的返回值。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string' },
        rva: { type: 'string', description: '起始 RVA，如 0xa5440（默认入口点）' },
        arch: { type: 'string', enum: ['x64', 'x86'] },
        reg: { type: 'array', items: { type: 'string' }, description: '寄存器初值，如 ["rcx=0x401000","rdx=8"]' },
        write: { type: 'array', items: { type: 'string' }, description: '写内存，如 ["0x300000:41414141"]' },
        dump: { type: 'array', items: { type: 'string' }, description: '结束时 dump，如 ["0x300000:32"]' },
        max_insns: { type: 'number' },
      },
      required: ['file'],
    },
    handler: (a) => {
      const argv = ['emu', a.file];
      if (a.rva) argv.push('--rva', String(a.rva));
      if (a.arch) argv.push('--arch', a.arch);
      for (const r of a.reg || []) argv.push('--reg', String(r));
      for (const w of a.write || []) argv.push('--write', String(w));
      for (const d of a.dump || []) argv.push('--dump', String(d));
      if (a.max_insns) argv.push('--max-insns', String(a.max_insns));
      return runKai(argv, 600000);
    },
  },
  {
    name: 'mem',
    title: '进程内存扫描/读写（外挂原语）',
    description: '扫描/过滤/读写目标进程内存：int32/float/bytes 首扫、next 过滤、AOB 特征码扫描、模块基址。不依赖 Cheat Engine。',
    inputSchema: {
      type: 'object',
      properties: {
        pid: { type: 'number' },
        name: { type: 'string', description: '进程名，如 game.exe' },
        action: { type: 'string', enum: ['mods', 'scan', 'next', 'read', 'write', 'aob'] },
        type: { type: 'string', enum: ['int32', 'uint32', 'int64', 'float', 'double', 'bytes'] },
        value: { type: 'string' },
        addr: { type: 'string' },
        len: { type: 'number' },
        bytes: { type: 'string', description: '十六进制字节串，如 e7030000' },
        pattern: { type: 'string', description: 'AOB 特征码，如 48 8B ?? 05' },
      },
      required: ['action'],
    },
    handler: (a) => {
      const argv = ['mem'];
      if (a.pid) argv.push('--pid', String(a.pid));
      if (a.name) argv.push('--name', String(a.name));
      argv.push(a.action);
      if (a.type) argv.push('--type', a.type);
      if (a.value !== undefined) argv.push('--value', String(a.value));
      if (a.addr) argv.push('--addr', String(a.addr));
      if (a.len) argv.push('--len', String(a.len));
      if (a.bytes) argv.push('--bytes', String(a.bytes));
      if (a.pattern) argv.push('--pattern', String(a.pattern));
      return runKai(argv, 600000);
    },
  },
  {
    name: 'solve',
    title: '符号执行求解（angr）',
    description: '给成功/失败地址，angr 自动探索出能到达成功分支的输入（stdin 或 argv）。用于注册码/序列号类校验的自动求解。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string' },
        find: { type: 'string', description: '成功地址，可逗号分隔' },
        avoid: { type: 'string', description: '失败地址，可逗号分隔' },
        mode: { type: 'string', enum: ['stdin', 'argv'] },
        length: { type: 'number' },
        charset: { type: 'string', enum: ['alnum', 'printable', 'hex', 'digits', 'none'] },
        start: { type: 'string', description: '从指定函数地址开始（跳过 CRT 初始化）' },
      },
      required: ['file', 'find'],
    },
    handler: (a) => {
      const argv = ['solve', a.file, '--find', String(a.find)];
      if (a.avoid) argv.push('--avoid', String(a.avoid));
      if (a.mode) argv.push('--mode', a.mode);
      if (a.length) argv.push('--length', String(a.length));
      if (a.charset) argv.push('--charset', a.charset);
      if (a.start) argv.push('--start', String(a.start));
      return runKai(argv, 900000);
    },
  },
  {
    name: 'skill',
    title: '读取技能正文',
    description: '按 id 读取 hack-skills 里的 SKILL.md（目录/标题；full=true 输出全文）。',
    inputSchema: {
      type: 'object',
      properties: { id: { type: 'string' }, full: { type: 'boolean' } },
      required: ['id'],
    },
    handler: (a) => {
      const p = path.join(VENDOR_SKILLS, a.id, 'SKILL.md');
      if (!fs.existsSync(p)) return { ok: false, text: `未找到技能 ${a.id}` };
      const body = fs.readFileSync(p, 'utf8');
      if (a.full) return { ok: true, text: body };
      const heads = body.match(/^#+ .+$/gm) || [];
      return { ok: true, text: `${a.id}\n${p}\n\n${heads.join('\n')}` };
    },
  },
];

// ---------------------------------------------------------------- JSON-RPC

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function handle(msg) {
  const { id, method, params } = msg;
  const reply = (result) => send({ jsonrpc: '2.0', id, result });
  const error = (code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

  if (method === 'initialize') {
    const asked = params?.protocolVersion;
    const version = PROTOCOLS.includes(asked) ? asked : PROTOCOLS[PROTOCOLS.length - 1];
    return reply({
      protocolVersion: version,
      capabilities: { tools: { listChanged: false } },
      serverInfo: SERVER_INFO,
      instructions:
        'kai 是逆向/破解/渗透的能力内核：probe 静态深挖、dis 反汇编、patch+diff 出补丁表、run 拿动态判据、case/claim/verify/report 记账本。' +
        '硬约束：没有 evidence 的结论只能是 inferred；声称“破解成功/拿到权限”必须有 run 的前后对照。',
    });
  }
  if (method === 'notifications/initialized' || method === 'initialized') return;
  if (method === 'ping') return reply({});
  if (method === 'tools/list') {
    return reply({
      tools: TOOLS.map((t) => ({ name: t.name, title: t.title, description: t.description, inputSchema: t.inputSchema })),
    });
  }
  if (method === 'tools/call') {
    const name = params?.name;
    const args = params?.arguments || {};
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) return error(-32602, `unknown tool: ${name}`);
    try {
      const r = tool.handler(args);
      if (!r.ok && r.exit !== 0) {
        // 工具执行失败也返回内容，让模型看到原因而不是协议错误
        return reply({ content: [{ type: 'text', text: r.text }], isError: true });
      }
      return reply({ content: [{ type: 'text', text: r.text }] });
    } catch (e) {
      return reply({ content: [{ type: 'text', text: `执行异常：${e.message}` }], isError: true });
    }
  }
  if (method === 'resources/list') return reply({ resources: [] });
  if (method === 'prompts/list') return reply({ prompts: [] });
  if (method === 'logging/setLevel') return reply({});
  return error(-32601, `method not found: ${method}`);
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  let msg;
  try { msg = JSON.parse(s); } catch { return; }
  try { handle(msg); } catch (e) {
    if (msg && msg.id !== undefined) send({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: String(e.message || e) } });
  }
});
rl.on('close', () => process.exit(0));

// 启动自检：缺 venv 时也能起（probe/dis 会报错，其它工具可用）
if (!fs.existsSync(PY)) {
  process.stderr.write(`[kai-mcp] 警告：未找到 python venv（${PY}），probe/dis 将不可用\n`);
}
