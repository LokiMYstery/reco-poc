# Reco POC 生产接入指南

本仓库是音乐场景推荐的前后端 POC。本文面向正式项目的集成人员，目标不是说明如何继续维护 POC，而是把 POC 中已经验证过的职责边界、接口 contract、数据存储需求和生产化替换点梳理清楚。

生产接入时应优先复用：

- 前后端职责划分
- `/v1/recommend` 与 `/v1/feedback` 的请求/响应 contract
- 18 个推荐场景枚举
- 缺失权限/弱信号的处理语义
- 后端需要持久化的推荐事件、反馈事件、用户偏好和地理聚类数据

生产接入时不应直接照搬：

- SQLite 作为正式存储
- POC 的虚拟用户、权限模拟、导出脚本和烟测样例
- iOS Host App 的调试页面和虚拟用户 UI

## 1. 当前推荐返回数量

当前后端内部会对全部 18 个场景计算融合分并排序，但接口响应只返回 `top_k` 条，不返回完整 18 个排序。

- `top_k` 在后端默认值是 `3`。
- 目前后端 schema 限制 `top_k` 范围为 `1...10`，应按需调整。
- 当前 iOS POC 前端固定传 `top_k = 3`。
- 所以当前 POC 实际联调行为是返回 Top-3 场景。

代码依据：

- 后端默认与限制：[backend/poc_api.py](/Users/rickluo/Projects/poc/recsys_scene/backend/poc_api.py:95)
- 后端排序截断：[backend/poc_api.py](/Users/rickluo/Projects/poc/recsys_scene/backend/poc_api.py:304)
- 前端默认 Top-K：[frontend/RecoPOC/Sources/RecoPOC/Run/RunCoordinator.swift](/Users/rickluo/Projects/poc/recsys_scene/frontend/RecoPOC/Sources/RecoPOC/Run/RunCoordinator.swift:20)

生产建议：

- 正式项目不要默认沿用 `top_k = 3`，应按产品展示、服务端 rerank、客户端候选消费方式决定需要拿多少个。
- 如果只展示一个最终场景，可以请求 `top_k = 1`；如果需要候选列表、兜底或二次选择，再请求更多。


## 2. 前后端职责

### 2.1 前端职责

前端在正式项目中应定位为上下文 sensor 和反馈上报方，不在端上做最终推荐决策。

前端负责：

- 按正式账号体系生成或透传稳定 `user_id`；具体 ID 形态由后端和账号/隐私体系按需调整，前后端对齐即可。
- 每次推荐生成或透传 `request_id`，用于把后续反馈关联回本次推荐。
- 采集低权限上下文：时间、时区、网络、蓝牙/音频路由。
- 在用户授权后采集增强上下文：地点、运动、健康、噪音、App 内行为。
- 对拿不到的权限或设备能力传显式 availability 标记，例如 `heart_rate_available = 0`。
- 调用 `/v1/recommend` 获取 Top-K 场景。
- 在用户选择、播放、跳过、收藏、切换场景后调用 `/v1/feedback`。

前端不负责：

- 不在端上用规则选择最终场景。
- 不在端上学习长期偏好。
- 不把缺失权限当作负向证据。
- 当前实际推荐链路不需要日历；前端不要请求日历权限，不采集、不上传 `calendar_title` / `calendar_available`。

### 2.2 后端职责

后端在正式项目中应负责推荐排序、个性化学习和数据沉淀。

后端负责：

- 接收前端上下文并做字段兜底、枚举兼容和质量降权。
- 对 18 个场景计算规则分、语义分、偏好分和长期历史分。
- 输出按分数排序后的 Top-K 场景。
- 保存推荐请求、推荐结果和用于回放的上下文快照。
- 接收用户反馈，推断 reward，更新用户偏好。
- 保存长期历史行为，用于稳定分桶回退。
- 对粗略地理位置做用户内聚类，形成常去地点信号。

后端不应在生产中继续依赖：

- POC SQLite 文件作为唯一事实源。
- POC 本地偏好 JSON 文件不需要迁移；正式偏好可从零初始化，并按需接入正式存储。
- POC 导出 CSV 作为正式分析链路。

## 3. 项目结构

