#!/bin/sh
# hook 的输出和退出码会进到本人的对话，所以这里不输出，任何失败都静默 exit 0。
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

finish() {
  curl -sS -m 5 -H @"$header" -H 'Content-Type: application/json' \
    --data-binary "{\"round_id\":\"$round\",\"exit_code\":$1,\"usage\":{\"input_tokens\":${2:-null},\"cached_input_tokens\":${3:-null},\"output_tokens\":${4:-null}}}" \
    "$base/v1/auto/finish" >/dev/null 2>&1
}

locate_codex() {
  found=${WORLD_CAPTURE_CODEX:-$(command -v codex 2>/dev/null || true)}
  for candidate in /Applications/Codex.app/Contents/Resources/codex /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex; do
    [ -n "$found" ] && break
    [ -x "$candidate" ] && found=$candidate
  done
  printf '%s' "$found"
}

round_codex() {
  if [ ! -x "$program" ]; then finish 127; return; fi
  out=$(
    {
      printf '%s\n\n' '$world-source-extract'
      cat "$here/round-prompt.md"
      printf '\n通道描述文件：%s\n\n---\n\n' "$dir/agent-channel.json"
      cat "$here/../skills/world-source-extract/SKILL.md"
    } | "$program" exec --ephemeral --ignore-user-config --skip-git-repo-check --json -C "$dir" \
      -c 'default_permissions="world-extract"' -c 'features.network_proxy=true' -c 'approval_policy="never"' \
      -c "permissions.world-extract.filesystem={\":minimal\"=\"read\", \"$dir\"=\"read\", \"/private/tmp\"=\"deny\", \"/tmp\"=\"deny\"}" \
      -c 'permissions.world-extract.network.enabled=true' \
      -c 'permissions.world-extract.network.domains={"127.0.0.1"="allow"}' - 2>/dev/null
  )
  status=$?
  usage=$(printf '%s\n' "$out" | grep '"type":"turn.completed"' | tail -n 1)
  number() { printf '%s' "$usage" | sed -n "s/.*\"$1\":\\([0-9][0-9]*\\).*/\\1/p"; }
  finish "$status" "$(number input_tokens)" "$(number cached_input_tokens)" "$(number output_tokens)"
}

locate_claude() {
  found=${WORLD_CAPTURE_CLAUDE:-$(command -v claude 2>/dev/null || true)}
  for candidate in "$HOME/.local/bin/claude" "${CLAUDE_CODE_EXECPATH:-}"; do
    [ -n "$found" ] && break
    [ -x "$candidate" ] && found=$candidate
  done
  printf '%s' "$found"
}

