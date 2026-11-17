#!/bin/sh
# 本机采集的启动脚本（Mac）：capture.sh <claude|codex> <事件>，钩子的 JSON 从 stdin 来。
# 钩子的标准输出会被 Agent 当作指令解析（Stop 钩子输出 {"decision":"block"} 会拦住会话），所以这里什么都不输出，
# 任何失败都静默 exit 0。只用系统自带的 sh、/usr/bin/jq 和 /usr/bin/openssl；读取规则在同目录的 capture.jq，
# 后台轮（判断、落盘、送出、回执）的数据部分在 round.jq，提示词在 round-prompt.md。
# 另有三个子命令给「开始采集」那次对话里的 Agent 用（capture.sh <check|enable|import> <claude|codex> [选择记录文件]）：
# 它们在标准输出上交一行 JSON，拒绝时退出码 1；规则在 setup.jq。

[ -n "${WORLD_AUTO_EXTRACT_ROUND:-}" ] && exit 0
case "${1:-}" in
  check | enable | import) command=$1; shift; exec 2>/dev/null ;;
  *) command=; exec >/dev/null 2>&1 ;;
esac
# 装了 Git Bash 的 Windows 会把 Claude Code 那一行钩子整行交给 Git Bash，PowerShell 那段已经干过活了。
case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*)
  [ -n "$command" ] && printf '{"ok":false,"reason":"use_powershell"}\n' && exit 1
  exit 0 ;;
esac
# 钩子环境里的 PATH 只用来找 claude、codex（经环境变量传给脱离的进程）；脚本自己只用系统目录。
AGENT_PATH=${TKOS_CAPTURE_AGENT_PATH:-${PATH:-}}
TKOS_CAPTURE_AGENT_PATH=$AGENT_PATH
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL TKOS_CAPTURE_AGENT_PATH
umask 077

JQ=${TKOS_CAPTURE_JQ:-/usr/bin/jq}
# 后台轮的 world 连接：服务名 world 和地址要与 world 插件的 mcp.json 逐字一致，令牌按这两样找。
WORLD_URL=https://world.tokenkingos.com/app/mcp
# 一轮的硬时限（秒）。判断、送出、回执各次调用的时限按它的比例算，锁比它再老 LOCK_MARGIN 秒就当持锁的进程已不在。
ROUND_LIMIT=${TKOS_CAPTURE_ROUND_LIMIT:-1200}
case "$ROUND_LIMIT" in "" | *[!0-9]*) ROUND_LIMIT=1200 ;; esac
LOCK_MARGIN=600
OPENSSL=/usr/bin/openssl
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
script="$here/capture.sh"
mode=hook
if [ "${1:-}" = __worker ]; then mode=worker; shift; fi
agent=${1:-}
event=${2:-}
# 子命令拒绝时：标准输出上一行 {"ok":false,"reason":…}，退出码 1。
refuse() { printf '{"ok":false,"reason":"%s"}\n' "$1"; exit 1; }
case "$agent" in
  claude) format=claude-session-jsonl/1 ;;
  codex) format=codex-rollout-jsonl/1 ;;
  *) [ -n "$command" ] && refuse unknown_agent; exit 0 ;;
esac
[ -n "$command" ] || case "$event" in '' | *[!A-Za-z]*) exit 0 ;; esac
if [ -n "${TKOS_CAPTURE_HOME:-}" ]; then home=$TKOS_CAPTURE_HOME
elif [ -n "${HOME:-}" ]; then home="$HOME/.tkos-world/capture"
else [ -n "$command" ] && refuse no_home; exit 0
fi
# World Capture 组件的私有目录（Electron 的 userData 下的 capture/）。迁移只读它；它在采集时这里有 agent-channel.json。
component="${HOME:-}/Library/Application Support/World Capture/capture"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256() { "$OPENSSL" dgst -sha256 -r | cut -c1-64; }
jqc() { "$JQ" -L "$here" "$@"; }

# 目录 0700。已有的目录也收紧；是符号链接的不用。
private_dir() {
  [ -L "$1" ] && return 1
  mkdir -p "$1" && chmod 700 "$1"
}

# 这台机器上采集能不能工作：不能时 reason 是原因，能时为空。
support_reason() {
  reason= system=$(uname -s | tr -cd 'A-Za-z0-9._-') version=
  if [ "$system" != Darwin ]; then
    reason=not_macos
  else
    version=$(/usr/bin/sw_vers -productVersion | tr -cd '0-9.')
    case "${version%%.*}" in
      '' | *[!0-9]*) reason=os_version_unknown ;;
      *) [ "${version%%.*}" -ge 15 ] || reason=macos_too_old ;;
    esac
  fi
  [ -n "$reason" ] || [ -x "$JQ" ] || reason=jq_missing
  [ -n "$reason" ] || [ -x "$OPENSSL" ] || reason=openssl_missing
}

# 钩子用：不能工作时只把原因写进 unsupported.json（临时文件再改名），别的什么都不做。
unsupported() {
  support_reason
  [ -n "$reason" ] || return 1
  [ -d "$home" ] || private_dir "$home" || return 0
  seen=$(now)
  first=$(sed -n 's/.*"first_seen_at":"\([0-9TZ:-]*\)".*/\1/p' "$home/unsupported.json" 2>/dev/null)
  [ -n "$first" ] || first=$seen
  printf '{"reason":"%s","system":"%s","os_version":"%s","first_seen_at":"%s","last_seen_at":"%s"}\n' \
    "$reason" "$system" "$version" "$first" "$seen" >"$home/.unsupported.$$" \
    && mv -f "$home/.unsupported.$$" "$home/unsupported.json"
  rm -f "$home/.unsupported.$$"
  return 0
}

