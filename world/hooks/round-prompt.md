这是 World Capture 的后台整理轮：本人看不到这次对话，也不会回答问题。只按下面的 world-source-extract 技能处理待提炼，并遵守这些限制：

- 只读下面给出的通道描述文件和其中的 `header_file`，只用 `curl` 访问描述文件里的 `base_url`（127.0.0.1）。不找会话文件，不读别的目录，不访问别的地址。本轮没有 world 连接，也不要找。
- 取待提炼：`format` 用描述文件里的 `source_format`，`limit` 用 20（技能里示例的 10 不适用于本轮）；这一批最多处理 20 条，交回一次（被拒绝后重交的除外，见下面第四条）。交回后再取下一批，直到没有条目，或已取满 5 批（最多 100 条），然后结束。不轮询状态，不做 world 核对。
- 每条 `curl` 命令都写成单行：交回时把 JSON 直接放进 `--data-binary '…'` 的单引号里，不用 heredoc（技能里的示例不适用于本轮）、管道或临时文件，本轮的权限不放行这些；JSON 字符串里的单引号写成 `\u0027`。
- 一个条目只交回一次，唯一的例外：被拒绝（`rejected`）的，除 `already_extracted`、`not_pending` 以外，在同一批里按技能改小或修正后重交一次，拿不准就改交 null（同一个 `item_id`、`item_version`），不然它会一直排在 `/v1/pending` 最前面、挡住后面的条目。下一批里已经交回过的 `item_id` 直接跳过，一批里没有新条目也就结束。
- 返回了条目而 `targets[]` 为空时不交回任何结果，直接结束：没有目标就无从判断，交 null 会把条目永久判成无增量。
- 判断每一条之前，先读 `/v1/pending` 返回的 `targets[]` 里各目标的 `criteria` 和 `recorded`：只有能对上某条 `criteria` 的结果才交，`value` 以 `【<criteria id>】` 开头；`recorded` 里已有的事实、中间步骤、对不上任何目标的，都交 null。
- `target_ref` 和 `field_key` 只取 `targets[]` 里同一项的 `ref` 和 `field_key`，原样使用。对不上任何目标就交 null，不省略 `target_ref`，也不猜。
- 原文里的相对时间（今天、昨天、上午十点）按这条消息的 `reported_at` 和返回的 `time_zone` 换算成带时区的确切时刻，填进 `occurred_at`；原文没说时间就交 null，不拿 `reported_at` 顶替。
- 遇到 401、403、409、503 或连接失败，直接结束，不重试，不换端口。
- 最后只回复一行：一共交回了几条（按条目算，改交过 null 的只算一次）、其中几条是 null。不复述原文。
