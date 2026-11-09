# world-personal 的 params 参数表

`world_app_prepare_personal_action(action_type, target, params)` 的 `params` 按下表填。支持清单（`world_app_list_personal_actions`）只给动作名、适用的对象类型和所需角色，不给参数。字段名和必填与否取自服务端的动作模型。

`params` 不合模型时，`prepare` 回 422 `INVALID_REQUEST`，只有一句固定的话，不说是哪个字段。先对这张表改，不要靠试。多填和拼错的字段都会被拒。

## 通用写法

- **不填的两个字段。** 本入口不代别人办，填 `on_behalf_of` 会被拒。`declaration`（写入声明）属于 Agent 面，本人办门不用。表里没有这两个字段。
- **引用。** 对象写 `<对象 id>@<版本>`，块写 `<对象 id>@<版本>#<块 id>`，组件写 `<对象 id>@<版本>#<块 id>/<组件 id>`，事件写 `event:<事件 id>`。版本取 `business.version`，不取 `object_version`。
- **`content`。** 写进事件的内容，是对象，有三个字段：`text` 文字，`refs` 引用列表，`artifacts` 材料链接列表（`http://` 或 `https://` 开头，不超过 2048 个字符）。三个都可以省，但不能全空。不要写 `components`。
- **撤回。** 撤回一条已记的事件：`outcome` 填 `withdrawn`，同时 `supersedes_event_id` 填原事件 id（只写 id，不加 `event:`）。两个要一起给，缺一个会被拒。只能撤回产生对象当前状态的那一条，谁能撤由服务按角色判。下表里没有 `outcome` 的动作不能撤回。
- **理由。** 退回（`outcome` 为 `returned`）、重开、取消要在 `content.text` 写理由，空的会被拒。撤回重开、撤回取消也一样。

## 各动作

target 一栏写适用的对象类型，「不带」是不传 target。必填和选填两栏只列字段名，取值和写法在最后一栏。

