// 调试：直接跑一次 CLI，统计原始输出里有哪些事件，看思考过程有没有返回
// 用法：node src/probe.js claude|codex [额外的 codex -c 配置...]
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import { resolveCommand } from './resolve.js';
import { loadConfig, paths } from './config.js';

const config = loadConfig();
const [engine = 'claude', ...extra] = process.argv.slice(2);
const command = resolveCommand(config.commands[engine] || engine);
const prompt = '一个笼子里有鸡和兔共 35 只，脚共 94 只，各有几只？简短回答。';
const args = engine === 'codex'
  ? ['exec', '--json', '--skip-git-repo-check', '--sandbox', 'read-only', '-c', 'model_reasoning_effort="high"',
     ...extra.flatMap((e) => ['-c', e]), '-']
  : ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--max-turns', '1',
     '--effort', 'high', ...extra];

const child = spawn(command.file, [...command.pre, ...args], { cwd: paths.workspace, windowsHide: true });
const counts = {};
const samples = {};
readline.createInterface({ input: child.stdout }).on('line', (line) => {
  if (!line.trim().startsWith('{')) return;
  const obj = JSON.parse(line);
  let key = obj.type;
  if (obj.type === 'stream_event') key += ':' + obj.event?.type + ':' + (obj.event?.delta?.type || obj.event?.content_block?.type || '');
  if (obj.item) key += ':' + (obj.item.type || obj.item.item_type);
  counts[key] = (counts[key] || 0) + 1;
  if (!samples[key]) samples[key] = line.slice(0, 300);
});
child.stdin.end(prompt, 'utf8');
child.on('close', () => {
  for (const [k, n] of Object.entries(counts)) console.log(`${n}\t${k}\n\t${samples[k]}`);
});
