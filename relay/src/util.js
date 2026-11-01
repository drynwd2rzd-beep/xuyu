// 中继各处共用的小工具：截断文字、判断地址、给手机发消息

// ---- 文字 ----
/** 太长的文字截断，末尾加省略号 */
export function cut(s, n = 90) {
  const text = String(s ?? '');
  return text.length > n ? text.slice(0, n) + '…' : text;
}

// ---- 地址 ----
/** 去掉 IPv6 包着的 IPv4 前缀（::ffff:192.168.1.2 → 192.168.1.2） */
export function plainAddress(ip) {
  return String(ip || '').replace(/^::ffff:/, '');
}

function octets(ip) {
  return plainAddress(ip).split('.').map(Number);
}

/** 本机 */
export function isLocal(ip) {
  const from = plainAddress(ip);
  return from === '127.0.0.1' || from === '::1';
}

/** 家里局域网：10.x、172.16～31.x、192.168.x */
export function isPrivate(ip) {
  const [p, q] = octets(ip);
  return p === 10 || p === 192 && q === 168 || p === 172 && q >= 16 && q <= 31;
}

/** Tailscale（出门线路）：100.64～127.x */
export function isTailscale(ip) {
  const [p, q] = octets(ip);
  return p === 100 && q >= 64 && q <= 127;
}

/** 可信线路：家里局域网、Tailscale、本机 */
export function trustedAddress(ip) {
  return isLocal(ip) || isPrivate(ip) || isTailscale(ip);
}

// ---- 发送 ----
/** 给一台手机发一条消息；已经断开的不发 */
export function send(ws, obj) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}
