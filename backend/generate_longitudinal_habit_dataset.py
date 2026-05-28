"""生成用于检验“能否学习用户长期习惯”的长期时序场景数据。

设计参考:
  - Yambda: 用户-物品多事件日志、timestamp、listen/like/dislike、played_ratio、organic/recommendation 标记
  - Deezer RecSys24: 长时间跨度的 timestamped listening events、repeat consumption、sequential recommendation
  - MLHD: 大规模 Last.fm timestamped listening histories、用户级长期行为画像
  - PIMP: session start/end state、问卷用户信息、completion status

本脚本不生成“用户正在做什么”这种手机不可直接获取字段。ground_truth 只作为离线评测标签。
预测可用字段来自: 时间、地点类型及置信度、运动/心率授权状态、环境、连接、日历可用性、App内反馈历史聚合等。
"""

import csv
import json
import math
import os
import random
from collections import Counter, defaultdict
from datetime import datetime, timedelta

from scenes import SCENE_NAME_TO_ID, SCENE_NAMES


RANDOM_SEED = 20260525
NUM_USERS = 32
NUM_DAYS = 120
START_DATE = datetime(2026, 1, 1)
DISRUPTION_WEEK_START_RANGE = (55, 85)

TIME_WINDOWS = {
    "early_morning": (6, 9),
    "work_morning": (9, 12),
    "lunch": (12, 14),
    "afternoon": (14, 18),
    "commute_evening": (17, 20),
    "evening": (20, 23),
    "late_night": (23, 26),
}

PLACE_NOISE_CANDIDATES = {
    "住宅区": ["任意", "酒店", "餐厅", "商场"],
    "写字楼": ["任意", "商场", "餐厅", "酒店"],
    "图书馆": ["任意", "写字楼", "商场"],
    "公园": ["任意", "户外", "住宅区"],
    "户外": ["任意", "公园", "在途"],
    "在途": ["任意", "地铁站", "高铁站", "机场"],
    "地铁站": ["任意", "在途", "高铁站"],
    "高铁站": ["任意", "在途", "地铁站"],
    "机场": ["任意", "在途", "高铁站"],
    "酒店": ["任意", "住宅区", "写字楼"],
    "商场": ["任意", "餐厅", "写字楼"],
}

