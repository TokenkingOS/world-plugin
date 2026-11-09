#!/usr/bin/env python3
"""只选择日进展的日期与走哪条路，不收集会话、不写 world。

work_calendar 默认 cn；weekdays 保留周一至周五，忽略中国节假日。
--date 指定的补写日期直接采用。普通运行返回今天与待检查的上一个工作日；
date 为 null 时整次跳过，previous_workday 仍须由 Agent 检查是否已经写过。

mode 由 daily.json 的 capture_switch 机械判定：没有这一项是 write（照常写日进展），
有合法的一项是 check_only（已切换到本机采集，日终只查漏）。写了但形状不对就报错停下，
不退回 write。
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta
import json
from pathlib import Path
import re
import sys
from urllib.request import urlopen


CALENDAR_URL = "https://tokenhub.corp.tokenkingos.com/static/holiday-cn/{year}.json"
_OBJECT_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)


def load_calendar(year: int) -> dict[date, bool]:
    url = CALENDAR_URL.format(year=year)
    try:
        with urlopen(url, timeout=20) as response:
            data = json.loads(response.read())
    except OSError as exc:
        raise OSError(f"{year} 年日历读取失败（{url}）：{exc}") from exc
    if data.get("year") != year or not isinstance(data.get("days"), list):
        raise ValueError(f"{year} 年日历的 year 或 days 不正确")
    overrides = {}
    for entry in data["days"]:
        day = date.fromisoformat(entry["date"])
        off = entry["isOffDay"]
        if day.year != year or type(off) is not bool:
            raise ValueError(f"{year} 年日历的 date 或 isOffDay 不正确")
        overrides[day] = not off
    return overrides


def select_dates(today: date, calendar: str = "cn", requested_date: date | None = None) -> dict:
    if requested_date is not None:
        return {"calendar": "explicit", "date": requested_date.isoformat(), "previous_workday": None}
    if calendar not in ("cn", "weekdays"):
        raise ValueError('work_calendar 只接受 "cn" 或 "weekdays"')
    years: dict[int, dict[date, bool]] = {}

    def is_workday(day: date) -> bool:
        if calendar == "weekdays":
            return day.weekday() < 5
        if day.year not in years:
            years[day.year] = load_calendar(day.year)
        return years[day.year].get(day, day.weekday() < 5)

    if not is_workday(today):
        return {"calendar": calendar, "date": None, "previous_workday": None}
    previous = today - timedelta(days=1)
    while not is_workday(previous):
        previous -= timedelta(days=1)
    return {"calendar": calendar, "date": today.isoformat(), "previous_workday": previous.isoformat()}


def _has_offset(text: str) -> bool:
    try:
        moment = datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
    except ValueError:
        return False
    return moment.utcoffset() is not None


def capture_mode(config: dict) -> str:
    if "capture_switch" not in config:
        return "write"
    switch = config["capture_switch"]
    if not isinstance(switch, dict) or set(switch) != {"confirmed_at", "selection_id"}:
        raise ValueError('capture_switch 要写成 {"confirmed_at": "<带时区时刻>", "selection_id": "<来源选择 id>"}，'
                         "只有这两项；不按未切换处理")
    confirmed_at, selection_id = switch["confirmed_at"], switch["selection_id"]
    if not isinstance(confirmed_at, str) or not _has_offset(confirmed_at):
        raise ValueError("capture_switch.confirmed_at 要是带时区的时刻，例如 2026-11-06T10:00:00+08:00；不按未切换处理")
    if not isinstance(selection_id, str) or not _OBJECT_ID.fullmatch(selection_id):
        raise ValueError("capture_switch.selection_id 要是 world 里来源选择的 id（8-4-4-4-12 位十六进制）；不按未切换处理")
    return "check_only"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", type=date.fromisoformat, help="明确指定的日期，YYYY-MM-DD；不按日历跳过")
    parser.add_argument("--config", type=Path, default=Path.home() / ".tkos-world" / "daily.json")
    args = parser.parse_args(argv)
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        mode = capture_mode(config)
        plan = {**select_dates(date.today(), config.get("work_calendar", "cn"), args.date), "mode": mode}
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        print(f"日进展日期选择失败：{exc}；本次停止，不收集、不写入。", file=sys.stderr)
        return 2
    print(json.dumps(plan, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
