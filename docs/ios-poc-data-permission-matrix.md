# iOS 前端 PoC 数据获取与权限分层

本文整理 iPhone / Swift 前端 PoC **数据获取阶段**需要采集的字段，以及这些字段分别依赖什么系统能力或用户权限。

当前阶段目标：

1. 先验证 iPhone 侧能稳定获取哪些上下文数据。
2. 先保留原始采集数据和前端派生标签。
3. 采集层先保留原始字段；上传层按 `docs/frontend-backend-payload-contract.md` 做字段映射。

注意：最新后端已经支持把经纬度作为**可选增强字段**上传，用于按 `user_id` 聚类用户自己的常去地点。前端 PoC 的采集层仍应保留本地原始字段 `lat` / `lon` / `horizontal_accuracy_m`；进入上传层时，建议在用户授权且精度足够时映射为后端 canonical 字段 `latitude` / `longitude` / `location_accuracy_m`。只传 `place_type` 仍然可以跑通。

---

## 1. 权限层级总览

| 权限层级 | 数据类别 | 代表字段 | Swift / iOS 来源 | 第一版建议 |
|---|---|---|---|---|
| 无系统权限 | 时间、时区、App 内行为 | `timestamp`、`timezone`、`hour`、`weekday`、`app_event` | `Date`、`Calendar`、`TimeZone`、App 埋点 | 必做 |
| 低权限 / 通常无弹窗 | 网络、音频输出路由 | `network`、`bluetooth` | `NWPathMonitor`、`AVAudioSession` | 建议做 |
| 定位权限 | 经纬度、定位精度、地点类型 | 采集层：`lat`、`lon`、`horizontal_accuracy_m`、`place_type`；上传层：`latitude`、`longitude`、`location_accuracy_m` | `CoreLocation`、`MapKit` | 第一版核心；经纬度上传为可选增强 |
| 运动与健身权限 | 运动状态 | `activity_state`、`activity_state_available` | `CoreMotion` | 有权限则做 |
| HealthKit 权限 | 心率、步数、运动记录、睡眠 | `heart_rate_zone`、`steps_last_10min`、`recent_workout_minutes_24h`、`sleep_quality` | `HealthKit`、Apple Watch | 后续增强 |
| 麦克风权限 | 噪音分类 | `noise_class`、`noise_available` | `AVAudioSession` / 本地音频采样 | 后续增强，隐私高 |
| 日历权限 | 日程弱信号 | `calendar_title`、`calendar_available` | `EventKit` | 后续增强，不做主链路 |
| WeatherKit / 服务端 | 天气弱信号 | `weather` | `WeatherKit` 或服务端天气 | 后续增强 |
| 用户主动输入 / 软授权 | 问卷 intent / 冷启动 | `intent`、`intent_available`、`questionnaire_available`、`user_tag`、`gender`、`initial_need`、`initial_needs` | App 表单 | 可选，但需要按“有/无问卷授权”模拟 |

---

## 2. 基础数据：无系统权限

这些数据不依赖系统隐私授权，适合作为 PoC 的最小数据采集起点。

| 数据 | 字段 | 来源 | 说明 |
|---|---|---|---|
| 当前时间 | `timestamp` | `Date()` + ISO8601 格式化 | 推荐触发或采样时间 |
| 时区 | `timezone` | `TimeZone.current.identifier` | 例如 `Asia/Shanghai` |
| 小时 | `hour` | `Calendar.current` | `0`-`23` |
| 星期 | `weekday` | `Calendar.current` | 建议前端统一为 `0=周一`，`6=周日` |
| App 内行为 | `app_event` | 自家 App 埋点 | 如 `打开推荐页`、`播放`、`跳过`、`收藏`、`切换场景` |
| App 行为可用性 | `app_event_available` | 自家 App 状态 | 可用传 `1`，不可用或未实现传 `0` |

不建议第一阶段采集或上传任何 PII，例如手机号、邮箱、姓名。

---

