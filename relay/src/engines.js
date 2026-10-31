import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';


/**
 * 运行一次 CLI，把输出转换成统一事件：
 *   onEvent({ type: 'text' | 'reasoning' | 'step', text })
 * work = true 时是「工作模式」：可以在 cwd（工作文件夹）里读写文件、运行命令，每一步都会以 step 事件报告。
 * 工作模式两家都要过把关钩子（gate.js）；gate.calls() 是这次回复里把关被问过几次，用来发现「工具没经过把关就执行了」。
 * 返回 Promise，完成时 resolve，出错时 reject(Error)。
 */
export function runEngine({ engine, command, model, effort = '', system, prompt, files, images, cwd, signal, onEvent, work = false, gate = null, readDirs = [] }) {
  // 工作模式没有把关就不干（审查 Z-002、规范 RELAY-10）
  if (work && !gate) return Promise.reject(new EngineError('工作模式缺少把关，已停止。'));
  if (work && engine === 'codex') {
    const problem = prepareCodexHooks(cwd);
    if (problem) return Promise.reject(new EngineError(problem));
  }
  const spec = engine === 'codex'
    ? codexArgs({ model, effort, images, work })
    : claudeArgs({ model, effort, system, allowRead: files.length > 0, work, readDirs });
  const input = engine === 'codex' && system ? `${system}\n\n---\n\n${prompt}` : prompt;
  const parse = engine === 'codex' ? codexParser(onEvent) : claudeParser(onEvent);
  // 把关钩子要知道这是哪家、哪一次回复、工作文件夹在哪、怎么找到中继
  const gateEnv = work
    ? { XUYU_ENGINE: engine, XUYU_GATE_URL: gate.url, XUYU_GATE_KEY: gate.key, XUYU_JOB: gate.job, XUYU_ROOT: cwd }
    : {};

  return new Promise((resolve, reject) => {
    const child = spawn(command.file, [...command.pre, ...spec], {
      cwd,
      env: { ...process.env, NO_COLOR: '1', ...gateEnv },
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
        // 执行过的工具比把关被问过的次数还多：钩子没起作用，马上停下，不能让 AI 不经把关继续干
        if (work && parse.toolRuns > gate.calls()) {
          child.kill();
          finish(new EngineError('把关没有生效，为了安全已经停下。请重启电脑上的中继再试。'));
          return;
        }
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

// 工作模式下 Claude 能用的工具
const WORK_TOOLS = ['Read', 'Write', 'Edit', 'MultiEdit', 'Glob', 'Grep', 'Bash', 'TodoWrite', 'WebSearch', 'WebFetch'];
// 明显手滑的危险命令：只按开头匹配，换个写法（cmd /c、powershell -c、rm -r -f）就挡不住，
// 所以它只是顺手的提醒，不是安全边界。真正的把关是 gate.js：每条命令都要你在手机上点允许（审查 Z-480）
const WORK_DENY = ['Bash(rm -rf:*)', 'Bash(rmdir:*)', 'Bash(del /s:*)', 'Bash(format:*)', 'Bash(shutdown:*)',
  'Bash(Remove-Item -Recurse:*)', 'Bash(reg:*)', 'Bash(diskpart:*)', 'Bash(Stop-Computer:*)', 'Bash(Restart-Computer:*)',
  'Bash(Set-ExecutionPolicy:*)', 'Bash(net user:*)', 'Bash(schtasks:*)', 'Bash(sc :*)', 'Bash(bcdedit:*)', 'Bash(takeown:*)',
  'Bash(icacls:*)', 'Bash(cipher:*)', 'Bash(vssadmin:*)', 'Bash(wmic:*)'];

// 把关钩子：等手机确认最多 10 分钟（钩子默认只等 60 秒）。
// 用正在运行中继的这个 node 的完整路径：不靠 PATH 里找 node，找不到时钩子起不来（审查 Z-217）
const GATE_SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'gate.js').replace(/\\/g, '/');
const GATE_COMMAND = `"${process.execPath.replace(/\\/g, '/')}" "${GATE_SCRIPT}"`;
const gateHooks = (matcher) => ({
  hooks: { PreToolUse: [{ matcher, hooks: [{ type: 'command', command: GATE_COMMAND, timeout: 600 }] }] },
});
const GATE_SETTINGS = JSON.stringify(gateHooks('*'));

/**
 * Codex 只从工作文件夹的 .codex/hooks.json 读钩子：每次工作前由中继写好。
 * 那个文件夹里有别的设置（可能是 AI 或别人放的，会改 Codex 的行为）就先不动手，返回给你看的理由
 */
function prepareCodexHooks(cwd) {
  const dir = path.join(cwd, '.codex');
  try {
    fs.mkdirSync(dir, { recursive: true });
    const others = fs.readdirSync(dir).filter((name) => name.toLowerCase() !== 'hooks.json');
    if (others.length) return `工作文件夹的 .codex 里有别的设置（${others.join('、')}），为了安全先不动手。请在电脑上看一下，确认没用就删掉。`;
    // Codex 的匹配写法是正则：「.*」才是所有工具
    fs.writeFileSync(path.join(dir, 'hooks.json'), JSON.stringify(gateHooks('.*'), null, 2));
    return '';
  } catch (e) {
    return `没能准备好把关：${e.message}`;
  }
}

function claudeArgs({ model, effort, system, allowRead, work, readDirs = [] }) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
    '--max-turns', work ? '60' : allowRead ? '6' : '1'];
  if (model) args.push('--model', model);
  if (effort) args.push('--effort', effort);
  if (system) args.push('--system-prompt', system);
  if (work) {
    // 工作模式：只开放下面这些工具；每次用之前都先过把关钩子（gate.js）：
    // 工作文件夹外的读写直接拒绝，运行命令和上网先在手机上确认。
    // 不预先允许任何工具：只有把关明确放行才做，钩子出了错就停在「要你允许」上，后台没人点就不做（实测）。
    // 只读你自己的用户设置：工作文件夹里的 .claude 设置不生效，AI 写了也没用（审查 Z-005、Z-217）
    args.push('--strict-mcp-config', '--setting-sources', 'user',
      '--tools', WORK_TOOLS.join(','), '--disallowedTools', ...WORK_DENY, '--settings', GATE_SETTINGS);
  } else {
    // 聊天不带任何工具和 MCP：否则每条消息都会附上几万字的工具说明，又慢又耗额度。
    // 有附件时只开 Read，让它看图片/文件。提示词从 stdin 读取
    args.push('--strict-mcp-config', '--tools', allowRead ? 'Read' : '');
    // 你发来的图片、表情、文件存在 uploads，不在 Claude 的工作文件夹里：把它加成工作文件夹，就能直接读。
    // 不另加不带路径的 Read 允许规则：那会让它能读电脑上任何文件（实测：只加文件夹，外面的读不到）（审查 Z-216）
    if (allowRead) {
      for (const dir of readDirs) args.push('--add-dir', dir);
    }
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
  // toolRuns：真正执行成功的工具次数（被拒绝的不算），用来核对把关有没有被问过
  const state = { gotText: false, sawDelta: false, error: null, toolRuns: 0 };
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
        if (block.type !== 'tool_result') continue;
        if (block.is_error) onEvent({ type: 'step', text: '↳ 这一步没成功，换个办法' });
        else state.toolRuns += 1;
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
  if (work) {
    // 每次用工具前过把关钩子（.codex/hooks.json，见 prepareCodexHooks）：
    // 钩子默认要你在电脑上「信任」过才会运行，不然会被悄悄跳过（实测）；这个钩子是中继自己写的，所以这次运行直接信任它。
    // 不读你个人的 Codex 设置：里面装的插件（操作电脑界面、浏览器）不经过把关（审查 Z-002）
    args.push('--dangerously-bypass-hook-trust', '--ignore-user-config');
  }
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
  // toolRuns：开始执行的命令、改文件、外部工具次数（被把关拒绝的根本不会开始），用来核对把关有没有被问过
  const state = { gotText: false, error: null, toolRuns: 0 };
  state.line = (obj) => {
    if (obj.type === 'item.started' && ['command_execution', 'file_change', 'mcp_tool_call'].includes(obj.item?.type)) {
      state.toolRuns += 1;
    }
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
