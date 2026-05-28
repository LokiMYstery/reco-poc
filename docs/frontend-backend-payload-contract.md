# 前端需要传给推荐后端的字段清单

本文基于 `backend_reference/POC_BACKEND_API.md`、`backend_reference/POC_BACKEND_README.md`、`backend_reference/FRONTEND_CONTEXT_FIELDS.md` 整理，面向 Swift/iOS 前端实现。

目标：前端只负责采集可观测上下文和用户行为，不在前端判断最终推荐场景；后端根据上下文、历史反馈和用户偏好输出 Top-K 场景。

---

## 0. POC 前端定位：Sensor 字段总表

这个 POC 前端本质上是一个 **用户上下文 sensor**：重点不是在前端做推荐判断，而是尽可能稳定地采集时间、地点、运动、健康、连接状态、环境、App 行为和用户反馈，然后交给后端验证推荐规则、历史偏好和个性化学习是否有效。

优先级定义：

| 优先级 | 含义 | 前端实现策略 |
|---|---|---|
| P0 | 后端请求核心字段 | 第一版必须实现，否则链路不完整 |
| P1 | 推荐效果核心上下文 | 第一版强烈建议实现，低成本或后端强依赖 |
| P2 | 权限型/增强上下文 | 有权限、有设备能力则实现；拿不到要传 `*_available=0` |
| P3 | 冷启动/弱信号/后续增强 | POC 可选，不阻塞第一版闭环 |
| Debug | 调试/回看字段 | 主要用于联调、调试、历史查看 |

### 0.1 `/v1/recommend` 顶层字段

| 字段 | 类型 | 优先级 | 是否必须 | 枚举/取值 | 说明 |
|---|---|---:|---:|---|---|
| `user_id` | string | P0 | 是 | 匿名稳定 ID；例如 `u_full_permission` | 后端个性化、history、feedback 都按它隔离；不要传手机号/邮箱/姓名 |
| `request_id` | string | P0 | 否但强烈建议 | 每次推荐生成 UUID；例如 `req_20260527_0001` | 用来关联后续 `/v1/feedback`；前端生成更方便排查 |
| `top_k` | int | P1 | 否 | 建议固定 `3`；后端允许 1-10 | 返回几个候选场景 |
| `context` | object | P0 | 是 | 见下方 context 总表 | 用户上下文 sensor 数据主体 |

### 0.2 `context` 字段总表

