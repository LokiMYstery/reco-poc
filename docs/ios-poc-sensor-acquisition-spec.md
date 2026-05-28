# iOS PoC Sensor 获取与字段映射规范

## Metadata

- Source workflow: `$deep-interview`
- Date: 2026-05-28
- Scope: iOS / Swift 前端 PoC 的非问卷类 context 字段获取、映射、降级与置信度规则
- Upstream SPEC: `docs/ios-frontend-poc-spec.md`
- Backend contract: `docs/frontend-backend-payload-contract.md`、`backend/FRONTEND_CONTEXT_FIELDS.md`
- Virtual user masks: `docs/ios-poc-virtual-user-permission-masks.md`

## 0. 结论性原则

本文是**可执行的唯一方案**，不是方案评审文档。它补齐 `docs/ios-frontend-poc-spec.md` 中明确留出的“低层数据获取和字段映射”缺口，并替代 `docs/ios-poc-data-permission-matrix.md` 中较粗的采集建议作为实现依据。

1. **按权限层级采集**：无权限基础字段与 App 行为 → 低权限设备状态 → 定位/地点 → Motion → HealthKit → 麦克风 → 日历 → WeatherKit。
2. **完整优先，但有总超时**：一次推荐 run 的 sensor 采集总等待上限固定为 **15 秒**。
3. **并行采集**：点击“获取推荐”后，所有已授权/可用的采集任务并行启动；到 15 秒或全部完成时生成 `RawSensorSnapshot`。
4. **超时不阻塞推荐**：15 秒到达时仍未完成的字段按本文规则标记 unavailable / omitted / stale，不继续等待。
5. **权限在 setup 阶段处理**：推荐 run 中不弹权限申请；未授权、未设置 entitlement、设备不支持，都按 unavailable 处理。
6. **不制造强假信号**：缺失不是负证据；不知道就传 `*_available=0` 或省略字段，不用默认值伪装成真实观测。
7. **前端不判断最终场景**：前端只上传可观测 context 和弱派生标签；推荐决策仍由后端完成。
8. **问卷/profile 不在本文范围**：不覆盖 `user_tag`、`gender`、`initial_need`、`initial_needs`、`intent`、`questionnaire_available` 等字段。
9. **天气只用 Apple WeatherKit**：PoC 不接第三方天气服务；WeatherKit 不可用时省略 `weather`。
10. **隐私最小化**：原始敏感数据只进本地 raw snapshot；上传层只传 backend contract 需要的粗粒度字段。

---

## 1. 一次推荐 run 的采集模型

### 1.1 时间线

```text
T0 用户点击“获取推荐”
  ├─ 立即生成 request_id / timestamp / 时间字段
  ├─ 并行读取低权限字段：network、bluetooth、app_event
  ├─ 并行读取权限字段：location、motion、health、noise、calendar
  ├─ weather 等待 location 可用后通过 WeatherKit 请求
  └─ T0+15s 或全部任务完成：冻结 RawSensorSnapshot，进入 virtual mask / upload mapping
```

### 1.2 总超时规则

| 项目 | 规范 |
|---|---|
| 总 deadline | `T0 + 15s` |
| deadline 包含 | sensor 查询、MapKit POI、WeatherKit、HealthKit、EventKit、麦克风采样 |
| deadline 不包含 | 用户在 setup/onboarding 中授权权限的时间 |
| deadline 到达 | 立即冻结已完成结果；未完成字段按 unavailable / omitted / stale 处理 |
| UI 展示 | 显示每个采集组的 started / success / unavailable / timeout / stale 状态和耗时 |

### 1.3 Raw snapshot 与上传字段分离

采集层保留原始字段，例如 `lat`、`lon`、`horizontal_accuracy_m`、`raw_weather_condition`、`heart_rate_bpm`。上传层只输出 backend contract 字段，例如 `latitude`、`longitude`、`location_accuracy_m`、`weather`、`heart_rate_zone`。

Raw snapshot 可以比上传 payload 更敏感、更细；虚拟用户 mask 从 raw snapshot 派生不同 `VirtualContext`，但上传时仍遵守本文的字段映射和缺失语义。

---

## 2. 权限层级总表

