# 写入模板（tkos.world/0.2 与 0.3 通用）

下面每段 JSON 都是 MCP 工具的参数，照着改值即可。示例里的 id 都是编的：换成你从 `world_get_object`、`world_get_state` 和上一步返回里拿到的真实值。记外部事件与写快照的参数在 0.2、0.3 里相同，同一段模板两版都能用。

通用规则：

- 引用一律写字符串：对象 `<对象 id>@<版本>`，组件 `<对象 id>@<版本>#<块>/<组件 id>`，事件 `event:<事件 id>`。版本取 `world_get_object` 返回 `business` 组里的 `version`（修订序号）；同组的 `object_version` 是并发版本，和它不必相等，不能写进引用。
- 时刻带时区，例如 `2026-10-09T16:40:00+08:00`。`occurred_at` 保留已核实的事实原时刻，`as_of` 保留事实截至时刻，均不能晚于写入；来源时间未知时留待核，不用运行时间或固定补写钟点代替。
- 空块不要写成 `{"text": ""}`，整个块省掉。
- `artifacts` 与条目的 `url` 只能是 `http://` 或 `https://` 链接。
- 不要给 `idempotency_key`：工具会生成；只有返回 `HTTP_UNAVAILABLE` 或 `SERVICE_BUSY` 时，用它交回的键原样重放。

## 1. 记外部事件：world_record_event

每个有真实业务新增的目标对象记一条；没有新增只留运行/覆盖回执。内容第一行固定写 `【日进展】<姓名> <日期>`（当天第二次写时改成 `【日进展·补充】`），用来判断这一天写过没有、要不要补写。下面按 SKILL.md 第 2 步的四段写，段名照抄：`00｜今日摘要`、`01｜关键进展与结果`、`02｜关键问题与不确定性`、`03｜关键协同与待决事项`；某一段没有内容就写「在已覆盖来源中未见」。

<!-- validate: record_event -->
```json
{
  "category": "other",
  "subject_refs": ["78f375bd-2e07-48c4-9107-9420f1ed38c2@3"],
  "occurred_at": "2026-10-09T16:40:00+08:00",
  "content": {
    "text": "【日进展】张三 2026-10-09\n\n00｜今日摘要：新增一位同事实测 MCP 可读写，日进展 skill 初版合入；还没有经本人确认的写回。\n\n01｜关键进展与结果：\n- 王五在 Windows 上确认 MCP 可读写（来源：本机 Claude Code 会话，13:51 对方回复）；赵六还没实测。\n- 日进展 skill 初版合入、测试通过（来源：附件里的 PR）；只在本机跑过，同事机器上还没跑。\n\n02｜关键问题与不确定性：Windows 的接入说明可能还缺一处路径写法（Agent 初步判断），要等第二位 Windows 同事实测。\n\n03｜关键协同与待决事项：Agents、Method 的委托要赵六本人登记；说明已发，状态是已提出、待他回复，没有约定日期。",
    "artifacts": ["https://tokenking.feishu.cn/docx/ExampleDocToken"]
  },
  "declaration": {
    "scene": "78f375bd-2e07-48c4-9107-9420f1ed38c2@3",
    "trigger": "world-daily 每日定时任务 2026-10-09",
    "human_acceptance": {"required": false}
  }
}
```

当天在已获准完整覆盖内没有业务新增时，由采集组件记录 `world_app_sources_report_run` 运行元数据，本人用 `world_app_sources_runs` 查覆盖截止与最后完整检查；不调用本节经营写入模板。来源不可用、解析失败和覆盖未知分别留缺口。兼容接入没有运行工具时，只向调用方报告并明确未同步。

- `category` 用 `other`。当天有评审、交付这类单独的事实，想单独记，也可以分别用 `review`、`delivery` 各记一条，快照的 `source_event_refs` 都列上。会议不单独记：会议事件由天枢写，见 meetings.md。
- 不记验收，也不记确认完成：0.3 里 Task、Mission 的完成只由对象 DRI 本人确认，Activity 交付即关闭。交付了什么照实写进事实，例如「交付了 xx，待 DRI 确认完成」。
- 返回里的 `event_id` 下一步要用。

## 2. Mission、Task、Activity 的快照：execution_state