| 字段 | 类型 | 优先级 | 是否建议传 | 枚举/取值 | 缺失/拿不到时 | 说明 |
|---|---|---:|---:|---|---|---|
| `timestamp` | string | P0 | 必传 | ISO8601；例 `2026-05-27T10:40:00+08:00` | 不建议缺失 | 推荐触发时间；后端可从中解析 `hour/date/weekday` |
| `timezone` | string | P1 | 建议 | IANA timezone；例 `Asia/Shanghai` | 可不传 | 调试和日志解释用 |
| `date` | string | P3 | 可选 | `YYYY-MM-DD`；例 `2026-05-27` | 可不传，后端可从 timestamp 解析 | 日期分桶/调试 |
| `hour` | int | P1 | 建议 | `0`-`23` | 可不传，后端尝试从 timestamp 解析；默认兜底 12 | 时间规则、历史分桶 |
| `weekday` | int/string | P1 | 建议 | 建议 `0`=周一，`6`=周日；也可 `周二` | 可不传，后端尝试从 timestamp 解析 | 周期规律 |
| `time_slot` | string | P3 | 可选 | `早晨`、`中午`、`下午`、`傍晚`、`夜晚`、`深夜` | 可不传，后端可根据 `hour` 自动补 | 辅助时间语义 |
| `place_type` | string | P1 | 建议 | `任意`、`住宅区`、`商场`、`酒店`、`餐厅`、`公园`、`写字楼`、`机场`、`图书馆`、`海边`、`户外`、`在途`、`高铁站`、`地铁站` | 没权限传 `任意` | 重要地点上下文 |
| `place_type_available` | int | P1 | 建议 | `1` 可用，`0` 不可用 | 没权限/失败传 `0` | 标记地点信号是否可用 |
| `place_type_confidence` | float | P1 | 强烈建议 | `0.0`-`1.0`；例 `0.72` | 不可用传 `0.0` | 低于约 `0.55` 后端会弱化地点信号 |
| `place_type_quality` | string | P1 | 建议 | `exact_or_good_mapping`、`noisy_mapping`、`unavailable` | 不可用传 `unavailable` | 控制地点映射质量和历史 bucket 可信度 |
| `latitude` | float | P2 | 可选 | `-90` 到 `90` | 可不传 | 可选增强，用于后端按用户聚类常去地点 |
| `longitude` | float | P2 | 可选 | `-180` 到 `180` | 可不传 | 可选增强，用于后端按用户聚类常去地点 |
| `location_accuracy_m` | float | P2 | 可选 | 非负数；例 `35.0` | 可不传 | 定位水平精度；过低精度后端会跳过 geo 聚类 |
| `activity_state` | string | P2 | 有权限则传 | `任意`、`静止`、`慢速`、`中速`、`高速` | 不可用可传 `任意` 或不传 | CoreMotion 运动状态 |
| `activity_state_available` | int | P2 | 建议 | `1` 可用，`0` 不可用 | 无权限/不可用传 `0` | 后端把不可用当 missing，不当负证据 |
| `heart_rate_zone` | string | P2 | 有权限则传 | `任意`、`静息`、`稍高`、`高`、`波动` | 不可用传 `任意` 或不传 | HealthKit/Apple Watch 心率区间 |
| `heart_rate_available` | int | P2 | 建议 | `1` 可用，`0` 不可用 | 无权限/无手表传 `0` | 后端把不可用当 missing，不否定跑步/健身 |
| `heart_rate_quality` | string | P3 | 可选 | `fresh`、`stale_before_activity` | 可不传 | 心率是否新鲜，避免刚运动心率滞后 |
| `steps_last_10min` | int | P3 | 可选 | 非负整数；例 `850` | 可不传 | HealthKit 步数弱信号 |
| `recent_workout_minutes_24h` | int | P3 | 可选 | 非负整数；例 `35` | 可不传 | 24 小时内运动分钟数 |
| `sleep_quality` | string | P3 | 可选 | `好`、`一般`、`差` | 可不传 | 睡眠权限弱信号 |
| `weather` | string | P3 | 可选 | `晴`、`多云`、`小雨` 等 | 可不传 | 天气弱信号，可后续接 WeatherKit/服务端 |
| `light_class` | string | P3 | 可选 | `暗光`、`室内柔光`、`明亮`、`强光` | 可不传 | 睡眠/午睡辅助信号 |
| `noise_class` | string | P3 | 可选 | `安静`、`普通`、`嘈杂` | 可不传 | 只上传本地分类，不上传原始音频 |
| `noise_available` | int | P3 | 可选 | `1` 可用，`0` 不可用 | 无麦克风权限传 `0` 或不传 | 噪音分类是否可用 |
| `bluetooth` | string | P1 | 建议 | `任意`、`耳机`、`车载蓝牙`、`家用音响` | 不确定传 `任意` | 通勤/运动/睡眠辅助信号 |
| `network` | string | P1 | 建议 | `wifi`、`蜂窝数据`、`蜂窝数据（弱）` | 可默认 `wifi`，但建议真实采集 | 在途/可用性弱信号 |
| `calendar_title` | string | P3 | 可选 | 任意日历标题；例 `瑜伽课` / `会议` | 可不传 | 权限较大，第一版不建议依赖 |
| `calendar_available` | int | P3 | 可选 | `1` 可用，`0` 不可用 | 无权限传 `0` 或不传 | 日历信号是否可用 |
| `app_event` | string | P2 | 可选但建议逐步做 | `打开推荐页`、`点击某场景`、`搜索关键词`、`播放`、`跳过`、`收藏`、`切换场景` | 可不传 | 自家 App 内行为，低隐私风险 |
| `app_event_available` | int | P2 | 可选 | `1` 可用，`0` 不可用 | 可不传 | App 行为信号是否可用 |
| `user_tag` | string | P3 | 可选 | `任意`、`学生`、`母婴用户`、`女性`、`养宠物` | 可传 `任意` 或不传 | 冷启动问卷主标签 |
| `gender` | string | P3 | 可选 | `任意`、`女性`、`男性`、`不便透露` | 可传 `任意` 或不传 | 冷启动弱先验，不建议强制采集 |
| `initial_need` | string | P3 | 可选 | `学习/工作专注`、`睡眠/午休`、`放松/减压`、`运动/健身`、`通勤/出行`、`情绪陪伴`、`家庭/照护`、`游戏娱乐`、`阅读陪伴` | 可不传 | 问卷单选主需求 |
| `initial_needs` | array | P3 | 可选 | 同 `initial_need`，数组形式 | 可不传 | 问卷多选需求；后端 POC 可作为扩展字段接收 |

