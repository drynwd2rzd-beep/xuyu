import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { loadConfig, saveConfig, paths, workPaths } from './config.js';
import { resolveCommand } from './resolve.js';
import { runEngine } from './engines.js';
import { proof, newNonce, validNonce, sameProof } from './pairing.js';

// ---- 兜底：任何没接住的错误只记一行，中继不退出（审查 Z-003、规范 RELAY-9） ----
process.on('uncaughtException', (e) => console.log(`出错了（中继继续运行）：${e?.message || e}`));
process.on('unhandledRejection', (e) => console.log(`出错了（中继继续运行）：${e?.message || e}`));

const config = loadConfig();
// 2：连接时先对暗号（pairing.js），配对码不再放在网址里
const PROTOCOL = 2;
// 工作模式把关钩子（gate.js）找中继问「用户允不允许」时要带的钥匙：每次启动随机生成，只在本机用
const GATE_KEY = crypto.randomBytes(16).toString('hex');
let listeningPort = config.port;

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

// Codex 的模型说明是英文，按系列翻成中文
const CODEX_FAMILY = {
  astra: '最强，适合最难、最复杂的工作',
  sol: '主力模型，写代码和日常都好用',
  terra: '均衡，适合直接明了的工作',
  luna: '又快又省，适合简单的事',
};

function codexDescription(m) {
  const family = Object.keys(CODEX_FAMILY).find((k) => String(m.slug).includes(k));
  if (!family) return m.description || '';
  const en = String(m.description || '').toLowerCase();
  if (en.startsWith('latest')) return `最新 · ${CODEX_FAMILY[family]}`;
  if (/older|previous/.test(en)) return `上一代 · ${CODEX_FAMILY[family]}`;
  return CODEX_FAMILY[family];
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
        name: String(m.display_name || m.slug).replace(/[- ](Sol|Astra|Terra|Luna)$/i, ' $1'),
        description: codexDescription(m),
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
  let value = statusCache.value;
  if (value) {
    if (Date.now() - statusCache.at > 60_000) refreshStatus().catch(() => {});
  } else {
    value = await refreshStatus();
  }
  return { ...value, autostart: autostartEnabled() };
}

// ---- 开机自动启动：在「启动」文件夹里放一个最小化启动中继的快捷方式 ----
const relayDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const startupLink = path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', '絮语中继.lnk');

function autostartEnabled() {
  return fs.existsSync(startupLink);
}

function setAutostart(on) {
  return new Promise((resolve) => {
    if (!on) {
      fs.rm(startupLink, { force: true }, () => resolve());
      return;
    }
    const bat = path.join(relayDir, 'start-relay.bat');
    const ico = path.join(relayDir, 'xuyu.ico');
    const q = (s) => `'${String(s).replace(/'/g, "''")}'`;
    const script = [
      '$s = (New-Object -ComObject WScript.Shell).CreateShortcut(' + q(startupLink) + ')',
      `$s.TargetPath = ${q(bat)}`,
      `$s.WorkingDirectory = ${q(relayDir)}`,
      fs.existsSync(ico) ? `$s.IconLocation = ${q(ico + ',0')}` : '',
      '$s.WindowStyle = 7',
      '$s.Save()',
    ].filter(Boolean).join('; ');
    execFile('powershell.exe', ['-NoProfile', '-Command', script], { windowsHide: true }, () => resolve());
  });
}

// ---- 附件：聊天时存到 uploads，10 分钟后删除；工作模式存进工作文件夹的「收到的文件」，一直保留 ----
function saveAttachments(id, attachments = [], work = false) {
  const saved = [];
  const dir = work ? workPaths(config).inbox : paths.uploads;
  attachments.forEach((a, i) => {
    const safe = String(a.name || `file-${i}`).replace(/[^\w.\-一-龥]/g, '_').slice(-80);
    const stamp = new Date().toISOString().slice(5, 16).replace(/[-T:]/g, '');
    const file = path.join(dir, work ? `${stamp}-${safe}` : `${id}-${i}-${safe}`);
    fs.writeFileSync(file, Buffer.from(String(a.data || ''), 'base64'));
    saved.push({ file, kind: a.kind === 'image' ? 'image' : 'file', name: a.name || safe });
  });
  if (saved.length && !work) {
    setTimeout(() => saved.forEach((s) => fs.rm(s.file, { force: true }, () => {})), 10 * 60 * 1000);
  }
  return saved;
}

