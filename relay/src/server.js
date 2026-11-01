// 絮语中继的入口：开 WebSocket 服务、对暗号、把手机发来的消息分给各部分处理、监听端口。
//   catalog.js 状态和模型目录　run.js 一次回复　jobs.js 回复任务和续传　approval.js 工作模式确认
//   backups.js 备份　autostart.js 开机自启　security.js 防猜配对码　protocol.js 共用的数值　util.js 小工具
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { loadConfig, saveConfig } from './config.js';
import { resolveCommand } from './resolve.js';
import { proof, newNonce, validNonce, sameProof } from './pairing.js';
import { PROTOCOL, FALLBACK_PORTS, MAX_PAYLOAD, CLOSE, SECURITY } from './protocol.js';
import { plainAddress, isLocal, isPrivate, isTailscale, trustedAddress, send } from './util.js';
import { createLockout } from './security.js';
import { createStatus } from './catalog.js';
import { setAutostart } from './autostart.js';
import { jobs, resumeJob, unsubscribe, startPruning } from './jobs.js';
import { settleApproval, handleGate } from './approval.js';
import { createBackups } from './backups.js';
import { handleRun } from './run.js';

// ---- 中继 ----
/**
 * 建好中继（还没监听端口）。config 是 loadConfig() 的结果；
 * 返回的 relay.server 由调用方决定监听哪个端口，监听后设 relay.port（把关钩子靠它找回中继）
 */
export function createRelay(config) {
  // 工作模式把关钩子（gate.js）找中继问「用户允不允许」时要带的钥匙：每次启动随机生成，只在本机用
  const gateKey = crypto.randomBytes(16).toString('hex');
  const command = (engine) => resolveCommand(config.commands[engine] || engine);
  const status = createStatus(config, command);
  const backups = createBackups(config.backupDir);
  const lockout = createLockout();
  const pruneTimer = setInterval(() => lockout.prune(), SECURITY.lockFor);
  pruneTimer.unref();

  const relay = { port: config.port, status };
  const gate = { url: () => `http://127.0.0.1:${relay.port}/gate`, key: gateKey };

  const server = http.createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/gate') {
      handleGate(req, res, { key: gateKey, findJob: (id) => jobs.get(id) });
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

  const wss = new WebSocketServer({ server, path: '/ws', maxPayload: MAX_PAYLOAD });
  // WebSocketServer 会转发底层的 error 事件，这里统一在 listen 时处理
  wss.on('error', () => {});
  server.on('close', () => clearInterval(pruneTimer));

  // ---- 对暗号：对上以前，除了 auth 什么都不认，也什么都不发（pairing.js） ----
  wss.on('connection', (ws, req) => {
    // 第一件事：连接出错（坏帧、超过大小上限）只断开这一个连接，不让整个中继崩溃（审查 Z-003）
    ws.on('error', (e) => console.log(`连接出错：${e.message}`));
    const from = plainAddress(req.socket.remoteAddress);
    // 公网来的一律不接（审查 Z-004）
    if (!trustedAddress(from)) {
      ws.close(CLOSE.untrusted, 'untrusted');
      return;
    }
    if (lockout.isLocked(from)) {
      ws.close(CLOSE.locked, 'locked');
      return;
    }
    const nonce = newNonce();
    let authed = false;
    let rejected = false;
    const authTimer = setTimeout(() => { if (!authed) ws.close(CLOSE.badProof, 'no auth'); }, SECURITY.authWait);
    send(ws, { type: 'hello', protocol: PROTOCOL, nonce });

    function authenticate(msg) {
      // 已经拒绝了：关闭前又到的消息不再算错
      if (rejected) return;
      if (msg.type !== 'auth') {
        rejected = true;
        ws.close(CLOSE.updateApp, 'update app');
        return;
      }
      const cnonce = String(msg.cnonce || '');
      if (!validNonce(cnonce) || !sameProof(msg.proof, proof(config.token, 'app', nonce, cnonce))) {
        rejected = true;
        if (lockout.fail(from)) console.log(`⚠ ${from} 连续对不上配对码，已暂时拒绝它 ${SECURITY.lockFor / 60000} 分钟`);
        ws.close(CLOSE.badProof, 'bad proof');
        return;
      }
      authed = true;
      clearTimeout(authTimer);
      lockout.clear(from);
      ws.remoteAddress = from;
      send(ws, { type: 'welcome', proof: proof(config.token, 'relay', nonce, cnonce) });
      console.log(`iPhone 已连接（${from}${isTailscale(from) ? '，出门线路' : ''}）`);
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
      await dispatch(ws, msg);
    });
    ws.on('close', () => {
      clearTimeout(authTimer);
      if (!authed) return;
      unsubscribe(ws);
      console.log('iPhone 已断开');
    });
  });

  // ---- 消息分发：不认识的类型不理（规范 RELAY-3） ----
  async function dispatch(ws, msg) {
    switch (msg.type) {
      case 'status':
        send(ws, { type: 'status', id: msg.id, ...(await status()) });
        break;
      case 'run':
        handleRun(ws, msg, { config, command, gate });
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
        send(ws, { type: 'backupSaved', id: msg.id, ok: backups.save(msg.name, msg.data) });
        break;
      case 'backups':
        send(ws, { type: 'backups', id: msg.id, list: backups.list() });
        break;
      case 'fetchBackup':
        send(ws, { type: 'backupData', id: msg.id, data: backups.read(msg.name) });
        break;
      case 'backupChunk':
        send(ws, { type: 'backupChunkSaved', id: msg.id, ok: backups.saveChunk(msg.name, msg.index, msg.total, msg.data) });
        break;
      case 'fetchBackupChunk':
        send(ws, { type: 'backupChunkData', id: msg.id, ...backups.readChunk(msg.name, msg.offset, msg.length) });
        break;
      case 'ping':
        send(ws, { type: 'pong', id: msg.id });
        break;
    }
  }

  relay.server = server;
  return relay;
}

