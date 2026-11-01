// 中继状态：CLI 有没有装、版本、能选哪些模型。手机连上和打开设置时来问
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { PROTOCOL, CLAUDE_EFFORTS } from './protocol.js';
import { autostartEnabled } from './autostart.js';

// ---- 版本 ----
function version(cmd) {
  if (!cmd) return Promise.resolve({ installed: false, version: '' });
  return new Promise((resolve) => {
    execFile(cmd.file, [...cmd.pre, '--version'], { timeout: 15000, windowsHide: true }, (err, stdout) => {
      if (err) return resolve({ installed: false, version: '' });
      resolve({ installed: true, version: String(stdout).trim().split('\n')[0].slice(0, 60) });
    });
  });
}

// ---- 模型目录：Claude 用配置里的列表，Codex 读它自己缓存的官方列表 ----
const CLAUDE_NAMES = {
  'claude-fable-5-1': ['Fable 5.1', '最强，适合最难的问题'],
  'claude-opus-5-5': ['Opus 5.5', '聪明又稳定'],
  'claude-sonnet-5-5': ['Sonnet 5.5', '更快，适合日常聊天'],
  'claude-haiku-5-5': ['Haiku 5.5', '最快最省'],
};

function claudeCatalog(config) {
  return config.models.claude.map((id) => ({
    id,
    name: CLAUDE_NAMES[id]?.[0] || id,
    description: CLAUDE_NAMES[id]?.[1] || '',
    efforts: CLAUDE_EFFORTS,
    defaultEffort: '',
  }));
}

// Codex 的模型说明是英文，按系列翻成中文
const CODEX_FAMILY = {
  astra: '最强，适合最难、最复杂的工作',
  sol: '主力模型，写代码和日常都好用',
  terra: '均衡，适合直接明了的工作',
  luna: '又快又省，适合简单的事',
};

function codexDescription(m) {
  const family = Object.keys(CODEX_FAMILY).find((k) => String(m.slug).includes(k));
  if (!family) return m.description || '';
  const en = String(m.description || '').toLowerCase();
  if (en.startsWith('latest')) return `最新 · ${CODEX_FAMILY[family]}`;
  if (/older|previous/.test(en)) return `上一代 · ${CODEX_FAMILY[family]}`;
  return CODEX_FAMILY[family];
}

function codexCatalog(config) {
  try {
    const home = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
    const cache = JSON.parse(fs.readFileSync(path.join(home, 'models_cache.json'), 'utf8'));
    return (cache.models || [])
      .filter((m) => m.visibility === 'list')
      .sort((a, b) => (a.priority ?? 99) - (b.priority ?? 99))
      .map((m) => ({
        id: m.slug,
        name: String(m.display_name || m.slug).replace(/[- ](Sol|Astra|Terra|Luna)$/i, ' $1'),
        description: codexDescription(m),
        efforts: (m.supported_reasoning_levels || []).map((l) => l.effort),
        defaultEffort: m.default_reasoning_level || '',
      }));
  } catch {
    return config.models.codex.map((id) => ({ id, name: id, description: '', efforts: [], defaultEffort: '' }));
  }
}

// ---- 缓存 ----
/**
 * 状态查询器。command(engine) 给出能直接运行的命令（没装时是 null）。
 * 有旧结果就立刻返回，过期了在后台刷新；手机连上时不用等 CLI 查版本（出门线路延迟高，等不起）
 */
export function createStatus(config, command) {
  let cache = { at: 0, value: null };
  let refreshing = null;

  function refresh() {
    if (!refreshing) {
      refreshing = (async () => {
        const [claude, codex] = await Promise.all([version(command('claude')), version(command('codex'))]);
        const catalog = { claude: claudeCatalog(config), codex: codexCatalog(config) };
        const models = { claude: catalog.claude.map((m) => m.id), codex: catalog.codex.map((m) => m.id) };
        const value = { protocol: PROTOCOL, host: os.hostname(), claude, codex, models, catalog };
        cache = { at: Date.now(), value };
        return value;
      })().finally(() => { refreshing = null; });
    }
    return refreshing;
  }

  return async function status() {
    let value = cache.value;
    if (value) {
      if (Date.now() - cache.at > 60_000) refresh().catch(() => {});
    } else {
      value = await refresh();
    }
    return { ...value, autostart: autostartEnabled() };
  };
}