```text
backend/
  poc_api.py                 FastAPI 服务入口，定义接口 schema 和推荐/反馈流程
  poc_storage.py             POC SQLite 存储：推荐事件、反馈事件、geo cluster
  rule_scorer.py             missing-aware 实时规则打分
  preference_scorer.py       基于反馈的用户偏好学习
  history_booster.py         长期历史分桶回退
  scenes.py                  18 个场景枚举
  semantic_scorer.py         可选语义打分实现
  prototype_semantic_scorer.py
  qwen3_semantic_scorer.py
  Dockerfile                 POC 部署镜像
  docker-compose.yml         POC VPS 部署配置
  smoke_test/                POC 烟测，调试使用
  data/                      POC 本地数据，生产不要直接依赖

frontend/
  RecoPOC/
    Sources/RecoPOC/
      App/                   POC App shell 和状态模型
      Domain/                场景、问卷、虚拟用户、身份/安装标识
      Sensors/               原始 sensor 采集和平台 adapter
      Mapping/               前端上下文到后端 payload 的映射
      Services/API/          `/v1/recommend` 和 `/v1/feedback` 客户端
      Run/                   推荐 run 编排、反馈重试队列
      Features/              POC UI，生产可参考但不建议直接照搬
    Host/RecoPOCHost/        iOS Host App，仅用于 POC 安装和调试
    Tests/RecoPOCTests/      contract、payload、sensor 和 run 测试

docs/
  frontend-backend-payload-contract.md
  ios-frontend-poc-spec.md
  ios-poc-amap-poi-scoring-spec.md
  ios-poc-data-permission-matrix.md
  ios-poc-questionnaire-spec.md
  ios-poc-virtual-user-permission-masks.md
```

说明：

- 上面的目录是当前 POC 结构示例，不是正式项目必须照搬的模块边界。
- 问卷、用户输入、场景枚举、地点字段和反馈字段都需要结合正式前后端、产品交互和隐私策略重新对齐。
- 当前 POC 的问卷输入会通过 `intent`、`initial_need`、`initial_needs`、`user_tag`、`gender` 等字段进入后端；后端需要重新确认从哪里拿和请求这些值。
- 正式项目可与产品团队重新商议问卷文案和字段枚举；只要最终能稳定映射到后端可理解的主需求、多选需求和用户标签即可。

生产集成优先阅读：

- [docs/frontend-backend-payload-contract.md](/Users/rickluo/Projects/poc/recsys_scene/docs/frontend-backend-payload-contract.md)
- [backend/POC_BACKEND_API.md](/Users/rickluo/Projects/poc/recsys_scene/backend/POC_BACKEND_API.md)
- [backend/FRONTEND_CONTEXT_FIELDS.md](/Users/rickluo/Projects/poc/recsys_scene/backend/FRONTEND_CONTEXT_FIELDS.md)

## 4. 场景枚举

`recommended_scene`、`accepted_scene` 和 response 中的 `scene` 当前使用同一套 18 个中文场景名。

| scene_id | scene |
|---:|---|
| 0 | 放松 |
| 1 | 图书馆 |
| 2 | 健身 |
| 3 | 通勤 |
| 4 | 游戏 |
| 5 | 专注 |
| 6 | 阅读 |
| 7 | 深睡眠 |
| 8 | 减压 |
| 9 | 婴儿安睡 |
| 10 | 胎教 |
| 11 | 宠物陪伴 |
| 12 | 经期舒缓 |
| 13 | 睡午觉 |
| 14 | 跑步 |
| 15 | 瑜伽 |
| 16 | 冥想 |
| 17 | 深夜EMO |

生产约束：

- 正式项目需要和当前实际前后端、资源体系重新对齐场景名、场景 ID 和资源 ID。
- 前后端必须使用同一套场景名或稳定 ID 做映射。
- 反馈中的 `recommended_scene` 与 `accepted_scene` 必须是上述枚举之一。
- 如果正式项目内部使用资源 ID、歌单 ID 或场景 ID，应在服务端维护映射，不要让客户端猜映射。

## 5. 推荐接口 contract

### 5.1 `POST /v1/recommend`

