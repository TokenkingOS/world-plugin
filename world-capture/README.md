# world-capture 插件

工程包版本：0.1.0。本机采集：Claude Code、Codex 的会话每轮结束时，钩子只读这个会话新增的记录，把条目放进本机队列；攒够了在后台起一轮只带 world 工具的 Agent 判断，再经 world 插件的连接送进 world。要和 `world` 插件一起装：后台那一轮用它的连接（和它的登录），判断规则取它的 `world-source-extract` 技能。

拆成单独的插件，是因为 Codex 在插件里任何一个文件变了以后都要本人重新信任一次钩子；`world` 经常发版，采集逻辑很少变。

- `hooks/claude.json`、`hooks/codex.json`：会话开始（新开或恢复）、每轮结束、会话结束三个钩子。
- `hooks/capture.sh`：macOS 15 及以上，只用系统的 `/bin/sh`、`/usr/bin/jq`、`/usr/bin/openssl`。读取规则在 `hooks/capture.jq`，后台轮的数据部分在 `hooks/round.jq`，「开始采集」与迁移的三个子命令的规则在 `hooks/setup.jq`。
- `hooks/capture.ps1`：Windows PowerShell 5.1（`powershell.exe`），JSON 用 .NET 的 `JavaScriptSerializer`，SHA-256 用 .NET。文件带 UTF-8 BOM，注释以外只有 ASCII。
- `hooks/round-prompt.md`：后台轮的提示词。

## 安装

两个插件来自同一个市场 `tkos-world`，先按市场的 README 装好 `world` 并登录，再装这一个：

```sh
claude plugin install world-capture@tkos-world   # Claude Code
codex plugin add world-capture@tkos-world        # Codex
```

Codex 装好以后第一次开会话会弹「Hooks need review」，选信任；之后 `world-capture` 每次更新也会弹一次。不信任，Codex 的会话就不采集。装好以后在对话里说「开始采集 world 进展」，Agent 按 `world` 插件的 `world-capture-start` 技能核对本机、准备来源选择，本人在对话里确认后它调下面的 `enable` 写本机 `config.json`；没有它，钩子什么都不做。每种 Agent、每台设备一项选择，在哪种 Agent 里确认就是哪种的。

## 命令行

```sh
capture.sh  <claude|codex> <事件>   # 钩子：stdin 是钩子的 JSON：session_id、transcript_path、hook_event_name
capture.ps1 <claude|codex> <事件>
capture.sh  <check|enable|import> <claude|codex> [选择记录文件]   # 「开始采集」那次对话里的 Agent 调用
capture.ps1 <check|enable|import> <claude|codex> [选择记录文件]
```

钩子只读 stdin 里的 `transcript_path`，事件取命令行参数。任何情况下退出码都是 0，标准输出和标准错误都不写：Agent 会解析钩子的标准输出，Stop 钩子输出 `{"decision":"block"}` 会拦住会话。三个子命令见「开始采集与迁移」。

以下情况直接退出，什么都不写：

- 环境变量 `WORLD_AUTO_EXTRACT_ROUND` 非空（后台轮里加载的钩子）。
- sh 版：`uname -s` 是 `MINGW*`、`MSYS*` 或 `CYGWIN*`。装了 Git Bash 的 Windows 会把 Claude Code 那一行钩子整行交给 Git Bash，PowerShell 那段已经跑过。
- Agent 不是 `claude` 或 `codex`，事件名不全是字母。
- `config.json` 不存在，或其中没有这种 Agent 的合用项。
- `transcript_path` 不是绝对路径、不以 `.jsonl` 结尾、不是普通文件，或是符号链接（Windows 上是重解析点）。
- `transcript_path` 不在这一项的 `folder`（「开始采集」时确认过的文件夹）下面。sh 版按实际所在的目录比（`cd -P`），用 `..` 或文件夹里的符号链接绕到外面的不算；ps1 版把路径规范化后比前缀（不区分大小写），并要求从文件夹往下到文件所在目录的每一层都不是重解析点。

