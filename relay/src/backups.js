// 手机聊天备份：存在电脑的备份文件夹（默认 D:\絮语备份），只留最近 30 份。
// 大的备份分块传（照片多了以后，整份塞进一条消息会超过 64MB 上限）
import fs from 'node:fs';
import path from 'node:path';
import { BACKUP, KEEP } from './protocol.js';

/** 只认单纯的 .json 文件名，去掉路径和奇怪的字符；不合格返回空 */
export function backupName(name) {
  const safe = path.basename(String(name || '')).replace(/[^\w.\-一-龥]/g, '_');
  return safe.endsWith('.json') ? safe : '';
}

/** 一个备份文件夹的读写。dir 是文件夹，keep 是最多留几份 */
export function createBackups(dir, { keep = BACKUP.keep } = {}) {
  // 每份正在分块上传的备份，下一块应该是第几块
  const chunkProgress = new Map();

  function list() {
    try {
      return fs.readdirSync(dir)
        .filter((n) => n.endsWith('.json'))
        .map((name) => {
          const st = fs.statSync(path.join(dir, name));
          return { name, size: st.size, at: st.mtimeMs };
        })
        .sort((a, b) => b.at - a.at);
    } catch {
      return [];
    }
  }

  /** 存好一份：只留最近几份，顺手清掉一天前没传完的半截 */
  function saved(safe) {
    for (const old of list().slice(keep)) fs.rmSync(path.join(dir, old.name), { force: true });
    try {
      for (const name of fs.readdirSync(dir).filter((n) => n.endsWith('.part'))) {
        const file = path.join(dir, name);
        if (Date.now() - fs.statSync(file).mtimeMs > KEEP) fs.rmSync(file, { force: true });
      }
    } catch {
      // 清不掉也不影响这次备份
    }
    console.log(`已保存手机备份：${safe}`);
  }

  // ---- 存 ----
  /** 整份存（小的备份）；data 是 base64 */
  function save(name, data) {
    const safe = backupName(name);
    if (!safe || !data) return false;
    try {
      fs.writeFileSync(path.join(dir, safe), Buffer.from(String(data), 'base64'));
      saved(safe);
      return true;
    } catch {
      return false;
    }
  }

  /** 分块存：先写进「名字.part」，第 0 块从头写，之后按顺序接在后面，最后一块到了再改成正式的名字 */
  function saveChunk(name, index, total, data) {
    const safe = backupName(name);
    const i = Number(index);
    const n = Number(total);
    if (!safe || !data || !Number.isInteger(i) || !Number.isInteger(n) || i < 0 || n < 1 || i >= n) return false;
    const part = path.join(dir, `${safe}.part`);
    try {
      const buf = Buffer.from(String(data), 'base64');
      if (i === 0) {
        fs.writeFileSync(part, buf);
      } else {
        // 顺序不对（中间丢了一块、或者重复发）：不接，让手机这次算失败
        if (chunkProgress.get(safe) !== i) return false;
        fs.appendFileSync(part, buf);
      }
      chunkProgress.set(safe, i + 1);
      if (i === n - 1) {
        chunkProgress.delete(safe);
        fs.renameSync(part, path.join(dir, safe));
        saved(safe);
      }
      return true;
    } catch {
      return false;
    }
  }

  // ---- 取 ----
  /** 整份取回，base64；没有就是空 */
  function read(name) {
    const safe = backupName(name);
    try {
      return safe ? fs.readFileSync(path.join(dir, safe)).toString('base64') : '';
    } catch {
      return '';
    }
  }

  /** 取回大的备份：一次读一段（最多 8MB），连同文件总大小一起回给手机 */
  function readChunk(name, offset, length) {
    const safe = backupName(name);
    if (!safe) return { data: '', size: 0 };
    let fd;
    try {
      fd = fs.openSync(path.join(dir, safe), 'r');
      const size = fs.fstatSync(fd).size;
      const start = Math.max(0, Math.floor(Number(offset) || 0));
      const want = Math.min(Math.max(0, Math.floor(Number(length) || 0)), BACKUP.maxChunk, Math.max(0, size - start));
      const buf = Buffer.alloc(want);
      const got = want > 0 ? fs.readSync(fd, buf, 0, want, start) : 0;
      return { data: buf.subarray(0, got).toString('base64'), size };
    } catch {
      return { data: '', size: 0 };
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
  }

  return { list, save, saveChunk, read, readChunk };
}
