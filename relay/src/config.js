import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const base = process.env.APPDATA || path.join(os.homedir(), '.config');
const dir = path.join(base, 'xuyu-relay');

export const paths = {
  dir,
  config: path.join(dir, 'config.json'),
  // 让 CLI 在一个空目录里运行，不碰你的其他文件
  workspace: path.join(dir, 'workspace'),
  uploads: path.join(dir, 'uploads'),
};

const defaults = {
  port: 51888,
  token: '',
  models: {
    claude: ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1'],
    codex: [],
  },
  commands: { claude: 'claude', codex: 'codex' },
};

function newToken() {
  // 8 位，去掉容易看错的字符
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.randomBytes(8);
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join('');
}

export function loadConfig() {
  for (const d of [paths.dir, paths.workspace, paths.uploads]) fs.mkdirSync(d, { recursive: true });
  let saved = {};
  try {
    saved = JSON.parse(fs.readFileSync(paths.config, 'utf8'));
  } catch {
    // 第一次运行
  }
  const config = {
    ...defaults,
    ...saved,
    models: { ...defaults.models, ...(saved.models || {}) },
    commands: { ...defaults.commands, ...(saved.commands || {}) },
  };
  if (!config.token) config.token = newToken();
  saveConfig(config);
  return config;
}

export function saveConfig(config) {
  fs.writeFileSync(paths.config, JSON.stringify(config, null, 2));
}