<!-- validate: refresh_state -->
```json
{
  "payload": {
    "title": "可信 Context 与真实 Agent 读写闭环 · 张三 2026-10-09 日进展",
    "subject_ref": "78f375bd-2e07-48c4-9107-9420f1ed38c2@3",
    "as_of": "2026-10-09T16:40:00+08:00",
    "period": "2026-10",
    "payload_type": "execution_state",
    "source_event_refs": ["event:e4d458e1-bbf3-4925-9103-0dae07a83f59"],
    "blocks": {
      "current_state": {"text": "新增一位同事实测 MCP 可读写，日进展 skill 初版合入；还没有经本人确认的写回。"},
      "progress": {
        "components": [
          {
            "id": "todo:7f3a2c",
            "type": "progress_item",
            "text": "天枢同步：接口联调第一批",
            "refs": ["37c0f987-e95d-4220-b48b-691cc109b08d@1"],
            "attributes": {
              "principal_id": "2590401e-4702-4b69-857b-96f867086bf0",
              "principal_name": "李四",
              "external_status": "进行中",
              "entries": [{"at": "2026-10-08T01:00:00Z", "source": "web", "text": "第一批写入预提交通过"}]
            }
          },
          {
            "id": "daily:ed04d5f1",
            "type": "progress_item",
            "text": "10/9：同事接入打通两位，日进展 skill 初版完成",
            "attributes": {
              "principal_id": "ed04d5f1-515d-4f38-8974-d29f99adf9f5",
              "principal_name": "张三",
              "external_status": "进行中",
              "entries": [
                {"at": "2026-10-09T11:08:00+08:00", "source": "claude", "text": "给王五发 Windows 版接入说明，13:51 对方确认 MCP 可用"},
                {"at": "2026-10-09T16:40:00+08:00", "source": "github", "text": "日进展 skill 初版完成，测试通过",
                 "url": "https://github.com/example/repo/pull/1"}
              ]
            }
          }
        ]
      },
      "blockers": {"text": "赵六的 Agents、Method 委托还没登记，这两个域的确认要等他。"},
      "issues": {
        "components": [
          {
            "id": "issue-delegation",
            "type": "issue",
            "text": "Agents、Method 的确认卡在委托登记上",
            "attributes": {"core_question": "Agents、Method 的门由谁、在什么时候记？"}
          }
        ]
      },
      "materials": {"artifacts": ["https://tokenking.feishu.cn/docx/ExampleDocToken"]}
    }
  },
  "declaration": {
    "scene": "78f375bd-2e07-48c4-9107-9420f1ed38c2@3",
    "trigger": "world-daily 每日定时任务 2026-10-09",
    "human_acceptance": {"required": false}
  }
}
```

- 你的进展条目 id 固定为 `daily:<你的 principal_id 前 8 位>`，每天整条换掉；`entries` 只放今天的，`source` 取 `codex`、`claude`、`github`、`web`（飞书文档、网页）、`other` 之一，`url` 没有就省掉。
- 上例里 `todo:7f3a2c`（天枢写的）与 `issue-delegation` 是从上一条快照原样带过来的，见第 5 节。

## 3. 周期目标、长期目标的快照：goal_state

这两类的 `progress` 块只有文字，不能放进展条目。

<!-- validate: refresh_state -->
```json
{
  "payload": {
    "title": "Method 10 月目标 · 张三 2026-10-09 日进展",
    "subject_ref": "b4e12011-3582-408c-b805-d7e1373e18d5@2",
    "as_of": "2026-10-09T16:40:00+08:00",
    "period": "2026-10",
    "payload_type": "goal_state",
    "source_event_refs": ["event:e4d458e1-bbf3-4925-9103-0dae07a83f59"],
    "blocks": {
      "current_state": {"text": "10 月目标仍是草稿，待本人承诺后请 CEO 确认；M2 v0.4 方法已发布。"},
      "progress": {"text": "- 10/9 张三：发布 M2 战略解码方法 v0.4 与两个模板，要求 10 月任务拆到 Activity\n- 10/9 张三：确认本机 tkos-world MCP 可用"},
      "key_risks": {"text": "Mission 还没录入，拆解进度难以在本体里看到。"},
      "materials": {"artifacts": ["https://tokenking.feishu.cn/wiki/ExampleWikiToken"]}
    }
  },
  "declaration": {
    "scene": "b4e12011-3582-408c-b805-d7e1373e18d5@2",
    "trigger": "world-daily 每日定时任务 2026-10-09",
    "human_acceptance": {"required": false}
  }
}
```

