# TokenkingOS world 插件

这个仓库是 TokenkingOS 成员接入 world 的插件来源。装一次，以后 `world` 插件的新版本会自动到你的 Agent，不用再收压缩包。

本仓库由内部源码经脚本生成。直接在这里改动的内容，下次发布会被覆盖，请不要提交修改。

## 在 Claude Code 里安装

1. 安装插件。这条命令会同时登记名为 `tkos-world` 的插件市场。

   ```sh
   claude plugin install world --marketplace TokenkingOS/world-plugin
   ```

2. 打开自动更新。对你的 Agent 说「给 tkos-world 插件市场打开自动更新」。它会在 `~/.claude/settings.json` 的 `extraKnownMarketplaces` 下，给 `tkos-world` 加上 `"autoUpdate": true`，改之前会先问你。不打开的话，第三方市场不会自动更新。
3. 重启 Claude Code。
4. 登录 world，只需登录一次：运行 `claude mcp login plugin:world:world`，会打开浏览器。也可以在 MCP 管理界面登录。登录页上点「用飞书登录」，在飞书里确认就行；也可以填邮箱和密码。
5. 登录后对 Agent 说「核对 world 的身份和可用能力」，看显示的是不是你本人和正确的公司。刚登录的那个对话里 Agent 可能还看不到 world 的工具，再问一次；不行就新开一个对话。

以后有新版本时，Claude Code 会自动下载，重启后生效。

## 在 Codex 里安装

1. 登记市场并安装插件：

   ```sh
   codex plugin marketplace add TokenkingOS/world-plugin
   codex plugin add world@tkos-world
   ```

2. 重启 Codex，用 `/hooks` 审核并信任插件的 hook。
3. 登录 world，只需登录一次：运行 `codex mcp login world`，会打开浏览器。登录页上点「用飞书登录」，在飞书里确认就行；也可以填邮箱和密码。
4. 登录后对 Agent 说「核对 world 的身份和可用能力」，看显示的是不是你本人和正确的公司。刚登录的那个对话里 Agent 可能还看不到 world 的工具，再问一次；不行就新开一个对话。

Codex 每次启动都会更新市场和已装的插件，不用另外设置。插件更新改动了 hook 时，新的 hook 要你再用一次 `/hooks` 信任后才会运行。

## world 调用会记进 Langfuse

你经 `world` 插件调用 world 时，每次调用的参数和返回（含正文，凭证先抹掉）会记进维护方自建的 Langfuse，只用来排障和评估写入质量，满 30 天整条删除（2026-12-11 起，挑出来做评测的少量样本除外）。记什么、不记什么、谁能看，见 world 插件说明里的「[world 调用会记进 Langfuse](world/README.md#world-调用会记进-langfuse)」。

## 本机采集（world-capture）

`world-capture` 是第二个插件：会话每轮结束时读这个会话新增的记录，攒够了在后台起一轮只带 world 工具的 Agent，判断后经 `world` 插件的连接送进 world。先按上面装好 `world` 并登录，再装它：

```sh
claude plugin install world-capture@tkos-world   # Claude Code
codex plugin add world-capture@tkos-world        # Codex
```

Codex 装好后第一次开会话会弹「Hooks need review」，选信任；之后 `world-capture` 每次更新也会弹一次，不信任就不采集。

装好以后对 Agent 说「开始采集 world 进展」。它先核这台机器能不能采（Mac 要 macOS 15 及以上），再列出读哪个文件夹、从什么时候起、送到哪个公司、记到哪些 Task 和 Mission，你在对话里明确同意后才开始。Claude Code 和 Codex 各说一次，各是一项。从确认的时刻起采，之前的会话不补。

`world-capture` 送进 world 的条目经 `world` 插件的连接调用，同样按上面那一节记进 Langfuse。它的后台轮只用来源工具，所以参数和返回只记编号、状态、版本和时刻，原文留在本机。

以前用过 World Capture 组件的，在 Claude Code 里说「开始采集 world 进展」时，Agent 会请你先在组件里停止采集并退出，再问你是否同意把组件的采集迁到插件；迁过来以后组件已送出的不会再送一遍。

## 许可

MIT，见 [LICENSE](LICENSE)。