### 0.3 `/v1/feedback` 字段总表

| 字段 | 类型 | 优先级 | 是否必须 | 枚举/取值 | 说明 |
|---|---|---:|---:|---|---|
| `user_id` | string | P0 | 是 | 同推荐请求 `user_id` | 确保反馈写到同一个模拟用户 |
| `request_id` | string | P0 | 否但强烈建议 | 推荐接口返回/前端生成的 request id | 后端可用它找回推荐时的 context |
| `recommended_scene` | string | P0 | 是 | 18 个场景中文名之一，见下表 | 后端推荐给用户的场景 |
| `accepted_scene` | string | P1 | 否但建议 | 18 个场景中文名之一 | 用户实际接受/切换后的场景；不传默认等于推荐场景 |
| `event_type` | string | P0 | 是 | `impression`、`listen`、`like`、`dislike`、`skip`、`correction` | 用户行为类型 |
| `dwell_time_sec` | int | P1 | 建议 | 非负整数；例 `420` | 停留/播放时长，影响 reward 推断 |
| `played_ratio_pct` | float | P1 | 可选但建议 | `0.0`-`1.0`；例 `0.82` | 播放完成比例 |
| `next_action` | string | P2 | 可选 | `继续播放`、`关闭`、`用户切换场景` 等 | 后续动作描述，辅助 reward 推断 |
| `context` | object | P3 | 可选 | 同 recommend 的 `context` | 如果 `request_id` 找不到原推荐上下文，可补传 |

### 0.4 场景枚举：`recommended_scene` / `accepted_scene`

`recommended_scene` 和 `accepted_scene` 必须使用下面 18 个中文场景名之一：

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

### 0.5 第一版最小 Sensor 实现顺序

| 阶段 | 实现内容 | 覆盖字段 |
|---|---|---|
| 第 1 步 | 跑通推荐/反馈闭环 | `user_id`、`request_id`、`top_k`、`timestamp`、`hour`、`weekday`、`event_type`、`recommended_scene` |
| 第 2 步 | 低权限上下文 | `timezone`、`network`、`bluetooth` |
| 第 3 步 | 地点上下文 | `place_type`、`place_type_available`、`place_type_confidence`、`place_type_quality` |
| 第 4 步 | 运动/健康上下文 | `activity_state_available`、`activity_state`、`heart_rate_available`、`heart_rate_zone` |
| 第 5 步 | 用户真实反馈质量 | `accepted_scene`、`dwell_time_sec`、`played_ratio_pct`、`next_action` |
| 第 6 步 | 增强弱信号 | `latitude/longitude/location_accuracy_m`、`app_event`、`noise_class`、`weather`、`user_tag`、`initial_need(s)` |

`time_slot` 统一小时映射建议：

```text
05:00-10:59 -> 早晨
11:00-13:59 -> 中午
14:00-16:59 -> 下午
17:00-19:59 -> 傍晚
20:00-22:59 -> 夜晚
23:00-04:59 -> 深夜
```


