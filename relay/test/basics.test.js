// 中继的小工具、防猜配对码、共用数值（node --test）
import test from 'node:test';
import assert from 'node:assert/strict';
import { cut, isLocal, isPrivate, isTailscale, trustedAddress, plainAddress } from '../src/util.js';
import { createLockout } from '../src/security.js';
import { TIMEOUTS, FALLBACK_PORTS, DEFAULT_PORT } from '../src/protocol.js';

// ---- 文字 ----
test('cut 只截太长的', () => {
  assert.equal(cut('abc', 5), 'abc');
  assert.equal(cut('abcdef', 3), 'abc…');
  assert.equal(cut(undefined), '');
});

// ---- 地址 ----
test('可信线路：局域网、Tailscale、本机', () => {
  for (const ip of ['127.0.0.1', '::1', '::ffff:127.0.0.1', '10.0.0.8', '192.168.1.5', '172.16.0.1', '172.31.255.1', '100.64.0.1', '100.127.9.9']) {
    assert.ok(trustedAddress(ip), ip);
  }
  for (const ip of ['8.8.8.8', '172.32.0.1', '172.15.0.1', '100.63.0.1', '100.128.0.1', '192.169.0.1', '', undefined]) {
    assert.ok(!trustedAddress(ip), String(ip));
  }
});

test('出门线路只认 100.64～127，和可信线路的判断一致', () => {
  assert.ok(isTailscale('100.100.1.1'));
  assert.ok(!isTailscale('100.1.1.1'));
  assert.ok(!isPrivate('100.100.1.1'));
  assert.ok(isPrivate('::ffff:192.168.0.2'));
  assert.ok(isLocal('::ffff:127.0.0.1'));
  assert.equal(plainAddress('::ffff:10.0.0.1'), '10.0.0.1');
});

// ---- 防猜配对码 ----
test('连续错 5 次封 15 分钟，过期后解封，对上一次清零', () => {
  let t = 0;
  const lock = createLockout({ lockAfter: 5, lockFor: 1000, now: () => t });
  for (let i = 0; i < 4; i++) assert.equal(lock.fail('a'), false);
  assert.equal(lock.isLocked('a'), false);
  assert.equal(lock.fail('a'), true);
  assert.equal(lock.isLocked('a'), true);
  t = 1001;
  assert.equal(lock.isLocked('a'), false);
  // 解封后重新数
  assert.equal(lock.fail('a'), false);
  lock.clear('a');
  for (let i = 0; i < 4; i++) lock.fail('a');
  assert.equal(lock.isLocked('a'), false);
});

test('过期的记录会被清掉', () => {
  let t = 0;
  const lock = createLockout({ lockAfter: 5, lockFor: 1000, now: () => t });
  lock.fail('a');
  lock.fail('b');
  t = 500;
  lock.prune();
  assert.equal(lock.size, 2);
  t = 2000;
  lock.prune();
  assert.equal(lock.size, 0);
});

// ---- 共用数值 ----
test('工作模式的时限：手机确认 < 钩子收尾 < 钩子时限', () => {
  assert.ok(TIMEOUTS.approval < TIMEOUTS.gateSelf);
  assert.ok(TIMEOUTS.gateSelf < TIMEOUTS.gateHook);
  // 写进钩子设置的是整秒
  assert.ok(Number.isInteger(TIMEOUTS.gateHook / 1000));
});

test('默认端口在备用端口里', () => {
  assert.ok(FALLBACK_PORTS.includes(DEFAULT_PORT));
});