SCENE_BASE = {
    "放松": {"places": ["住宅区", "酒店", "公园"], "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"], "light": ["室内柔光", "暗光"], "dwell": (420, 2400)},
    "图书馆": {"places": ["图书馆"], "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["明亮", "室内柔光"], "dwell": (1200, 7200)},
    "健身": {"places": ["商场", "写字楼", "酒店"], "activity": ["中速", "高速"], "hr": ["稍高", "高", "波动"], "noise": ["普通", "嘈杂"], "light": ["明亮"], "dwell": (900, 4200)},
    "通勤": {"places": ["在途", "地铁站", "高铁站", "机场"], "activity": ["静止", "慢速", "中速"], "hr": ["静息", "稍高"], "noise": ["普通", "嘈杂"], "light": ["明亮", "室内柔光"], "dwell": (600, 5400)},
    "游戏": {"places": ["住宅区", "酒店"], "activity": ["静止"], "hr": ["稍高", "波动"], "noise": ["安静", "普通"], "light": ["暗光", "室内柔光"], "dwell": (900, 7200)},
    "专注": {"places": ["写字楼", "住宅区", "酒店"], "activity": ["静止"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"], "light": ["明亮", "室内柔光"], "dwell": (1500, 7200)},
    "阅读": {"places": ["住宅区", "图书馆", "公园", "酒店"], "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["室内柔光", "明亮"], "dwell": (900, 5400)},
    "深睡眠": {"places": ["住宅区", "酒店"], "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["暗光"], "dwell": (3600, 28800)},
    "减压": {"places": ["住宅区", "写字楼", "酒店", "公园"], "activity": ["静止", "慢速"], "hr": ["稍高", "波动"], "noise": ["安静", "普通"], "light": ["暗光", "室内柔光"], "dwell": (600, 3600)},
    "婴儿安睡": {"places": ["住宅区", "酒店"], "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静"], "light": ["暗光", "室内柔光"], "dwell": (1200, 10800)},
    "胎教": {"places": ["住宅区", "公园", "酒店"], "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"], "light": ["室内柔光", "明亮"], "dwell": (900, 3600)},
    "宠物陪伴": {"places": ["住宅区", "公园", "户外"], "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"], "light": ["明亮", "室内柔光"], "dwell": (600, 3600)},
    "经期舒缓": {"places": ["住宅区", "酒店"], "activity": ["静止"], "hr": ["静息", "稍高", "波动"], "noise": ["安静"], "light": ["暗光", "室内柔光"], "dwell": (900, 5400)},
    "睡午觉": {"places": ["住宅区", "写字楼", "酒店"], "activity": ["静止"], "hr": ["静息"], "noise": ["安静", "普通"], "light": ["室内柔光", "暗光"], "dwell": (1200, 5400)},
    "跑步": {"places": ["公园", "户外", "海边"], "activity": ["高速"], "hr": ["高", "波动"], "noise": ["普通", "嘈杂"], "light": ["明亮", "强光"], "dwell": (900, 5400)},
    "瑜伽": {"places": ["住宅区", "公园", "商场"], "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静"], "light": ["室内柔光", "明亮"], "dwell": (1200, 4200)},
    "冥想": {"places": ["住宅区", "酒店", "公园"], "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["暗光", "室内柔光"], "dwell": (600, 2400)},
    "深夜EMO": {"places": ["住宅区", "酒店"], "activity": ["静止"], "hr": ["稍高", "波动"], "noise": ["安静"], "light": ["暗光"], "dwell": (900, 7200)},
}

SCENE_TIME_PRIOR = {
    "early_morning": ["跑步", "瑜伽", "冥想", "通勤", "放松"],
    "work_morning": ["专注", "图书馆", "胎教", "阅读"],
    "lunch": ["睡午觉", "减压", "放松", "通勤"],
    "afternoon": ["专注", "阅读", "图书馆", "宠物陪伴", "放松"],
    "commute_evening": ["通勤", "跑步", "健身", "减压"],
    "evening": ["放松", "游戏", "瑜伽", "婴儿安睡", "经期舒缓", "阅读", "胎教"],
    "late_night": ["深睡眠", "深夜EMO", "婴儿安睡", "冥想"],
}

USER_ARCHETYPES = [
    {"tag": "学生", "gender": ["女性", "男性"], "age": (18, 24), "need": "学习专注", "boost": {"图书馆": 1.6, "专注": 1.5, "阅读": 1.3, "深夜EMO": 1.2}},
    {"tag": "上班族", "gender": ["女性", "男性"], "age": (24, 42), "need": "工作通勤减压", "boost": {"通勤": 1.7, "专注": 1.5, "减压": 1.4, "健身": 1.2}},
    {"tag": "母婴用户", "gender": ["女性", "男性"], "age": (25, 38), "need": "家庭睡眠照护", "boost": {"婴儿安睡": 2.2, "深睡眠": 1.3, "睡午觉": 1.2}},
    {"tag": "女性", "gender": ["女性"], "age": (22, 40), "need": "情绪和身体舒缓", "boost": {"经期舒缓": 1.8, "减压": 1.5, "瑜伽": 1.3, "胎教": 1.2}},
    {"tag": "养宠物", "gender": ["女性", "男性"], "age": (20, 45), "need": "陪伴和放松", "boost": {"宠物陪伴": 2.0, "放松": 1.4, "跑步": 1.2}},
    {"tag": "泛娱乐", "gender": ["女性", "男性"], "age": (18, 35), "need": "娱乐放松", "boost": {"游戏": 1.8, "放松": 1.4, "深夜EMO": 1.3}},
]


def weighted_choice(weights):
    names = list(weights.keys())
    vals = [max(0.0, weights[n]) for n in names]
    return random.choices(names, weights=vals, k=1)[0]


def weekday_zh(dt):
    return ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][dt.weekday()]