## 1. 前端需要接的后端接口

第一版 POC 只需要接两个核心接口：

| 时机 | Method | Path | 作用 |
|---|---|---|---|
| 打开 App、进入推荐页、需要刷新推荐时 | `POST` | `/v1/recommend` | 上传上下文，获取 Top-K 场景 |
| 用户曝光、播放、跳过、收藏、切换场景后 | `POST` | `/v1/feedback` | 上传真实行为反馈，让后端学习偏好 |

辅助调试接口：

| Method | Path | 作用 |
|---|---|---|
| `GET` | `/health` | 后端健康检查 |
| `GET` | `/v1/scenes` | 获取 18 个场景枚举 |
| `GET` | `/v1/users/{user_id}/history` | 查看某个测试用户历史反馈摘要 |

---

## 2. `/v1/recommend` 请求结构

推荐请求整体结构：

```json
{
  "user_id": "u_001",
  "request_id": "req_001",
  "top_k": 3,
  "context": {
    "timestamp": "2026-05-26T08:35:00+08:00",
    "timezone": "Asia/Shanghai",
    "hour": 8,
    "weekday": 1,
    "network": "蜂窝数据",
    "bluetooth": "耳机",
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

---

## 3. 推荐请求顶层字段

| 字段 | 类型 | 是否需要 | 前端建议 | 说明 |
|---|---|---:|---|---|
| `user_id` | string | 必须 | 必传 | 匿名稳定用户 ID；可用多个 UUID 模拟多个账号 |
| `request_id` | string | 建议 | 每次推荐生成一个 UUID | 用来把后续 feedback 关联回这次推荐 |
| `top_k` | int | 可选 | 固定传 `3` | 后端默认 3；POC 展示 Top-3 即可 |
| `context` | object | 必须 | 必传 | 推荐上下文字段 |

注意：

- `user_id` 不要用手机号、邮箱、姓名等 PII。
- POC 测试时，一个前端可以内置多个 `user_id` 模拟不同账号和权限组合。
- 同一个模拟账号的 `user_id` 要保持稳定，否则后端学不到个性化偏好。

---

## 4. context 字段分级

### 4.1 第一版必须/强烈建议传

这些字段是低成本、低权限、后端最容易利用的字段，第一版建议全部实现。

| 字段 | 类型 | 是否建议 | 示例 | iOS 来源 | 后端用途 |
|---|---|---:|---|---|---|
| `timestamp` | string | 必传 | `2026-05-26T08:35:00+08:00` | `Date()` + ISO8601 | 推荐触发时间；可解析 hour/date/weekday |
| `timezone` | string | 建议 | `Asia/Shanghai` | `TimeZone.current.identifier` | debug、日志、时间解释 |
| `hour` | int | 建议 | `8` | `Calendar.current` | 时间规则、历史分桶 |
| `weekday` | int/string | 建议 | `1` | `Calendar.current` | 周期规律；建议 0=周一，6=周日 |
| `network` | string | 建议 | `wifi` / `蜂窝数据` | `NWPathMonitor` | 在途/可用性弱信号 |
| `bluetooth` | string | 建议 | `耳机` | `AVAudioSession` | 通勤、运动、睡眠等弱信号 |
| `place_type` | string | 建议 | `住宅区` / `在途` | CoreLocation/POI 映射 | 重要上下文信号 |
| `place_type_available` | int | 建议 | `1` / `0` | 定位是否可用 | 标记地点是否缺失 |
| `place_type_confidence` | float | 强烈建议 | `0.72` | 前端/地图映射置信度 | 低置信后端会降权 |
| `place_type_quality` | string | 建议 | `exact_or_good_mapping` | 前端映射质量 | 控制是否进入细分历史 bucket |
| `latitude` | float | 可选 | `31.2304` | CoreLocation | 用户常去地点聚类增强 |
| `longitude` | float | 可选 | `121.4737` | CoreLocation | 用户常去地点聚类增强 |
| `location_accuracy_m` | float | 可选 | `35.0` | CoreLocation horizontalAccuracy | 精度太差时后端跳过聚类 |

地点字段拿不到时，建议这样传：

```json
{
  "place_type": "任意",
  "place_type_available": 0,
  "place_type_confidence": 0.0,
  "place_type_quality": "unavailable"
}
```

经纬度增强说明：

- 经纬度不是第一版必需字段，只传 `place_type` 也能跑通。
- 如果用户授权位置且精度较好，可以传 `latitude`、`longitude`、`location_accuracy_m`。
- 后端会按 `user_id` 聚类为 `geo_cluster_id`，用于学习用户自己的常去地点 routine。
- 后端不会把经纬度作为硬规则；低精度或无权限时直接跳过，不影响推荐。

### 4.2 有权限则传，没有权限要显式标记 unavailable

| 字段 | 类型 | 是否建议 | 示例 | iOS 来源 | 拿不到时 |
|---|---|---:|---|---|---|
| `activity_state` | string | 有权限则传 | `静止` / `慢速` | CoreMotion | 传 `activity_state_available=0` |
| `activity_state_available` | int | 建议 | `1` / `0` | CoreMotion 权限/可用性 | 必传 0 更清楚 |
| `heart_rate_zone` | string | 有权限则传 | `静息` / `稍高` | HealthKit/Apple Watch | 传 `heart_rate_available=0` |
| `heart_rate_available` | int | 建议 | `1` / `0` | HealthKit 权限/设备可用性 | 必传 0 更清楚 |
| `heart_rate_quality` | string | 可选 | `fresh` / `stale_before_activity` | HealthKit 时间戳判断 | 可不传 |
| `steps_last_10min` | int | 可选 | `850` | HealthKit | 可不传 |
| `recent_workout_minutes_24h` | int | 可选 | `35` | HealthKit | 可不传 |
| `sleep_quality` | string | 可选 | `好` / `一般` / `差` | HealthKit 睡眠 | 可不传 |

健康/运动权限缺失时推荐最小写法：

```json
{
  "activity_state_available": 0,
  "heart_rate_available": 0
}
```

后端会把这些当作 missing，不会当作负证据。

### 4.3 环境字段，可选

| 字段 | 类型 | 是否建议 | 示例 | 前端实现建议 |
|---|---|---:|---|---|
| `weather` | string | 可选 | `晴` / `多云` / `小雨` | 可后续接 WeatherKit 或服务端天气 |
| `light_class` | string | 可选 | `暗光` / `明亮` | iOS 不一定稳定，第一版可不做 |
| `noise_class` | string | 可选 | `安静` / `普通` / `嘈杂` | 只上传本地分类，不上传音频 |
| `noise_available` | int | 可选 | `1` / `0` | 麦克风权限可用性 |

### 4.4 日历与 App 内行为，可选

| 字段 | 类型 | 是否建议 | 示例 | 说明 |
|---|---|---:|---|---|
| `calendar_title` | string | 可选 | `瑜伽课` / `会议` | 权限较大，第一版不建议依赖 |
| `calendar_available` | int | 可选 | `1` / `0` | 标记日历是否可用 |
| `app_event` | string | 可选 | `打开推荐页` / `播放` | 推荐先只传自家 App 内行为 |
| `app_event_available` | int | 可选 | `1` / `0` | 标记 App 行为信号是否可用 |

### 4.5 用户 profile / 冷启动问卷字段，可选

新版文档增加/强调了 profile 枚举，适合冷启动弱先验。

| 字段 | 类型 | 是否建议 | 示例 | 说明 |
|---|---|---:|---|---|
| `user_tag` | string | 可选 | `学生` / `母婴用户` / `养宠物` | 单选主标签，避免过细 |
| `gender` | string | 可选 | `女性` / `不便透露` | 不建议强制采集 |
| `initial_need` | string | 可选 | `学习/工作专注` | 问卷单选主需求 |
| `initial_needs` | array | 可选 | `["睡眠/午休", "放松/减压"]` | 问卷多选需求；当前 POC 可作为扩展字段传 |

推荐枚举：

```text
user_tag:
任意、学生、母婴用户、女性、养宠物

