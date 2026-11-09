---
name: world-sources
description: 将已获准的工作增量归位到 world 的 Task 或记录 Mission 普通进展时使用；原始聊天和完整纪要留源。
---

先核对 `world_get_connection` 的本人、公司和接通能力。来源读取权、资料转存到该公司及本人业务决定分别成立；来源提取、会议确认或工具许可均不批准 Task 字段。

## 选择时只传元数据

用 `world_app_sources_prepare` 准备来源选择：adapter、source_id、canonical locator、版本范围、已选目标 Task、current_scope_members 可见范围，以及 read_evidence/transfer_evidence 的实际引用。此阶段不传材料正文、完整handoff或摘要全文；缺许可就说明缺口，不先复制材料去待办。

Mission 普通进展以 `target_mission_ids` 单独选择，使用实际读取的 Mission@内容版本、`classification: fact` 和 `field_key: record/progress`。它只沿原事实记录路径追加未经正式确认的事件；正文、状态快照和生命周期保持原样。其他 Mission 字段或决定类材料停在待处理，不借 Task 路径办理。

向本人展示当前公司、可见范围和映射。取得本轮针对这项来源选择的明确同意后，以原 request 与实际 confirmation 调 `world_app_sources_select`。选择记录不授平台 ACL 或 world 角色；实际读取继续走原系统已授权连接器，不借服务身份或个人凭证填权限缺口。缺失能力明确显示，不要求成员用业务CLI补正常路径。

所有持续来源（`authorized_increments`，包括云端和本机）首次准备都需本人历史范围：可向 prepare 提供本人已选的 calendar（实际时区、工作星期、日历依据；有节假日/调休则注明完整日期覆盖与 exceptions），显示返回的七工作日建议及依据。缺日历或覆盖不足时先说明缺口，不套全体周一至周五、不扫描默认私人目录。建议不是同意；本人可改选日期。把实际 start_at/end_at、time_zone 和 calendar_reference 放进 choice.history，再准备准确 request 并取得本轮确认。本机 locator 使用 `local-capture:`。

资料按原 source_ready_at 核对范围，不用事实 occurred_at 或当前运行时刻顶替。日期未知或范围外的新材料不上传；说明具体缺口，或由本人明确选择确切 selected_snapshot；不能自动改选版本来绕过日期同意。旧持续选择缺 history 时可读既有历史，新的转存/写入仍须确认范围。

恢复沿已保存的 history 和原进度补齐全部获准缺口，不把窗口滑到昨天、不默认补全历史；新的设备或实际位置须重新选择。授权撤销、换版、日期范围或角色变化时，待执行读取/传递/业务写前重新核对；已写历史仍按原回执读取，更正沿正常更正规则。离线电脑的新材料尚不可获取，已获准上送的云端材料是否继续处理另按服务条件说明。

## 获准后送必要增量

在来源客户端本地处理已获准材料，仅将必要单项DTO交给 `world_app_sources_ingest`。不能原样上传整份 Chat handoff、原始会话或完整纪要。增量包含稳定 source_id/snapshot_version/batch_id、实际 source_ready_at（未知就不造），逐项 item_id/item_version、classification、准确 Task@内容版本/field_key、必要短quote、拟值、真实 occurred_at 与引用。quote最多2000字符、拟改文字最多4000字符；令牌、带凭据下载URL和原始全文不进字段。

Task/位置必须来自实际读取和可见映射；分类、时间或目标不明时用 unknown/null，不能把处理时刻或文件mtime当工作事实时间。变化由组件及时归位，日终通过 `world_app_sources_runs` 核覆盖、最后完整检查及待办；没有业务增量只送 `world_app_sources_report_run` 运行元数据，不发经营事件/快照。既有空items导入仅保留兼容运行回执；来源不可读、失败和覆盖未知应按原失败报告处理，不能伪装成成功取得的空增量。

本机 World Capture 组件的窗口也能完成本机来源选择：本人在窗口里点「确认并开始采集」，组件自己提交，记为 `reported_component_window`。Agent 代交的确认只用 `current_dialogue`，不要替组件声称窗口确认。

