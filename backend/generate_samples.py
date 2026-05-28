"""生成更贴近真实手机/可穿戴可观测信号的音乐场景测试数据。

输出:
  data/realistic_scene_samples.csv
  data/realistic_scene_samples.json

设计原则:
  1. 不直接生成“用户正在干嘛”这类不可直接获取的真值字段。
  2. 使用可观测代理信号: 地点类型、运动状态、心率、睡眠/健身摘要、
     环境光/噪音、蓝牙、网络、日历、App 后续事件、停留时长、纠错。
  3. 每条样本保留 ground_truth，便于离线评测。
"""

import csv
import json
import os
import random
from datetime import datetime, timedelta

from scenes import SCENE_NAMES


RANDOM_SEED = 20260521
SAMPLES_PER_SCENE = 40
NUM_USERS = 24

random.seed(RANDOM_SEED)

PLACE_TYPES = [
    "任意", "住宅区", "商场", "酒店", "餐厅", "公园", "写字楼", "机场",
    "图书馆", "海边", "户外", "在途", "高铁站", "地铁站",
]
ACTIVITY_STATES = ["任意", "静止", "慢速", "中速", "高速"]
HEART_RATE_ZONES = ["任意", "静息", "稍高", "高", "波动"]
WEATHERS = ["晴", "多云", "小雨", "大雪", "阴", "雾"]
LIGHT_CLASSES = ["暗光", "室内柔光", "明亮", "强光"]
NOISE_CLASSES = ["安静", "普通", "嘈杂"]
BLUETOOTH = ["任意", "耳机", "车载蓝牙", "家用音响"]
NETWORK = ["任意", "wifi", "蜂窝数据", "无网络", "飞行模式", "蜂窝数据（弱）"]

CONFUSABLE_GROUP = {
    "放松": "放松/减压/深夜EMO",
    "减压": "放松/减压/深夜EMO",
    "深夜EMO": "放松/减压/深夜EMO",
    "图书馆": "图书馆/专注/阅读",
    "专注": "图书馆/专注/阅读",
    "阅读": "图书馆/专注/阅读",
    "健身": "健身/跑步",
    "跑步": "健身/跑步",
    "瑜伽": "瑜伽/冥想",
    "冥想": "瑜伽/冥想",
    "深睡眠": "深睡眠/睡午觉/婴儿安睡",
    "睡午觉": "深睡眠/睡午觉/婴儿安睡",
    "婴儿安睡": "深睡眠/睡午觉/婴儿安睡",
    "胎教": "人群专属",
    "宠物陪伴": "人群专属",
    "经期舒缓": "人群专属",
    "通勤": "通勤",
    "游戏": "游戏",
}

USER_PROFILES = [
    {"tag": "学生", "age": (18, 24), "gender": ["女性", "男性"], "need": "学习专注"},
    {"tag": "女性", "age": (22, 38), "gender": ["女性"], "need": "情绪和身体舒缓"},
    {"tag": "母婴用户", "age": (25, 36), "gender": ["女性", "男性"], "need": "家庭睡眠照护"},
    {"tag": "养宠物", "age": (20, 42), "gender": ["女性", "男性"], "need": "陪伴和放松"},
    {"tag": "任意", "age": (20, 45), "gender": ["女性", "男性"], "need": "日常音乐推荐"},
]

