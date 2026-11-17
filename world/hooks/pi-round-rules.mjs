// pi 后台整理轮的两道关：pi-round.ts 在 tool_call 里用 refusal 拦命令，在 TOOL 的 spawnHook 里用 sandboxed 包命令、withoutProxy 去代理变量。
// 拆成不依赖 pi 的模块，测试才能直接跑。

// 整理轮唯一的工具。不叫 bash：同名靠 pi「扩展覆盖内置」才带上关卡和沙箱，换个合并顺序就成了不设防的内置 bash。
export const TOOL = 'world_channel_curl';

const DATA_FLAGS = new Set(['-d', '--data', '--data-binary', '--data-raw', '--data-ascii', '--data-urlencode', '--json']);
const DENY_READ = ['/private/tmp', '/private/var/tmp', '/private/var/folders', '/Users/Shared', '/Volumes'];
const PROXY_VARIABLES = new Set(['http_proxy', 'https_proxy', 'all_proxy', 'no_proxy']);

function channelPort(base) {
  const match = /^http:\/\/127\.0\.0\.1:(\d+)$/.exec(base);
  if (!match) throw new Error('后台整理轮没有拿到通道地址');
  return match[1];
}

// 按 shell 规则拆词，只认单引号、双引号和反斜杠；遇到会让 shell 多做一件事的写法（分号、管道、重定向、变量、命令替换、花括号展开）就返回 null。
function words(command) {
  const out = [];
  let word = null;
  let quote = null;
  for (let index = 0; index < command.length; index += 1) {
    const c = command[index];
    if (quote === "'") {
      if (c === "'") quote = null; else word += c;
    } else if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === '$' || c === '`') return null;
      else if (c === '\\' && index + 1 < command.length) word += command[++index];
      else word += c;
    } else if (c === ' ' || c === '\t') {
      if (word !== null) out.push(word);
      word = null;
    } else if (';&|<>()`${}'.includes(c)) {
      return null;
    } else {
      word ??= '';
      if (c === "'" || c === '"') quote = c;
      else if (c === '\\') { if (index + 1 >= command.length) return null; word += command[++index]; }
      else word += c;
    }
  }
  if (quote) return null;
  if (word !== null) out.push(word);
  return out;
}

// 只放行 TOOL 里的单行 curl：除了交回的数据（--data-binary 等的值，里面是原文摘出的文字，可能带任何网址），
// 每个词里出现的网址都必须在通道之下，且至少有一个。返回拒绝理由，放行返回 null。
export function refusal(tool, input, base) {
  channelPort(base);
  const reason = `后台整理轮只放行 ${TOOL} 里的单行 curl 命令，只访问 ${base} 下的地址；不用管道、重定向、分号、变量、命令替换和花括号，`
    + `交回的 JSON 直接放进 --data-binary '…' 的单引号里。`;
  if (tool !== TOOL || typeof input?.command !== 'string') return reason;
  const { command } = input;
  if (/[\r\n]/.test(command) || !command.startsWith('curl ')) return reason;
  const parts = words(command);
  if (!parts) return reason;
  let urls = 0;
  for (let index = 1; index < parts.length; index += 1) {
    if (DATA_FLAGS.has(parts[index - 1])) continue;
    for (const match of parts[index].matchAll(/[A-Za-z][A-Za-z0-9+.-]*:\/\//g)) {
      const url = parts[index].slice(match.index);
      if (url !== base && !url.startsWith(`${base}/`) && !url.startsWith(`${base}?`)) return reason;
      urls += 1;
    }
  }
  return urls ? null : reason;
}

const literal = path => `"${path.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
const shell = text => `'${text.replaceAll("'", "'\\''")}'`;

// 网络只出通道那一个回环端口（本机代理也在回环上，放行整个回环就能经它出外网）；拒读主目录、各临时目录、共享目录和外接卷，再放行组件目录和本轮目录（后写的规则优先）；只能写本轮目录和 /dev。
// 路径都要是真实路径：sandbox-exec 按解析后的路径比对，/tmp、/var 这类链接写进去不生效。
export function sandboxed(command, { home, capture, work, base }) {
  const profile = ['(version 1)', '(allow default)',
    '(deny network-outbound)', `(allow network-outbound (remote ip "localhost:${channelPort(base)}"))`,
    `(deny file-read* ${[home, ...DENY_READ].map(path => `(subpath ${literal(path)})`).join(' ')})`,
    `(allow file-read* (subpath ${literal(capture)}) (subpath ${literal(work)}))`,
    '(deny file-write*)', `(allow file-write* (subpath ${literal(work)}) (subpath "/dev"))`].join('\n');
  return `exec /usr/bin/sandbox-exec -p ${shell(profile)} /bin/bash -c ${shell(command)}`;
}

// pi 按本人配置的 httpProxy 给自己设 HTTP(S)_PROXY，子进程会继承；命令不该经代理出去，大小写都去掉。
export function withoutProxy(env) {
  return Object.fromEntries(Object.entries(env).filter(([name]) => !PROXY_VARIABLES.has(name.toLowerCase())));
}
