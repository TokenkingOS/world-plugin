# capture.sh 的「开始采集」与迁移：check、enable、import 三个子命令的纯函数部分。文件读写在 capture.sh；
# capture.ps1 里是同一套规则的 PowerShell 写法。选择记录是 world_app_sources_select / _read 交回的 selection；
# 组件的 settings.json、source-<选择>.json、extraction-<选择>.json 的格式照 packages/world-capture-host 和库。
include "capture";

def parsed: if . == "" then null else (try fromjson catch "unreadable") end;
def is_uuid: type == "string" and test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z");
def positive_int: type == "number" and . >= 1 and . == floor;
def hex64: type == "string" and test("\\A[0-9a-f]{64}\\z");
def item_name: "\(.item_id)@\(.item_version)";
def well_formed_item: (.item_id | type) == "string" and (.item_id | test("\\Aentry-[0-9a-f]{64}\\z")) and (.item_version | hex64);

# 确认原话里要逐字出现的词：读的是哪种会话、哪个文件夹、包括以后新开的、持续采集；Codex 还要写明只读没压缩的 .jsonl。
def SCOPE_WORDS: {claude: ["Claude Code", "projects", "以后新开", "持续"], codex: ["Codex", "sessions", ".jsonl", "以后新开", "持续"]};

# 组件的 settings.json（host.mjs 的格式）：合用时交出要用的几项，否则 null。
def component_settings:
  if type == "object" and .format == "world-capture-host/1" and (.device_id | type) == "string" and (.device_id | test("\\A[0-9a-f-]{36}\\z"))
  then {device_id, source_format: (.source_format | if type == "string" then . else null end),
        selection_id: (.selection_id | if is_uuid then . else null end),
        root: (.location | field("root") | if type == "string" then . else null end),
        capture_enabled: (.capture_enabled == true), open_at_login: (.open_at_login != false)}
  else null end;

def config_device: field("device_id") | if type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\\z") then . else null end;

# 这台设备的 id：已有 config.json 的；没有就用组件的（迁移时来源标识要和组件建的选择对得上）；都没有是 null，由调用方新起一个。
def device_choice($config; $settings):
  ($config | config_device) as $c | ($settings | component_settings | field("device_id")) as $s
  | if $c != null then {device: $c, from: "config"} elif $s != null then {device: $s, from: "component"} else null end;

# 来源标识 local-capture-<Agent>-<设备 id> 里的设备 id。
def device_of($agent): ("local-capture-\($agent)-") as $p | if type == "string" and startswith($p) then .[($p | length):] else null end;

# 选择记录对得上这台设备这种 Agent 的本机采集时，交出 config.json 里的那一项和设备 id；否则 {refused: code}。
# $mode 是确认方式：对话里新建的是 current_dialogue，迁移沿用的组件选择是 component_window。$device 为 null 时设备 id 要是 UUID。
def selection_entry($agent; $format; $mode; $device; $folder):
  field("choice") as $c | ($c | field("source")) as $src | ($c | field("history")) as $h | field("confirmation") as $k
  | ($src | field("source_id")) as $sid | ($sid | device_of($agent)) as $own
  | if type != "object" or (.selection_id | is_uuid | not) or (.version | positive_int | not) then {refused: "selection_unreadable"}
    elif .status != "active" then {refused: "selection_not_active"}
    elif ($src | field("adapter")) != "work-increment/0.1" or $own == null or ($sid | test("\\A[A-Za-z0-9][A-Za-z0-9._:/@+~-]{0,199}\\z") | not)
      or ($src | field("locator")) != "local-capture:\($sid)" then {refused: "source_mismatch"}
    elif ($device != null and $own != $device) or ($device == null and ($own | is_uuid | not)) then {refused: "device_mismatch"}
    elif ($c | field("version_scope")) != "authorized_increments" or ($h | field("start_at") | utc) == null or ($h | field("end_at")) != null
      then {refused: "history_mismatch"}
    elif ($k | field("mode")) != $mode then {refused: "confirmation_mismatch"}
    elif $mode == "current_dialogue" and (($k | field("text")) as $t | ($t | type) != "string" or any(SCOPE_WORDS[$agent][]; . as $w | $t | contains($w) | not))
      then {refused: "scope_not_confirmed"}
    else {device: $own, entry: {selection_id, selection_version: .version, source_id: $sid, format: $format, history_from: $h.start_at,
      confirmed_at: ($k | field("confirmed_at")), folder: $folder}} end;

