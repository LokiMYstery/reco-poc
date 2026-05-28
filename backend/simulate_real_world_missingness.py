"""把完整模拟数据降级成更接近真实线上可获取状态的数据。

动机:
  - app_event: 外部App行为通常拿不到，只能拿到自家App内行为或极少数系统事件。
  - calendar: 权限敏感，且很多用户没有日程习惯。
  - place_type: 原始POI/定位类型很杂，死映射会有较大噪声。
  - activity_state: 依赖健康/运动权限，授权率不一定高。
  - heart_rate: 打开App当下可能还没开始运动，或者手表未佩戴/未授权。

输出:
  data/realistic_scene_samples_sparse.csv
  data/missingness_report.txt
"""

import argparse
import csv
import os
import random
from collections import Counter, defaultdict


DEFAULT_SEED = 20260522


PLACE_NOISE_CANDIDATES = {
    "住宅区": ["任意", "酒店", "餐厅", "商场"],
    "写字楼": ["任意", "商场", "餐厅", "酒店"],
    "图书馆": ["任意", "写字楼", "商场"],
    "商场": ["任意", "餐厅", "写字楼"],
    "酒店": ["任意", "住宅区", "写字楼"],
    "餐厅": ["任意", "商场", "写字楼"],
    "公园": ["任意", "户外", "住宅区"],
    "户外": ["任意", "公园", "在途"],
    "海边": ["任意", "户外", "公园"],
    "在途": ["任意", "地铁站", "高铁站", "机场"],
    "地铁站": ["任意", "在途", "高铁站"],
    "高铁站": ["任意", "在途", "地铁站"],
    "机场": ["任意", "在途", "高铁站"],
}


def blank(row, fields):
    for field in fields:
        row[field] = ""


def degrade_place_type(row, accuracy):
    row["original_place_type"] = row.get("place_type", "任意")
    if random.random() <= accuracy:
        row["place_type_available"] = "1"
        row["place_type_quality"] = "exact_or_good_mapping"
        row["place_type_confidence"] = "0.85"
        return
    original = row.get("place_type", "任意")
    row["place_type"] = random.choice(PLACE_NOISE_CANDIDATES.get(original, ["任意"]))
    row["place_type_available"] = "1" if row["place_type"] != "任意" else "0"
    row["place_type_quality"] = "noisy_mapping"
    row["place_type_confidence"] = "0.35" if row["place_type"] != "任意" else "0.10"


def degrade_activity(row, auth_rate):
    if random.random() <= auth_rate:
        row["activity_state_available"] = "1"
        return
    row["activity_state"] = "任意"
    row["steps_last_10min"] = ""
    row["recent_workout_minutes_24h"] = ""
    row["activity_state_available"] = "0"


def degrade_heart_rate(row, auth_rate, stale_rate):
    if random.random() > auth_rate:
        row["heart_rate_zone"] = "任意"
        row["heart_rate_bpm"] = ""
        row["heart_rate_trend"] = ""
        row["heart_rate_available"] = "0"
        row["heart_rate_quality"] = "missing"
        return

    row["heart_rate_available"] = "1"
    if random.random() <= stale_rate:
        # 用户刚打开App，还没真正开始运动：心率可能仍接近日常。
        if row.get("ground_truth") in {"跑步", "健身"}:
            row["heart_rate_zone"] = random.choice(["静息", "稍高"])
            row["heart_rate_bpm"] = str(random.randint(68, 105))
            row["heart_rate_trend"] = random.choice(["稳定", "上升"])
            row["heart_rate_quality"] = "stale_before_activity"
        else:
            row["heart_rate_quality"] = "available"
    else:
        row["heart_rate_quality"] = "available"


def degrade_calendar(row, permission_rate, usage_rate):
    if random.random() <= permission_rate and random.random() <= usage_rate and row.get("calendar_title"):
        row["calendar_available"] = "1"
        return
    blank(row, ["calendar_title", "calendar_start_time", "calendar_location", "calendar_note"])
    row["calendar_available"] = "0"


def degrade_app_event(row, availability_rate):
    # 外部App行为大概率拿不到；保留少量自家App内或系统可推断行为用于弱信号。
    if random.random() <= availability_rate:
        row["app_event_available"] = "1"
        return
    row["app_event"] = ""
    row["app_event_available"] = "0"