held= child=
cleanup() {
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
  release_lock
  rm -rf "$work"
}

# 只删自己的锁：这一轮被判为无主、另一轮接手以后，锁里的 owner 已是别人的。
release_lock() {
  [ -n "$held" ] || return 0
  grep -q "\"round_id\":\"$round_id\"" "$held/owner" 2>/dev/null && rm -rf "$held"
  held=
}

# 这个会话文件读不读：确认过的文件夹（config.json 的 folder）下面的 .jsonl，本身不是符号链接；
# 按实际所在的目录比，用 .. 或文件夹里的符号链接绕到外面的不读。
transcript_ok() {
  case "$1" in /*.jsonl) ;; *) return 1 ;; esac
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  dir=$(cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  root=$(cd -P -- "$folder" 2>/dev/null && pwd -P) || return 1
  case "$dir/" in "$root"/*) return 0 ;; esac
  return 1
}

# 本机状态目录和这一次运行的临时目录。
prepare_state() {
  private_dir "$home" && private_dir "$home/transcripts" && private_dir "$home/tmp" || return 1
  queue="$home/queue/$format"
  mkdir -p "$queue" && chmod 700 "$home/queue" "$home/queue/${format%%/*}" "$queue" || return 1
  find "$home/tmp" -mindepth 1 -maxdepth 1 -mtime +0 -exec rm -rf {} + 2>/dev/null
  work=$(mktemp -d "$home/tmp/run.XXXXXX") || return 1
  trap cleanup EXIT
  trap 'cleanup; exit 0' HUP INT TERM
}

# 读这个会话文件上次读到的位置之后、已经写完整的行，新条目放进队列，最后做起轮决定。
worker() {
  path=$1
  [ -f "$home/config.json" ] || return
  entry=$(jqc -n -r --arg agent "$agent" --arg format "$format" --slurpfile config "$home/config.json" \
    'include "capture"; $config[0] | config_entry($agent; $format)') || return
  [ -n "$entry" ] || return
  { IFS= read -r source_id; IFS= read -r from; IFS= read -r folder; } <<EOF
$entry
EOF
  transcript_ok "$path" || return
  prepare_state || return
  read_file "$path"
  decide
}

# 读一个会话文件，新条目放进队列。用到 source_id、from（历史起点）、queue、work。
read_file() {
  path=$1
  rm -rf "$work/h" "$work/q"
  key=$(printf '%s' "$path" | sha256)
  position="$home/transcripts/$key.json"
  set -- $(stat -f '%z %m' "$path")
  size=$1 mtime=$2
  offset=0 head_bytes=0 head_sha= lines=0 previous=/dev/null
  if [ -f "$position" ]; then
    known=$(jqc -r --arg format "$format" --arg path "$path" 'include "capture"; position_line($format; $path)' "$position")
    if [ -n "$known" ]; then
      set -- $known
      # 文件变小，或开头那一段的摘要变了：当作被改写，从头读。
      if [ "$size" -ge "$1" ] && [ "$(head -c "$2" "$path" | sha256)" = "$3" ]; then
        offset=$1 head_bytes=$2 head_sha=$3 lines=$4 previous=$position
      fi
    fi
  fi

  if [ "$size" -gt "$offset" ]; then
    tail -c +"$((offset + 1))" "$path" | head -c "$((size - offset))" >"$work/chunk"
    length=$(wc -c <"$work/chunk" | tr -d ' ')
    complete=$length
    if [ "$length" -gt 0 ] && [ "$(tail -c 1 "$work/chunk" | od -An -tu1 | tr -d ' ')" != 10 ]; then
      complete=$((length - $(tail -n 1 "$work/chunk" | wc -c | tr -d ' ')))
    fi
    if [ "$complete" -gt 0 ]; then
      head -c "$complete" "$work/chunk" >"$work/lines"
      read_increment
    fi
  fi
  return 0
}

# UTF-8 合法的一行。不合法的行 TextDecoder（fatal）读不出，jq 却会换成 U+FFFD 照读，所以先挑出来。
UTF8=$(printf '^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354\356\357][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$')

read_increment() {
  bad=$(grep -n -a -v -E "$UTF8" "$work/lines" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
  jqc -n -c --arg format "$format" --arg from "$from" --argjson base "$lines" --argjson bad "[$bad]" \
    --slurpfile previous "$previous" --rawfile data "$work/lines" \
    'include "capture"; parse($format; $from; $base; $previous[0]; $bad; $data)' >"$work/result.json" || return 1
  # 认不出是这种格式（Claude 没有带会话 id 的消息，Codex 还没有 session_meta）：不前进，下次从同一处再读。
  [ "$(jqc -r '.recognized' "$work/result.json")" = true ] || return 1

  mkdir "$work/h" "$work/q" || return 1
  jqc -r --arg format "$format" 'include "capture"; hash_inputs($format)' "$work/result.json" >"$work/hash-in" || return 1
  awk -v dir="$work/h" '{ f = dir "/" NR; printf "%s", $0 > f; close(f) }' "$work/hash-in"
  for i in $(jqc -r 'include "capture"; slow_ids' "$work/result.json"); do
    jqc -j --arg format "$format" --argjson i "$i" '$format + ":" + .entries[$i].id' "$work/result.json" >"$work/h/$((2 * i + 1))"
  done
  if [ -n "$(ls "$work/h")" ]; then (cd "$work/h" && "$OPENSSL" dgst -sha256 -r *) >"$work/hashes" || return 1
  else : >"$work/hashes"
  fi

  offset=$((offset + complete))
  head_bytes=$offset
  [ "$head_bytes" -le 4096 ] || head_bytes=4096
  head_sha=$(head -c "$head_bytes" "$path" | sha256)
  # 先列队列、再读已送出：后台轮是先记已送出、再删队列文件，这个顺序下刚送出的条目不会被重新排进来。
  ls "$queue" >"$work/queued"
  delivered="$home/delivered/$format.jsonl"
  [ -f "$delivered" ] || delivered=/dev/null
  seen=$(now)
  meta=$(printf '{"path":%s,"format":"%s","offset":%s,"size":%s,"mtime":%s,"head_bytes":%s,"head_sha256":"%s","source_id":"%s","now":"%s"}' \
    "$(jqc -n --arg p "$path" '$p')" "$format" "$offset" "$size" "$mtime" "$head_bytes" "$head_sha" "$source_id" "$seen")
  jqc -n -r --slurpfile result "$work/result.json" --slurpfile previous "$previous" --rawfile hashes "$work/hashes" \
    --rawfile queued "$work/queued" --rawfile delivered "$delivered" --argjson meta "$meta" \
    'include "capture"; assemble($result[0]; $previous[0]; $hashes; $queued; $delivered; $meta)' >"$work/out" || return 1
  # 先把条目放进队列，再写位置：中途断了，下次从旧位置重读，同名条目不会重复。
  tail -n +2 "$work/out" | awk -v dir="$work/q" '{ i = index($0, "\t"); name = substr($0, 1, i - 1)
    f = dir "/" name; printf "%s\n", substr($0, i + 1) > f; close(f); print name }' >"$work/names"
  while IFS= read -r name; do
    mv -f "$work/q/$name" "$queue/$name"
  done <"$work/names"
  head -n 1 "$work/out" >"$work/position" && mv -f "$work/position" "$home/transcripts/$key.json"
}

# 后台轮不起的原因写进 paused.json（首次和最近一次碰到的时刻）；原因不在了，下一次钩子删掉它。
paused() {
  seen=$(now)
  first=$(sed -n 's/.*"first_seen_at":"\([0-9TZ:-]*\)".*/\1/p' "$home/paused.json" 2>/dev/null)
  [ -n "$first" ] || first=$seen
  printf '{"reason":"%s","first_seen_at":"%s","last_seen_at":"%s"}\n' "$1" "$first" "$seen" >"$work/paused" \
    && mv -f "$work/paused" "$home/paused.json"
}