用途：前端上传当前上下文，后端返回 Top-K 推荐场景。

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
    "network": "蜂窝数据",
    "bluetooth": "耳机",
    "place_candidates": [
      {
        "place_type": "在途",
        "confidence": 0.72,
        "distance_m": 35.0,
        "source": "mapkit_category"
      }
    ],
    "place_type": "在途",
    "place_type_available": 1,
    "place_type_confidence": 0.72,
    "place_type_quality": "exact_or_good_mapping",
    "activity_state": "慢速",
    "activity_state_available": 1,
    "heart_rate_zone": "任意",
    "heart_rate_available": 0
  }
}
```

顶层字段：

| 字段 | 类型 | 必须 | 生产语义 |
|---|---|---:|---|
| `user_id` | string | 是 | 稳定用户 ID，用于个性化、历史和反馈隔离；具体形态按正式账号体系调整 |
| `request_id` | string | 否但强烈建议 | 单次推荐请求 ID，后续 feedback 应带回 |
| `top_k` | int | 否 | 返回候选数量，当前 POC 默认 3，后端允许 1-10；生产按需决定 |
| `context` | object | 是 | 可观测上下文字段 |

响应示例：

```json
{
  "request_id": "req_20260526_0001",
  "user_id": "u_001",
  "model_version": "poc-2026-06-09-mobility-aware",
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
    },
    {
      "rank": 2,
      "scene_id": 5,
      "scene": "专注",
      "score": 0.8012,
      "components": {
        "rule": 0.82,
        "semantic": 0.5,
        "preference": 0.44,
        "history": 0.12
      }
    },
    {
      "rank": 3,
      "scene_id": 0,
      "scene": "放松",
      "score": 0.7345,
      "components": {
        "rule": 0.74,
        "semantic": 0.5,
        "preference": 0.49,
        "history": 0.08
      }
    }
  ],
  "availability_notes": [
    "heart_rate unavailable; no heart-rate penalty applied"
  ]
}
```

响应字段：

| 字段 | 生产使用建议 |
|---|---|
| `request_id` | 用于和后续反馈、日志、埋点关联 |
| `user_id` | 回显用户 ID，便于联调核对 |
| `model_version` | 可进入服务端日志和实验分析 |
| `semantic_mode` | 调试/实验字段，正式客户端不应依赖 |
| `weights` | 调试/实验字段，正式客户端不应依赖 |
| `recommendations` | 客户端真正使用的 Top-K 推荐结果 |
| `recommendations[].rank` | 从 1 开始的排序 |
| `recommendations[].scene_id` | 场景 ID |
| `recommendations[].scene` | 场景中文名 |
| `recommendations[].score` | 排序分数，可用于调试，不建议直接展示 |
| `recommendations[].components` | 调试解释字段，正式客户端不应依赖 |
| `availability_notes` | 调试解释字段，正式客户端不应依赖 |

## 6. 上下文字段 contract

生产第一版建议先保证最小闭环，再逐步增强上下文。

### 6.1 最小闭环字段

| 字段 | 类型 | 建议 | 说明 |
|---|---|---:|---|
| `timestamp` | string | 必传 | ISO8601 推荐触发时间 |
| `timezone` | string | 建议 | IANA timezone，例如 `Asia/Shanghai` |
| `hour` | int | 建议 | `0...23`，后端也可从 timestamp 解析 |
| `weekday` | int/string | 建议 | 建议 `0=周一...6=周日` |
| `network` | string | 建议 | `wifi`、`蜂窝数据`、`蜂窝数据（弱）` |
| `bluetooth` | string | 建议 | `任意`、`耳机`、`车载蓝牙`、`家用音响` |

### 6.2 地点字段

推荐正式前端传 `place_candidates`，最多 3 项，按 confidence 降序。

```json
{
  "place_candidates": [
    {
      "place_type": "商场",
      "confidence": 0.72,
      "distance_m": 18.0,
      "source": "mapkit_category",
      "quality": "exact_or_good_mapping"
    }
  ],
  "place_type": "商场",
  "place_type_available": 1,
  "place_type_confidence": 0.72,
  "place_type_quality": "exact_or_good_mapping"
}
```

地点枚举：

```text
任意、住宅区、商场、酒店、餐厅、公园、写字楼、机场、图书馆、海边、户外、在途、高铁站、地铁站、运动场所
```

后端语义：

- `place_candidates` 存在时，后端取 Top-1 自动补齐兼容字段 `place_type`、`place_type_confidence`、`place_type_quality`。
- 后端实时规则按 `1.0 / 0.45 / 0.20` 的排名权重软融合 Top-3 地点候选。
- Top-1 与 Top-2 的 confidence 差值 `< 0.12` 时，后端将地点质量降为 `noisy_mapping`。
- `place_type_available = 0` 或 `place_type_quality = noisy_mapping` 时，地点只作为弱信号或缺失信号处理。

POI 请求归属：

- 当前 POC 为了快速验证，把高德 Web API 请求临时放在 iOS 前端实现。
- 生产环境不应在前端直接请求 POI 服务，也不应把地图服务 key、POI 原始返回和地点映射规则放在客户端作为主链路。
- 正式方案建议前端只上传定位授权状态、经纬度/精度或服务端需要的最小定位输入，由后端统一调用高德等地图服务并派生 `place_candidates` / `place_type_*`。
- 国内地理当前按高德方案设计；海外方向仓库已有 `MapboxPlaceKnowledge.json` 资源表，但还没有实装完整海外 POI 请求和映射链路。

### 6.3 运动、健康和弱信号字段

| 字段 | 类型 | 生产语义 |
|---|---|---|
| `activity_state` | string | `任意`、`静止`、`慢速`、`中速`、`高速` |
| `activity_state_available` | int | `1` 可用，`0` 不可用 |
| `heart_rate_zone` | string | `任意`、`静息`、`稍高`、`高`、`波动` |
| `heart_rate_available` | int | `1` 可用，`0` 不可用 |
| `steps_last_10min` | int | 可选弱信号 |
| `recent_workout_minutes_24h` | int | 可选弱信号 |
| `sleep_quality` | string | 可选弱信号 |
| `weather` | string | 可选弱信号 |
| `noise_class` | string | `安静`、`普通`、`嘈杂` |
| `noise_available` | int | `1` 可用，`0` 不可用 |
| `app_event` | string | App 内行为，例如打开推荐页、播放、跳过、收藏 |
| `app_event_available` | int | `1` 可用，`0` 不可用 |
| `initial_need` | string | 问卷主需求 |
| `initial_needs` | array | 问卷多选需求 |
| `questionnaire_snapshot` | object | 问卷快照；后端会解码为 `initial_need` / `initial_needs` |
| `user_tag` | string | 冷启动弱先验 |

当前实际推荐链路不使用日历字段。POC backend schema 里仍保留 `calendar_title`、`calendar_available`，但生产第一版不要请求日历权限，也不要采集或上传这两个字段。

缺失语义：

- 权限未授权、设备不支持、采集失败时，优先传 `*_available = 0`。
- 后端应把 unavailable 当 missing，不当负向证据。
- 不建议用假值补齐，例如没有心率时不要传 `heart_rate_zone = 静息`。

### 6.4 问卷 snapshot decoder

生产链路可以不在每次推荐请求里拉问卷表，而是在用户完成或更新问卷后生成一个稳定快照，并随用户画像或冷启动上下文进入推荐。当前后端支持 `questionnaire_snapshot`，会在 context normalization 阶段把它解码成现有算法可读的 `initial_need` / `initial_needs`。

示例：

```json
{
  "questionnaire_snapshot": {
    "schema_version": 1,
    "need_taxonomy_version": 1,
    "primary_need_bit": 2,
    "needs_mask": 6,
    "questionnaire_available": 1,
    "intent_available": 1
  }
}
```

`needs_mask` 是 9-bit bitmask，语义固定为 `0 = 未选中`、`1 = 选中`。每个元需求占一个固定 bit 位：

| bit | 单项 bit 值 | 需求 |
|---:|---:|---|
| 0 | `1` | 学习/工作专注 |
| 1 | `2` | 睡眠/午休 |
| 2 | `4` | 放松/减压 |
| 3 | `8` | 运动/健身 |
| 4 | `16` | 通勤/出行 |
| 5 | `32` | 情绪陪伴 |
| 6 | `64` | 家庭/照护 |
| 7 | `128` | 游戏娱乐 |
| 8 | `256` | 阅读陪伴 |

编码方式是 bitwise OR，不是普通枚举 ID 相加。比如用户选择 `睡眠/午休` 和 `放松/减压`：

```text
needs_mask = (1 << 1) | (1 << 2) = 2 | 4 = 6
```

后端解码结果：

```json
{
  "initial_needs": ["睡眠/午休", "放松/减压"]
}
```

`primary_need_bit` 表示主需求，必须是单个合法 bit 值。例如 `primary_need_bit = 2` 会解码成：

```json
{
  "initial_need": "睡眠/午休"
}
```

如果 snapshot 里没有合法 `primary_need_bit`，但 `needs_mask` 解出了多个需求，后端会沿用旧兼容逻辑，把多选需求拼成一个 `initial_need` 字符串，例如：

```text
睡眠/午休、放松/减压
```

兼容规则：

- `need_taxonomy_version = 1` 是当前唯一支持版本。
- `needs_mask = 0` 表示没有 initial needs，不会生成 `initial_need` / `initial_needs`。
- snapshot 存在且版本合法时，优先派生 canonical 字段；旧格式 `initial_need` / `initial_needs` 仍可继续直接传。
- 非整数 mask、非法 primary bit、未知版本会被保守忽略，不应让推荐请求失败。

## 7. 反馈接口 contract

### 7.1 `POST /v1/feedback`

用途：用户发生真实选择或行为后回传反馈，让后端学习偏好。

第一版生产最简口径：只需要能告诉后端“用户最后选择了哪个场景”。如果前端暂时没有播放时长、完成比例、like/skip 等质量信号，可以先只传 `user_id`、`request_id`、`recommended_scene`、`accepted_scene` 和一个固定事件类型。

请求示例：

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

用户纠错示例：

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

字段说明：

| 字段 | 类型 | 必须 | 生产语义 |
|---|---|---:|---|
| `user_id` | string | 是 | 必须和 recommend 的用户一致 |
| `request_id` | string | 否但强烈建议 | 用于找回推荐时上下文 |
| `recommended_scene` | string | 是 | 后端当时推荐给用户的场景 |
| `accepted_scene` | string | 第一版建议必传 | 用户实际选择、接受或切换后的场景 |
| `event_type` | string | 是 | 第一版可固定为 `correction` 或 `listen`；增强版再区分 `impression`、`like`、`dislike`、`skip` |
| `dwell_time_sec` | int | 建议 | 停留/播放时长 |
| `played_ratio_pct` | float | 建议 | `0.0...1.0` 播放完成比例 |
| `next_action` | string | 可选 | 后续动作描述 |
| `context` | object | 可选 | 如果 `request_id` 找不到原上下文，可补传 |

最小反馈示例：

```json
{
  "user_id": "u_001",
  "request_id": "req_20260526_0002",
  "recommended_scene": "通勤",
  "accepted_scene": "跑步",
  "event_type": "correction"
}
```

响应示例：

```json
{
  "ok": true,
  "user_id": "u_001",
  "request_id": "req_20260526_0001",
  "accepted_scene": "通勤",
  "reward": 0.45,
  "learned": true
}
```

反馈语义：

- `impression` 只记录曝光，当前 POC 不更新偏好，`learned = false`。
- `listen`、`like`、`dislike`、`skip`、`correction` 会进入偏好学习。
- 如果 `accepted_scene` 不传，非 impression 事件默认按 `recommended_scene` 学习。
- 如果用户从推荐场景切换到另一个场景，应使用 `event_type = correction` 并传 `accepted_scene`。

## 8. 后端融合逻辑

当前 POC 后端融合四类分数：

```text
final_score =
  rule_weight * rule_score
