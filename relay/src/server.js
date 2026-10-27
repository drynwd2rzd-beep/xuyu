import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { WebSocketServer } from 'ws';
import { loadConfig, saveConfig, paths } from './config.js';
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

// ---- 模型目录：Claude 用配置里的列表，Codex 读它自己缓存的官方列表 ----
const CLAUDE_EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'];
const CLAUDE_NAMES = {
  'claude-fable-5-1': ['Fable 5.1', '最强，适合最难的问题'],
  'claude-opus-5-5': ['Opus 5.5', '聪明又稳定'],
  'claude-sonnet-5-5': ['Sonnet 5.5', '更快，适合日常聊天'],
  'claude-haiku-5-5': ['Haiku 5.5', '最快最省'],
};

function claudeCatalog() {
  return config.models.claude.map((id) => ({
    id,
    name: CLAUDE_NAMES[id]?.[0] || id,
    description: CLAUDE_NAMES[id]?.[1] || '',
    efforts: CLAUDE_EFFORTS,
    defaultEffort: '',
  }));
}

function codexCatalog() {
  try {
    const home = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
    const cache = JSON.parse(fs.readFileSync(path.join(home, 'models_cache.json'), 'utf8'));
    return (cache.models || [])
      .filter((m) => m.visibility === 'list')
      .sort((a, b) => (a.priority ?? 99) - (b.priority ?? 99))
      .map((m) => ({
        id: m.slug,
        name: m.display_name || m.slug,
        description: m.description || '',
        efforts: (m.supported_reasoning_levels || []).map((l) => l.effort),
        defaultEffort: m.default_reasoning_level || '',
      }));
  } catch {
    return config.models.codex.map((id) => ({ id, name: id, description: '', efforts: [], defaultEffort: '' }));
  }
}

let refreshing = null;

function refreshStatus() {
  if (!refreshing) {
    refreshing = (async () => {
      const [claude, codex] = await Promise.all([version('claude'), version('codex')]);
      const catalog = { claude: claudeCatalog(), codex: codexCatalog() };
      const models = { claude: catalog.claude.map((m) => m.id), codex: catalog.codex.map((m) => m.id) };
      const value = { protocol: PROTOCOL, host: os.hostname(), claude, codex, models, catalog };
      statusCache = { at: Date.now(), value };
      return value;
    })().finally(() => { refreshing = null; });
  }
  return refreshing;
}

