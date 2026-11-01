// 开机自动启动：在「启动」文件夹里放一个最小化启动中继的快捷方式。
// 建快捷方式用 scripts/make-shortcut.ps1，和桌面快捷方式同一份写法（审查 Z-500）
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const script = path.join(repoDir, 'scripts', 'make-shortcut.ps1');
const startupLink = path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', '絮语中继.lnk');

export function autostartEnabled() {
  return fs.existsSync(startupLink);
}

/** 打开或关掉开机自动启动；做完（不论成没成）才返回，手机随后收到最新状态 */
export function setAutostart(on) {
  return new Promise((resolve) => {
    if (!on) {
      fs.rm(startupLink, { force: true }, () => resolve());
      return;
    }
    execFile('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-Link', startupLink, '-Minimized'],
      { windowsHide: true }, () => resolve());
  });
}