def date_type(dt):
    return "周末" if dt.weekday() >= 5 else "工作日"


def time_slot_from_hour(hour):
    if hour < 6:
        return "凌晨"
    if hour < 9:
        return "早晨"
    if hour < 12:
        return "上午"
    if hour < 14:
        return "中午"
    if hour < 18:
        return "下午"
    if hour < 22:
        return "晚上"
    return "深夜"


def hour_window(dt):
    hour = dt.hour
    if 6 <= hour < 9:
        return "early_morning"
    if 9 <= hour < 12:
        return "work_morning"
    if 12 <= hour < 14:
        return "lunch"
    if 14 <= hour < 17:
        return "afternoon"
    if 17 <= hour < 20:
        return "commute_evening"
    if 20 <= hour < 23:
        return "evening"
    return "late_night"


def make_user(uid):
    arch = random.choice(USER_ARCHETYPES)
    age = random.randint(*arch["age"])
    gender = random.choice(arch["gender"])
    health_auth = random.random() < random.uniform(0.45, 0.75)
    hr_auth = health_auth and random.random() < random.uniform(0.55, 0.85)
    calendar_auth = random.random() < random.uniform(0.15, 0.45)
    calendar_usage = random.random() < random.uniform(0.25, 0.65)
    stable_habits = {}
    for window, priors in SCENE_TIME_PRIOR.items():
        weights = {scene: 0.25 for scene in SCENE_NAMES}
        for scene in priors:
            weights[scene] += 1.0
        for scene, boost in arch["boost"].items():
            weights[scene] *= boost
        # 每个用户在每个时间窗形成1-2个固定偏好。
        primary = weighted_choice(weights)
        weights[primary] *= 0.25
        secondary = weighted_choice(weights)
        stable_habits[window] = {
            primary: random.uniform(0.50, 0.70),
            secondary: random.uniform(0.15, 0.28),
        }
    return {
        "user_id": f"user_{uid:03d}",
        "age": age,
        "gender": gender,
        "user_tag": arch["tag"],
        "initial_need": arch["need"],
        "health_auth": health_auth,
        "heart_rate_auth": hr_auth,
        "calendar_auth": calendar_auth,
        "calendar_usage": calendar_usage,
        "place_accuracy": random.uniform(0.58, 0.88),
        "app_event_rate": random.uniform(0.03, 0.18),
        "sleep_auth": health_auth and random.random() < 0.65,
        "stable_habits": stable_habits,
        "exploration_rate": random.uniform(0.07, 0.18),
        # 每个用户有一周习惯中断期，用于测试“长期习惯很强但最近一周不遵循”的边界。
        "disruption_start_day": random.randint(*DISRUPTION_WEEK_START_RANGE),
        "disruption_windows": random.sample(list(TIME_WINDOWS.keys()), k=random.choice([1, 2])),
    }


def random_time_for_window(day, window):
    start, end = TIME_WINDOWS[window]
    hour = random.randint(start, end - 1)
    if hour >= 24:
        day = day + timedelta(days=1)
        hour -= 24
    return day.replace(hour=hour, minute=random.randint(0, 59), second=0, microsecond=0)


