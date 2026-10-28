// 工作模式的把关钩子：Claude Code 每次要用工具之前都会先运行它（PreToolUse），由它决定放行还是拒绝。
// 以前「只在工作文件夹里操作」「危险的事先问」只写在提示词里，AI 不照做也没人拦；现在由这里真正把关：
//   读写文件：只能在工作文件夹里，外面的一律拒绝
//   运行命令、打开网页、上网搜索：先在手机上弹「允许 / 不允许」，点了允许才做；手机没回应就当不允许
// 中继启动时随机生成一把钥匙，只有带着它、从本机来的请求才算数。出任何错都按「不允许」处理
import path from 'node:path';

const FILE_TOOLS = new Set(['Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Glob', 'Grep']);
const ASK_TOOLS = new Set(['Bash', 'WebFetch', 'WebSearch']);

function answer(decision, reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason },
  }));
  process.exit(0);
}

/** 这个路径在不在工作文件夹里（Windows 不分大小写） */
function inside(root, target) {
  const rel = path.relative(path.resolve(root).toLowerCase(), path.resolve(target).toLowerCase());
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function describe(tool, input) {
  const cut = (s, n = 300) => (String(s || '').length > n ? String(s).slice(0, n) + '…' : String(s || ''));
  switch (tool) {
    case 'Bash': return `运行命令：${cut(input.command)}`;
    case 'WebFetch': return `打开网页：${cut(input.url, 200)}`;
    case 'WebSearch': return `上网搜索：${cut(input.query, 200)}`;
    default: return tool;
  }
}

async function ask(text) {
  const res = await fetch(process.env.XUYU_GATE_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-xuyu-gate': process.env.XUYU_GATE_KEY || '' },
    body: JSON.stringify({ job: process.env.XUYU_JOB || '', text }),
    // 比钩子本身的时限（10 分钟）短一点，自己先收尾
    signal: AbortSignal.timeout(9.5 * 60 * 1000),
  });
  const reply = await res.json();
  return reply.ok === true;
}

let raw = '';
process.stdin.on('data', (d) => (raw += d));
process.stdin.on('end', async () => {
  try {
    const input = JSON.parse(raw || '{}');
    const tool = String(input.tool_name || '');
    const args = input.tool_input || {};
    const root = process.env.XUYU_ROOT || '';
    if (FILE_TOOLS.has(tool)) {
      const target = args.file_path || args.notebook_path || args.path;
      const pattern = String(args.pattern || '');
      const base = input.cwd || root;
      if (target && !inside(root, path.resolve(base, String(target)))) {
        return answer('deny', '只能读写工作文件夹里的文件，这个在外面，已拒绝。');
      }
      if (tool === 'Glob' && (path.isAbsolute(pattern) || pattern.split(/[\\/]/).includes('..'))) {
        return answer('deny', '只能在工作文件夹里找文件，已拒绝。');
      }
      return answer('allow', '工作文件夹里的文件');
    }
    if (ASK_TOOLS.has(tool)) {
      const ok = await ask(describe(tool, args));
      return ok ? answer('allow', '用户在手机上点了允许') : answer('deny', '用户在手机上没有允许。不要换个办法做同一件事，告诉用户并问用户想怎么办。');
    }
    return answer('allow', '');
  } catch {
    return answer('deny', '没能在手机上确认，已拒绝。');
  }
});