| 层级 | 字段 | iOS 来源 | 是否等待 | 上传规则 |
|---|---|---|---:|---|
| 无系统权限 | `timestamp`、`timezone`、`date`、`hour`、`weekday`、`time_slot` | `Date`、`Calendar`、`TimeZone` | 立即 | 必传/建议传 |
| 无系统权限 | `app_event`、`app_event_available`、`dwell_time_sec`、`played_ratio_pct`、`next_action` | App 内状态/埋点 | 立即 | 有事件则传 |
| 低权限 | `network` | `NWPathMonitor` + 最近一次推荐/健康检查 RTT | 最多等到总 deadline | 有结果则传；未知省略 |
| 低权限 | `bluetooth` | `AVAudioSession.currentRoute.outputs` | 立即 | 有结果则传，未知传 `任意` |
| 定位权限 | `latitude`、`longitude`、`location_accuracy_m` | `CLLocationManager` | 最多等到总 deadline | 仅 full accuracy 且 `<=250m` 上传 |
| 定位权限 + MapKit | `place_type`、`place_type_available`、`place_type_confidence`、`place_type_quality` | `CoreLocation` + `MapKit` | 最多等到总 deadline | 可用则传；不可用传 unavailable 组合 |
| Motion 权限 | `activity_state`、`activity_state_available` | `CMMotionActivityManager` | 最多等到总 deadline | 可用则传；未知传 unavailable 组合 |
| HealthKit 权限 | `heart_rate_zone`、`heart_rate_available`、`heart_rate_quality`、`steps_last_10min`、`recent_workout_minutes_24h`、`sleep_quality` | `HealthKit` | 最多等到总 deadline | 有样本则传；无权限/无样本按字段规则降级 |
| 麦克风权限 | `noise_class`、`noise_available` | `AVAudioRecorder` metering | 采样 3 秒，受总 deadline 约束 | 只传分类，不传音频 |
| 日历权限 | `calendar_title`、`calendar_available` | `EventKit` | 最多等到总 deadline | 只传规范化关键词，不传完整标题 |
| WeatherKit 能力 + 定位 | `weather` | `WeatherKit` | location 后请求，受总 deadline 约束 | 可用则传粗粒度天气；不可用省略 |
| 不采集 | `light_class` | 无可靠低侵入 iOS 环境光 API | 不等待 | PoC 默认省略 |

---

## 3. 无系统权限字段

这些字段不依赖系统隐私授权，必须在 T0 立即生成。

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `timestamp` | `triggered_at` | `Date()` | T0 立即生成 ISO8601，带时区偏移 | 例：`2026-05-28T09:40:00+08:00` | 必传，不允许缺失 |
| `timezone` | `timezone_identifier` | `TimeZone.current.identifier` | T0 立即读取 | IANA timezone，例 `Asia/Shanghai` | 读取失败则省略 |
| `date` | `local_date` | `Calendar.current` | 从 `timestamp` 按本地时区派生 | `YYYY-MM-DD` | 可省略，后端可由 `timestamp` 派生 |
| `hour` | `local_hour` | `Calendar.current.component(.hour)` | 从 `timestamp` 派生 | `0`-`23` | 建议传；失败则省略 |
| `weekday` | `local_weekday_monday0` | `Calendar.current` | 从 `timestamp` 派生 | `0=周一`，`6=周日` | 建议传；失败则省略 |
| `time_slot` | `time_slot` | 前端规则 | 从 `hour` 派生 | 见下表 | 可省略，后端可补 |

`time_slot` 固定映射：

| 小时 | `time_slot` |
|---|---|
| 05:00-10:59 | `早晨` |
| 11:00-13:59 | `中午` |
| 14:00-16:59 | `下午` |
| 17:00-19:59 | `傍晚` |
| 20:00-22:59 | `夜晚` |
| 23:00-04:59 | `深夜` |

---

## 4. App 内行为字段

这些不是系统 sensor，但属于低风险上下文。它们必须来自自家 App 行为，不读取其它 App 或系统行为。

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `app_event` | `current_app_event` | App state / analytics | T0 立即读取当前触发事件 | `打开推荐页`、`点击某场景`、`搜索关键词`、`播放`、`跳过`、`收藏`、`切换场景`、`手动获取推荐` | 不知道则省略 |
| `app_event_available` | `app_event_available` | App state | `app_event` 非空则 1 | `1` / `0` | 未实现或未知传 `0` |
| `dwell_time_sec` | `dwell_time_sec` | App 内页面停留计时 | feedback 时读取；recommend context 默认不传 | 非负整数秒 | 没有明确停留事件则省略 |
| `played_ratio_pct` | `played_ratio_pct` | App 播放器 | feedback 时读取；recommend context 默认不传 | `0.0`-`1.0` | 没有播放事件则省略 |
| `next_action` | `next_action` | App 内用户动作 | feedback 时读取；recommend context 默认不传 | `继续播放`、`关闭`、`用户切换场景` 等 | 没有后续动作则省略 |

规范：

- 推荐请求的默认 `app_event` 为 `手动获取推荐`。
- `dwell_time_sec`、`played_ratio_pct`、`next_action` 主要属于 `/v1/feedback` 行为字段；不要为了推荐请求伪造。

---

## 5. 低权限设备状态

### 5.1 网络：`network`

