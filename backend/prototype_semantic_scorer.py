"""多原型 embedding 语义通道。"""

import os
from typing import Dict, List, Tuple

import numpy as np

from qwen3_semantic_scorer import QWEN3_INSTRUCTION_VARIANTS
from scene_prototypes import SCENE_PROTOTYPES
from scenes import SCENE_NAMES
from semantic_scorer import SemanticScorer


class PrototypeSemanticScorer(SemanticScorer):
    def __init__(
        self,
        model_name: str = "paraphrase-multilingual-MiniLM-L12-v2",
        cache_path: str = "data/prototype_scene_vectors.npy",
        use_cache: bool = True,
        query_instruction: str = None,
        document_instruction: str = None,
        aggregate: str = "max_top2",
        clean_sparse_query: bool = True,
        local_files_only: bool = False,
    ):
        self.prototype_index: List[Tuple[str, str]] = []
        for scene in SCENE_NAMES:
            for text in SCENE_PROTOTYPES[scene]:
                self.prototype_index.append((scene, text))
        self.aggregate = aggregate
        self.clean_sparse_query = clean_sparse_query
        super().__init__(
            model_name=model_name,
            cache_path=cache_path,
            use_cache=use_cache,
            query_instruction=query_instruction,
            document_instruction=document_instruction,
            local_files_only=local_files_only,
        )

    def _build_scene_vectors(self) -> np.ndarray:
        texts = [text for _, text in self.prototype_index]
        return self._encode_documents(texts, show_progress_bar=True)

    def _context_to_text(self, context: Dict) -> str:
        if not self.clean_sparse_query:
            return super()._context_to_text(context)

        parts = []
        weekday = context.get("weekday")
        time_slot = context.get("time_slot")
        hour = context.get("hour")
        if weekday or time_slot or hour not in (None, ""):
            parts.append(f"时间：{weekday or ''} {time_slot or ''} {hour}点")

        def usable(value):
            text = "" if value is None else str(value)
            return bool(text) and text not in {"任意", "nan", "None"}

        place = context.get("place_type")
        place_conf = float(context.get("place_type_confidence") or 0.0)
        if usable(place) and place_conf >= 0.3:
            parts.append(f"地点类型：{place}，地点置信度{place_conf:.2f}")

        activity = context.get("activity_state")
        if usable(activity):
            parts.append(f"运动状态：{activity}")

        hr = context.get("heart_rate_zone")
        if usable(hr):
            hr_quality = context.get("heart_rate_quality")
            suffix = f"，质量={hr_quality}" if usable(hr_quality) else ""
            parts.append(f"心率：{hr}{suffix}")

        steps = context.get("steps_last_10min")
        if usable(steps):
            parts.append(f"最近10分钟步数：{steps}")

        workout = context.get("recent_workout_minutes_24h")
        if usable(workout):
            parts.append(f"过去24小时运动分钟：{workout}")

        for label, key in [
            ("天气", "weather"),
            ("光线", "light_class"),
            ("噪音", "noise_class"),
            ("蓝牙", "bluetooth"),
            ("网络", "network"),
            ("睡眠质量", "sleep_quality"),
            ("用户标签", "user_tag"),
            ("初始需求", "initial_need"),
        ]:
            value = context.get(key)
            if usable(value):
                parts.append(f"{label}：{value}")

        calendar = context.get("calendar_title")
        if usable(calendar):
            parts.append(f"日历：{calendar}")
        app = context.get("app_event")
        if usable(app):
            parts.append(f"后续App行为：{app}")

        if context.get("signal_availability_profile"):
            parts.append(f"信号完整度：{context['signal_availability_profile']}")
        return "；".join(parts) + "。"

    def score_all(self, context: Dict) -> Dict[str, float]:
        context_text = self._context_to_text(context)
        context_vector = self._encode_queries([context_text])[0]
        similarities = np.dot(self.scene_vectors, context_vector)
        scores = (similarities + 1) / 2

        by_scene = {scene: [] for scene in SCENE_NAMES}
        for i, (scene, _) in enumerate(self.prototype_index):
            by_scene[scene].append(float(scores[i]))

        result = {}
        for scene, values in by_scene.items():
            values = sorted(values, reverse=True)
            if self.aggregate == "max":
                result[scene] = values[0]
            elif self.aggregate == "mean":
                result[scene] = sum(values) / len(values)
            elif self.aggregate == "softmax":
                arr = np.array(values, dtype=float)
                arr = (arr - arr.max()) * 25.0
                weights = np.exp(arr)
                weights = weights / weights.sum()
                result[scene] = float(np.dot(np.array(values), weights))
            else:
                top2 = values[:2]
                result[scene] = 0.70 * top2[0] + 0.30 * (sum(top2) / len(top2))
        return result


class Qwen3PrototypeSemanticScorer(PrototypeSemanticScorer):
    def __init__(
        self,
        model_name: str = "Qwen/Qwen3-Embedding-0.6B",
        cache_path: str = "data/qwen3_prototype_scene_vectors.npy",
        use_cache: bool = True,
        aggregate: str = "max_top2",
        instruction_variant: str = "short",
        local_files_only: bool = True,
    ):
        query_instruction = QWEN3_INSTRUCTION_VARIANTS.get(instruction_variant, instruction_variant)
        super().__init__(
            model_name=model_name,
            cache_path=cache_path,
            use_cache=use_cache,
            query_instruction=query_instruction,
            document_instruction=None,
            aggregate=aggregate,
            local_files_only=local_files_only,
        )
