// 手机和中继互相「对暗号」：配对码不在网上传，双方各出一个随机数，用配对码算出证明交给对方核对。
//   中继先发 hello（带随机数 nonce）→ 手机回 auth（自己的随机数 cnonce + 手机的证明）
//   → 中继核对后回 welcome（中继的证明）→ 手机核对通过才发任何内容
// 这样偷听的人拿不到配对码；冒充中继的设备算不出证明，手机不会把聊天和备份发给它（审查 Z-004、Z-038）。
// 算法和 App 的 RelayPairing.swift 一一对应，改了要两边一起改（规范 RELAY-2）
import crypto from 'node:crypto';

// 先把配对码拉伸成钥匙：偷听到一次对暗号的人，想离线一个个试配对码，每试一次都要算这么多轮
const SALT = 'xuyu-relay-pair-v2';
const ROUNDS = 100_000;

let cache = { code: '', key: null };

function keyFor(code) {
  const normalized = String(code || '').trim().toUpperCase();
  if (cache.code !== normalized) {
    cache = { code: normalized, key: crypto.pbkdf2Sync(normalized, SALT, ROUNDS, 32, 'sha256') };
  }
  return cache.key;
}

/** 一方的证明：role 是 'app' 或 'relay'，两边的随机数都算进去，旧的证明不能拿来重放 */
export function proof(code, role, nonce, cnonce) {
  return crypto.createHmac('sha256', keyFor(code)).update(`${role}|${nonce}|${cnonce}`).digest('hex');
}

export function newNonce() {
  return crypto.randomBytes(16).toString('hex');
}

/** 合格的随机数：16～64 字节的十六进制 */
export function validNonce(s) {
  return /^[0-9a-f]{32,128}$/.test(String(s || ''));
}

/** 比较两个证明：用固定时间的比较，不让人从快慢猜出前几位对不对（审查 Z-481） */
export function sameProof(a, b) {
  const x = Buffer.from(String(a || ''));
  const y = Buffer.from(String(b || ''));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}
