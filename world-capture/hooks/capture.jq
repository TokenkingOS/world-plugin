# capture.sh 的读取规则。逐条照 packages/world-capture 的 adapters.mjs（claude、codex 两种解析）、index.mjs（逐行读取、
# 条目身份、历史过滤）和 contract.mjs（utc、before）移植，语义按 JS 算，不按 jq 的习惯：
# - jq 的 `//` 把 false 当作没有值，JS 的 `??` 只跳过 null 和 undefined，所以这里不用 `//` 取字段。
# - jq 的正则是 Oniguruma 的 Perl 语法，\w、\b、\s 认 Unicode，^ $ 的行为也和 JS 不同，所以一律写成显式的字符类和断言。
# - 版本串 JSON.stringify([role, text, reported_at]) 按 JS 的转义规则手写，不用 tojson（tojson 把 0x7F 写成 \u007f）。

# ---------- JS 语义的小件 ----------

def field($k): if type == "object" then .[$k] else null end;
def truthy: . != null and . != false and . != 0 and . != "";
# JS 模板字符串里 `${x}` 的结果。数字只保证整数与 JS 相同（小数、指数写法 jq 与 JS 不同），条目 id 实际都是字符串。
def jsstr:
  if type == "string" then .
  elif type == "null" then "null"
  elif type == "boolean" then tostring
  elif type == "number" then (. + 0 | tostring)
  elif type == "array" then map(if . == null then "" else jsstr end) | join(",")
  else "[object Object]" end;

# JS 的 String.prototype.trim 去掉的字符（WhiteSpace 加 LineTerminator）。
def ws: "\t\n\u000b\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff";
# JS 正则里 . 不匹配、多行模式的 ^ $ 认作行边界的字符。
def eol: "\n\r\u2028\u2029";
def ltrim_js: sub("\\A[" + ws + "]+"; "");
def blank_js: test("\\A[" + ws + "]*\\z");

def hex2: . as $n | "0123456789abcdef" as $h | $h[($n / 16 | floor):($n / 16 | floor) + 1] + $h[($n % 16):($n % 16) + 1];
def escapes: [["\\", "\\\\"], ["\"", "\\\""], ["\b", "\\b"], ["\f", "\\f"], ["\n", "\\n"], ["\r", "\\r"], ["\t", "\\t"]]
  + [range(0; 32) | select(IN(8, 9, 10, 12, 13) | not) | [([.] | implode), "\\u00" + hex2]];
# JSON.stringify(string)：" \ 与 \b \f \n \r \t 用短转义，其余 0x00–0x1F 写成小写 \u00xx，其他字符（含 0x7F、U+2028）原样。
# 孤立代理项在 jq 的字符串里不存在（读入时已拒绝，见 parse_line），所以没有 \udxxx 这一条。
def jsq: escapes as $t | "\"" + reduce $t[] as $p (.; if index($p[0]) != null then split($p[0]) | join($p[1]) else . end) + "\"";

# ---------- 时间：contract.mjs 的 utc 与 before ----------

def pad($n): tostring | if length < $n then ("0" * ($n - length)) + . else . end;
def padr($n): if length < $n then . + ("0" * ($n - length)) else . end;
def days_from_civil($y; $m; $d):
  (if $m <= 2 then $y - 1 else $y end) as $yy
  | ($yy / 400 | floor) as $era
  | ($yy - $era * 400) as $yoe
  | ((153 * (if $m > 2 then $m - 3 else $m + 9 end) + 2) / 5 | floor) as $mp
  | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $mp + $d - 1) as $doe
  | $era * 146097 + $doe - 719468;
def civil_from_days($z):
  ($z + 719468) as $z2
  | ($z2 / 146097 | floor) as $era
  | ($z2 - $era * 146097) as $doe
  | (($doe - ($doe / 1460 | floor) + ($doe / 36524 | floor) - ($doe / 146096 | floor)) / 365 | floor) as $yoe
  | ($doe - (365 * $yoe + ($yoe / 4 | floor) - ($yoe / 100 | floor))) as $doy
  | ((5 * $doy + 2) / 153 | floor) as $mp
  | (if $mp < 10 then $mp + 3 else $mp - 9 end) as $m
  | [($yoe + $era * 400) + (if $m <= 2 then 1 else 0 end), $m, $doy - ((153 * $mp + 2) / 5 | floor) + 1];
