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
4. 登录 world，只需登录一次：运行 `claude mcp login plugin:world:world`，会打开浏览器。也可以在 MCP 管理界面登录。
5. 登录后对 Agent 说「核对 world 的身份和可用能力」，看显示的是不是你本人和正确的公司。刚登录的那个对话里 Agent 可能还看不到 world 的工具，再问一次；不行就新开一个对话。

以后有新版本时，Claude Code 会自动下载，重启后生效。

## 在 Codex 里安装

1. 登记市场并安装插件：

   ```sh
   codex plugin marketplace add TokenkingOS/world-plugin
   codex plugin add world@tkos-world
   ```

2. 重启 Codex，用 `/hooks` 审核并信任插件的 hook。
3. 登录 world，只需登录一次：运行 `codex mcp login world`，会打开浏览器。
4. 登录后对 Agent 说「核对 world 的身份和可用能力」，看显示的是不是你本人和正确的公司。刚登录的那个对话里 Agent 可能还看不到 world 的工具，再问一次；不行就新开一个对话。

Codex 每次启动都会更新市场和已装的插件，不用另外设置。插件更新改动了 hook 时，新的 hook 要你再用一次 `/hooks` 信任后才会运行。

## 许可

MIT，见 [LICENSE](LICENSE)。
