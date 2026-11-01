// 中继和 App 之间、中继各部分之间共用的数值，集中在这里（规范 RELAY-2）。
// App 那边对应的常量在 App/Services/RelayClient.swift 等处，改了要两边一起改

// ---- 协议 ----
// 2：连接时先对暗号（pairing.js），配对码不再放在网址里
export const PROTOCOL = 2;

/** 默认端口和被占用时依次尝试的备用端口 */
export const DEFAULT_PORT = 51888;
export const FALLBACK_PORTS = [51888, 52888, 53888, 54888, 47823];

/** 一条 WebSocket 消息最大 64MB；大的备份分块传 */
export const MAX_PAYLOAD = 64 * 1024 * 1024;

/** 关闭码：暗号不对、手机的 App 太旧（还在用旧的连接方式）、猜错太多次暂时封住、不是可信线路 */
export const CLOSE = { badProof: 4001, updateApp: 4002, locked: 4003, untrusted: 4004 };

// ---- 安全 ----
export const SECURITY = {
  /** 同一个地址连续对不上几次暗号就封住 */
  lockAfter: 5,
  /** 封多久 */
  lockFor: 15 * 60 * 1000,
  /** 连上以后多久内必须对完暗号 */
  authWait: 10 * 1000,
};

// ---- 回复任务 ----
/** 写好的回复在内存和硬盘各存 24 小时，重新连上或重新打开 App 后接着收；没传完的备份半截也按这个清 */
export const KEEP = 24 * 60 * 60 * 1000;
/** 聊天时的附件 10 分钟后删除 */
export const UPLOAD_KEEP = 10 * 60 * 1000;
/** 工作模式一次最多发回几个文件、每个最大多少 */
export const OUTBOX = { maxFiles: 10, maxBytes: 20 * 1024 * 1024 };

// ---- 工作模式的三个时限 ----
// 必须满足：手机确认等待 < 把关钩子自己收尾 < Claude / Codex 给钩子的时限。
// 反过来的话，钩子会先被 Claude 杀掉，而被杀掉的钩子会被当成放行（审查 Z-500、R9-09）
export const TIMEOUTS = {
  /** 等你在手机上点「允许 / 不允许」，太久没人点就当不允许 */
  approval: 9 * 60 * 1000,
  /** 把关钩子问中继最多等这么久，自己先收尾 */
  gateSelf: 9.5 * 60 * 1000,
  /** 写进钩子设置里的时限（钩子默认只等 60 秒） */
  gateHook: 10 * 60 * 1000,
};
if (!(TIMEOUTS.approval < TIMEOUTS.gateSelf && TIMEOUTS.gateSelf < TIMEOUTS.gateHook)) {
  throw new Error('工作模式的时限顺序不对：必须 手机确认 < 钩子收尾 < 钩子时限');
}

// ---- 备份 ----
export const BACKUP = {
  /** 电脑上只留最近几份 */
  keep: 30,
  /** 取回大的备份时一次最多读多少 */
  maxChunk: 8 * 1024 * 1024,
};

// ---- 模型 ----
/** Claude 的推理强度档位 */
export const CLAUDE_EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'];
