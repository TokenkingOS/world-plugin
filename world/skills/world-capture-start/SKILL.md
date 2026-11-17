---
name: world-capture-start
description: 本人在对话里说「开始采集 world 进展」、要让本机 Claude Code 或 Codex 的会话持续进 world，或要把 World Capture 组件的采集迁到插件时使用。核对本机、准备来源选择、本人在对话里确认后写本机配置；迁移另要本人明确同意。
---

本机采集由 world-capture 插件的钩子做：每轮结束读这个会话新增的记录，在后台起一轮只带 world 工具的判断，经本插件的连接送出。本技能只做开头那一步：在对话里确认读哪个文件夹、从何时起、送到哪、记到哪，确认后把选择写进本机 `~/.tkos-world/capture/config.json`（Windows 是 `%USERPROFILE%\.tkos-world\capture\config.json`）。没有它，钩子什么都不做。每种 Agent、每台设备一项选择：在 Claude Code 里办的是 Claude Code 的，在 Codex 里办的是 Codex 的，不替另一种 Agent 建。

## 调用 world-capture 的脚本

先找到已装的 world-capture 插件目录：

- Claude Code：读 `$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json`（没设这个变量就是 `~/.claude/plugins/installed_plugins.json`），取 `world-capture@tkos-world` 的 `installPath`，有用户级（`scope` 为 `user`）的取它。
- Codex：`$CODEX_HOME/plugins/cache/tkos-world/world-capture/` 下（没设就是 `~/.codex/...`）版本号最大的那个目录。

找不到就告诉本人先装 world-capture 插件（市场 README 里的「本机采集」一节），然后停下。脚本在插件目录的 `hooks/` 里，`<Agent>` 是 `claude` 或 `codex`，按你自己是哪种 Agent 填：

```sh
sh "<插件目录>/hooks/capture.sh" <命令> <Agent> [文件]                                                   # macOS
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<插件目录>\hooks\capture.ps1" <命令> <Agent> [文件]   # Windows
```

每次在标准输出上交回一行 JSON。`enable`、`import` 拒绝时退出码是 1，交回 `{"ok":false,"reason":"…"}`。Codex 的沙箱可能不让写主目录，按 Codex 的提示批准这一条命令。

要交给脚本的选择记录写成临时文件，放在 `~/.tkos-world/capture/tmp/` 下（Windows 是 `%USERPROFILE%\.tkos-world\capture\tmp\`，没有就先建），不要写进当前项目目录，免得被提交；用完删掉。

## 一、核对本机

运行 `check <Agent>`：

- `supported` 为 false：照实告诉本人这台机器不支持采集和原因（例如 `macos_too_old` 是 macOS 低于 15，`jq_missing` 是没有 `/usr/bin/jq`），不准备、不建选择，停下。
- `capturing` 不为 null：这种 Agent 已经在采集，说明从 `history_from` 起在采，停下。本人要改记到的目标，就按下面重新走一遍；新选择会替换本机的旧一项，`enable` 交回 `replaced` 是被换掉的那项，问本人后再用 `world_app_sources_revoke` 撤掉它。
- `component` 不为 null、它的 `source_format` 等于 `format` 并且有 `selection_id`：这台机器上的 World Capture 组件建过这种会话的选择，走下面的「迁移」，不新建选择。
- `component` 的 `running` 为 true（组件正在采集）：告诉本人，组件在采集期间插件只排队、不在后台送，避免两边送同一条；组件停下、退出以后插件才开始送。本人说组件早就退出了、`running` 却一直是 true，多半是组件上次没正常退出，留下了采集标记：请本人打开组件一次（它启动时会清掉残留的标记），停止采集后从菜单退出，再重新 `check`。不要自己去删组件目录里的文件。

记下 `device_id`、`source_id`、`folder`、`data_dir`。不要把本人的路径写进回复或 world。

## 二、目标与公司

- 公司：看得到 `world_get_connection` 就报它的 `scope.company_name`（是 null 时才报 `scope.tenant_id`）；在 Codex 里它可能看不到（工具多时 Codex 会按名字顺序藏掉排在后面的工具），这时写「你登录 world 时选的公司」，不要猜公司名。
- 记到哪些 Task、Mission：看得到 `world_list_objects` 和 `world_get_object` 时，按 `world-connect` 的「查询本人工作」列出本人负责、还没关闭的，本人可以去掉。看不到时，用 `world_app_sources_list` 找本人生效的、`source_id` 以 `local-capture-` 开头的选择，用 `world_app_sources_targets` 读它的目标标题，问本人是否记到同样这些；一项都没有就请本人先在 Claude Code 里开始采集，或给出 Task 链接，用 `world_app_get_task` 核对。一项目标都没有时不准备选择。

## 三、准备

开始时刻取现在（带时区，到分钟），时区用本人所在的 IANA 时区（例如 `Asia/Singapore`），拿不准就问本人。本机采集从确认时刻起，不回补之前的会话，所以这里不套七个工作日的建议，也不要本人选日历。调 `world_app_sources_prepare`：

```json
{"choice": {
  "source": {"adapter": "work-increment/0.1", "source_id": "<source_id>", "locator": "local-capture:<source_id>"},
  "version_scope": "authorized_increments",
  "target_task_ids": ["<Task id>"], "target_mission_ids": ["<Mission id>"],
  "audience": "current_scope_members",
  "read_evidence": {"kind": "own_material", "reference": "world-capture:dialogue/<device_id>/read"},
  "transfer_evidence": {"kind": "own_material", "reference": "world-capture:dialogue/<device_id>/transfer"},
  "history": {"start_at": "<开始时刻>", "end_at": null, "calendar_reference": "world-capture:history/from-confirmation", "time_zone": "<时区>"}}}