/** 工作模式的说明：告诉 AI 能在哪里动手、怎么把文件发回手机 */
function workGuide() {
  const w = workPaths(config);
  return [
    `你现在可以在用户电脑上的工作文件夹「${w.root}」里读写文件、运行命令，帮用户把事情做完。`,
    '只在这个文件夹里操作：读写外面的文件会被直接拒绝。不要删除用户没让你删的文件，不要安装软件或改系统设置。',
    '运行命令、打开网页、上网搜索之前，系统会自动在用户手机上请求确认，你不用再另外问；用户没有允许时，不要换个办法做同一件事，告诉用户并问用户想怎么办。',
    `用户从手机发来的文件在「${w.inbox}」。`,
    `要把做好的文件发到用户手机上，就把文件保存（或复制）到「${w.outbox}」，系统会自动发过去。`,
    '做完后用一两句口语化的话告诉用户结果。',
  ].join('\n');
}

/** 把「发给手机」文件夹里这次新出现的文件发回手机，然后挪到「已发送」 */
function sendOutbox(job, since) {
  const w = workPaths(config);
  let names = [];
  try {
    names = fs.readdirSync(w.outbox);
  } catch {
    return;
  }
  for (const name of names.slice(0, 10)) {
    const file = path.join(w.outbox, name);
    try {
      const st = fs.statSync(file);
      if (!st.isFile() || st.mtimeMs < since - 2000) continue;
      if (st.size > 20 * 1024 * 1024) {
        publish(job, { type: 'step', id: job.id, text: `${name} 超过 20MB，留在电脑上没有发送` });
        continue;
      }
      publish(job, { type: 'file', id: job.id, name, data: fs.readFileSync(file).toString('base64') });
      let target = path.join(w.sent, name);
      if (fs.existsSync(target)) target = path.join(w.sent, `${Date.now()}-${name}`);
      fs.renameSync(file, target);
    } catch {
      // 单个文件出错不影响其他文件
    }
  }
}

function send(ws, obj) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

// ---- 回复任务：手机断开也继续跑；写好的回复在内存和硬盘各存 24 小时，重新连上或重新打开 App 后接着收 ----
const jobs = new Map();
const KEEP = 24 * 60 * 60 * 1000;

function replyFile(id) {
  return path.join(paths.replies, `${String(id).replace(/[^\w-]/g, '')}.json`);
}

function publish(job, obj) {
  job.events.push(obj);
  const seq = job.events.length;
  for (const ws of job.subscribers) send(ws, { ...obj, seq });
}

function finishJob(job, obj) {
  job.final = obj;
  for (const ws of job.subscribers) send(ws, obj);
  // 存到硬盘：中继重启了也能取回
  fs.writeFile(replyFile(job.id), JSON.stringify({ events: job.events, final: obj, at: Date.now() }), () => {});
  setTimeout(() => jobs.delete(job.id), KEEP);
}

function resumeJob(ws, id, from) {
  let job = jobs.get(id);
  if (!job) {
    try {
      const saved = JSON.parse(fs.readFileSync(replyFile(id), 'utf8'));
      job = { id, events: saved.events || [], final: saved.final, subscribers: new Set() };
    } catch {
      send(ws, { type: 'error', id, message: '这条回复已经过期，可以点重试。' });
      return;
    }
  }
  job.subscribers.add(ws);
  job.events.slice(from).forEach((e, i) => send(ws, { ...e, seq: from + i + 1 }));
  if (job.final) send(ws, job.final);
  // 断线前还在等你点「允许 / 不允许」：重新连上后再问一次
  if (job.approval) send(ws, approvalMessage(job));
}

// ---- 工作模式的确认：把关钩子问「允不允许」，转给手机，等你点 ----
// 不放进 events（不按编号重放），一次只有一个；断线重连时由 resumeJob 再发一遍
const APPROVAL_WAIT = 9 * 60 * 1000;