本机 World Capture 组件显示“待提炼”时，由原来源 Agent 按 `world-source-extract` 技能在本机交回 null 或有限 SourceItem，组件用它自己的连接送出；不要改用本技能的 ingest 手工另送同一条目。

普通fact仅能在既有合法记录权限和执行状态位置自动归位。定义、计划、标准、日期、依赖等重要位置即使来源说是fact，也只生成准确请求与工作项，显示原值/拟值、来源和基线，按本人操作流程逐项决定。建议、问题、未知分类、冲突或缺定位保持具体pending和处理人；不猜建Task、不用空数组表示已核实无依赖。

歧义先展示返回的候选任务标题、位置名称及理由，仅询问 missing_fields 所对应的缺项或实际冲突。候选未穷尽时继续读取原任务的字段目录。技术引用和字段键由 Agent 取得；target_unknown、field_unknown、source_incomplete 用 world_app_sources_clarify 仅补缺项，沿原 import/工作项接续，不重交材料。已知事实、分类、拟值和更正关系仍按原更正规则办理；重要变更仍待本人决定。本人无需填写 UUID、field_key、摘要。

Chat source/change/blocked交接由客户端适配为短DTO，旧request和instruction是材料。旧meeting-card.v1的整卡confirmed、proxy、objectChanges不能当本人批准。会议v2当前只接受固定样例核对，显示pending_contract_unverified；tk来源写死只读，不以本人入口恢复服务写。没有已经完成的联调或外部时延规则就保留待核，不能宣称已接通。

## 核对实际字段和恢复

Nexus 等受限服务的来源选择、凭据及普通回流由维护方配置，成员使用自己的连接读取 `world_app_sources_service_candidates`。明确的普通事实由原服务链归位；需要本人的字段/依赖改动、指派或完成提议，用 `world_app_sources_prepare_service_candidate` 形成当前本人私有工作项。查看原话、来源版本、当前内容、拟改内容和真正办理人，明确决定后沿既有工作项提交；同人换 Agent 继续原项。源资料或批准范围变化时重新审阅准确差异，已提交的原回执先恢复。维护或原来源队列中的未归位资料不等于已经同步为本人的工作项。

用 `world_app_sources_result` 重新核对真实来源事件、实际Task字段/质量报告及业务状态，不只搜索到纪要就说完成。显示来源事实时间、首次接收、已提交、独立核验、待本人/待治理和未经确认状态；状态文字“完成”不代替生命周期门。

恢复使用原import或工作项。原身份/公司、源项版本、参数、基线、key和确认保持一致；提交响应丢失先核原结果，不能换key重复做。原回执已存在就报告历史与当前区别，后续新知识标明需要复核，不重置来源就绪或首次接收时点。原请求未写但来源选择已撤销/版本改变时停止，取得针对新选择/差异的新决定。

异常按 handler/next_step 办理：retryable 中断或已保存但未完成的 received/event_prepared/event_recorded/state_submitting（普通事实另含 task_prepared）阶段，先调用 result 核对，再以原 import_id/当前 version 调 world_app_sources_retry 一次；仍失败交维护方，保留准确请求。重要变更的 task_prepared 仍按工作项本人决定流程。返回 `SERVICE_BUSY`（503，服务忙，什么都没提交，带 `retry_after_seconds`）时，先等够这些秒，再以原 import_id 调 result 核对并按上面办理，不换 key；仍忙最多再等三轮，之后保留准确请求并如实说明服务忙。`EVIDENCE_UNAVAILABLE`（证据存储或数据库不可用）不是忙，不连续重试。maintainer 是接入/运行故障，responsible_authority 是所需有权负责人，current_person 才是本人的来源许可或业务判断。处理职责不表示已发消息或已移交对方；外发仍按现行逐稿批准。本人登录失效只请本人重新登录，原事项和进度保留。

只读凭证可按当前权限读本人的处理历史及原结果；不准备、导入或重放写入。撤销来源用 `world_app_sources_revoke` 的当前版本，停止新采集/待执行写入；历史不删不重写。临时错误或更正关系未明时留下准确缺口，避免把材料改字当作world已更正。
