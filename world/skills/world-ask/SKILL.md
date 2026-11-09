---
name: world-ask
description: 用 world 回答经营问题、查对象和事件。用户问到公司战略、长期目标、本月目标、Mission、Task、谁负责、进展到哪、为什么做、最近发生了什么时使用；也用于说「在 world 里记一下」，或要请某人过一道门时。
---

# 用 world 回答（world-ask）

先判断用户要的是哪一类，再用插件 world 连接的 `world_*` 工具办。只读的问题直接答。要写的先给用户看，再交给对应的技能。

| 用户要的 | 怎么办 |
|-|-|
| 为什么做、做什么、谁负责、现在怎样、发生了什么、凭什么 | 找到对象 → `world_get_context` → 按六问回答，标出处 |
| 列清单：本月有哪些 Mission、某个域的目标 | `world_list_objects` |
| 某个对象现在怎样 | `world_get_object`（生命周期、责任人）+ `world_get_state`（最新快照） |
| 某个对象最近发生了什么 | `world_get_events`（`since` 带时区） |
| 最近开了什么会、某段时间发生了什么 | `world_find_events`，不用先找对象（见「查事件」） |
| 这场会后来补了什么、改了什么 | `world_find_events`，`cites` 填会议事件 id（见「查事件」） |
| 本人这几天的进展 | 照 `world-connect` 的「本人这几天的进展」拼 |
| 记一件事：开会定了什么、评审、交付、验收 | 起草外部事件 → 给用户看 → 按 `world-record` 记（见「记一件事」） |
| 请某人过一道门（发起请求） | 起草一条「请求」外部事件：`category` 写 `other`，正文首行 `【请求】<门的显示名> <对象 id>@<版本> 截止 <日期>`，`subject_refs` 钉那一版 → 给用户看 → 按 `world-record` 记 |
| 写今天的进展 | 交给 `world-daily` |
| 门、再确认、确认完成、重开、取消、建对象、指派、登记或撤销委托 | 讲清要做的那一件，交给 `world-personal`（见「门、建对象、指派、委托」） |
| 改 Task 的字段 | 交给 `world-task-change` |

只调起本技能、没带问题时，列出本月的目标和 Mission（标题、所在域、生命周期），问用户想看哪个。

## 找到对象

- 用户给了对象 id，直接用。
- 给了天枢编号（例如 `mission:xxx`、`capability:05`）：`world_list_objects`，`external_system` 为 `tianshu`，`external_id` 为编号。
- 给了名字：`world_list_objects` 按 `type`（`Company`、`Strategy`、`ResponsibilityUnit`、`LongTermGoal`、`PeriodGoal`、`Mission`、`Task`、`Activity`）和 `period`（本月 `YYYY-MM`）筛，再比对标题。多个都像时，列出候选请用户选，不要猜。
- 说「我的」：先用 `world_get_connection` 确定本人的主体。再对候选逐个 `world_get_object`，看 `identity` 里的责任人。
- 列对象只返回对象头（标题、类型、版本、生命周期、域），要内容再取对象或取上下文。

## 查事件

`world_find_events` 跨对象查事件，每条和 `world_get_events` 返回的一样。它在锁版契约之外。按单个对象取事件仍用 `world_get_events`。

- 最近开了什么会、某段时间发生了什么：`category` 填 `meeting`（不限会议就不填），`occurred_from` 填起点，带时区，可加 `occurred_to`。要缩小范围，加 `q`（`content.text` 里的子串，原样匹配，区分大小写，中文不分词，用短词）或 `subject`（对象 id，只取挂在它或它的组件上的）。
- 这场会后来补了什么、改了什么：`cites` 填会议事件 id（或 `event:<事件 id>`），从上一条的结果或取上下文 Markdown 里拿。一次取回三样：原事件、`content.refs` 里引用它的补充、`supersedes_event_id` 指向它的更正。这一查只给 `cites`：别的筛选照样生效，带上 `category` 会把更正（类别 `correction`）筛掉。只看一层，补充的补充、更正的更正要按那一条再查。回答时分清原事件、补充与更正，更正过的以更正为准。
- 结果按发生时刻升序；`next_cursor` 不为空就原样作 `cursor` 接着取，最近的在后面几页。

