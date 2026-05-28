"""Stable long-term history booster.

This module turns past listen rows into a smoothed scene prior. It is deliberately
conservative: low-confidence place values are dropped, sparse buckets back off to
coarser buckets, and recent/disruption samples can be down-weighted.
"""

from collections import Counter, defaultdict
from typing import Any, Dict, Iterable, List, Tuple

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


class StableHistoryBooster:
    """Smoothed, hierarchical user-history scorer.

    The scorer builds several bucket levels from historical listen rows:

    1. user + weekday + time_slot + activity + geo cluster
    2. user + weekday + time_slot + activity + place
    3. user + weekday + time_slot + activity
    4. user + weekday + time_slot
    5. user + time_slot
    6. user global
    7. profile/time-slot cohort
    8. global

    Each level is shrinkage-smoothed by evidence count, so a tiny bucket cannot
    dominate the decision.
    """

    def __init__(
        self,
        min_place_confidence: float = 0.55,
        support_k: float = 6.0,
        disruption_weight: float = 0.35,
    ):
        self.min_place_confidence = min_place_confidence
        self.support_k = support_k
        self.disruption_weight = disruption_weight
        self.tables = defaultdict(Counter)
        self.global_prior = Counter()

    def _place_token(self, row: Dict[str, Any]) -> str:
        place = _s(row.get("place_type")) or "任意"
        available = _s(row.get("place_type_available"))
        quality = _s(row.get("place_type_quality"))
        confidence = _f(row.get("place_type_confidence"), 0.65)
        if available == "0" or quality == "noisy_mapping" or confidence < self.min_place_confidence:
            return "任意"
        return place

    def _geo_token(self, row: Dict[str, Any]) -> str:
        status = _s(row.get("geo_cluster_status"))
        cluster_id = _s(row.get("geo_cluster_id"))
        if not cluster_id or status in {"", "unavailable", "invalid", "low_accuracy"}:
            return "任意"
        return cluster_id

    def _activity_token(self, row: Dict[str, Any]) -> str:
        available = _s(row.get("activity_state_available"))
        activity = _s(row.get("activity_state")) or "任意"
        if available == "0":
            return "任意"
        return activity

    def _time_slot(self, row: Dict[str, Any]) -> str:
        return _s(row.get("time_slot")) or _s(row.get("hour")) or "任意"

    def _weekday(self, row: Dict[str, Any]) -> str:
        return _s(row.get("weekday")) or "任意"

    def _profile(self, row: Dict[str, Any]) -> str:
        return _s(row.get("user_tag")) or _s(row.get("profile_tag")) or "任意"

    def _keys(self, row: Dict[str, Any]) -> List[Tuple[Any, ...]]:
        user = _s(row.get("user_id")) or "anonymous"
        weekday = self._weekday(row)
        slot = self._time_slot(row)
        activity = self._activity_token(row)
        place = self._place_token(row)
        geo = self._geo_token(row)
        profile = self._profile(row)
        return [
            ("u_w_t_a_g", user, weekday, slot, activity, geo),
            ("u_w_t_a_p", user, weekday, slot, activity, place),
            ("u_w_t_a", user, weekday, slot, activity),
            ("u_w_t", user, weekday, slot),
            ("u_t", user, slot),
            ("u", user),
            ("profile_t", profile, slot),
            ("global",),
        ]

    def fit(self, rows: Iterable[Dict[str, Any]]):
        for row in rows:
            if row.get("event_type") and row.get("event_type") != "listen":
                continue
            scene = row.get("ground_truth", "")
            if scene not in SCENE_NAMES:
                continue
            weight = 1.0
            if _s(row.get("is_disruption_week")) == "1" or _s(row.get("is_disruption_window")) == "1":
                weight *= self.disruption_weight
            for key in self._keys(row):
                self.tables[key][scene] += weight
            self.global_prior[scene] += weight
        return self

    def _level_scores(self, key: Tuple[Any, ...]) -> Dict[str, float]:
        counter = self.tables.get(key, Counter())
        total = sum(counter.values())
        if total <= 0:
            return {scene: 0.0 for scene in SCENE_NAMES}

        global_total = sum(self.global_prior.values()) or 1.0
        support = total / (total + self.support_k)
        alpha = 0.25
        denom = total + alpha * len(SCENE_NAMES)
        scores = {}
        for scene in SCENE_NAMES:
            prior = self.global_prior.get(scene, 0.0) / global_total
            ratio = (counter.get(scene, 0.0) + alpha * prior) / denom
            scores[scene] = support * ratio
        return scores

    def score_all(self, row: Dict[str, Any]) -> Dict[str, float]:
        level_weights = [0.24, 0.22, 0.18, 0.13, 0.09, 0.07, 0.04, 0.03]
        scores = {scene: 0.0 for scene in SCENE_NAMES}
        used_weight = 0.0
        for weight, key in zip(level_weights, self._keys(row)):
            level = self._level_scores(key)
            if max(level.values()) <= 0:
                continue
            used_weight += weight
            for scene in SCENE_NAMES:
                scores[scene] += weight * level[scene]

        if used_weight <= 0:
            return scores
        return {scene: scores[scene] / used_weight for scene in SCENE_NAMES}

    def boost(self, base_scores: Dict[str, float], row: Dict[str, Any], amount: float = 1.2) -> Dict[str, float]:
        history = self.score_all(row)
        return {scene: base_scores.get(scene, 0.0) + amount * history.get(scene, 0.0) for scene in SCENE_NAMES}