SCENE_TEMPLATES = {
    "放松": {
        "hours": [(19, 22), (14, 17)], "places": ["住宅区", "酒店", "公园"],
        "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"],
        "light": ["室内柔光", "暗光"], "bt": ["耳机", "家用音响"], "calendar": ["", "休息", "无安排"],
        "app": ["短视频退出后停留", "音乐App主动播放", ""], "dwell": (420, 2400),
    },
    "图书馆": {
        "hours": [(9, 12), (14, 18), (19, 21)], "places": ["图书馆"],
        "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["明亮", "室内柔光"],
        "bt": ["耳机"], "calendar": ["复习", "自习", "考试周"], "app": ["学习App打开", "电子书App打开"],
        "dwell": (1200, 7200),
    },
    "健身": {
        "hours": [(7, 9), (18, 21)], "places": ["商场", "写字楼", "酒店"],
        "activity": ["中速", "高速"], "hr": ["稍高", "高", "波动"], "noise": ["普通", "嘈杂"],
        "light": ["明亮"], "bt": ["耳机"], "calendar": ["健身课", "力量训练"], "app": ["健身记录开始"],
        "dwell": (900, 4200),
    },
    "通勤": {
        "hours": [(7, 9), (17, 20)], "places": ["在途", "地铁站", "高铁站", "机场"],
        "activity": ["静止", "慢速", "中速"], "hr": ["静息", "稍高"], "noise": ["普通", "嘈杂"],
        "light": ["明亮", "室内柔光"], "bt": ["耳机", "车载蓝牙"], "calendar": ["上班", "出差", "会议"],
        "app": ["地图导航开始", "打车App打开"], "dwell": (600, 5400),
    },
    "游戏": {
        "hours": [(20, 24), (13, 17)], "places": ["住宅区", "酒店"],
        "activity": ["静止"], "hr": ["稍高", "波动"], "noise": ["安静", "普通"],
        "light": ["暗光", "室内柔光"], "bt": ["耳机"], "calendar": ["", "休息"], "app": ["游戏App前台"],
        "dwell": (900, 7200),
    },
    "专注": {
        "hours": [(9, 12), (14, 18)], "places": ["写字楼", "住宅区", "酒店"],
        "activity": ["静止"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"],
        "light": ["明亮", "室内柔光"], "bt": ["耳机"], "calendar": ["会议", "提交报告", "项目截止"],
        "app": ["办公App前台", "番茄钟开始"], "dwell": (1500, 7200),
    },
    "阅读": {
        "hours": [(10, 12), (15, 18), (21, 23)], "places": ["住宅区", "图书馆", "公园", "酒店"],
        "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["室内柔光", "明亮"],
        "bt": ["耳机", "家用音响"], "calendar": ["", "读书会"], "app": ["电子书App打开", "浏览器长阅读"],
        "dwell": (900, 5400),
    },
    "深睡眠": {
        "hours": [(22, 24), (0, 2)], "places": ["住宅区", "酒店"],
        "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["暗光"],
        "bt": ["家用音响", "耳机"], "calendar": [""], "app": ["屏幕熄灭后持续播放", "睡眠记录开始"],
        "dwell": (3600, 28800),
    },
    "减压": {
        "hours": [(12, 14), (18, 23)], "places": ["住宅区", "写字楼", "酒店", "公园"],
        "activity": ["静止", "慢速"], "hr": ["稍高", "波动"], "noise": ["安静", "普通"],
        "light": ["暗光", "室内柔光"], "bt": ["耳机"], "calendar": ["项目截止", "考试", "会议"],
        "app": ["健康App呼吸训练", "音乐App主动播放"], "dwell": (600, 3600),
    },
    "婴儿安睡": {
        "hours": [(12, 15), (20, 23), (0, 2)], "places": ["住宅区", "酒店"],
        "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静"], "light": ["暗光", "室内柔光"],
        "bt": ["家用音响"], "calendar": ["宝宝睡觉", "哄睡"], "app": ["白噪音App打开"],
        "dwell": (1200, 10800), "profile": ["母婴用户"],
    },
    "胎教": {
        "hours": [(9, 12), (19, 22)], "places": ["住宅区", "公园", "酒店"],
        "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"],
        "light": ["室内柔光", "明亮"], "bt": ["耳机", "家用音响"], "calendar": ["产检", "胎教"],
        "app": ["孕期App打开"], "dwell": (900, 3600), "profile": ["女性"],
    },
    "宠物陪伴": {
        "hours": [(7, 9), (18, 22)], "places": ["住宅区", "公园", "户外"],
        "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静", "普通"],
        "light": ["明亮", "室内柔光"], "bt": ["耳机", "家用音响"], "calendar": ["遛宠", ""],
        "app": ["宠物App打开", "音乐App主动播放"], "dwell": (600, 3600), "profile": ["养宠物"],
    },
    "经期舒缓": {
        "hours": [(8, 10), (20, 23)], "places": ["住宅区", "酒店"],
        "activity": ["静止"], "hr": ["静息", "稍高", "波动"], "noise": ["安静"],
        "light": ["暗光", "室内柔光"], "bt": ["耳机", "家用音响"], "calendar": ["经期提醒", "休息"],
        "app": ["健康App经期记录"], "dwell": (900, 5400), "profile": ["女性"],
    },
    "睡午觉": {
        "hours": [(12, 15)], "places": ["住宅区", "写字楼", "酒店"],
        "activity": ["静止"], "hr": ["静息"], "noise": ["安静", "普通"], "light": ["室内柔光", "暗光"],
        "bt": ["耳机", "家用音响"], "calendar": ["午休", ""], "app": ["闹钟设置", "屏幕熄灭后持续播放"],
        "dwell": (1200, 5400),
    },
    "跑步": {
        "hours": [(6, 9), (18, 21)], "places": ["公园", "户外", "海边"],
        "activity": ["高速"], "hr": ["高", "波动"], "noise": ["普通", "嘈杂"], "light": ["明亮", "强光"],
        "bt": ["耳机"], "calendar": ["跑步", "训练"], "app": ["运动记录开始"], "dwell": (900, 5400),
    },
    "瑜伽": {
        "hours": [(6, 9), (19, 22)], "places": ["住宅区", "公园", "商场"],
        "activity": ["静止", "慢速"], "hr": ["静息", "稍高"], "noise": ["安静"], "light": ["室内柔光", "明亮"],
        "bt": ["耳机", "家用音响"], "calendar": ["瑜伽课", "拉伸"], "app": ["健身App瑜伽课程"],
        "dwell": (1200, 4200),
    },
    "冥想": {
        "hours": [(6, 8), (21, 23)], "places": ["住宅区", "酒店", "公园"],
        "activity": ["静止"], "hr": ["静息"], "noise": ["安静"], "light": ["暗光", "室内柔光"],
        "bt": ["耳机", "家用音响"], "calendar": ["冥想", ""], "app": ["冥想App打开", "健康App呼吸训练"],
        "dwell": (600, 2400),
    },
    "深夜EMO": {
        "hours": [(23, 24), (0, 3)], "places": ["住宅区", "酒店"],
        "activity": ["静止"], "hr": ["稍高", "波动"], "noise": ["安静"], "light": ["暗光"],
        "bt": ["耳机"], "calendar": ["", "失眠"], "app": ["社交App深夜停留", "音乐App主动播放"],
        "dwell": (900, 7200),
    },
}


