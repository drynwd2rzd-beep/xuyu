// 工作模式的把关钩子：Claude Code 和 Codex 每次要用工具之前都会先运行它（PreToolUse），由它决定放行还是拒绝。
// 以前「只在工作文件夹里操作」「危险的事先问」只写在提示词里，AI 不照做也没人拦；现在由这里真正把关：
//   读写文件：只能在工作文件夹里，外面的一律拒绝；会改 AI 自己权限和指令的文件（.claude、CLAUDE.md 这类）不许写
//   运行命令、打开网页、上网搜索：先在手机上弹「允许 / 不允许」，点了允许才做；手机没回应就当不允许
//   不认识的工具：拒绝
// 中继启动时随机生成一把钥匙，只有带着它、从本机来的请求才算数。出任何错都按「不允许」处理
import fs from 'node:fs';
import path from 'node:path';

// ---- 工具分类 ----
const FILE_TOOLS = new Set(['Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Glob', 'Grep']);
const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
// Codex 的命令也叫 Bash；web_search 是 Codex 的上网搜索
const ASK_TOOLS = new Set(['Bash', 'WebFetch', 'WebSearch', 'web_search']);
// 只是整理步骤，不碰电脑
const HARMLESS_TOOLS = new Set(['TodoWrite', 'update_plan']);

// 会改变 AI 权限或指令的文件和文件夹：AI 写了它们，下一次干活时就能绕过把关（审查 Z-005）
const PROTECTED_DIRS = new Set(['.claude', '.codex', '.git']);
const PROTECTED_FILES = new Set(['.mcp.json', 'claude.md', 'claude.local.md', 'agents.md', 'agents.override.md']);

// 确认卡片上要能看清整条命令：太长的直接拒绝，让 AI 拆开做（审查 Z-031）
const MAX_ASK_TEXT = 1500;

// ---- 回答 ----
const isCodex = process.env.XUYU_ENGINE === 'codex';

function answer(decision, reason) {
  // Codex 只认「拒绝」：放行就什么都不输出。Claude 要明确放行，因为它没有预先允许任何工具（钩子出错时默认不放行）
  if (!(isCodex && decision === 'allow')) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason },
    }));
  }
  process.exit(0);
}

// ---- 路径 ----
/** 解析符号链接和目录联接以后的真实路径；目标还不存在时，取最近一个存在的上级的真实路径再拼回去 */
function realPath(target) {
  const rest = [];
  let current = path.resolve(target);
  for (;;) {
    try {
      return path.join(fs.realpathSync.native(current), ...rest);
    } catch {
      const parent = path.dirname(current);
      if (parent === current) return path.resolve(target);
      rest.unshift(path.basename(current));
      current = parent;
    }
  }
}

/** 相对工作文件夹的路径；在外面时返回 null（Windows 不分大小写） */
function relativeInside(root, target) {
  const rel = path.relative(realPath(root).toLowerCase(), realPath(target).toLowerCase());
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel)) ? rel : null;
}

function isProtected(rel) {
  const parts = rel.split(/[\\/]/).filter(Boolean);
  return parts.some((p) => PROTECTED_DIRS.has(p)) || PROTECTED_FILES.has(parts[parts.length - 1] || '');
}

/** 检查一个要读写的路径；不行时返回拒绝的理由 */
function checkPath(root, base, target, writing) {
  const rel = relativeInside(root, path.resolve(base, String(target)));
  if (rel === null) return '只能读写工作文件夹里的文件，这个在外面，已拒绝。';
  if (writing && isProtected(rel)) return '这个文件管着 AI 自己的权限和指令，不能改，已拒绝。';
  return '';
}

/** Codex 改文件用的补丁里写到的所有路径 */
function patchPaths(patch) {
  const re = /^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/gm;
  return [...String(patch || '').matchAll(re)].map((m) => m[1].trim());
}

// ---- 问中继 ----
function describe(tool, input) {
  switch (tool) {
    case 'Bash': return `运行命令：${String(input.command || '')}`;
    case 'WebFetch': return `打开网页：${String(input.url || '')}`;
    default: return `上网搜索：${String(input.query || '')}`;
  }
}

/** 告诉中继「把关来过了」；要问手机时带上 text，等到你点了才回来。中继没回应就当不允许 */
async function tellRelay(text) {
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

// ---- 判断 ----
async function decide(input) {
  const tool = String(input.tool_name || '');
  const args = input.tool_input || {};
  const root = process.env.XUYU_ROOT || '';
  const base = input.cwd || root;
  if (!root) return answer('deny', '没找到工作文件夹，已拒绝。');

  if (ASK_TOOLS.has(tool)) {
    const text = describe(tool, args);
    if (text.length > MAX_ASK_TEXT) return answer('deny', '这条太长了，手机上看不全。拆成几步短一点的再做。');
    const ok = await tellRelay(text);
    return ok ? answer('allow', '用户在手机上点了允许') : answer('deny', '用户在手机上没有允许。不要换个办法做同一件事，告诉用户并问用户想怎么办。');
  }

  // 下面这些不用问手机，但也要让中继知道把关在工作（中继发现有工具没经过把关，就会停下这次工作）
  if (!(await tellRelay(undefined))) return answer('deny', '没能联系上中继，已拒绝。');

  if (FILE_TOOLS.has(tool)) {
    const target = args.file_path || args.notebook_path || args.path;
    const pattern = String(args.pattern || '');
    const reason = target ? checkPath(root, base, target, WRITE_TOOLS.has(tool)) : '';
    if (reason) return answer('deny', reason);
    if (tool === 'Glob' && (path.isAbsolute(pattern) || pattern.split(/[\\/]/).includes('..'))) {
      return answer('deny', '只能在工作文件夹里找文件，已拒绝。');
    }
    return answer('allow', '工作文件夹里的文件');
  }
  if (tool === 'apply_patch') {
    const targets = patchPaths(args.command || args.input || args.patch);
    if (!targets.length) return answer('deny', '看不出要改哪个文件，已拒绝。');
    for (const target of targets) {
      const reason = checkPath(root, base, target, true);
      if (reason) return answer('deny', reason);
    }
    return answer('allow', '工作文件夹里的文件');
  }
  if (HARMLESS_TOOLS.has(tool)) return answer('allow', '');
  return answer('deny', '工作模式里不能用这个工具，已拒绝。');
}

let raw = '';
process.stdin.on('data', (d) => (raw += d));
process.stdin.on('end', async () => {
  try {
    await decide(JSON.parse(raw || '{}'));
  } catch {
    answer('deny', '没能在手机上确认，已拒绝。');
  }
});