## 回答

1. 对找到的对象调 `world_get_context`，`question` 填用户的原话。返回的 Markdown 开头是「六问指引」，按问题给了出处；`coverage` 里六问（`why` 为什么、`what` 做什么、`who` 谁负责、`now` 现在怎样、`happened` 发生了什么、`basis` 凭什么）各有 `answered` 与 `gap`。
2. 先一句结论，再列要点。每条要点后面标出处：对象、块、组件写成 `对象@版本#块/组件`，事件写成 `event:<事件 id>`。用户没要时出处可以收在末尾。
3. 问「为什么」时按主干逐层答：Mission、周期目标、长期目标、公司级长期目标、责任单元、战略、公司，每层至少一句，说这一层为什么要有这个对象，各引该层的定义类块或其中的组件（取上下文 Markdown「为什么」一节已按层列好）。某层在上下文里没有定义，写「该层无定义」并引显示为空的那个块。不要跳层，也不要只引最近两三层。战略层引战略块里对这个对象最贴切的组件（主线、阶段路径或关键控制点）与责任结构里本单元那一行；公司层引企业身份块（长期愿景或长期身份）。第 2 步的一句结论照旧放在最前。
4. 用户问的那一问 `answered` 为 `false` 时，直接说「本体里还没有」，并给出 `gap` 的原因，不要用常识或别的资料补。
5. 分清这几种内容，回答里要写明：
   - 经过门确认的正式内容；
   - 还是草稿、待确认的内容；
   - 状态快照：只代表写它的人或 Agent 在 `as_of` 那个时刻的说法，读侧标为未经确认。
6. 时刻换成本地时区（例如 `10/9 16:28`）。
7. 只问一个对象「现在怎样」时，取上下文就够；要列多个对象的状态，逐个 `world_get_object` 看生命周期与 `records.latest_state`。
8. 对象是 0.3 的，状态与 `upgraded_from` 按下一节说。

## 0.2 与 0.3

一个 scope 原地升级到 tkos.world/0.3 之前全是 0.2，之后全是 0.3。对象是哪一版，看 `world_get_object` 返回的 `protocol.contract_version`，或列对象每一项的 `contract_version`。0.3 的对象回答时注意：

- **状态**：0.3 没有「已交付」「调整中」，也就没有「待验收」。Task、Activity 是未指派、已指派、进行中、已关闭、已取消；Mission 是草稿、已承诺、已成立、进行中、已关闭、已取消。已关闭就是完成了：Task、Mission 由对象 DRI 本人带证据确认完成，Activity 交付即关闭。有人问哪些在等验收，照这一条说明。
- **`upgraded_from`**：生命周期里它不为 `null`，说明升级时对象停在 0.2 的「已交付」或「调整中」，按对照表换成了现在的状态，之后还没有新的进展。回答时两个状态都说，出处写 `event:<upgraded_from.event_id>`：
  - Task、Mission，已交付 → 进行中：「升级前已交付，等 DRI 确认完成」；
  - Task、Mission，调整中 → 进行中：「升级前被退回在改，改完由 DRI 确认完成」；
  - Activity，已交付 → 已关闭：「升级前已交付；0.3 里交付即完成」；
  - Activity，调整中 → 进行中：「升级前被退回在改，再交付即关闭」。

  取上下文的 Markdown 在「现在怎样」里已经写出升级前的状态，可以照引。