钩子拉起脱离的进程后马上返回：sh 版用 `nohup /bin/sh capture.sh __worker …  &`，ps1 版用 `Start-Process -WindowStyle Hidden`，会话文件路径经环境变量 `TKOS_CAPTURE_TRANSCRIPT` 传给新进程。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `TKOS_CAPTURE_HOME` | 本机状态目录。不设时是 `$HOME/.tkos-world/capture`（Windows 是 `%USERPROFILE%\.tkos-world\capture`）。 |
| `TKOS_CAPTURE_FOREGROUND` | 为 `1` 时在钩子进程里直接读，不脱离。测试用。 |
| `TKOS_CAPTURE_DECISION_FILE` | 设了才把起轮决定写到这个路径。测试用。 |
| `TKOS_CAPTURE_JQ` | 只有 sh 版：换掉 `/usr/bin/jq` 的路径。测试用它模拟没有 jq 的机器。 |
| `TKOS_CAPTURE_CLAUDE`、`TKOS_CAPTURE_CODEX` | 后台轮用的程序。不设时在钩子环境的 `PATH` 里找，再找常见的安装位置（Mac 上 `~/.local/bin/claude`、`$CLAUDE_CODE_EXECPATH`、`/Applications/Codex.app`、`/Applications/ChatGPT.app` 里的 codex；Windows 上 `%USERPROFILE%\\.local\\bin\\claude.exe`、`%APPDATA%\\npm\\codex.cmd`）。设了但文件不在，就记「找不到程序」。 |
| `TKOS_CAPTURE_CLAUDE_MODEL` | Claude Code 后台轮的模型，默认 `sonnet`（与原来的自动整理相同）。 |
| `TKOS_CAPTURE_ROUND_LIMIT` | 一轮的硬时限（秒），默认 1200。测试用它把时限调短。 |

## 本机状态目录

目录 0700、文件 0600（sh 版 `umask 077` 加 `chmod`）。Windows 上用 `icacls` 把状态目录收到当前用户和 SYSTEM，子目录和文件继承。所有文件都先写临时文件再改名。

| 路径 | 内容 | 谁写 |
| --- | --- | --- |
| `config.json` | 见下文 | `enable`、`import` 子命令 |
| `import.json` | 迁移那一次的结果，见「开始采集与迁移」 | `import` 子命令 |
| `paused.json` | `reason`、`first_seen_at`、`last_seen_at`：后台轮暂停的原因，现在只有 `component_capturing`（组件正在采集）。原因不在了，下一次钩子删掉它 | 启动脚本 |
| `transcripts/<sha256(路径)>.json` | 位置文件，见下文 | 启动脚本 |
| `queue/<格式>/<item_id>@<item_version>.json` | 待提炼条目，见下文。格式里的 `/` 原样成为一层目录，例如 `queue/claude-session-jsonl/1/` | 启动脚本 |
| `results/<item_id>@<item_version>.json` | 后台轮给这一条的判断，送出前落盘，见「后台轮」 | 持锁的启动脚本 |
| `delivered/<格式>.jsonl` | 已收到 world 回执或已判为无增量的条目，每行一个 JSON 对象：`item_id`、`item_version`、`import_id`、`status`、`round_id`、`at`，见「后台轮」。读增量时只认前两项 | 持锁的启动脚本 |
| `rounds/<round_id>.json` | 每一轮的经过，见「后台轮」。只留最近 400 份 | 持锁的启动脚本 |
| `round.lock/` | 目录，里面的 `owner` 记着持锁进程的 `pid`、`round_id`、`started_at`。一轮结束就删 | 持锁的启动脚本 |
| `work/` | 后台轮里 CLI 的工作目录，一直是空的 | 持锁的启动脚本 |
| `unsupported.json` | `reason`、`system`、`os_version`、`first_seen_at`、`last_seen_at`。机器恢复支持后，下一次钩子删掉它 | 启动脚本 |
| `tmp/` | 每次运行的临时目录，结束时删掉；超过一天的残留由下一次运行删掉 | 启动脚本 |