| action_type | target | 必填 | 选填 | 取值与写法 |
| --- | --- | --- | --- | --- |
| `world_create_object` 建对象 | 不带 | `domain_id`、`object_type`、`payload` | | `domain_id` 是新对象放的分区 id，取 `world_list_objects` 返回项里同分区对象的 `domain_id`，拿不准就问本人。`object_type` 取 `Company`、`Strategy`、`ResponsibilityUnit`、`LongTermGoal`、`PeriodGoal`、`Mission`、`Task`、`Activity`，不能建状态快照。`payload` 写 `title`、上级引用和 `blocks`，写法见 `world-ask` 的「建对象的载荷」。 |
| `world_assign` 指派 | `ResponsibilityUnit`、`Mission`、`Task`、`Activity` | `principal_id` | | `principal_id` 是被指派人的主体 id，须是本公司已有的主体。指派不授予角色。Mission 的 Owner 只有所属周期目标的 DRI 能指派。 |
| `world_assign_strategy_round` 指定本轮责任人 | `Strategy` | `principal_ids` | `payload` | `principal_ids` 是本轮责任人的主体 id 列表，至少一个，不重复。`payload` 是候选，合并补丁，只含正式块和正式属性，Strategy 已生效后开新一轮时才能带。 |
| `world_mark_core_battle` 标记核心战役（关注） | `Mission` | | `content` | `content.text` 写关注的理由。同一个 Mission 只能标一次。 |
| `world_commit_period_goal` 承诺周期目标 | `PeriodGoal` | | `payload`、`content`、`outcome`、`supersedes_event_id` | 带候选承诺：候选合并补丁放进 `payload`，写法见下文。不带候选就不写，承诺的是当前这一版。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`，撤回时不带 `payload`。 |
| `world_confirm_period_goal` 确认周期目标 | `PeriodGoal` | `outcome` | `content`、`supersedes_event_id` | `outcome` 取 `accepted` 接受、`returned` 退回、`withdrawn` 撤回。退回要在 `content.text` 写理由。撤回要给 `supersedes_event_id`。 |
| `world_reconfirm_period_goal` 再确认周期目标 | `PeriodGoal` | | `content` | 再确认没有结果也没有候选，不能撤回。 |
| `world_commit_mission` 承诺 Mission（立项） | `Mission` | | `payload`、`content`、`outcome`、`supersedes_event_id` | 带候选承诺：候选合并补丁放进 `payload`，写法见下文。不带候选就不写，承诺的是当前这一版。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`，撤回时不带 `payload`。 |
| `world_confirm_mission` 确认 Mission（立项） | `Mission` | `outcome` | `content`、`supersedes_event_id` | `outcome` 取 `accepted` 接受、`returned` 退回、`withdrawn` 撤回。退回要在 `content.text` 写理由。撤回要给 `supersedes_event_id`。回应一条请求的写法见下文。 |
| `world_reconfirm_mission` 再确认 Mission | `Mission` | | `content` | 再确认没有结果也没有候选，不能撤回。 |
| `world_confirm_long_term_goal` 确认长期目标 | `LongTermGoal` | `outcome` | `content`、`payload`、`returns_to`、`supersedes_event_id` | `outcome` 取 `accepted` 接受、`returned` 退回、`withdrawn` 撤回，退回要在 `content.text` 写理由，撤回要给 `supersedes_event_id`。长期目标没有承诺门，接受时可以带候选：合并补丁放 `payload`，只在 `accepted` 时带。`returns_to` 只有一个取值 `strategy`，注明确认（接受或退回）后返回 M1-A，只作记录，撤回时不带。 |
| `world_reconfirm_long_term_goal` 再确认长期目标（保持） | `LongTermGoal` | | `content`、`returns_to` | 再确认没有结果也没有候选，不能撤回。`returns_to` 只有一个取值 `strategy`，注明返回 M1-A，只作记录。 |
| `world_agree_strategy` 记 Agreement | `Strategy` | | `content`、`outcome`、`supersedes_event_id` | 只有本轮被指定的责任人能记。`content` 写记录者自己的判断。所同意的内容由服务钉住，不带候选。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`。 |
| `world_confirm_strategy` 确认 Strategy 生效 | `Strategy` | `outcome` | `content`、`supersedes_event_id` | `outcome` 取 `accepted` 接受、`returned` 退回、`withdrawn` 撤回。退回要在 `content.text` 写理由。撤回要给 `supersedes_event_id`。 |
| `world_reconfirm_strategy` 再确认 Strategy（继续有效） | `Strategy` | | `content` | 再确认没有结果也没有候选，不能撤回。 |
| `world_confirm_review` 复盘确认 | `StateSnapshot` | | `content`、`outcome`、`supersedes_event_id` | target 的 `expected_version` 取快照对象头的 `object_version`，找法见 SKILL.md。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`。公司复盘的确认不能撤回。 |
| `world_confirm_task_plan` 确认 Task 计划 | `Task` | | `content` | Task DRI 本人确认。没有结果也没有候选，不能撤回，记错了再记一条。 |
| `world_confirm_checkpoint_change` 确认治理点变更 | `Task` | `checkpoint_ref`、`explanation` | `content` | `checkpoint_ref` 是治理点组件的引用，写成 `<Task id>@<版本>#task_plan/<组件 id>`，指向这个 Task 当前版本 Task 计划里的治理点。`explanation` 是对象，四项都要写，不能空：`purpose` 原始目的，`evidence` 实际证据，`residual_risk` 剩余风险，`fallback` 替代或恢复措施。没有结果，不能撤回。 |
| `world_confirm_task_change` 确认 Task 改动 | `Task` | | `content` | Mission DRI 确认 Task 计划确认之后改过的工作结果和验收标准。没有结果也没有候选，不能撤回。 |
| `world_start` 开始 | `Mission`、`Task`、`Activity` | | `content`、`outcome`、`supersedes_event_id` | Task 开始前要先有 Task 计划确认。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`。 |
| `world_deliver` 交付 | `Activity` | | `content`、`outcome`、`supersedes_event_id` | Activity 交付即关闭。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`。 |
| `world_confirm_completion` 确认完成 | `Mission`、`Task` | `content` | `outcome`、`supersedes_event_id` | 只有对象 DRI 本人能确认。`content` 必须引用证据：`content.refs` 放事件或对象版本的引用，或 `content.artifacts` 放材料链接，至少一项。只引用问题组件不算证据。撤回时 `content` 可省：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`。 |
| `world_reopen` 重开 | `Mission`、`Task`、`Activity` | `content` | `outcome`、`supersedes_event_id` | `content.text` 写理由。`content.refs` 引用证据或问题组件，或 `content.artifacts` 放材料链接，至少一项。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`，`content.text` 照样要写。 |
| `world_cancel` 取消 | `LongTermGoal`、`PeriodGoal`、`Mission`、`Task`、`Activity` | `content` | `outcome`、`supersedes_event_id` | `content.text` 写取消的理由。撤回：`outcome` 填 `withdrawn`，另给 `supersedes_event_id`，`content.text` 照样要写。 |
| `world_grant_delegation` 登记委托 | 不带 | `delegate_principal_id`、`families`、`domain_ids`、`valid_until` | | `delegate_principal_id` 是受托的服务主体（本公司的 Agent 主体）id。`families` 是动作族列表，至少一个，不重复，取 `gate` 门、`assign` 指派、`lifecycle` 生命周期、`issue` 议题、`create` 建对象、`revise` 修订。`domain_ids` 是分区 id 列表，至少一个，不重复。`valid_until` 是带时区的到期时刻。受托方不能再转委托。 |
| `world_revoke_delegation` 撤销委托 | 不带 | `delegation_event_id` | | `delegation_event_id` 是登记委托那条事件的 id。撤销即时生效。 |