def choose_scene(user, window, day_index):
    if user["disruption_start_day"] <= day_index < user["disruption_start_day"] + 7 and window in user["disruption_windows"]:
        usual = set(user["stable_habits"][window].keys())
        alternatives = [s for s in SCENE_TIME_PRIOR[window] if s not in usual]
        if not alternatives:
            alternatives = [s for s in SCENE_NAMES if s not in usual]
        return random.choice(alternatives)

    if random.random() < user["exploration_rate"]:
        candidates = SCENE_TIME_PRIOR[window]
        return random.choice(candidates)
    weights = {scene: 0.03 for scene in SCENE_NAMES}
    for scene in SCENE_TIME_PRIOR[window]:
        weights[scene] += 0.25
    for scene, prob in user["stable_habits"][window].items():
        weights[scene] += prob * 3.0
    # 小幅季节/周期漂移，避免完全死板。
    if day_index > NUM_DAYS * 0.65 and user["user_tag"] in {"上班族", "学生"}:
        weights["减压"] += 0.35
        weights["深夜EMO"] += 0.15
    return weighted_choice(weights)


def apply_place_noise(place, user):
    if random.random() < user["place_accuracy"]:
        return place, "1", "exact_or_good_mapping", round(random.uniform(0.70, 0.92), 2)
    noisy = random.choice(PLACE_NOISE_CANDIDATES.get(place, ["任意"]))
    return noisy, "1" if noisy != "任意" else "0", "noisy_mapping", round(random.uniform(0.10, 0.42), 2)


def hr_bpm(zone):
    ranges = {
        "静息": (54, 78),
        "稍高": (79, 112),
        "波动": (70, 145),
        "高": (125, 176),
        "任意": (60, 110),
    }
    return random.randint(*ranges[zone])


def steps_for_activity(activity):
    ranges = {"静止": (0, 80), "慢速": (120, 650), "中速": (500, 1300), "高速": (1100, 2600), "任意": (0, 900)}
    return random.randint(*ranges[activity])


def build_history_features(history, user_id, dt, scene_counts_by_bucket):
    total = sum(history[user_id].values())
    top_scene, top_count = ("", 0)
    if total:
        top_scene, top_count = history[user_id].most_common(1)[0]
    bucket = (dt.weekday(), hour_window(dt))
    bucket_counter = scene_counts_by_bucket[(user_id, bucket)]
    bucket_total = sum(bucket_counter.values())
    bucket_top_scene, bucket_top_count = ("", 0)
    if bucket_total:
        bucket_top_scene, bucket_top_count = bucket_counter.most_common(1)[0]
    return {
        "user_history_events_before": total,
        "user_top_scene_before": top_scene,
        "user_top_scene_ratio_before": round(top_count / total, 3) if total else 0.0,
        "bucket_history_events_before": bucket_total,
        "bucket_top_scene_before": bucket_top_scene,
        "bucket_top_scene_ratio_before": round(bucket_top_count / bucket_total, 3) if bucket_total else 0.0,
    }


def recent_history_features(recent_history, user_id, dt):
    bucket = (dt.weekday(), hour_window(dt))
    counter = recent_history[(user_id, bucket)]
    total = sum(counter.values())
    if not total:
        return {
            "recent_7d_bucket_events_before": 0,
            "recent_7d_bucket_top_scene_before": "",
            "recent_7d_bucket_top_scene_ratio_before": 0.0,
        }
    top_scene, top_count = counter.most_common(1)[0]
    return {
        "recent_7d_bucket_events_before": total,
        "recent_7d_bucket_top_scene_before": top_scene,
        "recent_7d_bucket_top_scene_ratio_before": round(top_count / total, 3),
    }


def choose_network(scene, true_place):
    # 这个App需要联网才能打开，因此不生成“无网络/飞行模式”作为可打开时刻。
    if scene == "通勤" or true_place in {"在途", "地铁站", "高铁站", "机场", "户外", "公园", "海边"}:
        return random.choices(["蜂窝数据", "蜂窝数据（弱）", "wifi"], weights=[0.62, 0.20, 0.18])[0]
    return random.choices(["wifi", "蜂窝数据", "蜂窝数据（弱）"], weights=[0.72, 0.23, 0.05])[0]


