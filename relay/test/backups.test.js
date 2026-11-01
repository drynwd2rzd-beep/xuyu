// 电脑上的聊天备份：分块存取、名字清理、只留最近几份（node --test）
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createBackups, backupName } from '../src/backups.js';

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'xuyu-backups-'));
}
const b64 = (s) => Buffer.from(s).toString('base64');

test('名字只留单纯的 .json 文件名', () => {
  assert.equal(backupName('../../evil.json'), 'evil.json');
  assert.equal(backupName('a b.json'), 'a_b.json');
  assert.equal(backupName('x.txt'), '');
  assert.equal(backupName(''), '');
});

test('分块按顺序接上，最后一块到了才出现正式文件', () => {
  const dir = tempDir();
  const store = createBackups(dir);
  assert.ok(store.saveChunk('b.json', 0, 3, b64('aa')));
  assert.ok(!fs.existsSync(path.join(dir, 'b.json')));
  assert.ok(store.saveChunk('b.json', 1, 3, b64('bb')));
  assert.ok(store.saveChunk('b.json', 2, 3, b64('cc')));
  assert.equal(fs.readFileSync(path.join(dir, 'b.json'), 'utf8'), 'aabbcc');
  assert.ok(!fs.existsSync(path.join(dir, 'b.json.part')));
});

test('分块顺序不对、重复、越界都算失败', () => {
  const store = createBackups(tempDir());
  assert.ok(!store.saveChunk('c.json', 1, 3, b64('x')));
  assert.ok(store.saveChunk('c.json', 0, 3, b64('x')));
  assert.ok(!store.saveChunk('c.json', 2, 3, b64('x')));
  assert.ok(store.saveChunk('c.json', 1, 3, b64('x')));
  assert.ok(!store.saveChunk('c.json', 1, 3, b64('x')));
  assert.ok(!store.saveChunk('c.json', 3, 3, b64('x')));
  assert.ok(!store.saveChunk('c.json', -1, 3, b64('x')));
  assert.ok(!store.saveChunk('c.txt', 0, 1, b64('x')));
});

test('分段取回：按偏移读，带回总大小', () => {
  const dir = tempDir();
  const store = createBackups(dir);
  assert.ok(store.save('d.json', b64('0123456789')));
  const first = store.readChunk('d.json', 0, 4);
  assert.equal(Buffer.from(first.data, 'base64').toString(), '0123');
  assert.equal(first.size, 10);
  const last = store.readChunk('d.json', 8, 100);
  assert.equal(Buffer.from(last.data, 'base64').toString(), '89');
  assert.equal(store.readChunk('d.json', 20, 4).data, '');
  assert.deepEqual(store.readChunk('nope.json', 0, 4), { data: '', size: 0 });
  assert.equal(Buffer.from(store.read('d.json'), 'base64').toString(), '0123456789');
});

test('只留最近几份', () => {
  const dir = tempDir();
  const store = createBackups(dir, { keep: 2 });
  for (const [i, name] of ['1.json', '2.json', '3.json'].entries()) {
    fs.writeFileSync(path.join(dir, name), 'x');
    const t = new Date(Date.now() - (10 - i) * 1000);
    fs.utimesSync(path.join(dir, name), t, t);
  }
  assert.ok(store.save('4.json', b64('y')));
  assert.deepEqual(store.list().map((b) => b.name).sort(), ['3.json', '4.json']);
});
