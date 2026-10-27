// 本机自检：不经过手机，直接让中继各问一句，确认 Claude Code / Codex 能用
import { resolveCommand } from './resolve.js';
import { runEngine } from './engines.js';
import { loadConfig, paths } from './config.js';

const config = loadConfig();
const engines = process.argv.slice(2).length ? process.argv.slice(2) : ['claude', 'codex'];

for (const engine of engines) {
  const command = resolveCommand(config.commands[engine] || engine);
  if (!command) {
    console.log(`${engine}: 未安装`);
    continue;
  }
  let text = '';
  let reasoning = 0;
  const started = Date.now();
  try {
    await runEngine({
      engine,
      command,
      model: '',
      system: '你是一个简短的助手。',
      prompt: '只回复两个字：你好',
      files: [],
      images: [],
      cwd: paths.workspace,
      onEvent: (e) => (e.type === 'text' ? (text += e.text) : (reasoning += e.text.length)),
    });
    console.log(`${engine}: ✓ ${JSON.stringify(text.trim())}（${((Date.now() - started) / 1000).toFixed(1)}s，思考 ${reasoning} 字）`);
  } catch (e) {
    console.log(`${engine}: ✗ ${e.message}`);
  }
}