| 项目 | 规范 |
|---|---|
| 权限层级 | 低权限，通常无用户弹窗 |
| iOS 来源 | `NWPathMonitor.currentPath`；弱网判断使用最近一次后端健康检查或推荐请求 RTT，不为了 sensor 额外发 blocking 请求 |
| Raw 字段 | `network_interface_type`、`network_is_expensive`、`network_is_constrained`、`last_backend_rtt_ms`、`network_status` |
| 上传字段 | `network` |
| 等待策略 | run 开始时读取当前 path；如果 monitor 尚无 path，等到总 deadline 内第一个 update；弱网判断只读取已有 RTT 或本次推荐请求实际 RTT，不单独阻塞采集 |

映射规则：

| 条件 | `network` |
|---|---|
| `path.usesInterfaceType(.wifi)` | `wifi` |
| `path.usesInterfaceType(.cellular)` 且最近/本次后端 RTT `>1500ms`，或最近请求失败但 path 仍 satisfied | `蜂窝数据（弱）` |
| `path.usesInterfaceType(.cellular)` | `蜂窝数据` |
| 其它 satisfied path | `wifi` |
| deadline 前无 path / path unsatisfied | 省略 `network` |

说明：

- iOS 不提供通用蜂窝信号强度 API；`蜂窝数据（弱）` 只能用 App 自己到后端的 RTT/失败作为弱网代理。
- 不读取 SSID，不上传 Wi-Fi 名称。

### 5.2 音频输出路由：`bluetooth`

| 项目 | 规范 |
|---|---|
| 权限层级 | 低权限；只读当前音频 route，不扫描蓝牙设备 |
| iOS 来源 | `AVAudioSession.sharedInstance().currentRoute.outputs` |
| Raw 字段 | `audio_output_port_type`、`audio_output_port_name_local_only` |
| 上传字段 | `bluetooth` |
| 等待策略 | T0 立即读取；无需等待 |

映射规则：

| 条件 | `bluetooth` |
|---|---|
| `portType == .carAudio`，或本地 `portName` 命中 `car` / `车` / `CarPlay` / 常见车品牌关键词 | `车载蓝牙` |
| `portType == .airPlay`，或本地 `portName` 命中 `HomePod` / `Speaker` / `音箱` | `家用音响` |
| `portType` 属于 `.bluetoothA2DP` / `.bluetoothLE` / `.bluetoothHFP` / `.headphones` / `.headsetMic` | `耳机` |
| 内置扬声器、听筒、未知、无输出 | `任意` |

隐私规则：

- 可以在本地用 `portName` 做关键词分类，但不得上传具体设备名。
- 不使用 CoreBluetooth 扫描附近设备。

---

## 6. 定位与地点字段

### 6.1 原始定位与上传经纬度

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/规则 | 缺失规则 |
|---|---|---|---|---|---|
| `latitude` | `lat` | `CLLocation.coordinate.latitude` | 使用 `requestLocation()` 请求一次当前位置；等待到总 deadline，持续保留 best sample | 仅当 full accuracy 且 `0 <= horizontal_accuracy_m <= 250` 上传 | 否则省略 |
| `longitude` | `lon` | `CLLocation.coordinate.longitude` | 同上 | 同 `latitude` | 否则省略 |
| `location_accuracy_m` | `horizontal_accuracy_m` | `CLLocation.horizontalAccuracy` | 同上 | 与经纬度一起上传 | 否则省略 |

Raw snapshot 还必须保留：

| Raw 字段 | 来源 | 用途 |
|---|---|---|
| `location_timestamp` | `CLLocation.timestamp` | 判断样本新鲜度 |
| `location_authorization` | `CLLocationManager.authorizationStatus()` | mask 和 debug |
| `location_accuracy_authorization` | `CLLocationManager.accuracyAuthorization` | 判断 precise / reduced |
| `location_age_sec` | `T0 - location_timestamp` | 置信度计算 |

定位策略：

1. setup 阶段只申请“使用 App 期间定位”。
2. run 阶段不申请后台定位。
3. `desiredAccuracy = kCLLocationAccuracyBest`，但必须接受 iOS 返回较低精度样本。
4. 在 15 秒内选择 `horizontal_accuracy_m` 最小且 `location_age_sec <= 120` 的 best sample。
5. 如果 `accuracyAuthorization == reducedAccuracy`，raw snapshot 可保留粗位置；上传层可在 virtual user 需要 approximate location 调试时传 `location_accuracy_m` 很大的 coarse coordinate，但默认 full-permission 用户不传 `latitude/longitude/location_accuracy_m`，避免低精度污染 geo cluster。
6. 如果 full accuracy 但 `horizontal_accuracy_m > 250`，raw 保留，上传经纬度省略；地点类型可继续按低置信尝试。

