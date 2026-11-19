# world-capture 插件

工程包版本：0.2.0。0.2.0 起钩子、后台轮和子命令由 `bin/` 下的启动程序跑，代替两份脚本，不再用 jq，0.2.0 时行为与 0.1.7 相同，之后有意改的行为列在 `tests/world-capture/README.md`。本机采集：Claude Code、Codex 的会话每轮结束时，钩子只读这个会话新增的记录，把条目放进本机队列；攒够了在后台起一轮：先经 world 插件的连接读所选目标，再不带任何工具按会话判断，最后经同一个连接送进 world。要和 `world` 插件一起装：后台那一轮用它的连接（和它的登录），判断规则取它的 `world-source-extract` 技能。

拆成单独的插件，是因为 Codex 在插件里任何一个文件变了以后都要本人重新信任一次钩子；`world` 经常发版，采集逻辑很少变。

- `hooks/claude.json`、`hooks/codex.json`：会话开始（新开或恢复）、每轮结束、会话结束三个钩子。
- `bin/run.sh`、`bin/run.ps1`：钩子与子命令的包装。挑出这台机器的二进制（`bin/capture-darwin-arm64`、`capture-darwin-amd64`、`capture-windows-amd64.exe`、`capture-windows-arm64.exe`），参数原样交给它，退出码原样交回；stdin 不经包装的手。`run.ps1` 带 UTF-8 BOM，代码只有 ASCII。
- `launcher/`：启动程序的 Go 源码，只用标准库。`build.sh` 编出四个二进制，再打出各自的 SHA-256。二进制随插件一起提交，改了源码就重编、一起提交。Go 钉在 1.27.3（`go.mod` 的 toolchain 一行，`mise.toml`），编的时候用 `CGO_ENABLED=0`、`-trimpath`、`-buildvcs=false`、`-ldflags="-s -w"`：同样的源码、Go 版本和参数，谁编出来哈希都一样（源码要按 LF 检出）。macOS 15 及以上；不用 jq、openssl。
- `hooks/round-prompt.md`：后台轮的提示词，启动程序当数据文件读。
- `hooks/capture.sh`、`capture.jq`、`round.jq`、`setup.jq`、`capture.ps1`：0.1.7 的两份启动脚本。钩子不再调它们，也不再拿来逐字节对照：0.2.0 之后启动程序有意改了读取、队列和后台轮（列在 `tests/world-capture/README.md`）。启动程序跑稳以后删掉。

## 安装

两个插件来自同一个市场 `tkos-world`，先按市场的 README 装好 `world` 并登录，再装这一个：

```sh
claude plugin install world-capture@tkos-world   # Claude Code
codex plugin add world-capture@tkos-world        # Codex
```

Codex 装好以后第一次开会话会弹「Hooks need review」，选信任；之后 `world-capture` 每次更新也会弹一次。不信任，Codex 的会话就不采集。装好以后在对话里说「开始采集 world 进展」，Agent 按 `world` 插件的 `world-capture-start` 技能核对本机、准备来源选择，本人在对话里确认后它调下面的 `enable` 写本机 `config.json`；没有它，钩子什么都不做。每种 Agent、每台设备一项选择，在哪种 Agent 里确认就是哪种的。

## 命令行

```sh
bin/run.sh  <claude|codex> <事件>   # 钩子：stdin 是钩子的 JSON：session_id、transcript_path、hook_event_name
bin/run.ps1 <claude|codex> <事件>   # Windows；Codex 的 commandWindows 本来就在 PowerShell 里跑，直接调这台机器架构的 exe
bin/run.sh  <check|enable|import> <claude|codex> [选择记录文件]   # 「开始采集」那次对话里的 Agent 调用
bin/run.ps1 <check|enable|import> <claude|codex> [选择记录文件]
bin/run.sh  export <claude|codex> [选择记录文件 读回记录文件]      # 回退到组件时调用
bin/run.ps1 export <claude|codex> [选择记录文件 读回记录文件]
```

钩子只读 stdin 里的 `transcript_path`，事件取命令行参数。任何情况下退出码都是 0，标准输出和标准错误都不写：Agent 会解析钩子的标准输出，Stop 钩子输出 `{"decision":"block"}` 会拦住会话。四个子命令见「开始采集与迁移」「回退到组件」。

以下情况直接退出，什么都不写：

- 环境变量 `WORLD_AUTO_EXTRACT_ROUND` 非空（后台轮里加载的钩子）。
- `run.sh`：`uname -s` 不是 Darwin。装了 Git Bash 的 Windows 会把 Claude Code 那一行钩子整行交给 Git Bash，PowerShell 那段已经跑过。子命令这时交回拒绝：`MINGW*`、`MSYS*`、`CYGWIN*` 上是 `use_powershell`，别的系统上是 `not_macos`（`check` 交 `supported: false`）。
- Agent 不是 `claude` 或 `codex`，事件名不全是字母。
- `config.json` 不存在，或其中没有这种 Agent 的合用项。
- `transcript_path` 不是绝对路径、不以 `.jsonl` 结尾、不是普通文件，或是符号链接（Windows 上是重解析点）。
- `transcript_path` 不在这一项的 `folder`（「开始采集」时确认过的文件夹）下面。Mac 上按实际所在的目录比（同 `cd -P`），用 `..` 或文件夹里的符号链接绕到外面的不算；Windows 上把路径规范化后比前缀（不区分大小写），并要求从文件夹往下到文件所在目录的每一层都不是重解析点。

钩子拉起脱离的进程（同一个程序的 `__worker` 模式）后马上返回，会话文件路径经环境变量 `TKOS_CAPTURE_TRANSCRIPT` 传给新进程。Mac 上新进程另起一个会话、不理会 HUP（同 `nohup`）；Windows 上是没有控制台的 `DETACHED_PROCESS`，先试着脱离钩子所在的作业对象，作业不许时退回不脱离作业。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `TKOS_CAPTURE_HOME` | 本机状态目录。不设时是 `$HOME/.tkos-world/capture`（Windows 是 `%USERPROFILE%\.tkos-world\capture`）。 |
| `TKOS_CAPTURE_FOREGROUND` | 为 `1` 时在钩子进程里直接读，不脱离。测试用。 |
| `TKOS_CAPTURE_DECISION_FILE` | 设了才把起轮决定写到这个路径。测试用。 |
| `TKOS_CAPTURE_OS_VERSION` | 只在 Mac 上：换掉系统版本（`sw_vers -productVersion` 的结果）。测试用它模拟低于 15 的机器。 |
| `TKOS_CAPTURE_CLAUDE`、`TKOS_CAPTURE_CODEX` | 后台轮用的程序。不设时在钩子环境的 `PATH` 里找，再找常见的安装位置（Mac 上 `~/.local/bin/claude`、`$CLAUDE_CODE_EXECPATH`、`/Applications/Codex.app`、`/Applications/ChatGPT.app` 里的 codex；Windows 上 `%USERPROFILE%\\.local\\bin\\claude.exe`、`%APPDATA%\\npm\\codex.cmd`）。设了但文件不在，就记「找不到程序」。 |
| `TKOS_CAPTURE_CLAUDE_MODEL` | Claude Code 后台轮的模型，默认 `sonnet`（与原来的自动整理相同）。 |
| `TKOS_CAPTURE_ROUND_LIMIT` | 一轮的硬时限（秒），默认 1200。测试用它把时限调短。 |

