// 工作模式把关的规则：哪些工具能用、哪些要问手机、哪些路径能读写。
// gate.js（把关钩子）照它判断，engines.js 照它给 Claude 开放工具，两边只看这一份（审查 Z-500）
import fs from 'node:fs';
import path from 'node:path';

// ---- 工具分类 ----
export const FILE_TOOLS = new Set(['Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Glob', 'Grep']);
export const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
// Codex 的命令也叫 Bash；web_search 是 Codex 的上网搜索
export const ASK_TOOLS = new Set(['Bash', 'WebFetch', 'WebSearch', 'web_search']);
// 只是整理步骤，不碰电脑
export const HARMLESS_TOOLS = new Set(['TodoWrite', 'update_plan']);

/** 工作模式下给 Claude 开放的工具：每一个都必须在上面的分类里，把关才认得（测试核对） */
export const CLAUDE_WORK_TOOLS = ['Read', 'Write', 'Edit', 'MultiEdit', 'Glob', 'Grep', 'Bash', 'TodoWrite', 'WebSearch', 'WebFetch'];

// 会改变 AI 权限或指令的文件和文件夹：AI 写了它们，下一次干活时就能绕过把关（审查 Z-005）
const PROTECTED_DIRS = new Set(['.claude', '.codex', '.git']);
const PROTECTED_FILES = new Set(['.mcp.json', 'claude.md', 'claude.local.md', 'agents.md', 'agents.override.md']);

// 确认卡片上要能看清整条命令：太长的直接拒绝，让 AI 拆开做（审查 Z-031）
export const MAX_ASK_TEXT = 1500;

// ---- 路径 ----
/** 解析符号链接和目录联接以后的真实路径；目标还不存在时，取最近一个存在的上级的真实路径再拼回去 */
export function realPath(target) {
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
export function relativeInside(root, target) {
  const rel = path.relative(realPath(root).toLowerCase(), realPath(target).toLowerCase());
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel)) ? rel : null;
}

export function isProtected(rel) {
  const parts = rel.split(/[\\/]/).filter(Boolean);
  return parts.some((p) => PROTECTED_DIRS.has(p)) || PROTECTED_FILES.has(parts[parts.length - 1] || '');
}

/** 检查一个要读写的路径；不行时返回拒绝的理由 */
export function checkPath(root, base, target, writing) {
  const rel = relativeInside(root, path.resolve(base, String(target)));
  if (rel === null) return '只能读写工作文件夹里的文件，这个在外面，已拒绝。';
  if (writing && isProtected(rel)) return '这个文件管着 AI 自己的权限和指令，不能改，已拒绝。';
  return '';
}

/** Codex 改文件用的补丁里写到的所有路径 */
export function patchPaths(patch) {
  const re = /^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/gm;
  return [...String(patch || '').matchAll(re)].map((m) => m[1].trim());
}

/** 要问手机时卡片上写的那句话 */
export function describe(tool, input) {
  switch (tool) {
    case 'Bash': return `运行命令：${String(input.command || '')}`;
    case 'WebFetch': return `打开网页：${String(input.url || '')}`;
    default: return `上网搜索：${String(input.query || '')}`;
  }
}
