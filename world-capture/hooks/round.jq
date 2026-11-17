# capture.sh 后台轮的数据部分：排批、拼提示词、解析两种 CLI 的输出、核对判断、拼送出骨架和运行回执。
# 文件读写、加锁、起 CLI 都在 capture.sh；这里只有纯函数，capture.ps1 里是同一套规则的 PowerShell 写法。
include "capture";

def CLAUDE_PREFIX: "mcp__plugin_world_world__";
def TOOLS: {judge: ["world_app_sources_read", "world_app_sources_targets"],
  send: ["world_app_sources_ingest", "world_app_sources_imports"], report: ["world_app_sources_report_run"]};
# 一轮最多 5 批、每批 20 条（同组件）；每条原文最多交 8000 字，一批原文合计最多 60000 字，超了这一批就少放几条。
# 读回导入每页 10 条：一页太大时 Claude Code 只给模型看一句「输出太大、已存到文件」（约 50 KB 起，实测），模型就看不到 next_cursor 翻不了页。
def LIMITS: {batches: 5, batch: 20, item_chars: 8000, batch_chars: 60000, increment: 50, increments: 5, readback_pages: 20, readback_page: 10, pending: 200};
def ITEM_FIELDS: ["classification", "target_ref", "field_key", "value", "quote", "occurred_at", "links", "source_event_ref", "constraint"];

def name: "\(.item_id)@\(.item_version)";
def delivered_set($raw): $raw | split("\n") | map((try fromjson catch null) | select(type == "object") | {(name): true}) | add // {};

def fill($values): reduce ($values | to_entries[]) as $v (.; split("{{\($v.key)}}") | join($v.value));

# 原文太长时留头 6000 字、尾 2000 字，中间换成 round-prompt.md 里 omitted 那一句；判断只看这一份，不改队列里的原文。
def clipped($omitted):
  if (.text | length) <= LIMITS.item_chars then . else
    .text as $t | . + {text: ($t[:6000] + "\n" + ($omitted | fill({n: ($t | length - 8000 | tostring)})) + "\n" + $t[-2000:]),
      truncated: ($t | length)} end;

