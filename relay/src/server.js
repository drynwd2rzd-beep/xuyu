import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { WebSocketServer } from 'ws';
import { loadConfig, paths } from './config.js';
import { resolveCommand } from './resolve.js';
import { runEngine } from './engines.js';

const config = loadConfig();
const PROTOCOL = 1;

function command(engine) {
  return resolveCommand(config.commands[engine] || engine);
}

// ---- 状态：CLI 是否安装、版本 ----
let statusCache = { at: 0, value: null };

function version(engine) {
  const cmd = command(engine);
  if (!cmd) return Promise.resolve({ installed: false, version: '' });
  return new Promise((resolve) => {
    execFile(cmd.file, [...cmd.pre, '--version'], { timeout: 15000, windowsHide: true }, (err, stdout) => {
      if (err) return resolve({ installed: false, version: '' });
      resolve({ installed: true, version: String(stdout).trim().split('\n')[0].slice(0, 60) });
    });
  });
}

async function status() {
  if (Date.now() - statusCache.at < 60_000 && statusCache.value) return statusCache.value;
  const [claude, codex] = await Promise.all([version('claude'), version('codex')]);
  const value = { protocol: PROTOCOL, host: os.hostname(), claude, codex, models: config.models };
  statusCache = { at: Date.now(), value };
  return value;
}

// ---- 附件：保存到 uploads，10 分钟后删除 ----
function saveAttachments(id, attachments = []) {
  const saved = [];
  attachments.forEach((a, i) => {
    const safe = String(a.name || `file-${i}`).replace(/[^\w.\-一-龥]/g, '_').slice(-80);
    const file = path.join(paths.uploads, `${id}-${i}-${safe}`);
    fs.writeFileSync(file, Buffer.from(String(a.data || ''), 'base64'));
    saved.push({ file, kind: a.kind === 'image' ? 'image' : 'file', name: a.name || safe });
  });
  if (saved.length) {
    setTimeout(() => saved.forEach((s) => fs.rm(s.file, { force: true }, () => {})), 10 * 60 * 1000);
  }
  return saved;
}

function send(ws, obj) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

async function handleRun(ws, msg, running) {
  const id = String(msg.id || '');
  const engine = msg.engine === 'codex' ? 'codex' : 'claude';
  const cmd = command(engine);
  if (!cmd) {
    send(ws, { type: 'error', id, message: engine === 'codex' ? '电脑上还没有安装 Codex。' : '电脑上还没有安装 Claude Code。' });
    return;
  }
  const saved = saveAttachments(id.replace(/[^\w-]/g, ''), msg.attachments);
  let prompt = String(msg.prompt || '');
  const files = saved.filter((s) => engine === 'claude' || s.kind !== 'image');
  if (files.length) {
    prompt += '\n\n用户附带的文件（可以直接读取）：\n' + files.map((f) => `- ${f.name}: ${f.file}`).join('\n');
  }

  const controller = new AbortController();
  running.set(id, controller);
  const started = Date.now();
  console.log(`→ ${id.slice(0, 8)} ${engine}${msg.model ? ' ' + msg.model : ''}`);
  try {
    await runEngine({
      engine,
      command: cmd,
      model: msg.model || '',
      system: msg.system || '',
      prompt,
      files,
      images: saved.filter((s) => s.kind === 'image').map((s) => s.file),
      cwd: paths.workspace,
      signal: controller.signal,
      onEvent: (e) => send(ws, { type: e.type, id, text: e.text }),
    });
    send(ws, { type: 'done', id });
    console.log(`✓ ${id.slice(0, 8)} ${((Date.now() - started) / 1000).toFixed(1)}s`);
  } catch (e) {
    if (!controller.signal.aborted) send(ws, { type: 'error', id, message: e.message });
    console.log(`✗ ${id.slice(0, 8)} ${e.message}`);
  } finally {
    running.delete(id);
  }
}

// ---- 服务器 ----
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('xuyu-relay ok');
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, path: '/ws', maxPayload: 64 * 1024 * 1024 });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://relay');
  if ((url.searchParams.get('token') || '').toUpperCase() !== config.token) {
    ws.close(4001, 'bad token');
    return;
  }
  const running = new Map();
  console.log(`iPhone 已连接（${req.socket.remoteAddress}）`);

  ws.on('message', async (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    switch (msg.type) {
      case 'status':
        send(ws, { type: 'status', id: msg.id, ...(await status()) });
        break;
      case 'run':
        handleRun(ws, msg, running);
        break;
      case 'cancel':
        running.get(String(msg.id))?.abort();
        break;
      case 'ping':
        send(ws, { type: 'pong', id: msg.id });
        break;
    }
  });
  ws.on('close', () => {
    running.forEach((c) => c.abort());
    console.log('iPhone 已断开');
  });
});

function lanAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family === 'IPv4' && !a.internal) out.push(a.address);
    }
  }
  return out;
}

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error(`端口 ${config.port} 已被占用。是不是已经开着一个中继了？`);
  } else {
    console.error(e.message);
  }
  process.exit(1);
});

server.listen(config.port, '0.0.0.0', async () => {
  const s = await status();
  const line = '─'.repeat(44);
  console.log(line);
  console.log('  絮语中继已启动');
  console.log(line);
  for (const ip of lanAddresses()) console.log(`  地址    ${ip}:${config.port}`);
  console.log(`  配对码  ${config.token}`);
  console.log(line);
  console.log(`  Claude Code  ${s.claude.installed ? s.claude.version : '未安装'}`);
  console.log(`  Codex        ${s.codex.installed ? s.codex.version : '未安装'}`);
  console.log(line);
  console.log('  在 iPhone 的「设置 → 连接」里填上地址和配对码。');
  console.log('  这个窗口开着，手机才能聊天。');
});