def choose_profile(scene_name):
    required = SCENE_TEMPLATES[scene_name].get("profile")
    pool = [p for p in USER_PROFILES if not required or p["tag"] in required]
    profile = random.choice(pool)
    age = random.randint(*profile["age"])
    gender = random.choice(profile["gender"])
    return profile["tag"], age, gender, profile["need"]


def random_datetime(base_date, hour_ranges):
    start_hour, end_hour = random.choice(hour_ranges)
    if start_hour == 24:
        start_hour = 0
    hour = random.randint(start_hour, end_hour - 1)
    minute = random.randint(0, 59)
    day_offset = random.randint(0, 34)
    dt = base_date + timedelta(days=day_offset, hours=hour, minutes=minute)
    return dt


def date_type(dt):
    if dt.weekday() >= 5:
        return "周末"
    return "工作日"


def time_slot(hour):
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


def weekday_zh(dt):
    return ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][dt.weekday()]


def hr_bpm(zone, age):
    ranges = {
        "静息": (54, 78),
        "稍高": (79, 112),
        "高": (125, 176),
        "波动": (70, 145),
        "任意": (60, 110),
    }
    low, high = ranges[zone]
    if age > 38 and zone == "高":
        high = min(high, 162)
    return random.randint(low, high)


def steps_for_activity(activity_state):
    ranges = {
        "静止": (0, 80),
        "慢速": (120, 650),
        "中速": (500, 1300),
        "高速": (1100, 2600),
        "任意": (0, 900),
    }
    return random.randint(*ranges[activity_state])