### 6.2 地点类型：`place_type_*`

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 缺失规则 |
|---|---|---|---|---|
| `place_type` | `raw_place_type_candidate` | CoreLocation + MapKit POI + 本地映射表 | location best sample 后启动 MapKit 查询；受总 deadline 约束 | 不可用传 `任意` |
| `place_type_available` | `place_type_available` | 前端派生 | 有可解释候选且 confidence `>=0.35` 为 1 | 无权限/失败/低于 0.35 传 `0` |
| `place_type_confidence` | `place_type_confidence` | 前端公式 | 见下方公式 | 不可用传 `0.0` |
| `place_type_quality` | `place_type_quality` | 前端派生 | 见下方阈值 | 不可用传 `unavailable` |

内部枚举固定为：

```text
任意、住宅区、商场、酒店、餐厅、公园、写字楼、机场、图书馆、海边、户外、在途、高铁站、地铁站
```

#### 6.2.1 MapKit 查询与硬编码映射

使用 `MKLocalSearch` / `MKLocalPointsOfInterestRequest` 在当前位置附近查询 POI，读取 `MKMapItem.pointOfInterestCategory`、`name`、`placemark`、距离。Apple Maps / MapKit 不能保证所有项目都有 POI category；`pointOfInterestCategory == nil` 时必须降置信。

| MapKit / 本地判定 | `place_type` |
|---|---|
| `.airport` 或名称含“机场” | `机场` |
| `.publicTransport` 且名称含“地铁”/`metro`/`subway` | `地铁站` |
| `.publicTransport` 且名称含“高铁”/“火车”/`rail`/`train` | `高铁站` |
| `.publicTransport` 但无法区分 | `在途` |
| `.library` | `图书馆` |
| `.park` / `.nationalPark` | `公园` |
| `.restaurant` / `.cafe` / `.bakery` / `.foodMarket` | `餐厅` |
| `.store` / `.shoppingCenter` | `商场` |
| `.hotel` | `酒店` |
| `.beach` / 名称含“海滩”/“海边” | `海边` |
| `.fitnessCenter` / `.stadium` | `户外`（具体健身/跑步由 motion/health 辅助，不在 place_type 中新增枚举） |
| `.school` / `.university` 且名称含 library / 图书馆 | `图书馆`（低置信） |
| `.school` / `.university` 但无图书馆关键词 | `任意` |
| 名称/地址含 office / coworking / 写字楼 / 科技园 / 园区 | `写字楼` |
| 名称/地址含 apartment / residential / 小区 / 公寓 / 住宅 | `住宅区` |
| 当前 `activity_state` 为汽车/高速移动，且无强 POI | `在途` |
| 无候选或候选冲突严重 | `任意` |

#### 6.2.2 `place_type_confidence` 公式

```text
confidence = clamp(
  0.40 * accuracy_score +
  0.35 * poi_score +
  0.15 * stability_score +
  0.10 * motion_score -
  conflict_penalty,
  0.0,
  1.0
)
```

`accuracy_score`：

| 定位情况 | score |
|---|---:|
| full accuracy 且 `<=50m` | 1.00 |
| full accuracy 且 `<=100m` | 0.85 |
| full accuracy 且 `<=250m` | 0.65 |
| reduced accuracy 或 `250m-1000m` | 0.35 |
| `>1000m` 或 location age `>120s` | 0.20 |
| 无定位 | 0.00 |

`poi_score`：

| POI 情况 | score |
|---|---:|
| 单一强 POI，距离 `<= max(50m, accuracy*1.2)` | 1.00 |
| 单一可用 POI，距离 `<= max(150m, accuracy*2)` | 0.75 |
| POI category 可映射但距离较远/名称弱匹配 | 0.55 |
| 只有地址/关键词推断，无明确 POI category | 0.40 |
| 无 POI | 0.20 |

`stability_score`：

| 稳定性 | score |
|---|---:|
| 最近 10 分钟内同一 `place_type` 出现 2 次以上且相距至少 30 秒 | 1.00 |
| 本次 run 有两个连续样本落在同一 POI 半径内 | 0.75 |
| 只有一个样本 | 0.50 |
| 样本跳动或新旧样本冲突 | 0.20 |

`motion_score`：

| Motion / route 辅助 | score |
|---|---:|
| `activity_state` 支持当前类型，例如静止 + 商场/图书馆/写字楼 | 0.80 |
| automotive / 高速移动 + `在途` | 0.90 |
| 无 motion 数据 | 0.50 |
| motion 与候选冲突，例如高速移动 + 餐厅 | 0.20 |

`conflict_penalty`：

| 冲突 | penalty |
|---|---:|
| 无明显冲突 | 0.00 |
| 两个不同类别 POI 距离接近且都强匹配 | 0.15 |
| reduced accuracy 下映射到细粒度 POI | 0.20 |
| 样本 age `>120s` 仍试图映射 | 0.25 |

