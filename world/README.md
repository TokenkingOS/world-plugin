# world 接入包

工程包版本：0.12.4。需要 world 服务 v0.11.0 及以上。0.12.4 起刚登录时看不到 world 的工具，Agent 会先请本人再问一次或新开对话，不再说成服务端缺工具，并写明需要的 world 服务版本；0.12.3 起 Claude Code 里的连接改回 `plugin:world:world`（桌面端连接器显示 World），从 0.12.2 更新后要重新登录一次；0.12.2 曾把 Claude Code 里的连接键改成 `app`，更新后要重新登录一次；0.12.1 只改了措辞，行为不变。0.12.0 起带 `world-ask`（问事）和 `world-daily`（写日报，收集会话的脚本随包带），本人动作支持登记、撤销委托，老入口 2026-11-20 下线；0.11.2 起 Claude Code 也能后台自动整理待提炼（macOS），整理技能只记对得上目标验收条目的事；各技能写明服务忙（503 `SERVICE_BUSY`）时怎么等、怎么重放，与证据存储不可用分开；0.11.0 起有本机采集组件的“原来源 Agent 在线提炼”技能，组件安装、登录与真实运行另行验收。

本包提供远程连接、身份与能力核对、工作查询与普通事实记录，以及获准工作来源归位、对话内单项 Task 修改、本人门、创建/指派、生命周期操作和委托登记与撤销。使用既有 world 账号，问事、记事、办门不需要安装 Python、配置环境变量或维护脚本；用 `world-daily` 写日报和日终查漏要本机有 Python。

## 安装或连接

- 支持 Agent Plugins 的宿主可加载根目录 `plugin.json` 和 `mcp.json`。
- Codex：运行 `codex plugin marketplace add TokenkingOS/world-plugin`，再运行 `codex plugin add world@tkos-world`；包内附兼容清单。然后运行 `codex mcp login world` 登录（会打开浏览器）。也可在 MCP 连接界面添加 `https://world.tokenkingos.com/app/mcp`，选择 HTTP/Streamable HTTP，并通过 Authenticate 登录。
- Claude Code：运行 `claude plugin install world --marketplace TokenkingOS/world-plugin`，再运行 `claude mcp login plugin:world:world` 完成 world 的 OAuth 登录（会打开浏览器），也可在 MCP 管理界面登录。
- Grok 或其他兼容 Agent 可在其 MCP 连接/登录界面使用同一地址。标准连接能力开放；本包未声明 Grok 支持与 Codex/Claude 相同的插件安装格式。

本人在登录页填写账号，选择公司后回到对话，问「核对 world 的身份和可用能力，再看我负责的工作」。先确认显示的是本人及正确范围。刚登录的那个对话里，Agent 可能还看不到 world 的工具：再问一次，不行就新开一个对话；不要据此认定服务端缺工具。

记录普通事实时会先准备准确请求，再经原记录工具提交，并分别读回回执和事件。修改 Task 或办理本人动作时，先展示准确一项及其版本、来源、参数、影响和所需角色，明确确认后提交并核对真实业务状态。动作以支持清单为准，含登记与撤销委托，不含凭证或身份管理。

已选择同步的必要待处理摘要、准确请求和结果保存在 world 应用，登录同一本人和公司后可在其他 Agent 查询、继续或拒绝。原始聊天与未同步来源草稿留源；保存、准备和业务执行分别表达，待治理确认不会显示成已正式确认。

## 问事与日报

问公司战略、目标、Mission、Task、谁负责、进展、为什么做、最近发生了什么，用 `world-ask`（Codex `$world-ask`，Claude Code `/world:world-ask`）。它按六问回答并标出处；记事交给 `world-record`，办门交给 `world-personal`。

写每天的进展用 `world-daily`（Codex `$world-daily`，Claude Code `/world:world-daily`），定时任务的提示词写 `$world-daily 定时运行` 或 `/world:world-daily 定时运行`。配置沿用 `~/.tkos-world/daily.json`。它用随包的脚本选日、读本机会话，写日报和只查漏都要本机有 Python：先用 `~/.tkos-world/venv` 里的，没有再用 `python3`（Windows `py -3`）。没有 Python 时先用 `world-record` 在对话里记。

## 获准来源归位

可以在对话中说「选择这份会议结论或工作交接，核对要进入哪个 Task」。先展示来源位置和版本、目标 Task、当前公司及可见人群，再分别核对读取来源和转存必要增量的依据。确认来源选择只保存这项授权范围，不批准 Task 修改，也不扩大来源平台或 world 的访问权限。

