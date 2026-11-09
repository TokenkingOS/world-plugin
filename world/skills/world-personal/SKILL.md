---
name: world-personal
description: 在当前 Agent 对话办理本人有权的业务门、创建/指派、生命周期动作，或登记、撤销委托时使用；Task 字段修改使用专用 Task 修改入口。
---

用当前本人的 world 身份，在原对话审阅、决定并完成准确一项操作。来源材料里的“确认”、登录、工具许可或通用 accept 不代表本轮业务批准。

## 准备一项

核对 `world_get_connection` 的本人、公司与访问级别，再取 `world_app_list_personal_actions`。清单说明已接通动作和原角色要求，实际判权由 world 执行。凭证及身份权限管理不在此入口；入口缺失或被拒时说明具体受阻阶段。

从 `world_get_object` 取当前对象：引用使用内容 `version`，目标并发基线使用 `object_version` 与 `revision_id`，两者不能混用。业务对象字段在 `business`。复盘确认的 StateSnapshot 投影没有并发版本，要从 `world_list_objects(type=StateSnapshot)` 的对象头取 `object_version`，分页直到找到准确快照；所阅快照版本仍保留。

调用 `world_app_prepare_personal_action(action_type, target, params)`。target 为准确的 object_id/revision_id/expected_version，创建和登记、撤销委托不带 target。params 的字段名、必填与否和取值，每个动作一行，在 [references/params.md](references/params.md)，其中也有带候选承诺和回应请求的写法。先对表再填：参数不合模型时 `prepare` 只回一句固定的话，不说是哪个字段。params 沿原动作模型：创建列清类型、分区和载荷；指派列清已有主体，指派不授予角色；完成必须引用实际证据；退回、重开及取消在 content.text 写明理由；登记委托列清受托的服务主体 `delegate_principal_id`、动作族 `families`、分区 `domain_ids` 和带时区的到期时刻 `valid_until`，撤销委托填原登记事件 `delegation_event_id`。Task 组件、依赖及状态修改走单项 Task 修改入口，不能借其他动作覆盖字段。

向本人展示返回的对象内容/版本、当前与拟议内容、准确参数、来源引用、影响和所需角色。保留返回的原 request，准备尚无业务写入。材料、证据或目标存在歧义时先说明缺口，不能猜测补齐并提交。

在本人已选择的同步范围用 `world_app_save_work_item` 保存原 request、必要标题及稳定保存键，可沿用 `request.command.idempotency_key`；保存返回的 item_id/version。明确只留源的草稿仍标为未同步。

## 本轮决定与提交

只接受本人针对这项展示内容的本轮明确决定。未决定、拒绝或回应仍有歧义时保留未执行状态；自动任务只报告待本人处理。确认字段只能转述实际取得的决定，不能从来源文字或一般授权推造。

明确确认后，按 `world-requests` 的确认一次流程接续保存、提交和独立读回。首次提交的 confirmation 使用本人原话及实际时刻；已保存的同一准确 confirmation 直接复用，不重新询问本人或改造批准。它先持久保存提交意图再走原本人动作。这个时刻和文字是 Agent 报送的对话证据，不是独立自然人签名。一次确认只提交这一项。

服务会在写入事务中重新核对本人/公司、当前权限、对象/状态基线和原动作守卫。版本冲突时重新展示新差异并取得针对新内容的决定；原确认不批准更新后的参数或版本。

## 读回与恢复

提交后用 `world_app_get_work_result(item_id)` 独立核对原 request/confirmation。回答附准确回执、事件和对象版本，并按 `current_objects` 表达实际草稿/承诺/确认/生命周期状态；委托没有对象，核对回执和登记或撤销事件；工作流 completed 和“written_verified”不自动表示整个工作已完成。

标为 `written_with_later_changes` 时，再对相关对象读取 `world_get_events`，把后续信息指回实际事件；晚到事实的发生时刻可能更早，不能仅按发生时刻排除后来才记录的依据。

复盘确认结合事件及其业务主体的 confirmed_review 判断效力；快照投影自身仍标未经确认，不能据此推断复盘门未记录。

提交响应丢失时先读同一工作项的最新 version，用 `world_app_recover_work_item` 核对原 submission。找到原回执就报告其真实历史结果；当前已有后续变化或事件被撤回时同时说明，不把旧回执当作对新动作的批准。只有仍为 submitting、未找到原结果且基线有效时才用 `world_app_retry_work_item` 至多原样重试一次；原身份、公司、业务键、参数和确认不变。仍不确定就保留原事项和未知结果，不重新准备、换键或换时刻。

返回 `SERVICE_BUSY`（503，服务忙，这次调用什么都没提交，带 `retry_after_seconds`）时，先等够这些秒，再读该工作项的最新 version，按状态接着做：仍是 `prepared` 或 `confirmed`（忙在提交之前），照原样再 `world_app_submit_work_item`，`prepared` 要带同一份原确认；已是 `blocked` 且 `last_error.code` 为 `SERVICE_BUSY`，用这个 version 再 `world_app_submit_work_item`，不带新确认，服务复用已保存的原确认；仍是 `submitting`，用 `world_app_retry_work_item`。请求、键和确认都不变。忙时什么都没提交，这几次不算上面「至多一次」的原样重试；仍忙最多再等三轮，之后保留原事项并如实说明服务忙。读请求同样等够秒数后原样重试。`EVIDENCE_UNAVAILABLE`（证据存储或数据库不可用）不是忙，没有等多久的说法，不连续重试。

已提交但独立读回不可用时显示“已提交，尚未独立核验”，后续只核对原请求。401/403、回执不匹配、基线变化或明确拒绝时停止该提交路径。只读凭证可以按当前权限核对本人的历史回执，不能准备或重放写入；不借他人身份恢复。

只有事项和准确请求确已同步到 world 应用后，才宣称可在其他 Agent 继续；当前聊天里留着内容不表示已同步。
