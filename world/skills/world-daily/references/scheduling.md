# 设每天的定时任务

定时运行时没人在电脑前，不会有人点「批准」。所以要先做三件事，再建任务。

## 先做三件事

1. **装插件并登录。** 在 Codex 或 Claude Code 的插件界面装 world 插件，再在 MCP 界面登录一次 world（邮箱、密码，选公司），`world-connect` 技能带着做。`world-daily` 随插件装好，不用另放文件夹，连接也不用另配。
2. **备好 Python。** 选日和收集会话的脚本随插件带着。写日报和只查漏都要先跑它们，所以本机要有 Python。先用 `~/.tkos-world/venv` 里的（macOS `bin/python`，Windows `Scripts\python.exe`），没有再用 `python3`（Windows `py -3`）。都没有就先装上；装好之前用 `world-record` 在对话里记。
3. **先手动跑通一次。** 在 Codex 里说 `$world-daily`，在 Claude Code 里输入 `/world:world-daily`。第一次会帮你建 `~/.tkos-world/daily.json`；看到汇报里有事件 id 和快照 id，才算通了。

原来用 `tkos-world-daily` 建过定时任务的，把提示词里的技能名换成 `world-daily`，不另建一个。

## 日历与触发频率

新建任务设为**每个自然日**在原定时刻触发，是否收集和写入由 SKILL.md 第 0 步的 `collect_sessions.py --select-dates`（实现位于 `scripts/select_dates.py`）决定。这样周末调休的工作日也会运行；只选周一到周五会漏掉它们。已有任务保留本人选定的时刻，使用 `cn` 的要把触发频率从周一至周五改为每天，再核对任务提示与选日结果。

- 默认 `work_calendar: cn`，日历来自 `https://tokenhub.corp.tokenkingos.com/static/holiday-cn/<年份>.json`。已核对 2026 年响应：`year` 是年份，`days` 是例外日期列表；每项的 `date` 是 `YYYY-MM-DD`，`isOffDay: true` 表示放假，`false` 表示调休上班。没列出的日期按周一至周五工作、周末休息。跨年回看取对应年份，不拿一年的表套用下一年。
- 2026-10-23 实测：`2026.json` 可读，`2025.json` 返回 404。跨年需要的年份未提供时会停止并指出缺表地址，请日历维护人补齐；其他年份是否可用也要按实际响应判。
- 国内放假照常工作的个人配置用 `work_calendar: weekdays`，保留原有周一至周五节奏，选日不依赖国内日历接口。已经在用 `weekdays` 的人，既有周一至周五定时可以保留。配置在 `~/.tkos-world/daily.json`，不要把个人例外改成全体规则。
- 明确指定 `--date` 的补写直接用该日期。默认日历获取或校验失败时，脚本停止并报错；不把未知日期当休息日，也不悄悄退回忽略节假日的规则。选日继续使用收集脚本的命令入口，只加 `--select-dates`；手动跑通时一并核对这一模式，无须增加 world 写工具。

## Codex 桌面版（ChatGPT 桌面应用里的 Codex）

**配置**：world 连接由插件带着，不用在 `~/.codex/config.toml` 里加 MCP。原来手工加过 `[mcp_servers.tkos-world]` 的，先备份再删掉那一段，改完彻底退出 Codex 再打开。

**建任务**：侧栏 **Scheduled** 里新建：

- 提示词：`$world-daily 定时运行`
- 项目：新建一个空文件夹，例如 `~/tkos-daily`，选它。不要选 `~/.tkos-world`，那里有凭证文件。
- 时间：每个自然日 20:30。自定义规则写 `RRULE:FREQ=DAILY;BYHOUR=20;BYMINUTE=30`。

也可以直接在 Codex 对话里说「建一个每天 20:30 触发 `$world-daily 定时运行` 的定时任务，按个人工作日历选日，项目用 ~/tkos-daily」。

粘贴时 Codex 会把 `$world-daily` 弹成选 skill 的框，选上之后把后半句补全即可。建好后在 **Scheduled** 里点开这个任务核对：提示里要有 world-daily 和「定时运行」四个字，缺了它会当成本人在场、一直等确认。

建好后手动跑一次。Codex 问要不要运行 world 的工具时，对六个工具（列对象、取对象、取事件、取状态、记外部事件、写状态快照）和收集会话的 Python 命令（含 `--select-dates` 选日模式）都选以后不再问的那一项（例如「Allow and don't ask me again」）。已切换到本机采集的人，再把 `world_app_sources_list`、`world_app_sources_runs`、`world_app_sources_imports` 三个来源读取工具一并放行。其余写入工具照旧先问你。