## 3. 低权限数据：网络与音频输出路由

### 3.1 网络

| 字段 | 来源 | 权限 | 枚举 |
|---|---|---|---|
| `network` | `NWPathMonitor` | 通常不需要用户授权 | `wifi`、`蜂窝数据`、`蜂窝数据（弱）` |

说明：

- 只需要粗粒度网络类型，不需要 SSID。
- 不建议依赖“无网络/飞行模式”作为推荐触发时刻，因为 App 需要联网才能打开和请求后端。

### 3.2 蓝牙 / 音频输出

| 字段 | 来源 | 权限 | 枚举 |
|---|---|---|---|
| `bluetooth` | 建议使用 `AVAudioSession.currentRoute` | 只判断当前音频输出路由通常不需要蓝牙扫描权限 | `任意`、`耳机`、`车载蓝牙`、`家用音响` |

说明：

- PoC 第一版建议只判断当前音频输出大类。
- 不建议扫描附近蓝牙设备，也不建议读取具体设备名；那会引入额外蓝牙权限和隐私风险。

---

## 4. 定位权限：经纬度与 `place_type`

用户已明确希望第一阶段把具体经纬度纳入要获取的数据；最新后端也支持授权后的经纬度上传增强，因此定位原始字段、上传字段和地点派生字段需要分开看。

### 4.1 原始定位数据，本地采集

| 字段 | 类型 | 来源 | 说明 |
|---|---|---|---|
| `lat` | double | `CLLocation.coordinate.latitude` | 纬度，本地原始定位数据 |
| `lon` | double | `CLLocation.coordinate.longitude` | 经度，本地原始定位数据 |
| `horizontal_accuracy_m` | double | `CLLocation.horizontalAccuracy` | 水平精度，单位米；上传层建议映射为 `location_accuracy_m` |
| `location_timestamp` | string | `CLLocation.timestamp` | 定位样本时间 |
| `location_authorization` | string | `CLLocationManager.authorizationStatus()` | 如未授权、使用期间授权等 |
| `location_accuracy_authorization` | string | `CLLocationManager.accuracyAuthorization` | 精确定位或大致定位 |

权限：

- 需要定位权限，PoC 第一版建议只申请 **使用 App 期间定位**。
- 不建议第一版申请后台定位。
- 如果用户只允许大致位置，仍可采集低精度位置，但 `place_type_confidence` 应降低。
- 上传给后端时优先使用 `latitude` / `longitude` / `location_accuracy_m`；后端也兼容 `lat` / `lon` / `horizontal_accuracy_m`。
- 建议仅在用户授权且 `horizontal_accuracy_m <= 250` 时上传经纬度；后端超过 250m 会标记 `geo_cluster_status=low_accuracy` 并跳过聚类。

### 4.2 地点类型派生数据

| 字段 | 类型 | 来源 | 后续用途 |
|---|---|---|---|
| `place_type` | string | CoreLocation 坐标 + MapKit POI / 地点类别映射 | 推荐地点上下文 |
| `place_type_available` | int | 定位和 POI 映射是否成功 | `1` 可用，`0` 不可用 |
| `place_type_confidence` | float | 前端根据定位精度、POI 距离、候选冲突等计算 | 后端低置信降权 |
| `place_type_quality` | string | 前端映射质量判断 | 是否进入细分历史 bucket |

内部枚举：

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

建议质量枚举：

```text
exact_or_good_mapping
noisy_mapping
unavailable
```

### 4.3 MapKit / POI 映射思路

推荐流程：

1. 用 `CLLocationManager` 获取当前 `lat/lon` 和 `horizontal_accuracy_m`。
2. 基于当前位置构造 MapKit 查询区域。
3. 用 MapKit / POI 候选结果获取地点类别、距离、名称等本地映射依据。
4. 将 Apple / MapKit 地点类别映射到项目内部 `place_type`。
5. 根据定位精度、POI 距离、候选冲突、停留时间或连续采样稳定性计算 `place_type_confidence`。
6. 低置信时输出 `place_type="任意"`，或 `place_type_quality="noisy_mapping"`。

