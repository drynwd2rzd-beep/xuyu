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
  // 写好的回复存 24 小时：App 被关掉后再打开，可以把没收到的回复取回来
  replies: path.join(dir, 'replies'),
};

// 工作模式下 AI 能读写的文件夹（只在这里面动手）：有 D 盘就放 D 盘
const oldWorkDir = path.join(os.homedir(), '絮语工作区');
const defaultWorkDir = fs.existsSync('D:\\') ? 'D:\\絮语工作区' : oldWorkDir;

const defaults = {
  port: 51888,
  workDir: defaultWorkDir,
  // 手机的聊天备份放这里（和工作区分开，AI 碰不到）
  backupDir: fs.existsSync('D:\\') ? 'D:\\絮语备份' : path.join(os.homedir(), '絮语备份'),
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
  for (const d of [paths.dir, paths.workspace, paths.uploads, paths.replies]) fs.mkdirSync(d, { recursive: true });
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
  // 之前默认放在 C 盘用户目录，有 D 盘时改到 D 盘
  if (config.workDir === oldWorkDir) config.workDir = defaultWorkDir;
  for (const d of Object.values(workPaths(config))) fs.mkdirSync(d, { recursive: true });
  fs.mkdirSync(config.backupDir, { recursive: true });
  saveConfig(config);
  return config;
}

/** 工作文件夹和里面的三个子文件夹 */
export function workPaths(config) {
  return {
    root: config.workDir,
    inbox: path.join(config.workDir, '收到的文件'),
    outbox: path.join(config.workDir, '发给手机'),
    sent: path.join(config.workDir, '已发送'),
  };
}

export function saveConfig(config) {
  fs.writeFileSync(paths.config, JSON.stringify(config, null, 2));
}