质量阈值：

| 条件 | 上传字段 |
|---|---|
| `confidence >= 0.70` | `place_type_available=1`、`place_type_quality=exact_or_good_mapping` |
| `0.35 <= confidence < 0.70` | `place_type_available=1`、`place_type_quality=noisy_mapping` |
| `confidence < 0.35` 或无候选 | `place_type=任意`、`place_type_available=0`、`place_type_confidence=0.0`、`place_type_quality=unavailable` |

---

## 7. Motion 权限：运动状态

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `activity_state` | `raw_motion_activity` | `CMMotionActivityManager` | 并行查询 `[T0-10min, T0]` 历史活动，同时监听当前 update；选择最新 high/medium confidence 结果 | `任意`、`静止`、`慢速`、`中速`、`高速` | 不可用传 `任意` |
| `activity_state_available` | `activity_state_available` | 权限/API/样本可用性 | 有 medium/high confidence 样本则 1 | `1` / `0` | 无权限、无样本、低置信传 `0` |

映射规则：

| CoreMotion | `activity_state` | 备注 |
|---|---|---|
| `stationary` | `静止` | 静止、坐着、站立都归此类 |
| `walking` | `慢速` | 走路 |
| `running` | `高速` | 跑步 |
| `cycling` | `中速` | 骑行 |
| `automotive` | `高速` | 同时可辅助 `place_type=在途` / 通勤 |
| `unknown` 或 low confidence | `任意` | `activity_state_available=0` |

说明：

- CoreMotion 历史活动可能有延迟；本文只用它作为弱上下文，不作为实时运动真值。
- 没有 motion 不等于用户没有运动。

---

## 8. HealthKit 权限：健康增强字段

HealthKit 字段全部是弱信号。必须有用户授权；没有 Apple Watch 或没有样本时按 missing 处理。

### 8.1 心率：`heart_rate_*`

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `heart_rate_zone` | `heart_rate_bpm`、`heart_rate_sample_at` | HealthKit `.heartRate` latest sample | 查询最近 6 小时最新样本；如果 15 秒 deadline 前无结果则 unavailable | `任意`、`静息`、`稍高`、`高`、`波动` | 不可用传 `任意` 或省略；同时 `heart_rate_available=0` |
| `heart_rate_available` | `heart_rate_available` | HealthKit 权限 + 样本 | 有 6 小时内样本为 1 | `1` / `0` | 无权限/无样本/超时传 `0` |
| `heart_rate_quality` | `heart_rate_age_sec` | 前端派生 | 根据样本 age 与 motion 判断 | `fresh`、`stale_before_activity` | unavailable 时省略 |

心率质量：

| 条件 | `heart_rate_quality` | `heart_rate_available` |
|---|---|---:|
| 样本 age `<=10min` | `fresh` | 1 |
| `10min < age <=6h` | `stale_before_activity` | 1 |
| `age >6h` 或无样本 | 省略 | 0 |

心率区间：

| 条件 | `heart_rate_zone` |
|---|---|
| 最近 10 分钟内至少 3 个样本，max-min `>=25 bpm` | `波动` |
| latest bpm `<85` | `静息` |
| latest bpm `85-110` | `稍高` |
| latest bpm `>110` | `高` |
| 无可用样本 | `任意` |

注意：

- 这不是医疗分级；只服务推荐上下文。
- `stale_before_activity` 表示“只知道上一次心率”，不是实时心率。后端应弱化使用。

### 8.2 步数：`steps_last_10min`

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射 | 缺失规则 |
|---|---|---|---|---|---|
| `steps_last_10min` | `steps_last_10min_raw` | 首选 HealthKit `.stepCount`；HealthKit 不可用但 Motion 授权时可用 `CMPedometer` fallback | 查询 `[T0-10min, T0]` cumulative steps | 非负整数，四舍五入 | 无权限/无样本/超时则省略 |

规范：

- 优先 HealthKit，因为它能合并 iPhone / Watch 数据。
- fallback 到 `CMPedometer` 时，raw snapshot 记录 `steps_source=coremotion_pedometer`。
- 不要用缺失表示“没走路”；只有确认窗口内步数为 0 时才传 `0`，否则省略。

### 8.3 24 小时运动：`recent_workout_minutes_24h`

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射 | 缺失规则 |
|---|---|---|---|---|---|
| `recent_workout_minutes_24h` | `workout_minutes_24h_raw` | HealthKit `HKWorkout` | 查询与 `[T0-24h, T0]` 重叠的 workout，累计重叠分钟数 | 非负整数分钟 | 无权限/无 workout 样本则省略；确认有权限且无运动可传 `0` |

说明：没有 workout 不等于用户没有健身；很多运动不会被记录为 workout。