// ---- 监听端口：被占用或被系统保留时，自动换下一个，并记住能用的端口 ----
function listen(config, relay, candidates, index = 0) {
  const { server } = relay;
  const port = candidates[index];
  if (port === undefined) {
    console.error('找不到可用的端口，请重启电脑后再试。');
    process.exit(1);
  }
  const onListening = () => {
    server.off('error', onError);
    relay.port = port;
    if (port !== config.port) {
      config.port = port;
      saveConfig(config);
    }
    banner(config, relay, port);
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
            listen(config, relay, candidates, index + 1);
          }
        });
      }).on('error', () => listen(config, relay, candidates, index + 1));
    } else if (e.code === 'EADDRINUSE' || e.code === 'EACCES') {
      listen(config, relay, candidates, index + 1);
    } else {
      console.error(e.message);
      process.exit(1);
    }
  };
  server.once('error', onError);
  server.once('listening', onListening);
  server.listen(port, '0.0.0.0');
}

// ---- 启动横幅 ----
/** 手机能连的局域网地址（排除代理/VPN 的虚拟网卡），Tailscale 地址放在后面 */
function lanAddresses() {
  const lan = [];
  const tailscale = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (isPrivate(a.address)) lan.push(a.address);
      else if (isTailscale(a.address)) tailscale.push(a.address);
    }
  }
  return [...lan, ...tailscale];
}

async function banner(config, relay, port) {
  const s = await relay.status();
  const line = '─'.repeat(44);
  console.log(line);
  console.log('  絮语中继已启动');
  console.log(line);
  for (const ip of lanAddresses()) console.log(`  地址    ${ip}:${port}`);
  // 配对码只在这里显示：要抄到手机上（规范 ERR-4 的例外）
  console.log(`  配对码  ${config.token}`);
  console.log(`  工作区  ${config.workDir}`);
  console.log(line);
  console.log(`  Claude Code  ${s.claude.installed ? s.claude.version : '未安装'}`);
  console.log(`  Codex        ${s.codex.installed ? s.codex.version : '未安装'}`);
  console.log(line);
  console.log('  在 iPhone 的「设置 → 连接」里填上地址和配对码。');
  console.log('  这个窗口开着，手机才能聊天。');
}

// ---- 直接运行 node src/server.js 时启动（测试里只 import，不启动） ----
// Windows 的盘符大小写可能不一样（d:\ 和 D:\），按不分大小写比较
const isMain = process.argv[1]
  && path.resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase();
if (isMain) {
  // 兜底：任何没接住的错误只记一行，中继不退出（审查 Z-003、规范 RELAY-9）
  process.on('uncaughtException', (e) => console.log(`出错了（中继继续运行）：${e?.message || e}`));
  process.on('unhandledRejection', (e) => console.log(`出错了（中继继续运行）：${e?.message || e}`));
  const config = loadConfig();
  const relay = createRelay(config);
  startPruning();
  listen(config, relay, [...new Set([config.port, ...FALLBACK_PORTS])]);
}
