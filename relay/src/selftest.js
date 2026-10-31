// 本机自检：先核对和 App 共用的算法，再不经过手机，直接让中继各问一句，确认 Claude Code / Codex 能用
// 用法：node src/selftest.js [claude|codex] [推理强度，例如 low]
import { resolveCommand } from './resolve.js';
import { runEngine } from './engines.js';
import { loadConfig, paths } from './config.js';
import { proof, sameProof } from './pairing.js';

// ---- 对暗号：和 App 的 Tests/RelayPairingTests.swift 用同一组数，两边算出来必须一样 ----
const PAIR_SAMPLE = {
  code: 'abcd2345 ', nonce: '00'.repeat(16), cnonce: '11'.repeat(16),
  app: '99aa92a17df70e1b31f2051f2d0aae379bd891c939b2a0a1f577f55d1ba464e0',
  relay: 'c35829f110732cd591d915b90bef7108703b837932bb9e7c4c9e40ed302c6942',
};
const sample = PAIR_SAMPLE;
const pairOK = sameProof(proof(sample.code, 'app', sample.nonce, sample.cnonce), sample.app)
  && sameProof(proof(sample.code, 'relay', sample.nonce, sample.cnonce), sample.relay);
console.log(`对暗号: ${pairOK ? '✓' : '✗ 和 App 算的不一样'}`);
if (!pairOK) process.exitCode = 1;

const config = loadConfig();
const args = process.argv.slice(2);
const effort = args.find((a) => /^(low|medium|high|xhigh|max|ultra)$/.test(a)) || '';
const engines = args.filter((a) => a === 'claude' || a === 'codex');

for (const engine of engines.length ? engines : ['claude', 'codex']) {
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
      effort,
      system: '你是一个简短的助手。',
      prompt: '只回复两个字：你好',
      files: [],
      images: [],
      cwd: paths.workspace,
      onEvent: (e) => (e.type === 'text' ? (text += e.text) : (reasoning += e.text.length)),
    });
    console.log(`${engine}${effort ? ' · ' + effort : ''}: ✓ ${JSON.stringify(text.trim())}（${((Date.now() - started) / 1000).toFixed(1)}s，思考 ${reasoning} 字）`);
  } catch (e) {
    console.log(`${engine}: ✗ ${e.message}`);
  }
}