### 8.4 睡眠：`sleep_quality`

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `sleep_quality` | `sleep_asleep_minutes`、`sleep_awake_minutes`、`sleep_ended_at` | HealthKit sleep category samples | 查询最近 36 小时最近一次睡眠段 | `好`、`一般`、`差` | 无权限/无样本/超时则省略 |

映射规则：

| 条件 | `sleep_quality` |
|---|---|
| asleep `>=420min` 且 awake/fragmentation `<=30min` | `好` |
| asleep `300-419min` 或 awake/fragmentation `31-60min` | `一般` |
| asleep `<300min` 或 awake/fragmentation `>60min` | `差` |

说明：这只是推荐弱信号，不做健康判断。

---

## 9. 麦克风权限：噪音分类

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `noise_class` | `noise_median_dbfs`、`noise_p95_dbfs` | `AVAudioRecorder` metering | 麦克风授权后采样 3 秒；前 0.5 秒 warmup；不保存音频文件 | `安静`、`普通`、`嘈杂` | 不可用时省略 |
| `noise_available` | `noise_available` | 麦克风权限 + 采样成功 | 采样成功为 1 | `1` / `0` | 无权限/失败/超时传 `0` |

采样规范：

1. 使用 `AVAudioSession` 的录音能力，只开启本地 metering。
2. `AVAudioRecorder.isMeteringEnabled = true`。
3. 每 100ms 调用 `updateMeters()`，读取 `averagePower(forChannel: 0)`。
4. 只保留统计值，不保存、不上传原始音频。
5. 由于 iPhone 未校准为声级计，本文使用 **dBFS 相对阈值**，不宣称 dBA。

映射规则：

| `median averagePower` | `noise_class` |
|---:|---|
| `<= -50 dBFS` | `安静` |
| `>-50` 且 `<= -30 dBFS` | `普通` |
| `> -30 dBFS` | `嘈杂` |

---

## 10. 日历权限：弱意图信号

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `calendar_title` | `calendar_event_title_raw_local_only`、`calendar_keyword` | `EventKit` | iOS 17+ 请求 full access；iOS 16 及以下使用 events access；查询 `[T0-15min, T0+60min]` 内当前/即将开始事件 | 上传规范化关键词，不上传完整标题 | 不可用时省略 |
| `calendar_available` | `calendar_available` | EventKit 授权 + 查询结果 | 有日历读取权限且查询成功为 1 | `1` / `0` | 无权限/失败/超时传 `0` |

事件选择规则：

1. 优先选择当前正在进行且未标记为 all-day 的事件。
2. 如果没有当前事件，选择 30 分钟内即将开始的事件。
3. 多个事件冲突时，选择最早开始且标题命中关键词的事件。
4. 不上传完整 event title，只上传关键词归一化结果到 `calendar_title`。

关键词归一化：

| 标题本地关键词 | `calendar_title` |
|---|---|
| 会议、meeting、sync、review、面试 | `会议` |
| 瑜伽、yoga | `瑜伽课` |
| 健身、训练、workout、gym | `健身` |
| 跑步、run | `跑步` |
| 学习、课程、class、lecture | `学习` |
| 睡觉、nap、午休 | `睡眠` |
| 宝宝、婴儿、哄睡 | `婴儿照护` |
| 宠物、遛狗、猫 | `宠物陪伴` |
| 其它非空标题 | `日程` |

说明：日历权限较敏感；它只作为弱信号，不作为第一推荐依据。

---

## 11. WeatherKit：天气弱信号

| 上传字段 | Raw 字段 | 来源 | 获取策略 | 映射/枚举 | 缺失规则 |
|---|---|---|---|---|---|
| `weather` | `raw_weather_condition`、`weather_temperature_c`、`weather_fetched_at` | Apple `WeatherKit` `WeatherService` | 需要 WeatherKit capability；等待可用 location 后请求 current weather；受 15 秒总 deadline 约束 | 粗粒度中文天气枚举 | WeatherKit 不可用、无定位、超时、失败则省略 |

能力要求：

- App target 必须启用 WeatherKit entitlement / capability。
- 运行系统需满足 WeatherKit 支持版本：iOS 16+。
- WeatherKit 是 Apple Weather 服务，不是第三方天气服务。
- WeatherKit 基于位置请求天气；没有可用定位时不获取天气。

映射规则：

| WeatherKit condition 类别 | `weather` |
|---|---|
| clear / mostlyClear | `晴` |
| partlyCloudy / mostlyCloudy / cloudy | `多云` |
| drizzle / light rain | `小雨` |
| rain | `中雨` |
| heavyRain | `大雨` |
| snow / sleet / wintryMix | `雪` |
| fog / haze / smoke | `雾` |
| windy / breezy | `大风` |
| thunderstorm / isolatedThunderstorms / scatteredThunderstorms / strongStorms | `雷雨` |
| 其它或未知 | 省略 `weather` |

