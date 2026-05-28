"""FastAPI POC service for music scene recommendation.

Run:
    uvicorn poc_api:app --host 0.0.0.0 --port 8000
"""

import os
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from history_booster import StableHistoryBooster
from poc_storage import POCStorage
from preference_scorer import FeedbackEvent, PreferenceScorer
from rule_scorer import RuleScorer
from scenes import SCENE_NAME_TO_ID, SCENES, SCENE_NAMES


MODEL_VERSION = "poc-2026-05-26"


class ContextPayload(BaseModel):
    timestamp: Optional[str] = Field(None, description="ISO8601 timestamp from client")
    timezone: Optional[str] = Field(None, description="Client timezone, e.g. Asia/Shanghai")
    date: Optional[str] = None
    hour: Optional[int] = Field(None, ge=0, le=23)
    weekday: Optional[Any] = None
    time_slot: Optional[str] = None

    place_type: Optional[str] = None
    place_type_available: Optional[int] = None
    place_type_confidence: Optional[float] = Field(None, ge=0.0, le=1.0)
    place_type_quality: Optional[str] = None

    activity_state: Optional[str] = None
    activity_state_available: Optional[int] = None
    heart_rate_zone: Optional[str] = None
    heart_rate_available: Optional[int] = None
    heart_rate_quality: Optional[str] = None
    steps_last_10min: Optional[int] = None
    recent_workout_minutes_24h: Optional[int] = None
    sleep_quality: Optional[str] = None

    weather: Optional[str] = None
    light_class: Optional[str] = None
    noise_class: Optional[str] = None
    noise_available: Optional[int] = None
    bluetooth: Optional[str] = None
    network: Optional[str] = None

    calendar_title: Optional[str] = None
    calendar_available: Optional[int] = None
    app_event: Optional[str] = None
    app_event_available: Optional[int] = None

    user_tag: Optional[str] = None
    gender: Optional[str] = None
    initial_need: Optional[str] = None
    initial_needs: Optional[List[str]] = None

    class Config:
        extra = "allow"


class RecommendRequest(BaseModel):
    user_id: str = Field(..., description="Stable anonymous user id from the mini app")
    request_id: Optional[str] = Field(None, description="Client request id; generated if missing")
    top_k: int = Field(3, ge=1, le=10)
    context: ContextPayload


class FeedbackRequest(BaseModel):
    user_id: str
    request_id: Optional[str] = None
    recommended_scene: str
    accepted_scene: Optional[str] = None
    event_type: str = Field("listen", description="impression/listen/like/dislike/correction/skip")
    dwell_time_sec: int = Field(0, ge=0)
    played_ratio_pct: Optional[float] = Field(None, ge=0.0, le=1.0)
    next_action: Optional[str] = None
    context: Optional[ContextPayload] = None


def _normalize(scores: Dict[str, float]) -> Dict[str, float]:
    values = list(scores.values())
    if not values:
        return {scene: 0.5 for scene in SCENE_NAMES}
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return {scene: 0.5 for scene in scores}
    return {scene: (score - lo) / (hi - lo) for scene, score in scores.items()}


def _as_context_dict(context: ContextPayload) -> Dict[str, Any]:
    if hasattr(context, "model_dump"):
        data = context.model_dump(exclude_none=True)
    else:
        data = context.dict(exclude_none=True)
    data = dict(data)

    ts = data.get("timestamp")
    if ts and ("hour" not in data or "date" not in data or "weekday" not in data):
        try:
            dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            data.setdefault("hour", dt.hour)
            data.setdefault("date", dt.date().isoformat())
            data.setdefault("weekday", dt.weekday())
        except ValueError:
            pass

    data.setdefault("hour", 12)
    data.setdefault("time_slot", _time_slot_from_hour(int(data["hour"])))
    data.setdefault("place_type", "任意")
    data.setdefault("activity_state", "任意")
    data.setdefault("heart_rate_zone", "任意")
    data.setdefault("noise_class", "普通")
    data.setdefault("bluetooth", "任意")
    data.setdefault("network", "wifi")
    if not data.get("initial_need") and isinstance(data.get("initial_needs"), list):
        data["initial_need"] = "、".join(str(item) for item in data["initial_needs"] if item)
    return data


