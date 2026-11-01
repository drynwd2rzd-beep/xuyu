// 防止有人反复猜配对码：同一个地址连续对不上几次暗号，就暂时拒绝它
import { SECURITY } from './protocol.js';

/**
 * 一张「谁猜错了几次」的表。now 可以换成假的时钟，方便测试
 */
export function createLockout({ lockAfter = SECURITY.lockAfter, lockFor = SECURITY.lockFor, now = Date.now } = {}) {
  const failures = new Map();
  return {
    /** 这个地址现在是不是被封着 */
    isLocked(from) {
      return failures.get(from)?.until > now();
    },
    /** 记一次暗号不对；返回 true 表示这一次把它封住了 */
    fail(from) {
      const count = (failures.get(from)?.count || 0) + 1;
      const until = count >= lockAfter ? now() + lockFor : 0;
      failures.set(from, { count: until ? 0 : count, until, at: now() });
      return Boolean(until);
    },
    /** 对上了：清掉它的记录 */
    clear(from) {
      failures.delete(from);
    },
    /** 清掉过期的记录，表不会一直变大 */
    prune() {
      const t = now();
      for (const [from, record] of failures) {
        if (record.until < t && t - record.at > lockFor) failures.delete(from);
      }
    },
    get size() {
      return failures.size;
    },
  };
}