# 起轮决定：队列规则（最早一条等了 30 分钟或会话结束）加上组件、间隔与锁。设了 TKOS_CAPTURE_DECISION_FILE 时把决定写出来供测试核对。
decide() {
  find "$queue" -type f -name 'entry-*.json' -exec grep -h -o '"first_seen_at":"[^"]*"' {} + 2>/dev/null \
    | jqc -n -R -c --arg agent "$agent" --arg event "$event" --arg format "$format" --arg now "$(now)" \
      'include "capture"; decision($agent; $event; $format; $now)' >"$work/decision" || return 0
  rounds_of_format >"$work/rounds.json"
  locked=false
  [ -d "$home/round.lock" ] && ! lock_stale && locked=true
  capturing=false
  if [ -e "$component/agent-channel.json" ]; then capturing=true; paused component_capturing
  else rm -f "$home/paused.json"
  fi
  jqc -c --slurpfile rounds "$work/rounds.json" --arg now "$(now)" --argjson locked "$locked" --argjson component "$capturing" \
    'include "round"; with_gate($rounds[0] | gate($now); $locked; $component)' "$work/decision" >"$work/decision.gated" || return 0
  if [ -n "${TKOS_CAPTURE_DECISION_FILE:-}" ]; then
    cp "$work/decision.gated" "$work/decision.out" && mv -f "$work/decision.out" "$TKOS_CAPTURE_DECISION_FILE"
  fi
  [ "$(jqc -r '.run' "$work/decision.gated")" = true ] || return 0
  round "$(jqc -r '.reason' "$work/decision.gated")"
}

# ---------- 后台轮（ADR 决定三、九）：判断、落盘、送出、回执 ----------
# 一轮里每次模型调用是一次单独的 claude -p 或 codex exec：判断那次只有两个只读工具，交回的判断由这里核对、落盘；
# 送出那次只有送出和读回两个工具，参数是这里算好的骨架加上已落盘的判断；最后一次只报运行回执。

rounds_of_format() {
  if [ -d "$home/rounds" ]; then
    find "$home/rounds" -type f -name '*.json' -exec cat {} + 2>/dev/null \
      | jqc -s -c --arg format "$format" 'map(select(type == "object" and .format == $format))' 2>/dev/null || printf '[]'
  else printf '[]'
  fi
}

# 锁比时限再老一截，说明持锁的进程已经不在了。
lock_stale() {
  [ -n "$(find "$home/round.lock" -maxdepth 0 -mmin +$(( (ROUND_LIMIT + LOCK_MARGIN + 59) / 60 )) 2>/dev/null)" ]
}

left() { echo $(( ROUND_LIMIT - $(date +%s) + start_epoch )); }

# state.json 记这一轮的经过，最后写进 rounds/<round_id>.json。
note() {
  expr=$1; shift
  jqc "$@" "$expr" "$work/state.json" >"$work/state.next" && mv -f "$work/state.next" "$work/state.json"
}
fail() { note '.failure = (.failure // {class: $c, detail: $d})' --arg c "$1" --arg d "$2"; }