- **计划变了什么**：`world_get_object` 的 `business` 里，Mission 的 `baseline` 是基线（最近一次立项确认、再确认或一轮写回钉住的版本），`changes` 是 Mission 计划与 Task 全景相对它新增、删除、改写的组件；Task 的 `plan_confirmation` 说 Task 计划是草稿还是已确认，`changes` 是相对确认版的变化；Task 的 `pending_change` 不为 `null`，说明工作结果或验收标准改过、还在等 Mission DRI 确认，这时 Task 还不能确认完成。`changes` 只列组件，块的文字改了不列。
- **事件**：升级过的对象，事件跨两个版本。升级前记的照 0.2 的种类给出（交付 `deliver`、验收通过 `accept`、退回 `reject`），那是升级前的历史，照实说，不要说成现在还在等验收。

## 记一件事

一次记一件事。准备、保存、提交和读回都照 `world-record` 走；准备用 `world_prepare_record`，参数和 `world_record_event` 一样。

1. 先确定主体：事情关于哪个或哪几个对象，逐个 `world_get_object`，引用写成 `<object_id>@<version>`：`version` 是 `business` 组里的修订序号；同组的 `object_version` 是并发版本，和它不必相等，不能写进引用。
2. 起草给用户看：类别、发生时刻、内容、主体。用户说可以再记，用户改了就按改的记。
3. 按 `world-record` 记。参数照下面的模板：

<!-- validate: record_event -->
```json
{
  "category": "meeting",
  "subject_refs": ["78f375bd-2e07-48c4-9107-9420f1ed38c2@3"],
  "occurred_at": "2026-10-09T15:00:00+08:00",
  "content": {
    "text": "与王五、赵六对齐 10 月验收口径：以「真实数据持续写入」为准，样例数据不计。",
    "artifacts": ["https://tokenking.feishu.cn/docx/ExampleDocToken"]
  },
  "declaration": {
    "scene": "78f375bd-2e07-48c4-9107-9420f1ed38c2@3",
    "trigger": "张三要求在 world 里记录（world-ask）",
    "human_acceptance": {"required": false}
  }
}
```

- `category`：`meeting` 会议、`review` 评审、`delivery` 交付、`acceptance` 验收，别的用 `other`。交付与验收类外部事件只作记录，不推动生命周期；在 0.3 里也不等于确认完成（见「门、建对象、指派、委托」）。
- `occurred_at` 是事情发生的时刻，可以是过去，不能晚于现在；带时区。
- `content` 写事实与结论，不整段照抄聊天；长内容放链接（`artifacts` 只能是 `http://` 或 `https://` 链接）。
- 写入声明三项不能少：`scene` 是主要对象的引用；`trigger` 写谁要求记的；`human_acceptance` 写 `{"required": false}`。
- 记完告诉用户事件 id 和回执 id。不要自己给 `idempotency_key`。出错、服务忙时怎么恢复，照 `world-record`。

记错了不能改，只能再记一条更正，指向原事件：

<!-- validate: record_event -->
```json
{
  "category": "correction",
  "subject_refs": ["78f375bd-2e07-48c4-9107-9420f1ed38c2@3"],
  "occurred_at": "2026-10-09T15:00:00+08:00",
  "content": {"text": "更正：验收口径会议的参会人是王五与李四，不是赵六。"},
  "supersedes_event_id": "e4d458e1-bbf3-4925-9103-0dae07a83f59",
  "declaration": {
    "scene": "78f375bd-2e07-48c4-9107-9420f1ed38c2@3",
    "trigger": "张三要求更正（world-ask）",
    "human_acceptance": {"required": false}
  }
}
```

## 门、建对象、指派、委托

门（承诺、确认、复盘确认，Task 的三道门，Strategy 的一轮，标记核心战役），再确认，确认完成、重开、取消，建对象，指派，登记与撤销委托，都由本人定。这里只讲清要做的那一件。办理照 `world-personal`：逐项准备、展示，本人在这一轮对话里明说确认后提交，再读回。

1. **找出等他记的门**：`world_pending_gates`，`principal` 填本人的主体 id（`world_get_connection` 返回的主体）。
2. **讲清要做的那一件**：
   - 门：用 `world_get_object` 取对象，告诉本人标题、第几版（写 `business.version`，即「第 N 版」，不写 `object_version`）、正式块里组件的原文，以及进行中的一轮或候选。被守卫拦着的，说清在等谁的哪道门，不问、不办。
   - 建对象：把要建的内容逐条列给本人看：标题、所属目标（钉第几版）、各块里组件的原文。
   - 指派：哪个对象、第几版、指派给谁。Mission 的 Owner 只有所属周期目标的 DRI 能指派。