### config.json

```json
{
  "device_id": "<设备 id>",
  "agents": {
    "claude": {
      "selection_id": "<uuid>",
      "selection_version": 1,
      "source_id": "local-capture-claude-<设备 id>",
      "format": "claude-session-jsonl/1",
      "history_from": "2026-11-17T02:00:00Z",
      "confirmed_at": "2026-11-17T10:00:30+08:00",
      "folder": "/Users/<本人>/.claude/projects"
    },
    "codex": { "format": "codex-rollout-jsonl/1", "folder": "/Users/<本人>/.codex/sessions" }
  }
}
```

一项合用的条件：`format` 等于这种 Agent 的格式（`claude` 对 `claude-session-jsonl/1`，`codex` 对 `codex-rollout-jsonl/1`），`selection_id` 是 UUID，`selection_version` 是正整数，`source_id` 符合库的标识规则，`history_from` 是带时区的显式时刻，`folder` 是绝对路径、不含控制字符。不合用就当没有这一项（没有 `folder` 的也不合用：读的范围要和确认过的对得上）。启动脚本用 `source_id`（拼 locator）、`history_from`（历史过滤）和 `folder`（只读它下面的会话）；`device_id` 是 `check` 给设备 id 的依据，`confirmed_at` 只留作记录。

除了 `folder`，每项都照抄 world 交回的选择记录：`selection_version` 是记录的 `version`，`history_from` 是 `choice.history.start_at`，`confirmed_at` 是 `confirmation.confirmed_at`。`folder` 由子命令按数据目录算，不由 Agent 给：`enable` 时 Claude Code 是 `$CLAUDE_CONFIG_DIR/projects`（没设就是 `~/.claude/projects`），Codex 是 `$CODEX_HOME/sessions`（没设就是 `~/.codex/sessions`；钩子本来就只读 `.jsonl`，压缩过的 `.jsonl.zst` 不读）；`import` 时是组件 `settings.json` 里它读的位置 `location.root`。

### 位置文件

`path`、`format`、`offset`（已读到的字节位置，总在一个换行之后）、`size`、`mtime`（Unix 秒）、`head_bytes`、`head_sha256`、`lines`（已读的行数，空行也算）、`state`（解析器状态）、`issues`（各类缺口的累计条数）、`updated_at`。

- `head_sha256` 是文件开头 `head_bytes` 个字节的摘要，`head_bytes` 取 4096 和已读字节数中较小的那个。只摘已读过的那一段，所以 4 KiB 以内的小文件往后写也不会被误判为改写。
- 文件比 `offset` 小，或开头那一段的摘要变了，就当被改写：位置、状态、`issues` 都从头算，已入队的条目留着。
- 文件大小等于 `offset` 时什么都不读，也不改位置文件。
- `state`：Claude 是 `recognized`、`daily`；Codex 是 `session`、`subagent`、`up`、`ap`（用户消息和最终答复各自见过的最高优先级）、`daily`。
- `issues` 的键：`parse_failed`（读不出的行）、`text_not_well_formed`（原文含孤立代理项的条目）、`time_unknown`（没有可用时刻的条目）。

### 队列文件

`item_id`、`item_version`、`locator`、`role`、`reported_at`、`text`、`first_seen_at`。

- `item_id` 是 `entry-` 加 `sha256("<格式>:<条目 id>")`，`item_version` 是 `sha256(JSON.stringify([role, text, reported_at]))`，这里的 `reported_at` 是会话文件里的原始时刻串。`locator` 是 `local-capture:<source_id>/<item_id>@<item_version>`。
- `reported_at` 是按库的 `utc()` 换算后的 UTC 时刻，`text` 与库交给提炼的原文逐字相同。
- `first_seen_at` 是第一次入队的时刻（UTC，到秒）。同名文件已存在时不重写。
- 条目在 `delivered/<格式>.jsonl` 里或队列里已有同名文件时不入队。脚本先列队列目录、再读 `delivered/`。后台轮要先把条目记进 `delivered/`、再删队列文件，这个顺序下刚送出的条目不会被重新排进来。

