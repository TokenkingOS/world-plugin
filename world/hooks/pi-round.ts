import { realpathSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createBashTool } from "@earendil-works/pi-coding-agent";
import { refusal, sandboxed, TOOL, withoutProxy } from "./pi-round-rules.mjs";

// 只由 auto-extract.sh 的 pi 后台轮用 -e 加载，--tools 只列 TOOL，内置 bash 不注册。pi 没有内置沙箱，这一轮的隔离就是这里的两道关：
// tool_call 只放行通道的单行 curl，TOOL 的每条命令再去掉代理变量、包进 sandbox-exec。缺通道地址或目录时工厂抛错：pi 加载扩展失败就退出。
export default function (pi: ExtensionAPI) {
  const base = process.env.WORLD_ROUND_BASE_URL ?? "";
  const capture = process.env.WORLD_ROUND_CAPTURE_DIR;
  const work = process.env.WORLD_ROUND_WORK_DIR;
  if (!base || !capture || !work) throw new Error("WORLD_ROUND_* 不全，不是后台整理轮");
  const paths = { home: realpathSync(homedir()), capture: realpathSync(capture), work: realpathSync(work) };

  const bash = createBashTool(paths.work, {
    spawnHook: ({ command, cwd, env }) => ({ command: sandboxed(command, { ...paths, base }), cwd, env: withoutProxy(env) }),
  });
  const description = `只运行一条访问 ${base}（本机 World Capture 通道）的单行 curl 命令，返回 stdout 和 stderr；别的命令一律被拦下。`;
  pi.registerTool({ ...bash, name: TOOL, label: TOOL, description, promptSnippet: description, promptGuidelines: undefined,
    execute: (id, params, signal, onUpdate) => bash.execute(id, params, signal, onUpdate) });

  // 不接异常：handler 抛错时 pi 拦下这次调用。
  pi.on("tool_call", event => {
    const reason = refusal(event.toolName, event.input, base);
    return reason ? { block: true, reason } : undefined;
  });

  const total = { input: 0, cacheRead: 0, cacheWrite: 0, output: 0 };
  let counted = false;
  pi.on("message_end", event => {
    const usage = event.message.role === "assistant" ? event.message.usage : undefined;
    if (!usage) return;
    for (const key of Object.keys(total) as (keyof typeof total)[]) total[key] += usage[key] ?? 0;
    counted = true;
  });
  pi.on("session_shutdown", () => {
    if (!counted) return;
    writeFileSync(join(paths.work, "usage.json"), JSON.stringify({ input_tokens: total.input + total.cacheRead + total.cacheWrite,
      cached_input_tokens: total.cacheRead, output_tokens: total.output }));
  });
}
