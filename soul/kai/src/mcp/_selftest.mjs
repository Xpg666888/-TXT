// MCP 自检：起 kai-mcp，走 initialize → tools/list → tools/call，逐条断言。
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const server = spawn(process.execPath, [path.join(HERE, 'kai-mcp.mjs')], { stdio: ['pipe', 'pipe', 'pipe'] });

let buf = '';
const pending = new Map();
server.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    const p = pending.get(msg.id);
    if (p) { pending.delete(msg.id); p(msg); }
  }
});
server.stderr.on('data', (d) => process.stderr.write(`[srv] ${d}`));

let seq = 1;
function rpc(method, params) {
  const id = seq++;
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timeout: ${method}`)), 120000);
    pending.set(id, (m) => { clearTimeout(t); resolve(m); });
    server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

const sample = 'E:\\逆向\\瓶瓶下载器-复原\\_original\\瓶瓶下载器-1.2-最终版-新版UI客户端\\瓶瓶下载器.exe';

const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'selftest', version: '0' } });
console.log('initialize →', init.result.protocolVersion, init.result.serverInfo.name);
server.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');

const list = await rpc('tools/list', {});
console.log('tools/list →', list.result.tools.length, 'tools:', list.result.tools.map((t) => t.name).join(', '));

const call = async (name, args) => {
  const r = await rpc('tools/call', { name, arguments: args });
  const t = r.result?.content?.[0]?.text || JSON.stringify(r.error || r.result);
  return { isError: !!r.result?.isError, text: t };
};

const kb = await call('kb', { query: '脱壳', limit: '2' });
console.log('\n[kb 脱壳] isError=', kb.isError, '\n', kb.text.split('\n').slice(0, 6).join('\n'));

const probe = await call('probe', { file: sample });
console.log('\n[probe] isError=', probe.isError, '\n', probe.text.split('\n').slice(0, 8).join('\n'));

const dis = await call('dis', { file: sample, rva: '0x76be', len: '16', arch: 'x86' });
console.log('\n[dis] isError=', dis.isError, '\n', dis.text.split('\n').slice(0, 4).join('\n'));

const bad = await call('patch', { file: sample, offset: '0xzz', bytes: '90', out: 'x' });
console.log('\n[patch 非法参数] isError=', bad.isError, '→', bad.text.split('\n')[0]);

server.kill();
console.log('\nself-test done');