## 本机状态目录

目录 0700、文件 0600（Mac 上 `umask 077` 加 `chmod`，起的 CLI 也照这个建文件）。Windows 上用 `icacls` 把状态目录收到当前用户和 SYSTEM，子目录和文件继承。所有文件都先写临时文件再改名。JSON 按 `jq -c` 的写法写：键照插入的顺序，读进来的数字原样写回，`0x7F` 写成 `\u007f`，非 ASCII 原样。

| 路径 | 内容 | 谁写 |
| --- | --- | --- |
| `config.json` | 见下文 | `enable`、`import`、`export` 子命令 |
| `import.json` | 迁移那一次的结果，见「开始采集与迁移」 | `import` 子命令 |
| `export.json`、`export/` | 回退那一次的记录，和改之前的组件检查点，见「回退到组件」 | `export` 子命令 |
| `paused.json` | `reason`、`first_seen_at`、`last_seen_at`：后台轮暂停的原因，现在只有 `component_capturing`（组件正在采集）。原因不在了，下一次钩子删掉它 | 启动脚本 |
| `transcripts/<sha256(路径)>.json` | 位置文件，见下文。会话结束后也留着 | 启动脚本 |
| `queue/<格式>/<item_id>@<item_version>.json` | 待提炼条目，见下文。格式里的 `/` 原样成为一层目录，例如 `queue/claude-session-jsonl/1/` | 启动脚本 |
| `results/<item_id>@<item_version>.json` | 后台轮给这一条的判断，送出前落盘，见「后台轮」 | 持锁的启动脚本 |
| `delivered/<格式>.jsonl` | 已收到 world 回执、已判为无增量或被规则挡下的条目，每行一个 JSON 对象：`item_id`、`item_version`、`import_id`、`status`、`round_id`、`at`，队列条目有 `session`、`line` 的也照抄（旧条目没有就不带），见「后台轮」。读增量时只认前两项 | 持锁的启动脚本 |
| `context/<格式>/<session>.json` | 前文存放：同一会话里判完或被规则挡下的条目（`item_id`、`item_version`、`role`、`reported_at`、`text`、`line`），按行号的最后 3 条加上队列里还没判完的条目前面紧挨着的 3 条，见「后台轮」 | 持锁的启动脚本；队列里没有它的条目了，并且会话已结束或这一份 24 小时没改过，下一次钩子或下一轮删掉 |
| `rounds/<round_id>.json` | 每一轮的经过，见「后台轮」。只留最近 400 份 | 持锁的启动脚本 |
| `audits/<格式>/<UTC 日期>.json` | 每周复核的结果：抽了哪些、分歧在哪，见「每周复核」。每种格式只留最近 26 份 | 持锁的启动脚本 |
| `world-tools.json` | Claude Code 的后台调用见过的 world 工具名（不带前缀），用来关掉每次用不到的，见「后台轮」。删了也行，下一次调用重新学 | 持锁的启动脚本 |
| `round.lock/` | 目录，里面的 `owner` 记着持锁进程的 `pid`、`round_id`、`started_at`。一轮结束就删 | 持锁的启动脚本 |
| `work/` | 后台轮里 CLI 的工作目录，一直是空的 | 持锁的启动脚本 |
| `unsupported.json` | `reason`、`system`、`os_version`、`first_seen_at`、`last_seen_at`。机器恢复支持后，下一次钩子删掉它 | 启动脚本 |
| `tmp/` | 每次运行的临时目录，结束时删掉；超过一天的残留由下一次运行删掉 | 启动脚本 |

### config.json

