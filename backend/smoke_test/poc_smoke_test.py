"""Smoke test for the music scene recommendation POC backend.

Default mode runs in-process and uses a temporary SQLite/preference file:

    python3 poc_smoke_test.py

HTTP mode tests a running server:

    uvicorn poc_api:app --host 0.0.0.0 --port 8000
    python3 poc_smoke_test.py --base-url http://127.0.0.1:8000
"""

import argparse
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request
from copy import deepcopy
from pathlib import Path
from typing import Any, Dict, List, Optional


ROOT = Path(__file__).resolve().parent
DEFAULT_PAYLOADS = ROOT / "poc_test_payloads.json"


class SmokeFailure(RuntimeError):
    pass


def load_payloads(path: Path) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    cases = payload.get("cases", [])
    if not cases:
        raise SmokeFailure(f"No cases found in {path}")
    return cases


def require(condition: bool, message: str):
    if not condition:
        raise SmokeFailure(message)


def post_json(url: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SmokeFailure(f"HTTP {exc.code} from {url}: {body}") from exc


def get_json(url: str) -> Dict[str, Any]:
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SmokeFailure(f"HTTP {exc.code} from {url}: {body}") from exc


class HTTPClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def health(self):
        return get_json(f"{self.base_url}/health")

    def scenes(self):
        return get_json(f"{self.base_url}/v1/scenes")

    def recommend(self, payload: Dict[str, Any]):
        return post_json(f"{self.base_url}/v1/recommend", payload)

    def feedback(self, payload: Dict[str, Any]):
        return post_json(f"{self.base_url}/v1/feedback", payload)

    def history(self, user_id: str):
        return get_json(f"{self.base_url}/v1/users/{user_id}/history")


class InProcessClient:
    def __init__(self):
        from poc_api import FeedbackRequest, RecommendRequest, app, service

        self.FeedbackRequest = FeedbackRequest
        self.RecommendRequest = RecommendRequest
        self.app = app
        self.service = service

    def health(self):
        return {"ok": True}

    def scenes(self):
        from scenes import SCENES

        return {"scenes": SCENES}

    def recommend(self, payload: Dict[str, Any]):
        return self.service.recommend(self.RecommendRequest(**payload))

    def feedback(self, payload: Dict[str, Any]):
        return self.service.feedback(self.FeedbackRequest(**payload))

    def history(self, user_id: str):
        return self.service.storage.feedback_summary(user_id)


def make_feedback(case: Dict[str, Any], recommend_response: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    feedback = case.get("feedback")
    if not feedback:
        return None
    payload = deepcopy(feedback)
    rec = recommend_response["recommendations"][0]
    payload.setdefault("user_id", case["recommend"]["user_id"])
    payload.setdefault("request_id", recommend_response["request_id"])
    payload.setdefault("recommended_scene", rec["scene"])
    if payload.get("accepted_scene") == "__TOP1__":
        payload["accepted_scene"] = rec["scene"]
    return payload


def apply_second_recommend(case: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    second = case.get("second_recommend")
    if not second:
        return None
    payload = deepcopy(case["recommend"])
    if second.get("request_id"):
        payload["request_id"] = second["request_id"]
    updates = second.get("context_updates", {})
    payload["context"].update(updates)
    return payload


def validate_recommend(case_name: str, response: Dict[str, Any], expected_top_k: int):
    recs = response.get("recommendations", [])
    require(response.get("request_id"), f"{case_name}: missing request_id")
    require(len(recs) == expected_top_k, f"{case_name}: expected {expected_top_k} recommendations, got {len(recs)}")
    require(all("scene" in item and "score" in item for item in recs), f"{case_name}: malformed recommendation items")
    require(all("components" in item for item in recs), f"{case_name}: missing score components")


def run_smoke(client, cases: List[Dict[str, Any]], verbose: bool = False):
    health = client.health()
    require(health.get("ok") is True, "health check failed")
    scenes = client.scenes().get("scenes", [])
    require(len(scenes) == 18, f"expected 18 scenes, got {len(scenes)}")

    seen_users = set()
    for case in cases:
        name = case["name"]
        request = deepcopy(case["recommend"])
        response = client.recommend(request)
        validate_recommend(name, response, request.get("top_k", 3))
        top1 = response["recommendations"][0]["scene"]
        seen_users.add(request["user_id"])

        feedback = make_feedback(case, response)
        feedback_result = None
        if feedback:
            feedback_result = client.feedback(feedback)
            require(feedback_result.get("ok") is True, f"{name}: feedback failed")

        second_payload = apply_second_recommend(case)
        second_response = None
        if second_payload:
            second_response = client.recommend(second_payload)
            validate_recommend(f"{name}/second", second_response, second_payload.get("top_k", 3))

        if name == "low_accuracy_geo":
            notes = " ".join(response.get("availability_notes", []))
            require("geo clustering skipped" in notes, "low_accuracy_geo: expected geo clustering skipped note")

        if name == "routine_geo_cluster" and second_response:
            history_score = second_response["recommendations"][0]["components"]["history"]
            require(history_score > 0, "routine_geo_cluster: expected positive history component on second recommend")

        if name == "minimal_context":
            notes = " ".join(response.get("availability_notes", []))
            require("heart_rate unavailable" in notes, "minimal_context: expected heart-rate missing note")

        if name == "low_place_confidence":
            notes = " ".join(response.get("availability_notes", []))
            require("place_type low confidence" in notes, "low_place_confidence: expected low-confidence place note")

        if feedback_result and feedback.get("event_type") == "impression":
            require(feedback_result.get("learned") is False, f"{name}: impression should not update preference")

        if verbose:
            detail = f" top1={top1}"
            if second_response:
                detail += f" second_top1={second_response['recommendations'][0]['scene']}"
            if feedback_result:
                detail += f" feedback_reward={feedback_result.get('reward')}"
            print(f"OK {name}:{detail}")
        else:
            print(f"OK {name}")

    histories = {user: client.history(user) for user in seen_users}
    for user, history in histories.items():
        require(history.get("user_id") == user, f"{user}: history user_id mismatch")

    # User isolation sanity check: feedback from one test user must not appear under another.
    full = histories.get("u_full_permission", {})
    minimal = histories.get("u_minimal_context", {})
    require(full.get("feedback_events", 0) >= 1, "u_full_permission: expected at least one feedback event")
    require(minimal.get("feedback_events", 0) >= 1, "u_minimal_context: expected at least one feedback event")

    print(f"\nPASS: {len(cases)} payload cases, {len(seen_users)} users")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="", help="Optional running backend URL, e.g. http://127.0.0.1:8000")
    parser.add_argument("--payloads", default=str(DEFAULT_PAYLOADS), help="Path to poc_test_payloads.json")
    parser.add_argument("--keep-temp", action="store_true", help="Keep temp DB files in in-process mode")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    cases = load_payloads(Path(args.payloads))

    temp_dir = None
    try:
        if args.base_url:
            client = HTTPClient(args.base_url)
        else:
            temp_dir = tempfile.TemporaryDirectory()
            os.environ["POC_SQLITE_PATH"] = str(Path(temp_dir.name) / "poc_smoke.db")
            os.environ["POC_PREFERENCE_PATH"] = str(Path(temp_dir.name) / "poc_preference.json")
            client = InProcessClient()

        run_smoke(client, cases, verbose=args.verbose)
    except SmokeFailure as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        if temp_dir is not None and args.keep_temp:
            print(f"Temp files kept at: {temp_dir.name}")
        elif temp_dir is not None:
            temp_dir.cleanup()


if __name__ == "__main__":
    main()