## 一次运行做什么

1. 从位置文件记的 `offset` 起读到文件当前大小，只取到最后一个换行为止。末行没写完就留到下次。
2. 逐行解析：空行跳过；每行去掉开头一个 BOM，按 UTF-8 严格解码，按 JSON 解析，要是对象。
3. 每段增量读完时，Claude 把这一轮到目前为止最后的答复交出来；Codex 按到目前为止见过的最高优先级挑表示。
4. 条目原文不合法的丢掉、记 `text_not_well_formed`；没有可用时刻的不入队、记 `time_unknown`；早于 `history_from`（按 UTC 比较，秒以下补零后比）的丢掉。其余的入队。
5. 先写队列文件，再写位置文件。中途断了，下次从旧位置重读，同名条目不会重复。
6. Claude 没有带会话 id 的消息、Codex 还没有 `session_meta` 时，这段增量认不出格式：什么都不写，下次从同一处再读。

## 起轮决定

队列不空，并且事件是 `SessionEnd`（`reason` 为 `session_end`），或最早一条的 `first_seen_at` 已过 30 分钟（`reason` 为 `waited`），这一种格式就该起后台轮（`due`）。真起不起（`run`）还看三条：

- 组件：World Capture 组件的 `agent-channel.json` 在（组件正在采集时才有；Mac 上在 `~/Library/Application Support/World Capture/capture/`，Windows 上在 `%APPDATA%\World Capture\capture\`），就不起，不管组件采的是哪种会话（`blocked` 为 `component_capturing`）。同一时间只有一方送；条目照常排队，原因记进 `paused.json`，不记进 `rounds/`，也不算失败。组件停下以后，下一次钩子照常起轮、删掉 `paused.json`。
- 间隔：这种格式的上一轮开始后至少隔 30 分钟；最近连续失败了几轮，间隔就翻几倍，最长 4 小时（`blocked` 为 `too_soon`）。
- 锁：`round.lock/` 在、而且不比硬时限再老 10 分钟以上，说明另一轮正在跑（`blocked` 为 `round_running`）。两种格式共用这一把锁，同一时间只跑一轮。

设了 `TKOS_CAPTURE_DECISION_FILE` 时把决定写出来：`agent`、`event`、`format`、`due`、`reason`、`queued`、`oldest_first_seen_at`、`decided_at`、`run`、`blocked`、`failures`、`next_round_at`。

## 后台轮

一轮在读增量的那个脱离进程里跑，先建 `round.lock/`（Mac 上 `mkdir`，Windows 上 `New-Item -ItemType Directory`，要么建成、要么失败）。锁比硬时限再老 10 分钟，就当持锁的进程已经不在了，挪开重来。

每次模型调用是一次单独的 `claude -p` 或 `codex exec`，提示词从标准输入交，工作目录是空的 `work/`，环境只带 `HOME`、用户名、系统 `PATH` 加程序所在目录（Windows 上再接上钩子环境的 `PATH`：npm 装的 `codex.cmd` 要找 node，node 不在同一个目录）、`LANG`、临时目录、`CLAUDE_CONFIG_DIR` 或 `CODEX_HOME`（设了才带），以及 `WORLD_AUTO_EXTRACT_ROUND=<round_id>`：后台轮加载的 world 插件的钩子靠它一进来就退出。三种调用各自只放行这几个 world 工具：

| 调用 | 工具 | 做什么 |
| --- | --- | --- |
| 判断 | `world_app_sources_read`、`world_app_sources_targets` | 读选择和所选目标（`since` 是这一批最早的上报时刻往前 24 小时），按规则给每条交 null 或 SourceItem 字段，最后回一个 JSON |
| 送出 | `world_app_sources_ingest`、`world_app_sources_imports` | 把启动脚本算好的骨架原样交给 `world_app_sources_ingest`；上一轮报过 `IDEMPOTENCY_CONFLICT` 的，先用 `world_app_sources_imports` 读回 |
| 回执 | `world_app_sources_report_run` | 把启动脚本算好的运行回执原样交上去 |

判断那一次没有送出的工具，所以判断一定先落盘、再送出。启动脚本从 CLI 的事件流里读工具调用的参数和 world 的返回（Claude Code 用 `--output-format stream-json --verbose`，Codex 用 `--json`），只认 world 的回执，不认模型自己说的。

Claude Code：

```sh
claude -p --no-session-persistence --setting-sources "" --plugin-dir <world 插件的 installPath> --tools "" \
  --allowedTools <这次的工具全名，逗号分隔> --permission-mode dontAsk --output-format stream-json --verbose --model sonnet