```json
{
  "device_id": "<设备 id>",
  "screen_short": true,
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

`screen_short` 为 `true` 时后台轮先过一道规则：用户消息和不到 300 字的答复不单独判，只当前后文（见「后台轮」）。没有这一项就是关，子命令不会替本人打开它；`enable`、`import` 重写 `config.json` 时留着它。

除了 `folder`，每项都照抄 world 交回的选择记录：`selection_version` 是记录的 `version`，`history_from` 是 `choice.history.start_at`，`confirmed_at` 是 `confirmation.confirmed_at`。`folder` 由子命令按数据目录算，不由 Agent 给：`enable` 时 Claude Code 是 `$CLAUDE_CONFIG_DIR/projects`（没设就是 `~/.claude/projects`），Codex 是 `$CODEX_HOME/sessions`（没设就是 `~/.codex/sessions`；钩子本来就只读 `.jsonl`，压缩过的 `.jsonl.zst` 不读）；`import` 时是组件 `settings.json` 里它读的位置 `location.root`。

### 位置文件

`path`、`format`、`offset`（已读到的字节位置，总在一个换行之后）、`size`、`mtime`（Unix 秒）、`head_bytes`、`head_sha256`、`lines`（已读的行数，空行也算）、`state`（解析器状态）、`issues`（各类缺口的累计条数）、`updated_at`，会话结束后还有 `ended_at`。

- `head_sha256` 是文件开头 `head_bytes` 个字节的摘要，`head_bytes` 取 4096 和已读字节数中较小的那个。只摘已读过的那一段，所以 4 KiB 以内的小文件往后写也不会被误判为改写。
- 文件比 `offset` 小，或开头那一段的摘要变了，就当被改写：位置、状态、`issues` 都从头算，已入队的条目留着。
- 文件大小等于 `offset` 时什么都不读，也不改位置文件；只有 `SessionEnd` 时还没有 `ended_at` 的，补记上它，`SessionStart` 时有 `ended_at` 的，去掉它。
- `ended_at`：`SessionEnd` 钩子读过这份文件的时刻（UTC，到秒），读没读到新内容都记。记上以后，之后的读取照抄它（写位置文件之前再读一次盘上的那份，另一个进程刚记上的也不丢），直到 `SessionStart`（会话恢复）读这份文件时去掉它，读没读到新内容都去掉：恢复以后的新候选照常等后文。后台轮靠它判断这个会话的条目都可以判了（见「后台轮」）。
- 位置文件不删：会话结束、前文存放清掉以后也留着。`delivered/` 里一行的 `session` 就是它的文件名，`path` 是会话文件，按 `line` 能回会话文件读原文。
- `state`：Claude 是 `recognized`、`daily`；Codex 是 `session`、`subagent`、`up`、`ap`（用户消息和最终答复各自见过的最高优先级）、`daily`。
- `issues` 的键：`parse_failed`（读不出的行）、`text_not_well_formed`（原文含孤立代理项的条目）、`time_unknown`（没有可用时刻的条目）。

### 队列文件

`item_id`、`item_version`、`locator`、`role`、`reported_at`、`text`、`first_seen_at`、`session`、`line`。

- `item_id` 是 `entry-` 加 `sha256("<格式>:<条目 id>")`，`item_version` 是 `sha256(JSON.stringify([role, text, reported_at]))`，这里的 `reported_at` 是会话文件里的原始时刻串。`locator` 是 `local-capture:<source_id>/<item_id>@<item_version>`。
- `reported_at` 是按库的 `utc()` 换算后的 UTC 时刻，`text` 与库交给提炼的原文逐字相同。
- `first_seen_at` 是第一次入队的时刻（UTC，到秒）。同名文件已存在时不重写。
- `session` 是条目所在会话文件的位置文件名（`transcripts/<session>.json`，即路径的 SHA-256），`line` 是条目在会话文件里的行号（从 1 起，空行也算；Claude 的答复是这一轮最后那段文字所在的行）。后台轮按这两项把条目按会话分组、按先后排。0.2.0 起、本版以前入队的条目没有这两项，各自当一个单独的会话。
- 条目在 `delivered/<格式>.jsonl` 里或队列里已有同名文件时不入队。脚本先列队列目录、再读 `delivered/`。后台轮要先把条目记进 `delivered/`、再删队列文件，这个顺序下刚送出的条目不会被重新排进来。

## 一次运行做什么

1. 从位置文件记的 `offset` 起读到文件当前大小，只取到最后一个换行为止。末行没写完就留到下次。
2. 逐行解析：空行跳过；每行去掉开头一个 BOM，按 UTF-8 严格解码，按 JSON 解析，要是对象。
3. 每段增量读完时，Claude 把这一轮到目前为止最后的答复交出来；Codex 按到目前为止见过的最高优先级挑表示。
4. 条目原文不合法的丢掉、记 `text_not_well_formed`；没有可用时刻的不入队、记 `time_unknown`；早于 `history_from`（按 UTC 比较，秒以下补零后比）的丢掉。其余的入队。
5. 先写队列文件，再写位置文件。中途断了，下次从旧位置重读，同名条目不会重复。
6. Claude 没有带会话 id 的消息、Codex 还没有 `session_meta` 时，这段增量认不出格式：什么都不写，下次从同一处再读。

## 起轮决定

队列里有可判的候选、可以落地的挡下条目（都见「后台轮」第 2 步），或有已判完、待送出、待读回的条目，并且事件是 `SessionEnd`（`reason` 为 `session_end`），或其中最早一条的 `first_seen_at` 已过 30 分钟（`reason` 为 `waited`），这一种格式就该起后台轮（`due`）。只有还不可判的候选、或只有还不能落地的挡下条目，不起：起了也做不了什么。队列文件读不出、排不了时退回原来的规则（队列里任何一条都算）。真起不起（`run`）还看三条：

- 组件：World Capture 组件的 `agent-channel.json` 在（组件正在采集时才有；Mac 上在 `~/Library/Application Support/World Capture/capture/`，Windows 上在 `%APPDATA%\World Capture\capture\`），就不起，不管组件采的是哪种会话（`blocked` 为 `component_capturing`）。同一时间只有一方送；条目照常排队，原因记进 `paused.json`，不记进 `rounds/`，也不算失败。组件停下以后，下一次钩子照常起轮、删掉 `paused.json`。
- 间隔：这种格式的上一轮开始后至少隔 30 分钟；最近连续失败了几轮，间隔就翻几倍，最长 4 小时（`blocked` 为 `too_soon`）。有一批进了 `failed_batches` 的轮在这里也算失败：那一批留在队列，不该每 30 分钟就重判一次。登录类失败（`login_invalid`、`world_unavailable`）不翻倍（本人 2026-11-19 定）：最近一轮是登录类的，下一轮照旧隔 30 分钟，本人登录好以后最多半小时自动恢复；数连续失败的轮数时跳过登录类的轮，它们不算数也不打断，别的失败照旧翻倍（例如 `network`、`login_invalid`、`network` 之后隔 2 小时）。`failures` 报的是连续失败的总轮数，登录类的也算在内。答坏的候选单独判满 3 次就按 null 落盘（见「后台轮」第 5 步），间隔不会一直停在 4 小时。
- 锁：`round.lock/` 在、而且不比硬时限再老 10 分钟以上，说明另一轮正在跑（`blocked` 为 `round_running`）。两种格式共用这一把锁，同一时间只跑一轮。

设了 `TKOS_CAPTURE_DECISION_FILE` 时把决定写出来：`agent`、`event`、`format`、`due`、`reason`、`queued`（队列里的条数）、`judgeable`（其中可判的候选条数；排不了时是 null）、`oldest_first_seen_at`（队列里最早入队的那一条）、`decided_at`、`run`、`blocked`、`failures`、`next_round_at`。

起轮决定之前，先扫一遍这种格式的前文存放：队列里没有这个会话的条目了，并且它的位置文件有了 `ended_at`、或这一份 24 小时没改过（Claude 被杀、Codex 的 `SessionEnd` 没拉起程序时，`ended_at` 一直记不上），删掉它那一份。

## 后台轮

一轮在读增量的那个脱离进程里跑，先建 `round.lock/`（建目录：要么建成、要么失败）。锁比硬时限再老 10 分钟，就当持锁的进程已经不在了，挪开重来。

每次模型调用是一次单独的 `claude -p` 或 `codex exec`，提示词从标准输入交（Claude Code 连 world 的三次先问 world 连没连上，见下），工作目录是空的 `work/`，环境只带 `HOME`、用户名、系统 `PATH` 加程序所在目录（Windows 上再接上钩子环境的 `PATH`：npm 装的 `codex.cmd` 要找 node，node 不在同一个目录）、`LANG`、临时目录、`CLAUDE_CONFIG_DIR` 或 `CODEX_HOME`（设了才带），以及 `WORLD_AUTO_EXTRACT_ROUND=<round_id>`：后台轮加载的 world 插件的钩子靠它一进来就退出。claude 另带 `ENABLE_CLAUDEAI_MCP_SERVERS=false`：账号上的 claude.ai 连接器连上后，claude 会把它们的工具定义补发进下一次请求（本机实测约 12 万 token），`--setting-sources`、`--tools`、`--disallowedTools` 都拦不住，这个变量把它们关掉（0.1.7 起）。四种调用各自只放行这几个 world 工具：

| 调用 | 工具 | 做什么 |
| --- | --- | --- |
| 准备 | `world_app_sources_read`、`world_app_sources_targets` | 照抄启动脚本给的参数读选择和所选目标（`since` 是这一轮要判的候选里最早的上报时刻往前 24 小时；这一轮要做每周复核时，取它和复核窗口起点往前 24 小时里更早的那个，判断仍只用前者以来的 `recorded`），只回 `done`。有要判的候选才调 |
| 判断 | 没有，也不连 world | 提示词里放好判断规则、时区、目标和这一批，按规则给每条候选交 null 或 SourceItem 字段，一次回一个 JSON |
| 每周复核 | 没有，也不连 world | 同判断，候选是从 `delivered/` 抽出来、按会话文件重读的条目，见「每周复核」 |
| 送出 | `world_app_sources_ingest`、`world_app_sources_imports` | 把启动脚本算好的骨架原样交给 `world_app_sources_ingest`；上一轮报过 `IDEMPOTENCY_CONFLICT` 的，先用 `world_app_sources_imports` 读回 |
| 回执 | `world_app_sources_report_run` | 把启动脚本算好的运行回执原样交上去 |

判断那一次一个工具都没有，所以判断一定先落盘、再送出；原文里就算混进指令，这次调用也做不了什么。启动脚本从 CLI 的事件流里读工具调用的参数和 world 的返回（Claude Code 用 `--output-format stream-json --verbose`，Codex 用 `--json`），只认 world 的回执，不认模型自己说的。

Claude Code，准备、送出、回执：

```sh
claude -p --no-session-persistence --setting-sources "" --plugin-dir <world 插件的 installPath> --tools "" \
  --allowedTools <这次的工具全名，逗号分隔> [--disallowedTools <这次用不到的 world 工具全名，逗号分隔>] \
  --input-format stream-json --permission-mode dontAsk --output-format stream-json --verbose --model sonnet