function approvalMessage(job) {
  return { type: 'approve', id: job.id, req: job.approval.req, text: job.approval.text };
}

function settleApproval(job, ok) {
  const pending = job.approval;
  if (!pending) return;
  job.approval = null;
  clearTimeout(pending.timer);
  pending.resolve(ok);
}

function requestApproval(job, text) {
  return new Promise((resolve) => {
    // 上一个还没答就又来一个（不应该发生）：上一个按不允许
    settleApproval(job, false);
    const req = crypto.randomUUID();
    // 太久没人点：当不允许，AI 收到后会告诉你
    const timer = setTimeout(() => settleApproval(job, false), APPROVAL_WAIT);
    job.approval = { req, text, resolve, timer };
    for (const ws of job.subscribers) send(ws, approvalMessage(job));
    console.log(`? ${job.id.slice(0, 8)} 等手机确认：${text.slice(0, 60)}`);
  });
}

// 清理超过 24 小时的回复
function pruneReplies() {
  fs.readdir(paths.replies, (err, names) => {
    if (err) return;
    for (const name of names) {
      const file = path.join(paths.replies, name);
      fs.stat(file, (e, st) => { if (!e && Date.now() - st.mtimeMs > KEEP) fs.rm(file, { force: true }, () => {}); });
    }
  });
}
pruneReplies();
setInterval(pruneReplies, 60 * 60 * 1000);

async function handleRun(ws, msg) {
  const id = String(msg.id || '');
  const engine = msg.engine === 'codex' ? 'codex' : 'claude';
  const cmd = command(engine);
  if (!cmd) {
    send(ws, { type: 'error', id, message: engine === 'codex' ? '电脑上还没有安装 Codex。' : '电脑上还没有安装 Claude Code。' });
    return;
  }
  const work = msg.work === true;
  // 工作模式只接受可信线路：家里局域网、Tailscale、本机
  if (work && !trustedAddress(ws.remoteAddress)) {
    send(ws, { type: 'error', id, message: '为了安全，「操作电脑」只能在家里的 Wi-Fi 或 Tailscale 下使用。' });
    return;
  }
  // gateCalls：把关钩子这次被问过几次，引擎拿它核对「每个执行过的工具都经过了把关」
  const job = { id, events: [], final: null, subscribers: new Set([ws]), controller: new AbortController(), approval: null, gateCalls: 0 };
  jobs.set(id, job);
  const controller = job.controller;
  // 你取消了这条回复：还在等的确认按不允许收尾
  controller.signal.addEventListener('abort', () => settleApproval(job, false));
  const started = Date.now();
  console.log(`→ ${id.slice(0, 8)} ${engine}${msg.model ? ' ' + msg.model : ''}${msg.effort ? ' · ' + msg.effort : ''}${work ? ' · 工作模式' : ''}`);
  // 整个过程（包括存附件）出的错都在这里接住，回给手机；不让一个错误把整个中继带倒（以前存附件时硬盘满了，中继会直接退出）
  try {
    const saved = saveAttachments(id.replace(/[^\w-]/g, ''), msg.attachments, work);
    let prompt = String(msg.prompt || '');
    const files = saved.filter((s) => work || engine === 'claude' || s.kind !== 'image');
    if (files.length) {
      prompt += '\n\n用户附带的文件（可以直接读取）：\n' + files.map((f) => `- ${f.name}: ${f.file}`).join('\n');
    }
    const system = work ? `${msg.system || ''}\n\n${workGuide()}`.trim() : msg.system || '';
    await runEngine({
      engine,
      command: cmd,
      model: msg.model || '',
      effort: /^[a-z]+$/.test(String(msg.effort || '')) ? msg.effort : '',
      system,
      prompt,
      files,
      images: saved.filter((s) => s.kind === 'image').map((s) => s.file),
      cwd: work ? workPaths(config).root : paths.workspace,
      readDirs: work ? [] : [paths.uploads],
      signal: controller.signal,
      work,
      gate: { url: `http://127.0.0.1:${listeningPort}/gate`, key: GATE_KEY, job: id, calls: () => job.gateCalls },
      onEvent: (e) => publish(job, { type: e.type, id, text: e.text }),
    });
    if (work) sendOutbox(job, started);
    finishJob(job, { type: 'done', id });
    console.log(`✓ ${id.slice(0, 8)} ${((Date.now() - started) / 1000).toFixed(1)}s`);
  } catch (e) {
    finishJob(job, { type: 'error', id, message: controller.signal.aborted ? '已取消' : e.message });
    console.log(`✗ ${id.slice(0, 8)} ${e.message}`);
  } finally {
    settleApproval(job, false);
  }
}

