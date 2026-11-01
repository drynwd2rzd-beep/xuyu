// 工作模式的把关：路径判断、工具名单，以及真的运行一次把关钩子（node --test）
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  CLAUDE_WORK_TOOLS, FILE_TOOLS, ASK_TOOLS, HARMLESS_TOOLS, checkPath, isProtected, patchPaths,
} from '../src/policy.js';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'xuyu-work-'));
const gateScript = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'src', 'gate.js');

// ---- 规则 ----
test('给 Claude 开放的每个工具，把关都认得', () => {
  for (const tool of CLAUDE_WORK_TOOLS) {
    assert.ok(FILE_TOOLS.has(tool) || ASK_TOOLS.has(tool) || HARMLESS_TOOLS.has(tool), tool);
  }
});

test('只能读写工作文件夹里面', () => {
  assert.equal(checkPath(root, root, 'a.txt', true), '');
  assert.equal(checkPath(root, root, path.join(root, 'sub', 'b.txt'), true), '');
  assert.notEqual(checkPath(root, root, '../outside.txt', false), '');
  assert.notEqual(checkPath(root, root, os.homedir(), false), '');
});

test('管 AI 权限和指令的文件不许写，但可以读', () => {
  assert.ok(isProtected('.claude/settings.json'));
  assert.ok(isProtected('sub/CLAUDE.md'.toLowerCase()));
  assert.ok(isProtected('.codex/hooks.json'));
  assert.ok(!isProtected('notes/claude.txt'));
  assert.notEqual(checkPath(root, root, '.mcp.json', true), '');
  assert.equal(checkPath(root, root, '.mcp.json', false), '');
});

test('Codex 补丁里的路径都找出来', () => {
  const patch = '*** Begin Patch\n*** Add File: a.txt\n+x\n*** Update File: b/c.txt\n*** Move to: d.txt\n*** End Patch';
  assert.deepEqual(patchPaths(patch), ['a.txt', 'b/c.txt', 'd.txt']);
});

// ---- 真的运行把关钩子 ----
/** 起一个假的中继，记下钩子来问了什么；answer 是它的回答 */
function fakeRelay(answer) {
  const asked = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d));
    req.on('end', () => {
      asked.push({ key: req.headers['x-xuyu-gate'], ...JSON.parse(body) });
      res.end(JSON.stringify({ ok: answer }));
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, asked, port: server.address().port })));
}

function runGate(port, input, engine = 'claude') {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [gateScript], {
      env: { ...process.env, XUYU_ENGINE: engine, XUYU_GATE_URL: `http://127.0.0.1:${port}/gate`, XUYU_GATE_KEY: 'k', XUYU_JOB: 'j1', XUYU_ROOT: root },
    });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.on('close', () => resolve(out ? JSON.parse(out).hookSpecificOutput : null));
    child.stdin.end(JSON.stringify(input));
  });
}

test('读工作文件夹里的文件：放行，并且向中继报到', async () => {
  const relay = await fakeRelay(true);
  const out = await runGate(relay.port, { tool_name: 'Read', tool_input: { file_path: path.join(root, 'a.txt') } });
  relay.server.close();
  assert.equal(out.permissionDecision, 'allow');
  assert.equal(relay.asked.length, 1);
  assert.equal(relay.asked[0].key, 'k');
  assert.equal(relay.asked[0].text, undefined);
});

test('读外面的文件：拒绝', async () => {
  const relay = await fakeRelay(true);
  const out = await runGate(relay.port, { tool_name: 'Read', tool_input: { file_path: os.homedir() } });
  relay.server.close();
  assert.equal(out.permissionDecision, 'deny');
});

test('运行命令：问手机，手机不允许就拒绝', async () => {
  const relay = await fakeRelay(false);
  const out = await runGate(relay.port, { tool_name: 'Bash', tool_input: { command: 'dir' } });
  relay.server.close();
  assert.equal(out.permissionDecision, 'deny');
  assert.equal(relay.asked[0].text, '运行命令：dir');
});

test('中继没有回应：拒绝', async () => {
  const relay = await fakeRelay(true);
  const { port } = relay;
  await new Promise((r) => relay.server.close(r));
  const out = await runGate(port, { tool_name: 'Read', tool_input: { file_path: path.join(root, 'a.txt') } });
  assert.equal(out.permissionDecision, 'deny');
});

test('Codex 放行时什么都不输出，不认识的工具拒绝', async () => {
  const relay = await fakeRelay(true);
  const allowed = await runGate(relay.port, { tool_name: 'Read', tool_input: { file_path: path.join(root, 'a.txt') } }, 'codex');
  const unknown = await runGate(relay.port, { tool_name: 'Teleport', tool_input: {} }, 'codex');
  relay.server.close();
  assert.equal(allowed, null);
  assert.equal(unknown.permissionDecision, 'deny');
});
