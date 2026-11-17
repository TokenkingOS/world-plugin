r"""已切换到本机采集的人，日终查本机采集的漏。只读 world-capture 插件的本机状态目录，不写文件、不联网、只用标准库。

由收集脚本的入口调起（定时任务已放行这条命令）：

    python collect_sessions.py --capture-check --date 2026-11-17

状态目录是 ~/.tkos-world/capture（Windows 是 %USERPROFILE%\.tkos-world\capture），和钩子一样认 TKOS_CAPTURE_HOME。
check() 交回：
- selections：要在 world 里核的来源选择。本机 config.json 里每种 Agent 合用的一项；一项都没有时（还在用 World Capture
  组件，或这台机器不采集），退回 daily.json 的 capture_switch.selection_id。
- rounds：每种 Agent 这一天起了几轮后台轮、成功几轮、失败几轮，现在队列里积压几条。
- findings：要报给本人的问题，每项有 code 和照着报的 text。
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone, tzinfo
import json
from pathlib import Path
import re
from typing import Any, Callable, Optional

FORMATS = {"claude": "claude-session-jsonl/1", "codex": "codex-rollout-jsonl/1"}
NAMES = {"claude": "Claude Code", "codex": "Codex"}
STALE = timedelta(hours=24)  # 队列里等了这么久还没送走，算没补上
SEND_MISMATCHES = ("copy_mismatch", "unknown_import")  # rounds/ 里送出那一步记的、本机对不上 world 的导入
_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_SOURCE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@+~-]{0,199}")

# 后台轮失败的类别（rounds/ 里 failure.class）：是什么、本人怎么处理。
FAILURES = {
    "program_missing": ("找不到 {agent} 程序", "装好 {agent}，或让钩子的环境里找得到它"),
    "login_invalid": ("{agent} 的模型账号或登录失效", "在命令行重新登录 {agent}"),
    "world_unavailable": ("world 连接不可用（没装 world 插件、连不上或没登录）", "在任一交互会话里重新登录 world 插件的连接"),
    "network": ("网络不通", "网络恢复后下一轮自动重试"),
    "other": ("其他（{detail}）", "看本机 rounds/ 里这几轮的 calls"),
}
# 钩子写进 unsupported.json 的原因（sh 版与 PowerShell 版）。
UNSUPPORTED = {
    "macos_too_old": "macOS 低于 15（本机采集只支持 15 及以上）",
    "jq_missing": "没有 /usr/bin/jq",
    "openssl_missing": "没有 /usr/bin/openssl",
    "not_macos": "sh 版钩子跑在了 macOS 以外的系统上",
    "os_version_unknown": "读不出 macOS 版本",
    "powershell_core": "钩子是由 PowerShell 7（pwsh）跑的，本机采集要 Windows PowerShell 5.1",
    "json_parser_unavailable": "Windows PowerShell 读不了 JSON（缺 System.Web.Extensions）",
}
# 当天有会话、钩子却一个都没读过时，多半是什么原因、本人怎么处理。
HOOK_CAUSES = {
    "codex": "多半是没信任。请在 Codex 里用 /hooks 审核并信任 world-capture 的钩子（world-capture 每次更新后都要再信任一次）。",
    "claude": "多半是那些会话所在文件夹的信任框没接受（接受之前钩子不跑），或 world-capture 插件没装好、没启用："
              "请在 Claude Code 的插件管理（/plugin）里看 world-capture 是否已启用。",
}


def _time(value: Any) -> Optional[datetime]:
    """带时区的 ISO 时刻；不带时区或读不出的是 None。"""
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    except ValueError:
        return None
    return moment if moment.utcoffset() is not None else None


def _read(path: Path) -> Any:
    """文件里的 JSON；不在是 None，读不出是 ValueError。"""
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))  # PowerShell 写的可能带 BOM
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as exc:
        raise ValueError(str(exc)) from exc


def _optional(path: Path) -> Any:
    """读不出的当没有。"""
    try:
        return _read(path)
    except ValueError:
        return None


def _records(folder: Path, pattern: str) -> list[dict]:
    """目录下这些文件里读得出的 JSON 对象；读不出的跳过。"""
    found = []
    for path in sorted(folder.glob(pattern)) if folder.is_dir() else []:
        value = _optional(path)
        if isinstance(value, dict):
            found.append(value)
    return found


def _entry(config: Any, agent: str) -> tuple[str, Optional[dict]]:
    """config.json 里这种 Agent 的那一项，按钩子的规则判合不合用：absent、invalid 或 capturing。"""
    agents = config.get("agents") if isinstance(config, dict) else None
    entry = agents.get(agent) if isinstance(agents, dict) else None
    if entry is None:
        return "absent", None
    if not isinstance(entry, dict):
        return "invalid", None
    version, folder, source = entry.get("selection_version"), entry.get("folder"), entry.get("source_id")
    usable = (entry.get("format") == FORMATS[agent] and _time(entry.get("history_from")) is not None
              and isinstance(entry.get("selection_id"), str) and _UUID.fullmatch(entry["selection_id"]) is not None
              and isinstance(version, (int, float)) and not isinstance(version, bool) and version >= 1 and version == int(version)
              and isinstance(source, str) and _SOURCE_ID.fullmatch(source) is not None
              and isinstance(folder, str) and Path(folder).is_absolute() and all(ord(char) >= 32 for char in folder))
    return ("capturing", entry) if usable else ("invalid", None)


def switch_selection(daily: Path) -> Optional[str]:
    """daily.json 里切换时记下的 capture_switch.selection_id；第 0 步的选日已经核过形状。"""
    try:
        switch = (_read(daily) or {}).get("capture_switch")
    except (ValueError, AttributeError):
        return None
    selection = switch.get("selection_id") if isinstance(switch, dict) else None
    return selection if isinstance(selection, str) else None


class _Clock:
    def __init__(self, day: date, tz: tzinfo):
        self.tz = tz
        self.start = datetime(day.year, day.month, day.day, tzinfo=tz)
        self.end = self.start + timedelta(days=1)

    def today(self, moment: Optional[datetime]) -> bool:
        return moment is not None and self.start <= moment < self.end

    def show(self, moment: datetime) -> str:
        return moment.astimezone(self.tz).strftime("%m-%d %H:%M")

    def span(self, first: datetime, last: datetime) -> str:
        return self.show(first) if self.show(first) == self.show(last) else f"{self.show(first)}–{self.show(last)}"


def _utc(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _classes(failed: list[dict], agent: str) -> tuple[list[dict], str, str]:
    """一组失败的轮按类别数：[{class, detail, count}]（detail 取这一类第一次的）、怎么说、怎么处理。"""
    groups: dict[str, dict] = {}
    for record in failed:
        failure = record["failure"] if isinstance(record["failure"], dict) else {}
        name = str(failure.get("class") or "other")
        groups.setdefault(name, {"class": name, "detail": str(failure.get("detail") or ""), "count": 0})["count"] += 1
    labels, hints = [], []
    for group in groups.values():
        label, hint = FAILURES.get(group["class"], FAILURES["other"])
        fill = {"agent": NAMES[agent], "detail": group["detail"] or group["class"]}
        labels.append(f"{label.format(**fill)} {group['count']} 轮")
        hints.append(hint.format(**fill))
    return list(groups.values()), "；".join(labels), "；".join(dict.fromkeys(hints))


def _rounds(home: Path, agent: str, clock: _Clock, now: datetime) -> tuple[Optional[dict], list[dict]]:
    """这种 Agent 的后台轮与积压：这一天的摘要，和要报的问题。"""
    records = [record for record in _records(home / "rounds", "*.json")
               if record.get("agent") == agent and record.get("format") == FORMATS[agent] and _time(record.get("started_at"))]
    records.sort(key=lambda record: (_time(record["started_at"]), str(record.get("round_id") or "")))
    queue = _records(home / "queue" / FORMATS[agent], "entry-*.json")
    if not records and not queue:
        return None, []
    today = [record for record in records if clock.today(_time(record["started_at"]))]
    failed_today = [record for record in today if record.get("failure")]
    summary = {"rounds": len(today), "ok": len(today) - len(failed_today), "failed": len(failed_today), "queued": len(queue)}
    name, findings = NAMES[agent], []
    sent = [mismatch for record in today for mismatch in (record.get("mismatches") if isinstance(record.get("mismatches"), list) else [])
            if isinstance(mismatch, dict) and mismatch.get("reason") in SEND_MISMATCHES]
    if sent:
        counts = {reason: sum(1 for mismatch in sent if mismatch["reason"] == reason) for reason in SEND_MISMATCHES}
        items = sum(len(mismatch["items"]) for mismatch in sent if isinstance(mismatch.get("items"), list))
        findings.append({"code": "import_mismatch", "agent": agent, **counts, "items": items,
                         "text": f"{name} 今天有 {len(sent)} 处本机对不上 world 的导入，涉及 {items} 条：模型交给 world 的和本机算好的"
                                 f"骨架不一致、world 照收了的 {counts['copy_mismatch']} 处，送了这一批里没有的条目的 "
                                 f"{counts['unknown_import']} 处。要维护方对着本机 rounds/ 里这几轮核。"})
    streak = []
    for record in reversed(records):
        if not record.get("failure"):
            break
        streak.insert(0, record)
    if streak:
        since, last = _time(streak[0]["started_at"]), _time(streak[-1]["started_at"])
        classes, labels, hints = _classes(streak, agent)
        earlier = since < clock.start
        findings.append({"code": "round_failing", "agent": agent, "failing": len(streak), "since": _utc(since), "last": _utc(last),
                         "classes": classes, "queued": len(queue), "earlier": earlier,
                         "text": f"{name} 的后台轮连续失败 {len(streak)} 轮（{clock.span(since, last)}{'，此前已报' if earlier else ''}）："
                                 f"{labels}。"
                                 f"待提炼积压 {len(queue)} 条，都留在本机队列，下一轮成功时补送。处理：{hints}。"})
    elif failed_today:
        first, last = _time(failed_today[0]["started_at"]), _time(failed_today[-1]["started_at"])
        classes, labels, _ = _classes(failed_today, agent)
        findings.append({"code": "round_recovered", "agent": agent, "failed": len(failed_today), "classes": classes,
                         "text": f"{name} 今天有 {len(failed_today)} 轮后台轮失败（{clock.span(first, last)}：{labels}），"
                                 "之后的轮已成功，已恢复。"})
    seen = [moment for moment in (_time(item.get("first_seen_at")) for item in queue) if moment]
    if seen and now - min(seen) > STALE:
        oldest = min(seen)
        hours = int((now - oldest).total_seconds() // 3600)
        findings.append({"code": "backlog_stale", "agent": agent, "queued": len(queue), "oldest": _utc(oldest),
                         "text": f"{name} 的待提炼队列里最早一条（{clock.show(oldest)} 入队）已等了 {hours} 小时，超过 24 小时还没送走；"
                                 f"现在积压 {len(queue)} 条。"})
    return summary, findings


def _session_files(agent: str, folder: Path, day: date) -> list[Path]:
    """钩子读的那个文件夹里，这一天可能写过的会话文件。"""
    if agent == "codex":  # sessions/<年>/<月>/<日>/；前一天开的会话可能延续到今天
        return [path for each in (day - timedelta(days=1), day)
                for path in sorted((folder / f"{each:%Y}" / f"{each:%m}" / f"{each:%d}").glob("*.jsonl"))]
    return sorted(folder.glob("*/*.jsonl"))  # projects/<工作目录>/<会话>.jsonl


def _hook(home: Path, agent: str, entry: dict, clock: _Clock, has_work: Callable[[str, Path, datetime, datetime], bool]) -> list[dict]:
    """当天（开始采集以后）有这种 Agent 的会话，却没有一个它的位置文件被更新过：钩子没在跑。"""
    since = max(clock.start, _time(entry["history_from"]))
    if since >= clock.end:
        return []
    recent, skipped, findings = [], 0, []
    for path in _session_files(agent, Path(entry["folder"]), clock.start.date()):
        try:
            if path.stat().st_mtime >= since.timestamp():
                recent.append(path)
        except OSError:  # 失效的符号链接，或正被压缩、挪走的文件
            skipped += 1
    if skipped:
        findings.append({"code": "session_files_skipped", "agent": agent, "skipped": skipped,
                         "text": f"{NAMES[agent]} 有 {skipped} 个会话文件读不了（失效的符号链接，或正被压缩、挪走），这次查钩子没算它们。"})
    sessions = sum(1 for path in recent if has_work(agent, path, since, clock.end))
    read = [record for record in _records(home / "transcripts", "*.json") if record.get("format") == FORMATS[agent]
            and (updated := _time(record.get("updated_at"))) is not None and updated >= since]
    if sessions and not read:
        findings.append({"code": "hook_not_running", "agent": agent, "sessions": sessions,
                         "text": f"{NAMES[agent]} 今天有 {sessions} 个会话，采集钩子一个都没读过：{NAMES[agent]} 的采集钩子没在跑，"
                                 + HOOK_CAUSES[agent]})
    return findings


def check(home: Path, day: date, tz: tzinfo, now: datetime, switch_selection_id: Optional[str],
          has_work: Callable[[str, Path, datetime, datetime], bool] = lambda *_: True) -> dict:
    """查这台机器这一天的本机采集。has_work(Agent, 会话文件, 起, 止) 说这段时间里这个会话有没有要采的工作。"""
    clock, findings = _Clock(day, tz), []
    unsupported = _optional(home / "unsupported.json")
    if isinstance(unsupported, dict):
        reason = str(unsupported.get("reason") or "")
        first, last = _time(unsupported.get("first_seen_at")), _time(unsupported.get("last_seen_at"))
        when = "，".join(part for part in (first and f"{clock.show(first)} 起", last and f"最近一次 {clock.show(last)}") if part)
        findings.append({"code": "unsupported", "agent": None, "reason": reason,
                         "text": f"这台机器不采集：{UNSUPPORTED.get(reason, reason)}（{unsupported.get('system') or ''} "
                                 f"{unsupported.get('os_version') or ''}{'，' + when if when else ''}）。钩子在这台机器上不读会话、"
                                 "不起后台轮，world 里也没有这台机器的运行回执。"})
    try:
        config = _read(home / "config.json")
    except ValueError:
        config = False
    readable = config is None or isinstance(config, dict)
    entries = {agent: _entry(config, agent) for agent in FORMATS}
    if not readable:
        findings.append({"code": "config_unreadable", "agent": None,
                         "text": "本机采集的 config.json 读不出，钩子什么都不采：在 Agent 里重新说「开始采集 world 进展」。"})
    for agent, (status, _) in entries.items():
        if status == "invalid":
            findings.append({"code": "entry_invalid", "agent": agent,
                             "text": f"本机 config.json 里 {NAMES[agent]} 那一项不合用，钩子当它不存在，{NAMES[agent]} 的会话没在采集："
                                     f"在 {NAMES[agent]} 里重新说「开始采集 world 进展」。"})
    if readable and not isinstance(unsupported, dict) and all(status == "absent" for status, _ in entries.values()):
        findings.append({"code": "not_capturing", "agent": None,
                         "text": "这台机器上没有插件采集的配置，Claude Code、Codex 的会话都不经插件采集。还在用 World Capture 组件的，"
                                 "以组件为准；都没有的，在 Agent 里说「开始采集 world 进展」。"})
    selections = [{"agent": agent, "selection_id": entry["selection_id"], "selection_version": int(entry["selection_version"]),
                   "from": "config"} for agent, (status, entry) in entries.items() if status == "capturing"]
    if not selections and switch_selection_id:
        selections = [{"agent": None, "selection_id": switch_selection_id, "selection_version": None, "from": "capture_switch"}]
    rounds = {}
    for agent in FORMATS:
        summary, found = _rounds(home, agent, clock, now)
        if summary:
            rounds[agent] = summary
        findings += found
    for agent, (status, entry) in entries.items():
        if status == "capturing":
            findings += _hook(home, agent, entry, clock, has_work)
    paused = _optional(home / "paused.json")
    if isinstance(paused, dict):
        reason = str(paused.get("reason") or "")
        first = _time(paused.get("first_seen_at"))
        cause = "World Capture 组件在采集" if reason == "component_capturing" else reason
        findings.append({"code": "paused", "agent": None, "reason": reason,
                         "text": f"插件暂停送出：{cause}{f'（{clock.show(first)} 起）' if first else ''}。条目照常排进本机队列；"
                                 "组件停止采集并退出后，下一次钩子接着送。"})
    imported = _optional(home / "import.json")
    missing = imported.get("missing") if isinstance(imported, dict) else None
    if isinstance(missing, int) and not isinstance(missing, bool) and missing > 0:
        agent = imported.get("agent") if imported.get("agent") in FORMATS else None
        at = _time(imported.get("imported_at"))
        earlier = at is not None and at < clock.start
        findings.append({"code": "import_missing", "agent": agent, "missing": missing, "earlier": earlier,
                         "text": f"迁移{f'（{clock.show(at)}）' if at else ''}时有 {missing} 条在会话文件里找不到原文，不会进 world；"
                                 f"这是迁移留下的覆盖缺口，之后不会再变。{'此前已报。' if earlier else ''}"})
    return {"date": day.isoformat(), "selections": selections, "rounds": rounds, "findings": findings}