# 这一轮要做的事。$queue 是队列文件的内容，$results 是 results/ 里各文件（{name, value}），$delivered 是 delivered/<格式>.jsonl。
# - settle：已判为 null 还没记进 delivered 的（上一轮中途断了），直接记。
# - judge：没有判断、或上次被 world 拒了要重判的，按 5 批 × 20 条排好。
# - send：已有判断（非 null）的，按每份骨架 50 条切好；readback：上次报 IDEMPOTENCY_CONFLICT 的，要先读回。
# - stale：results/ 里条目已不在待提炼的文件，删掉。
def plan($queue; $results; $delivered; $omitted):
  delivered_set($delivered) as $done
  | ($results | map({(.name): .value}) | add // {}) as $stored
  | [$queue[] | select(type == "object" and (.item_id | type) == "string") | . + {name: name} | select($done[.name] | not)]
  | unique_by(.name) | sort_by(.first_seen_at, .reported_at, .item_id) as $open
  | ($open | map({(.name): true}) | add // {}) as $isOpen
  | [$open[] | . as $e | $stored[$e.name] as $s | $e + {stored: $s}] as $rows
  | {
      backlog: ($open | length),
      pending: [$open[] | {item_id, item_version}],
      settle: [$rows[] | select(.stored != null and (.stored | has("result")) and .stored.result == null)
        | {name, item_id, item_version, dropped: .stored.dropped}],
      judge: ([$rows[] | select(.stored == null or (.stored | has("result") | not))
          | {name, item_id, item_version, role, reported_at, text}
            + (if .stored.rejected then {rejected: .stored.rejected[-1].code, attempt: (.stored.attempt // 1)} else {} end)
          | clipped($omitted)]
        | reduce .[] as $e ({batches: [], current: [], chars: 0};
            if (.batches | length) >= LIMITS.batches then .
            elif (.current | length) > 0 and ((.current | length) >= LIMITS.batch or .chars + ($e.text | length) > LIMITS.batch_chars)
            then .batches += [.current] | .current = [$e] | .chars = ($e.text | length)
            else .current += [$e] | .chars += ($e.text | length) end)
        | (.batches + (if (.current | length) > 0 then [.current] else [] end))[:LIMITS.batches]),
      send: ([$rows[] | select(.stored != null and (.stored | has("result")) and .stored.result != null and (.stored.conflict | not))
          | {name, item_id, item_version, locator, reported_at, result: .stored.result, stored}][:LIMITS.increment * LIMITS.increments]
        | [range(0; length; LIMITS.increment) as $i | .[$i:$i + LIMITS.increment]]),
      readback: [$rows[] | select(.stored.conflict) | {name, item_id, item_version, stored}],
      # results/ 里条目已不在待提炼的，和已记进 delivered 却还留着的队列文件（上一轮记完 delivered 后断了）。
      stale: ([$stored | keys[] | select($isOpen[.] | not)]
        + [$queue[] | select(type == "object" and (.item_id | type) == "string") | name | select($done[.])] | unique)
    };

# ---------- 落盘 ----------
# capture.sh 的 apply_effects 按 deliver（追加进 delivered）、remove（删队列文件和 results/）、write（写 results/）的顺序做。
# write 的 mode 为 new 时只在 results/ 还没有这一条时写，已有的判断不改。

def delivered_line($row; $status; $round; $at; $extra):
  {item_id: $row.item_id, item_version: $row.item_version, import_id: ($extra.import_id // null), status: $status, round_id: $round, at: $at}
  + ($extra | del(.import_id)) | tojson;

def settle_effects($plan; $round; $at):
  {deliver: [$plan.settle[] | delivered_line(.; (if .dropped then "dropped" else "null" end); $round; $at; (if .dropped then {code: .dropped} else {} end))],
   remove: ([$plan.settle[].name] + $plan.stale), write: []};

# 判断轮交回的：合规的照收；不合规的算被拒一次（invalid_increment），第二次就当 null，免得一直重判。
def judge_effects($format; $round; $at):
  {deliver: [], remove: [],
   write: ([.accepted[] | {name, mode: (if .attempt then "replace" else "new" end),
       value: {format: $format, item_id, item_version, result, attempt: ((.attempt // 0) + 1), round_id: $round, judged_at: $at}}]
     + [.invalid[] | ((.attempt // 0) + 1) as $n | {name, mode: (if .attempt then "replace" else "new" end), value: (
         if $n >= 2 then {format: $format, item_id, item_version, result: null, dropped: "invalid_increment", attempt: $n, round_id: $round, judged_at: $at}
         else {format: $format, item_id, item_version, rejected: [{code: "invalid_increment", round_id: $round}], attempt: $n} end)}])};

# 送出之后：收到回执的记 imported（带导入 id）；被拒的下一轮带着 code 重判，已经判过两次的当 null；
# 报 IDEMPOTENCY_CONFLICT 的整份骨架标上 conflict，下一轮先读回；读回找到的记 conflict（带导入 id），读完没找到的去掉标记照常重送。
def send_effects($plan; $outcome; $round; $at):
  ([$plan.send[][]] | map({(.name): .}) | add // {}) as $rows
  | ([$outcome.increments[]? | . as $inc
      | ($inc.imports | map({(.name): .import_id}) | add // {}) as $got
      | ($inc.rejected | map({(.name): .code}) | add // {}) as $why
      | $inc.items[] | select($rows[.] != null) | $rows[.] as $row
      | if $got[.] then {kind: "imported", row: $row, import_id: $got[.], mismatch: ($inc.exact | not)}
        elif $why[.] then {kind: "rejected", row: $row, code: $why[.]}
        elif $inc.error == "IDEMPOTENCY_CONFLICT" then {kind: "conflict", row: $row}
        else empty end]
    + [$plan.readback[] | . as $row | ($outcome.readback.found // {})[$row.name] as $id
      | if $id then {kind: "read_back", row: $row, import_id: $id}
        elif $outcome.readback.complete == true then {kind: "unflag", row: $row} else empty end]) as $all
  | ($all | map(select(.kind == "imported" or .kind == "read_back" or (.kind == "rejected" and (.row.stored.attempt // 1) >= 2)))) as $done
  | {deliver: [$done[] | delivered_line(.row; ({imported: "imported", read_back: "conflict", rejected: "dropped"}[.kind]); $round; $at;
        {import_id} + (if .mismatch then {copy_mismatch: true} else {} end) + (if .code then {code} else {} end))],
     remove: [$done[].row.name],
     write: [$all[] | select((.kind == "rejected" and (.row.stored.attempt // 1) < 2) or .kind == "conflict" or .kind == "unflag")
       | {name: .row.name, mode: "replace", value: (
           if .kind == "rejected" then {format: .row.stored.format, item_id: .row.item_id, item_version: .row.item_version,
               rejected: ((.row.stored.rejected // []) + [{code, round_id: $round}]), attempt: (.row.stored.attempt // 1)}
           elif .kind == "conflict" then .row.stored + {conflict: $round}
           else .row.stored | del(.conflict) end)}]};

# ---------- 提示词 ----------

# round-prompt.md 里 <!-- judge --> 这类标记之后、下一个标记之前的一段。
def prompt_section($text; $kind):
  $text | split("<!-- \($kind) -->")[1] // "" | split("\n<!-- ")[0] | sub("^\\s+"; "") | sub("\\s+$"; "");

# world-source-extract 技能里 rules-from 那一段列出的各节（「什么值得记」「逐条提炼」），按技能里的顺序原样交给判断轮。
def skill_rules($skill; $names):
  ($names | split("\n") | map(select(length > 0))) as $wanted
  | [$skill | split("\n## ")[] | . as $part | select(any($wanted[]; . as $n | $part | startswith($n + "\n")))] as $kept
  | if ($kept | length) == ($wanted | length) then $kept | map("## " + .) | join("\n") | sub("\\s+$"; "") else null end;

def since($batch): $batch | map(.reported_at[0:19] + "Z" | fromdateiso8601) | min - 86400 | todate;

def code_block: "```json\n" + tojson + "\n```";

def judge_prompt($template; $rules; $config; $batch):
  ($template | fill({rules: $rules, batch: ({selection_id: $config.selection_id, selection_version: $config.selection_version,
     since: since($batch), items: [$batch[] | del(.name, .attempt)]} | code_block)})) + "\n";

def send_prompt($template; $readbackStep; $ingestStep; $config; $increments; $readback):
  ([if ($readback | length) > 0 then
      $readbackStep | fill({pages: (LIMITS.readback_pages | tostring), args: ({selection_id: $config.selection_id, limit: LIMITS.readback_page} | code_block)})
    else empty end]
   + [$increments[] | code_block as $args | $ingestStep | fill({args: $args})]) as $steps
  | ($template | fill({steps: ([$steps | to_entries[] | "\(.key + 1). \(.value)"] | join("\n\n"))})) + "\n";

def report_prompt($template; $args): ($template | fill({args: ($args | code_block)})) + "\n";

# ---------- 两种 CLI 的输出 ----------

def body: if type == "string" then (try fromjson catch null) else null end;
def first_text: if type == "string" then . elif type == "array" then (map(select(type == "object" and .type == "text") | .text) | first) else null end;

# claude -p --output-format stream-json --verbose 的每一行。init 里有 world 连接的状态，result 里有用量与最终答复。
def parse_claude:
  (map(select(.type == "system" and .subtype == "init")) | first) as $init
  | (map(select(.type == "result")) | last) as $result
  # 工具返回超过约 50 KB 时，content 里只剩一句「已存到文件」，完整的返回在这一行的 tool_use_result 里（实测）。
  | ([.[] | select(.type == "user") | .tool_use_result as $full | [.message.content[]? | select(type == "object" and .type == "tool_result")]
        | if length == 1 and $full != null then [.[0] + {content: $full}] else . end | .[]]
      | map({(.tool_use_id | tostring): .}) | add // {}) as $outs
  | {
      events: length,
      mcp: (if $init == null then null else ($init.mcp_servers // []) | map(select(.name == "plugin:world:world")) | first | .status // "missing" end),
      calls: [.[] | select(.type == "assistant") | .message.content[]? | select(type == "object" and .type == "tool_use")
        | select(.name | startswith(CLAUDE_PREFIX)) | $outs[.id | tostring] as $out
        | {tool: (.name | ltrimstr(CLAUDE_PREFIX)), args: .input, text: ($out.content | first_text),
           failed: ($out == null or $out.is_error == true)}],
      denied: [($result.permission_denials // [])[] | .tool_name],
      final: (if ($result.result | type) == "string" then $result.result else null end),
      errors: [if $result.is_error == true then ($result.result // "error" | tostring) else empty end],
      api_status: $result.api_error_status,
      usage: ($result.usage | if type == "object" then {
          input_tokens: ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)),
          cached_input_tokens: (.cache_read_input_tokens // 0), output_tokens: (.output_tokens // 0)} else null end)
    };

# codex exec --json 的每一行。world 连接设成 required，连不上时 codex 不起会话、只在标准错误里说。
def parse_codex:
  {
    events: length,
    mcp: null,
    calls: [.[] | select(.type == "item.completed" and .item.type == "mcp_tool_call" and .item.server == "world") | .item
      | {tool, args: .arguments, text: (.result.content | first_text), failed: (.status != "completed" or .error != null)}],
    denied: [],
    final: ([.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | last),
    errors: ([.[] | select(.type == "error") | .message] + [.[] | select(.type == "turn.failed") | .error.message]
      + [.[] | select(.type == "item.completed" and .item.type == "error") | .item.message] | map(tostring)),
    api_status: null,
    usage: ([.[] | select(.type == "turn.completed") | .usage] | if length == 0 then null else
      {input_tokens: (map(.input_tokens // 0) | add), cached_input_tokens: (map(.cached_input_tokens // 0) | add),
       output_tokens: (map(.output_tokens // 0) | add)} end)
  };

# 失败分五类（ADR 决定九）：找不到程序、账号或登录失效、world 工具不可用、网络、其他。$stderr 是标准错误的末尾一段。
def classify($agent; $status; $timeout; $stderr):
  ((.errors | join("\n")) + "\n" + ($stderr // "")) as $text
  | if $timeout then {class: "other", detail: "timeout"}
    elif $status == 126 or $status == 127 then {class: "program_missing", detail: "exit \($status)"}
    elif $agent == "claude" and (.api_status == 401 or .api_status == 403) then {class: "login_invalid", detail: "api \(.api_status)"}
    elif ($text | test("required MCP servers failed to initialize"; "")) then
      (if ($text | test("error sending request|dns error|[Cc]onnection refused|timed out|[Nn]etwork"; "")) then {class: "network", detail: "world"}
       else {class: "world_unavailable", detail: "mcp_not_ready"} end)
    elif ($text | test("401 Unauthorized|403 Forbidden|[Ii]nvalid API key|/login|[Nn]ot logged in|log in again|refresh token|suspended|authentication_error"; ""))
      then {class: "login_invalid", detail: "auth"}
    elif ($text | test("error sending request|stream disconnected|[Cc]onnection refused|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|Unable to connect|fetch failed|getaddrinfo"; ""))
      then {class: "network", detail: "model"}
    elif .events == 0 then {class: "other", detail: "output_unreadable"}
    elif $agent == "claude" and .mcp != "connected" then {class: "world_unavailable", detail: "mcp_\(.mcp)"}
    elif $status != 0 then {class: "other", detail: "exit \($status)"}
    else null end;

# ---------- 判断轮的结果 ----------

def bounded_text($min; $max): type == "string" and length >= $min and length <= $max;
def valid_item:
  type == "object" and ((keys - ITEM_FIELDS) | length) == 0
  and (.classification | IN("fact", "decision", "suggestion", "question", "unknown"))
  and (.target_ref == null or (.target_ref | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@[1-9][0-9]*$")))
  and (.field_key == null or (.field_key | bounded_text(1; 300)))
  and (.value == null or (.value | bounded_text(0; 4000) or (type == "array" and length <= 50 and all(.[]; bounded_text(0; 2048)))))
  and (.quote == null or (.quote | bounded_text(1; 2000)))
  and (.occurred_at == null or (.occurred_at | type == "string"
    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$")))
  and (.links == null or (.links | type == "array" and length <= 20 and all(.[]; bounded_text(1; 2048))))
  and (.source_event_ref == null or (.source_event_ref | type == "string" and test("^event:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
  and (.constraint == null or (.constraint | IN("none", "upstream_blocked", "pending_contract_unverified")));

def tool_body($tool): [.calls[] | select(.tool == $tool and (.failed | not)) | .text | body] | last;
def tool_error($tool): [.calls[] | select(.tool == $tool) | (.text | body | .error.code // null) // (if .failed then "tool_failed" else null end)] | map(select(. != null)) | last;
def answer: (.final // "") | (capture("(?<j>\\{[\\s\\S]*\\})") // null) | if . == null then null else (.j | try fromjson catch null) end;

# 只认这一次调用里真的读到了生效的选择和非空的目标：world 连不上时模型照样会交一份全是 null 的结果，不能收。
def judge_outcome($batch; $config):
  ($batch | map({(.name): .}) | add) as $by
  | tool_body("world_app_sources_read").selection as $selection
  | tool_body("world_app_sources_targets").targets as $targets
  | if $selection == null or ($targets | type) != "array" then
      {failure: {class: (if (tool_error("world_app_sources_read") // tool_error("world_app_sources_targets")) == "HTTP_UNAVAILABLE" then "network" else "world_unavailable" end),
        detail: (tool_error("world_app_sources_read") // tool_error("world_app_sources_targets") // "tools_not_called")}}
    elif $selection.selection_id != $config.selection_id or $selection.status != "active" or $selection.version != $config.selection_version then
      {failure: {class: "other", detail: "selection_changed"}}
    elif ($targets | length) == 0 then {failure: {class: "other", detail: "targets_empty"}}
    elif (answer | .results | type) != "array" then {failure: {class: "other", detail: "answer_unreadable"}}
    else answer.results
      | reduce .[] as $r ({failure: null, accepted: [], invalid: [], mismatches: [], seen: {}};
          (if ($r | type) == "object" then "\($r.item_id)@\($r.item_version)" else "" end) as $key
          | if $by[$key] == null then .mismatches += [{item_id: ($r.item_id? // null), item_version: ($r.item_version? // null), reason: "not_in_batch"}]
            elif .seen[$key] then .mismatches += [{item_id: $r.item_id, item_version: $r.item_version, reason: "duplicate"}]
            elif ($r | has("result") | not) then .mismatches += [{item_id: $r.item_id, item_version: $r.item_version, reason: "no_result"}] | .seen[$key] = true
            elif $r.result == null then .accepted += [$by[$key] + {result: null}] | .seen[$key] = true
            elif ($r.result | valid_item) then .accepted += [$by[$key] + {result: ($r.result | with_entries(select(.value != null)))}] | .seen[$key] = true
            else .invalid += [$by[$key]] | .seen[$key] = true end)
      | .unanswered = ([$batch[].name] - (.seen | keys))
      | del(.seen) end;

# ---------- 送出 ----------

def increments($groups; $config; $round):
  [$groups | to_entries[] | .key as $k | .value as $group
    | {selection_id: $config.selection_id, selection_version: $config.selection_version,
       increment: {format: "world-source-increment/0.1", source_id: $config.source_id, snapshot_version: "queue-\($round)",
         batch_id: "batch-\($round)-\($k + 1)",
         source_ready_at: (reduce ($group[] | .reported_at) as $t (null; if . == null or before(.; $t) then $t else . end)),
         items: [$group[] | {item_id, item_version} + .result + {locator}]}}];

def sent_names: [(.args.increment.items // [])[]? | select(type == "object") | name];

# 每份骨架的结果。只认工具返回里的 imports（world 的回执），不认模型自己说的。参数和骨架不一致的也照回执记，另记 copy_mismatch。
def send_outcome($increments):
  .calls as $calls
  | [$calls[] | select(.tool == "world_app_sources_ingest")] as $ingests
  | {
      increments: [$increments | to_entries[] | .key as $k | .value as $inc
        | ($inc.increment.items | map(name)) as $mine
        | ([$ingests[] | select(.args == $inc)] | first) as $exact
        | (if $exact != null then $exact else [$ingests[] | select(sent_names | any(.[]; IN($mine[])))] | first end) as $call
        | ($call.text | body) as $b
        | {index: $k, items: $mine, sent: ($call != null), exact: ($exact != null),
           imports: [($b.imports // [])[] | {name: "\(.source_item_id)@\(.source_version)", import_id, status}],
           error: ($b.error.code // (if $call != null and $b == null then "tool_failed" else null end)),
           rejected: [($b.error.rejected // [])[] | {name: name, code}]}],
      readback: ([$calls[] | select(.tool == "world_app_sources_imports" and (.failed | not)) | .text | body | select(. != null)]
        | {complete: (length > 0 and (last.next_cursor == null)),
           found: ([.[].items[]? | {("\(.source_item_id)@\(.source_version)"): .import_id}] | add // {})}),
      unknown: [$ingests[] | sent_names | select(any(.[]; IN($increments[].increment.items[] | name)) | not)]
    };

# ---------- 运行回执 ----------

def report_args($config; $round; $started; $finished; $plan; $files; $outcome; $taken):
  $plan.backlog as $backlog
  | ([$outcome.increments[]? | select(.sent and .error == null)] | length) as $accepted
  | ([$outcome.increments[]?] | length) as $planned
  | [$outcome.increments[]?.imports[].import_id] as $ids
  | {selection_id: $config.selection_id, request_key: "run-\($round)", selection_version: $config.selection_version, trigger: "source_change",
     observed_at: $started, started_at: $started, finished_at: $finished,
     coverage_status: (if $backlog > 0 then "partial" else "ready" end),
     coverage_code: (if $backlog > 0 then "coverage_incomplete" elif ($ids | length) > 0 then "increment_ready"
       elif $taken > 0 then "no_business_increment" else "no_new_content" end),
     discovered_files: $files.count, read_files: $files.count, read_bytes: $files.bytes,
     issue_count: (if $backlog > 0 then 1 else 0 end), issues: (if $backlog > 0 then [{code: "extraction_pending"}] else [] end),
     pending_count: $backlog, pending: [$plan.pending[:LIMITS.pending][] | {item_id, reason: "extraction_pending", item_version}],
     planned_batches: $planned, accepted_batches: $accepted,
     delivery_status: (if $accepted == $planned then (if $backlog > 0 then "accepted_with_gaps" else "accepted" end)
       elif any($outcome.increments[]?; .error == "SOURCE_ITEMS_REJECTED" or .error == "IDEMPOTENCY_CONFLICT") then "blocked" else "unknown" end),
     import_count: ($ids | length), import_ids: $ids[:1000]};

# ---------- 配置与已装的 world 插件 ----------

# config.json 里这种 Agent 合用的那一项（规则同 capture.jq 的 config_entry），交出后台轮要的三项。
def round_config($agent; $format):
  if ([config_entry($agent; $format)] | length) == 1 then .agents[$agent] | {selection_id, selection_version, source_id} else empty end;

# Claude Code 的 ~/.claude/plugins/installed_plugins.json：world@tkos-world 当前装在哪（用户级优先）。
def installed_world:
  (.plugins["world@tkos-world"] // []) | if type == "array" then . else [] end
  | (map(select(.scope == "user")) + .) | map(.installPath | select(type == "string" and startswith("/"))) | first // empty;

# Codex 的插件缓存目录里 world 的各个版本目录名，取版本号最大的。
def newest_version:
  split("\n") | map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) | sort_by(split(".") | map(tonumber)) | last // empty;

# ---------- 间隔 ----------

# 上一轮开始后至少隔 30 分钟再起；连续失败几轮，间隔就翻几倍，最长 4 小时（ADR 决定九）。输入是这种格式的各轮记录。
def gate($now):
  # 按开始时刻排（同一秒里的两轮 round_id 只差随机后缀，不能单按它排）。
  sort_by(.started_at, .round_id) as $rounds
  | ($rounds | last) as $last
  | ([$rounds | reverse | .[] | .failure != null] | (index(false) // length)) as $failed
  | ([1800 * pow(2; $failed), 14400] | min) as $gap
  | ($last.started_at | if type == "string" then (.[0:19] + "Z" | try fromdateiso8601 catch null) else null end) as $at
  | {failures: $failed, gap_seconds: $gap,
     next_round_at: (if $at == null then null else ($at + $gap | todate) end),
     too_soon: ($at != null and ($now | fromdateiso8601) < $at + $gap)};

# 起轮决定加上组件、间隔与锁：due 仍是队列规则（capture.jq 的 decision），run 才是这次真起不起。
# World Capture 组件正在采集（它的 agent-channel.json 在）时不起：同一时间只有一方送。
def with_gate($gate; $locked; $component):
  . + {run: (.due and ($component | not) and ($gate.too_soon | not) and ($locked | not)),
       blocked: (if .due | not then null elif $component then "component_capturing" elif $locked then "round_running"
         elif $gate.too_soon then "too_soon" else null end),
       failures: $gate.failures, next_round_at: $gate.next_round_at};