+ semantic_weight * semantic_score
+ preference_weight * preference_score
+ history_weight * stable_history_score
```

默认权重：

```text
rule_weight = 0.58
semantic_weight = 0.00
preference_weight = 0.18
history_weight = 0.24
```

通道职责：

| 通道 | 说明 |
|---|---|
| `rule_score` | 当前上下文规则兜底，处理时间、地点、运动、健康、设备等实时信号 |
| `semantic_score` | 可选语义通道，默认关闭；POC Docker 配置会开启 embedding prototype |
| `preference_score` | 基于用户反馈的在线偏好学习 |
| `stable_history_score` | 基于长期历史的分桶回退，低样本时更稳定 |

生产建议：

- 权重应进入服务端配置或实验平台，不要写死在客户端。
- `components` 可保留在服务端日志和内部调试工具里，客户端展示不应依赖。
- 语义模型是否开启应由服务端实验和资源成本决定。

## 9. 后端需要持久化的数据

生产后端至少需要保存以下数据域。

### 9.1 推荐事件

用途：回放、解释、反馈关联、离线评估。

POC 表：`recommendation_events`

| 字段 | 生产含义 |
|---|---|
| `request_id` | 单次推荐请求 ID |
| `user_id` | 用户 ID，具体形态按正式账号体系决定 |
| `created_at` | 服务端接收时间 |
| `context_json` | 归一化后的上下文快照 |
| `result_json` | 返回给前端的推荐结果 |

生产建议：

- `request_id + user_id` 应可定位一次推荐。
- 保存服务端归一化后的 context，而不只是客户端原始 payload。
- 推荐结果应保存 Top-K、model_version、实验桶、权重版本和必要解释字段。

### 9.2 反馈事件

用途：偏好学习、长期历史、效果评估。

POC 表：`feedback_events`

| 字段 | 生产含义 |
|---|---|
| `request_id` | 关联推荐事件 |
| `user_id` | 用户 ID，具体形态按正式账号体系决定 |
| `created_at` | 服务端接收时间 |
| `recommended_scene` | 当时推荐的场景 |
| `accepted_scene` | 用户实际接受/切换后的场景 |
| `event_type` | 行为类型 |
| `dwell_time_sec` | 停留时长 |
| `played_ratio_pct` | 播放完成比例 |
| `next_action` | 后续动作 |
| `context_json` | 用于学习的上下文 |
| `raw_json` | 原始反馈 payload |

生产建议：

- 反馈事件是推荐学习的核心事实源，应进入正式行为日志或推荐特征库。
- `impression`、`listen`、`skip`、`like`、`dislike`、`correction` 应保留为可区分事件。
- reward 可以实时推断，也可以离线重算；不要只存最终 reward 而丢失原始行为。

### 9.3 用户偏好表

用途：按用户、上下文分桶、场景学习长期偏好。

POC 实现：`data/poc_preference.json`

生产建议表意：

| 维度 | 说明 |
|---|---|
| `user_id` | 用户 ID，具体形态按正式账号体系决定 |
| `context_bucket` | 时间、地点、活动、心率、噪声、设备等离散桶 |
| `scene` | 18 个场景之一 |
| `score` | 用户在该上下文桶下对该场景的偏好强度 |
| `count` | 证据次数 |
| `updated_at` | 最近更新时间 |

生产替换建议：

- 当前 POC 偏好表在文件不存在时会从空表初始化；正式系统支持从零开始初始化，不需要迁移 POC 本地偏好文件。
- 如果继续保留同类在线偏好学习，需要用正式 KV/特征库/在线特征服务承载，而不是依赖本地 JSON 文件。
- 支持按用户删除、隐私合规清理和冷启动回退。
- 保留全局偏好或 cohort 偏好，用于低样本用户。

### 9.4 长期历史特征

用途：在实时上下文稀疏或短期反馈不足时提供稳定回退。

POC 实现：从 `feedback_events` 加载历史 listen rows，构建分层分桶：

```text
user + weekday + time_slot + activity + geo_cluster
user + weekday + time_slot + activity + place
user + weekday + time_slot + activity
user + weekday + time_slot
user + time_slot
user global
profile/time-slot cohort
global
```

生产建议：

- 长期历史可以离线聚合后写入在线特征。
- 需要样本数 shrinkage，避免小样本 bucket 支配排序。
- 低置信地点和 unavailable 权限不应进入细粒度地点桶。

### 9.5 地理聚类

用途：把经纬度转换为用户内常去地点信号，避免直接依赖原始坐标。

POC 表：`geo_clusters`

| 字段 | 生产含义 |
|---|---|
| `user_id` | 用户 ID，具体形态按正式账号体系决定 |
| `center_lat` / `center_lon` | 用户内聚类中心 |
| `count` | 命中次数 |
| `avg_accuracy_m` | 平均定位精度 |
| `created_at` / `last_seen_at` | 生命周期 |

生产建议：

- 原始坐标属于敏感数据，正式环境需按隐私策略最小化保存。
- 可改为只保存用户内 cluster ID、粗粒度地理 token 或服务端派生特征。
- 低精度定位应跳过聚类。

## 10. 生产化替换清单

| POC 项 | 当前实现 | 生产建议 |
|---|---|---|
| HTTP 服务 | FastAPI `poc_api.py` | 可保留 contract，按正式后端框架重写或封装 |
| 存储 | SQLite `data/poc_music_scene.db` | 替换为正式 DB、日志、特征库 |
| 偏好 | JSON `data/poc_preference.json`，不存在时从空表启动 | 可从零初始化；如保留在线学习，替换为正式在线特征/KV/用户画像服务 |
| 用户 ID | POC 虚拟用户或 device-demo key | 使用正式账号/设备体系映射，前后端对齐即可 |
| POI 请求 | iOS 前端临时请求高德 Web API | 生产迁到后端，前端只传最小定位输入 |
| 权限模拟 | 16 个 virtual users | 生产仅保留真实权限状态和 availability flags |
| Host App | `RecoPOCHost` | 集成进正式 iOS App |
| Debug UI | Setup/Diagnostics/VirtualUsers | 后置到内部调试入口或删除 |
| 导出脚本 | CSV export | 接入正式日志、BI 或实验分析 |
| 模型权重 | 环境变量 | 接入配置中心/实验平台 |
| 语义模型 | 可选本地 prototype | 服务端统一部署、灰度和监控 |

## 11. 正式接入建议顺序

1. 固定 18 个场景枚举和正式资源映射。
2. 在正式后端实现 `/v1/recommend` 和 `/v1/feedback` contract。
3. 前端先接最小上下文字段和“用户选择了哪个场景”的反馈闭环。
4. 后端保存推荐事件和反馈事件，先保证可回放。
5. 接入偏好学习和长期历史回退。
6. 增加地点 Top-3、运动、健康、噪音、App 行为等增强信号；日历当前没有用到，不请求、不采集、不上传。
7. 将 `components`、`availability_notes`、导出和诊断能力收敛到内部调试工具。
8. 接入正式监控、实验、隐私清理和数据保留策略。

## 12. 本地调试和 POC 验证

以下内容仅用于 POC 调试，不是生产接入要求。

### 12.1 后端本地启动

```bash
cd backend
python3 -m pip install -r requirements_poc.txt
uvicorn poc_api:app --host 0.0.0.0 --port 8000
```

健康检查：

```bash
curl http://127.0.0.1:8000/health
```

烟测：

```bash
cd backend
python3 smoke_backend.py --base-url http://127.0.0.1:8000
```

Docker 调试部署：

```bash
cd backend
docker compose up -d --build
curl http://127.0.0.1:8000/health
```

### 12.2 iOS POC 调试

```bash
git pull origin main
open frontend/RecoPOC/RecoPOC.xcodeproj
```

在 Xcode 中选择 `RecoPOCHost` scheme，选择真机，确认 Signing Team 后运行。打开 App 后先进入 Setup 完成权限和问卷，再发起推荐 run。

当前 Debug backend URL 在 `frontend/RecoPOC/project.yml` 中配置为：

```text
https://www.zkjpoc.icu
```

如需改连本地或 staging 后端，可覆盖 `RECO_BACKEND_BASE_URL`。这属于 POC/调试配置，生产 App 应使用正式环境配置体系。

### 12.3 前端构建和测试

```bash
cd frontend/RecoPOC
swift build -j 1 -Xswiftc -warnings-as-errors
swift test -j 1 -Xswiftc -warnings-as-errors
xcodegen generate
xcodebuild -project RecoPOC.xcodeproj \
  -scheme RecoPOCHost \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

这些命令用于验证 POC 包和 Host App，不代表正式 App 的接入方式。