```

这三次先预检，world 不是 `connected` 就不调模型（2026-11-19 起）。world 没令牌、令牌被拒（`needs-auth`）、连不上（`failed`）、连得慢（`pending`），`claude -p` 都不会自己停，照样带着提示词调一次模型（每次约 4 千输入 token，偶尔失控到十几万；Codex 那边 world 是 required，没连上在调模型之前就退出，不用预检）。做法：

1. 标准输入是一条管道，先写 `{"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}}`，再写一条 `mcp_status`。回复是输出里的 `control_response` 行，`response.response.mcpServers[]` 里 `plugin:world:world` 那一行的 `status` 就是 world 的状态；列表里没有它记 `missing`。
2. `connected`：把提示词作为一条用户消息 `{"type":"user","message":{"role":"user","content":"<提示词>"}}` 写进去，关上标准输入，后面和原来交提示词文件一样（11/19 用本机假 world 和 haiku 实测：事件流、`result` 行、用量、退出码都相同，只是开头多几行 `control_response`，读事件流时跳过它们）。
3. `pending`：每秒再问一次。连得上的 world 第一次问也是 `pending`，约 0.1 秒后变 `connected`；连不上的，claude 在连接超时（`MCP_TIMEOUT`，缺省 30 秒，启动程序不设）以后自己改成 `failed`（实测起进程后约 28 秒）。所以最多问 45 秒，并且不超过这次调用的时限减 10 秒，但至少问 5 秒（时限只剩几秒时也不把第一次的 `pending` 当结果，时限更短的到点照旧记超时）；到了还是 `pending` 就按 `pending` 记。
4. 别的状态（`needs-auth`、`failed`、`missing` 等）：不写提示词，关上标准输入。claude 不调模型就退出（实测约 1 到 3 秒、退出码 0、没有 `result` 行）。这一次记 `world_unavailable`、detail `mcp_<状态>`，用量记 0、`requests` 记 0，这一轮到此为止，和原来 world 不可用时一样。
5. 预检本身出错（一次 `mcp_status` 10 秒没回、回的是出错或读不出、进程先退了）：不写提示词，不当成 world 不可用，照输出本身分类（多半是 `other`/`output_unreadable`）。

标准输出、标准错误照旧写文件、不走管道（Node 写的 CLI 往管道写时，进程一退出没写完的就丢了），预检的回复是边写边从输出文件里读的。Mac 和 Windows 一样。

判断：

```sh
claude -p --no-session-persistence --setting-sources "" --tools "" --strict-mcp-config --disable-slash-commands \
  --permission-mode dontAsk --output-format stream-json --verbose --model sonnet
```

不带 `--plugin-dir`，就没有 world 连接；`--tools ""` 关掉内置工具，`--strict-mcp-config` 不读别处的 MCP 配置，`--disable-slash-commands` 不带技能和命令清单（claude 2.1.327 本机实测：`init` 事件里 `tools`、`mcp_servers`、`skills`、`slash_commands` 都是空的）。

`--allowedTools` 只管免确认：world 连接上的六十来个工具（schema 约 70 KB）照样每次请求都带给模型。`--disallowedTools` 才把工具从模型看到的里拿掉（CLI 说明）。world 有哪些工具从各次调用 `init` 事件的 `tools` 学来，并进状态目录的 `world-tools.json`；第一次调用还没学到，全带着；world 以后新加的工具在被学到之前也照样带着，只是多花一点。

`installPath` 每次从 `~/.claude/plugins/installed_plugins.json` 的 `world@tkos-world` 取（用户级优先），升级后目录会变。工具全名是 `mcp__plugin_world_world__<工具>`。`claude -p` 每次在 `~/.claude/projects` 下按 `work/` 留一个目录：里面是空的 `memory/`，工具返回超过约 50 KB 时还有 `<会话 id>/tool-results/` 下存的完整返回（`--no-session-persistence` 也存）。这个目录只属于后台轮，每次调用后删掉存下的工具返回，再删空目录，别的文件不动。返回超过约 50 KB 时模型只看到一句「已存到文件」，启动脚本照样从事件流的 `tool_use_result` 读完整的回执。

Codex，准备、送出、回执：

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

判断：前面那些开关照旧，不配 `mcp_servers.world`，另加 `-c features.plugins=false`，再接 `--json -`。codex 0.167 即使不读本人配置，也会连上远程的官方插件（各带 MCP 工具；本机调试日志实测连上了三个），关掉插件以后一个 MCP 都没有。

服务名 `world` 和地址与 world 插件的 `mcp.json` 逐字一致，Codex 按这两样找到本人登录时存下的令牌。`required=true` 让 world 连不上时 codex 直接退出，不白花一次模型调用。判断规则从 `$CODEX_HOME/plugins/cache/tkos-world/world/<版本>/skills/world-source-extract/SKILL.md` 取版本号最大的那份。上面这些开关关掉以后，模型还看得到的只有：选定的 world 工具；codex 0.167 自带模型目录里大多数模型固定开着的 code mode（`exec`、`wait`，在不能访问文件和网络的 JS 环境里组合工具调用），其中嵌着 `apply_patch`（只读沙箱加不批准，写文件会被拒）、MCP 资源的列出与读取、当前时刻。

一轮的步骤，每一步都按已有状态推，中途断了重跑结果相同：

1. 已判为 null 还没记进 `delivered/` 的记上，可以落地的挡下条目落地（见第 4 步）；`results/` 里条目已不在待提炼的、已记进 `delivered/` 却还留着的队列文件，删掉。
2. 排这一轮：没有判断、或上次被 world 拒了要重判的条目，按会话（`session`）分组、按行号（`line`）排。
   - 规则：`config.json` 的 `screen_short` 为 `true` 时，用户消息（`by` 为 `rule:user`）和不到 300 个 UTF-16 码元的答复（`rule:short`，和库里的 `text.length` 一样数）不判，只当前后文；其余的是候选。没开时所有条目都是候选。
   - 可判时机：一条候选后面队列里已有至少 3 条（按 `line`，在队列里的都算），或这个会话的位置文件有了 `ended_at`，或这个会话最新一条的 `first_seen_at` 已过 30 分钟，就可判。没有 `session` 的旧条目立即可判。一个会话里，第一条还不可判的候选和它后面的条目都留在队列等后文。
   - 挡下的条目什么时候落地：两件事都满足才落地。一是同一会话里排在它前面的候选都已判完、判断落进 `results/`；二是它后面那条候选也已判完落盘，或它后面已没有候选、会话可判了（位置文件有了 `ended_at`、会话静默满 30 分钟，或是没有 `session` 的旧条目）。其余的留在队列当前后文。判断中途停下、某批答坏、超出批数或时限时，没判到的候选前后挡下的都还在队列里，下一轮照样是它的前后文。
3. 准备：有可判的候选才做，一次准备调用；只有可以落地的挡下条目、没有可判的候选时，不准备、不判断，落地以后照常报回执。只有这次调用里真的读到了生效的选择（`selection_id`、`selection_version` 都对得上、`status` 为 `active`）和非空的目标才往下走；否则（world 连不上、选择已变、目标为空）这一轮到此为止，不判断、不送、不报回执。
4. 挡下的条目落地：记进 `delivered/`（`status` 为 `screened`，带 `by`），移出队列，放进前文存放。落地的条件见第 2 步：到上一轮为止已经满足的在第 1 步落地，这一轮判完才满足的在第 6 步落地。
5. 判断：可判的候选按会话装批，会话按其中最早入队的候选排，最多 5 批、每批最多 30 条候选；判断失败过的候选单独成一批（见下面没判成的那一条）。每批 60000 字只算候选：候选原文合计超过 60000 字就少放几条，前后文不算在内；一条候选超过 8000 字时只交头 6000 字和尾 2000 字。每批一次判断调用，提示词里有判断规则、选择里的时区、准备读到的目标（`criteria`、`recorded` 都在）、这一轮前几批交出的非 null 结论（`target_ref`、`value`、`occurred_at`），和这一批：
   - 这一批按会话分组，会话用这一批里的编号 `s1`、`s2`，不给路径或摘要。每组带第一条候选之前 3 条、最后一条候选之后 3 条，候选之间的非候选条目也带上，都是前后文，取自队列和前文存放；一批放不下拆开时，前后文可以重叠。前后文另算，不占那 60000 字，每条最多交 1500 字：超过的只交头 1000 字和尾 500 字。
   - 候选带短编号 `key`（`"1"` 起，代替各 64 位十六进制的 `item_id`、`item_version`），前后文不带，规则写明不能对它们交结果。每条都带 `role`、`reported_at`、`text`，截过的带 `truncated`（原长），等重判的候选带 `rejected`。
   - 模型按 `key` 交回，启动脚本再对回候选。合规的判断写进 `results/`（已有判断的不覆盖），并进前文存放；`key` 对不上这一批的、重复的、没交 `result` 的记进这一轮的 `mismatches`，漏判的留在队列。字段不合规（多了字段、越界、格式不对）的算被 world 拒了一次（`invalid_increment`）。非 null 却没有 `occurred_at` 的，world 会拒收（`occurred_at_missing`），落盘前改成 null，`dropped` 记 `occurred_at_missing`，`mismatches` 也记一条。
   - 回复里读不出 `results` 数组：这一批不落判断，整批留在队列，记进 `failed_batches`，接着判下一批。
   - 没判成的候选（这一批答坏了 `answer_unreadable`，漏了它的 `key` `unanswered`，有 `key` 没 `result` `no_result`）在 `results/` 的 `judge_failures` 里记一笔，留在队列。下一轮它单独成一批，一批只有它一条候选，前后文照常带，坏的那条不再连累同批的别的候选；只失败过一次、是和别的候选一起整批答坏的，还认不出是哪一条，先照常装批再判一次（偶尔答坏一次多半不是哪一条的问题，不值得把一批拆成一条一次调用）。单独判失败满 3 次的按 null 落盘，`dropped` 记 `judge_failed`，第 6 步记进 `delivered/`、移出队列。
6. 再排一次：判为 null 的记进 `delivered/`（`status` 为 `null`；改成 null 的是 `dropped`，带 `code`），这一轮判完才满足落地条件的挡下条目落地，再删队列文件和 `results/`。
7. 送出：已有判断（非 null）的条目，按每份 50 条拼成骨架：`selection_id`、`selection_version`、`source_id`、`batch_id`、`snapshot_version`、`source_ready_at`（这一份里最晚的上报时刻）和每条的 `item_id`、`item_version`、`locator` 都是启动脚本填的，模型只交判断字段。一轮最多 5 份，一次送出调用。
   - 收到回执的记进 `delivered/`（`status` 为 `imported`，带 `import_id`），再删队列文件和 `results/`。模型交给工具的参数和骨架不一致、world 也收下了的，照回执记，另记 `copy_mismatch`。
   - 422 `SOURCE_ITEMS_REJECTED`：一份骨架在一个事务里，整份不进。被点名的条目带着拒绝的 code 留到下一轮重判；同一条判过两次还被拒，就当 null（`status` 为 `dropped`）。没被点名的原样留到下一轮重送。这一轮不再送第二次。
   - `IDEMPOTENCY_CONFLICT`：这个版本 world 已经收过另一份内容，报错不说是哪一条，整份骨架标上 `conflict`。下一轮的送出调用先用 `world_app_sources_imports` 翻页读回（每页 10 条、最多 20 页：页太大时模型只看到「已存到文件」，看不到 `next_cursor`），找到的记进 `delivered/`（`status` 为 `conflict`，带 world 那边的 `import_id`），读完没找到的去掉标记照常重送。
   - 没收到回执的（调用失败、中途断了）留在队列，下一轮用 `results/` 里落盘的那一份原样重送；内容逐字相同时 world 返回原导入，不会收两次。
8. 回执：用 `world_app_sources_report_run` 报这一轮：还有积压（包括还不可判、等后文的候选）时 `coverage_status` 为 `partial`、`coverage_code` 为 `coverage_incomplete`、一条 `extraction_pending` 缺口，`pending_count` 是积压条数，`pending` 只列出最早的 20 条（服务端要求有积压时至少列一条、最多 200 条，条数照实报；原来列 200 条，模型要逐条照抄两个 64 位十六进制，一次回执约 2.3 万输出 token）；没有积压时是 `ready`。`request_key` 是 `run-<round_id>`。
9. 每周复核：到了时候才做，见「每周复核」。
10. 扫一遍前文存放，同「起轮决定」：队列里没有条目了、并且已结束或 24 小时没改过的会话，删掉它那一份。

### 每周复核

看判断漏没漏：被规则挡下的和判成 null 的条目里，有多少其实该记。结果只给本人看，不写 world。

- **什么时候跑**：挂在一轮的末尾，在同一把锁里、同一个进程里。准备那一步看离上一次复核完成满没满 7 天（看 `audits/<格式>/` 里文件名最大的那份的 `finished_at`；没有过复核、那份读不出的也算满），满了就是要复核的轮；还要这一轮的准备成功过、这一轮没失败、剩下的时间还有一轮硬时限的一半。不满足的不跑，留给下一轮。两种格式各算各的。
- **已记的事实读多久**：要复核的轮，准备读目标时 `since` 放宽到复核窗口起点往前 24 小时（不复核的轮照旧）。复核用放宽后读到的全量 `recorded`：复核抽的条目跨 7 天，当初判成 null 的常常是因为同一件事那时已经记过；只读最近一天的 `recorded`，这些会被误算成分歧。这一轮的判断不受影响：启动脚本按每条的 `occurred_at` 在本地筛回原来的 `since`（这一轮要判的候选里最早的上报时刻往前 24 小时）以来的，同服务端按 `since` 筛的规则。
- **抽什么**：`delivered/<格式>.jsonl` 里 `at` 在最近 7 天的行，分两类：`status` 为 `screened` 的，和 `status` 为 `null` 的（判成 null 的；`dropped` 的不算，包括 `judge_failed`、`occurred_at_missing`）。每类打乱次序往下取，凑满 30 条为止；规则关着的机器上挡下的那类是 0 条。
- **原文从哪来**：按行里的 `session` 读位置文件 `transcripts/<session>.json`，拿到会话文件的路径，照钩子读增量的同一套规则（解析、条目身份、历史过滤，文件要在 `config.json` 的 `folder` 下面、是普通文件）从头读到最后一个换行，按 `item_id` 找到这一条，再核 `item_version`。整份读不出、但这一条是一轮中间被读进来、后来被同一轮更晚的答复顶掉的，读到它那一行（`line`）为止再找一次，同钩子当时读到的那一段：同一个会话里这样的几条按行号排，接着上一段的读取状态往后读，整个文件只多读一遍。前后文是整份读出的条目里它前后各 3 条。按会话读：往下取到某一行、它的会话还没读过时，池子里这个会话的行（两类）一起找完，就放掉这个文件和它读出的条目，一次复核里每个会话文件只读一次。每读一个会话文件前看剩下的时间，不够一次调用就作罢（见「怎么判」）。原文只在内存里用，不另存：提示词照判断那次一样经运行目录里的临时文件交给标准输入，运行结束就删。
- **读不到的不抽**：没有 `session`、`line` 的旧行，位置文件没了或读不出，会话文件删了、压缩了（Codex 的 `.jsonl.zst`）、不是普通文件或读不了，找不到这一条，`item_version` 对不上（原文变了），都跳过，计进 `unreadable`。`unreadable` 是往下取的时候碰到的条数，不是整类里读不到的总数。
- **怎么判**：照判断那一步：同一段提示词、判断规则、这一轮准备读到的时区和目标（`criteria`、放宽后的 `recorded`），「本轮已交出」是这一轮判断交出的那几条；抽中的条目当候选、前后文照带，按会话分组、按行号排，每批最多 30 条候选、候选原文合计最多 60000 字，前后文的截法也一样。两类各自装批，每批一次调用，种类记 `audit`，命令行和判断那次相同：不带任何工具，不连 world。交回的照判断那一步的规则核：合规、带 `occurred_at` 的非 null 是分歧，记下去掉了 null 字段的 `result`；合规却没带 `occurred_at` 的同判断改成 null，不算分歧；不合规的（字段不认识、格式不对、超长，包括 `{}`）计进 `invalid`，只记是哪一条，不记交回的内容。回复读不出、调用失败的那一批不重试，计进 `failed`；没交、或交了却没给 `result` 的候选计进 `unanswered`。`audits/` 先建好，建不了就一次都不调用，直接作罢。每次调用最多等一轮硬时限的四分之一；读会话文件和起每一批之前都看剩下的时间，不够一次调用（一轮硬时限的二十分之一）就作罢：一批都还没判的，什么都不写，留给下一轮；判了几批的，判出的照样写进 `audits/`，记 `partial: true`，也算这一周做过了。
- **不动的**：不写 world，不改 `delivered/`、队列、`results/`、前文存放。
- **从旧版本升上来以后**：`delivered/` 里升级前的行没有 `session`、`line`，都读不到，第一次复核只抽得到升级后判完的条目（往往只有升级那一轮的几条），下一次要再等 7 天。想早点有一份完整的，删掉 `audits/<格式>/`，下一轮会重做。

`audits/<格式>/<UTC 日期>.json`（权限同 `rounds/`，每种格式最多留 26 份，多的删最早的）：`audit_id`（`<UTC 时刻>-<随机>`）、`round_id`、`agent`、`format`、`started_at`、`finished_at`、`partial`（没时间判完是 true）、`window`（`from`、`to`：取条目的 7 天）、`screened` 和 `null`（各是 `pool` 这一类有几条、`sampled` 交去复核几条（没起的批不算）、`unreadable`、`unanswered`、`invalid`、`failed` 几批）、`disagreements[]`（每项 `kind` 为 `screened` 或 `null`，`item_id`、`item_version`、`session`、`line`，挡下的另有 `by`，以及核过的 `result`）、`invalid[]`（交回不合规的，每项同 `disagreements` 但没有 `result`）、`usage`（这次复核各次调用的合计）。那一轮的 `rounds/` 记录里 `audit` 是 `file`（相对状态目录的路径）、两类的计数、`disagreements` 的条数和 `partial`；作罢的是 `failure`（`other`/`no_time`，或 `audits_unwritable`）；没跑是 null。日进展的查漏读 `audits/`：最近 8 天里最新的那一份报一项，查漏那天之前做完的注明此前已报；开始采集（`config.json` 那一项的 `confirmed_at`，读不出时用 `history_from`）满 8 天、最近 8 天里有带准备调用的轮，却一份做完的都没有，也报。最近 8 天里一次准备都没调过的，是没有要判的候选，复核也起不了，不报。

### 前文存放

`context/<格式>/<session>.json` 是一个 JSON 数组，每项是同一会话里判完或被规则挡下的条目：`item_id`、`item_version`、`role`、`reported_at`、`text`、`line`。每判完一条、每落地一条挡下的就并进去，按名字去重，留两部分的并集：按 `line` 的最后 3 条；这次落盘以后还留在队列、还没判完的每一条（要判的、判失败过的、挡下等落地的，以及判了非 null 等送出或读回的：送出被拒还要重判）前面紧挨着的 3 条。判断次序乱了时（某批答坏、漏判、被 world 拒后重判），后面先判完的候选就挤不掉前面那条还要用的前文；它判完以后，多留的在这个会话下一次并进来时清掉。条目判完或挡下落地以后就移出队列，下一轮的候选要的前文从这里取。队列里没有这个会话的条目了，并且会话的位置文件有了 `ended_at`、或这一份 24 小时没改过，就删掉这一份；没有 `session` 的旧条目不进前文存放。

### results/

`format`、`item_id`、`item_version`，加上下面三种之一：

- 判断：`result`（null 或 SourceItem 字段）、`attempt`（判过几次）、`round_id`、`judged_at`；判过两次还不合规的是 `result: null` 加 `dropped`（`invalid_increment`），非 null 却没有 `occurred_at` 的也是 `result: null` 加 `dropped`（`occurred_at_missing`）。
- 等重判：没有 `result`，`rejected` 是历次拒绝的 `code` 与 `round_id`，`attempt`。
- 判断失败过：没有 `result`，`judge_failures` 是历次没判成的 `reason`（`answer_unreadable`、`unanswered`、`no_result`）、`round_id` 与 `alone`（那一批是不是只有它一条候选），可以和 `rejected`、`attempt` 同在。单独判失败满 3 次的是 `result: null` 加 `dropped`（`judge_failed`），`judge_failures` 留着。判成了就按「判断」改写，`judge_failures` 不留。
- 等读回：判断之外多一个 `conflict`（报冲突的那一轮）。

### rounds/

`round_id`（`<UTC 时刻>-<随机>`）、`agent`、`format`、`trigger`（`session_end` 或 `waited`）、`started_at`、`finished_at`、`taken`（判断了几条）、`accepted`（收到回执几条）、`nulls`、`rejected`、`screened`（这一轮落地的挡下条目几条）、`calls`（每次调用的种类 `prepare`、`judge`、`send`、`report`、`audit`（每周复核），退出码、秒数、是否超时、失败类别、用量，以及 Claude Code 的 `visible_tools`：模型看得到几个 world 工具，判断那次是 0，`requests`：这次调用里模型请求了几次，预检问到 world 没连上、没调模型的那次是 0，用量也记 0；Codex 这两项是 null）、`exit_code`（最后一次调用的）、`usage`（合计）、`failure`、`mismatches`、`failed_batches`（回复读不出的批：第几批、`detail`、这一批的条目）、`imports`、`report`（回执交上去没有）、`backlog`、`audit`（这一轮末尾的每周复核，见「每周复核」）、`next_round_at`（按「起轮决定」的间隔，这种格式的下一轮最早几点；日进展的查漏照它报）。

### 失败

`failure` 是 `{class, detail}`，按退出码和输出分五类：`program_missing`（找不到程序）、`login_invalid`（模型那边的账号或登录失效，例如 401）、`world_unavailable`（没装 world 插件、world 连不上或没登录、world 的工具报错；Claude Code 预检问到 world 不是 `connected` 时 detail 是 `mcp_<状态>`，例如 `mcp_needs-auth`，见「后台轮」）、`network`、`other`（超时、输出读不出、选择已变、目标为空等）。准备或判断那次调用失败，这一轮到此为止。失败时条目都留在队列，已落盘的判断留着，下一轮接着做；这一轮不报回执，下一次成功时的回执里有积压条数。某一批的回复读不出不算这一轮失败（`failure` 仍是 null），只记进 `failed_batches`；但两轮的间隔按失败算（见「起轮决定」），日进展的查漏另报这几批。不跨 Agent 兜底：Claude Code 的条目不交给 Codex 判。

### 时限

一轮硬时限 20 分钟（`ROUND_LIMIT`，1200 秒）。准备和判断每次最多 5 分钟，并且要给送出（最多 4 分钟）和回执（最多 5 分钟）留够时间，不够就不再起新的一批；到点 CLI 先收 TERM、再收 KILL（Windows 上 `taskkill /T /F`），这一轮记 `other`/`timeout`。

## 开始采集与迁移

三个子命令给「开始采集」那次对话里的 Agent 用（流程在 `world` 插件的 `world-capture-start` 技能里）。每次在标准输出上交一行 JSON（UTF-8），标准错误不写；`enable`、`import` 拒绝时退出码 1，交回 `{"ok":false,"reason":"…"}`，什么都不写。选择记录文件是 world 交回的 `selection` 对象（`world_app_sources_select` 或 `world_app_sources_read`），原样存成 JSON。

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

## 回退到组件

**`export <Agent> [<选择记录文件> <读回记录文件>]`**：迁移的反方向，插件出了问题、要退回 World Capture 组件时用；做法与前后步骤见 `docs/world-capture-rollback.md`。把插件已处理的条目写进组件检查点 `source-<选择>.json` 的 `progress.entries`，置空它没收尾的送出计划 `pending`，组件之后不再重判、重送这些条目。组件目录只改检查点这一个文件，改之前的原样存进 `export/source-<选择>.json`（已有就不覆盖）；`format`、`source_hash`、`progress.context_hash`、`progress.files` 原样不动。

不带文件时只看，什么都不写：交回 `dry_run: true`、`configured`（`config.json` 里还有没有这种 Agent 的合用项）、`round_running`、`added`（不含读回会找到的）、`pending_cleared`、`readback`（要读回的条目，`item_id`、`item_version`）、`rejudge`（只数等重判的；读回没找到的，做的时候再加上）。

要过的关，按顺序，不过就拒绝、什么都不写：

| `reason` | 情况 |
| --- | --- |
| `selection_file_missing`、`readback_file_missing` | 给了选择记录却没给读回记录，或文件不在 |
| `component_missing`、`component_running`、`component_settings_unreadable`、`component_format_mismatch`、`component_no_selection`、`component_capture_enabled` | 同 `import` |
| `config_unreadable`、`device_mismatch` | 同 `import` |
| `export_record_unreadable` | `export.json` 在、却读不出 |
| `not_migrated` | `config.json` 里没有这种 Agent 的合用项，也没有上次做到一半的 `export.json`：只交回迁移来的那一项，不要先手工摘掉它 |
| `selection_mismatch` | 那一项、选择记录不是组件的那项选择 |
| `checkpoint_unreadable`、`checkpoint_without_progress` | 组件检查点不在、读不出，或还没有进度 |
| `selection_not_active`、`selection_version_changed` 及 `import` 的其余选择关 | 选择记录不再生效，或版本和那一项记的不同（组件检查点按选择版本认人） |
| `readback_unreadable`、`readback_mismatch`、`readback_incomplete` | 读回记录不是 `{selection_id, complete, imports: [...]}`、不是这项选择的，或 `complete` 不是 true |

读回记录由 Agent 写：用 `world_app_sources_imports`（`selection_id` 填这项选择）翻完所有页，把每页的 `items` 接起来放进 `imports`，翻完才写 `complete: true`。只用每项的 `selection_id`、`source_item_id`、`source_version`。

过了关，按顺序：

1. 这种 Agent 在 `config.json` 里还有合用项时，先在 `export.json` 记下它（`format` 为 `world-capture-export/0.1`、`agent`、`selection_id`、`entry`、`started_at`、`done_at: null`），再从 `config.json` 摘掉它，别的 Agent 的项和 `device_id` 留着。从这时起钩子不读这种 Agent 的会话、不起后台轮。
2. `round.lock/` 在、又不比硬时限老 10 分钟以上：拒绝 `round_running`。从这一步起的拒绝（`round_running`、`state_unwritable`、`component_unwritable`、`failed`）都已经做过第 1 步，等原因过去再跑一次，按 `export.json` 接着做；在这之前的拒绝什么都没写。新的一次在第 1 步还删掉上一次回退存的 `export/source-<选择>.json`，它已经不是这一次「改之前」的那份。
3. 算要写进 `entries` 的条目：`delivered/<格式>.jsonl` 的每一行（各种 `status`）；`results/` 里还没进 `delivered/` 的，判为 null 的记上，判了非 null 的看读回记录，world 里有这个版本的记上，没有的留给组件重判（`rejudge`），等重判的（没有 `result`）也留给组件。插件的判断不交给组件：判得早的到组件送出时目标可能已经变了，模型抄错骨架、world 照收的那份也可能和落盘的不同，原样再送会被拒或冲突，组件碰到这两种都会停住。同一个 `item_id` 有几个版本时取时刻最晚的（`delivered/` 按 `at`，`results/` 按 `judged_at`，相同时取 `delivered/` 的）；`entries` 里已有、值不同的，用插件的。`results/` 里读不出的文件只跳过它自己。留给组件重判的条目里，迁移时从组件带过来的那种（`round_id` 为 `import`），组件的待提炼文件里还存着它当初交回的结果，组件会原样再送、不重判；export 不改待提炼文件。
4. 存一份改之前的检查点，写新的检查点（临时文件再改名），在 `export.json` 记上 `done_at` 和下面几个数。

成功时交回 `ok`、`agent`、`selection_id`、`already: false`、`added`（`entries` 里新增或改了的条数）、`pending_cleared`、`readback`、`found`（读回找到的）、`rejudge`。做完以后再跑（`config.json` 里没有这种 Agent 的合用项、`export.json` 有 `done_at`），交回 `already: true`，什么都不改；只有组件检查点又和 `export/` 里存的那份相同时（本人从备份恢复了组件目录）才再做一次。之后要切回插件，照迁移再跑一次 `import`：它把这一项写回 `config.json`，再退回就是新的一次 `export`。`results/` 和 `queue/` 不随 export 交出去，切回以后插件会照旧送它回退前判的那几条；world 拒了的照「后台轮」重判，报冲突的读回。

## 参数

| 参数 | 值 | 理由 |
| --- | --- | --- |
| 开头摘要的长度 | 4096 字节，且不超过已读字节数 | ADR 决定一写的 4 KiB；限于已读部分，小文件续写不误判 |
| 起轮的等待 | 30 分钟 | 与现在的自动整理相同 |
| 临时目录残留 | 超过一天删掉 | 正常运行结束时就删了，残留只来自中途被杀的运行 |
| `first_seen_at` 的精度 | 秒 | 与 0.1.7 的两份脚本同一种格式（`date -u` 只到秒） |
| 每批、每轮 | 30 条候选一批、5 批一轮 | 判断不带工具以后，一次调用的固定部分只剩系统提示和规则；每批还带着前后文和目标。一批候选原文合计仍不超过 60000 字，前后文不算在内 |
| 前后文 | 候选前后各 3 条，另算，每条最多 1500 字（超过的交头 1000、尾 500） | 结论和时刻常写在相邻的条目里；前后文只占提示词的一小部分 |
| 规则 | 用户消息和不到 300 个 UTF-16 码元的答复不判，`screen_short` 打开才用 | 用户消息几乎从来不是要记的进展，短答复也很少是；这条线可能挡掉别人写得短的结论，所以缺省关着 |
| 可判时机 | 后面有 3 条、会话结束，或会话静默 30 分钟 | 前后文要等它产生；30 分钟同起轮的等待 |
| 回执的积压清单 | 最早 20 条，条数照实报 | 要求 world 服务已允许清单只列一部分（有积压时至少列一条）；旧服务端要求列满 `min(积压, 200)` 条，会对回执报 422，所以先部署服务、再发这一版插件 |
| 两轮的间隔 | 30 分钟，连续失败翻倍，最长 4 小时；登录类失败（`login_invalid`、`world_unavailable`）不翻倍（本人 2026-11-19 定） | 翻倍与原来的自动整理相同；登录类的失败要等本人登录，翻倍只会让本人登录好以后白等几小时 |
| 一轮的硬时限 | 20 分钟 | 估计的一轮最长约 15 分钟：判断 5 批各一两分钟、送出与回执各一两分钟；锁再宽 10 分钟 |
| 被拒后重判 | 最多判两次 | 第二次还被拒就当 null，不一直重判 |
| 没判成后重判 | 单独判，满 3 次还没判成就当 null（`judge_failed`）；只和别的候选一起整批答坏过一次的先整批再判一次 | 坏的那条不一直留在队列、每轮拖着同批的条目和两轮的间隔；一批 30 条偶尔答坏一次就拆成 30 次单独调用太贵 |