# Date#toISOString 到秒为止的那一段：0–9999 年写四位，之外写正负号加六位。
def iso_seconds($t):
  ($t / 86400 | floor) as $days | ($t - $days * 86400) as $s
  | civil_from_days($days) as [$y, $m, $d]
  | (if $y >= 0 and $y <= 9999 then ($y | pad(4)) elif $y < 0 then "-" + (-$y | pad(6)) else "+" + ($y | pad(6)) end)
    + "-" + ($m | pad(2)) + "-" + ($d | pad(2)) + "T" + (($s / 3600 | floor) | pad(2)) + ":"
    + ((($s % 3600) / 60 | floor) | pad(2)) + ":" + (($s % 60) | pad(2));
# 带时区的显式时刻换成 UTC；秒以下照原样保留全部位数，没有就补 .000。不合法返回 null。
def utc:
  if type != "string" then null else
  (capture("\\A(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(?:\\.(?<f>[0-9]+))?(?<z>Z|(?<sign>[+-])(?<oh>[0-9]{2}):(?<om>[0-9]{2}))\\z") // null) as $c
  | if $c == null then null else
    ($c.y | tonumber) as $y | ($c.mo | tonumber) as $mo | ($c.d | tonumber) as $d
    | ($c.h | tonumber) as $h | ($c.mi | tonumber) as $mi | ($c.s | tonumber) as $s
    | (if $c.z == "Z" then 0 else ($c.oh | tonumber) end) as $oh | (if $c.z == "Z" then 0 else ($c.om | tonumber) end) as $om
    | ($y % 4 == 0 and ($y % 100 != 0 or $y % 400 == 0)) as $leap
    | [31, (if $leap then 29 else 28 end), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] as $month
    | if $y < 1 or $mo < 1 or $mo > 12 or $d < 1 or $d > $month[$mo - 1] or $h > 23 or $mi > 59 or $s > 59 or $oh > 23 or $om > 59
      then null
      else iso_seconds(days_from_civil($y; $mo; $d) * 86400 + $h * 3600 + $mi * 60 + $s
          - (if $c.sign == "-" then -1 else 1 end) * ($oh * 3600 + $om * 60))[0:19] + "." + ($c.f // "000") + "Z"
      end
    end
  end;
def before($a; $b):
  if $a[0:19] != $b[0:19] then $a[0:19] < $b[0:19]
  else ($a[20:-1]) as $x | ($b[20:-1]) as $y | ([($x | length), ($y | length)] | max) as $w | ($x | padr($w)) < ($y | padr($w)) end;

# ---------- adapters.mjs 的判断 ----------

def text_blocks($kinds):
  if type == "string" then [.]
  elif type == "array" then [.[] | select(type == "object" and (.type | IN($kinds[])) and (.text | type) == "string") | .text]
  else [] end;
def known_content:
  type == "string" or (type == "array" and all(.[]; type == "object" and (.type | type) == "string" and (.type != "text" or (.text | type) == "string")));
def real_request:
  (blank_js | not) and (ltrim_js | (startswith("<") or startswith("# AGENTS.md") or startswith("[Request interrupted") or startswith("Caveat:")) | not);
def skill_directory($name):
  contains("Base directory for this skill: ")
  and test("(?<![^" + eol + "])Base directory for this skill: [^" + eol + "]*[\\\\/]" + $name + "[" + ws + "]*(?![^" + eol + "])");
def daily_request:
  (ltrim_js | test("\\A[$/](?:tkos-|world:|skill:(?:tkos-)?)?world-daily(?![A-Za-z0-9_-])"))
  or (contains("<command-name>/") and test("<command-name>/(?:tkos-|world:)?world-daily</command-name>"))
  or skill_directory("(?:tkos-)?world-daily")
  or (ltrim_js | test("\\A<skill name=\"(?:tkos-)?world-daily\""));
def extract_request:
  (ltrim_js | test("\\A[$/](?:world:|skill:)?world-source-extract(?![A-Za-z0-9_])"))
  or (contains("<command-name>/") and test("<command-name>/(?:world:)?world-source-extract</command-name>"))
  or skill_directory("world-source-extract")
  or (ltrim_js | test("\\A<skill name=\"world-source-extract\""));
def self_report: daily_request or extract_request;
def daily_write($name; $args):
  ($name | type) == "string" and ($name | endswith("world_record_event"))
  and ($args | if type == "string" then . elif . == null then "{}" else tojson end | contains("【日进展"));

# ---------- 逐行读取：index.mjs 的 rows/decodeRow ----------

# 孤立代理项的 \u 转义 JSON.parse 收、jq 不收。读不进时把它们换成 U+10FFFF（非字符）再读一次，并给这一行记上标记；
# 由这一行出的条目原文里有 U+10FFFF，就是库会判为不合法的原文（isWellFormed 为假）。
def fix_lone:
  gsub("(?<p>(?<!\\\\)(?:\\\\\\\\)*)(?:(?<pair>\\\\u[dD][89abAB][0-9a-fA-F]{2}\\\\u[dD][c-fC-F][0-9a-fA-F]{2})|\\\\u[dD][89a-fA-F][0-9a-fA-F]{2})";
    .p + (.pair // "\\udbff\\udfff"));
# TextDecoder 每行去掉开头一个 BOM；JSON.parse 不认第二个 BOM，jq 却会跳过，所以第二个也判为读不出。
def parse_line:
  (if startswith("\ufeff") then .[1:] else . end)
  | if startswith("\ufeff") then null
    else . as $line | (try {row: fromjson, lone: false} catch ($line | try {row: (fix_lone | fromjson), lone: true} catch null))
    | if . != null and (.row | type) == "object" then . else null end
    end;

def bump($code): .issues[$code] = ((.issues[$code] // 0) + 1);

# ---------- Claude：adapters.mjs 的 claude() ----------
# 状态：recognized、daily。每段增量读完时把 pending（这一轮到目前为止最后的答复）交出并清空，等于库在这个位置读完整个文件。

def claude_step($r; $n; $lone):
  $r.type as $t
  | (if ($r.sessionId | type) == "string" and ($t == "user" or $t == "assistant") then .state.recognized = true else . end)
  | if ($r.isSidechain | truthy) or ($t != "user" and $t != "assistant") then .
    else ($r.message | field("content")) as $content
    | if ($content | known_content | not) then bump("parse_failed")
      else [$content | text_blocks(["text"])[] | select(blank_js | not)] as $texts
      | ([($r.message | field("id")), $r.uuid, $r.timestamp] | map(select(. != null))) as $ids
      | (if ($r | has("sessionId")) then ($r.sessionId | jsstr) else "undefined" end) as $session
      | (if ($ids | length) > 0 then ($ids[0] | jsstr) else ($n | tostring) end) as $key
      | def make($role; $text): {role: $role, text: $text, raw: $r.timestamp, lone: $lone, id: "\($session)/\($role)/\($key)"};
        if ($texts | any(self_report)) or (($content | type) == "array" and ($content | any(.[]; .type == "tool_use" and daily_write(.name; .input))))
        then (if .pending != null and (.state.daily | not) then .out += [.pending] else . end) | .pending = null | .state.daily = true
        elif $t == "assistant" and ($texts | length) > 0 and (.state.daily | not) then .pending = make("assistant"; $texts[-1])
        elif $t == "user" and ($r.isMeta | truthy | not) then
          [$texts[] | select(real_request)] as $requests
          | if ($requests | length) > 0
            then (if .pending != null then .out += [.pending] else . end) | .pending = null | .state.daily = false
              | .out += [make("user"; $requests | join("\n"))]
            else . end
        else . end
      end
    end;

def claude_finish: (if .state.recognized and .pending != null then .out += [.pending] else . end) | .pending = null | .recognized = .state.recognized;

# ---------- Codex：adapters.mjs 的 codex() ----------
# 状态：session、subagent、两种消息各自见过的最高优先级、daily。优先级按到目前为止读过的全部内容取最大，库按整份文件取。

def codex_messages($r; $n; $lone):
  ($r.payload) as $p | ($p | field("type")) as $pt | $r.timestamp as $ts
  | def add($role; $text; $priority; $id):
      {role: $role, text: $text, priority: $priority, raw: $ts, lone: $lone,
       id: (if $id != null then $id elif $ts != null then $ts else "line-\($n)" end)};
    [
      (if $r.type == "event_msg" and $pt == "user_message" and ($p.message | type) == "string" then add("user"; $p.message; 1; null) else empty end),
      (if $r.type == "event_msg" and $pt == "task_complete" and ($p.last_agent_message | type) == "string"
        then add("assistant"; $p.last_agent_message; 1; $p.turn_id) else empty end),
      (if $r.type == "event_msg" and $pt == "item_completed" and ($p.item | truthy) then
        ($p.item) as $item | ($item | field("type")) as $it
        | (if $it == "UserMessage" then ($item | field("content") | text_blocks(["text"])[]) as $x | add("user"; $x; 2; $item.id) else empty end),
          (if $it == "AgentMessage" and ($item | field("phase")) == "final_answer"
            then ($item | field("content") | text_blocks(["text", "Text"])[]) as $x | add("assistant"; $x; 2; $item.id) else empty end),
          (if $it == "McpToolCall" and daily_write($item.tool; $item.arguments) then add("daily"; ""; 0; null) else empty end)
        else empty end),
      (if $r.type == "response_item" and $pt == "message" then
        (if $p.role == "user" then ($p.content | text_blocks(["input_text"])[]) as $x | add("user"; $x; 0; null) else empty end),
        (if $p.role == "assistant" and ($p.phase == "final_answer" or $p.channel == "final")
          then ($p.content | text_blocks(["output_text"])[]) as $x | add("assistant"; $x; 0; null) else empty end)
        else empty end),
      (if $r.type == "response_item" and ($pt == "function_call" or $pt == "custom_tool_call")
        and daily_write($p.name; (if $p.arguments == null then $p.input else $p.arguments end)) then add("daily"; ""; 0; null) else empty end)
    ];

def codex_step($r; $n; $lone):
  (if $r.type == "session_meta" then
    ($r.payload) as $p
    | .state.session = ($p | field("id"))
    | .state.subagent = (($p | field("thread_source")) == "subagent" or ($p | field("source") | field("subagent") | truthy))
   else . end)
  | .msgs += codex_messages($r; $n; $lone);

def codex_finish:
  .state.up = ([.state.up, (.msgs[] | select(.role == "user") | .priority)] | max)
  | .state.ap = ([.state.ap, (.msgs[] | select(.role == "assistant") | .priority)] | max)
  | .recognized = ((.state.session | type) == "string")
  | .state.session as $session | .state.up as $up | .state.ap as $ap
  | reduce .msgs[] as $m (.;
      if $m.role == "daily" or ($m.role == "user" and $m.priority == $up and ($m.text | self_report)) then .state.daily = true
      elif $m.role == "user" and $m.priority == $up and ($m.text | real_request) then
        .state.daily = false | .out += [$m + {id: "\($session)/user/\($m.id | jsstr)"}]
      elif $m.role == "assistant" and $m.priority == $ap and (.state.daily | not) and ($m.text | blank_js | not) then
        .out += [$m + {id: "\($session)/assistant/\($m.id | jsstr)"}]
      else . end)
  | if .state.subagent then .out = [] else . end
  | .msgs = [];

# ---------- 各阶段，capture.sh 按顺序调用 ----------

def initial_state($format):
  if $format == "claude-session-jsonl/1" then {recognized: false, daily: false}
  else {session: null, subagent: false, up: -1, ap: -1, daily: false} end;

# config.json 里这种 Agent 的那一项；合用时输出三行：source_id、历史起点(UTC)、确认过的文件夹（只读它下面的会话），
# 否则什么都不输出。folder 是「开始采集」时 setup.jq 按数据目录写的绝对路径。
def config_entry($agent; $format):
  (field("agents") | field($agent)) as $e
  | ($e | field("history_from") | utc) as $from
  | if ($e | type) == "object" and $e.format == $format and $from != null
      and ($e.selection_id | type) == "string" and ($e.selection_id | test("\\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\z"))
      and ($e.selection_version | type) == "number" and $e.selection_version >= 1 and $e.selection_version == ($e.selection_version | floor)
      and ($e.source_id | type) == "string" and ($e.source_id | test("\\A[A-Za-z0-9][A-Za-z0-9._:/@+~-]{0,199}\\z"))
      and ($e.folder | type) == "string" and ($e.folder | startswith("/")) and ($e.folder | explode | all(. >= 32))
    then "\($e.source_id)\n\($from)\n\($e.folder)" else empty end;

# 钩子 stdin 上的 JSON：配置合用时输出 transcript_path。
def hook_transcript($config; $agent; $format):
  if ([$config[0] | config_entry($agent; $format)] | length) == 1 and (field("transcript_path") | type) == "string"
  then .transcript_path else empty end;

# 上次的位置文件：合用时输出「offset head_bytes head_sha256 lines」。
def position_line($format; $path):
  if type == "object" and .format == $format and .path == $path
    and ([.offset, .head_bytes, .lines] | all(type == "number" and . >= 0 and . == floor))
    and (.head_sha256 | type) == "string" and (.head_sha256 | test("\\A[0-9a-f]{64}\\z")) and (.state | type) == "object"
  then "\(.offset) \(.head_bytes) \(.head_sha256) \(.lines)" else empty end;

# 读一段只含完整行的增量。用 --rawfile 整段读进来再按换行切：jq 1.7.1 的 -R 在它的读缓冲边界上会把多字节字符
# 切坏、换成 U+FFFD（长行里实测到），--rawfile 不会。$bad 是 UTF-8 不合法的行在这段里的序号（从 1 起）。
def parse($format; $from; $base; $previous; $bad; $data):
  ($bad | map({(tostring): true}) | add // {}) as $invalid
  | (if $previous == null then initial_state($format) else $previous.state end) as $state
  | reduce ($data | split("\n") | .[:-1][]) as $line ({state: $state, pending: null, msgs: [], out: [], issues: {}, n: $base};
      .n += 1
      | if $line == "" then .
        elif $invalid[(.n - $base) | tostring] then bump("parse_failed")
        else ($line | parse_line) as $parsed
        | if $parsed == null then bump("parse_failed")
          elif $format == "claude-session-jsonl/1" then claude_step($parsed.row; .n; $parsed.lone)
          else codex_step($parsed.row; .n; $parsed.lone) end
        end)
  | (if $format == "claude-session-jsonl/1" then claude_finish else codex_finish end)
  # 与 index.mjs 相同的筛选：原文不合法的整份文件不交（这里只丢这一条），没有可用时刻的是覆盖缺口，早于历史起点的丢掉。
  | reduce .out[] as $e (. + {entries: []};
      ($e.raw | utc) as $at
      | if $e.lone and ($e.text | contains("\udbff\udfff")) then bump("text_not_well_formed")
        elif $at == null then bump("time_unknown")
        elif before($at; $from) then .
        else .entries += [{id: $e.id, role: $e.role, text: $e.text, raw: $e.raw, reported_at: $at}] end)
  | {recognized, lines: .n, state, issues, entries};

# 每条两行：sha256 的输入 "<格式>:<条目 id>"（含换行或 NUL 的输出空行，由 capture.sh 另写），和 JSON.stringify([role, text, reported_at])。
def hash_inputs($format):
  .entries[] | ($format + ":" + .id | if explode | any(. == 10 or . == 0) then "" else . end),
    "[" + (.role | jsq) + "," + (.text | jsq) + "," + (.raw | jsq) + "]";

def slow_ids: .entries | to_entries[] | select(.value.id | explode | any(. == 10 or . == 0)) | .key;

# 第一行是新的位置文件，之后每个新条目一行「<文件名>\t<JSON>」。队列里已有的、已送出的不再输出。
def assemble($r; $previous; $hashes; $queued; $delivered; $meta):
  ($hashes | split("\n") | map(capture("\\A(?<h>[0-9a-f]{64}) \\*(?<n>[0-9]+)\\z")? | {(.n): .h}) | add // {}) as $digest
  | ($queued | split("\n") | map(select(length > 0) | {(.): true}) | add // {}) as $inQueue
  | ($delivered | split("\n") | map((try fromjson catch null) | select(type == "object")
      | {"\(.item_id)@\(.item_version).json": true}) | add // {}) as $done
  | ([($previous // {}).issues // {}, $r.issues] | map(to_entries[]) | group_by(.key) | map({(.[0].key): (map(.value) | add)}) | add // {}) as $issues
  | ({path: $meta.path, format: $meta.format, offset: $meta.offset, size: $meta.size, mtime: $meta.mtime,
      head_bytes: $meta.head_bytes, head_sha256: $meta.head_sha256, lines: $r.lines, state: $r.state, issues: $issues,
      updated_at: $meta.now} | tojson),
    ($r.entries | to_entries | map(
        ("entry-" + $digest["\(2 * .key + 1)"]) as $item | $digest["\(2 * .key + 2)"] as $version
        | .value + {item_id: $item, item_version: $version, name: "\($item)@\($version).json",
            locator: "local-capture:\($meta.source_id)/\($item)@\($version)"})
      | map(select($inQueue[.name] != true and $done[.name] != true)) | unique_by(.name)[]
      | "\(.name)\t\({item_id, item_version, locator, role, reported_at, text, first_seen_at: $meta.now} | tojson)");

# 起轮决定：最早入队的一条等了 30 分钟以上，或会话结束；队列空时不起。输入是各队列文件里的 first_seen_at 字段。
def decision($agent; $event; $format; $at):
  [inputs | capture("\"first_seen_at\":\"(?<t>[^\"]*)\"").t] as $seen
  | ($seen | min) as $oldest
  | ($oldest | if . == null then null else (try fromdateiso8601 catch null) end) as $since
  | (if ($seen | length) == 0 then null elif $event == "SessionEnd" then "session_end"
     elif $since != null and (now - $since) >= 1800 then "waited" else null end) as $reason
  | {agent: $agent, event: $event, format: $format, due: ($reason != null), reason: $reason, queued: ($seen | length),
     oldest_first_seen_at: $oldest, decided_at: $at};
