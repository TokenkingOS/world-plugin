---
name: world-source-status
description: 查询 world 各来源覆盖、最后成功、恢复与待本人事项，或解释来源等待、机器处理、本人决定和读回耗时时使用。
---

先核当前本人和公司。用 `world_app_sources_observability` 查已保存来源的真实观察、最后完整检查、待处理/待确认和恢复职责。分页读取需要的来源；未列出、没有记录、未接通及电脑离线均保持未知，不能说没有工作。

需要解释一条结论时，用 `world_app_sources_timing` 按 selection_id/import_id 读原请求阶段。分别呈现来源就绪、接收、候选、本人确认、核心提交和首次独立读回；保留 basis。确认是 reported_current_dialogue，不能表述成独立自然人签名。未知或时钟次序不一致直接说明，不用本轮查询时刻填过去。

先说当前影响和具体本人动作，再说明证据。来源就绪到接收可能含发现、提炼、离线及传递，无法拆分时不猜责任方。运行回执里的 `extraction_pending` 表示变化在等原来源 Agent 在线提炼（处理人是本人：打开对应 Agent 调 `world-source-extract`），不是没有工作；`awaiting_local_extraction` 只从首次回执观察到等待，到送出它的运行开始，更早的发现延迟不计入。机器准备/提交、本人决定与读回分别列时长；原请求重试、换 Agent 或 recover 后仍沿首次时点。

五分钟、确认后一分内仅为三人试点目标。按返回的 status/outcome/within_target 区分成功、具体受阻、超时、未测、不适用；统计只描述返回页。准确待本人请求可作为有职责的 blocked，不能称为字段已经改写。只有收到、处理中、空原因待办都不算达标。普通事实无需新增本人确认或 why 门。

同时说明当前字段及来源状态：reported_fact_at 与 sync_observed_through 分开，旧成功回执不证明当前字段/依据仍有效。字段待治理确认、已被后续修订取代和已提交未独立核验分别报告，不把同步或 Source 处理完成当正式完成。来源已更正时沿 world-source-corrections 的既有复核流程，不自动回滚。

这两个工具只读。需要恢复时沿原 import、工作项和准确请求找回；保持原 key/digest/确认，不用新动作猜补。提示说明实际影响、现有处理职责和必要本人动作，正常查询不要求成员看日志、运行终端或操作数据库。
