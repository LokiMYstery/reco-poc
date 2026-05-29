#!/usr/bin/env python3
"""Minimal HTTP smoke test for the POC backend.

Usage:
    cd backend
    python3 smoke_backend.py --base-url http://127.0.0.1:8000

The script checks:
    - GET /health
    - GET /v1/scenes
    - POST /v1/recommend
    - POST /v1/feedback
    - GET /v1/users/{user_id}/history
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Tuple


DEFAULT_BASE_URL = "http://127.0.0.1:8000"
DEFAULT_USER_ID = "device-demo:u_full_permission"
DEFAULT_REQUEST_ID = "smoke-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
DEFAULT_TIMEOUT_SECONDS = 5.0


def request_json(base_url: str, method: str, path: str, body: dict[str, Any] | None, timeout: float) -> Tuple[int, dict[str, Any]]:
    url = base_url.rstrip("/") + path
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read().decode("utf-8")
            parsed = json.loads(payload) if payload else {}
            return resp.status, parsed
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {payload}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{method} {path} -> URL error: {exc.reason}") from exc


def ensure(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a smoke test against the POC backend.")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="Backend base URL, e.g. http://127.0.0.1:8000")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="Per-request timeout in seconds")
    parser.add_argument("--user-id", default=DEFAULT_USER_ID, help="Stable anonymous user_id to test")
    parser.add_argument("--request-id", default=DEFAULT_REQUEST_ID, help="Request ID to send in the recommend call")
    parser.add_argument("--top-k", type=int, default=3, help="Number of recommendations to request")
    args = parser.parse_args()

    scene_names = set()

    status, health = request_json(args.base_url, "GET", "/health", None, args.timeout)
    ensure(status == 200, f"/health returned status {status}")
    ensure(health.get("ok") is True, f"/health response missing ok=true: {health}")
    ensure("model_version" in health, f"/health response missing model_version: {health}")
    print(f"OK /health -> {health['model_version']} ({health.get('semantic_mode', 'unknown')})")

    status, scenes = request_json(args.base_url, "GET", "/v1/scenes", None, args.timeout)
    ensure(status == 200, f"/v1/scenes returned status {status}")
    scene_list = scenes.get("scenes")
    ensure(isinstance(scene_list, list), f"/v1/scenes response missing scenes list: {scenes}")
    ensure(len(scene_list) == 18, f"expected 18 scenes, got {len(scene_list)}")
    for scene in scene_list:
        if isinstance(scene, dict) and scene.get("name"):
            scene_names.add(str(scene["name"]))
    ensure(len(scene_names) == 18, f"expected 18 named scenes, got {len(scene_names)}")
    print("OK /v1/scenes -> 18 scenes")

    recommend_payload = {
        "user_id": args.user_id,
        "request_id": args.request_id,
        "top_k": args.top_k,
        "context": {
            "timestamp": "2026-05-29T10:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "hour": 10,
            "weekday": 4,
            "place_type": "在家",
            "place_type_available": 1,
            "place_type_confidence": 0.8,
            "activity_state": "静止",
            "activity_state_available": 1,
            "heart_rate_available": 0,
            "noise_class": "普通",
            "bluetooth": "耳机",
            "network": "wifi",
            "initial_need": "阅读",
        },
    }
    status, recommend = request_json(args.base_url, "POST", "/v1/recommend", recommend_payload, args.timeout)
    ensure(status == 200, f"/v1/recommend returned status {status}")
    ensure(recommend.get("request_id") == args.request_id, f"/v1/recommend returned wrong request_id: {recommend}")
    ensure(recommend.get("user_id") == args.user_id, f"/v1/recommend returned wrong user_id: {recommend}")
    recommendations = recommend.get("recommendations")
    ensure(isinstance(recommendations, list) and recommendations, f"/v1/recommend returned no recommendations: {recommend}")
    top_scene = str(recommendations[0].get("scene"))
    ensure(top_scene in scene_names, f"/v1/recommend returned unknown scene {top_scene!r}")
    print(f"OK /v1/recommend -> top1={top_scene}, top_k={len(recommendations)}")

    feedback_payload = {
        "user_id": args.user_id,
        "request_id": args.request_id,
        "recommended_scene": top_scene,
        "accepted_scene": top_scene,
        "event_type": "listen",
        "dwell_time_sec": 60,
        "played_ratio_pct": 0.7,
        "next_action": "继续播放",
    }
    status, feedback = request_json(args.base_url, "POST", "/v1/feedback", feedback_payload, args.timeout)
    ensure(status == 200, f"/v1/feedback returned status {status}")
    ensure(feedback.get("ok") is True, f"/v1/feedback response missing ok=true: {feedback}")
    ensure(feedback.get("accepted_scene") == top_scene, f"/v1/feedback accepted wrong scene: {feedback}")
    print(f"OK /v1/feedback -> reward={feedback.get('reward')}, learned={feedback.get('learned')}")

    status, history = request_json(args.base_url, "GET", f"/v1/users/{args.user_id}/history", None, args.timeout)
    ensure(status == 200, f"/v1/users/{{user_id}}/history returned status {status}")
    ensure(int(history.get("feedback_events", 0)) >= 1, f"/history did not record feedback: {history}")
    print(f"OK /v1/users/{args.user_id}/history -> feedback_events={history.get('feedback_events')}")

    print(f"Smoke passed against {args.base_url}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - CLI guard
        print(f"SMOKE FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
