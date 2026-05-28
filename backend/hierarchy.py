"""音乐场景分层定义。

真实线上信号稀疏时，直接在18个细场景里做Top-1会过于苛刻。
更稳的方式是先判断粗场景，再在粗场景内部细分。
"""

from typing import Dict, List


SCENE_GROUPS: Dict[str, List[str]] = {
    "运动健身": ["健身", "跑步", "瑜伽"],
    "学习阅读": ["图书馆", "专注", "阅读"],
    "睡眠安抚": ["深睡眠", "睡午觉", "婴儿安睡"],
    "情绪舒缓": ["放松", "减压", "冥想", "深夜EMO", "经期舒缓"],
    "出行通勤": ["通勤"],
    "家庭陪伴": ["胎教", "宠物陪伴"],
    "娱乐游戏": ["游戏"],
}


SCENE_TO_GROUP = {
    scene: group
    for group, scenes in SCENE_GROUPS.items()
    for scene in scenes
}


def group_for_scene(scene: str) -> str:
    return SCENE_TO_GROUP[scene]


def scenes_for_groups(groups: List[str]) -> List[str]:
    scenes: List[str] = []
    for group in groups:
        scenes.extend(SCENE_GROUPS[group])
    return scenes