gender:
任意、女性、男性、不便透露

initial_need / initial_needs:
学习/工作专注
睡眠/午休
放松/减压
运动/健身
通勤/出行
情绪陪伴
家庭/照护
游戏娱乐
阅读陪伴
```

注意：profile 只作为冷启动辅助，不应覆盖实时上下文和真实反馈。

---

## 5. 枚举值清单

### 5.1 `place_type`

```text
任意
住宅区
商场
酒店
餐厅
公园
写字楼
机场
图书馆
海边
户外
在途
高铁站
地铁站
```

### 5.2 `activity_state`

```text
任意
静止
慢速
中速
高速
```

### 5.3 `heart_rate_zone`

```text
任意
静息
稍高
高
波动
```

### 5.4 `bluetooth`

```text
任意
耳机
车载蓝牙
家用音响
```

### 5.5 `network`

```text
wifi
蜂窝数据
蜂窝数据（弱）
```

### 5.6 `noise_class`

```text
安静
普通
嘈杂
```

### 5.7 `light_class`

```text
暗光
室内柔光
明亮
强光
```

---

## 6. `/v1/feedback` 请求结构

用户行为发生后调用反馈接口。

```json
{
  "user_id": "u_001",
  "request_id": "req_001",
  "recommended_scene": "通勤",
  "accepted_scene": "通勤",
  "event_type": "listen",
  "dwell_time_sec": 420,
  "played_ratio_pct": 0.82,
  "next_action": "继续播放"
}
```

字段说明：

| 字段 | 类型 | 是否需要 | 示例 | 说明 |
|---|---|---:|---|---|
| `user_id` | string | 必须 | `u_001` | 和推荐请求同一个用户 ID |
| `request_id` | string | 强烈建议 | `req_001` | 关联推荐上下文 |
| `recommended_scene` | string | 必须 | `通勤` | 后端推荐给用户的场景 |
| `accepted_scene` | string | 建议 | `跑步` | 用户最终接受/切换后的场景；不传则默认等于推荐场景 |
| `event_type` | string | 必须 | `listen` | 用户行为类型 |
| `dwell_time_sec` | int | 建议 | `420` | 停留/播放时长 |
| `played_ratio_pct` | float | 可选 | `0.82` | 播放完成比例，0-1 |
| `next_action` | string | 可选 | `继续播放` / `关闭` | 后续动作描述 |
| `context` | object | 可选 | 同 recommend context | 如果后端用 request_id 找不到推荐上下文，可补传 |

### 6.1 `event_type` 枚举建议

```text
impression -> 推荐曝光
listen     -> 实际播放/收听
like       -> 收藏/喜欢
dislike    -> 负反馈
skip       -> 跳过
correction -> 用户主动切换场景
```

注意：`impression` 只记录曝光，不会更新用户偏好；真正用于学习的是 `listen`、`like`、`dislike`、`skip`、`correction` 等后续行为。

### 6.2 什么时候发 feedback

| 用户行为 | 建议 event_type | recommended_scene | accepted_scene |
|---|---|---|---|
| 推荐卡片展示 | `impression` | 推荐场景 | 可不传或同推荐场景 |
| 用户点击播放推荐场景 | `listen` | 推荐场景 | 同推荐场景 |
| 用户收藏 | `like` | 推荐场景 | 同推荐场景 |
| 用户跳过 | `skip` | 推荐场景 | 可不传或同推荐场景 |
| 用户点不喜欢 | `dislike` | 推荐场景 | 可不传或同推荐场景 |
| 用户从推荐场景切换到另一个场景 | `correction` | 原推荐场景 | 用户切换后的场景 |
| 用户关闭页面/停止播放 | 可用 `listen` 或 `skip` | 推荐场景 | 根据停留时长判断 |

---

## 7. 后端支持的 18 个场景

`recommended_scene` 和 `accepted_scene` 必须使用以下中文场景名之一：

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

前端可以启动时调用 `/v1/scenes` 获取列表，也可以 POC 阶段内置这份枚举。

---

## 8. 多账号 / 多权限 POC 模拟

同一台 iPhone 可以通过不同 `user_id` 模拟多个账号或权限组合。

建议内置测试用户：

```text
u_full_permission       -> 地点、运动、心率都可用
u_no_health_permission  -> 健康权限不可用，只传时间/地点/网络/蓝牙
u_low_place_confidence  -> 地点低置信或 noisy mapping
u_minimal_context       -> 只传时间、网络、蓝牙
u_commuter              -> 通勤场景反馈多
u_runner                -> 跑步/健身反馈多
u_sleep                 -> 深睡眠/冥想反馈多
```

后端按 `user_id` 隔离 SQLite feedback、preference 和 history，所以：

```text
同一个设备 + 不同 user_id = 模拟不同用户/权限组
同一个 user_id + 多次 feedback = 观察个性化逐步生效
```

---

## 9. Swift 前端第一版实现范围建议

### 9.1 第一版推荐请求最小闭环

第一版建议先做到：

```text
user_id
request_id
top_k = 3
context.timestamp
context.timezone
context.hour
context.weekday
context.network
context.bluetooth
context.place_type
context.place_type_available
context.place_type_confidence
context.place_type_quality
context.activity_state_available
context.activity_state
context.heart_rate_available
context.heart_rate_zone
```

如果健康权限没有拿到：

```json
{
  "activity_state_available": 0,
  "heart_rate_available": 0
}
```

如果地点权限没有拿到：

```json
{
  "place_type_available": 0,
  "place_type": "任意",
  "place_type_confidence": 0.0,
  "place_type_quality": "unavailable"
}
```

### 9.2 第一版反馈闭环

必须实现：

```text
播放 -> /v1/feedback event_type=listen
跳过 -> /v1/feedback event_type=skip
收藏/喜欢 -> /v1/feedback event_type=like
切换场景 -> /v1/feedback event_type=correction
```

推荐同时记录：

```text
dwell_time_sec
played_ratio_pct
next_action
```

---

## 10. 不建议前端上传的东西

| 不上传 | 原因 |
|---|---|
| 手机号、邮箱、姓名 | POC 不需要 PII |
| 原始音频 | 噪音只做本地分类后传 `noise_class` |
| 未授权或低精度经纬度 | 经纬度只作为可选增强；无授权、低精度、或隐私策略不允许时不要传 |
| `ground_truth` | 只用于离线评测，不允许前端上传 |
| 过细敏感 profile | 优先用真实播放反馈学习 |

---

## 11. 推荐请求完整示例

```json
{
  "user_id": "u_full_permission",
  "request_id": "req_20260527_0001",
  "top_k": 3,
  "context": {
    "timestamp": "2026-05-27T10:40:00+08:00",
    "timezone": "Asia/Shanghai",
    "hour": 10,
    "weekday": 2,
    "network": "wifi",
    "bluetooth": "耳机",
    "place_type": "写字楼",
    "place_type_available": 1,
    "place_type_confidence": 0.78,
    "place_type_quality": "exact_or_good_mapping",
    "activity_state": "静止",
    "activity_state_available": 1,
    "heart_rate_zone": "静息",
    "heart_rate_available": 1,
    "noise_class": "普通",
    "app_event": "打开推荐页",
    "app_event_available": 1,
    "user_tag": "学生",
    "initial_need": "学习/工作专注"
  }
}
```

## 12. 反馈请求完整示例

```json
{
  "user_id": "u_full_permission",
  "request_id": "req_20260527_0001",
  "recommended_scene": "专注",
  "accepted_scene": "专注",
  "event_type": "listen",
  "dwell_time_sec": 360,
  "played_ratio_pct": 0.7,
  "next_action": "继续播放"
}
```