def _time_slot_from_hour(hour: int) -> str:
    hour = int(hour) % 24
    if 5 <= hour < 11:
        return "早晨"
    if 11 <= hour < 14:
        return "中午"
    if 14 <= hour < 17:
        return "下午"
    if 17 <= hour < 20:
        return "傍晚"
    if 20 <= hour < 23:
        return "夜晚"
    return "深夜"


def _availability_notes(context: Dict[str, Any]) -> List[str]:
    notes = []
    if str(context.get("place_type_available", "")) == "0":
        notes.append("place_type unavailable; downgraded to weak/no place evidence")
    elif context.get("place_type_quality") == "noisy_mapping" or float(context.get("place_type_confidence") or 0.65) < 0.55:
        notes.append("place_type low confidence; used as weak evidence only")
    if str(context.get("activity_state_available", "")) == "0":
        notes.append("activity_state unavailable; no motion penalty applied")
    if str(context.get("heart_rate_available", "")) == "0":
        notes.append("heart_rate unavailable; no heart-rate penalty applied")
    if not context.get("calendar_title"):
        notes.append("calendar absent; treated as missing, not negative")
    if not context.get("app_event"):
        notes.append("app_event absent; treated as missing, not negative")
    return notes


class RecommenderService:
    def __init__(self):
        self.rule = RuleScorer()
        self.preference = PreferenceScorer(
            start_worker=False,
            persistence_path=os.getenv("POC_PREFERENCE_PATH", "data/poc_preference.json"),
        )
        self.storage = POCStorage(os.getenv("POC_SQLITE_PATH", "data/poc_music_scene.db"))
        self.history = StableHistoryBooster(support_k=2.0)
        self.history.fit(self.storage.load_history_rows())
        self.semantic = None
        self.semantic_mode = os.getenv("POC_SEMANTIC", "none")

    def _semantic_scores(self, context: Dict[str, Any]) -> Dict[str, float]:
        if self.semantic_mode in {"", "none", "off"}:
            return {scene: 0.5 for scene in SCENE_NAMES}
        if self.semantic is None:
            if self.semantic_mode == "embedding-proto":
                from prototype_semantic_scorer import PrototypeSemanticScorer

                self.semantic = PrototypeSemanticScorer(
                    cache_path="data/minilm_prototype_scene_vectors.npy",
                    aggregate="max",
                )
            else:
                raise HTTPException(status_code=500, detail=f"Unsupported POC_SEMANTIC={self.semantic_mode}")
        return self.semantic.score_all(context)

    def recommend(self, request: RecommendRequest) -> Dict[str, Any]:
        request_id = request.request_id or str(uuid.uuid4())
        context = _as_context_dict(request.context)
        context["user_id"] = request.user_id

        rule_scores = self.rule.score_all(context)
        preference_scores = self.preference.score_all(context)
        history_scores = self.history.score_all(context)
        semantic_scores = self._semantic_scores(context)

        weights = {
            "rule": float(os.getenv("POC_RULE_WEIGHT", "0.58")),
            "semantic": float(os.getenv("POC_SEMANTIC_WEIGHT", "0.12" if self.semantic_mode != "none" else "0.0")),
            "preference": float(os.getenv("POC_PREFERENCE_WEIGHT", "0.18")),
            "history": float(os.getenv("POC_HISTORY_WEIGHT", "0.24")),
        }
        total = sum(weights.values()) or 1.0
        normalized = {
            "rule": _normalize(rule_scores),
            "semantic": _normalize(semantic_scores),
            "preference": _normalize(preference_scores),
            "history": _normalize(history_scores),
        }
        final_scores = {
            scene: (
                weights["rule"] * normalized["rule"].get(scene, 0.5)
                + weights["semantic"] * normalized["semantic"].get(scene, 0.5)
                + weights["preference"] * normalized["preference"].get(scene, 0.5)
                + weights["history"] * normalized["history"].get(scene, 0.5)
            )
            / total
            for scene in SCENE_NAMES
        }
        ranked = sorted(final_scores.items(), key=lambda x: x[1], reverse=True)[: request.top_k]
        recommendations = []
        for rank, (scene, score) in enumerate(ranked, start=1):
            recommendations.append(
                {
                    "rank": rank,
                    "scene_id": SCENE_NAME_TO_ID[scene],
                    "scene": scene,
                    "score": round(float(score), 4),
                    "components": {
                        "rule": round(float(normalized["rule"].get(scene, 0.5)), 4),
                        "semantic": round(float(normalized["semantic"].get(scene, 0.5)), 4),
                        "preference": round(float(normalized["preference"].get(scene, 0.5)), 4),
                        "history": round(float(normalized["history"].get(scene, 0.5)), 4),
                    },
                }
            )

        result = {
            "request_id": request_id,
            "user_id": request.user_id,
            "model_version": MODEL_VERSION,
            "semantic_mode": self.semantic_mode,
            "weights": weights,
            "recommendations": recommendations,
            "availability_notes": _availability_notes(context),
        }
        self.storage.save_recommendation(request_id, request.user_id, context, result)
        return result

    def feedback(self, request: FeedbackRequest) -> Dict[str, Any]:
        accepted_scene = request.accepted_scene or ("" if request.event_type == "impression" else request.recommended_scene)
        if request.recommended_scene not in SCENE_NAMES:
            raise HTTPException(status_code=400, detail="recommended_scene is not one of the 18 supported scenes")
        if accepted_scene and accepted_scene not in SCENE_NAMES:
            raise HTTPException(status_code=400, detail="accepted_scene is not one of the 18 supported scenes")

        context = _as_context_dict(request.context) if request.context else None
        if context is None and request.request_id:
            context = self.storage.latest_context_for_request(request.request_id, request.user_id)
        context = context or {"hour": 12, "place_type": "任意", "activity_state": "任意"}
        context["user_id"] = request.user_id

        if request.event_type == "impression":
            feedback_payload = request.dict(exclude_none=True)
            feedback_payload["accepted_scene"] = accepted_scene
            feedback_payload["reward"] = 0.0
            self.storage.save_feedback(feedback_payload, context)
            return {
                "ok": True,
                "user_id": request.user_id,
                "request_id": request.request_id,
                "accepted_scene": accepted_scene,
                "reward": 0.0,
                "learned": False,
            }

        next_action = request.next_action or request.event_type
        learning_scene = accepted_scene or request.recommended_scene
        corrected = learning_scene != request.recommended_scene or request.event_type == "correction"
        reward = self.preference.infer_reward(
            request.recommended_scene,
            learning_scene,
            request.dwell_time_sec,
            next_action,
            corrected,
        )
        if request.event_type == "like":
            reward = max(reward, 0.95)
        elif request.event_type in {"dislike", "skip"}:
            reward = min(reward, -0.65)

        event = FeedbackEvent(
            user_id=request.user_id,
            recommended_scene=request.recommended_scene,
            accepted_scene=learning_scene,
            context_bucket=self.preference.context_to_bucket(context),
            reward=reward,
            dwell_time_sec=request.dwell_time_sec,
            consistency=float(context.get("multiday_consistency", 0.5)),
        )
        self.preference.update_preference_from_feedback(event)
        self.preference._save()
        self.history.fit([{**context, "ground_truth": learning_scene, "event_type": "listen"}])

        feedback_payload = request.dict(exclude_none=True)
        feedback_payload["accepted_scene"] = learning_scene
        feedback_payload["reward"] = reward
        self.storage.save_feedback(feedback_payload, context)
        return {
            "ok": True,
            "user_id": request.user_id,
            "request_id": request.request_id,
            "accepted_scene": learning_scene,
            "reward": round(float(reward), 4),
            "learned": True,
        }


service = RecommenderService()
app = FastAPI(title="Music Scene Recommendation POC API", version=MODEL_VERSION)


@app.get("/health")
def health():
    return {"ok": True, "model_version": MODEL_VERSION, "semantic_mode": service.semantic_mode}


@app.get("/v1/scenes")
def scenes():
    return {"scenes": SCENES}


@app.post("/v1/recommend")
def recommend(request: RecommendRequest):
    return service.recommend(request)


@app.post("/v1/feedback")
def feedback(request: FeedbackRequest):
    return service.feedback(request)


@app.get("/v1/users/{user_id}/history")
def user_history(user_id: str):
    return service.storage.feedback_summary(user_id)
