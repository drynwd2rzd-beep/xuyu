// 中继协议的契约测试：起一个真的中继（临时文件夹、随机端口），用 WebSocket 像手机一样连上去（node --test）。
// 只测协议和鉴权，不调用 Claude / Codex；真调用在 selftest.js
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import WebSocket from 'ws';

// config.js 按 APPDATA 定文件夹，必须在 import 中继之前换成临时的
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xuyu-relay-'));
process.env.APPDATA = tmp;
const { createRelay } = await import('../src/server.js');
const { proof } = await import('../src/pairing.js');
const { PROTOCOL, CLOSE } = await import('../src/protocol.js');
const { paths } = await import('../src/config.js');
for (const d of [paths.dir, paths.workspace, paths.uploads, paths.replies]) fs.mkdirSync(d, { recursive: true });

const TOKEN = 'TESTCODE';
const config = {
  port: 0,
  token: TOKEN,
  workDir: path.join(tmp, 'work'),
  backupDir: path.join(tmp, 'backups'),
  models: { claude: ['claude-opus-5-5'], codex: [] },
  // 不存在的命令：状态里显示「未安装」，不会真去调用
  commands: { claude: 'xuyu-test-missing-claude', codex: 'xuyu-test-missing-codex' },
};
fs.mkdirSync(config.backupDir, { recursive: true });

const relay = createRelay(config);
await new Promise((r) => relay.server.listen(0, '127.0.0.1', r));
relay.port = relay.server.address().port;
const url = `ws://127.0.0.1:${relay.port}/ws`;

test.after(() => relay.server.close());

// ---- 像手机一样连接 ----
/** 一个连接：收到的消息排队，next() 取下一条，closed 等关闭码 */
function connect() {
  const ws = new WebSocket(url);
  const queue = [];
  const waiting = [];
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString());
    const w = waiting.shift();
    w ? w(msg) : queue.push(msg);
  });
  const closed = new Promise((resolve) => ws.on('close', (code) => resolve(code)));
  const next = () => (queue.length ? Promise.resolve(queue.shift()) : new Promise((r) => waiting.push(r)));
  const sendJSON = (obj) => ws.send(JSON.stringify(obj));
  return { ws, next, send: sendJSON, closed };
}

/** 连上并对好暗号；code 是手机用的配对码 */
async function pair(code = TOKEN) {
  const c = connect();
  const hello = await c.next();
  const cnonce = crypto.randomBytes(16).toString('hex');
  c.send({ type: 'auth', cnonce, proof: proof(code, 'app', hello.nonce, cnonce) });
  return { ...c, hello, cnonce };
}

// ---- 对暗号 ----
test('先发 hello，对上暗号回 welcome，中继的证明手机能核对', async () => {
  const c = await pair();
  assert.equal(c.hello.type, 'hello');
  assert.equal(c.hello.protocol, PROTOCOL);
  const welcome = await c.next();
  assert.equal(welcome.type, 'welcome');
  assert.equal(welcome.proof, proof(TOKEN, 'relay', c.hello.nonce, c.cnonce));
  c.ws.close();
});

test('第一条不是 auth：按旧版 App 关掉', async () => {
  const c = connect();
  await c.next();
  c.send({ type: 'status', id: 'x' });
  assert.equal(await c.closed, CLOSE.updateApp);
});

test('随机数不合格：按暗号不对关掉', async () => {
  const c = connect();
  await c.next();
  c.send({ type: 'auth', cnonce: 'zz', proof: 'bad' });
  assert.equal(await c.closed, CLOSE.badProof);
});

// ---- 对上以后 ----
test('ping 回 pong，不认识的消息不理也不断开', async () => {
  const c = await pair();
  await c.next();
  c.send({ type: 'teleport', id: 'u' });
  c.send({ type: 'ping', id: 'p1' });
  assert.deepEqual(await c.next(), { type: 'pong', id: 'p1' });
  c.ws.close();
});

test('status 带着协议版本、两家是否安装、模型目录', async () => {
  const c = await pair();
  await c.next();
  c.send({ type: 'status', id: 's1' });
  const s = await c.next();
  assert.equal(s.type, 'status');
  assert.equal(s.id, 's1');
  assert.equal(s.protocol, PROTOCOL);
  assert.equal(s.claude.installed, false);
  assert.deepEqual(s.models.claude, ['claude-opus-5-5']);
  assert.equal(typeof s.autostart, 'boolean');
  c.ws.close();
});

test('没装的引擎：run 直接回中文错误', async () => {
  const c = await pair();
  await c.next();
  c.send({ type: 'run', id: 'r1', engine: 'claude', prompt: '你好' });
  const e = await c.next();
  assert.equal(e.type, 'error');
  assert.equal(e.id, 'r1');
  // Windows 上找不到命令时直接说没装；别的系统要运行一下才知道
  assert.match(e.message, /还没有安装|无法启动/);
  c.ws.close();
});

test('取回不存在的回复：告诉手机已经过期', async () => {
  const c = await pair();
  await c.next();
  c.send({ type: 'resume', id: 'gone', from: 0 });
  const e = await c.next();
  assert.equal(e.type, 'error');
  assert.equal(e.id, 'gone');
  c.ws.close();
});

test('备份分块存进去、列得出来、分段取得回来', async () => {
  const c = await pair();
  await c.next();
  const parts = ['hello ', 'world'];
  for (const [i, p] of parts.entries()) {
    c.send({ type: 'backupChunk', id: `b${i}`, name: 'phone.json', index: i, total: parts.length, data: Buffer.from(p).toString('base64') });
    assert.deepEqual(await c.next(), { type: 'backupChunkSaved', id: `b${i}`, ok: true });
  }
  c.send({ type: 'backups', id: 'l' });
  const list = await c.next();
  assert.deepEqual(list.list.map((b) => b.name), ['phone.json']);
  c.send({ type: 'fetchBackupChunk', id: 'f', name: 'phone.json', offset: 6, length: 100 });
  const chunk = await c.next();
  assert.equal(Buffer.from(chunk.data, 'base64').toString(), 'world');
  assert.equal(chunk.size, 11);
  c.ws.close();
});

// 放在最后：会把本机地址封住
test('连续 5 次对不上暗号：之后的连接直接被拒绝', async () => {
  for (let i = 0; i < 5; i++) {
    const c = await pair('WRONGCODE');
    assert.equal(await c.closed, CLOSE.badProof);
  }
  const c = connect();
  assert.equal(await c.closed, CLOSE.locked);
});
