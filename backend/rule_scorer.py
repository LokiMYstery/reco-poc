"""Missing-aware 规则评分通道。

这个通道专门处理真实线上常见问题:
  - place_type 可能来自粗糙映射，置信度不高
  - app_event / calendar 经常缺失
  - activity_state / heart_rate 依赖健康授权
  - 用户刚打开App时，心率可能还没上来

规则分不是为了替代 embedding/LLM，而是作为低权限、可解释的兜底。
"""

from typing import Any, Dict

from scenes import SCENE_NAMES


def _s(value: Any) -> str:
    if value is None:
        return ""
    text = str(value)
    if text.lower() == "nan":
        return ""
    return text


def _f(value: Any, default: float = 0.0) -> float:
    try:
        text = _s(value)
        return float(text) if text else default
    except ValueError:
        return default


def _i(value: Any, default: int = 0) -> int:
    return int(_f(value, default))


class RuleScorer:
    """对18个场景输出0-1规则分。"""

    PLACE_CANDIDATE_RANK_WEIGHTS = (1.0, 0.45, 0.20)
    TRANSIT_PLACES = {"在途", "地铁站", "高铁站", "机场"}
    EXERCISE_PLACES = {"运动场所", "公园", "户外", "海边"}
    PASS_BY_PLACES = {"写字楼", "住宅区", "餐厅", "商场", "酒店"}

    def __init__(self):
        self.scene_names = SCENE_NAMES

    def _available(self, context: Dict[str, Any], field: str) -> bool:
        marker = _s(context.get(f"{field}_available"))
        if marker:
            return marker == "1"
        value = _s(context.get(field))
        return bool(value) and value != "任意"

    def _place_weight(self, context: Dict[str, Any]) -> float:
        if _s(context.get("place_type_available")) == "0":
            return 0.0
        confidence = _f(context.get("place_type_confidence"), 0.65)
        quality = _s(context.get("place_type_quality"))
        if quality == "noisy_mapping":
            confidence = min(confidence, 0.35)
        return max(0.0, min(0.85, confidence))

    def _place_evidence(self, context: Dict[str, Any]):
        candidates = context.get("place_candidates")
        if isinstance(candidates, list) and candidates:
            evidence = []
            overall_quality = _s(context.get("place_type_quality"))
            for rank, candidate in enumerate(candidates[:3]):
                if not isinstance(candidate, dict):
                    continue
                place = _s(candidate.get("place_type"))
                confidence = _f(candidate.get("confidence"))
                if not place or confidence <= 0:
                    continue
                if _s(candidate.get("quality")) == "noisy_mapping" or overall_quality == "noisy_mapping":
                    confidence = min(confidence, 0.45)
                weight = min(0.85, confidence) * self.PLACE_CANDIDATE_RANK_WEIGHTS[rank]
                evidence.append((place, weight))
            if evidence:
                return evidence
        return [(_s(context.get("place_type")), self._place_weight(context))]

    def place_evidence_strength(self, context: Dict[str, Any], place_name: str) -> float:
        return max((weight for place, weight in self._place_evidence(context) if place == place_name), default=0.0)

    def has_library_hint(self, context: Dict[str, Any]) -> bool:
        return self.place_evidence_strength(context, "图书馆") >= 0.15

    def _mobility_bucket(self, context: Dict[str, Any], fallback_activity: str) -> str:
        speed = _f(context.get("speed_mps"), -1.0)
        if speed >= 0:
            if speed < 0.5:
                return "静止"
            if speed < 2.5:
                return "慢速"
            if speed < 7.0:
                return "中速"
            return "高速"
        return fallback_activity

    def _max_place_strength(self, evidence, places) -> float:
        return max((weight for place, weight in evidence if place in places), default=0.0)

    def _adjust_place_evidence_for_mobility(self, evidence, mobility: str, exercise_evidence: float):
        if mobility not in {"中速", "高速"}:
            return evidence
        adjusted = []
        for place, weight in evidence:
            if place in self.TRANSIT_PLACES:
                adjusted.append((place, weight))
                continue
            if place in self.PASS_BY_PLACES:
                weight *= 0.45 if mobility == "高速" else 0.65
            elif place in self.EXERCISE_PLACES and mobility == "高速" and exercise_evidence < 0.55:
                weight *= 0.70
            adjusted.append((place, weight))
        return adjusted

    def _evidence_scores(
        self,
        context: Dict[str, Any],
        place_evidence,
        mobility: str,
        hr: str,
        steps: int,
        workout: int,
        bluetooth: str,
        hour: int,
        network: str,
        app: str,
        calendar: str,
    ):
        speed = _f(context.get("speed_mps"), -1.0)
        mobility_state = _s(context.get("mobility_state"))
        motion_activity = _s(context.get("motion_activity"))
        transit_place = self._max_place_strength(place_evidence, self.TRANSIT_PLACES)
        exercise_place = self._max_place_strength(place_evidence, self.EXERCISE_PLACES)

        transit = 0.0
        exercise = 0.0

        if transit_place >= 0.15:
            transit += 0.25 + 0.45 * transit_place
        if bluetooth == "车载蓝牙":
            transit += 0.35
        if mobility_state in {"vehicle_like", "automotive", "in_vehicle", "transit"} or motion_activity in {"automotive", "in_vehicle"}:
            transit += 0.42
        if speed >= 7.0 or mobility == "高速":
            transit += 0.34
        elif mobility == "中速" and steps < 250:
            transit += 0.14
        if 7 <= hour < 10 or 17 <= hour < 20:
            transit += 0.12
        if network in {"蜂窝数据", "蜂窝数据（弱）"}:
            transit += 0.04
        if "导航" in app:
            transit += 0.18

        if exercise_place >= 0.15:
            exercise += 0.20 + 0.35 * exercise_place
        if mobility == "中速":
            exercise += 0.18
        elif mobility == "高速":
            # 7m/s 以上日常更像车行；只有强运动证据时才允许解释为冲刺/高强度训练。
            exercise += 0.06
        if steps >= 1200:
            exercise += 0.32
        elif steps >= 500:
            exercise += 0.16
        if hr in {"高", "波动"}:
            exercise += 0.24
        elif hr == "稍高":
            exercise += 0.12
        if workout >= 20:
            exercise += 0.24
        elif workout >= 10:
            exercise += 0.12
        if any(k in app for k in ["运动", "健身", "跑步", "训练"]) or any(k in calendar for k in ["运动", "健身", "跑步", "训练"]):
            exercise += 0.18

        return min(1.0, transit), min(1.0, exercise)

    def _apply_place_signal(self, scores, place: str, place_w: float):
        if place in {"图书馆"}:
            self._add(scores, "图书馆", 0.30 * place_w)
            self._add(scores, "阅读", 0.12 * place_w)
            self._add(scores, "专注", 0.10 * place_w)
        if place in {"写字楼"}:
            self._add(scores, "专注", 0.22 * place_w)
            self._add(scores, "睡午觉", 0.08 * place_w)
        if place in {"住宅区", "酒店"}:
            for scene in ["放松", "阅读", "深睡眠", "睡午觉", "游戏", "冥想"]:
                self._add(scores, scene, 0.08 * place_w)
        if place in {"在途", "地铁站", "高铁站", "机场"}:
            self._add(scores, "通勤", 0.34 * place_w)
        if place in {"公园", "户外", "海边"}:
            self._add(scores, "跑步", 0.18 * place_w)
            self._add(scores, "瑜伽", 0.10 * place_w)
            self._add(scores, "宠物陪伴", 0.10 * place_w)
        if place == "运动场所":
            self._add(scores, "健身", 0.18 * place_w)
            self._add(scores, "瑜伽", 0.08 * place_w)
            self._add(scores, "跑步", 0.06 * place_w)

    def _add(self, scores, scene, amount):
        scores[scene] = min(1.0, scores[scene] + amount)

    def _sub(self, scores, scene, amount):
        scores[scene] = max(0.0, scores[scene] - amount)

    def _scale(self, scores, scene, multiplier):
        scores[scene] = max(0.0, min(1.0, scores[scene] * multiplier))

    def score_all(self, context: Dict[str, Any]) -> Dict[str, float]:
        scores = {scene: 0.08 for scene in self.scene_names}

        hour = _i(context.get("hour"), 12)
        place = _s(context.get("place_type"))
        activity = _s(context.get("activity_state"))
        hr = _s(context.get("heart_rate_zone"))
        noise = _s(context.get("noise_class"))
        light = _s(context.get("light_class"))
        bluetooth = _s(context.get("bluetooth"))
        network = _s(context.get("network"))
        user_tag = _s(context.get("user_tag"))
        initial_need = _s(context.get("initial_need"))
        gender = _s(context.get("gender"))
        calendar = _s(context.get("calendar_title"))
        app = _s(context.get("app_event"))
        steps = _i(context.get("steps_last_10min"), 0)
        workout = _i(context.get("recent_workout_minutes_24h"), 0)
        sleep_quality = _s(context.get("sleep_quality"))
        place_w = self._place_weight(context)
        hr_quality = _s(context.get("heart_rate_quality"))
        hr_w = 0.45 if hr_quality == "stale_before_activity" else 1.0
        activity_available = self._available(context, "activity_state")
        hr_available = self._available(context, "heart_rate")
        place_evidence = self._place_evidence(context)
        mobility = self._mobility_bucket(context, activity)
        mobility_available = activity_available or _f(context.get("speed_mps"), -1.0) >= 0 or bool(_s(context.get("mobility_state")))
        transit_evidence, exercise_evidence = self._evidence_scores(
            context,
            place_evidence,
            mobility,
            hr,
            steps,
            workout,
            bluetooth,
            hour,
            network,
            app,
            calendar,
        )
        place_evidence = self._adjust_place_evidence_for_mobility(place_evidence, mobility, exercise_evidence)
        library_hint = self.place_evidence_strength(context, "图书馆") >= 0.15
        conflicting_place_hint = any(
            candidate_place in {"商场", "餐厅", "运动场所", "在途", "地铁站", "高铁站", "机场"}
            and candidate_weight >= 0.35
            for candidate_place, candidate_weight in place_evidence
        )

        # 时间是低权限且稳定的主干信号。
        if 23 <= hour or hour < 3:
            self._add(scores, "深夜EMO", 0.28)
            self._add(scores, "深睡眠", 0.24)
            self._add(scores, "放松", 0.08)
        if 22 <= hour or hour < 6:
            self._add(scores, "深睡眠", 0.22)
        if 12 <= hour < 15:
            self._add(scores, "睡午觉", 0.26)
            self._add(scores, "放松", 0.08)
        if 7 <= hour < 10 or 17 <= hour < 20:
            self._add(scores, "通勤", 0.20)
        if 9 <= hour < 12 or 14 <= hour < 18:
            self._add(scores, "专注", 0.14)
            self._add(scores, "阅读", 0.03)
            self._add(scores, "图书馆", 0.04 if library_hint else 0.015)
        if 19 <= hour < 23:
            self._add(scores, "放松", 0.12)
            self._add(scores, "游戏", 0.10)

        # 实时规则可以软融合 Top-3；地点始终只加分，不做硬判断。
        for candidate_place, candidate_weight in place_evidence:
            self._apply_place_signal(scores, candidate_place, candidate_weight)

        # 速度桶是 mobility 证据，不直接等同于身体运动。
        if mobility_available:
            if mobility == "高速":
                self._add(scores, "通勤", 0.16 + 0.22 * transit_evidence)
                if exercise_evidence >= 0.65 and exercise_evidence > transit_evidence + 0.15:
                    self._add(scores, "跑步", 0.16)
                    self._add(scores, "健身", 0.06)
                else:
                    self._sub(scores, "跑步", 0.08)
            elif mobility == "中速":
                if exercise_evidence >= 0.45 and exercise_evidence >= transit_evidence:
                    self._add(scores, "跑步", 0.20)
                    self._add(scores, "健身", 0.14)
                if transit_evidence >= 0.30:
                    self._add(scores, "通勤", 0.12 + 0.14 * transit_evidence)
                elif exercise_evidence < 0.45:
                    self._add(scores, "通勤", 0.06)
            elif mobility == "慢速":
                self._add(scores, "通勤", 0.12)
                self._add(scores, "宠物陪伴", 0.08)
                self._add(scores, "放松", 0.06)
            elif mobility == "静止":
                for scene in ["专注", "阅读", "深睡眠", "睡午觉", "冥想", "游戏"]:
                    self._add(scores, scene, 0.07)
                if library_hint:
                    self._add(scores, "图书馆", 0.04)

        if steps >= 1200:
            self._add(scores, "跑步", 0.18 if exercise_evidence >= transit_evidence else 0.08)
        elif steps >= 500:
            if transit_evidence >= 0.45:
                self._add(scores, "通勤", 0.08)
            self._add(scores, "健身", 0.08)

        # 心率不能作为运动开始前的必要条件，所以只加分，不强扣分。
        if hr_available:
            if hr == "高":
                self._add(scores, "跑步", 0.24 * hr_w)
                self._add(scores, "健身", 0.20 * hr_w)
            elif hr == "波动":
                self._add(scores, "减压", 0.18 * hr_w)
                self._add(scores, "深夜EMO", 0.12 * hr_w)
                self._add(scores, "跑步", 0.10 * hr_w)
            elif hr == "稍高":
                self._add(scores, "健身", 0.10 * hr_w)
                self._add(scores, "减压", 0.10 * hr_w)
            elif hr == "静息":
                for scene in ["专注", "阅读", "深睡眠", "睡午觉", "冥想", "放松"]:
                    self._add(scores, scene, 0.06)
                if library_hint:
                    self._add(scores, "图书馆", 0.04)

        if workout >= 20:
            self._add(scores, "健身", 0.12)
            self._add(scores, "跑步", 0.10)
            self._add(scores, "瑜伽", 0.06)

        # 环境与连接是低权限弱信号。
        if noise == "安静":
            for scene in ["阅读", "专注", "深睡眠", "冥想", "婴儿安睡"]:
                self._add(scores, scene, 0.06)
            self._add(scores, "图书馆", 0.04 if library_hint else 0.015)
        elif noise == "嘈杂":
            self._add(scores, "通勤", 0.06)
            self._add(scores, "健身", 0.06)

        if light == "暗光":
            self._add(scores, "深睡眠", 0.10)
            self._add(scores, "睡午觉", 0.08)
            self._add(scores, "深夜EMO", 0.08)
            self._add(scores, "冥想", 0.06)
        elif light == "明亮":
            self._add(scores, "专注", 0.05)
            self._add(scores, "图书馆", 0.035 if library_hint else 0.01)

        if bluetooth == "车载蓝牙":
            self._add(scores, "通勤", 0.30)
        elif bluetooth == "家用音响":
            self._add(scores, "放松", 0.10)
            self._add(scores, "深睡眠", 0.08)
            self._add(scores, "婴儿安睡", 0.08)
        elif bluetooth == "耳机":
            for scene in ["通勤", "跑步", "健身", "专注", "深夜EMO"]:
                self._add(scores, scene, 0.04)

        if network in {"蜂窝数据", "蜂窝数据（弱）"}:
            self._add(scores, "通勤", 0.05)
        elif network in {"飞行模式", "无网络"}:
            self._add(scores, "深睡眠", 0.05)
            self._add(scores, "专注", 0.04)

        # 高权限/高稀疏信号，有则用，没有则完全不依赖。
        if calendar:
            if any(k in calendar for k in ["会议", "提交", "截止", "考试", "复习"]):
                self._add(scores, "专注", 0.20)
                self._add(scores, "减压", 0.08)
            if "瑜伽" in calendar:
                self._add(scores, "瑜伽", 0.24)
            if any(k in calendar for k in ["跑步", "训练"]):
                self._add(scores, "跑步", 0.22)
            if any(k in calendar for k in ["宝宝", "哄睡"]):
                self._add(scores, "婴儿安睡", 0.24)
            if any(k in calendar for k in ["胎教", "产检"]):
                self._add(scores, "胎教", 0.24)
            if "经期" in calendar:
                self._add(scores, "经期舒缓", 0.24)

        if app:
            app_rules = [
                ("游戏", "游戏", 0.28),
                ("电子书", "阅读", 0.24),
                ("长阅读", "阅读", 0.22),
                ("办公", "专注", 0.22),
                ("番茄钟", "专注", 0.22),
                ("运动", "跑步", 0.18),
                ("健身", "健身", 0.20),
                ("瑜伽", "瑜伽", 0.24),
                ("冥想", "冥想", 0.24),
                ("呼吸", "减压", 0.18),
                ("白噪音", "婴儿安睡", 0.20),
                ("睡眠", "深睡眠", 0.18),
                ("社交", "深夜EMO", 0.20),
                ("宠物", "宠物陪伴", 0.22),
                ("孕期", "胎教", 0.24),
                ("经期", "经期舒缓", 0.24),
                ("导航", "通勤", 0.20),
            ]
            for keyword, scene, amount in app_rules:
                if keyword in app:
                    self._add(scores, scene, amount)

        # 人群标签只作为弱先验。
        if user_tag == "母婴用户":
            self._add(scores, "婴儿安睡", 0.07)
            self._add(scores, "深睡眠", 0.06)
        if user_tag == "养宠物":
            self._add(scores, "宠物陪伴", 0.08)
        if user_tag == "学生":
            self._add(scores, "图书馆", 0.08 if library_hint else 0.03)
            self._add(scores, "专注", 0.11)
            self._add(scores, "阅读", 0.07)
        if gender == "女性" or user_tag == "女性":
            self._add(scores, "经期舒缓", 0.05)
            self._add(scores, "胎教", 0.04)

        if sleep_quality == "差":
            self._add(scores, "睡午觉", 0.08)
            self._add(scores, "减压", 0.06)

        # 缺少高权限信号时，使用稳定的组合特征做细分。
        at_home_like = place in {"住宅区", "酒店"} or place_w == 0
        quietish = noise in {"", "安静", "普通"}
        staticish = mobility in {"", "任意", "静止"} or not mobility_available
        low_light = light in {"暗光", "室内柔光", ""}
        calm_hr = hr in {"", "任意", "静息"} or not hr_available
        elevated_hr = hr in {"稍高", "波动", "高"}

        if at_home_like and staticish and quietish and 20 <= hour < 24 and bluetooth in {"耳机", "任意", ""}:
            self._add(scores, "游戏", 0.20)
            self._add(scores, "阅读", 0.10)
            self._add(scores, "放松", 0.10)

        if staticish and quietish and calm_hr and (10 <= hour < 12 or 15 <= hour < 18 or 21 <= hour < 23):
            self._add(scores, "阅读", 0.16)

        if staticish and quietish and at_home_like and (19 <= hour < 23) and low_light:
            self._add(scores, "放松", 0.14)

        if staticish and quietish and low_light and (6 <= hour < 8 or 21 <= hour < 23):
            self._add(scores, "冥想", 0.16)

        if staticish and elevated_hr and (12 <= hour < 14 or 18 <= hour < 23):
            self._add(scores, "减压", 0.24)

        if staticish and elevated_hr and at_home_like and (23 <= hour or hour < 3):
            self._add(scores, "深夜EMO", 0.32)
            self._sub(scores, "深睡眠", 0.18)
            self._sub(scores, "婴儿安睡", 0.10)

        if at_home_like and staticish and quietish and (20 <= hour < 23) and bluetooth == "耳机" and elevated_hr:
            self._add(scores, "游戏", 0.16)

        if staticish and at_home_like and low_light and (20 <= hour or hour < 2):
            if (user_tag in {"女性", "任意"} or gender == "女性") and elevated_hr:
                self._add(scores, "经期舒缓", 0.16)
            if user_tag == "母婴用户" and calm_hr and (12 <= hour < 15 or 20 <= hour < 23):
                self._add(scores, "婴儿安睡", 0.12)

        if quietish and calm_hr and workout >= 15 and mobility in {"静止", "慢速", "任意", ""} and (6 <= hour < 9 or 19 <= hour < 22):
            self._add(scores, "瑜伽", 0.22)

        if quietish and mobility in {"静止", "慢速", "任意", ""} and place in {"住宅区", "公园", "户外", "商场", "运动场所", ""} and (6 <= hour < 9 or 19 <= hour < 22):
            self._add(scores, "瑜伽", 0.10)

        if initial_need:
            if "学习" in initial_need or "工作" in initial_need or "专注" in initial_need:
                self._add(scores, "专注", 0.10)
                self._add(scores, "图书馆", 0.07 if library_hint else 0.03)
                self._add(scores, "阅读", 0.06)
            if "情绪" in initial_need or "舒缓" in initial_need:
                self._add(scores, "减压", 0.08)
                if elevated_hr:
                    self._add(scores, "经期舒缓", 0.08)
                self._add(scores, "放松", 0.06)
            if "放松" in initial_need or "减压" in initial_need:
                self._add(scores, "放松", 0.08)
                self._add(scores, "减压", 0.08)
                self._add(scores, "冥想", 0.04)
            if "睡眠" in initial_need or "午休" in initial_need or "睡眠照护" in initial_need:
                if 12 <= hour < 15:
                    self._add(scores, "睡午觉", 0.12)
                if 20 <= hour or hour < 6:
                    self._add(scores, "深睡眠", 0.12)
                self._add(scores, "放松", 0.04)
            if "家庭" in initial_need or "照护" in initial_need or "睡眠照护" in initial_need:
                if (12 <= hour < 15 or 20 <= hour < 23) and calm_hr:
                    self._add(scores, "婴儿安睡", 0.10)
                self._add(scores, "深睡眠", 0.06)
            if "运动" in initial_need or "健身" in initial_need:
                self._add(scores, "健身", 0.10)
                self._add(scores, "跑步", 0.08)
                self._add(scores, "瑜伽", 0.06)
            if "通勤" in initial_need or "出行" in initial_need:
                self._add(scores, "通勤", 0.12)
            if "冥想" in initial_need or "正念" in initial_need:
                self._add(scores, "冥想", 0.12)
                self._add(scores, "减压", 0.06)
            if "游戏" in initial_need or "娱乐" in initial_need:
                self._add(scores, "游戏", 0.12)
            if "阅读" in initial_need:
                self._add(scores, "阅读", 0.12)
                self._add(scores, "专注", 0.04)
            if "陪伴" in initial_need:
                if place in {"住宅区", "公园", "户外"} or mobility == "慢速":
                    self._add(scores, "宠物陪伴", 0.10)
                self._add(scores, "放松", 0.06)

        if hr_available and hr in {"稍高", "波动", "高"}:
            for sleep_scene in ["深睡眠", "睡午觉", "婴儿安睡"]:
                self._sub(scores, sleep_scene, 0.08)

        if not (12 <= hour < 15):
            self._sub(scores, "睡午觉", 0.08)

        # 地点强烈指向非学习空间时，只做轻微降权，不禁止图书馆。
        if conflicting_place_hint and not library_hint:
            self._scale(scores, "图书馆", 0.82)

        return scores

    def get_top_k(self, context: Dict[str, Any], k: int = 3):
        scores = self.score_all(context)
        return sorted(scores.items(), key=lambda x: x[1], reverse=True)[:k]