def degrade_sleep(row, health_auth_rate):
    if random.random() <= health_auth_rate:
        row["sleep_available"] = "1"
        return
    row["sleep_minutes_last_night"] = ""
    row["sleep_quality"] = ""
    row["breathing_rate"] = ""
    row["sleep_available"] = "0"


def signal_profile(row):
    available = [
        row.get("place_type_available") == "1",
        row.get("activity_state_available") == "1",
        row.get("heart_rate_available") == "1",
        row.get("calendar_available") == "1",
        row.get("app_event_available") == "1",
        row.get("sleep_available") == "1",
        bool(row.get("bluetooth")),
        bool(row.get("network")),
        bool(row.get("weather")),
        bool(row.get("light_class")),
        bool(row.get("noise_class")),
    ]
    count = sum(available)
    if count >= 8:
        return "rich"
    if count >= 5:
        return "medium"
    return "sparse"


def build_context_text(row):
    parts = [
        f"{row.get('weekday', '')} {row.get('time_slot', '')} {row.get('time', '')}",
        f"地点类型={row.get('place_type', '任意')}",
        f"运动状态={row.get('activity_state', '任意')}",
        f"心率={row.get('heart_rate_zone', '任意')}",
        f"天气={row.get('weather', '')}",
        f"光线={row.get('light_class', '')}",
        f"噪音={row.get('noise_class', '')}",
        f"蓝牙={row.get('bluetooth', '')}",
        f"网络={row.get('network', '')}",
    ]
    if row.get("calendar_title"):
        parts.append(f"日历={row['calendar_title']}")
    if row.get("app_event"):
        parts.append(f"后续事件={row['app_event']}")
    parts.append(f"信号完整度={row.get('signal_availability_profile', '')}")
    return "，".join([p for p in parts if p])


def write_report(rows, path):
    counters = defaultdict(Counter)
    for row in rows:
        for field in [
            "place_type_available",
            "activity_state_available",
            "heart_rate_available",
            "calendar_available",
            "app_event_available",
            "sleep_available",
            "signal_availability_profile",
            "heart_rate_quality",
            "place_type_quality",
        ]:
            counters[field][row.get(field, "")] += 1

    with open(path, "w", encoding="utf-8") as f:
        f.write("真实缺失/降级模拟报告\n")
        f.write(f"样本数: {len(rows)}\n\n")
        for field, counter in counters.items():
            f.write(f"{field}\n")
            total = sum(counter.values())
            for key, value in counter.most_common():
                f.write(f"  {key or '<empty>'}: {value} ({value / total:.1%})\n")
            f.write("\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="data/realistic_scene_samples.csv")
    parser.add_argument("--output", default="data/realistic_scene_samples_sparse.csv")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--app-event-rate", type=float, default=0.12)
    parser.add_argument("--calendar-permission-rate", type=float, default=0.35)
    parser.add_argument("--calendar-usage-rate", type=float, default=0.45)
    parser.add_argument("--place-accuracy", type=float, default=0.68)
    parser.add_argument("--activity-auth-rate", type=float, default=0.60)
    parser.add_argument("--heart-rate-auth-rate", type=float, default=0.52)
    parser.add_argument("--heart-rate-stale-rate", type=float, default=0.35)
    parser.add_argument("--sleep-auth-rate", type=float, default=0.45)
    args = parser.parse_args()

    random.seed(args.seed)
    with open(args.input, "r", encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))

    degraded = []
    for original in rows:
        row = dict(original)
        degrade_app_event(row, args.app_event_rate)
        degrade_calendar(row, args.calendar_permission_rate, args.calendar_usage_rate)
        degrade_place_type(row, args.place_accuracy)
        degrade_activity(row, args.activity_auth_rate)
        degrade_heart_rate(row, args.heart_rate_auth_rate, args.heart_rate_stale_rate)
        degrade_sleep(row, args.sleep_auth_rate)
        row["signal_availability_profile"] = signal_profile(row)
        row["context_text"] = build_context_text(row)
        degraded.append(row)

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    fields = list(degraded[0].keys())
    with open(args.output, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(degraded)

    report_path = os.path.join(os.path.dirname(args.output), "missingness_report.txt")
    write_report(degraded, report_path)
    print(f"输出: {args.output}")
    print(f"报告: {report_path}")


if __name__ == "__main__":
    main()