示例映射方向：

| Map / POI 含义 | 内部 `place_type` |
|---|---|
| airport | `机场` |
| train station / transit station | `高铁站` / `地铁站` / `在途` |
| library | `图书馆` |
| park | `公园` |
| restaurant / cafe | `餐厅` |
| shopping mall / store | `商场` |
| lodging / hotel | `酒店` |
| office / coworking | `写字楼` |
| residential / apartment | `住宅区` |
| beach / natural feature / tourist attraction | `海边` / `户外` |

### 4.4 定位不可用时

如果无定位权限、定位失败、POI 映射失败，派生字段建议保持：

```json
{
  "place_type": "任意",
  "place_type_available": 0,
  "place_type_confidence": 0.0,
  "place_type_quality": "unavailable"
}
```

---

## 5. 运动与健身权限：CoreMotion

| 字段 | 类型 | 来源 | 权限 | 说明 |
|---|---|---|---|---|
| `activity_state` | string | `CMMotionActivityManager` | 运动与健身权限 | `任意`、`静止`、`慢速`、`中速`、`高速` |
| `activity_state_available` | int | 权限状态 / API 可用性 | 运动与健身权限 | 可用 `1`，不可用 `0` |

建议映射：

```text
stationary -> 静止
walking    -> 慢速
cycling    -> 中速
running    -> 高速
automotive -> 在途 / 通勤辅助信号
unknown    -> 任意
```

不可用时：

```json
{
  "activity_state": "任意",
  "activity_state_available": 0
}
```

---

## 6. HealthKit 权限：健康增强数据

这些字段适合作为后续增强，不应阻塞第一版 PoC。

| 字段 | 类型 | 来源 | 权限 | 说明 |
|---|---|---|---|---|
| `heart_rate_zone` | string | HealthKit heart rate samples / Apple Watch | HealthKit 心率读权限 | `任意`、`静息`、`稍高`、`高`、`波动` |
| `heart_rate_available` | int | HealthKit 权限和设备可用性 | HealthKit | 无权限或无手表传 `0` |
| `heart_rate_quality` | string | 心率样本时间戳 | HealthKit | `fresh`、`stale_before_activity` |
| `steps_last_10min` | int | HealthKit 步数，或后续评估 CoreMotion 计步 | HealthKit / 运动权限 | 弱信号 |
| `recent_workout_minutes_24h` | int | HealthKit workout | HealthKit | 24 小时内运动分钟数 |
| `sleep_quality` | string | HealthKit sleep | HealthKit 睡眠读权限 | `好`、`一般`、`差` |

健康权限缺失时：

```json
{
  "heart_rate_available": 0
}
```

如果运动状态也不可用：

```json
{
  "activity_state_available": 0,
  "heart_rate_available": 0
}
```

关键原则：

- 没有心率不等于没有运动。
- 没有 workout 不等于用户没有健身。
- 后端和前端都应把这些字段缺失视为 missing，而不是负证据。

---

## 7. 麦克风权限：噪音分类

| 字段 | 类型 | 来源 | 权限 | 说明 |
|---|---|---|---|---|
| `noise_class` | string | 本地音频采样后计算分类 | 麦克风权限 | `安静`、`普通`、`嘈杂` |
| `noise_available` | int | 麦克风权限 / 采样是否成功 | 麦克风权限 | 可用 `1`，不可用 `0` |

建议：

- 第一版可以不做。
- 如果做，只上传分类或统计值，不上传原始音频。
- 噪音受手机位置、口袋、包、手持方向影响，只能作为弱信号。

工程映射可以参考：

```text
<45 dBA  -> 安静
45-68 dBA -> 普通
>=69 dBA -> 嘈杂
```

---

## 8. 天气、光线、日历和用户问卷

### 8.1 天气

