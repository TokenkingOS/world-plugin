# 会议：读妙记，把会上定下的进展写进日进展

会议事件统一由天枢写：主持人或创建人在天枢整卡确认后，天枢在本体里记一条整场会议事件（2026-10-20 定）。本 skill 不记会议事件，也不替天枢补记，只做两件事：

- 读今天开过的会，把会上定下的进展写进对应目标的日进展；
- 在汇报里列出参加过的会。

## 1. 找今天开过的会

```bash
lark-cli vc +search --start <日期> --end <日期> --format json --as user 2>/dev/null
lark-cli minutes +search --owner-ids me --start <日期> --end <日期> --format json --as user 2>/dev/null
```

- 日期写 `YYYY-MM-DD`；`--end` 写同一天就是到当天 23:59。
- 第一条列今天已结束的视频会议；第二条列你自己录的妙记，线下会的录音也在这里。同一场会常有两份录音（组织者的和你自己的），按开始时间重叠合并成一场；读内容优先用你自己那份，权限一定有。几十秒的尾巴录音并进同一场会，或忽略。
- 进度行走 stderr，要丢掉（`2>/dev/null`），不然 JSON 解析不了。
- 没有 `lark-cli`、用户身份没登录、或命令报缺权限：跳过会议这一步，汇报里写一句。不要为此申请授权或改权限。

## 2. 读摘要

```bash
lark-cli vc +detail --meeting-ids <id1>,<id2> --as user --format json 2>/dev/null
lark-cli minutes +detail --as user --minute-tokens <token1>,<token2> --summary --todo --format json 2>/dev/null
```

- `vc +detail` 给起止时间和 `minute_token`；`minutes +detail` 只要 `--summary --todo`，不要 `--transcript`（它往当前目录写文件）。总结拿不准、要确认谁负责时，才读逐字稿核对那一段。
- 妙记链接是 `https://<飞书域名>/minutes/<minute_token>`，搜索结果里的 `app_link` 就是它。

## 3. 写进日进展

- 什么算：会上定下的结论，例如定了方向、打通了、推翻了原判断。
- 怎么写：按 SKILL.md 第 2 步的四段，写进对应目标对象的日进展：结果进 01，要别人配合或判断的进 03；证据给妙记链接。不写「参加了某会」。
- 不写：只是开了会、还没有结论的。
- 本人在场和定时运行都这样做。
- 不记会议事件：不用 `category: meeting` 记事件，天枢没记的会也不补记。那场会要进本体，由主持人在天枢里确认。

## 4. 汇报里列会

- 列出今天参加过的会，每场写主题与妙记链接。
- SKILL.md 第 3 节第 2 步读到的目标对象事件里，类别是 `meeting` 的（多半是天枢记的）：
  - 汇报里列出它们的事件 id；
  - 写这个对象当天的快照时，`source_event_refs` 一并列上。