/**
 * 把关钩子来报到：只认本机、带着钥匙的请求。每次都记一笔（引擎靠它发现钩子没起作用）；
 * 带着 text 的是要问你的，一直等到你在手机上点了（或超时）才回答
 */
function handleGate(req, res) {
  if (!isLocal(req.socket.remoteAddress) || req.headers['x-xuyu-gate'] !== GATE_KEY) {
    res.writeHead(403);
    res.end();
    return;
  }
  let body = '';
  req.on('data', (d) => {
    body += d;
    if (body.length > 64 * 1024) req.destroy();
  });
  req.on('end', async () => {
    let ok = false;
    try {
      const { job: id, text } = JSON.parse(body || '{}');
      const job = jobs.get(String(id));
      if (job && !job.final && !job.controller.signal.aborted) {
        job.gateCalls += 1;
        ok = text === undefined ? true : await requestApproval(job, String(text));
        if (text !== undefined) console.log(ok ? '  手机上点了允许' : '  没有允许');
      }
    } catch {
      ok = false;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok }));
  });
}

// ---- 服务器 ----
const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/gate') {
    handleGate(req, res);
    return;
  }
  // 只给本机检查「中继是不是已经开着」用；局域网里的设备问不到，不能拿它找出谁的电脑开着中继（审查 Z-481）
  if (req.url === '/health' && isLocal(req.socket.remoteAddress)) {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('xuyu-relay ok');
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, path: '/ws', maxPayload: 64 * 1024 * 1024 });

// ---- 手机聊天备份：存在 D:\絮语备份，只留最近 30 份 ----
function backupName(name) {
  const safe = path.basename(String(name || '')).replace(/[^\w.\-一-龥]/g, '_');
  return safe.endsWith('.json') ? safe : '';
}

function saveBackup(name, data) {
  const safe = backupName(name);
  if (!safe || !data) return false;
  try {
    fs.writeFileSync(path.join(config.backupDir, safe), Buffer.from(String(data), 'base64'));
    backupSaved(safe);
    return true;
  } catch {
    return false;
  }
}

/** 存好一份：只留最近 30 份，顺手清掉一天前没传完的半截 */
function backupSaved(safe) {
  for (const old of listBackups().slice(30)) fs.rmSync(path.join(config.backupDir, old.name), { force: true });
  try {
    for (const name of fs.readdirSync(config.backupDir).filter((n) => n.endsWith('.part'))) {
      const file = path.join(config.backupDir, name);
      if (Date.now() - fs.statSync(file).mtimeMs > KEEP) fs.rmSync(file, { force: true });
    }
  } catch {
    // 清不掉也不影响这次备份
  }
  console.log(`已保存手机备份：${safe}`);
}

// 大的备份分块传（照片多了以后，整份塞进一条消息会超过 64MB 上限）：
// 先写进「名字.part」，第 0 块从头写，之后按顺序接在后面，最后一块到了再改成正式的名字
const chunkProgress = new Map();

function saveBackupChunk(name, index, total, data) {
  const safe = backupName(name);
  const i = Number(index);
  const n = Number(total);
  if (!safe || !data || !Number.isInteger(i) || !Number.isInteger(n) || i < 0 || n < 1 || i >= n) return false;
  const part = path.join(config.backupDir, `${safe}.part`);
  try {
    const buf = Buffer.from(String(data), 'base64');
    if (i === 0) {
      fs.writeFileSync(part, buf);
    } else {
      // 顺序不对（中间丢了一块、或者重复发）：不接，让手机这次算失败
      if (chunkProgress.get(safe) !== i) return false;
      fs.appendFileSync(part, buf);
    }
    chunkProgress.set(safe, i + 1);
    if (i === n - 1) {
      chunkProgress.delete(safe);
      fs.renameSync(part, path.join(config.backupDir, safe));
      backupSaved(safe);
    }
    return true;
  } catch {
    return false;
  }
}