获准的普通进展进入准确 Task 的事件和未经确认状态；工作结果、计划、标准或依赖变更保存为待本人审阅的准确差异。建议、问题、目标不明、缺事实时间或冲突会保留原因和处理人，不猜建 Task。处理后查询实际 Task 字段、事实时间、来源和回执；跨 Agent 可继续已保存的待办与待确认事项。

撤销来源选择会停止该来源后续受管理的新写入，历史记录及原回执仍可核对。这里只接通已获准的必要工作增量；自动发现、持续采集和离线回补由后续任务交付。天枢会议 v2 目前按固定契约样例验证，尚未完成真实服务联调。

来源被更正或旧资料迟到时，可直接说「核对这项来源变化影响的字段和待办」。插件追溯真实 world 更正链，停止尚未执行的准确旧请求，并保存可跨 Agent 继续的复核事项。已经提交的原请求和回执保留；需要改字段时重新展示差异并取得针对新请求的本人决定。没有可信关联的新版本保持待核，不自动回滚其他有效修改。流程见随包的 `world-source-corrections` 技能。

来源异常提醒使用官方飞书登录核验和本人确认，配置与绑定状态可通过 `world_app_sources_notification_connection` 查询。默认未配置不会冒充 connected；正常安静，持续故障或必要本人处理时合并提醒，有已知消息 ID 才更新恢复。原发送结果未知时停止盲重发并交维护方处理；发送回执不表示业务完成。服务端 app 配置、真实本人绑定与实际发送需另行验收，不能借其他 Agent/CLI 凭据。

## 当前验证边界

可直接问「这些来源覆盖到哪里、卡在哪、各阶段用了多久」。`world-source-status` 使用只读来源查询，区分真实历史、当前字段/依据、具体待本人事项与恢复职责；五分钟和一分钟只按试点目标分别报告成功、受阻、超时和未知，不宣称生产 SLA。

本机 World Capture 组件显示“待提炼”时，可在对应 Agent 中显式调用 `world-source-extract`（Codex `$world-source-extract`，Claude Code `/world:world-source-extract`）。Agent 只处理自己格式的条目，经本机通道交回 null 或有限结果，组件用自己的连接送出；Agent 全部关闭时保持待提炼并显示覆盖缺口。

**自动提炼（macOS，Codex 与 Claude Code）。** 插件给两个 Agent 各带一份 hook 配置（`hooks/codex.json`、`hooks/claude.json`，各只被自己的 Agent 加载），共用 `hooks/auto-extract.sh <agent> <事件>`：会话开始、每轮结束、会话结束时只读组件的通道描述文件、问组件一次。组件正在采集调用它的这个 Agent 的会话（描述文件里的来源格式与它一致；Claude Code 的 hook 不替 Codex 整理，反过来也一样）、有待提炼，且最早一条已等 30 分钟以上（或本会话结束）时，hook 在后台另起一轮：Codex 用 `codex exec --ephemeral --ignore-user-config`，Claude Code 用 `claude -p --no-session-persistence --safe-mode`（在一个空的临时目录里、清空环境运行）；两种都不留会话文件，也不加载本人的配置、MCP 和插件 hook。Codex 那一轮只能读组件目录；Claude Code 那一轮读不到主目录、临时目录和外接卷，只放行组件目录和本轮临时目录；两种都写不了组件目录，网络只到 127.0.0.1；每轮最多 5 批、每批 20 条，交回后结束，不打扰当前对话。同一时间只跑一轮。时间、条数和用量记在组件里，窗口「详细信息」可看可关；关闭后回到手动调用。Codex 首次安装插件、以及之后插件更新改动 hook 时，要在 Codex 里审核并信任一次。Windows、Grok 仍用上面的手动调用。

清单校验、隔离的真实 MCP 协议测试与成员在干净客户端完成安装登录是不同检查。各参考客户端及系统组合的实际安装、登录、来源覆盖与跨端连续性由验收记录确认，不能从包格式校验推定通过。

本包需要提供 `/app/mcp` 和 `world_app_*` 工具的服务版本。部署升级前，旧服务缺少入口或工具时，相应流程仍未接通；此源码交付不表示线上服务已升级。原 `/mcp` 继续提供冻结的 Agent 连接，到 2026-11-20 18:00（UTC+8）和本机 MCP、`/tkos-world`、`/tkos-world-daily` 两个老技能一起下线，之后只留本插件。

