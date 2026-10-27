import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

/**
 * 找到可以直接 spawn 的命令（不经过 shell，参数里的换行和引号才安全）。
 * Windows 上 npm 装的命令是 .cmd 包装，这里解析出真正的 .js 入口，用当前 node 运行。
 */
export function resolveCommand(name) {
  if (process.platform !== 'win32') return { file: name, pre: [] };
  if (path.isAbsolute(name) && fs.existsSync(name)) return fromPath(name);

  let lines = [];
  try {
    lines = execFileSync('where', [name], { encoding: 'utf8', windowsHide: true })
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean);
  } catch {
    return null;
  }
  const exe = lines.find((l) => l.toLowerCase().endsWith('.exe'));
  if (exe) return { file: exe, pre: [] };
  const cmd = lines.find((l) => l.toLowerCase().endsWith('.cmd'));
  return cmd ? fromPath(cmd) : null;
}

function fromPath(file) {
  if (!file.toLowerCase().endsWith('.cmd')) return { file, pre: [] };
  const text = fs.readFileSync(file, 'utf8');
  // npm 包装里可能是 .js 入口（用 node 运行），也可能直接是原生 .exe
  const match = text.match(/"%(?:~?dp0)%?\\([^"]+?\.(?:(?:c|m)?js|exe))"/i);
  if (!match) return null;
  const target = path.join(path.dirname(file), match[1]);
  if (target.toLowerCase().endsWith('.exe')) return { file: target, pre: [] };
  return { file: process.execPath, pre: [target] };
}