// 有旧结果就立刻返回，过期了在后台刷新；手机连上时不用等 CLI 查版本（出门线路延迟高，等不起）
async function status() {
  if (statusCache.value) {
    if (Date.now() - statusCache.at > 60_000) refreshStatus().catch(() => {});
    return statusCache.value;
  }
  return refreshStatus();
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

// ---- 回复任务：手机断开也继续跑，结果保留 10 分钟，重新连上后接着收 ----
const jobs = new Map();

function publish(job, obj) {
  job.events.push(obj);
  const seq = job.events.length;
  for (const ws of job.subscribers) send(ws, { ...obj, seq });
}

function finishJob(job, obj) {
  job.final = obj;
  for (const ws of job.subscribers) send(ws, obj);
  setTimeout(() => jobs.delete(job.id), 10 * 60 * 1000);
}

function resumeJob(ws, id, from) {
  const job = jobs.get(id);
  if (!job) {
    send(ws, { type: 'error', id, message: '这条回复已经过期，请重新发送。' });
    return;
  }
  job.subscribers.add(ws);
  job.events.slice(from).forEach((e, i) => send(ws, { ...e, seq: from + i + 1 }));
  if (job.final) send(ws, job.final);
}

async function handleRun(ws, msg) {
  const id = String(msg.id || '');
  const engine = msg.engine === 'codex' ? 'codex' : 'claude';
  const cmd = command(engine);
  if (!cmd) {
    send(ws, { type: 'error', id, message: engine === 'codex' ? '电脑上还没有安装 Codex。' : '电脑上还没有安装 Claude Code。' });
    return;
  }
  const job = { id, events: [], final: null, subscribers: new Set([ws]), controller: new AbortController() };
  jobs.set(id, job);
  const saved = saveAttachments(id.replace(/[^\w-]/g, ''), msg.attachments);
  let prompt = String(msg.prompt || '');
  const files = saved.filter((s) => engine === 'claude' || s.kind !== 'image');
  if (files.length) {
    prompt += '\n\n用户附带的文件（可以直接读取）：\n' + files.map((f) => `- ${f.name}: ${f.file}`).join('\n');
  }

  const controller = job.controller;
  const started = Date.now();
  console.log(`→ ${id.slice(0, 8)} ${engine}${msg.model ? ' ' + msg.model : ''}${msg.effort ? ' · ' + msg.effort : ''}`);
  try {
    await runEngine({
      engine,
      command: cmd,
      model: msg.model || '',
      effort: /^[a-z]+$/.test(String(msg.effort || '')) ? msg.effort : '',
      system: msg.system || '',
      prompt,
      files,
      images: saved.filter((s) => s.kind === 'image').map((s) => s.file),
      cwd: paths.workspace,
      signal: controller.signal,
      onEvent: (e) => publish(job, { type: e.type, id, text: e.text }),
    });
    finishJob(job, { type: 'done', id });
    console.log(`✓ ${id.slice(0, 8)} ${((Date.now() - started) / 1000).toFixed(1)}s`);
  } catch (e) {
    finishJob(job, { type: 'error', id, message: controller.signal.aborted ? '已取消' : e.message });
    console.log(`✗ ${id.slice(0, 8)} ${e.message}`);
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
  const from = String(req.socket.remoteAddress || '').replace(/^::ffff:/, '');
  console.log(`iPhone 已连接（${from}${from.startsWith('100.') ? '，出门线路' : ''}）`);

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
        handleRun(ws, msg);
        break;
      case 'resume':
        resumeJob(ws, String(msg.id), Math.max(0, Number(msg.from) || 0));
        break;
      case 'cancel':
        jobs.get(String(msg.id))?.controller.abort();
        break;
      case 'ping':
        send(ws, { type: 'pong', id: msg.id });
        break;
    }
  });
  ws.on('close', () => {
    // 不取消正在进行的回复，等手机回来继续收
    for (const job of jobs.values()) job.subscribers.delete(ws);
    console.log('iPhone 已断开');
  });
});

/** 手机能连的局域网地址（排除代理/VPN 的虚拟网卡），Tailscale 地址放在后面 */
function lanAddresses() {
  const lan = [];
  const tailscale = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      const [p, q] = a.address.split('.').map(Number);
      if (p === 192 && q === 168 || p === 10 || p === 172 && q >= 16 && q <= 31) lan.push(a.address);
      else if (p === 100 && q >= 64 && q <= 127) tailscale.push(a.address);
    }
  }
  return [...lan, ...tailscale];
}

// WebSocketServer 会转发底层的 error 事件，这里统一在 listen 时处理
wss.on('error', () => {});

// 端口被占用或被系统保留时，自动换下一个，并记住能用的端口
const candidates = [...new Set([config.port, 51888, 52888, 53888, 54888, 47823])];

function listen(index) {
  const port = candidates[index];
  if (port === undefined) {
    console.error('找不到可用的端口，请重启电脑后再试。');
    process.exit(1);
  }
  const onListening = () => {
    server.off('error', onError);
    if (port !== config.port) {
      config.port = port;
      saveConfig(config);
    }
    banner(port);
  };
  const onError = (e) => {
    server.off('listening', onListening);
    if (e.code === 'EADDRINUSE' || e.code === 'EACCES') {
      listen(index + 1);
    } else {
      console.error(e.message);
      process.exit(1);
    }
  };
  server.once('error', onError);
  server.once('listening', onListening);
  server.listen(port, '0.0.0.0');
}

listen(0);

async function banner(port) {
  const s = await status();
  const line = '─'.repeat(44);
  console.log(line);
  console.log('  絮语中继已启动');
  console.log(line);
  for (const ip of lanAddresses()) console.log(`  地址    ${ip}:${port}`);
  console.log(`  配对码  ${config.token}`);
  console.log(line);
  console.log(`  Claude Code  ${s.claude.installed ? s.claude.version : '未安装'}`);
  console.log(`  Codex        ${s.codex.installed ? s.codex.version : '未安装'}`);
  console.log(line);
  console.log('  在 iPhone 的「设置 → 连接」里填上地址和配对码。');
  console.log('  这个窗口开着，手机才能聊天。');
}