def with_entry($config; $agent; $device; $entry):
  {device_id: $device, agents: ((($config | field("agents")) | if type == "object" then . else {} end) + {($agent): $entry})};

def capturing($agent; $format):
  if ([config_entry($agent; $format)] | length) == 1 then .agents[$agent] | {selection_id, selection_version, history_from, confirmed_at} else null end;

# check：这台机器能不能采、用哪个设备 id 和来源标识、要读的文件夹叫什么（不交路径）、已在采的选择、组件在不在。
def check_view($agent; $format; $configRaw; $settingsRaw; $new; $running; $present; $system; $version; $dataDir; $folder):
  ($configRaw | parsed) as $config | ($settingsRaw | parsed) as $settings
  | device_choice($config; $settings) as $d | (($d | field("device")) // $new) as $device | ($settings | component_settings) as $comp
  | {supported: true, system: $system, os_version: $version, agent: $agent, format: $format, data_dir: $dataDir, folder: $folder,
     folder_present: $present, device_id: $device, device_from: (($d | field("from")) // "new"), source_id: "local-capture-\($agent)-\($device)",
     capturing: ($config | capturing($agent; $format)),
     component: (if $comp == null then null else
       {selection_id: $comp.selection_id, source_format: $comp.source_format, capture_enabled: $comp.capture_enabled, running: $running,
        open_at_login: $comp.open_at_login} end)};

# enable：对话里确认的选择写进 config.json。交出 {refused} 或要写的 config 与回给 Agent 的结果。
def enable_plan($agent; $format; $folder; $configRaw; $settingsRaw; $selectionRaw):
  ($configRaw | parsed) as $config | ($settingsRaw | parsed) as $settings
  | if $config != null and ($config | type) != "object" then {refused: "config_unreadable"} else
    device_choice($config; $settings) as $d
    | ($selectionRaw | parsed | selection_entry($agent; $format; "current_dialogue"; ($d | field("device")); $folder)) as $r
    | if $r.refused then {refused: $r.refused} else
      ($config | field("agents") | field($agent) | field("selection_id")) as $old
      | {config: with_entry($config; $agent; $r.device; $r.entry),
         result: {ok: true, agent: $agent, selection_id: $r.entry.selection_id, selection_version: $r.entry.selection_version,
           history_from: $r.entry.history_from, replaced: (if $old != null and $old != $r.entry.selection_id then $old else null end)}} end end;

def checkpoint_ok: type == "object" and .format == "world-source-run-checkpoint/0.1"
  and (.progress == null or ((.progress | type) == "object" and .progress.format == "world-capture-progress/0.1" and (.progress.entries | type) == "object"));
def extraction_ok($format): type == "object" and .format == "world-capture-extraction/0.1" and .source_format == $format
  and (.pending | type) == "array" and (.results | type) == "array";

# import：迁移组件的选择（只换读的人，不换选择）。组件目录只读；交出 {refused}、{already} 或这次要用的几项。
def import_plan($agent; $format; $configRaw; $settingsRaw; $selectionRaw; $checkpointRaw; $extractionRaw):
  ($configRaw | parsed) as $config | ($settingsRaw | parsed | component_settings) as $s
  | ($selectionRaw | parsed) as $sel | ($checkpointRaw | parsed) as $cp | ($extractionRaw | parsed) as $ex
  | if $s == null then {refused: "component_settings_unreadable"}
    elif $s.source_format != $format then {refused: "component_format_mismatch"}
    elif $s.selection_id == null then {refused: "component_no_selection"}
    elif $s.capture_enabled then {refused: "component_capture_enabled"}
    elif $s.root == null or ($s.root | startswith("/") | not) or ($s.root | explode | any(. < 32)) then {refused: "component_location_unreadable"}
    elif $config != null and ($config | type) != "object" then {refused: "config_unreadable"}
    elif ($config | config_device) != null and $config.device_id != $s.device_id then {refused: "device_mismatch"}
    elif ($sel | field("selection_id")) != $s.selection_id then {refused: "selection_mismatch"}
    else ($sel | selection_entry($agent; $format; "component_window"; $s.device_id; $s.root)) as $r
      | ($config | field("agents") | field($agent)) as $old
      | ([$config | config_entry($agent; $format)] | length == 1) as $configured
      | if $r.refused then {refused: $r.refused}
        elif $configured and $old.selection_id == $s.selection_id then {already: true, selection_id: $s.selection_id}
        elif $configured then {refused: "agent_already_configured"}
        elif $cp != null and ($cp | checkpoint_ok | not) then {refused: "checkpoint_unreadable"}
        elif $ex != null and ($ex | extraction_ok($format) | not) then {refused: "extraction_unreadable"}
        else {already: false, selection_id: $s.selection_id, folder: $s.root, source_id: $r.entry.source_id, from: ($r.entry.history_from | utc),
          config: with_entry($config; $agent; $s.device_id; $r.entry), open_at_login: $s.open_at_login,
          plan_pending: ($cp != null and $cp.pending != null)} end end;

# 组件检查点里已处理的条目（送出的和判为无增量的），还不在 delivered/ 里的，每条一行。
def import_delivered($checkpointRaw; $deliveredRaw; $at):
  ($deliveredRaw | split("\n") | map((try fromjson catch null) | select(type == "object") | {(item_name): true}) | add // {}) as $done
  | ($checkpointRaw | parsed) as $cp
  | [($cp | field("progress") | field("entries") // {}) | to_entries[] | {item_id: .key, item_version: .value} | select(well_formed_item)]
  | map(select($done[item_name] | not)) | unique_by(item_name)[]
  | {item_id, item_version, import_id: null, status: "component", round_id: null, at: $at} | tojson;

def listed($raw): $raw | split("\n") | map(select(length > 0) | sub("\\.json$"; "") | {(.): true}) | add // {};

# 组件交回了、还没送出的结果：条目已在待提炼里、results/ 里还没有这一条的，写成判过一次的判断，每条一行「<文件名>\t<JSON>」。
def import_results($extractionRaw; $queuedRaw; $judgedRaw; $format):
  listed($queuedRaw) as $queued | listed($judgedRaw) as $judged
  | ($extractionRaw | parsed) as $ex
  | [($ex | field("results") // [])[] | select(type == "object" and well_formed_item and has("result"))
      | select($queued[item_name] and ($judged[item_name] | not))] | unique_by(item_name)[]
  | "\(item_name)\t\({format: $format, item_id, item_version, result, attempt: 1, round_id: "import",
      judged_at: (.submitted_at | if type == "string" then . else null end)} | tojson)";

# 组件的待提炼和交回的结果里，补读之后既不在待提炼、也不在已送出的：原文已经读不到，是覆盖缺口。
def import_missing($extractionRaw; $queuedRaw; $deliveredRaw):
  listed($queuedRaw) as $queued
  | ($deliveredRaw | split("\n") | map((try fromjson catch null) | select(type == "object") | {(item_name): true}) | add // {}) as $done
  | ($extractionRaw | parsed) as $ex
  | [(($ex | field("pending") // []) + ($ex | field("results") // []))[] | select(type == "object" and well_formed_item)
      | select(($queued[item_name] | not) and ($done[item_name] | not)) | {item_id, item_version}] | unique_by(item_name);
