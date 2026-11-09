---
name: world-source-extract
description: 本机 World Capture 组件显示“待提炼”时使用；由原来源 Agent 读取属于自己来源格式的待提炼条目，交回 null 或有限 SourceItem，再核对组件送出的结果。原文留在本机，令牌不经手。
---

本技能只在本机 World Capture 组件已启用时有用。组件用自己的 world 连接送出结果；你不取得、不打印组件的 world 令牌，组件也不读你的凭据。建议本人显式调用（Codex `$world-source-extract`，Claude Code `/world:world-source-extract`，其他 Agent `/world-source-extract`），这样这次提炼会话本身不会再被采集成新的待提炼。

Codex 或 Claude Code 在 macOS 上装了 world 插件、组件里没关「自动整理」时，待提炼等够 30 分钟或会话结束，插件会在后台另起一轮自动跑本技能（只放行组件目录和本轮临时目录、只连 127.0.0.1，一轮最多 5 批、每批 20 条）；本人不用再手动调用。`/v1/pending` 返回的 `targets[]` 是本人所选 Task/Mission 的当前版本，带着它们的验收条目和近期已记事实，判断标准见「什么值得记」。

## 只处理自己的格式

| 当前 Agent | 可处理的 `source_format` |
| --- | --- |
| Codex | `codex-rollout-jsonl/1` |
| Claude Code | `claude-session-jsonl/1` |
| Grok | `grok-updates-jsonl/1`、`grok-history-jsonl/1` |

先读通道描述文件：macOS `~/Library/Application Support/World Capture/capture/agent-channel.json`，Windows `%APPDATA%\World Capture\capture\agent-channel.json`。取其中 `base_url`、`header_file`、`source_format`。`source_format` 不属于你时停止，告诉本人打开对应的 Agent 处理；不要替其他 Agent 提炼，也不要自己去找会话文件或其他目录。文件不存在或连接被拒绝，表示组件未运行或未启用采集，请本人打开组件并启用；不要重试别的端口，也不要用旧的描述文件或别处记下的端口。

`header_file` 里是本次组件启动的本机通道密钥：只用 `curl -H @<header_file>` 引用，不要 cat、复制、粘贴或写进命令参数和回复。Windows PowerShell 用 `curl.exe`。

## 取待提炼原文

```sh
curl -sS -H "@<header_file>" "<base_url>/v1/pending?format=<source_format>&limit=10"
```

返回 `items[]`：`item_id`、`item_version`、`locator`、`role`、`reported_at`、`text`，以及本人时区 `time_zone`；`waiting_for_source` 是暂时读不到原文的待提炼数（来源末行或本轮尚未写完）。只剩这类条目时如实说明，等本轮结束后在新会话中再处理；Grok 在同一会话内提炼时，本会话正在进行的这一轮未完成，同文件的条目要等它结束。text 是组件按定位从原来源重读的原文，只在本轮使用，不要复述进回复。另有 `targets[]`，每项是本人所选的一个 Task 或 Mission：`ref`（`<id>@<版本>`）、`type`、`title`、`field_key`（这个目标的普通进展写在哪里）、`criteria[]`（`id`、`kind`、`text`：它的结果、验收标准、里程碑、Task / Activity 全景条目）、`recorded`（近期已经记下的事实，每条 `occurred_at`、`source`、`text`；读不到时是 null，不是没有）。403 `format_not_owned` 是格式不符；403 `source_authorization_changed` 是来源或角色授权已变化（重读原文的途中撤销也返回它），403 的其他 code（如 `source_location_changed`）是来源位置或选择需本人处理，503 `authorization_unavailable`、`target_unavailable` 等是暂时无法核对授权、读取来源或读取目标：这些都停止，按原 code 告诉本人，不要说成“来源还没写完”；409 是组件未在采集。交回结果时收到同样的错误，处理相同。

## 什么值得记

提炼不是记流水账：只交能推进目标验收的结果，其余一律交回 null。判断前先读 `targets[]` 里各目标的 `criteria` 和 `recorded`。