def make_events(row, liked, disliked, corrected, dwell):
    events = []
    base = dict(row)
    base["event_type"] = "impression"
    base["event_order"] = 1
    base["event_weight"] = 0.10
    events.append(base)

    listen = dict(row)
    listen["event_type"] = "listen"
    listen["event_order"] = 2
    listen["event_weight"] = 1.00
    events.append(listen)

    if liked:
        liked_row = dict(row)
        liked_row["event_type"] = "like"
        liked_row["event_order"] = 3
        liked_row["event_weight"] = 1.40
        events.append(liked_row)
    if disliked:
        disliked_row = dict(row)
        disliked_row["event_type"] = "dislike"
        disliked_row["event_order"] = 3
        disliked_row["event_weight"] = -1.00
        events.append(disliked_row)
    if corrected:
        correction_row = dict(row)
        correction_row["event_type"] = "correction"
        correction_row["event_order"] = 4
        correction_row["event_weight"] = 1.60
        correction_row["dwell_time_sec"] = dwell
        events.append(correction_row)
    return events


def context_text(row):
    parts = [
        f"{row['weekday']} {row['time_slot']} {row['time']}",
        f"地点={row['place_type']}({row['place_type_quality']}, conf={row['place_type_confidence']})",
        f"运动={row['activity_state']}",
        f"心率={row['heart_rate_zone']}({row['heart_rate_quality']})",
        f"步数10min={row['steps_last_10min']}",
        f"噪音={row['noise_class']}",
        f"光线={row['light_class']}",
        f"蓝牙={row['bluetooth']}",
        f"网络={row['network']}",
        f"历史同桶top={row['bucket_top_scene_before']}:{row['bucket_top_scene_ratio_before']}",
    ]
    if row["calendar_title"]:
        parts.append(f"日历={row['calendar_title']}")
    return "，".join(parts)