| 字段 | 来源 | 权限 / 能力 | 建议 |
|---|---|---|---|
| `weather` | WeatherKit 或服务端天气 | WeatherKit 能力；若基于当前位置则依赖定位 | 后续增强 |

天气是户外、跑步、通勤、放松等场景的弱信号，不应单独决定推荐。

### 8.2 光线

| 字段 | 来源 | 权限 / 风险 | 建议 |
|---|---|---|---|
| `light_class` | iOS 侧不一定稳定；若用相机推断则涉及相机权限 | 中/高 | 第一版不建议做 |

枚举：

```text
暗光
室内柔光
明亮
强光
```

### 8.3 日历

| 字段 | 来源 | 权限 | 建议 |
|---|---|---|---|
| `calendar_title` | EventKit | 日历权限 | 可选，权限大，不作为主链路 |
| `calendar_available` | EventKit 权限状态 | 日历权限 | 可用 `1`，不可用 `0` |

日历可作为增强信号，例如会议、瑜伽课、健身课、宝宝睡觉等，但很多用户没有日历习惯，也不一定愿意授权。

### 8.4 用户问卷 / Intent / 冷启动

| 字段 | 来源 | 权限 | 建议 |
|---|---|---|---|
| `intent` | App 表单 | 用户主动填写 / 软授权 | 用户通过问卷表达的当前或初始需求；可映射到后端 `initial_need` |
| `intent_available` | App 表单状态 | 用户主动填写 / 软授权 | 有 intent 传 `1`，跳过问卷传 `0` |
| `questionnaire_available` | App 表单状态 | 用户主动填写 / 软授权 | 问卷整体是否可用 |
| `user_tag` | App 表单 | 用户主动填写 / 软授权 | 可选 |
| `gender` | App 表单 | 用户主动填写 | 不建议强制 |
| `initial_need` | App 表单 | 用户主动填写 / 软授权 | 可选，单选主需求；当前后端已有字段 |
| `initial_needs` | App 表单 | 用户主动填写 / 软授权 | 可选，多选需求；当前后端已有字段 |

这些字段只作为冷启动弱先验，不应覆盖实时上下文和真实播放反馈。

问卷不是 iOS 系统权限，但在实验里应按一种“用户授权/用户同意”处理：用户可能填写，也可能跳过。问卷缺失时建议本地 virtual context 标记：

```json
{
  "questionnaire_available": 0,
  "intent_available": 0
}
```

上传协议未调整前，`intent` 可以落到现有 `initial_need` / `initial_needs` 字段；如果后端新增 `intent` 字段，再保持两者同义或做兼容映射。

---

## 9. 第一阶段建议采集顺序

### Step 1：无权限基础数据

```text
timestamp
timezone
hour
weekday
app_event
app_event_available
```

### Step 2：低权限设备状态

```text
network
bluetooth
```

### Step 3：定位与 MapKit 地点类型

```text
lat
lon
horizontal_accuracy_m
location_timestamp
location_authorization
location_accuracy_authorization

place_type
place_type_available
place_type_confidence
place_type_quality
```

### Step 4：运动状态

```text
activity_state
activity_state_available
```

### Step 5：健康增强

```text
heart_rate_zone
heart_rate_available
heart_rate_quality
steps_last_10min
recent_workout_minutes_24h
sleep_quality
```

### Step 6：后续可选增强

```text
weather
light_class
noise_class
noise_available
calendar_title
calendar_available
user_tag
gender
intent
intent_available
questionnaire_available
initial_need
initial_needs
```

---

## 10. 第一阶段明确不处理的内容

以下内容留到上传链路和后端联调阶段再设计：

```text
user_id 生成与持久化策略
request_id 生成策略
/v1/recommend 上传 payload
/v1/feedback 上传 payload
经纬度上传的产品开关与隐私披露文案
敏感字段脱敏策略
```

当前阶段只需要把“能采什么、依赖什么权限、采不到时如何标记”先跑通；上传层按 `docs/frontend-backend-payload-contract.md` 的字段名和隐私策略执行。
