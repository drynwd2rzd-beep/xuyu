import { spawn } from 'node:child_process';
import path from 'node:path';
import readline from 'node:readline';


/**
 * 运行一次 CLI，把输出转换成统一事件：
 *   onEvent({ type: 'text' | 'reasoning' | 'step', text })
 * work = true 时是「工作模式」：可以在 cwd（工作文件夹）里读写文件、运行命令，每一步都会以 step 事件报告。
 * 返回 Promise，完成时 resolve，出错时 reject(Error)。
 */
export function runEngine({ engine, command, model, effort = '', system, prompt, files, images, cwd, signal, onEvent, work = false }) {
  const spec = engine === 'codex'
    ? codexArgs({ model, effort, images, work })
    : claudeArgs({ model, effort, system, allowRead: files.length > 0, work });
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
    const minutes = work ? 30 : 10;
    const timer = setTimeout(() => {
      child.kill();
      finish(new Error(`等待超时（${minutes} 分钟）`));
    }, minutes * 60 * 1000);

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
        // 回复已经完整了就立刻告诉手机，不用等 CLI 收尾退出（那要好几秒）
        if (parse.complete && parse.gotText) {
          parse.flush?.();
          finish();
        }
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

// 工作模式下 Claude 能用的工具，以及明确不许运行的危险命令
const WORK_TOOLS = ['Read', 'Write', 'Edit', 'MultiEdit', 'Glob', 'Grep', 'Bash', 'TodoWrite', 'WebSearch', 'WebFetch'];
const WORK_DENY = ['Bash(rm -rf:*)', 'Bash(rmdir:*)', 'Bash(del /s:*)', 'Bash(format:*)', 'Bash(shutdown:*)',
  'Bash(Remove-Item -Recurse:*)', 'Bash(reg:*)', 'Bash(diskpart:*)'];

function claudeArgs({ model, effort, system, allowRead, work }) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
    '--max-turns', work ? '60' : allowRead ? '6' : '1'];
  if (model) args.push('--model', model);
  if (effort) args.push('--effort', effort);
  if (system) args.push('--system-prompt', system);
  if (work) {
    // 工作模式：在工作文件夹里改文件不用再确认；只开放下面这些工具
    args.push('--strict-mcp-config', '--permission-mode', 'acceptEdits',
      '--tools', WORK_TOOLS.join(','), '--allowedTools', ...WORK_TOOLS, '--disallowedTools', ...WORK_DENY);
  } else {
    // 聊天不带任何工具和 MCP：否则每条消息都会附上几万字的工具说明，又慢又耗额度。
    // 有附件时只开 Read，让它看图片/文件。提示词从 stdin 读取
    args.push('--strict-mcp-config', '--tools', allowRead ? 'Read' : '');
  }
  return args;
}

/** 把 Claude 的一次工具调用写成一句人能看懂的步骤 */
function describeClaudeTool(name, input = {}) {
  const file = (p) => path.basename(String(p || ''));
  const cut = (s, n = 90) => (String(s || '').length > n ? String(s).slice(0, n) + '…' : String(s || ''));
  switch (name) {
    case 'Read': return `读取 ${file(input.file_path)}`;
    case 'Write': return `写入 ${file(input.file_path)}`;
    case 'Edit':
    case 'MultiEdit': return `修改 ${file(input.file_path)}`;
    case 'Bash': return `运行 ${cut(input.command)}`;
    case 'Glob': return `查找文件 ${cut(input.pattern, 50)}`;
    case 'Grep': return `搜索内容「${cut(input.pattern, 40)}」`;
    case 'WebSearch': return `搜索网页「${cut(input.query, 50)}」`;
    case 'WebFetch': return `打开网页 ${cut(input.url, 60)}`;
    case 'TodoWrite': return '整理接下来要做的步骤';
    default: return `使用 ${name}`;
  }
}

