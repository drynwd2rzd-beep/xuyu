import { spawn } from 'node:child_process';
import readline from 'node:readline';


/**
 * 运行一次 CLI，把输出转换成统一事件：
 *   onEvent({ type: 'text' | 'reasoning', text })
 * 返回 Promise，完成时 resolve，出错时 reject(Error)。
 */
export function runEngine({ engine, command, model, effort = '', system, prompt, files, images, cwd, signal, onEvent }) {
  const spec = engine === 'codex'
    ? codexArgs({ model, effort, images })
    : claudeArgs({ model, effort, system, allowRead: files.length > 0 });
  const input = engine === 'codex' && system ? `${system}\n\n---\n\n${prompt}` : prompt;
  const parse = engine === 'codex' ? codexParser(onEvent) : claudeParser(onEvent);

  return new Promise((resolve, reject) => {
    const child = spawn(command.file, [...command.pre, ...spec], {
      cwd,
      env: { ...process.env, NO_COLOR: '1' },
      windowsHide: true,
    });
    let stderr = '';
    let settled = false;
    const finish = (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      err ? reject(err) : resolve();
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(new Error('等待超时（10 分钟）'));
    }, 10 * 60 * 1000);

    signal?.addEventListener('abort', () => {
      child.kill();
      finish(new Error('已取消'));
    });

    child.on('error', (e) => finish(new Error(`无法启动 ${engine}：${e.message}`)));
    child.stderr.on('data', (d) => {
      stderr = (stderr + d.toString()).slice(-4000);
    });
    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      line = line.trim();
      if (!line.startsWith('{')) return;
      try {
        parse.line(JSON.parse(line));
      } catch (e) {
        if (e instanceof EngineError) {
          child.kill();
          finish(e);
        }
      }
    });
    child.on('close', (code) => {
      if (parse.error) return finish(new EngineError(parse.error));
      if (!parse.gotText && code !== 0) {
        return finish(new EngineError(explain(stderr) || `${engine} 退出（代码 ${code}）`));
      }
      parse.flush?.();
      finish();
    });

    child.stdin.on('error', () => {});
    child.stdin.end(input, 'utf8');
  });
}

class EngineError extends Error {}

function claudeArgs({ model, effort, system, allowRead }) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
    '--max-turns', allowRead ? '6' : '1'];
  if (model) args.push('--model', model);
  if (effort) args.push('--effort', effort);
  if (system) args.push('--system-prompt', system);
  // 聊天不带任何工具和 MCP：否则每条消息都会附上几万字的工具说明，又慢又耗额度。
  // 有附件时只开 Read，让它看图片/文件。提示词从 stdin 读取
  args.push('--strict-mcp-config', '--tools', allowRead ? 'Read' : '');
  return args;
}

function claudeParser(onEvent) {
  const state = { gotText: false, sawDelta: false, error: null };
  state.line = (obj) => {
    if (obj.type === 'stream_event') {
      const ev = obj.event || {};
      if (ev.type === 'content_block_delta') {
        const d = ev.delta || {};
        if (d.type === 'text_delta' && d.text) {
          state.sawDelta = true;
          state.gotText = true;
          onEvent({ type: 'text', text: d.text });
        } else if (d.type === 'thinking_delta' && d.thinking) {
          onEvent({ type: 'reasoning', text: d.thinking });
        }
      }
    } else if (obj.type === 'assistant' && !state.sawDelta) {
      // 不支持流式片段的旧版本：用整条消息
      for (const block of obj.message?.content || []) {
        if (block.type === 'text' && block.text) {
          state.gotText = true;
          onEvent({ type: 'text', text: block.text });
        } else if (block.type === 'thinking' && block.thinking) {
          onEvent({ type: 'reasoning', text: block.thinking });
        }
      }
    } else if (obj.type === 'result') {
      if (obj.is_error || (obj.subtype && obj.subtype !== 'success')) {
        state.error = explain(String(obj.result || obj.subtype || '出错了'));
        throw new EngineError(state.error);
      }
      if (!state.gotText && obj.result) {
        state.gotText = true;
        onEvent({ type: 'text', text: String(obj.result) });
      }
    }
  };
  return state;
}

function codexArgs({ model, effort, images }) {
  const args = ['exec', '--json', '--skip-git-repo-check', '--sandbox', 'read-only'];
  if (model) args.push('-m', model);
  if (effort) args.push('-c', `model_reasoning_effort="${effort}"`);
  for (const img of images) args.push('-i', img);
  args.push('-');
  return args;
}

function codexParser(onEvent) {
  const state = { gotText: false, error: null };
  state.line = (obj) => {
    // 新版事件：item.completed / turn.failed / error
    if (obj.type === 'item.completed' || obj.type === 'item.updated') {
      const item = obj.item || {};
      const kind = item.type || item.item_type || '';
      if (obj.type === 'item.completed' && /reasoning/.test(kind) && item.text) {
        onEvent({ type: 'reasoning', text: item.text + '\n' });
      } else if (obj.type === 'item.completed' && /(agent|assistant)_message/.test(kind) && item.text) {
        onEvent({ type: 'text', text: (state.gotText ? '\n\n' : '') + item.text });
        state.gotText = true;
      }
    } else if (obj.type === 'turn.failed' || obj.type === 'error') {
      state.error = explain(obj.error?.message || obj.message || '出错了');
      throw new EngineError(state.error);
    } else if (obj.msg) {
      // 旧版事件格式
      const m = obj.msg;
      if (m.type === 'agent_message' && m.message) {
        onEvent({ type: 'text', text: (state.gotText ? '\n\n' : '') + m.message });
        state.gotText = true;
      } else if (m.type === 'agent_reasoning' && m.text) {
        onEvent({ type: 'reasoning', text: m.text + '\n' });
      } else if (m.type === 'error') {
        state.error = explain(m.message || '出错了');
        throw new EngineError(state.error);
      }
    }
  };
  return state;
}

/** 把常见的英文报错翻译成人能看懂的话 */
export function explain(text) {
  const t = String(text || '').trim();
  if (!t) return '';
  if (/login|log in|\/login|not authenticated|unauthorized|invalid api key|401/i.test(t)) {
    return '这个账号还没有登录。请在电脑上运行一次 claude 或 codex 完成登录。';
  }
  if (/rate limit|usage limit|429|quota/i.test(t)) return '订阅额度暂时用完了，请稍后再试。';
  if (/model/i.test(t) && /not found|invalid|unknown|not available|not supported/i.test(t)) {
    return '这个模型现在用不了，请在设置里换一个。';
  }
  return t.split('\n').filter(Boolean).slice(-2).join(' ').slice(0, 300);
}