def generate_session(user, dt, day_index, session_idx, history, scene_counts_by_bucket, recent_history):
    window = hour_window(dt)
    scene = choose_scene(user, window, day_index)
    base = SCENE_BASE[scene]
    true_place = random.choice(base["places"])
    place, place_available, place_quality, place_conf = apply_place_noise(true_place, user)

    activity = random.choice(base["activity"]) if user["health_auth"] else "任意"
    activity_available = "1" if user["health_auth"] else "0"
    hr_zone = random.choice(base["hr"]) if user["heart_rate_auth"] else "任意"
    heart_rate_available = "1" if user["heart_rate_auth"] else "0"
    heart_rate_quality = "available" if user["heart_rate_auth"] else "missing"
    if user["heart_rate_auth"] and scene in {"跑步", "健身"} and random.random() < 0.28:
        hr_zone = random.choice(["静息", "稍高"])
        heart_rate_quality = "stale_before_activity"

    steps = steps_for_activity(activity) if user["health_auth"] else ""
    workout = random.randint(5, 80) if user["health_auth"] and scene in {"跑步", "健身", "瑜伽"} else (random.randint(0, 20) if user["health_auth"] else "")
    sleep_minutes = random.randint(220, 560) if user["sleep_auth"] else ""
    sleep_quality = random.choice(["差", "一般", "好"]) if user["sleep_auth"] else ""

    calendar_title = ""
    if user["calendar_auth"] and user["calendar_usage"] and random.random() < 0.28:
        scene_calendar = {
            "专注": ["会议", "提交报告", "项目截止"],
            "图书馆": ["复习", "考试"],
            "健身": ["健身课"],
            "跑步": ["跑步训练"],
            "瑜伽": ["瑜伽课"],
            "婴儿安睡": ["宝宝睡觉"],
            "胎教": ["产检", "胎教"],
            "经期舒缓": ["经期提醒"],
            "宠物陪伴": ["遛宠"],
        }
        calendar_title = random.choice(scene_calendar.get(scene, ["休息", "无安排"]))

    app_event = ""
    if random.random() < user["app_event_rate"]:
        app_map = {
            "游戏": "游戏App前台",
            "阅读": "电子书App打开",
            "专注": "办公App前台",
            "冥想": "冥想App打开",
            "跑步": "运动记录开始",
            "健身": "健身记录开始",
            "深睡眠": "睡眠记录开始",
            "婴儿安睡": "白噪音App打开",
        }
        app_event = app_map.get(scene, "音乐App主动播放")

    dwell_low, dwell_high = base["dwell"]
    habit_features = build_history_features(history, user["user_id"], dt, scene_counts_by_bucket)
    recent_features = recent_history_features(recent_history, user["user_id"], dt)
    same_bucket_habit = habit_features["bucket_top_scene_before"] == scene and habit_features["bucket_top_scene_ratio_before"] > 0.45
    dwell = random.randint(dwell_low, dwell_high)
    if same_bucket_habit:
        dwell = int(dwell * random.uniform(1.08, 1.35))
    played_ratio = min(100, max(5, int(random.gauss(78 if same_bucket_habit else 66, 20))))
    liked = random.random() < (0.18 + 0.18 * same_bucket_habit)
    disliked = random.random() < (0.02 if same_bucket_habit else 0.06)
    corrected = random.random() < (0.03 if same_bucket_habit else 0.10)
    correction_from = ""
    correction_to = ""
    if corrected:
        correction_from = random.choice([s for s in SCENE_NAMES if s != scene])
        correction_to = scene
        dwell = random.randint(20, 240)

    row = {
        "session_id": f"{user['user_id']}_{day_index:03d}_{session_idx:02d}",
        "user_id": user["user_id"],
        "day_index": day_index,
        "split": "train" if day_index < int(NUM_DAYS * 0.75) else "test",
        "date": dt.strftime("%Y-%m-%d"),
        "time": dt.strftime("%H:%M"),
        "timestamp": int(dt.timestamp()),
        "hour": dt.hour,
        "weekday": weekday_zh(dt),
        "date_type": date_type(dt),
        "time_slot": time_slot_from_hour(dt.hour),
        "time_window": window,
        "age": user["age"],
        "gender": user["gender"],
        "user_tag": user["user_tag"],
        "initial_need": user["initial_need"],
        "health_auth": int(user["health_auth"]),
        "heart_rate_auth": int(user["heart_rate_auth"]),
        "calendar_auth": int(user["calendar_auth"]),
        "sleep_auth": int(user["sleep_auth"]),
        "is_disruption_week": int(user["disruption_start_day"] <= day_index < user["disruption_start_day"] + 7),
        "is_disruption_window": int(window in user["disruption_windows"]),
        "true_place_type_for_eval_only": true_place,
        "place_type": place,
        "place_type_available": place_available,
        "place_type_quality": place_quality,
        "place_type_confidence": place_conf,
        "activity_state": activity,
        "activity_state_available": activity_available,
        "heart_rate_zone": hr_zone,
        "heart_rate_bpm": hr_bpm(hr_zone) if heart_rate_available == "1" else "",
        "heart_rate_quality": heart_rate_quality,
        "heart_rate_available": heart_rate_available,
        "steps_last_10min": steps,
        "recent_workout_minutes_24h": workout,
        "sleep_minutes_last_night": sleep_minutes,
        "sleep_quality": sleep_quality,
        "weather": random.choices(["晴", "多云", "小雨", "阴", "雾"], weights=[0.42, 0.28, 0.16, 0.10, 0.04])[0],
        "light_class": random.choice(base["light"]),
        "noise_class": random.choice(base["noise"]),
        "bluetooth": "车载蓝牙" if scene == "通勤" and random.random() < 0.28 else random.choice(["耳机", "家用音响", "任意"]),
        "network": choose_network(scene, true_place),
        "calendar_title": calendar_title,
        "calendar_available": int(bool(calendar_title)),
        "app_event": app_event,
        "app_event_available": int(bool(app_event)),
        "is_organic": int(random.random() < 0.72),
        "event_type": "listen",
        "event_order": 2,
        "event_weight": 1.0,
        "played_ratio_pct": played_ratio,
        "track_length_seconds": random.randint(120, 420),
        "dwell_time_sec": dwell,
        "liked": int(liked),
        "disliked": int(disliked),
        "user_correction_from": correction_from,
        "user_correction_to": correction_to,
        "ground_truth": scene,
        "ground_truth_id": SCENE_NAME_TO_ID[scene],
    }
    row.update(habit_features)
    row.update(recent_features)
    row["context_text"] = context_text(row)
    return make_events(row, liked, disliked, corrected, dwell)


