// 工作模式的确认：把关钩子（gate.js）问「允不允许」，转给手机，等你点。
// 不放进回复的事件里（不按编号重放），一次只有一个；断线重连时由 jobs.resumeJob 再发一遍
import crypto from 'node:crypto';
import { TIMEOUTS } from './protocol.js';
import { isLocal, send } from './util.js';

// ---- 问手机 ----
export function approvalMessage(job) {
  return { type: 'approve', id: job.id, req: job.approval.req, text: job.approval.text };
}

/** 收尾这一次确认：ok 是你点的结果；没有在等的确认时什么都不做 */
export function settleApproval(job, ok) {
  const pending = job.approval;
  if (!pending) return;
  job.approval = null;
  clearTimeout(pending.timer);
  pending.resolve(ok);
}

/** 发到正在收这条回复的手机上，等你点「允许 / 不允许」；太久没人点就当不允许 */
export function requestApproval(job, text, wait = TIMEOUTS.approval) {
  return new Promise((resolve) => {
    // 上一个还没答就又来一个（不应该发生）：上一个按不允许
    settleApproval(job, false);
    const req = crypto.randomUUID();
    const timer = setTimeout(() => settleApproval(job, false), wait);
    job.approval = { req, text, resolve, timer };
    for (const ws of job.subscribers) send(ws, approvalMessage(job));
    console.log(`? ${job.id.slice(0, 8)} 等手机确认：${text.slice(0, 60)}`);
  });
}

// ---- 把关钩子来报到 ----
/**
 * 只认本机、带着钥匙的请求。每次都记一笔（引擎靠它发现钩子没起作用）；
 * 带着 text 的是要问你的，一直等到你在手机上点了（或超时）才回答。findJob(id) 找到这次回复
 */
export function handleGate(req, res, { key, findJob }) {
  if (!isLocal(req.socket.remoteAddress) || req.headers['x-xuyu-gate'] !== key) {
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
      const job = findJob(String(id));
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
