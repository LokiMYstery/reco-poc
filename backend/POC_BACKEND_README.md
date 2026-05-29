# Music Scene Recommendation POC Backend

This is the POC backend for music scene recommendation. It exposes a small HTTP API for the iPhone mini app:

```text
raw context -> Top-K music scenes
user feedback -> SQLite history + personalized preference update
```

## 1. Files

Minimal files required to run the default POC backend:

```text
poc_api.py                    # FastAPI service
poc_storage.py                # SQLite persistence
history_booster.py            # stable long-term history fallback
preference_scorer.py          # personalized preference scorer
rule_scorer.py                # missing-aware rule scorer
scenes.py                     # 18 scene definitions
requirements_poc.txt          # POC dependencies
poc_test_payloads.json        # fixed multi-user test payloads
poc_smoke_test.py             # one-command smoke test
POC_BACKEND_API.md            # detailed API documentation
FRONTEND_CONTEXT_FIELDS.md    # frontend context field contract
```

Optional files only needed when enabling embedding semantic scoring:

```text
prototype_semantic_scorer.py
semantic_scorer.py
scene_prototypes.py
qwen3_semantic_scorer.py
```

## 2. Install

```bash
cd /Users/fengyongxi/Desktop/AI_music-main
python3 -m pip install -r requirements_poc.txt
```

## 3. Start Server

```bash
uvicorn poc_api:app --host 0.0.0.0 --port 8000
```

Local test URL:

```text
http://127.0.0.1:8000
```

Swagger UI:

```text
http://127.0.0.1:8000/docs
```

Health check:

```bash
curl http://127.0.0.1:8000/health
```

Expected response:

```json
{
  "ok": true,
  "model_version": "poc-2026-05-26",
  "semantic_mode": "none"
}
```

## 4. Main APIs

```text
GET  /health
GET  /v1/scenes
POST /v1/recommend
POST /v1/feedback
GET  /v1/users/{user_id}/history
```

## 5. Recommend Example

`top_k` means how many candidate scenes the backend should return for this app-open/recommendation request. For POC, use `top_k=3`.

```bash
curl -X POST http://127.0.0.1:8000/v1/recommend \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "u_001",
    "request_id": "req_001",
    "top_k": 3,
    "context": {
      "timestamp": "2026-05-26T08:35:00+08:00",
      "timezone": "Asia/Shanghai",
      "hour": 8,
      "weekday": 1,
      "place_type": "在途",
      "place_type_available": 1,
      "place_type_confidence": 0.72,
      "place_type_quality": "exact_or_good_mapping",
      "activity_state": "慢速",
      "activity_state_available": 1,
      "heart_rate_zone": "任意",
      "heart_rate_available": 0,
      "noise_class": "普通",
      "bluetooth": "耳机",
      "network": "蜂窝数据"
    }
  }'
```

Response shape:

```json
{
  "request_id": "req_001",
  "user_id": "u_001",
  "model_version": "poc-2026-05-26",
  "recommendations": [
    {
      "rank": 1,
      "scene_id": 3,
      "scene": "通勤",
      "score": 0.88,
      "components": {
        "rule": 1.0,
        "semantic": 0.5,
        "preference": 1.0,
        "history": 0.5
      }
    }
  ],
  "availability_notes": [
    "heart_rate unavailable; no heart-rate penalty applied"
  ]
}
```

## 6. Feedback Example

Call this after the user plays, skips, likes, closes, or switches scenes. This is how the POC learns user habits.

```bash
curl -X POST http://127.0.0.1:8000/v1/feedback \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "u_001",
    "request_id": "req_001",
    "recommended_scene": "通勤",
    "accepted_scene": "通勤",
    "event_type": "listen",
    "dwell_time_sec": 420,
    "played_ratio_pct": 0.82,
    "next_action": "继续播放"
  }'
```

Correction example:

```bash
curl -X POST http://127.0.0.1:8000/v1/feedback \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "u_001",
    "request_id": "req_002",
    "recommended_scene": "通勤",
    "accepted_scene": "跑步",
    "event_type": "correction",
    "dwell_time_sec": 8,
    "played_ratio_pct": 0.05,
    "next_action": "用户切换场景"
  }'
```

Check user history:

```bash
curl http://127.0.0.1:8000/v1/users/u_001/history
```

## 7. Minimal Context Fields

Frontend can start with these fields:

```text
user_id
timestamp
hour
weekday
network
bluetooth
place_type
place_type_confidence
place_type_available
activity_state_available
activity_state
heart_rate_available
heart_rate_zone
```

If health data is unavailable, send:

```json
{
  "activity_state_available": 0,
  "heart_rate_available": 0
}
```

Missing fields are treated as missing, not as negative evidence.

## 8. Multi-User / Permission Simulation

The POC supports multiple `user_id` values. The same iPhone device can simulate different users or different permission groups by sending different `user_id` values.

Example:

```text
u_full_permission       # location + motion + heart rate available
u_no_health_permission  # no activity / heart rate
u_low_place_confidence  # place_type noisy or low confidence
u_minimal_context       # only time + network + bluetooth
```

Backend personalization and history are keyed by `user_id`, so feedback from one user id will not affect another user id.

For missing permissions, send explicit availability flags:

```json
{
  "activity_state_available": 0,
  "heart_rate_available": 0,
  "place_type_available": 0
}
```

The backend will treat these as missing signals, not negative evidence.

## 9. More Documentation

## 9. Smoke Test

Run an in-process smoke test with temporary SQLite files:

```bash
python3 poc_smoke_test.py
```

Run against a live server:

```bash
uvicorn poc_api:app --host 0.0.0.0 --port 8000
python3 poc_smoke_test.py --base-url http://127.0.0.1:8000
```

The fixed payloads are in:

```text
poc_test_payloads.json
```

They cover:

```text
u_full_permission
u_no_health_permission
u_low_place_confidence
u_minimal_context
u_geo_routine
u_travel_or_new_place
u_low_accuracy_geo
```

The smoke test checks:

```text
/health
/v1/scenes
/v1/recommend
/v1/feedback
user_id isolation
feedback/history update
geo cluster reuse
low-accuracy geo skip
impression does not update preference
```

## 10. More Documentation

For detailed request/response schemas, see:

```text
POC_BACKEND_API.md
```

For frontend field availability, permissions, enum values, and optional fields, see:

```text
FRONTEND_CONTEXT_FIELDS.md
```