```

`installPath` 每次从 `~/.claude/plugins/installed_plugins.json` 的 `world@tkos-world` 取（用户级优先），升级后目录会变。工具全名是 `mcp__plugin_world_world__<工具>`。`claude -p` 每次在 `~/.claude/projects` 下按 `work/` 留一个目录：里面是空的 `memory/`，工具返回超过约 50 KB 时还有 `<会话 id>/tool-results/` 下存的完整返回（`--no-session-persistence` 也存）。这个目录只属于后台轮，每次调用后删掉存下的工具返回，再删空目录，别的文件不动。返回超过约 50 KB 时模型只看到一句「已存到文件」，启动脚本照样从事件流的 `tool_use_result` 读完整的回执。

Codex：

```sh
codex exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only -C <work/> \
  -c features.shell_tool=false -c features.view_image=false -c web_search="disabled" \
  -c tools.experimental_request_user_input.enabled=false -c agents.enabled=false -c features.goals=false \
  -c features.sleep_tool=false -c features.image_generation=false -c features.tool_suggest=false -c features.apps=false \
  -c cloud.skills.enabled=false -c features.code_mode=false \
  -c mcp_servers.world.url="https://world.tokenkingos.com/app/mcp" -c mcp_servers.world.enabled_tools=[<这次的工具>] \
  -c mcp_servers.world.default_tools_approval_mode="approve" -c mcp_servers.world.required=true \
  -c mcp_servers.world.omit_tools_from=["deferred","code_mode"] --json -
