# scenes.py - 最小可用版本
SCENES = [
    {"id": 0, "name": "放松", "description": "日常放松时刻，不需要特别专注，偏好轻柔的背景音乐", "tags": ["放松", "轻柔", "背景"], "typical_activity": "休息", "typical_location": "家", "typical_time": "晚上", "typical_heart_rate_zone": "静息"},
    {"id": 1, "name": "图书馆", "description": "在图书馆学习或看书，需要安静不打扰的氛围", "tags": ["安静", "学习", "无干扰"], "typical_activity": "学习", "typical_location": "图书馆", "typical_time": "下午", "typical_heart_rate_zone": "静息"},
    {"id": 2, "name": "健身", "description": "健身房力量训练或有氧运动，需要高能量、快节奏的音乐", "tags": ["运动", "高能量", "快节奏"], "typical_activity": "力量训练", "typical_location": "健身房", "typical_time": "傍晚", "typical_heart_rate_zone": "中高"},
    {"id": 3, "name": "通勤", "description": "上下班路上，驾车或公共交通，需要中等节奏的音乐", "tags": ["通勤", "驾车", "中等节奏"], "typical_activity": "驾车", "typical_location": "车内", "typical_time": "早晚高峰", "typical_heart_rate_zone": "静息"},
    {"id": 4, "name": "游戏", "description": "打游戏时，需要沉浸感或战斗感的音乐", "tags": ["游戏", "沉浸", "战斗"], "typical_activity": "打游戏", "typical_location": "家", "typical_time": "晚上", "typical_heart_rate_zone": "中低"},
    {"id": 5, "name": "专注", "description": "工作或学习需要高度专注，偏好无歌词、节奏稳定的纯音乐", "tags": ["专注", "工作", "纯音乐"], "typical_activity": "编程", "typical_location": "办公室", "typical_time": "上午", "typical_heart_rate_zone": "静息"},
    {"id": 6, "name": "阅读", "description": "安静看书，需要舒缓、不分散注意力的背景音乐", "tags": ["阅读", "舒缓", "安静"], "typical_activity": "阅读", "typical_location": "家", "typical_time": "下午", "typical_heart_rate_zone": "静息"},
    {"id": 7, "name": "深睡眠", "description": "晚上入睡，需要极度舒缓、缓慢的音乐或白噪音", "tags": ["睡眠", "入睡", "白噪音"], "typical_activity": "入睡", "typical_location": "卧室", "typical_time": "深夜", "typical_heart_rate_zone": "极低"},
    {"id": 8, "name": "减压", "description": "压力大时需要释放情绪，偏好治愈、温暖的音乐", "tags": ["减压", "治愈", "温暖"], "typical_activity": "压力释放", "typical_location": "不限", "typical_time": "不限", "typical_heart_rate_zone": "中高"},
    {"id": 9, "name": "婴儿安睡", "description": "哄婴儿入睡，需要轻柔、重复的摇篮曲或白噪音", "tags": ["婴儿", "安睡", "摇篮曲"], "typical_activity": "哄睡", "typical_location": "家", "typical_time": "晚上", "typical_heart_rate_zone": "静息"},
    {"id": 10, "name": "胎教", "description": "用户是女性孕期胎教，需要古典音乐或自然音效", "tags": ["胎教", "孕期", "古典"], "typical_activity": "胎教", "typical_location": "家", "typical_time": "上午", "typical_heart_rate_zone": "静息"},
    {"id": 11, "name": "宠物陪伴", "description": "陪伴宠物时，需要舒缓、安定的音乐", "tags": ["宠物", "陪伴", "安定"], "typical_activity": "陪伴宠物", "typical_location": "家", "typical_time": "下午", "typical_heart_rate_zone": "静息"},
    {"id": 12, "name": "经期舒缓", "description": "经期身体不适，需要温暖、放松的音乐", "tags": ["经期", "舒缓", "温暖"], "typical_activity": "休息", "typical_location": "家", "typical_time": "不限", "typical_heart_rate_zone": "静息"},
    {"id": 13, "name": "睡午觉", "description": "白天小睡，需要短暂放松、不易睡过头的轻音乐", "tags": ["午睡", "小憩", "轻音乐"], "typical_activity": "午睡", "typical_location": "家", "typical_time": "中午", "typical_heart_rate_zone": "低"},
    {"id": 14, "name": "跑步", "description": "户外或跑步机跑步，需要匹配步频的高BPM音乐", "tags": ["跑步", "高BPM", "节奏"], "typical_activity": "跑步", "typical_location": "户外", "typical_time": "早晨", "typical_heart_rate_zone": "高"},
    {"id": 15, "name": "瑜伽", "description": "瑜伽或拉伸，需要舒缓、平和的音乐", "tags": ["瑜伽", "拉伸", "平和"], "typical_activity": "瑜伽", "typical_location": "瑜伽室", "typical_time": "早晨", "typical_heart_rate_zone": "低"},
    {"id": 16, "name": "冥想", "description": "冥想或正念练习，需要极简、空灵的音乐或自然声", "tags": ["冥想", "正念", "空灵"], "typical_activity": "冥想", "typical_location": "家", "typical_time": "早晨", "typical_heart_rate_zone": "极低"},
    {"id": 17, "name": "深夜EMO", "description": "深夜情绪低落时，需要共情、治愈的音乐", "tags": ["深夜", "情绪", "治愈"], "typical_activity": "情绪调节", "typical_location": "卧室", "typical_time": "深夜", "typical_heart_rate_zone": "中高"},
]


SCENE_IDS = [s["id"] for s in SCENES]
SCENE_NAMES = [s["name"] for s in SCENES]
SCENE_NAME_TO_ID = {s["name"]: s["id"] for s in SCENES}
CONFUSION_PAIRS = [
    ("放松", "减压"),
    ("健身", "跑步"),
    ("专注", "阅读"),
    ("通勤", "跑步"),
    ("瑜伽", "冥想"),
    ("深睡眠", "睡午觉"),
    ("深睡眠", "冥想"),
    ("深夜EMO", "减压"),
    ("婴儿安睡", "深睡眠"),
    ("经期舒缓", "减压"),
]