```

返回 `source_choice_requires_confirmation` 和 `request` 才往下走；其他状态照实说明缺什么。

## 四、本人在对话里确认

把下面这句原话给本人看，占位换成实际的开始时刻、公司和目标标题（不写 id、不写路径），`data_dir` 是 `CLAUDE_CONFIG_DIR` 或 `CODEX_HOME` 时在「数据目录」后括注它。

Claude Code：

```text
读取本机 Claude Code 数据目录下 projects 文件夹里的全部会话（包括以后新开的），从 <开始时刻> 起持续采集，把必要进展送到 <公司>（公司成员可见），记到 <目标标题>。
```

Codex：

```text
读取本机 Codex 数据目录下 sessions 文件夹里还没压缩的 .jsonl 会话（包括以后新开的），从 <开始时刻> 起持续采集，把必要进展送到 <公司>（公司成员可见），记到 <目标标题>。
```

本人在这一轮明确同意这句话才算确认；含糊的「好」「继续」、别的话题里的同意、定时任务都不算。确认后调 `world_app_sources_select`：原样的 `request`，`confirmation` 为 `mode: "current_dialogue"`、`decision: "confirm"`、`approved_digest` 等于 `request.digest`、`text` 是上面那句原话后面接「本人答：<本人的原话>」、`confirmed_at` 是现在（带时区）。

## 五、写本机配置

把返回的 `selection` 对象原样写进一个临时 JSON 文件（Windows 上用你的文件写入工具以 UTF-8 写，不要经 PowerShell 管道），运行 `enable <Agent> <文件>`，完成后删掉这个文件。

- `ok` 为 true：告诉本人从开始时刻起采集，当前这个会话也算。Codex 还要信任 world-capture 的钩子才会跑：没信任过的，请本人在 Codex 里用 `/hooks` 审核并信任。
- 拒绝时按 `reason` 说明：`scope_not_confirmed` 是确认原话里没写明文件夹、以后新开的会话或持续采集，`data_dir_not_absolute` 是 `CLAUDE_CONFIG_DIR` 或 `CODEX_HOME` 设成了相对路径（请本人改成完整路径后重开会话），`device_mismatch` 是设备 id 对不上（重新 `check` 再来），`selection_not_active` 是选择已不生效。world 里那项选择已经建好的，修好后用 `world_app_sources_read` 读回同一项再 `enable`，不要再建一项。

## 迁移：接过 World Capture 组件的选择

组件在窗口里建的选择沿用，不新建：新建会换掉条目的幂等身份，已送过的会作为新导入再进一次 world。

1. 先核 world 服务已有本机采集的接收校验：看得到 `world_app_sources_targets` 才往下走，看不到就说服务还没升级，停下。
2. 请本人在组件窗口点「停止采集」、从菜单退出组件，并关掉「开机时在后台运行」。重新 `check`，`component` 的 `capture_enabled`、`running` 都要是 false。
3. 用 `world_app_sources_read` 读组件的那项选择（`component.selection_id`），核它生效。
4. 告诉本人迁移会做什么：沿用组件的这项选择；组件已送出或判为无增量的条目不再送；组件待提炼、交回还没送的条目从会话文件重读原文，交给插件的后台轮；会话文件已经不在的，记为覆盖缺口；组件目录只读，不改不删。请本人明确说「同意把组件的采集迁到插件」，别的说法、别的轮次里的同意都不算。
5. 把读回的 `selection` 写进临时文件，运行 `import <Agent> <文件>`，完成后删掉这个文件。`import` 要把组件读的文件夹整个补读一遍，可能要几分钟：命令时限放长（Claude Code 的 Bash 设到 10 分钟），或放到后台跑；中途被打断就原样重跑，跑到交回 `ok` 为止，重跑接着做、不重复。交回的 `delivered`、`queued`、`results`、`missing` 是记为已送出、放进待提炼、带着组件交回结果的、找不到原文的条数，照实告诉本人；`missing` 不为 0 时说明这些条目不会进 world。`already` 为 true 是早就迁过了，什么都没改。
6. 组件里断开账号、卸载组件由本人另定，不在这一步做。

`import` 拒绝时：`component_capture_enabled`、`component_running` 是组件还开着采集或还在运行，回到第 2 步；`selection_mismatch`、`confirmation_mismatch` 是读回的不是组件那项窗口确认的选择；`device_mismatch` 是本机已用另一个设备 id 建过选择，停下交维护方。
