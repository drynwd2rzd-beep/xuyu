// 一次回复：存附件、拼工作模式的说明、调用引擎、把工作模式做好的文件发回手机
import fs from 'node:fs';
import path from 'node:path';
import { paths, workPaths } from './config.js';
import { OUTBOX, UPLOAD_KEEP } from './protocol.js';
import { runEngine } from './engines.js';
import { send, trustedAddress } from './util.js';
import { createJob, publish, finishJob } from './jobs.js';
import { settleApproval } from './approval.js';

// ---- 附件：聊天时存到 uploads，10 分钟后删除；工作模式存进工作文件夹的「收到的文件」，一直保留 ----
function saveAttachments(config, id, attachments = [], work = false) {
  const saved = [];
  const dir = work ? workPaths(config).inbox : paths.uploads;
  attachments.forEach((a, i) => {
    const safe = String(a.name || `file-${i}`).replace(/[^\w.\-一-龥]/g, '_').slice(-80);
    const stamp = new Date().toISOString().slice(5, 16).replace(/[-T:]/g, '');
    const file = path.join(dir, work ? `${stamp}-${safe}` : `${id}-${i}-${safe}`);
    fs.writeFileSync(file, Buffer.from(String(a.data || ''), 'base64'));
    saved.push({ file, kind: a.kind === 'image' ? 'image' : 'file', name: a.name || safe });
  });
  if (saved.length && !work) {
    setTimeout(() => saved.forEach((s) => fs.rm(s.file, { force: true }, () => {})), UPLOAD_KEEP).unref();
  }
  return saved;
}

// ---- 工作模式 ----
/** 工作模式的说明：告诉 AI 能在哪里动手、怎么把文件发回手机 */
function workGuide(config) {
  const w = workPaths(config);
  return [
    `你现在可以在用户电脑上的工作文件夹「${w.root}」里读写文件、运行命令，帮用户把事情做完。`,
    '只在这个文件夹里操作：读写外面的文件会被直接拒绝。不要删除用户没让你删的文件，不要安装软件或改系统设置。',
    '运行命令、打开网页、上网搜索之前，系统会自动在用户手机上请求确认，你不用再另外问；用户没有允许时，不要换个办法做同一件事，告诉用户并问用户想怎么办。',
    `用户从手机发来的文件在「${w.inbox}」。`,
    `要把做好的文件发到用户手机上，就把文件保存（或复制）到「${w.outbox}」，系统会自动发过去。`,
    '做完后用一两句口语化的话告诉用户结果。',
  ].join('\n');
}

/** 把「发给手机」文件夹里这次新出现的文件发回手机，然后挪到「已发送」 */
function sendOutbox(config, job, since) {
  const w = workPaths(config);
  let names = [];
  try {
    names = fs.readdirSync(w.outbox);
  } catch {
    return;
  }
  for (const name of names.slice(0, OUTBOX.maxFiles)) {
    const file = path.join(w.outbox, name);
    try {
      const st = fs.statSync(file);
      if (!st.isFile() || st.mtimeMs < since - 2000) continue;
      if (st.size > OUTBOX.maxBytes) {
        publish(job, { type: 'step', id: job.id, text: `${name} 超过 ${OUTBOX.maxBytes / 1024 / 1024}MB，留在电脑上没有发送` });
        continue;
      }
      publish(job, { type: 'file', id: job.id, name, data: fs.readFileSync(file).toString('base64') });
      let target = path.join(w.sent, name);
      if (fs.existsSync(target)) target = path.join(w.sent, `${Date.now()}-${name}`);
      fs.renameSync(file, target);
    } catch {
      // 单个文件出错不影响其他文件
    }
  }
}

// ---- 一次回复 ----
/**
 * 手机发来 run：开一个回复任务，跑完把结果发回去。
 * command(engine) 给出能直接运行的命令；gate 是把关钩子找中继用的地址和钥匙（url 是函数：端口可能换过）
 */
export async function handleRun(ws, msg, { config, command, gate }) {
  const id = String(msg.id || '');
  const engine = msg.engine === 'codex' ? 'codex' : 'claude';
  const cmd = command(engine);
  if (!cmd) {
    send(ws, { type: 'error', id, message: engine === 'codex' ? '电脑上还没有安装 Codex。' : '电脑上还没有安装 Claude Code。' });
    return;
  }
  const work = msg.work === true;
  // 工作模式只接受可信线路：家里局域网、Tailscale、本机
  if (work && !trustedAddress(ws.remoteAddress)) {
    send(ws, { type: 'error', id, message: '为了安全，「操作电脑」只能在家里的 Wi-Fi 或 Tailscale 下使用。' });
    return;
  }
  const job = createJob(id, ws);
  const controller = job.controller;
  // 你取消了这条回复：还在等的确认按不允许收尾
  controller.signal.addEventListener('abort', () => settleApproval(job, false));
  const started = Date.now();
  console.log(`→ ${id.slice(0, 8)} ${engine}${msg.model ? ' ' + msg.model : ''}${msg.effort ? ' · ' + msg.effort : ''}${work ? ' · 工作模式' : ''}`);
  // 整个过程（包括存附件）出的错都在这里接住，回给手机；不让一个错误把整个中继带倒（以前存附件时硬盘满了，中继会直接退出）
  try {
    const saved = saveAttachments(config, id.replace(/[^\w-]/g, ''), msg.attachments, work);
    let prompt = String(msg.prompt || '');
    const files = saved.filter((s) => work || engine === 'claude' || s.kind !== 'image');
    if (files.length) {
      prompt += '\n\n用户附带的文件（可以直接读取）：\n' + files.map((f) => `- ${f.name}: ${f.file}`).join('\n');
    }
    const system = work ? `${msg.system || ''}\n\n${workGuide(config)}`.trim() : msg.system || '';
    await runEngine({
      engine,
      command: cmd,
      model: msg.model || '',
      effort: /^[a-z]+$/.test(String(msg.effort || '')) ? msg.effort : '',
      system,
      prompt,
      files,
      images: saved.filter((s) => s.kind === 'image').map((s) => s.file),
      cwd: work ? workPaths(config).root : paths.workspace,
      readDirs: work ? [] : [paths.uploads],
      signal: controller.signal,
      work,
      gate: { url: gate.url(), key: gate.key, job: id, calls: () => job.gateCalls },
      onEvent: (e) => publish(job, { type: e.type, id, text: e.text }),
    });
    if (work) sendOutbox(config, job, started);
    finishJob(job, { type: 'done', id });
    console.log(`✓ ${id.slice(0, 8)} ${((Date.now() - started) / 1000).toFixed(1)}s`);
  } catch (e) {
    finishJob(job, { type: 'error', id, message: controller.signal.aborted ? '已取消' : e.message });
    console.log(`✗ ${id.slice(0, 8)} ${e.message}`);
  } finally {
    settleApproval(job, false);
  }
}