## 带候选承诺

把候选直接放进 `params.payload`，不从最新快照读。`payload` 是合并补丁，只写要改的块和组件，组件按 `id` 合并。

<!-- validate: world_commit_mission -->
```json
{
  "payload": {"blocks": {"definition": {"components": [
    {"id": "ac-1", "type": "acceptance_criterion", "text": "验收口径改为以真实数据持续写入为准，样例数据不计。"}
  ]}}},
  "content": {"text": "带候选承诺：改验收标准 ac-1。"}
}
```

## 回应一条请求

这道门有人请过，就在 `params.content.refs` 加 `event:<请求事件 id>`，门事件就引用那条请求。找请求用 `world_find_events`，`subject` 填对象 id，`q` 填 `【请求】`。开一轮、建对象、指派、委托不加。

<!-- validate: world_confirm_mission -->
```json
{
  "outcome": "accepted",
  "content": {"refs": ["event:e4d458e1-bbf3-4925-9103-0dae07a83f59"]}
}
```

## 其余几处的例子

退回，理由写在 `content.text`：

<!-- validate: world_confirm_mission -->
```json
{
  "outcome": "returned",
  "content": {"text": "验收标准没有可核对的数据口径，补上再提。"}
}
```

确认完成，证据用事件引用和材料链接：

<!-- validate: world_confirm_completion -->
```json
{
  "content": {
    "text": "已按验收标准 ac-1 核对，样例见链接。",
    "refs": ["event:e4d458e1-bbf3-4925-9103-0dae07a83f59"],
    "artifacts": ["https://tokenking.feishu.cn/docx/ExampleDocToken"]
  }
}
```

确认治理点变更，四项说明都写：

<!-- validate: world_confirm_checkpoint_change -->
```json
{
  "checkpoint_ref": "78f375bd-2e07-48c4-9107-9420f1ed38c2@3#task_plan/gp-1",
  "explanation": {
    "purpose": "核对数据口径后再放行。",
    "evidence": "口径已在 10 月 9 日会上与王五对齐。",
    "residual_risk": "上游表结构可能再改。",
    "fallback": "上游改表时回退到手工核对。"
  }
}
```

指定 Strategy 本轮责任人：

<!-- validate: world_assign_strategy_round -->
```json
{
  "principal_ids": [
    "10000000-0000-4000-8000-000000000003",
    "10000000-0000-4000-8000-000000000004"
  ]
}
```

取消，理由写在 `content.text`：

<!-- validate: world_cancel -->
```json
{
  "content": {"text": "这项工作并入另一个 Mission，不再单独做。"}
}
```

登记委托：

<!-- validate: world_grant_delegation -->
```json
{
  "delegate_principal_id": "10000000-0000-4000-8000-000000000003",
  "families": ["gate"],
  "domain_ids": ["10000000-0000-4000-8000-000000000001"],
  "valid_until": "2026-12-28T23:59:59+08:00"
}
```