说明：天气是弱信号；不要因为下雨就直接推荐某个场景。

---

## 12. 光线：`light_class`

`light_class` 在 backend contract 中存在，但 PoC 默认**不采集、不上传**。

| 项目 | 规范 |
|---|---|
| 字段 | `light_class` |
| 决策 | 第一版省略 |
| 原因 | iOS 没有稳定、低侵入、公开的环境光强度 API；`UIScreen.brightness` 是屏幕亮度设置，不等于环境光；相机推断会引入相机权限和明显隐私/体验成本 |
| 缺失规则 | 直接省略 `light_class`，不要传 `暗光` / `明亮` 等猜测值 |

---

## 13. Virtual Mask 消费规则

本文只定义 raw sensor 获取和上传字段映射；虚拟用户 mask 必须消费同一份 `RawSensorSnapshot`，不得为不同虚拟用户重新采集 sensor。

| Mask 维度 | 处理规则 |
|---|---|
| `location=full` | 按本文定位规则输出 `latitude` / `longitude` / `location_accuracy_m` 和 `place_type_*`。 |
| `location=approximate` | 允许保留 coarse coordinate 与大 `location_accuracy_m` 供低精度实验；`place_type_confidence` 必须降到 `0.25-0.55` 区间，`place_type_quality=noisy_mapping`。 |
| `location=none` | 删除经纬度和 `location_accuracy_m`；`place_type=任意`、`place_type_available=0`、`place_type_confidence=0.0`、`place_type_quality=unavailable`。 |
| `motion=none` | `activity_state=任意`、`activity_state_available=0`。 |
| `health=none` | 删除 HealthKit 数值字段；`heart_rate_zone=任意`、`heart_rate_available=0`。 |
| `health=steps_only` | 只保留 `steps_last_10min`，删除心率、workout、sleep。 |
| `microphone=none` | 删除 `noise_class`；`noise_available=0`。 |
| `calendar=none` | 删除 `calendar_title`；`calendar_available=0`。 |
| `audio_route=unknown` | `bluetooth=任意`。 |
| `network=weak_cellular` | 强制 `network=蜂窝数据（弱）`，用于实验对照。 |

缺失字段仍按 missing 处理，不得把 mask 后的缺失解释为用户没有运动、没有日程、环境安静或不在某地点。

---

## 14. 上传 payload 映射总表

| Backend context 字段 | 是否覆盖 | 上传策略 |
|---|---:|---|
| `timestamp` | 是 | 必传，T0 ISO8601 |
| `timezone` | 是 | 建议传，读取失败省略 |
| `date` | 是 | 可传，由 timestamp 派生 |
| `hour` | 是 | 建议传，由 timestamp 派生 |
| `weekday` | 是 | 建议传，`0=周一` |
| `time_slot` | 是 | 可传，按固定小时表派生 |
| `place_type` | 是 | 可用则传映射值；不可用传 `任意` |
| `place_type_available` | 是 | 可用 `1`，不可用 `0` |
| `place_type_confidence` | 是 | 公式计算；不可用 `0.0` |
| `place_type_quality` | 是 | `exact_or_good_mapping` / `noisy_mapping` / `unavailable` |
| `latitude` | 是 | 仅 full accuracy 且 `<=250m` 上传 |
| `longitude` | 是 | 同 `latitude` |
| `location_accuracy_m` | 是 | 与经纬度一起上传 |
| `lat` / `lon` / `horizontal_accuracy_m` | 是 | 只作为 raw/兼容别名；新前端上传 canonical 字段 |
| `activity_state` | 是 | 有 medium/high confidence motion 则传；否则 `任意` |
| `activity_state_available` | 是 | motion 可用 `1`，否则 `0` |
| `heart_rate_zone` | 是 | 6 小时内样本可用则传；否则 `任意` 或省略 |
| `heart_rate_available` | 是 | 心率样本可用 `1`，否则 `0` |
| `heart_rate_quality` | 是 | `fresh` / `stale_before_activity`；不可用省略 |
| `steps_last_10min` | 是 | 有 HealthKit/CMPedometer 样本则传 |
| `recent_workout_minutes_24h` | 是 | 有 HealthKit workout 权限/结果则传 |
| `sleep_quality` | 是 | 有 HealthKit sleep 样本则传 |
| `weather` | 是 | WeatherKit 可用且定位可用则传；否则省略 |
| `light_class` | 是 | PoC 默认省略，不采集 |
| `noise_class` | 是 | 麦克风采样成功则传 |
| `noise_available` | 是 | 采样成功 `1`，否则 `0` |
| `bluetooth` | 是 | 当前 route 映射；未知 `任意` |
| `network` | 是 | path 可用则传；未知省略 |
| `calendar_title` | 是 | 只传规范化关键词；不可用省略 |
| `calendar_available` | 是 | EventKit 日历读取权限 + 查询成功 `1`，否则 `0` |
| `app_event` | 是 | 有 App 事件则传；推荐触发默认 `手动获取推荐` |
| `app_event_available` | 是 | 有事件 `1`，否则 `0` |
| `user_tag` / `gender` / `initial_need` / `initial_needs` | 否 | 问卷/profile，本文不覆盖 |