# 程序位置：TKOS_CAPTURE_CLAUDE / TKOS_CAPTURE_CODEX 指定的；否则钩子环境里的 PATH；再找常见的安装位置。
locate_program() {
  if [ "$agent" = claude ]; then override=${TKOS_CAPTURE_CLAUDE:-}; else override=${TKOS_CAPTURE_CODEX:-}; fi
  if [ -n "$override" ]; then
    [ -f "$override" ] && [ -x "$override" ] && printf '%s' "$override"
    return 0
  fi
  found=$(PATH=$AGENT_PATH; command -v "$agent" 2>/dev/null)
  case "$found" in /*) [ -f "$found" ] && [ -x "$found" ] && { printf '%s' "$found"; return 0; } ;; esac
  if [ "$agent" = claude ]; then set -- "$HOME/.local/bin/claude" "${CLAUDE_CODE_EXECPATH:-}"
  else set -- /Applications/Codex.app/Contents/Resources/codex /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
  fi
  for candidate in "$@"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
}

# 已装的 world 插件里的提炼技能。Claude Code 从 installed_plugins.json 取 installPath（版本升级后目录会变）；
# Codex 没有这样的索引，取插件缓存里 tkos-world/world 下版本号最大的目录。
world_skill() {
  if [ "$agent" = claude ]; then
    installed="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
    [ -f "$installed" ] || return 1
    plugin=$(jqc -r 'include "round"; installed_world' "$installed" 2>/dev/null)
    [ -n "$plugin" ] && [ -f "$plugin/skills/world-source-extract/SKILL.md" ] || return 1
    printf '%s' "$plugin/skills/world-source-extract/SKILL.md"
  else
    cache="${CODEX_HOME:-$HOME/.codex}/plugins/cache/tkos-world/world"
    version=$(ls "$cache" 2>/dev/null | jqc -R -s -r 'include "round"; newest_version')
    [ -n "$version" ] && [ -f "$cache/$version/skills/world-source-extract/SKILL.md" ] || return 1
    printf '%s' "$cache/$version/skills/world-source-extract/SKILL.md"
  fi
}

# 队列、results/、delivered/ 读一遍，算这一轮该做什么（round.jq 的 plan）。
make_plan() {
  find "$queue" -type f -name 'entry-*.json' -exec cat {} + 2>/dev/null >"$work/queue.jsonl"
  : >"$work/results.jsonl"
  if [ -n "$(ls "$home/results" 2>/dev/null)" ]; then
    find "$home/results" -type f -name 'entry-*.json' -exec "$JQ" -c \
      '{name: (input_filename | sub(".*/"; "") | sub("\\.json$"; "")), value: .}' {} + 2>/dev/null >"$work/results.jsonl"
  fi
  [ -f "$delivered" ] && src=$delivered || src=/dev/null
  jqc -n -c --rawfile queue "$work/queue.jsonl" --rawfile results "$work/results.jsonl" --rawfile delivered "$src" --arg format "$format" \
    --rawfile prompts "$here/round-prompt.md" 'include "round"; plan($queue | split("\n") | map(fromjson? // empty);
       $results | split("\n") | map(fromjson? // empty) | map(select(.value.format == $format)); $delivered;
       prompt_section($prompts; "omitted"))' >"$work/plan.json"
}

# 先把 delivered 记上，再删队列文件和 results/（启动脚本读增量时先列队列、再读 delivered，这个顺序下不会重排）。
apply_effects() {
  jqc -r '.deliver[]' "$1" >"$work/deliver.jsonl" && [ -s "$work/deliver.jsonl" ] && cat "$work/deliver.jsonl" >>"$delivered"
  jqc -r '.remove[]' "$1" | while IFS= read -r name; do
    rm -f "$queue/$name.json" "$home/results/$name.json"
  done
  jqc -r '.write[] | "\(.name)\t\(.mode)\t\(.value | tojson)"' "$1" | while IFS="$(printf '\t')" read -r name mode value; do
    printf '%s\n' "$value" >"$work/result.tmp" || continue
    # 新判断只在还没有这一条时写：已有的判断不改，重送用的就是落盘的那一份。
    if [ "$mode" = new ]; then ln "$work/result.tmp" "$home/results/$name.json" 2>/dev/null; rm -f "$work/result.tmp"
    else mv -f "$work/result.tmp" "$home/results/$name.json"
    fi
  done
}

settle() {
  jqc -c --arg round "$round_id" --arg at "$(now)" 'include "round"; settle_effects(.; $round; $at)' "$work/plan.json" >"$work/effects.json" \
    && apply_effects "$work/effects.json" \
    && note '.nulls += ([$e[0].deliver[] | fromjson | select(.status == "null")] | length)' --slurpfile e "$work/effects.json"
}

# 起一次 CLI，最多等 $1 秒，到点先 TERM 再 KILL。标准输入是 $work/prompt。
run_cli() {
  limit=$1; shift
  [ "$limit" -ge 1 ] || limit=1
  call_start=$(date +%s)
  (cd "$home/work" && exec env -i "$@" <"$work/prompt" >"$work/out" 2>"$work/err") &
  child=$!
  ticks=0 timed_out=false
  while kill -0 "$child" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 5)) ]; then
      timed_out=true
      kill -TERM "$child" 2>/dev/null
      sleep 1
      kill -KILL "$child" 2>/dev/null
      break
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$child"
  status=$?
  child=
  seconds=$(( $(date +%s) - call_start ))
}

