"""个性化偏好分通道 - 基于真实反馈和历史上下文的轻量学习器。

偏好分不应该猜“用户正在干嘛”，而是学习用户在某类可观测上下文里
最终更愿意留下来的场景。这个实现使用:
  - 用户级偏好表: user_id + context_bucket + scene_name
  - 全局偏好表: 冷启动和低样本时的回退
  - 反馈信号: 停留时长、主动纠错、收藏/切歌/继续播放等后续行为
  - 人群先验: 问卷标签只作为弱先验，不覆盖实时证据
"""

import csv
import json
import math
import os
import queue
import threading
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional, Tuple

import numpy as np

from scenes import SCENE_NAMES


Bucket = Tuple[int, int, int, int, int, int, int]


@dataclass
class FeedbackEvent:
    user_id: str
    recommended_scene: str
    accepted_scene: str
    context_bucket: Bucket
    reward: float
    dwell_time_sec: int
    timestamp: float = field(default_factory=time.time)
    consistency: float = 0.5


class PreferenceScorer:
    """用户偏好评分器。

    score_all(context) 返回 18 个场景的 0-1 个性化分数。
    无历史时不是简单返回 0.5，而是结合问卷标签、人群场景和上下文信号给弱先验。
    """

    def __init__(
        self,
        learning_rate: float = 0.16,
        decay_days: float = 45.0,
        persistence_path: str = "data/preference.json",
        start_worker: bool = True,
    ):
        self.learning_rate = learning_rate
        self.decay_days = decay_days
        self.persistence_path = persistence_path
        self.scene_names = SCENE_NAMES

        self.user_table = defaultdict(float)
        self.global_table = defaultdict(float)
        self.user_counts = defaultdict(int)
        self.global_counts = defaultdict(int)

        self.feedback_queue = queue.Queue()
        self._stop_worker = False
        self._worker_thread = None
        self._load()
        if start_worker:
            self._start_async_worker()

    # ---------- 特征分桶 ----------

    def _weekday_bucket(self, context: Dict[str, Any]) -> int:
        weekday = context.get("weekday", 0)
        if isinstance(weekday, str):
            mapping = {"周一": 0, "周二": 1, "周三": 2, "周四": 3, "周五": 4, "周六": 5, "周日": 6}
            return mapping.get(weekday, 0)
        return int(weekday) % 7

    def _hour_bucket(self, hour: int) -> int:
        if hour < 6:
            return 0
        if hour < 9:
            return 1
        if hour < 12:
            return 2
        if hour < 14:
            return 3
        if hour < 18:
            return 4
        if hour < 22:
            return 5
        return 6

    def _location_bucket(self, location: str) -> int:
        mapping = {
            "住宅区": 0, "home": 0, "家": 0,
            "写字楼": 1, "office": 1, "办公室": 1,
            "图书馆": 2, "library": 2,
            "商场": 3, "酒店": 4, "餐厅": 5,
            "公园": 6, "户外": 6, "海边": 6, "outdoor": 6,
            "在途": 7, "地铁站": 7, "高铁站": 7, "机场": 7, "car": 7,
        }
        return mapping.get(str(location), 8)

    def _activity_bucket(self, activity: str) -> int:
        mapping = {
            "静止": 0, "still": 0,
            "慢速": 1, "walking": 1,
            "中速": 2, "exercising": 2, "cycling": 2,
            "高速": 3, "running": 3,
            "任意": 4,
        }
        return mapping.get(str(activity), 4)

    def _hr_bucket(self, context: Dict[str, Any]) -> int:
        zone = context.get("heart_rate_zone")
        mapping = {"静息": 0, "稍高": 1, "波动": 2, "高": 3, "任意": 4}
        if zone in mapping:
            return mapping[zone]
        hr = context.get("heart_rate") or context.get("heart_rate_bpm") or 75
        hr = int(float(hr))
        if hr < 78:
            return 0
        if hr < 115:
            return 1
        if hr < 130:
            return 2
        return 3

    def _noise_bucket(self, noise: str) -> int:
        mapping = {"安静": 0, "quiet": 0, "普通": 1, "moderate": 1, "嘈杂": 2, "loud": 2}
        return mapping.get(str(noise), 1)

    def _device_bucket(self, bluetooth: str) -> int:
        mapping = {"任意": 0, "无": 0, "none": 0, "耳机": 1, "headphone": 1, "车载蓝牙": 2, "car": 2, "家用音响": 3, "speaker": 3}
        return mapping.get(str(bluetooth), 0)

    def context_to_bucket(self, context: Dict[str, Any]) -> Bucket:
        hour = int(context.get("hour", 12))
        location = context.get("place_type", context.get("location_type", "任意"))
        activity = context.get("activity_state", context.get("activity", "任意"))
        noise = context.get("noise_class", context.get("noise_level", "普通"))
        bluetooth = context.get("bluetooth", context.get("bluetooth_device", "任意"))

        place_available = str(context.get("place_type_available", "")).strip()
        place_quality = str(context.get("place_type_quality", "")).strip()
        try:
            place_confidence = float(context.get("place_type_confidence") or 0.65)
        except ValueError:
            place_confidence = 0.65
        if place_available == "0" or place_quality == "noisy_mapping" or place_confidence < 0.55:
            location = "任意"

        if str(context.get("activity_state_available", "")).strip() == "0":
            activity = "任意"
        if str(context.get("heart_rate_available", "")).strip() == "0":
            context = {**context, "heart_rate_zone": "任意"}
        if str(context.get("noise_available", "")).strip() == "0":
            noise = "普通"

        return (
            self._weekday_bucket(context),
            self._hour_bucket(hour),
            self._location_bucket(location),
            self._activity_bucket(activity),
            self._hr_bucket(context),
            self._noise_bucket(noise),
            self._device_bucket(bluetooth),
        )

    # ---------- 反馈信号 ----------

    def infer_reward(
        self,
        recommended_scene: str,
        accepted_scene: str,
        dwell_time_sec: int,
        next_action: str = "",
        corrected: bool = False,
    ) -> float:
        if corrected and accepted_scene and accepted_scene != recommended_scene:
            return -0.85
        if dwell_time_sec < 20 or next_action in {"切歌", "关闭", "跳过"}:
            return -0.65
        if next_action in {"收藏", "继续播放"}:
            return 0.95
        if dwell_time_sec >= 900:
            return 0.85
        if dwell_time_sec >= 300:
            return 0.45
        return 0.10

    def _time_decay(self, timestamp: float) -> float:
        age_days = max(0.0, (time.time() - timestamp) / 86400.0)
        return float(math.pow(2.0, -age_days / self.decay_days))

    def _bucket_similarity(self, a: Bucket, b: Bucket) -> float:
        sigmas = [1.2, 1.1, 0.9, 0.8, 0.8, 0.8, 0.9]
        total = 0.0
        for i, (x, y) in enumerate(zip(a, b)):
            d = abs(x - y)
            if i == 0:
                d = min(d, 7 - d)
            total += (d * d) / (2 * sigmas[i] * sigmas[i])
        return float(math.exp(-total))

    def _nearby_buckets(self, center: Bucket) -> Iterable[Bucket]:
        ranges = [7, 7, 9, 5, 5, 3, 4]
        candidates: List[List[int]] = []
        for dim, value in enumerate(center):
            vals = [value]
            if value - 1 >= 0:
                vals.append(value - 1)
            if value + 1 < ranges[dim]:
                vals.append(value + 1)
            candidates.append(vals)

        def dfs(depth: int, current: List[int]):
            if depth == len(center):
                if sum(abs(current[i] - center[i]) for i in range(len(center))) <= 2:
                    yield tuple(current)
                return
            for val in candidates[depth]:
                current.append(val)
                yield from dfs(depth + 1, current)
                current.pop()

        yield from dfs(0, [])

    def update_preference_from_feedback(self, feedback: FeedbackEvent):
        accepted = feedback.accepted_scene or feedback.recommended_scene
        scenes_to_update = [(feedback.recommended_scene, feedback.reward)]
        if accepted != feedback.recommended_scene:
            scenes_to_update.append((accepted, abs(feedback.reward) * 0.95))

        time_w = self._time_decay(feedback.timestamp)
        consistency_w = 0.75 + 0.5 * max(0.0, min(1.0, feedback.consistency))
        for scene, reward in scenes_to_update:
            for bucket in self._nearby_buckets(feedback.context_bucket):
                kernel = self._bucket_similarity(feedback.context_bucket, bucket)
                delta = self.learning_rate * reward * time_w * consistency_w * kernel
                user_key = (feedback.user_id, scene, bucket)
                global_key = (scene, bucket)
                self.user_table[user_key] = max(-1.0, min(1.0, self.user_table[user_key] + delta))
                self.global_table[global_key] = max(-1.0, min(1.0, self.global_table[global_key] + delta * 0.35))
                self.user_counts[user_key] += 1
                self.global_counts[global_key] += 1

    def record_feedback(
        self,
        user_id: str,
        scene_id: str,
        accepted_scene_id: str,
        context: Dict[str, Any],
        dwell_time_sec: int,
        signal_type: Optional[str] = None,
        next_action: str = "",
    ):
        corrected = bool(accepted_scene_id and accepted_scene_id != scene_id)
        reward = self.infer_reward(scene_id, accepted_scene_id, dwell_time_sec, next_action, corrected)
        if signal_type == "positive":
            reward = max(reward, 0.8)
        elif signal_type == "weak_positive":
            reward = max(reward, 0.25)
        elif signal_type == "negative":
            reward = min(reward, -0.65)

        event = FeedbackEvent(
            user_id=user_id,
            recommended_scene=scene_id,
            accepted_scene=accepted_scene_id or scene_id,
            context_bucket=self.context_to_bucket(context),
            reward=reward,
            dwell_time_sec=dwell_time_sec,
            consistency=float(context.get("multiday_consistency", 0.5)),
        )
        self.feedback_queue.put(event)

    # ---------- 查询打分 ----------

    def _profile_prior(self, scene: str, context: Dict[str, Any]) -> float:
        tag = context.get("user_tag") or context.get("profile_tag") or "任意"
        gender = context.get("gender", "")
        priors = {
            "母婴用户": {"婴儿安睡": 0.18, "深睡眠": 0.06, "睡午觉": 0.05},
            "女性": {"经期舒缓": 0.10, "胎教": 0.06, "减压": 0.04},
            "养宠物": {"宠物陪伴": 0.18, "放松": 0.04},
            "学生": {"图书馆": 0.12, "专注": 0.10, "阅读": 0.06},
        }
        prior = priors.get(tag, {}).get(scene, 0.0)
        if gender == "女性" and scene in {"经期舒缓", "胎教"}:
            prior += 0.04
        return prior

    def _context_prior(self, scene: str, context: Dict[str, Any]) -> float:
        hour = int(context.get("hour", 12))
        place = context.get("place_type", context.get("location_type", ""))
        activity = context.get("activity_state", context.get("activity", ""))
        hr = context.get("heart_rate_zone", "")
        noise = context.get("noise_class", "")
        bt = context.get("bluetooth", context.get("bluetooth_device", ""))
        app = context.get("app_event", "")
        cal = context.get("calendar_title", context.get("calendar_keyword", ""))

        score = 0.0
        if scene == "通勤" and (place in {"在途", "地铁站", "高铁站", "机场"} or bt == "车载蓝牙" or "导航" in app):
            score += 0.18
        if scene == "跑步" and activity == "高速" and hr in {"高", "波动"}:
            score += 0.20
        if scene == "健身" and ("健身" in cal or "健身" in app or (activity in {"中速", "高速"} and hr in {"稍高", "高"})):
            score += 0.16
        if scene == "图书馆" and place == "图书馆" and noise == "安静":
            score += 0.20
        if scene == "专注" and ("办公" in app or "番茄钟" in app or "截止" in cal):
            score += 0.16
        if scene == "阅读" and ("电子书" in app or "长阅读" in app):
            score += 0.18
        if scene == "游戏" and "游戏" in app:
            score += 0.22
        if scene == "深睡眠" and (hour >= 22 or hour < 5) and place in {"住宅区", "酒店"}:
            score += 0.18
        if scene == "睡午觉" and 12 <= hour < 15:
            score += 0.16
        if scene == "减压" and ("呼吸" in app or hr in {"稍高", "波动"}):
            score += 0.10
        if scene == "冥想" and ("冥想" in app or "呼吸" in app):
            score += 0.18
        if scene == "瑜伽" and ("瑜伽" in app or "瑜伽" in cal):
            score += 0.18
        if scene == "深夜EMO" and (hour >= 23 or hour < 3) and ("社交" in app or hr == "波动"):
            score += 0.14
        if scene == "婴儿安睡" and ("宝宝" in cal or "白噪音" in app):
            score += 0.18
        if scene == "胎教" and ("孕期" in app or "胎教" in cal or "产检" in cal):
            score += 0.18
        if scene == "宠物陪伴" and ("宠物" in app or "遛宠" in cal):
            score += 0.18
        if scene == "经期舒缓" and ("经期" in app or "经期" in cal):
            score += 0.18
        return score

    def _history_score(self, user_id: str, scene: str, bucket: Bucket) -> Tuple[float, int]:
        user_key = (user_id, scene, bucket)
        global_key = (scene, bucket)
        u = self.user_table.get(user_key, 0.0)
        g = self.global_table.get(global_key, 0.0)
        uc = self.user_counts.get(user_key, 0)
        gc = self.global_counts.get(global_key, 0)
        user_conf = min(1.0, uc / 8.0)
        global_conf = min(0.7, gc / 18.0)
        score = user_conf * u + (1.0 - user_conf) * global_conf * g
        return score, uc + gc

    def score(self, scene_id: str, context: Dict[str, Any]) -> float:
        scene = scene_id if isinstance(scene_id, str) else SCENE_NAMES[int(scene_id)]
        user_id = str(context.get("user_id", "anonymous"))
        bucket = self.context_to_bucket(context)
        history, evidence_count = self._history_score(user_id, scene, bucket)
        prior = self._profile_prior(scene, context) + self._context_prior(scene, context)
        confidence = min(1.0, evidence_count / 12.0)

        raw = 0.50 + prior + history
        # 历史证据越多，分数越敢偏离中性；冷启动时保持温和。
        raw = 0.50 + (raw - 0.50) * (0.55 + 0.45 * confidence)
        return float(max(0.0, min(1.0, raw)))

    def score_all(self, context: Dict[str, Any]) -> Dict[str, float]:
        return {scene: self.score(scene, context) for scene in self.scene_names}

    # ---------- 从历史 CSV 批量学习 ----------

    def fit_from_csv(self, csv_path: str, limit: Optional[int] = None):
        with open(csv_path, "r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            for idx, row in enumerate(reader):
                if limit is not None and idx >= limit:
                    break
                scene = row.get("ground_truth", "")
                if not scene:
                    continue
                recommended = row.get("user_correction_from") or scene
                accepted = row.get("user_correction_to") or scene
                dwell = int(float(row.get("dwell_time_sec") or 0))
                corrected = bool(row.get("user_correction_to"))
                reward = self.infer_reward(recommended, accepted, dwell, row.get("next_action", ""), corrected)
                event = FeedbackEvent(
                    user_id=row.get("user_id", "anonymous"),
                    recommended_scene=recommended,
                    accepted_scene=accepted,
                    context_bucket=self.context_to_bucket(row),
                    reward=reward,
                    dwell_time_sec=dwell,
                    consistency=float(row.get("multiday_consistency") or 0.5),
                )
                self.update_preference_from_feedback(event)
        self._save()

    # ---------- 异步与持久化 ----------

    def _start_async_worker(self):
        def worker():
            while not self._stop_worker:
                try:
                    feedback = self.feedback_queue.get(timeout=0.5)
                except queue.Empty:
                    continue
                self.update_preference_from_feedback(feedback)
                self._save()
                self.feedback_queue.task_done()

        self._worker_thread = threading.Thread(target=worker, daemon=True)
        self._worker_thread.start()

    def _serialize_table(self, table):
        return {"|".join([str(k[0]), str(k[1]), ",".join(map(str, k[2]))]): v for k, v in table.items()}

    def _serialize_counts(self, table):
        return {"|".join([str(k[0]), str(k[1]), ",".join(map(str, k[2]))]): v for k, v in table.items()}

    def _restore_user_key(self, key: str):
        user, scene, bucket = key.split("|")
        return user, scene, tuple(map(int, bucket.split(",")))

    def _restore_scene_key(self, key: str):
        scene, bucket = key.split("|")
        return scene, tuple(map(int, bucket.split(",")))

    def _save(self):
        os.makedirs(os.path.dirname(self.persistence_path), exist_ok=True)
        payload = {
            "user_table": self._serialize_table(self.user_table),
            "global_table": {"|".join([str(k[0]), ",".join(map(str, k[1]))]): v for k, v in self.global_table.items()},
            "user_counts": self._serialize_counts(self.user_counts),
            "global_counts": {"|".join([str(k[0]), ",".join(map(str, k[1]))]): v for k, v in self.global_counts.items()},
        }
        with open(self.persistence_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)

    def _load(self):
        if not os.path.exists(self.persistence_path):
            return
        try:
            with open(self.persistence_path, "r", encoding="utf-8") as f:
                payload = json.load(f)
            for key, value in payload.get("user_table", {}).items():
                self.user_table[self._restore_user_key(key)] = float(value)
            for key, value in payload.get("global_table", {}).items():
                self.global_table[self._restore_scene_key(key)] = float(value)
            for key, value in payload.get("user_counts", {}).items():
                self.user_counts[self._restore_user_key(key)] = int(value)
            for key, value in payload.get("global_counts", {}).items():
                self.global_counts[self._restore_scene_key(key)] = int(value)
        except Exception as exc:
            print(f"加载偏好表失败: {exc}")

    def shutdown(self):
        self._stop_worker = True
        if self._worker_thread:
            self._worker_thread.join(timeout=2)


if __name__ == "__main__":
    scorer = PreferenceScorer(start_worker=False, persistence_path="data/preference_demo.json")
    sample = {
        "user_id": "user_01",
        "hour": 22,
        "weekday": "周五",
        "place_type": "住宅区",
        "activity_state": "静止",
        "heart_rate_zone": "波动",
        "noise_class": "安静",
        "bluetooth": "耳机",
        "app_event": "社交App深夜停留",
    }
    print(sorted(scorer.score_all(sample).items(), key=lambda x: x[1], reverse=True)[:5])