# 隔离全靠这几处，缺一不可：空环境（不带父会话的会话 id 和消息 socket）、空临时目录作工作目录（不读任何项目配置）、
# --no-session-persistence（不留会话文件，不会被采集）、--safe-mode 加 disableAllHooks（不加载插件和 hook）、
# 沙箱只读组件目录和本轮临时目录（主目录、各临时目录、外接卷都拒读）、不能写组件目录、只开回环。Claude Code 把命令输出
# 写在它的临时目录里，拒读 /private/tmp 时要用 CLAUDE_CODE_TMPDIR 把它挪进本轮目录，否则 cat 这类命令一律报 stdout 无权限。
# 一批 20 条原文加 targets 常超过 Bash 工具默认的 30000 字符输出上限，被截断后模型会自己改小批次重取，一轮只办完三四十条。
round_claude() {
  if [ ! -x "$program" ]; then finish 127; return; fi
  work=$(mktemp -d) || { finish 1; return; }
  trap 'rm -rf "$work"; exit 143' TERM INT HUP
  real=$(cd "$work" && pwd -P) || { rm -rf "$work"; finish 1; return; }
  json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  allowed=$(json "$dir") readable=$(json "$real")
  settings=$(printf '{"disableAllHooks":true,"sandbox":{"enabled":true,"failIfUnavailable":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false,"network":{"allowedDomains":[],"allowLocalBinding":true},"filesystem":{"denyRead":["~","/private/tmp","/private/var/tmp","/private/var/folders","/Users/Shared","/Volumes"],"allowRead":["%s","%s"],"denyWrite":["%s"]}},"permissions":{"allow":["Bash(curl *)"],"deny":["WebFetch","WebSearch"]}}' "$allowed" "$readable" "$allowed")
  out=$(
    cd "$work" || exit 1
    {
      cat "$here/round-prompt.md"
      printf '\n通道描述文件：%s\n\n---\n\n' "$dir/agent-channel.json"
      cat "$here/../skills/world-source-extract/SKILL.md"
    } | env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$program")" \
      LANG="${LANG:-en_US.UTF-8}" TMPDIR="$real" CLAUDE_CODE_TMPDIR="$real" WORLD_AUTO_EXTRACT_ROUND="$round" \
      BASH_MAX_OUTPUT_LENGTH=150000 \
      "$program" -p --no-session-persistence --safe-mode --strict-mcp-config --tools Bash --permission-mode dontAsk \
      --settings "$settings" --model "${WORLD_CAPTURE_CLAUDE_MODEL:-sonnet}" --output-format json 2>/dev/null
  )
  status=$?
  rm -rf "$work"
  # 输出里 iterations 数组每项也有同名的键，所以按 usage.<键> 的完整路径取，不用 sed 抓第一个匹配。
  tokens() {
    value=$(printf '%s' "$out" | plutil -extract "usage.$1" raw -o - - 2>/dev/null) || return 0
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s' "$value" ;; esac
  }
  fresh=$(tokens input_tokens) written=$(tokens cache_creation_input_tokens) cached=$(tokens cache_read_input_tokens)
  input=
  if [ -n "$fresh" ] && [ -n "$written" ] && [ -n "$cached" ]; then input=$((fresh + written + cached)); fi
  finish "$status" "$input" "$cached" "$(tokens output_tokens)"
}

by_agent() {
  case "$1" in
    codex) format=codex-rollout-jsonl/1 locate=locate_codex run_round=round_codex ;;
    claude) format=claude-session-jsonl/1 locate=locate_claude run_round=round_claude ;;
    *) return 1 ;;
  esac
}

if [ "${1:-}" = "__round" ]; then
  agent=$2 round=$3 program=$4 dir=$5 base=$6 header=$7
  by_agent "$agent" || exit 0
  $run_round
  exit 0
fi

[ -n "${WORLD_AUTO_EXTRACT_ROUND:-}" ] && exit 0
agent=${1:-}
by_agent "$agent" || exit 0
case "${2:-}" in
  SessionStart) trigger=session_start ;;
  Stop) trigger=stop ;;
  SessionEnd) trigger=session_end ;;
  *) exit 0 ;;
esac
case "$(uname -s)" in
  Darwin) dir=${WORLD_CAPTURE_DIR:-"$HOME/Library/Application Support/World Capture/capture"} ;;
  *) exit 0 ;;
esac
descriptor="$dir/agent-channel.json"
[ -f "$descriptor" ] || exit 0
json=$(cat "$descriptor" 2>/dev/null) || exit 0
field() { printf '%s' "$json" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }
[ "$(field source_format)" = "$format" ] || exit 0
base=$(field base_url)
header=$(field header_file)
case "$base" in http://127.0.0.1:[0-9]*) ;; *) exit 0 ;; esac
[ -f "$header" ] || exit 0

answer=$(curl -sS -m 5 -H @"$header" -H 'Content-Type: application/json' \
  --data-binary "{\"trigger\":\"$trigger\"}" "$base/v1/auto/claim" 2>/dev/null) || exit 0
case "$answer" in *'"run":true'*) ;; *) exit 0 ;; esac
round=$(printf '%s' "$answer" | sed -n 's/.*"round_id":"\([0-9a-f-]*\)".*/\1/p')
[ -n "$round" ] || exit 0

program=$($locate)
WORLD_AUTO_EXTRACT_ROUND=$round nohup sh "$here/auto-extract.sh" __round "$agent" "$round" "${program:-/nonexistent}" "$dir" "$base" "$header" \
  </dev/null >/dev/null 2>&1 &
exit 0