- **该记的**：能对上目标 `criteria` 里某一条（验收标准、结果、里程碑、Task / Activity 全景条目），或者改变了它的状态（完成、受阻、偏离）的结果。`value` 以 `【<criteria id>】` 开头，后面写一句结论，再写依据的性质（实测、对方报告、推断）。一段原文同时涉及几条 criteria 时，选改变最直接的一条开头。
- **一律交 null 的中间步骤**：PR 开了或合并了、组件或插件装了、换了版本号、写了草稿或 ADR、给同事发了文档或消息、结构重构、跑了测试、讨论和计划本身、关于提炼本身的对话。只有它直接改变了某条 criteria 的状态才算，例如「真实 Case 的确认、事件、读回第一次对上」。
- **对照**：目标有 criteria `ac-2`「真实 Case 全链路读回一致」。原文「今天 10:20 拿真实 Case 走了一遍，确认、事件、读回第一次对上了」，交 `value: "【ac-2】真实 Case 的确认、事件、读回第一次对上（实测）"`，`occurred_at` 取 10:20。原文「PR 已合并，版本号升到 0.2.0」，没有说明任何一条 criteria 因此达成或受阻，交 null。目标有 criteria `ac-4`「条件未满足时明确缺口、影响与责任方」，原文「16:02 用合成数据重跑联测，对方产品对平常问题取不到 world 里的跨人依赖，已告知对方」：跑测试本身交 null，跑出的这个缺口对上了 ac-4，交 `value: "【ac-4】对方产品对平常问题取不到 world 里的跨人依赖（合成数据实测），已告知对方"`，`occurred_at` 取 16:02。
- **去重**：同一批里说的是同一件事的，合成一条交在最能代表的那个条目上，其余交 null；本轮前几批里你自己已经交回的，也不再重复交。`recorded` 里已经有的事实，不论措辞怎样都交 null。`recorded` 为 null 表示没读到，这时只做上面的批内和本轮内去重。
- **时间**：`occurred_at` 只用原文写明的、或可由原文相对时间按这条的 `reported_at` 换算的真实时刻。给不出就交 null，不用 `reported_at`、文件时间、现在顶替，也不留给本人补。
- **目标**：`target_ref` 只用 `targets[].ref`，`field_key` 用同一项的 `field_key`。对不上任何目标就交 null，不要省略 `target_ref` 留给本人归位。返回了条目而 `targets` 为空时，不交回任何结果，告诉本人组件读不到目标；交 null 会把条目永久判成无增量。组件读不到本人所选的目标时，`/v1/pending` 返回 503 `target_unavailable`，按上面的 503 停止。
- **被拒绝时**：收到 `occurred_at_missing`、`target_not_selected`、`criterion_unlinked`，同一个 item 改交 null，或按提示修正后重交一次；不换 `item_id`、`item_version`。

## 逐条提炼

每条只能交回两种结果之一：

- `null`：已检查，没有需要进入 world 的业务增量。
- 有限 SourceItem，只含 `classification`（fact/decision/suggestion/question/unknown）、`target_ref`、`field_key`、`value`、`quote`、`occurred_at`、`links`、`source_event_ref`、`constraint`。

沿用 world-sources 的必要增量规则：`quote` 不超过 2000 字符，只是必要短依据；`value` 不超过 4000 字符或不超过 50 个短字符串。不传整段聊天、多轮对话、工具输出、完整提示、凭据或带凭据的链接、本机路径。`target_ref` 必须来自本轮实际读取、且已选入来源范围的 world Task@版本或 Mission@版本（只用 `targets[].ref`），对不上就交回 null，不猜。Mission 仅支持 world-sources 所述的普通进展事实位置。`occurred_at` 只用真实事实时点并带时区；不能用 reported_at、文件时间或现在顶替。原文用相对说法（今天、昨天、上午十点、刚才）时，以这条消息的 `reported_at` 为“当时”，在 `time_zone` 里换算成确切时刻：例如 reported_at 是本人时区 11 月 3 日下午，原文说“今天 10:20”，就是 11 月 3 日 10:20（本人时区）。原文没说时间，就交回 null。只知道“某 Agent 在某时报告了某事”时，value/quote 写明是未经独立核验的报告。来源里说“确认”不是本人对业务变更的批准。关于提炼本身的对话（处理待提炼、交回结果）交回 null。

## 交回并核对

一次最多 20 条，结果从 stdin 送出：

```sh
curl -sS -H "@<header_file>" -H "Content-Type: application/json" --data-binary @- "<base_url>/v1/results" <<'JSON'
{"format":"<source_format>","results":[{"item_id":"entry-…","item_version":"…","result":null}]}
JSON
```

Windows PowerShell 没有 heredoc，且管道可能改写中文编码：先用你的文件写入工具把这段 JSON 以 UTF-8 写到临时目录，再用 `curl.exe ... --data-binary "@<临时文件>"` 送出，完成后删除该文件。

返回 `accepted[]` 与 `rejected[]`。`invalid_increment`、`conversation_copy`、`local_path` 说明结果越界，按规则改小后重交；`occurred_at_missing`（没有 `occurred_at`）、`target_not_selected`（没有 `target_ref`，或它不是本人选的目标）、`criterion_unlinked`（目标有 criteria，`value` 没有以其中一条的 `【<id>】` 开头）说明这条不该照这样交：同一个 item 改交 null，或按「什么值得记」修正后重交一次；`already_extracted` 表示这个版本已交回，不能改写；`not_pending` 表示已送出、来源已变化或不是待提炼条目。不要换 item_id/item_version 重交；已送出内容的更正走 world-source-corrections。

交回后读 `GET <base_url>/v1/status`，每 3 秒一次，最多 20 次（约 1 分钟），直到 `submitted` 为 0。到上限仍不为 0，就停止轮询，如实告诉本人“组件尚未送出这些结果”，并说明组件窗口显示的状态；不要重交。再用 world 连接的 `world_app_sources_imports`（按 selection_id）和 `world_app_sources_result` 核对：`source_item_id`、`source_version` 与交回的 item_id/item_version 一致，并分别说明已交回、组件已送出、world 已接收、业务读回和待本人事项；没有读回就说未核实。`world_app_sources_runs` 里仍有 `extraction_pending` 时，如实说还有多少条待提炼。

回复只写数量、结果和本人需要做的事，不贴原文、密钥或路径。所有 Agent 都关闭时组件保持待提炼并显示覆盖缺口，这不是“没有工作”。
