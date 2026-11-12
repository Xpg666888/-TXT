// ============================================================
//  YG-SOUL / digest.mjs — 把会话日志（多帧 zstd）压成人读记忆索引
//  用法: node digest.mjs <sessionsDir> <outFile>
// ============================================================
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

// 多帧 zstd：按 magic 切帧逐个解，解坏的帧丢弃（magic 可能出现在压缩流里）
function decodeAll(buf) {
  const offs = [];
  let p = 0;
  while ((p = buf.indexOf(MAGIC, p)) !== -1) { offs.push(p); p++; }
  offs.push(buf.length);
  const parts = [];
  for (let i = 0; i < offs.length - 1; i++) {
    let end = offs[i + 1];
    for (let tries = 0; tries < 4; tries++) {
      try { parts.push(zlib.zstdDecompressSync(buf.subarray(offs[i], end))); break; }
      catch { end = offs[i + tries + 2] ?? buf.length; if (end >= buf.length) break; }
    }
  }
  return Buffer.concat(parts);
}

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walk(full, out);
    else if (e.name.endsWith('.jsonl.zstd')) out.push(full);
  }
  return out;
}

const text = (content) => (content || [])
  .filter((c) => c && c.type === 'text' && typeof c.text === 'string')
  .map((c) => c.text.replace(/\s+/g, ' ').trim())
  .join(' ');

const clip = (s, n) => (s.length > n ? s.slice(0, n) + ' …' : s);

const [, , sessionsDir, outFile] = process.argv;
if (!sessionsDir || !outFile) { console.error('usage: node digest.mjs <sessionsDir> <outFile>'); process.exit(2); }

const rows = [];
for (const file of walk(sessionsDir)) {
  let objs = [];
  try {
    objs = decodeAll(fs.readFileSync(file)).toString('utf8')
      .split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean);
  } catch { continue; }
  if (!objs.length) continue;

  const head = objs.find((o) => o.type === 'session')?.data ?? objs.find((o) => o.type === 'session') ?? {};
  const title = objs.find((o) => o.type === 'session/title')?.data?.title ?? '';
  const msgs = objs.filter((o) => o.type === 'user/message' && o.data);
  const real = msgs.filter((m) => (m.data.source?.kind ?? 'user') === 'user' || m.data.role === 'user');
  const NOISE = /^(The approval policy changed|Current runtime context|<system-reminder>|Time sampled while preparing|# AGENTS\.md|<available_skills>)/i;
  const userTexts = real.map((m) => text(m.data.content)).filter((t) => t && !NOISE.test(t));
  const tools = objs.filter((o) => o.type === 'tool/call').length;
  const created = head.createdAt ?? objs[0]?.time ?? 0;
  if (!userTexts.length && !title) continue;
  rows.push({
    id: head.id ?? path.basename(path.dirname(file)),
    cwd: head.cwd ?? '',
    preset: head.agentPreset ?? '',
    created,
    title,
    turns: real.length,
    tools,
    bytes: fs.statSync(file).size,
    userTexts,
  });
}

rows.sort((a, b) => b.created - a.created);

const fmt = (t) => new Date(t || 0).toLocaleString('sv-SE', { timeZone: 'Asia/Shanghai' });
const lines = [
  '# 会话记忆索引',
  '',
  `> 由 \`soul/tools/digest.mjs\` 自动生成 · ${rows.length} 个会话 · 生成时间 ${fmt(Date.now())}`,
  '> 用途：换机器后我靠它知道「我们打过哪些仗」，避免从零开始。',
  '',
];

for (const r of rows) {
  lines.push(`## ${fmt(r.created)} · ${r.title || '(无标题)'}`);
  lines.push('');
  lines.push(`- 目录：\`${r.cwd}\` · 预设：\`${r.preset || '-'}\` · 用户轮次：${r.turns} · 工具调用：${r.tools} · 体积：${(r.bytes / 1048576).toFixed(2)} MB`);
  lines.push(`- session：\`${r.id}\``);
  const uniq = [...new Set(r.userTexts)];
  for (const u of uniq.slice(0, 4)) lines.push(`  - 用户：${clip(u, 220)}`);
  lines.push('');
}

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, lines.join('\n'), 'utf8');
console.log(`digest: ${rows.length} sessions -> ${outFile}`);