def summarize(rows, users):
    by_user = Counter(row["user_id"] for row in rows)
    by_scene = Counter(row["ground_truth"] for row in rows)
    return {
        "rows": len(rows),
        "users": len(users),
        "days": NUM_DAYS,
        "events_per_user_min": min(by_user.values()),
        "events_per_user_median": sorted(by_user.values())[len(by_user) // 2],
        "events_per_user_max": max(by_user.values()),
        "train_rows": sum(1 for r in rows if r["split"] == "train"),
        "test_rows": sum(1 for r in rows if r["split"] == "test"),
        "scene_counts": dict(by_scene),
        "event_type_counts": dict(Counter(row["event_type"] for row in rows)),
        "network_counts": dict(Counter(row["network"] for row in rows)),
        "disruption_rows": sum(1 for row in rows if str(row.get("is_disruption_week")) == "1"),
    }


def main():
    random.seed(RANDOM_SEED)
    os.makedirs("data", exist_ok=True)
    users = [make_user(i + 1) for i in range(NUM_USERS)]
    rows = []
    history = defaultdict(Counter)
    scene_counts_by_bucket = defaultdict(Counter)
    recent_history = defaultdict(Counter)
    recent_queue = defaultdict(list)

    for user in users:
        for day_index in range(NUM_DAYS):
            day = START_DATE + timedelta(days=day_index)
            possible_windows = list(TIME_WINDOWS.keys())
            # 每个用户每天2-5个session，长期比用户数更重要。
            num_sessions = random.choices([2, 3, 4, 5], weights=[0.18, 0.42, 0.30, 0.10])[0]
            windows = random.sample(possible_windows, k=num_sessions)
            for session_idx, window in enumerate(sorted(windows, key=lambda w: TIME_WINDOWS[w][0])):
                dt = random_time_for_window(day, window)
                session_events = generate_session(user, dt, day_index, session_idx, history, scene_counts_by_bucket, recent_history)
                rows.extend(session_events)
                row = next(event for event in session_events if event["event_type"] == "listen")
                uid = row["user_id"]
                scene = row["ground_truth"]
                history[uid][scene] += 1
                bucket = (dt.weekday(), hour_window(dt))
                scene_counts_by_bucket[(uid, bucket)][scene] += 1
                recent_history[(uid, bucket)][scene] += 1
                recent_queue[uid].append((day_index, bucket, scene))
                while recent_queue[uid] and recent_queue[uid][0][0] < day_index - 6:
                    _, old_bucket, old_scene = recent_queue[uid].pop(0)
                    recent_history[(uid, old_bucket)][old_scene] -= 1
                    if recent_history[(uid, old_bucket)][old_scene] <= 0:
                        del recent_history[(uid, old_bucket)][old_scene]

    rows.sort(key=lambda r: (r["user_id"], r["timestamp"]))
    csv_path = "data/longitudinal_habit_scene_samples.csv"
    json_path = "data/longitudinal_habit_scene_samples.json"
    report_path = "data/longitudinal_habit_report.json"
    with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(summarize(rows, users), f, ensure_ascii=False, indent=2)
    print(f"输出: {csv_path}")
    print(f"输出: {json_path}")
    print(f"报告: {report_path}")
    print(json.dumps(summarize(rows, users), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