# 一次模型调用：$1 是 judge、send 或 report，$2 是最多等几秒。解析结果在 $work/call.json。
call() {
  kind=$1 limit=$2
  user=$(id -un)
  set -- HOME="$HOME" USER="$user" LOGNAME="$user" PATH="/usr/bin:/bin:/usr/sbin:/sbin:${program%/*}" \
    LANG="${LANG:-en_US.UTF-8}" TMPDIR="$work/tmp" WORLD_AUTO_EXTRACT_ROUND="$round_id"
  if [ "$agent" = claude ]; then
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && set -- "$@" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"
    tools=$(jqc -n -r --arg kind "$kind" 'include "round"; TOOLS[$kind] | map(CLAUDE_PREFIX + .) | join(",")')
    set -- "$@" "$program" -p --no-session-persistence --setting-sources "" --plugin-dir "${skill%/skills/*}" --tools "" \
      --allowedTools "$tools" --permission-mode dontAsk --output-format stream-json --verbose \
      --model "${TKOS_CAPTURE_CLAUDE_MODEL:-sonnet}"
  else
    [ -n "${CODEX_HOME:-}" ] && set -- "$@" CODEX_HOME="$CODEX_HOME"
    tools=$(jqc -n -c --arg kind "$kind" 'include "round"; TOOLS[$kind]')
    set -- "$@" "$program" exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only -C "$home/work" \
      -c features.shell_tool=false -c features.view_image=false -c 'web_search="disabled"' \
      -c tools.experimental_request_user_input.enabled=false -c agents.enabled=false -c features.goals=false \
      -c features.sleep_tool=false -c features.image_generation=false -c features.tool_suggest=false -c features.apps=false \
      -c cloud.skills.enabled=false -c features.code_mode=false \
      -c "mcp_servers.world.url=\"$WORLD_URL\"" -c "mcp_servers.world.enabled_tools=$tools" \
      -c 'mcp_servers.world.default_tools_approval_mode="approve"' -c mcp_servers.world.required=true \
      -c 'mcp_servers.world.omit_tools_from=["deferred","code_mode"]' --json -
  fi
  mkdir -p "$work/tmp"
  run_cli "$limit" "$@"
  tail -c 4000 "$work/err" >"$work/err.tail" 2>/dev/null
  if [ "$agent" = claude ]; then parser=parse_claude; tidy_claude; else parser=parse_codex; fi
  jqc -n -R -c --arg agent "$agent" --argjson status "$status" --argjson timeout "$timed_out" --rawfile err "$work/err.tail" \
    "include \"round\"; [inputs | fromjson? // empty] | $parser | . + {failure: classify(\$agent; \$status; \$timeout; \$err)}" \
    "$work/out" >"$work/call.json" || printf '{"calls":[],"failure":{"class":"other","detail":"output_unreadable"}}' >"$work/call.json"
  note '.calls += [{kind: $kind, exit_code: $status, seconds: $seconds, timed_out: $timeout, failure: $call[0].failure, usage: $call[0].usage}]
    | .exit_code = $status
    | .usage = (if $call[0].usage == null then .usage else
        {input_tokens: ((.usage.input_tokens // 0) + $call[0].usage.input_tokens), cached_input_tokens: ((.usage.cached_input_tokens // 0) + $call[0].usage.cached_input_tokens),
         output_tokens: ((.usage.output_tokens // 0) + $call[0].usage.output_tokens)} end)' \
    --arg kind "$kind" --argjson status "$status" --argjson seconds "$seconds" --argjson timeout "$timed_out" --slurpfile call "$work/call.json"
}

# claude -p 每次在 projects 下按工作目录留一个目录：里面是空的 memory/（核查 9），工具返回超过约 50 KB 时还有
# <会话 id>/tool-results/ 下存的完整返回（--no-session-persistence 也存，实测）。这个目录只属于后台轮的 work/，
# 删掉存下的工具返回，再删空目录；别的文件不动。
tidy_claude() {
  real=$(cd "$home/work" && pwd -P) || return 0
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$real" | sed 's/[^A-Za-z0-9]/-/g')"
  [ -d "$dir" ] || return 0
  for results in "$dir"/*/tool-results; do
    [ -d "$results" ] || continue
    find "$results" -maxdepth 1 -type f -name 'toolu_*' -exec rm -f {} + 2>/dev/null
    rmdir "$results" "${results%/tool-results}" 2>/dev/null
  done
  rmdir "$dir/memory" 2>/dev/null
  rmdir "$dir" 2>/dev/null
  return 0
}

judge_batch() {
  budget=$(( $(left) - ROUND_LIMIT * 9 / 20 ))
  [ "$budget" -gt $(( ROUND_LIMIT / 20 )) ] || return 2
  [ "$budget" -le $(( ROUND_LIMIT / 4 )) ] || budget=$(( ROUND_LIMIT / 4 ))
  jqc -c --argjson i "$1" '.judge[$i]' "$work/plan.json" >"$work/batch.json"
  jqc -n -r --rawfile p "$here/round-prompt.md" --rawfile rules "$work/rules" --argjson cfg "$cfg" --slurpfile batch "$work/batch.json" \
    'include "round"; judge_prompt(prompt_section($p; "judge"); $rules | sub("\\s+$"; ""); $cfg; $batch[0])' >"$work/prompt"
  call judge "$budget"
  jqc -c --argjson cfg "$cfg" --slurpfile batch "$work/batch.json" \
    'include "round"; if .failure then {failure} else judge_outcome($batch[0]; $cfg) end' "$work/call.json" >"$work/outcome.json"
  failure=$(jqc -c '.failure' "$work/outcome.json")
  if [ "$failure" != null ]; then note '.failure = (.failure // $f[0].failure)' --slurpfile f "$work/outcome.json"; return 1; fi
  jqc -c --arg format "$format" --arg round "$round_id" --arg at "$(now)" 'include "round"; judge_effects($format; $round; $at)' \
    "$work/outcome.json" >"$work/effects.json" || { fail other effects_unreadable; return 1; }
  apply_effects "$work/effects.json"
  note '.taken += ($o[0].accepted | length) + ($o[0].invalid | length)
    | .mismatches += [$o[0].mismatches[] + {call: "judge"}] + [$o[0].unanswered[] | {name: ., reason: "unanswered", call: "judge"}]' \
    --slurpfile o "$work/outcome.json"
}

send_batch() {
  budget=$(( $(left) - ROUND_LIMIT / 4 ))
  [ "$budget" -le $(( ROUND_LIMIT / 5 )) ] || budget=$(( ROUND_LIMIT / 5 ))
  [ "$budget" -ge 1 ] || { fail other no_time_to_send; return 1; }
  jqc -c --argjson cfg "$cfg" --arg round "$round_id" 'include "round"; increments(.send; $cfg; $round)' "$work/plan.json" >"$work/increments.json"
  jqc -r --rawfile p "$here/round-prompt.md" --argjson cfg "$cfg" --slurpfile inc "$work/increments.json" \
    'include "round"; send_prompt(prompt_section($p; "send"); prompt_section($p; "send-readback"); prompt_section($p; "send-ingest");
       $cfg; $inc[0]; .readback)' "$work/plan.json" >"$work/prompt"
  call send "$budget"
  jqc -c --slurpfile inc "$work/increments.json" 'include "round"; send_outcome($inc[0])' "$work/call.json" >"$work/send.json"
  jqc -c --slurpfile outcome "$work/send.json" --arg round "$round_id" --arg at "$(now)" \
    'include "round"; send_effects(.; $outcome[0]; $round; $at)' "$work/plan.json" >"$work/effects.json" \
    || { fail other effects_unreadable; return 1; }
  apply_effects "$work/effects.json"
  note '.accepted += ([$e[0].deliver[] | fromjson | select(.status == "imported")] | length)
    | .imports += [$e[0].deliver[] | fromjson | select(.import_id != null) | {item_id, item_version, import_id}]
    | .mismatches += [$s[0].increments[] | select(.sent and (.exact | not)) | {items, reason: "copy_mismatch", call: "send"}]
      + [$s[0].unknown[] | {items: ., reason: "unknown_import", call: "send"}]
    | .rejected += ([$s[0].increments[].rejected[]] | length)
    | .send_errors = [$s[0].increments[] | select(.error != null) | {items, error}]' \
    --slurpfile e "$work/effects.json" --slurpfile s "$work/send.json"
  failure=$(jqc -c '.failure' "$work/call.json")
  [ "$failure" = null ] || { note '.failure = (.failure // $c[0].failure)' --slurpfile c "$work/call.json"; return 1; }
}

report_run() {
  budget=$(left)
  [ "$budget" -le $(( ROUND_LIMIT / 4 )) ] || budget=$(( ROUND_LIMIT / 4 ))
  [ "$budget" -ge 1 ] || { note '.report = {status: "skipped", reason: "no_time"}'; return 0; }
  find "$home/transcripts" -type f -name '*.json' -exec cat {} + 2>/dev/null \
    | jqc -s -c --arg format "$format" 'map(select(.format == $format)) | {count: length, bytes: (map(.offset // 0) | add // 0)}' >"$work/files.json"
  [ -f "$work/send.json" ] || printf 'null' >"$work/send.json"
  jqc -c --argjson cfg "$cfg" --arg round "$round_id" --arg started "$started" --arg finished "$(now)" \
    --slurpfile files "$work/files.json" --slurpfile outcome "$work/send.json" --slurpfile state "$work/state.json" \
    'include "round"; report_args($cfg; $round; $started; $finished; .; $files[0]; $outcome[0]; $state[0].taken)' "$work/plan.json" >"$work/report.json"
  jqc -n -r --rawfile p "$here/round-prompt.md" --slurpfile args "$work/report.json" \
    'include "round"; report_prompt(prompt_section($p; "report"); $args[0])' >"$work/prompt"
  call report "$budget"
  note '.report = ([$c[0].calls[] | select(.tool == "world_app_sources_report_run")] as $runs
      | if ($runs | length) == 0 then {status: "not_called"}
        elif any($runs[]; .args == $a[0] and (.failed | not) and ((.text | try fromjson catch null) | .error == null)) then {status: "reported"}
        elif any($runs[]; .args != $a[0]) then {status: "copy_mismatch"}
        else {status: "failed", error: ([$runs[] | .text | try fromjson catch null | .error.code? // null] | map(select(. != null)) | first)} end)
    | .backlog = $a[0].pending_count' --slurpfile c "$work/call.json" --slurpfile a "$work/report.json"
}

run_round() {
  cfg=$(jqc -c --arg agent "$agent" --arg format "$format" 'include "round"; round_config($agent; $format)' "$home/config.json")
  [ -n "$cfg" ] || { fail other config_changed; return; }
  program=$(locate_program)
  [ -n "$program" ] || { fail program_missing not_found; return; }
  skill=$(world_skill) || { fail world_unavailable world_plugin_missing; return; }
  jqc -n -r -e --rawfile skill "$skill" --rawfile p "$here/round-prompt.md" \
    'include "round"; skill_rules($skill; prompt_section($p; "rules-from"))' >"$work/rules" 2>/dev/null \
    || { fail world_unavailable skill_rules_missing; return; }
  make_plan
  settle
  batches=$(jqc '.judge | length' "$work/plan.json")
  i=0
  while [ "$i" -lt "$batches" ]; do
    judge_batch "$i"
    case $? in 0) ;; 2) break ;; *) return ;; esac
    i=$((i + 1))
  done
  make_plan
  settle
  if [ "$(jqc '(.send | length) + (.readback | length)' "$work/plan.json")" -gt 0 ]; then
    send_batch || return
  fi
  make_plan
  report_run
}

round() {
  trigger=$1
  lock="$home/round.lock"
  round_id=$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
  started=$(now)
  start_epoch=$(date +%s)
  if ! mkdir "$lock" 2>/dev/null; then
    lock_stale || return 0
    mv "$lock" "$work/stale-lock" 2>/dev/null || return 0
    mkdir "$lock" 2>/dev/null || return 0
  fi
  held=$lock
  chmod 700 "$lock"
  printf '{"pid":%s,"round_id":"%s","started_at":"%s"}\n' "$$" "$round_id" "$started" >"$lock/owner"
  for dir in rounds results delivered work; do private_dir "$home/$dir" || { release_lock; return 0; }; done
  mkdir -p "$home/delivered/${format%%/*}" && chmod 700 "$home/delivered/${format%%/*}"
  delivered="$home/delivered/$format.jsonl"
  printf '{"taken":0,"accepted":0,"nulls":0,"rejected":0,"calls":[],"mismatches":[],"imports":[],"usage":null,"exit_code":null,"failure":null,"report":null,"backlog":null}' \
    >"$work/state.json"
  run_round
  jqc -c --arg round "$round_id" --arg agent "$agent" --arg format "$format" --arg trigger "$trigger" --arg started "$started" \
    --arg finished "$(now)" '{round_id: $round, agent: $agent, format: $format, trigger: $trigger, started_at: $started, finished_at: $finished} + .' \
    "$work/state.json" >"$work/round.json" && mv -f "$work/round.json" "$home/rounds/$round_id.json"
  ls "$home/rounds" | sort -r | tail -n +401 | while IFS= read -r old; do rm -f "$home/rounds/$old"; done
  release_lock
}

# ---------- 「开始采集」与迁移（ADR 决定七、八）：对话里的 Agent 调用的三个子命令 ----------

# 这种 Agent 的数据目录下要读的文件夹：Claude Code 是 projects，Codex 是 sessions（钩子只读其中未压缩的 .jsonl）。
data_folder() {
  if [ "$agent" = claude ]; then printf '%s/projects' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  else printf '%s/sessions' "${CODEX_HOME:-$HOME/.codex}"
  fi
}
data_dir_name() {
  if [ "$agent" = claude ]; then if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then printf CLAUDE_CONFIG_DIR; else printf '~/.claude'; fi
  elif [ -n "${CODEX_HOME:-}" ]; then printf CODEX_HOME; else printf '~/.codex'
  fi
}
# 交给 jq --rawfile 的文件：不在就是空文件。
raw() { if [ -f "$1" ]; then printf '%s' "$1"; else printf /dev/null; fi; }

# check：能不能采、设备 id 与来源标识、要读的文件夹名（不交路径）、已在采的选择、组件在不在。什么都不写。
setup_check() {
  support_reason
  if [ -n "$reason" ]; then
    printf '{"supported":false,"reason":"%s","system":"%s","os_version":"%s"}\n' "$reason" "$system" "$version"
    exit 0
  fi
  present=false
  [ -d "$(data_folder)" ] && present=true
  running=false
  [ -e "$component/agent-channel.json" ] && running=true
  jqc -n -c --arg agent "$agent" --arg format "$format" --rawfile config "$(raw "$home/config.json")" \
    --rawfile settings "$(raw "$component/settings.json")" --arg new "$(/usr/bin/uuidgen | tr A-F a-f)" --argjson running "$running" \
    --argjson present "$present" --arg system "$system" --arg version "$version" --arg dataDir "$(data_dir_name)" \
    --arg folder "$(basename "$(data_folder)")" \
    'include "setup"; check_view($agent; $format; $config; $settings; $new; $running; $present; $system; $version; $dataDir; $folder)' \
    || refuse check_failed
  exit 0
}

# 先把这次要写的东西算成 plan（setup.jq），拒绝时什么都不写。
refused_in() {
  why=$(printf '%s' "$1" | jqc -r '.refused // empty')
  [ -z "$why" ] || refuse "$why"
}

# enable：对话里确认、world 已建好的选择（selection 对象的 JSON 文件）写进 config.json。读的文件夹按数据目录算，不由 Agent 给。
setup_enable() {
  support_reason
  [ -z "$reason" ] || refuse "$reason"
  [ -n "${1:-}" ] && [ -f "$1" ] || refuse selection_file_missing
  # 数据目录是相对路径时，钩子按会话的工作目录解释它，读的范围对不上，从此静默不采；直接拒。
  case "$(data_folder)" in /*) ;; *) refuse data_dir_not_absolute ;; esac
  plan=$(jqc -n -c --arg agent "$agent" --arg format "$format" --arg folder "$(data_folder)" --rawfile config "$(raw "$home/config.json")" \
    --rawfile settings "$(raw "$component/settings.json")" --rawfile selection "$1" \
    'include "setup"; enable_plan($agent; $format; $folder; $config; $settings; $selection)') || refuse selection_unreadable
  refused_in "$plan"
  private_dir "$home" || refuse state_unwritable
  printf '%s' "$plan" | jqc -c '.config' >"$home/.config.$$" && mv -f "$home/.config.$$" "$home/config.json" \
    || { rm -f "$home/.config.$$"; refuse state_unwritable; }
  printf '%s' "$plan" | jqc -c '.result'
  exit 0
}

# import：沿用组件在窗口里建的选择（selection 对象的 JSON 文件），接过它的进度。组件目录只读不写。
# 顺序：已处理的进 delivered/，补读文件夹里的会话文件，交回未送的进 results/，记下读不到原文的，最后写 config.json；
# 中途断了重跑，每一步都按已有的状态推（delivered 不重记、队列与 results/ 不覆盖、位置文件接着读）。
setup_import() {
  support_reason
  [ -z "$reason" ] || refuse "$reason"
  [ -n "${1:-}" ] && [ -f "$1" ] || refuse selection_file_missing
  [ -f "$component/settings.json" ] || refuse component_missing
  [ -e "$component/agent-channel.json" ] && refuse component_running
  chosen=$(jqc -r 'include "setup"; component_settings | .selection_id // empty' "$component/settings.json")
  checkpoint=/dev/null extraction=/dev/null
  if [ -n "$chosen" ]; then
    checkpoint=$(raw "$component/source-$chosen.json")
    extraction=$(raw "$component/extraction-$chosen.json")
  fi
  plan=$(jqc -n -c --arg agent "$agent" --arg format "$format" --rawfile config "$(raw "$home/config.json")" \
    --rawfile settings "$component/settings.json" --rawfile selection "$1" --rawfile checkpoint "$checkpoint" --rawfile extraction "$extraction" \
    'include "setup"; import_plan($agent; $format; $config; $settings; $selection; $checkpoint; $extraction)') || refuse selection_unreadable
  refused_in "$plan"
  if [ "$(printf '%s' "$plan" | jqc -r '.already')" = true ]; then
    printf '%s' "$plan" | jqc -c --arg agent "$agent" '{ok: true, agent: $agent, selection_id, already: true}'
    exit 0
  fi
  { IFS= read -r source_id; IFS= read -r from; IFS= read -r folder; } <<EOF
$(printf '%s' "$plan" | jqc -r '.source_id, .from, .folder')
EOF
  prepare_state || refuse state_unwritable
  for dir in delivered results; do private_dir "$home/$dir" || refuse state_unwritable; done
  mkdir -p "$home/delivered/${format%%/*}" && chmod 700 "$home/delivered/${format%%/*}" || refuse state_unwritable
  done_file="$home/delivered/$format.jsonl"
  at=$(now)
  jqc -n -r --rawfile checkpoint "$checkpoint" --rawfile delivered "$(raw "$done_file")" --arg at "$at" \
    'include "setup"; import_delivered($checkpoint; $delivered; $at)' >"$work/component.jsonl" || refuse checkpoint_unreadable
  added=$(wc -l <"$work/component.jsonl" | tr -d ' ')
  [ "$added" -eq 0 ] || cat "$work/component.jsonl" >>"$done_file" || refuse state_unwritable
  # 补读确认过的文件夹：组件检查点里记着的和之后新出现的会话文件都在这里，按读增量的同一套规则从头读。唯一一次扫目录。
  before=$(ls "$queue" | wc -l | tr -d ' ')
  since=$(jqc -n -r --arg from "$from" '$from[0:19] + "Z" | fromdateiso8601')
  find -H "$folder" -type f -name '*.jsonl' >"$work/files" 2>/dev/null
  files=0 skipped=0
  while IFS= read -r file <&3; do
    transcript_ok "$file" || continue
    # 最后修改早于历史起点的文件里没有起点以后的条目（与库相同）。
    if [ "$(stat -f %m "$file")" -lt "$since" ]; then skipped=$((skipped + 1)); continue; fi
    files=$((files + 1))
    read_file "$file"
  done 3<"$work/files"
  queued=$(( $(ls "$queue" | wc -l | tr -d ' ') - before ))
  # 组件交回了、还没送出的结果：重送时内容与当初逐字相同，world 认得出同一条。
  ls "$queue" >"$work/queued"
  ls "$home/results" >"$work/judged"
  jqc -n -r --rawfile extraction "$extraction" --rawfile queued "$work/queued" --rawfile judged "$work/judged" --arg format "$format" \
    'include "setup"; import_results($extraction; $queued; $judged; $format)' >"$work/carried" || refuse extraction_unreadable
  carried=0
  while IFS="$(printf '\t')" read -r name value; do
    printf '%s\n' "$value" >"$work/result.tmp" && ln "$work/result.tmp" "$home/results/$name.json" 2>/dev/null && carried=$((carried + 1))
    rm -f "$work/result.tmp"
  done <"$work/carried"
  jqc -n -c --rawfile extraction "$extraction" --rawfile queued "$work/queued" --rawfile delivered "$(raw "$done_file")" \
    'include "setup"; import_missing($extraction; $queued; $delivered)' >"$work/missing.json" || refuse extraction_unreadable
  jqc -n -c --arg agent "$agent" --arg at "$at" --argjson plan "$plan" --slurpfile missing "$work/missing.json" --argjson delivered "$added" \
    --argjson queued "$queued" --argjson results "$carried" --argjson files "$files" --argjson skipped "$skipped" \
    '{format: "world-capture-import/0.1", agent: $agent, selection_id: $plan.selection_id, imported_at: $at, delivered: $delivered,
      queued: $queued, results: $results, missing: ($missing[0] | length), missing_items: $missing[0], files: $files, skipped_files: $skipped,
      component_plan_pending: $plan.plan_pending, open_at_login: $plan.open_at_login}' >"$work/import.json" \
    && mv -f "$work/import.json" "$home/import.json" || refuse state_unwritable
  printf '%s' "$plan" | jqc -c '.config' >"$work/config.json" && mv -f "$work/config.json" "$home/config.json" || refuse state_unwritable
  jqc -c '{ok: true, agent, selection_id, already: false} + (del(.format, .agent, .selection_id, .imported_at, .missing_items))' "$home/import.json"
  exit 0
}

case "$command" in
  check) setup_check ;;
  enable) setup_enable "${2:-}" ;;
  import) setup_import "${2:-}" ;;
esac

if [ "$mode" = worker ]; then
  worker "${3:-}"
  exit 0
fi

unsupported && exit 0
rm -f "$home/unsupported.json"
[ -f "$home/config.json" ] || exit 0
path=$(jqc -r --arg agent "$agent" --arg format "$format" --slurpfile config "$home/config.json" \
  'include "capture"; hook_transcript($config; $agent; $format)') || exit 0
[ -n "$path" ] || exit 0
if [ "${TKOS_CAPTURE_FOREGROUND:-}" = 1 ]; then
  worker "$path"
else
  nohup /bin/sh "$script" __worker "$agent" "$event" "$path" </dev/null >/dev/null 2>&1 &
fi
exit 0