```

服务名 `world` 和地址与 world 插件的 `mcp.json` 逐字一致，Codex 按这两样找到本人登录时存下的令牌。`required=true` 让 world 连不上时 codex 直接退出，不白花一次模型调用。判断规则从 `$CODEX_HOME/plugins/cache/tkos-world/world/<版本>/skills/world-source-extract/SKILL.md` 取版本号最大的那份。上面这些开关关掉以后，模型还看得到的只有：选定的 world 工具；codex 0.167 自带模型目录里大多数模型固定开着的 code mode（`exec`、`wait`，在不能访问文件和网络的 JS 环境里组合工具调用），其中嵌着 `apply_patch`（只读沙箱加不批准，写文件会被拒）、MCP 资源的列出与读取、当前时刻。

一轮的步骤，每一步都按已有状态推，中途断了重跑结果相同：

1. 已判为 null 还没记进 `delivered/` 的记上；`results/` 里条目已不在待提炼的、已记进 `delivered/` 却还留着的队列文件，删掉。
2. 判断：没有判断、或上次被 world 拒了要重判的条目，按入队先后排成最多 5 批、每批最多 20 条（原文合计超过 60000 字就少放几条；一条超过 8000 字时只交头 6000 字和尾 2000 字）。每批一次判断调用。只有这次调用里真的读到了生效的选择（`selection_id`、`selection_version` 都对得上、`status` 为 `active`）和非空的目标，才收它的判断：world 连不上时模型照样会交一份全是 null 的结果。合规的判断写进 `results/`（已有的不覆盖），对不上这一批 `item_id`、`item_version` 的、重复的、没交 `result` 的记进这一轮的 `mismatches`，漏判的条目留在队列。字段不合规（多了字段、越界、格式不对）的算被 world 拒了一次（`invalid_increment`）。
3. 判为 null 的记进 `delivered/`（`status` 为 `null`），再删队列文件和 `results/`。
4. 送出：已有判断（非 null）的条目，按每份 50 条拼成骨架：`selection_id`、`selection_version`、`source_id`、`batch_id`、`snapshot_version`、`source_ready_at`（这一份里最晚的上报时刻）和每条的 `item_id`、`item_version`、`locator` 都是启动脚本填的，模型只交判断字段。一轮最多 5 份，一次送出调用。
   - 收到回执的记进 `delivered/`（`status` 为 `imported`，带 `import_id`），再删队列文件和 `results/`。模型交给工具的参数和骨架不一致、world 也收下了的，照回执记，另记 `copy_mismatch`。
   - 422 `SOURCE_ITEMS_REJECTED`：一份骨架在一个事务里，整份不进。被点名的条目带着拒绝的 code 留到下一轮重判；同一条判过两次还被拒，就当 null（`status` 为 `dropped`）。没被点名的原样留到下一轮重送。这一轮不再送第二次。
   - `IDEMPOTENCY_CONFLICT`：这个版本 world 已经收过另一份内容，报错不说是哪一条，整份骨架标上 `conflict`。下一轮的送出调用先用 `world_app_sources_imports` 翻页读回（每页 10 条、最多 20 页：页太大时模型只看到「已存到文件」，看不到 `next_cursor`），找到的记进 `delivered/`（`status` 为 `conflict`，带 world 那边的 `import_id`），读完没找到的去掉标记照常重送。
   - 没收到回执的（调用失败、中途断了）留在队列，下一轮用 `results/` 里落盘的那一份原样重送；内容逐字相同时 world 返回原导入，不会收两次。
5. 回执：用 `world_app_sources_report_run` 报这一轮：还有积压时 `coverage_status` 为 `partial`、`coverage_code` 为 `coverage_incomplete`、一条 `extraction_pending` 缺口，`pending_count` 是积压条数，`pending` 列出最早的 200 条；没有积压时是 `ready`。`request_key` 是 `run-<round_id>`。

### results/

`format`、`item_id`、`item_version`，加上下面三种之一：

- 判断：`result`（null 或 SourceItem 字段）、`attempt`（判过几次）、`round_id`、`judged_at`；判过两次还不合规的是 `result: null` 加 `dropped`。
- 等重判：没有 `result`，`rejected` 是历次拒绝的 `code` 与 `round_id`，`attempt`。
- 等读回：判断之外多一个 `conflict`（报冲突的那一轮）。

### rounds/

`round_id`（`<UTC 时刻>-<随机>`）、`agent`、`format`、`trigger`（`session_end` 或 `waited`）、`started_at`、`finished_at`、`taken`（判断了几条）、`accepted`（收到回执几条）、`nulls`、`rejected`、`calls`（每次调用的种类、退出码、秒数、是否超时、失败类别、用量）、`exit_code`（最后一次调用的）、`usage`（合计）、`failure`、`mismatches`、`imports`、`report`（回执交上去没有）、`backlog`。

### 失败

`failure` 是 `{class, detail}`，按退出码和输出分五类：`program_missing`（找不到程序）、`login_invalid`（模型那边的账号或登录失效，例如 401）、`world_unavailable`（没装 world 插件、world 连不上或没登录、world 的工具报错）、`network`、`other`（超时、输出读不出、选择已变、目标为空等）。失败时条目都留在队列，已落盘的判断留着，下一轮接着做；这一轮不报回执，下一次成功时的回执里有积压条数。不跨 Agent 兜底：Claude Code 的条目不交给 Codex 判。

### 时限

一轮硬时限 20 分钟（`ROUND_LIMIT`，1200 秒）。判断每次最多 5 分钟，并且要给送出（最多 4 分钟）和回执（最多 5 分钟）留够时间，不够就不再起新的一批；到点 CLI 先收 TERM、再收 KILL（Windows 上 `taskkill /T /F`），这一轮记 `other`/`timeout`。

## 开始采集与迁移

三个子命令给「开始采集」那次对话里的 Agent 用（流程在 `world` 插件的 `world-capture-start` 技能里）。每次在标准输出上交一行 JSON（ps1 版按 UTF-8 写），标准错误不写；`enable`、`import` 拒绝时退出码 1，交回 `{"ok":false,"reason":"…"}`，什么都不写。选择记录文件是 world 交回的 `selection` 对象（`world_app_sources_select` 或 `world_app_sources_read`），原样存成 JSON。

**`check <Agent>`**：什么都不写。不支持的机器交回 `supported: false` 和原因（同 `unsupported.json` 的 `reason`）。支持时交回：

| 字段 | 内容 |
| --- | --- |
| `data_dir`、`folder`、`folder_present` | 数据目录叫什么（`~/.claude`、`CLAUDE_CONFIG_DIR`、`~/.codex`、`CODEX_HOME`）、要读的文件夹名（`projects` 或 `sessions`）、它在不在。不交路径 |
| `device_id`、`device_from`、`source_id` | 设备 id 先用 `config.json` 的（`config`），没有再用组件 `settings.json` 的（`component`，迁移时来源标识才和组件建的选择对得上），都没有就新起一个 UUID（`new`，不落盘，`enable` 时才写）；`source_id` 是 `local-capture-<Agent>-<设备 id>` |
| `capturing` | 这种 Agent 在 `config.json` 里已有合用项时，它的 `selection_id`、`selection_version`、`history_from`、`confirmed_at`；没有是 null |
| `component` | 组件 `settings.json` 合用时，它的 `selection_id`、`source_format`、`capture_enabled`、`running`（`agent-channel.json` 在不在）、`open_at_login`；没有组件是 null |

**`enable <Agent> <文件>`**：对话里确认、world 已建好的选择写进 `config.json`，别的 Agent 的那一项留着。要过的关，按顺序，不过就拒绝：

| `reason` | 情况 |
| --- | --- |
| `selection_file_missing`、`selection_unreadable`、`config_unreadable` | 文件不在或读不出；本机 `config.json` 在、却读不出 |
| `selection_not_active` | `status` 不是 `active` |
| `source_mismatch` | `adapter` 不是 `work-increment/0.1`、`source_id` 不是 `local-capture-<这种 Agent>-<设备 id>`，或 `locator` 不是 `local-capture:<source_id>` |
| `device_mismatch` | 设备 id 不是 `check` 会给的那个：有 `config.json` 时要等于它的，有组件时要等于组件的，都没有时要是 UUID |
| `history_mismatch` | 不是持续来源（`authorized_increments`）、没有合法的 `history.start_at`，或有 `end_at` |
| `confirmation_mismatch` | 确认方式不是 `current_dialogue` |
| `scope_not_confirmed` | 确认原话（`confirmation.text`）没有逐字写出读的范围：Claude Code 要有「Claude Code」「projects」，Codex 要有「Codex」「sessions」「.jsonl」，两边都要有「以后新开」「持续」 |
| `data_dir_not_absolute` | `CLAUDE_CONFIG_DIR` 或 `CODEX_HOME` 是相对路径：钩子会按会话的工作目录解释它，读的范围对不上 |

成功时交回 `ok`、`selection_id`、`selection_version`、`history_from`，以及 `replaced`：这种 Agent 原来那一项的 `selection_id`（换了选择时），否则 null。

**`import <Agent> <文件>`**：迁移，沿用 World Capture 组件在窗口里建的选择（不新建：新建会换掉 world 的幂等键，已送过的会作为新导入再进一次 world）。组件目录只读不写。先核：组件 `settings.json` 在（`component_missing`）且读得出（`component_settings_unreadable`）、没在运行（`agent-channel.json` 不在，`component_running`）、`capture_enabled` 为 false（`component_capture_enabled`）、会话种类就是这种 Agent（`component_format_mismatch`）、有选择（`component_no_selection`）；本机 `config.json` 的设备 id 若有要等于组件的（`device_mismatch`）；文件里的选择就是组件那一项（`selection_mismatch`），确认方式是 `component_window`，其余同 `enable` 的关。这种 Agent 在 `config.json` 里已经是这项选择的，交回 `already: true`，什么都不改；是别的选择的，拒绝（`agent_already_configured`）。然后按顺序：

1. 组件检查点 `source-<选择>.json` 的 `progress.entries`（送出的和判为无增量的）记进 `delivered/`，`status` 为 `component`，`import_id` 为 null；已在里面的不重记。
2. 补读组件读的那个文件夹：里面每个 `.jsonl`（不跟符号链接、不进重解析点，最后修改早于历史起点的跳过）按读增量的同一套规则从头读，已送出、已在队列的不入队，写好位置文件，之后的钩子接着读。组件检查点里记着的文件和组件停下以后新出现的文件都在其中；这是唯一一次扫目录。组件的待提炼条目就这样连原文进了队列。
3. 组件的待提炼 `extraction-<选择>.json` 里交回了、还没送出的结果（`results`），条目已在队列、`results/` 里还没有的，写成判过一次的判断（`round_id` 为 `import`，`judged_at` 是组件收下它的时刻）。之后的后台轮原样送出：组件其实已经送过的，world 按幂等键返回原导入。
4. 组件的待提炼和交回的结果里，补读之后既不在队列、也不在 `delivered/` 的，原文已经读不到（会话文件被清掉了），记为覆盖缺口。
5. 写 `import.json`，最后写 `config.json`：钩子要等它才读这种 Agent 的会话、起后台轮。中途断了重跑，每一步都按已有的状态推。

成功时交回、也记在 `import.json` 里：`delivered`（这次记进 `delivered/` 的条数）、`queued`（这次新入队的条数）、`results`（带着组件交回结果的条数）、`missing`（覆盖缺口的条数，`import.json` 的 `missing_items` 列出 `item_id`、`item_version`）、`files`、`skipped_files`（读了和跳过的会话文件数）、`component_plan_pending`（组件检查点里还有一份没收尾的送出计划：那几条会重新判断，组件若已送出，world 报冲突后按读回记）、`open_at_login`（组件的开机运行还开着）。

组件的待提炼条目不存原文，只能从会话文件重读；Codex 的会话被压成 `.jsonl.zst` 或挪进 `archived_sessions` 以后插件读不到，这样的条目也记为覆盖缺口。

## 参数

| 参数 | 值 | 理由 |
| --- | --- | --- |
| 开头摘要的长度 | 4096 字节，且不超过已读字节数 | ADR 决定一写的 4 KiB；限于已读部分，小文件续写不误判 |
| 起轮的等待 | 30 分钟 | 与现在的自动整理相同 |
| 临时目录残留 | 超过一天删掉 | 正常运行结束时就删了，残留只来自中途被杀的运行 |
| `first_seen_at` 的精度 | 秒 | `date -u` 只到秒，两份脚本写同一种格式 |
| 每批、每轮 | 20 条一批、5 批一轮 | 与原来的自动整理相同 |
| 两轮的间隔 | 30 分钟，连续失败翻倍，最长 4 小时 | 与原来的自动整理相同 |
| 一轮的硬时限 | 20 分钟 | 估计的一轮最长约 15 分钟：判断 5 批各一两分钟、送出与回执各一两分钟；锁再宽 10 分钟 |
| 被拒后重判 | 最多判两次 | 第二次还被拒就当 null，不一直重判 |