function claudeParser(onEvent) {
  const state = { gotText: false, sawDelta: false, error: null };
  state.line = (obj) => {
    if (obj.type === 'stream_event') {
      const ev = obj.event || {};
      if (ev.type === 'content_block_delta') {
        const d = ev.delta || {};
        if (d.type === 'text_delta' && d.text) {
          // 用过工具之后又开始说话：和前面的话空一行隔开
          if (state.needBreak && state.gotText) onEvent({ type: 'text', text: '\n\n' });
          state.needBreak = false;
          state.sawDelta = true;
          state.gotText = true;
          onEvent({ type: 'text', text: d.text });
        } else if (d.type === 'thinking_delta' && d.thinking) {
          onEvent({ type: 'reasoning', text: d.thinking });
        }
      }
    } else if (obj.type === 'assistant') {
      for (const block of obj.message?.content || []) {
        if (block.type === 'tool_use') {
          // 工作模式：每用一次工具就报告一步
          onEvent({ type: 'step', text: describeClaudeTool(block.name, block.input) });
          state.needBreak = true;
        } else if (state.sawDelta) {
          continue;
        } else if (block.type === 'text' && block.text) {
          // 不支持流式片段的旧版本：用整条消息
          state.gotText = true;
          onEvent({ type: 'text', text: block.text });
        } else if (block.type === 'thinking' && block.thinking) {
          onEvent({ type: 'reasoning', text: block.thinking });
        }
      }
    } else if (obj.type === 'user') {
      // 工具执行失败时在步骤里标一下
      for (const block of obj.message?.content || []) {
        if (block.type === 'tool_result' && block.is_error) onEvent({ type: 'step', text: '↳ 这一步没成功，换个办法' });
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
      state.complete = true;
    }
  };
  return state;
}

function codexArgs({ model, effort, images, work }) {
  // 工作模式：只能写工作文件夹（Codex 自带的沙盒限制），聊天时只读
  const args = ['exec', '--json', '--skip-git-repo-check', '--sandbox', work ? 'workspace-write' : 'read-only'];
  if (model) args.push('-m', model);
  if (effort) args.push('-c', `model_reasoning_effort="${effort}"`);
  for (const img of images) args.push('-i', img);
  args.push('-');
  return args;
}

/** 把 Codex 的一个动作写成一句人能看懂的步骤 */
function describeCodexItem(item) {
  const cut = (s, n = 90) => (String(s || '').length > n ? String(s).slice(0, n) + '…' : String(s || ''));
  switch (item.type) {
    case 'command_execution': {
      const cmd = String(item.command || '').replace(/^.*?-Command\s+/i, '').replace(/^["']|["']$/g, '');
      return `运行 ${cut(cmd)}${item.exit_code && item.exit_code !== 0 ? ' · 没成功' : ''}`;
    }
    case 'file_change':
      return (item.changes || []).map((c) => `${c.kind === 'add' ? '新建' : c.kind === 'delete' ? '删除' : '修改'} ${path.basename(String(c.path || ''))}`).join('\n') || '修改文件';
    case 'web_search': return `搜索网页「${cut(item.query, 50)}」`;
    case 'todo_list': return '整理接下来要做的步骤';
    case 'mcp_tool_call': return `使用 ${item.tool || '工具'}`;
    default: return '';
  }
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
      } else if (obj.type === 'item.completed') {
        const step = describeCodexItem(item);
        for (const line of step.split('\n').filter(Boolean)) onEvent({ type: 'step', text: line });
      }
    } else if (obj.type === 'turn.completed') {
      state.complete = true;
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
      } else if (m.type === 'task_complete') {
        state.complete = true;
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
  if (/hit your .*limit|session limit|weekly limit|rate limit|usage limit|429|quota/i.test(t)) {
    const reset = t.match(/resets?\s+(?:at\s+)?([^\n(·]+?)\s*(?:\(|$)/i)?.[1]?.trim();
    return reset ? `这段时间的订阅用量到上限了，${reset} 后恢复。可以先换另一个模型聊。` : '订阅用量暂时到上限了，请稍后再试，或先换另一个模型聊。';
  }
  if (/model/i.test(t) && /not found|invalid|unknown|not available|not supported/i.test(t)) {
    return '这个模型现在用不了，请在设置里换一个。';
  }
  return t.split('\n').filter(Boolean).slice(-2).join(' ').slice(0, 300);
}