def noise_db(noise_class):
    ranges = {"安静": (28, 45), "普通": (46, 68), "嘈杂": (69, 90)}
    return random.randint(*ranges[noise_class])


def light_lux(light_class):
    ranges = {"暗光": (0, 50), "室内柔光": (51, 350), "明亮": (351, 1200), "强光": (1201, 8000)}
    return random.randint(*ranges[light_class])


def network_for_place(place, hour):
    if hour < 6 and place in ["住宅区", "酒店"]:
        return random.choices(["wifi", "飞行模式", "无网络"], weights=[0.75, 0.15, 0.10])[0]
    if place in ["地铁站", "高铁站", "机场", "在途"]:
        return random.choices(["蜂窝数据", "蜂窝数据（弱）", "wifi"], weights=[0.55, 0.25, 0.20])[0]
    if place in ["住宅区", "写字楼", "图书馆", "酒店"]:
        return random.choices(["wifi", "蜂窝数据"], weights=[0.80, 0.20])[0]
    return random.choices(["蜂窝数据", "wifi", "蜂窝数据（弱）"], weights=[0.60, 0.30, 0.10])[0]


def context_text(row):
    parts = [
        f"{row['weekday']} {row['time_slot']} {row['time']}",
        f"地点类型={row['place_type']}",
        f"运动状态={row['activity_state']}",
        f"心率={row['heart_rate_zone']}({row['heart_rate_bpm']}bpm,{row['heart_rate_trend']})",
        f"天气={row['weather']}",
        f"光线={row['light_class']}",
        f"噪音={row['noise_class']}",
        f"蓝牙={row['bluetooth']}",
        f"网络={row['network']}",
    ]
    if row["calendar_title"]:
        parts.append(f"日历={row['calendar_title']}")
    if row["app_event"]:
        parts.append(f"后续事件={row['app_event']}")
    return "，".join(parts)