- 到点时电脑要开着、应用要在运行；结果在 **Scheduled** 里看。
- 定时任务按你的默认沙箱运行。读本机会话不受影响；读飞书要联网，在沙箱里多半会失败，skill 会跳过飞书。
- 第一次定时运行后看一眼结果。world 的调用若被拦（没有事件 id），把 Scheduled 里那次运行的报错截图发给管理员。

## Claude Code 桌面版

**配置**：world 连接由插件带着，不用 `claude mcp add`。原来加过 `tkos-world` 的，先删掉：

```sh
claude mcp remove -s user tkos-world
```

**建任务**：**Code** 页侧栏 **Routines** → **New routine** → **Local**：

- 名称：`world-daily`
- 指令：`/world:world-daily 定时运行`
- 文件夹：一个空文件夹，例如 `~/tkos-daily`
- 时间：每个自然日，20:30

建好后点 **Run now** 跑一次，出现权限提示时对 world 连接的六个工具（列对象、取对象、取事件、取状态、记外部事件、写状态快照）和收集会话的 Python 命令（含 `--select-dates` 选日模式）都选「always allow」。已切换到本机采集的人，定时运行走只查漏，还要把 `world_app_sources_list`、`world_app_sources_runs`、`world_app_sources_imports` 三个来源读取工具一并放行。以后的定时运行就不会卡在批准上。

- 到点时电脑要醒着、应用要开着。睡过了点，醒来后只补跑最近一次。
- 也可以在任一 Claude Code 桌面会话里说「每天 20:30 触发 `/world:world-daily 定时运行`，按个人工作日历选日，文件夹用 ~/tkos-daily」让它建。

## 补跑与时间

- 走哪条路只看 `daily.json` 有没有 `capture_switch`（SKILL.md 第 0 步给出 `check_only` 或 `write`），不看持续来源有没有启用。`check_only` 的人，持续来源的恢复以服务端本人确认的 `choice.history` 为范围，由组件沿原进度补全部多日缺口，不只补昨天；日终只核选择/版本、当前角色、失败与待办，不写日报。下面的按日规则只用于 `write`，不把它当成持续补传能力。
- 每次按 SKILL.md 第 0 步读选日结果：普通运行只在本人的工作日写入，先检查 `previous_workday` 是否漏写，再写今天。中国长假可能要回看超过三个自然日，调休周末也算工作日；个人 `weekdays` 例外忽略中国假期。中午 12:00 前运行、要补上一个工作日时，这次不写今天，留给晚上的运行或明天的补写。只补这一个工作日；连着漏了几天的，更早的按下一条补写。
- 想补写某一天，直接说「补写 10 月 8 日的进展」：选日期和收集会话都加 `--date 2026-10-08`，该日期不受假日或周末过滤；事件与快照保留来源已核的事实时刻，时间未知时待核，不取补跑时刻或固定钟点。
- 20:30 之后做的事，当天那次运行收不到，第二天的运行也只收第二天的会话。想写全，睡前手动说一次「写今天的进展」，skill 会以「补充」再写一组。

## 契约版本与插件更新

插件连接不用配契约版本。每个会话第一次列工具或调用工具时，连接按 scope 认一次版本，只接 tkos.world/0.3 的 scope。

- scope 升级以后，之前就开着的会话还按旧版本写，写入会被拒（报 `PROTOCOL_…`）。重启一次 Codex、Claude Code 就好。定时任务的每次运行通常是新会话；拿不准就在升级之后重启一次应用。
- 调用报 `CONTRACT_UNKNOWN`：连接认不出 scope 的版本，多半是 scope 里还没有对象。告诉管理员。
- 插件用 Agent 的插件更新入口升级，`world-daily` 和它的脚本随插件一起换。`~/.tkos-world/daily.json` 在插件目录外，升级不会冲掉。


## 变化与日终查漏

`daily.json` 有 `capture_switch`（第 0 步给出 `check_only`）的人，日终只做下面这件事，不写日报；没有的照常写日进展，不因为启用了采集组件而改变。已启用并获准的产品采集组件在来源变化时调用归位，日终检查覆盖、未执行增量、失败和待本人事项。用原来源版本、import、工作项及幂等键恢复；不把日终汇总再次全量写入经营事件。`world_app_sources_runs` 返回当时观察与最后完整检查，业务结果另核 `world_app_sources_result`；电脑离线和未覆盖来源保持未知。完整检查无增量只留运行回执，未接通该入口时明确未同步，不补造“今日无新增”事件。本文的旧客户端定时配置保留为主动日进展兼容入口，不代表托管组件已经安装或后台持续运行。