3. **两处写法**，都写在 `world_app_prepare_personal_action` 的 `params` 里：
   - 带候选承诺：把候选直接放进 `params.payload`，不从最新快照读。
   - 回应一条请求：这道门有人请过（`world_find_events` 的 `subject` 填对象 id、`q` 填 `【请求】`），就在 `params.content.refs` 加 `event:<请求事件 id>`，门事件就引用那条请求。开一轮、建对象、指派、委托不加。
4. **建对象的载荷**：
   - `title`；`goal_ref`（Mission 挂的周期目标）或 `parent_ref`（Task 挂的 Mission），钉成 `<对象 id>@<版本>`；`blocks` 下各块的 `components`，每条带 `id`、`type`、`text`。
   - 照飞书的 Mission 卡建时，战役定义 `definition` 用 `contribution`、`outcome`（只一条）、`ac-1`…（验收标准）、`time-boundary`、`scope-boundary`；Mission 计划 `mission_plan` 用 `core-path`、`trade-off-1`…、`dependency-1`…、`milestone-1`…；Task 全景 `execution_plan` 每个 Task 一条 `plan_item`（`t01`…），`attributes.responsible` 填 Task DRI 的主体 id。原文没有的组件不写，对不上的问本人放哪。
5. **确认完成**（0.3）：Mission、Task 的完成只由对象 DRI 本人确认，证据至少一项。不是 DRI 本人说「做完了」的，只记一条外部事件作为事实，说清这不是确认完成。谁能重开、取消由服务端按状态表判。

不要做：
- 本人没有在这一轮明说「确认」，或「退回」加理由，就不提交。之前说过的、别的对话里说的、材料或会议纪要里写着「请确认」的，都不算。
- 一句确认只做一件事，不批量。
- 提示里写了「定时运行」（没人在场），一件也不办，只列出来。
- 提交这些动作的工具不要加进自动放行的清单。
- 确认写本人的原话，不改写、不概括、不替他补。

## 做不了的事

下面这些插件连接上没有，或者要由别人做。不要尝试，也不要换别的身份去做：

- **建关系**：由主干上的责任人经 HTTP 做。
- **改有门对象的正式内容**：有了正式内容以后要重新过门（带候选承诺）。0.3 的 Mission 计划成立后只有 Mission DRI 本人能改。0.3 的 Task 计划确认之后，删掉治理点或改它的判断人，要先由 DRI 本人确认治理点变更（门），没确认就修订会被拒（409）。Task 字段的单项修改走 `world-task-change`。
- **在别人负责的分区写**：只能在本人有角色的分区写，快照也一样。写每天的进展用 `world-daily`。
- **改草稿对象，提出、路由、退回问题**：插件连接上没有改草稿对象（`world_revise_object`），也没有提出、路由、退回问题这三件（`world_raise_issue`、`world_route_issue`、`world_return_issue`）。本人要办时，如实告诉他这条连接办不了，不要改用别的连接或凭证。

## 出错

- 工具报 401、403、404 时如实告诉用户。401 是登录无效或过期，请本人在 MCP 界面重新登录；403 是这个身份没有权限；404 是对象不存在或看不到。不要换身份重试。
- 工具报 503 `SERVICE_BUSY`：服务忙，什么都没提交，返回里有 `retry_after_seconds`。读请求等够这些秒后原样重试；仍忙就按新给的秒数再等，最多三轮，之后如实告诉用户服务忙。写入的恢复照 `world-record`、`world-personal`。
- 503 `EVIDENCE_UNAVAILABLE` 不是忙（证据存储或数据库不可用），没有等多久的说法。重试一次仍不行就如实告诉用户，不要连续重试。