def generate_row(scene_name, idx, base_date):
    tpl = SCENE_TEMPLATES[scene_name]
    profile_tag, age, gender, need = choose_profile(scene_name)
    dt = random_datetime(base_date, tpl["hours"])
    place = random.choice(tpl["places"])
    activity = random.choice(tpl["activity"])
    hr_zone = random.choice(tpl["hr"])
    noise = random.choice(tpl["noise"])
    light = random.choice(tpl["light"])
    bluetooth = random.choice(tpl["bt"])
    calendar_title = random.choice(tpl["calendar"])
    app_event = random.choice(tpl["app"])
    weather = random.choices(WEATHERS, weights=[0.42, 0.27, 0.18, 0.04, 0.07, 0.02])[0]

    if scene_name in ["跑步", "通勤"] and place in ["户外", "公园", "海边", "在途"]:
        weather = random.choices(["晴", "多云", "小雨"], weights=[0.55, 0.35, 0.10])[0]
    if scene_name in ["深睡眠", "睡午觉", "婴儿安睡"]:
        app_event = random.choice(tpl["app"])

    dwell_low, dwell_high = tpl["dwell"]
    dwell = random.randint(dwell_low, dwell_high)
    correction_to = ""
    correction_from = ""
    if random.random() < 0.08:
        correction_from = random.choice([s for s in SCENE_NAMES if s != scene_name])
        correction_to = scene_name
        dwell = random.randint(20, 180)

    conflict_flag = False
    conflict_reason = ""
    if random.random() < 0.06:
        conflict_flag = True
        if scene_name in ["深睡眠", "睡午觉", "婴儿安睡"]:
            noise = "普通"
            conflict_reason = "睡眠类场景但环境噪音偏高"
        elif scene_name in ["专注", "图书馆", "阅读"]:
            noise = "嘈杂"
            conflict_reason = "专注/阅读类场景但噪音偏高"
        elif scene_name in ["跑步", "健身"]:
            hr_zone = "稍高"
            conflict_reason = "运动类场景但心率未达到高强度"
        else:
            conflict_reason = "弱冲突样本，用于鲁棒性评测"

    gt_confidence = 0.92
    if conflict_flag:
        gt_confidence -= 0.18
    if correction_to:
        gt_confidence -= 0.10
    if scene_name in ["阅读", "专注", "图书馆"] and place == "图书馆":
        gt_confidence -= 0.05

    row = {
        "sample_id": f"s{idx:05d}",
        "user_id": f"user_{random.randint(1, NUM_USERS):02d}",
        "age": age,
        "gender": gender,
        "user_tag": profile_tag,
        "initial_need": need,
        "date": dt.strftime("%Y-%m-%d"),
        "time": dt.strftime("%H:%M"),
        "hour": dt.hour,
        "weekday": weekday_zh(dt),
        "date_type": date_type(dt),
        "time_slot": time_slot(dt.hour),
        "place_type": place,
        "activity_state": activity,
        "heart_rate_zone": hr_zone,
        "heart_rate_bpm": hr_bpm(hr_zone, age),
        "heart_rate_trend": random.choice(["稳定", "上升", "下降", "波动"]),
        "sleep_minutes_last_night": random.randint(220, 560),
        "sleep_quality": random.choice(["差", "一般", "好"]),
        "recent_workout_minutes_24h": random.randint(0, 95) if scene_name in ["健身", "跑步", "瑜伽"] else random.randint(0, 35),
        "breathing_rate": random.randint(10, 22),
        "steps_last_10min": steps_for_activity(activity),
        "weather": weather,
        "light_lux": light_lux(light),
        "light_class": light,
        "noise_db": noise_db(noise),
        "noise_class": noise,
        "bluetooth": bluetooth,
        "network": network_for_place(place, dt.hour),
        "calendar_title": calendar_title,
        "calendar_start_time": dt.strftime("%Y-%m-%d %H:%M") if calendar_title else "",
        "calendar_location": place if calendar_title else "",
        "calendar_note": calendar_title if calendar_title else "",
        "app_event": app_event,
        "dwell_time_sec": dwell,
        "next_action": random.choice(["继续播放", "切歌", "收藏", "调低音量", "发起导航", "无"]),
        "user_correction_from": correction_from,
        "user_correction_to": correction_to,
        "multiday_consistency": round(random.uniform(0.25, 0.95), 3),
        "conflict_flag": conflict_flag,
        "conflict_reason": conflict_reason,
        "confusable_group": CONFUSABLE_GROUP[scene_name],
        "ground_truth": scene_name,
        "ground_truth_id": SCENE_NAMES.index(scene_name),
        "gt_confidence": round(max(0.55, gt_confidence), 2),
    }
    row["context_text"] = context_text(row)
    return row


def main():
    out_dir = "data"
    os.makedirs(out_dir, exist_ok=True)
    base_date = datetime(2026, 4, 20)
    rows = []
    idx = 1
    for scene_name in SCENE_NAMES:
        for _ in range(SAMPLES_PER_SCENE):
            rows.append(generate_row(scene_name, idx, base_date))
            idx += 1
    random.shuffle(rows)

    csv_path = os.path.join(out_dir, "realistic_scene_samples.csv")
    json_path = os.path.join(out_dir, "realistic_scene_samples.json")
    fields = list(rows[0].keys())

    with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)

    counts = {name: 0 for name in SCENE_NAMES}
    for row in rows:
        counts[row["ground_truth"]] += 1

    print(f"生成 {len(rows)} 条样本，{len(SCENE_NAMES)} 个场景，每个场景 {SAMPLES_PER_SCENE} 条")
    print(csv_path)
    print(json_path)
    print(json.dumps(counts, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