/** 取回大的备份：一次读一段（最多 8MB），连同文件总大小一起回给手机 */
function readBackupChunk(name, offset, length) {
  const safe = backupName(name);
  if (!safe) return { data: '', size: 0 };
  let fd;
  try {
    fd = fs.openSync(path.join(config.backupDir, safe), 'r');
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, Math.floor(Number(offset) || 0));
    const want = Math.min(Math.max(0, Math.floor(Number(length) || 0)), 8 * 1024 * 1024, Math.max(0, size - start));
    const buf = Buffer.alloc(want);
    const got = want > 0 ? fs.readSync(fd, buf, 0, want, start) : 0;
    return { data: buf.subarray(0, got).toString('base64'), size };
  } catch {
    return { data: '', size: 0 };
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function listBackups() {
  try {
    return fs.readdirSync(config.backupDir)
      .filter((n) => n.endsWith('.json'))
      .map((name) => {
        const st = fs.statSync(path.join(config.backupDir, name));
        return { name, size: st.size, at: st.mtimeMs };
      })
      .sort((a, b) => b.at - a.at);
  } catch {
    return [];
  }
}

function readBackup(name) {
  const safe = backupName(name);
  try {
    return safe ? fs.readFileSync(path.join(config.backupDir, safe)).toString('base64') : '';
  } catch {
    return '';
  }
}

// ---- 安全：连接先对暗号、防止有人反复猜配对码；只接受可信线路 ----
// 关闭码：4001 暗号不对，4002 手机的 App 太旧（还在用旧的连接方式），4003 猜错太多次暂时封住，4004 不是可信线路
const LOCK_AFTER = 5;
const LOCK_FOR = 15 * 60 * 1000;
const AUTH_WAIT = 10 * 1000;
const failures = new Map();

function plainAddress(ip) {
  return String(ip || '').replace(/^::ffff:/, '');
}

function isLocal(ip) {
  const from = plainAddress(ip);
  return from === '127.0.0.1' || from === '::1';
}

/** 家里局域网、Tailscale、本机 */
function trustedAddress(ip) {
  const [p, q] = String(ip || '').split('.').map(Number);
  return isLocal(ip) || p === 10 || p === 192 && q === 168 || p === 172 && q >= 16 && q <= 31
    || p === 100 && q >= 64 && q <= 127;
}

/** 记一次暗号不对：同一个地址连续错 5 次，封 15 分钟 */
function recordFailure(from) {
  const count = (failures.get(from)?.count || 0) + 1;
  const until = count >= LOCK_AFTER ? Date.now() + LOCK_FOR : 0;
  failures.set(from, { count: until ? 0 : count, until, at: Date.now() });
  if (until) console.log(`⚠ ${from} 连续对不上配对码，已暂时拒绝它 15 分钟`);
}

/** 清掉过期的记录，表不会一直变大 */
function pruneFailures() {
  const now = Date.now();
  for (const [from, record] of failures) {
    if (record.until < now && now - record.at > LOCK_FOR) failures.delete(from);
  }
}
setInterval(pruneFailures, LOCK_FOR);

wss.on('connection', (ws, req) => {
  // 第一件事：连接出错（坏帧、超过大小上限）只断开这一个连接，不让整个中继崩溃（审查 Z-003）
  ws.on('error', (e) => console.log(`连接出错：${e.message}`));
  const from = plainAddress(req.socket.remoteAddress);
  // 公网来的一律不接（审查 Z-004）
  if (!trustedAddress(from)) {
    ws.close(4004, 'untrusted');
    return;
  }
  if (failures.get(from)?.until > Date.now()) {
    ws.close(4003, 'locked');
    return;
  }
  // 先对暗号：对上以前，除了 auth 什么都不认，也什么都不发（pairing.js）
  const nonce = newNonce();
  let authed = false;
  let rejected = false;
  const authTimer = setTimeout(() => { if (!authed) ws.close(4001, 'no auth'); }, AUTH_WAIT);
  send(ws, { type: 'hello', protocol: PROTOCOL, nonce });

  function authenticate(msg) {
    // 已经拒绝了：关闭前又到的消息不再算错
    if (rejected) return;
    if (msg.type !== 'auth') {
      rejected = true;
      ws.close(4002, 'update app');
      return;
    }
    const cnonce = String(msg.cnonce || '');
    if (!validNonce(cnonce) || !sameProof(msg.proof, proof(config.token, 'app', nonce, cnonce))) {
      rejected = true;
      recordFailure(from);
      ws.close(4001, 'bad proof');
      return;
    }
    authed = true;
    clearTimeout(authTimer);
    failures.delete(from);
    ws.remoteAddress = from;
    send(ws, { type: 'welcome', proof: proof(config.token, 'relay', nonce, cnonce) });
    console.log(`iPhone 已连接（${from}${from.startsWith('100.') ? '，出门线路' : ''}）`);
  }

  ws.on('message', async (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (!authed) {
      authenticate(msg);
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
      case 'autostart':
        await setAutostart(msg.on === true);
        console.log(msg.on === true ? '已设置开机自动启动' : '已取消开机自动启动');
        send(ws, { type: 'status', id: msg.id, ...(await status()) });
        break;
      case 'cancel':
        jobs.get(String(msg.id))?.controller.abort();
        break;
      case 'approval': {
        // 你在手机上点了「允许 / 不允许」：只认对得上号的那一次，而且要来自正在收这条回复的手机
        const job = [...jobs.values()].find((j) => j.approval?.req === String(msg.req || ''));
        if (job?.subscribers.has(ws)) settleApproval(job, msg.ok === true);
        break;
      }
      case 'backup':
        send(ws, { type: 'backupSaved', id: msg.id, ok: saveBackup(msg.name, msg.data) });
        break;
      case 'backups':
        send(ws, { type: 'backups', id: msg.id, list: listBackups() });
        break;
      case 'fetchBackup':
        send(ws, { type: 'backupData', id: msg.id, data: readBackup(msg.name) });
        break;
      case 'backupChunk':
        send(ws, { type: 'backupChunkSaved', id: msg.id, ok: saveBackupChunk(msg.name, msg.index, msg.total, msg.data) });
        break;
      case 'fetchBackupChunk':
        send(ws, { type: 'backupChunkData', id: msg.id, ...readBackupChunk(msg.name, msg.offset, msg.length) });
        break;
      case 'ping':
        send(ws, { type: 'pong', id: msg.id });
        break;
    }
  });
  ws.on('close', () => {
    clearTimeout(authTimer);
    if (!authed) return;
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
    listeningPort = port;
    if (port !== config.port) {
      config.port = port;
      saveConfig(config);
    }
    banner(port);
  };
  const onError = (e) => {
    server.off('listening', onListening);
    if (e.code === 'EADDRINUSE' && index === 0) {
      // 端口被占用：先看看是不是絮语中继已经开着了（比如又双击了一次桌面图标）
      http.get({ host: '127.0.0.1', port, path: '/health', timeout: 1500 }, (res) => {
        let body = '';
        res.on('data', (d) => (body += d));
        res.on('end', () => {
          if (body.includes('xuyu-relay')) {
            console.log('絮语中继已经在运行了，不用再开一个。这个窗口可以关掉。');
            setTimeout(() => process.exit(0), 8000);
          } else {
            listen(index + 1);
          }
        });
      }).on('error', () => listen(index + 1));
    } else if (e.code === 'EADDRINUSE' || e.code === 'EACCES') {
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
  console.log(`  工作区  ${config.workDir}`);
  console.log(line);
  console.log(`  Claude Code  ${s.claude.installed ? s.claude.version : '未安装'}`);
  console.log(`  Codex        ${s.codex.installed ? s.codex.version : '未安装'}`);
  console.log(line);
  console.log('  在 iPhone 的「设置 → 连接」里填上地址和配对码。');
  console.log('  这个窗口开着，手机才能聊天。');
}
