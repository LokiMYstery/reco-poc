# 音乐场景推荐 POC 后端 API 文档

```text
poc_api.py                    # FastAPI 服务入口
poc_storage.py                # SQLite 存储
history_booster.py            # 稳定版长期历史分桶回退
preference_scorer.py          # 用户反馈偏好分
rule_scorer.py                # missing-aware rule
scenes.py                     # 18 个场景定义
requirements_poc.txt          # POC 依赖
POC_BACKEND_README.md         # 最短启动说明
FRONTEND_CONTEXT_FIELDS.md    # 前端字段对齐
```

如果开启 embedding semantic scoring，还需要：

```text
prototype_semantic_scorer.py
semantic_scorer.py
scene_prototypes.py
qwen3_semantic_scorer.py
```

## 2. 启动方式

安装依赖：

```bash
python3 -m pip install -r requirements_poc.txt
```

启动服务：

```bash
uvicorn poc_api:app --host 0.0.0.0 --port 8000
```

本地测试地址：

```text
http://127.0.0.1:8000
```

Swagger 文档：

```text
http://127.0.0.1:8000/docs
```

健康检查：

```bash
curl http://127.0.0.1:8000/health
```

## 3. 算法链路

当前 POC 的推荐融合：

```text
final_score =
  rule_weight * rule_score
+ semantic_weight * semantic_score
+ preference_weight * preference_score
+ history_weight * stable_history_score
```

默认 POC 配置：

```text
rule_weight = 0.58
semantic_weight = 0.00
preference_weight = 0.18
history_weight = 0.24
```

说明：

- `rule_score`：当前上下文规则兜底。
- `preference_score`：用户历史反馈在线学习。
- `stable_history_score`：SQLite 历史行为分桶回退。
- `semantic_score`：默认关闭，避免 POC 服务首次启动加载 embedding 模型太慢；需要时可开启。

如需开启 MiniLM prototype embedding：

```bash
export POC_SEMANTIC=embedding-proto
export POC_RULE_WEIGHT=0.54
export POC_SEMANTIC_WEIGHT=0.12
export POC_PREFERENCE_WEIGHT=0.14
export POC_HISTORY_WEIGHT=0.20
uvicorn poc_api:app --host 0.0.0.0 --port 8000
```

## 4. Endpoint 总览

| Method | Path | 作用 |
|---|---|---|
| GET | `/health` | 健康检查 |
| GET | `/v1/scenes` | 返回 18 个支持场景 |
| POST | `/v1/recommend` | 根据用户上下文返回 Top-K 场景 |
| POST | `/v1/feedback` | 写入用户反馈并更新偏好 |
| GET | `/v1/users/{user_id}/history` | 查看某用户 POC 历史反馈摘要 |

## 5. 推荐接口

### POST `/v1/recommend`

请求示例：

```json
{
  "user_id": "u_001",
  "request_id": "req_20260526_0001",
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
}
```

返回示例：

```json
{
  "request_id": "req_20260526_0001",
  "user_id": "u_001",
  "model_version": "poc-2026-05-26",
  "semantic_mode": "none",
  "weights": {
    "rule": 0.58,
    "semantic": 0.0,
    "preference": 0.18,
    "history": 0.24
  },
  "recommendations": [
    {
      "rank": 1,
      "scene_id": 3,
      "scene": "通勤",
      "score": 0.9123,
      "components": {
        "rule": 1.0,
        "semantic": 0.5,
        "preference": 0.52,
        "history": 0.0
      }
    }
  ],
  "availability_notes": [
    "heart_rate unavailable; no heart-rate penalty applied",
    "calendar absent; treated as missing, not negative",
    "app_event absent; treated as missing, not negative"
  ]
}
```

返回字段说明：

