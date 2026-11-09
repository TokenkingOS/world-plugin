"""汇总本机 Codex 与 Claude Code 某一天的会话，给 world-daily 整理日进展用。

只读本机文件、只用标准库，不联网。每个会话列出工作目录、时间段、你的请求与每轮最后的答复；
每条截断，疑似密钥与凭证隐去。子 Agent 会话、Claude Code 的旁支对话不列。日进展任务自己的运行
（以 $world-daily、/world:world-daily 或老技能的 $tkos-world-daily、/tkos-world-daily 调起、载入了这个 skill，
或写了「【日进展」开头的外部事件）从那一刻起到下一条你的请求为止都不列，免得把写过的内容再当进展；
同一会话里在它之前、之后的工作照列。

    python collect_sessions.py                 # 今天，本地时区
    python collect_sessions.py --date 2026-10-09 --tz +08:00

Codex 读 ~/.codex/sessions/<年>/<月>/<日>/*.jsonl（当天与前一天的目录，前一天开的会话可能延续到今天）
与 ~/.codex/archived_sessions；Claude Code 读 ~/.claude/projects/*/*.jsonl。按每行的 timestamp 过滤到这一天。

~/.tkos-world/daily.json 里写了 session_dirs 的，只列工作目录在这些目录（含子目录）下的会话，条目可以用 * ? 通配；
不写就全列。写在 daily.json 里，插件更新换 skill 时不会冲掉。
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
import fnmatch
import json
import os
from pathlib import Path
import re
import runpy
import sys
from typing import Any, Iterator, Optional

# 技能目录名；老技能 tkos-world-daily 在 11/20 下线前还会跑，它的运行也要略去
SKILL_NAMES = ("world-daily", "tkos-world-daily")
# 调起时写的名字：Claude Code 里插件技能带插件名前缀
CALL_NAMES = (*SKILL_NAMES, "world:world-daily")
DAILY_EVENT = "【日进展"
# Claude Code 载入 skill 时注入的目录行；别的 skill 正文提到本 skill 名字不算
_SKILL_DIRECTORY = re.compile(rf"^Base directory for this skill: .*[\\/](?:{'|'.join(map(re.escape, SKILL_NAMES))})[\\/]?\s*$",
                              re.M)

_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_SECRETS = [
    (re.compile(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"), r"\1[已隐去]"),
    (re.compile(r"(?i)\b((?:password|passwd|secret|token|api[_-]?key)[\"']?\s*[:=]\s*[\"']?)[^\s\"',;]{6,}"), r"\1[已隐去]"),
    (re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"), "[已隐去]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bxox[abprs]-[A-Za-z0-9-]{10,}"), "[已隐去]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[已隐去]"),
]
_LONG = re.compile(r"[A-Za-z0-9_+=-]{32,}")
_URL = re.compile(r"https?://[^\s<>\"'）)\]]+")


def _long(match: re.Match[str]) -> str:
    word = match.group(0)
    if _UUID.match(word) or not (re.search(r"[a-z]", word) and re.search(r"[A-Z]", word) and re.search(r"[0-9]", word)):
        return word
    return "[已隐去]"


def redact(text: str) -> str:
    """隐去疑似密钥：常见前缀与「token=…」写法，以及链接以外同时含大小写字母与数字的长串
    （UUID、十六进制哈希与链接本身保留，链接里的 token= 照样隐去）。"""
    for pattern, replacement in _SECRETS:
        text = pattern.sub(replacement, text)
    parts, last = [], 0
    for match in _URL.finditer(text):
        parts += [_LONG.sub(_long, text[last:match.start()]), match.group(0)]
        last = match.end()
    return "".join(parts) + _LONG.sub(_long, text[last:])


def clip(text: str, limit: int) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit] + "…"


def parse_time(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def parse_offset(text: str) -> timezone:
    match = re.fullmatch(r"([+-])([0-9]{2}):([0-9]{2})", text)
    if not match:
        raise argparse.ArgumentTypeError("--tz must look like +08:00")
    minutes = int(match[2]) * 60 + int(match[3])
    return timezone(timedelta(minutes=minutes if match[1] == "+" else -minutes))


@dataclass
class Session:
    tool: str
    session_id: str
    cwd: str = ""
    requests: list[tuple[datetime, str]] = field(default_factory=list)
    answers: list[tuple[datetime, str]] = field(default_factory=list)
    daily_runs: int = 0  # 这一天里日进展任务自己的运行，不列

    def times(self) -> list[datetime]:
        return [moment for moment, _ in self.requests + self.answers]


def _jsonl(path: Path) -> Iterator[dict[str, Any]]:
    try:
        with path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if isinstance(item, dict):
                    yield item
    except OSError:
        return


def _texts(content: Any, kinds: tuple[str, ...]) -> list[str]:
    if isinstance(content, str):
        return [content]
    if not isinstance(content, list):
        return []
    return [item["text"] for item in content
            if isinstance(item, dict) and item.get("type") in kinds and isinstance(item.get("text"), str)]


def _real_request(text: str) -> bool:
    """注入的环境说明、命令回显与系统提醒都以尖括号或固定前缀开头，不算你的请求。"""
    stripped = text.strip()
    return bool(stripped) and not stripped.startswith(("<", "# AGENTS.md", "Caveat:", "[Request interrupted"))


def _calls_daily(text: str) -> bool:
    """调起日进展任务的用户消息：$ 或 / 开头的调用、Claude Code 的命令回显、载入 skill 时注入的正文。
    只是在对话里提到 skill 名字的不算。"""
    stripped = text.strip()
    return (stripped.startswith(tuple(f"{sign}{name}" for name in CALL_NAMES for sign in "$/"))
            or any(f"<command-name>/{name}</command-name>" in stripped for name in CALL_NAMES)
            or bool(_SKILL_DIRECTORY.search(stripped)))


def _writes_daily(name: Any, arguments: Any) -> bool:
    """写日进展外部事件的工具调用：参数里带「【日进展」的 world_record_event。"""
    if not isinstance(name, str) or not name.endswith("world_record_event"):
        return False
    text = arguments if isinstance(arguments, str) else json.dumps(arguments, ensure_ascii=False)
    return DAILY_EVENT in text


def codex_session(path: Path, start: datetime, end: datetime) -> Optional[Session]:
    session = Session("Codex", path.stem[-36:])
    items: list[tuple[datetime, str, str]] = []  # (时刻, 来源, 文字)：来源 user_item、user_event、user_response、final
    for line in _jsonl(path):
        payload = line.get("payload") if isinstance(line.get("payload"), dict) else {}
        kind, sub = line.get("type"), payload.get("type")
        if kind == "session_meta":
            session.session_id = str(payload.get("id") or session.session_id)
            session.cwd = str(payload.get("cwd") or session.cwd)
            source = payload.get("source")
            if payload.get("thread_source") == "subagent" or (isinstance(source, dict) and "subagent" in source):
                return None
            continue
        if kind == "turn_context" and not session.cwd:
            session.cwd = str(payload.get("cwd") or "")
        moment = parse_time(line.get("timestamp"))
        if moment is None or not start <= moment < end:
            continue
        if kind == "event_msg" and sub == "item_completed" and isinstance(payload.get("item"), dict):
            item = payload["item"]
            if item.get("type") == "UserMessage":
                items += [(moment, "user_item", text) for text in _texts(item.get("content"), ("text",))]
            elif item.get("type") == "AgentMessage" and item.get("phase") == "final_answer":
                items += [(moment, "final", text) for text in _texts(item.get("content"), ("Text", "text"))]
            elif item.get("type") == "McpToolCall" and _writes_daily(item.get("tool"), item.get("arguments")):
                items.append((moment, "daily", ""))
        elif kind == "response_item" and sub in {"function_call", "custom_tool_call"} \
                and _writes_daily(payload.get("name"), payload.get("arguments") or payload.get("input")):
            items.append((moment, "daily", ""))
        elif kind == "event_msg" and sub == "user_message" and isinstance(payload.get("message"), str):
            items.append((moment, "user_event", payload["message"]))
        elif kind == "event_msg" and sub == "task_complete" and isinstance(payload.get("last_agent_message"), str):
            items.append((moment, "final", payload["last_agent_message"]))
        elif kind == "response_item" and sub == "message" and payload.get("role") == "user":
            items += [(moment, "user_response", text) for text in _texts(payload.get("content"), ("input_text",))]
    # 同一条请求可能在三处都有：有 UserMessage 就只用它，其次 user_message 事件，最后才用模型输入里的用户消息。
    sources = {source for _, source, _ in items}
    wanted = next((name for name in ("user_item", "user_event", "user_response") if name in sources), None)
    seen: set[str] = set()
    daily = False  # 正处在日进展任务自己的运行里：到下一条你的请求为止
    for moment, source, text in items:
        if source == "daily" or (source == wanted and _calls_daily(text)):
            session.daily_runs += not daily
            daily = True
        elif source == "final":
            if not daily and text.strip() and text not in seen:
                seen.add(text)
                session.answers.append((moment, text))
        elif source == wanted and _real_request(text):
            daily = False
            session.requests.append((moment, text))
    return session


def claude_session(path: Path, start: datetime, end: datetime) -> Optional[Session]:
    session = Session("Claude Code", path.stem)
    pending: Optional[tuple[datetime, str]] = None  # 本轮到目前为止最后一段答复，下一条请求到来时落定
    daily = False  # 正处在日进展任务自己的运行里：到下一条你的请求为止

    def enter_daily() -> None:
        nonlocal daily, pending
        if pending and not daily:
            session.answers.append(pending)
        pending = None
        session.daily_runs += not daily
        daily = True

    for line in _jsonl(path):
        if line.get("isSidechain") or line.get("type") not in {"user", "assistant"}:
            continue
        session.session_id = str(line.get("sessionId") or session.session_id)
        session.cwd = str(line.get("cwd") or session.cwd)
        moment = parse_time(line.get("timestamp"))
        if moment is None or not start <= moment < end:
            continue
        message = line.get("message") if isinstance(line.get("message"), dict) else {}
        content = message.get("content")
        if line["type"] == "assistant":
            if any(isinstance(block, dict) and block.get("type") == "tool_use"
                   and _writes_daily(block.get("name"), block.get("input")) for block in content or []):
                enter_daily()
            texts = [text for text in _texts(content, ("text",)) if text.strip()]
            if texts and not daily:
                pending = (moment, texts[-1])
            continue
        texts = _texts(content, ("text",))
        if any(_calls_daily(text) for text in texts):  # 命令回显与载入 skill 的注入也算调起，所以先于过滤判断
            enter_daily()
            continue
        requests = [text for text in texts if _real_request(text)] if not line.get("isMeta") else []
        if requests:
            if pending:
                session.answers.append(pending)
                pending = None
            daily = False
            session.requests += [(moment, text) for text in requests]
    if pending:
        session.answers.append(pending)
    return session


def day_window(day: date, tz: timezone) -> tuple[datetime, datetime]:
    start = datetime(day.year, day.month, day.day, tzinfo=tz)
    return start, start + timedelta(days=1)


def codex_files(home: Path, day: date, start: datetime) -> list[Path]:
    folders = [home / "sessions" / f"{d:%Y}" / f"{d:%m}" / f"{d:%d}" for d in (day - timedelta(days=1), day)]
    files = [path for folder in folders if folder.is_dir() for path in sorted(folder.glob("*.jsonl"))]
    archived = home / "archived_sessions"
    if archived.is_dir():  # 归档的会话不按日期分目录，按修改时间挑
        files += [path for path in sorted(archived.glob("*.jsonl")) if path.stat().st_mtime >= start.timestamp()]
    return files


def claude_files(home: Path, start: datetime) -> list[Path]:
    projects = home / "projects"
    if not projects.is_dir():
        return []
    return [path for path in sorted(projects.glob("*/*.jsonl")) if path.stat().st_mtime >= start.timestamp()]


def _norm(path: str) -> str:
    return os.path.normcase(os.path.normpath(os.path.expanduser(path.strip())))


def session_dirs(config: Path) -> list[str]:
    """daily.json 的 session_dirs，规整成可比的形式；没有这个文件或没写这一项时是空表（全列）。"""
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as exc:
        raise ValueError(f"读不了 {config}（{exc.__class__.__name__}）") from exc
    value = data.get("session_dirs") if isinstance(data, dict) else None
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        raise ValueError(f"{config} 里的 session_dirs 要写成目录的列表，例如 [\"~/TKOS\"]")
    return [_norm(item) for item in value]


def in_dirs(cwd: str, dirs: list[str]) -> bool:
    """工作目录本身或它的某一级上级与 dirs 的某一条相同（可带通配）。dirs 为空时都算；工作目录未知的不算。"""
    if not dirs:
        return True
    if not cwd:
        return False
    path = _norm(cwd)
    while True:
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in dirs):
            return True
        parent = os.path.dirname(path)
        if parent == path:
            return False
        path = parent


def collect(day: date, tz: timezone, codex_home: Path, claude_home: Path) -> list[Session]:
    start, end = day_window(day, tz)
    sessions = [codex_session(path, start, end) for path in codex_files(codex_home, day, start)]
    sessions += [claude_session(path, start, end) for path in claude_files(claude_home, start)]
    kept = [session for session in sessions if session is not None and (session.requests or session.answers
                                                                          or session.daily_runs)]
    return sorted(kept, key=lambda item: min(item.times(), default=end))


def render(sessions: list[Session], day: date, tz: timezone, max_chars: int, max_messages: int,
           dirs: Optional[list[str]] = None) -> str:
    def stamp(moment: datetime) -> str:
        return moment.astimezone(tz).strftime("%H:%M")

    def lines(entries: list[tuple[datetime, str]]) -> list[str]:
        shown = entries[-max_messages:]
        out = [f"- {stamp(moment)} {clip(redact(text), max_chars)}" for moment, text in shown]
        if len(entries) > len(shown):
            out.insert(0, f"- （更早的 {len(entries) - len(shown)} 条略）")
        return out

    offset = datetime.now(tz).strftime("%z")
    with_content = [session for session in sessions if session.requests or session.answers]
    used = [session for session in with_content if in_dirs(session.cwd, dirs or [])]
    out = [f"# 本机会话 {day.isoformat()}（UTC{offset[:3]}:{offset[3:]}）", "",
           f"Codex {sum(s.tool == 'Codex' for s in used)} 个、Claude Code {sum(s.tool == 'Claude Code' for s in used)} 个；"
           f"日进展任务自己的运行 {sum(s.daily_runs for s in sessions)} 次，已略去。每条已截断到 {max_chars} 字，疑似密钥已隐去。", ""]
    if dirs:
        out[-1:-1] = [f"按 daily.json 的 session_dirs 只列这些目录下的会话：{'、'.join(dirs)}；"
                      f"另有 {len(with_content) - len(used)} 个会话不在其中，已略去。"]
    if not used:
        out.append("今天没有会话记录。")
    for session in used:
        times = session.times()
        out += [f"## {session.tool} · {session.cwd or '（工作目录未知）'} · {stamp(min(times))}–{stamp(max(times))}"
                f"（会话 {session.session_id[:8]}）", ""]
        if session.requests:
            out += ["请求：", *lines(session.requests), ""]
        if session.answers:
            out += ["答复（每轮最后一段）：", *lines(session.answers), ""]
    return "\n".join(out).rstrip() + "\n"


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="汇总本机会话（默认只读、不联网）；--select-dates 只选日，可读取工作日历。")
    parser.add_argument("--select-dates", action="store_true", help="只输出日进展选日与 mode 的 JSON，不收集会话、不写文件")
    parser.add_argument("--date", type=date.fromisoformat, help="哪一天，YYYY-MM-DD；默认今天")
    parser.add_argument("--tz", type=parse_offset, help="时区，例如 +08:00；默认本机时区")
    parser.add_argument("--codex-home", type=Path, default=Path.home() / ".codex")
    parser.add_argument("--claude-home", type=Path, default=Path.home() / ".claude")
    parser.add_argument("--max-chars", type=int, default=300, help="每条最多保留的字数")
    parser.add_argument("--max-messages", type=int, default=12, help="每个会话的请求与答复各最多列几条（取最后几条）")
    parser.add_argument("--out", type=Path, help="写进这个文件（UTF-8）而不是标准输出；Windows 控制台中文乱码时用")
    parser.add_argument("--config", type=Path, default=Path.home() / ".tkos-world" / "daily.json",
                        help="日进展配置，读其中的 session_dirs（只列这些目录下的会话）")
    args = parser.parse_args(argv)
    if args.select_dates:
        selector = runpy.run_path(str(Path(__file__).with_name("select_dates.py")))
        plan_args = ["--config", str(args.config)]
        if args.date:
            plan_args += ["--date", args.date.isoformat()]
        return selector["main"](plan_args)
    try:
        dirs = session_dirs(args.config)
    except ValueError as exc:
        print(f"collect_sessions：{exc}", file=sys.stderr)
        return 2
    tz = args.tz or datetime.now().astimezone().tzinfo
    day = args.date or datetime.now(tz).date()
    sessions = collect(day, tz, args.codex_home, args.claude_home)
    text = render(sessions, day, tz, args.max_chars, args.max_messages, dirs)
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.buffer.write(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