---

## 15. 推荐请求示例

```json
{
  "user_id": "u_full_permission",
  "request_id": "req_20260528_094000",
  "top_k": 3,
  "context": {
    "timestamp": "2026-05-28T09:40:00+08:00",
    "timezone": "Asia/Shanghai",
    "date": "2026-05-28",
    "hour": 9,
    "weekday": 3,
    "time_slot": "早晨",
    "network": "wifi",
    "bluetooth": "耳机",
    "place_type": "写字楼",
    "place_type_available": 1,
    "place_type_confidence": 0.76,
    "place_type_quality": "exact_or_good_mapping",
    "latitude": 31.2304,
    "longitude": 121.4737,
    "location_accuracy_m": 35.0,
    "activity_state": "静止",
    "activity_state_available": 1,
    "heart_rate_zone": "静息",
    "heart_rate_available": 1,
    "heart_rate_quality": "fresh",
    "steps_last_10min": 120,
    "recent_workout_minutes_24h": 0,
    "weather": "多云",
    "noise_class": "普通",
    "noise_available": 1,
    "calendar_title": "会议",
    "calendar_available": 1,
    "app_event": "手动获取推荐",
    "app_event_available": 1
  }
}
```

不可用示例：

```json
{
  "context": {
    "timestamp": "2026-05-28T09:40:00+08:00",
    "timezone": "Asia/Shanghai",
    "hour": 9,
    "weekday": 3,
    "time_slot": "早晨",
    "bluetooth": "任意",
    "place_type": "任意",
    "place_type_available": 0,
    "place_type_confidence": 0.0,
    "place_type_quality": "unavailable",
    "activity_state": "任意",
    "activity_state_available": 0,
    "heart_rate_zone": "任意",
    "heart_rate_available": 0,
    "noise_available": 0,
    "calendar_available": 0,
    "app_event": "手动获取推荐",
    "app_event_available": 1
  }
}
```

---

## 16. 实现验收清单

- [ ] 每次 run 使用统一 `T0 + 15s` deadline。
- [ ] 所有 sensor 任务并行启动，不串行等待导致超时。
- [ ] 权限弹窗只在 setup/maintenance 中触发，不在推荐 run 中阻塞。
- [ ] 经纬度只在 full accuracy 且 `location_accuracy_m <= 250` 时上传。
- [ ] `place_type_confidence` 使用本文公式，低置信不伪装为高置信。
- [ ] HealthKit 心率允许使用最近样本，但必须写 `heart_rate_quality`。
- [ ] 麦克风只上传噪音分类，不保存/上传音频。
- [ ] 日历只上传归一化关键词，不上传完整标题。
- [ ] Weather 只用 Apple WeatherKit；失败则省略，不接第三方。
- [ ] `light_class` 第一版不采集、不上传。
- [ ] 问卷/profile 字段不在本文实现范围。
- [ ] 虚拟用户 mask 只裁剪/降级 raw snapshot，不重新发起 sensor 采集。

---

## 17. 参考资料

- Apple Developer: WeatherKit — `https://developer.apple.com/weatherkit/`
- Apple Developer Documentation: WeatherKit framework — `https://developer.apple.com/documentation/weatherkit`
- Apple Developer Documentation: WeatherKit entitlement — `https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.weatherkit`
- Apple Developer Documentation: Core Location — `https://developer.apple.com/documentation/corelocation`
- Apple Developer Documentation: `CLLocationManager.requestLocation()` — `https://developer.apple.com/documentation/corelocation/cllocationmanager/requestlocation()`
- Apple Developer Documentation: MapKit local search — `https://developer.apple.com/documentation/mapkit/mklocalsearch`
- Apple Developer Documentation: Core Motion `CMMotionActivityManager` — `https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager`
- Apple Developer Documentation: HealthKit — `https://developer.apple.com/documentation/healthkit`
- Apple Developer Documentation: AVFAudio `AVAudioSession` / audio routing — `https://developer.apple.com/documentation/avfaudio/avaudiosession`
- Apple Developer Documentation: `AVAudioRecorder` metering — `https://developer.apple.com/documentation/avfaudio/avaudiorecorder`
- Apple Developer Documentation: EventKit — `https://developer.apple.com/documentation/eventkit`