| 字段 | 含义 |
|---|---|
| `request_id` | 本次推荐 ID，后续反馈可带回 |
| `recommendations` | Top-K 场景 |
| `scene_id` | 0-17 场景 ID |
| `scene` | 场景中文名 |
| `score` | 融合后分数，主要用于排序 |
| `components.rule` | 规则通道归一化分 |
| `components.semantic` | 语义通道归一化分 |
| `components.preference` | 个性化偏好通道归一化分 |
| `components.history` | 长期历史通道归一化分 |
| `availability_notes` | 缺失/降级说明，方便 debug |

## 6. 反馈接口

### POST `/v1/feedback`

客户端应在用户产生真实行为后调用，例如：

- 推荐曝光后实际播放。
- 用户停留一段时间。
- 用户收藏/跳过/关闭。
- 用户主动切换到另一个场景。

请求示例：用户接受了推荐。

```json
{
  "user_id": "u_001",
  "request_id": "req_20260526_0001",
  "recommended_scene": "通勤",
  "accepted_scene": "通勤",
  "event_type": "listen",
  "dwell_time_sec": 420,
  "played_ratio_pct": 0.82,
  "next_action": "继续播放"
}
```

请求示例：用户纠错，从通勤切到了跑步。

```json
{
  "user_id": "u_001",
  "request_id": "req_20260526_0002",
  "recommended_scene": "通勤",
  "accepted_scene": "跑步",
  "event_type": "correction",
  "dwell_time_sec": 8,
  "played_ratio_pct": 0.05,
  "next_action": "用户切换场景"
}
```

返回示例：

```json
{
  "ok": true,
  "user_id": "u_001",
  "request_id": "req_20260526_0001",
  "accepted_scene": "通勤",
  "reward": 0.95
}
```

说明：

- 如果 `context` 不传，后端会用 `request_id + user_id` 找最近一次推荐时保存的 context。
- 如果找不到推荐记录，也可以直接在 feedback 里带 `context`。
- 后端会把 feedback 写入 `data/poc_music_scene.db`，并更新 `data/poc_preference.json`。

## 7. 18 个场景

可通过：

```bash
curl http://127.0.0.1:8000/v1/scenes
```

当前场景：

```text
0 放松
1 图书馆
2 健身
3 通勤
4 游戏
5 专注
6 阅读
7 深睡眠
8 减压
9 婴儿安睡
10 胎教
11 宠物陪伴
12 经期舒缓
13 睡午觉
14 跑步
15 瑜伽
16 冥想
17 深夜EMO
```

## 8. iPhone mini app 最小接入建议

第一版客户端只需要接两个接口：

1. 打开 App 或进入音乐推荐页时调用 `/v1/recommend`。
2. 用户播放、停留、跳过、收藏、切换场景时调用 `/v1/feedback`。

最小可用字段：

```text
user_id
timestamp
hour
weekday
network
bluetooth
place_type + place_type_confidence
activity_state_available + activity_state
heart_rate_available + heart_rate_zone
```

如果健康权限没有拿到，也可以先只传：

```text
user_id
timestamp
hour
weekday
network
bluetooth
place_type
place_type_confidence
```

后端不会因为缺失健康字段而扣分。

## 9. 多 user_id / 多权限场景模拟

POC 后端支持多个 `user_id`。同一台 iPhone 设备可以通过传不同 `user_id` 来模拟不同用户，或者模拟不同权限组合下的可用 context。

示例：

```text
u_full_permission       -> 地点、运动、心率都可用
u_no_health_permission  -> 健康权限不可用
u_low_place_confidence  -> 地点类型低置信或 noisy mapping
u_minimal_context       -> 只传时间、网络、蓝牙等低权限字段
```

后端的用户历史、SQLite feedback 和 preference/history 分都会按 `user_id` 隔离。因此：

```text
同一个设备 + 不同 user_id = 可以模拟不同用户/不同权限组
同一个 user_id + 多次 feedback = 可以观察个性化历史逐步生效
```

缺失权限建议显式传：

```json
{
  "activity_state_available": 0,
  "heart_rate_available": 0,
  "place_type_available": 0
}
```

后端会把这些字段当作 missing，不会当作负证据。
