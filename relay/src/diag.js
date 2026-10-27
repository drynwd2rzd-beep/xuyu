// 诊断：看看中继能不能找到 Claude Code 和 Codex
import { execFile } from 'node:child_process';
import { resolveCommand } from './resolve.js';

for (const name of ['claude', 'codex']) {
  const cmd = resolveCommand(name);
  console.log(name, '→', cmd ? `${cmd.file} ${cmd.pre.join(' ')}` : '找不到');
  if (!cmd) continue;
  await new Promise((done) => {
    execFile(cmd.file, [...cmd.pre, '--version'], { timeout: 20000, windowsHide: true }, (err, stdout, stderr) => {
      console.log('   ', err ? `出错：${err.message.split('\n')[0]} ${stderr}` : stdout.trim());
      done();
    });
  });
}
