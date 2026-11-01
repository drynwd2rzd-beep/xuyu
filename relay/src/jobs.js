// 回复任务：手机断开也继续跑；写好的回复在内存和硬盘各存 24 小时，重新连上或重新打开 App 后接着收
import fs from 'node:fs';
import path from 'node:path';
import { paths } from './config.js';
import { KEEP } from './protocol.js';
import { send } from './util.js';
import { approvalMessage } from './approval.js';

export const jobs = new Map();

function replyFile(id) {
  return path.join(paths.replies, `${String(id).replace(/[^\w-]/g, '')}.json`);
}

// ---- 开始和收尾 ----
/** 新开一个回复任务，ws 是发起它的手机。gateCalls：把关钩子这次被问过几次，引擎拿它核对「每个执行过的工具都经过了把关」 */
export function createJob(id, ws) {
  const job = { id, events: [], final: null, subscribers: new Set([ws]), controller: new AbortController(), approval: null, gateCalls: 0 };
  jobs.set(id, job);
  return job;
}

/** 发一个事件给所有在收这条回复的手机，并记下来以便断线后重放 */
export function publish(job, obj) {
  job.events.push(obj);
  const seq = job.events.length;
  for (const ws of job.subscribers) send(ws, { ...obj, seq });
}

export function finishJob(job, obj) {
  job.final = obj;
  for (const ws of job.subscribers) send(ws, obj);
  // 存到硬盘：中继重启了也能取回
  fs.writeFile(replyFile(job.id), JSON.stringify({ events: job.events, final: obj, at: Date.now() }), () => {});
  // unref：只靠这个计时器不让进程一直开着（测试结束时能退出）
  setTimeout(() => jobs.delete(job.id), KEEP).unref();
}

// ---- 断线后接着收 ----
/** 从第 from 个事件起重放给这台手机；内存里没有就从硬盘读 */
export function resumeJob(ws, id, from) {
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

/** 手机断开：不取消正在进行的回复，等它回来继续收 */
export function unsubscribe(ws) {
  for (const job of jobs.values()) job.subscribers.delete(ws);
}

// ---- 清理 ----
/** 清理超过 24 小时的回复，启动时一次、之后每小时一次 */
export function startPruning() {
  const prune = () => fs.readdir(paths.replies, (err, names) => {
    if (err) return;
    for (const name of names) {
      const file = path.join(paths.replies, name);
      fs.stat(file, (e, st) => { if (!e && Date.now() - st.mtimeMs > KEEP) fs.rm(file, { force: true }, () => {}); });
    }
  });
  prune();
  return setInterval(prune, 60 * 60 * 1000);
}