- 上一条快照的 `variance`（关键偏差）与 `issues` 里的组件原样带上。

## 4. 责任单元的快照：unit_state

<!-- validate: refresh_state -->
```json
{
  "payload": {
    "title": "Agents · 张三 2026-10-09 日进展",
    "subject_ref": "94763ec2-a9de-4d42-a679-fefcff09446a@1",
    "as_of": "2026-10-09T16:40:00+08:00",
    "period": "2026-10",
    "payload_type": "unit_state",
    "source_event_refs": ["event:e4d458e1-bbf3-4925-9103-0dae07a83f59"],
    "blocks": {
      "current_state": {"text": "单元已建，10 月 Mission 草稿待录入。"},
      "progress": {"text": "- 10/9 张三：Co-Agent 的 M1-B 接入方案初稿完成"}
    }
  },
  "declaration": {
    "scene": "94763ec2-a9de-4d42-a679-fefcff09446a@1",
    "trigger": "world-daily 每日定时任务 2026-10-09",
    "human_acceptance": {"required": false}
  }
}
```

公司（Company）与战略（Strategy）不在这个 skill 的范围里，不要给它们写快照。

## 5. 从上一条快照带过来

新快照是「上一条快照的完整状态 + 今天的变化」，不是只写今天：读者只看最新一条。先 `world_get_state` 读最新快照（没有就从空白开始），再按下面合成：

| 内容 | 怎么处理 |
|-|-|
| 别人的组件（例如天枢的 `todo:*` 进展条目） | 原样带上，不改 |
| `issues` 里的问题组件、`variance` 里的偏差组件 | 原样带上，id 不变；不要删，也不要自己新增（提出问题另有流程） |
| 你自己的进展条目 `daily:<前 8 位>` | 换成今天的 |
| `current_state`、`blockers`、`key_risks`，以及目标与单元的 `progress` 文字 | 按现在的情况重写：上一条里仍然成立的保留，已经过时的去掉。`current_state` 用今天 00 的摘要；`blockers`、`key_risks` 写 02，以及 03 里会影响结果的依赖 |
| `materials` 的链接 | 上一条的加上今天新增的，去重，最多留 20 个（去掉最早的） |

读回的块在 `blocks` 列表里，每项的 `value` 是块值（`null` 表示空块）。读回的组件比写入多了几个字段，照抄时要换回写入的样子：

读回（`world_get_state` 里 `progress` 块的一个组件）：

```json
{
  "id": "todo:7f3a2c",
  "type": "progress_item",
  "scope": null,
  "text": "天枢同步：接口联调第一批",
  "refs": [{"object_id": "37c0f987-e95d-4220-b48b-691cc109b08d", "object_version": 1,
            "revision_id": "2b6d0c8e-0f7a-4d38-9a51-8c2e7f4b1a90", "block": null, "component": null,
            "ref": "37c0f987-e95d-4220-b48b-691cc109b08d@1"}],
  "artifacts": [],
  "attributes": {"principal_id": "2590401e-4702-4b69-857b-96f867086bf0", "principal_name": "李四",
                 "external_status": "进行中",
                 "entries": [{"at": "2026-10-08T01:00:00Z", "source": "web", "text": "第一批写入预提交通过"}]},
  "ref": "61b54160-6c0e-4d20-a025-34c673304c4e@1#progress/todo:7f3a2c"
}
```

写入时：

- 只留 `id`、`type`、`scope`、`text`、`refs`、`artifacts`、`attributes` 七项，组件自己的 `ref` 删掉；
- `refs` 与 `scope` 换成各自的 `ref` 字符串，`scope` 为 `null` 时省掉；
- `attributes` 原样，`entries` 里的时刻不用改。

结果就是第 2 节里的 `todo:7f3a2c` 那一项。

## 6. 写入声明

每次写入都带，三项缺一不可：

- `scene`：这个目标对象的对象引用 `<id>@<版本>`；
- `trigger`：定时运行写 `world-daily 每日定时任务 <日期>`，有人当面要求时写 `<姓名>要求写今天的进展（world-daily）`；
- `human_acceptance`：`{"required": false}`。快照与外部事件写入即生效、标为未经确认，不需要验收人。
