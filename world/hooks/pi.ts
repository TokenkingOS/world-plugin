import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// 本人的 pi 对话里只问组件一次、不等它：子进程脱离、不接输出，任何失败都静默。
// 装法是把本文件链接进 ~/.pi/agent/extensions/，所以按真实路径找同目录的 auto-extract.sh。
function ask(event: string) {
  if (process.env.WORLD_AUTO_EXTRACT_ROUND) return;
  try {
    const script = `${dirname(realpathSync(fileURLToPath(import.meta.url)))}/auto-extract.sh`;
    const child = spawn("sh", [script, "pi", event], { detached: true, stdio: "ignore" });
    child.on("error", () => {});
    child.unref();
  } catch {}
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", () => ask("SessionStart"));
  pi.on("agent_settled", () => ask("Stop"));
  pi.on("session_shutdown", () => ask("SessionEnd"));
}
