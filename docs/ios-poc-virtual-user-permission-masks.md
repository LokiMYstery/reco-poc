# iOS 前端 PoC 虚拟用户与 Permission Mask 方案

本文定义前端 PoC 如何在一台 iPhone、一个真实实验用户授予全部权限的前提下，派生多个“虚拟用户”，用来模拟真实线上用户可能出现的不同授权组合。

目标：

1. 真实设备尽量采集完整 raw sensor snapshot。
2. 每个虚拟用户通过 permission mask 从同一份 raw snapshot 派生出不同 virtual context。
3. 用这些 virtual context 考察推荐系统在权限缺失、低置信、健康数据不完整等情况下的鲁棒性。
4. 当前文档只定义虚拟 context 派生规则；后续上传、`user_id` 持久化和反馈学习链路另行设计。

---

## 1. 总体思路

实验用户会在真机上尽量授予所有权限：

```text
Location
Precise Location
Motion & Fitness
HealthKit
Microphone，可选
Calendar，可选
```

前端先生成一份完整的真实采集快照：

```text
RawSensorSnapshot
```

然后对同一份 `RawSensorSnapshot` 应用多个 mask：

```text
RawSensorSnapshot
  -> mask_full_permission
  -> mask_minimal_context
  -> mask_no_location
  -> mask_approx_location
  -> mask_location_only_no_health
  -> mask_motion_only_no_health
  -> mask_steps_only_no_hr_sleep
  -> mask_no_watch_health_partial
  -> mask_no_calendar_no_microphone
  -> mask_calendar_enabled
  -> mask_noise_enabled
  -> mask_no_bluetooth_route
  -> mask_weak_cellular_commuter
  -> mask_home_speaker_no_health
  -> mask_full_no_questionnaire
  -> mask_intent_only_minimal_context
```

每个 mask 输出一份独立的：

```text
VirtualContext
```

进入上传和推荐链路时，每个虚拟用户应绑定一个稳定的虚拟 `user_id`，这样后端的偏好、history 和最新 geo cluster 都按虚拟用户隔离学习；本阶段主要关注 context 的生成。

---

## 2. RawSensorSnapshot 建议包含的原始数据

真实采集层尽量保留完整数据，供 mask 层裁剪。

| 类别 | 原始字段 | 说明 |
|---|---|---|
| 时间 | `timestamp`、`timezone`、`hour`、`weekday` | 无权限，所有虚拟用户都保留 |
| 网络 | `network` | `wifi` / `蜂窝数据` / `蜂窝数据（弱）` |
| 音频输出 | `bluetooth` | `耳机` / `车载蓝牙` / `家用音响` / `任意` |
| 定位原始数据 | `lat`、`lon`、`horizontal_accuracy_m`、`location_timestamp` | 本地原始定位数据 |
| 定位权限状态 | `location_authorization`、`location_accuracy_authorization` | 用于模拟 full / approximate / denied |
| 地点派生 | `place_type`、`place_type_confidence`、`place_type_quality` | 由 CoreLocation + MapKit / POI 映射得到 |
| 运动 | `activity_state`、`activity_confidence` | CoreMotion |
| 健康 | `heart_rate_zone`、`heart_rate_quality`、`steps_last_10min`、`recent_workout_minutes_24h`、`sleep_quality` | HealthKit / Apple Watch |
| 噪音 | `noise_class`、`noise_db` | 麦克风采样后本地分类，可选 |
| 日历 | `calendar_title`、`calendar_keyword` | EventKit，可选 |
| 问卷意图 | `intent`、`initial_need`、`initial_needs`、`user_tag`、`gender`、`questionnaire_submitted_at` | 用户主动填写；作为一种软授权/用户同意维度 |
| App 内行为 | `app_event`、`dwell_time_sec`、`played_ratio_pct` | 自家 App 埋点 |

注意：

- `RawSensorSnapshot` 可以包含敏感原始数据。
- `VirtualContext` 不一定包含全部原始数据。
- 最新后端已支持授权后的经纬度可选上传；上传层建议把 `lat/lon/horizontal_accuracy_m` 映射为 `latitude/longitude/location_accuracy_m`。

---

## 3. Permission Mask 维度

每个虚拟用户本质上是一组 mask 配置。

| 维度 | 可选值 | 影响字段 |
|---|---|---|
| `location` | `full` / `approximate` / `none` | 采集层 `lat`、`lon`、`horizontal_accuracy_m`；上传层 `latitude`、`longitude`、`location_accuracy_m`；以及 `place_type_*` |
| `motion` | `full` / `none` | `activity_state`、`activity_state_available` |
| `health` | `full` / `steps_only` / `no_watch` / `none` | `heart_rate_*`、`steps_last_10min`、`recent_workout_minutes_24h`、`sleep_quality` |
| `microphone` | `full` / `none` | `noise_class`、`noise_available` |
| `calendar` | `full` / `none` | `calendar_title`、`calendar_available` |
| `audio_route` | `full` / `unknown` | `bluetooth` |
| `network` | `full` / `weak_cellular` | `network` |
| `questionnaire` | `full` / `basic` / `none` | `intent`、`initial_need`、`initial_needs`、`user_tag`、`gender`、`questionnaire_available` |

说明：

- 问卷不是 iOS 系统权限，但实验上应当按“用户是否愿意填写/授权意图信息”处理。
- 本文用 `intent` 泛指用户通过问卷表达的当前或初始需求。
- 当前后端已有 `initial_need` / `initial_needs`，上传时可以把 `intent` 映射到这两个字段。

---

## 4. Mask 通用输出原则

### 4.1 不可用字段要显式标记

推荐使用 `*_available=0` 表示信号不可用，而不是传一个看似有效但实际伪造的值。

示例：

```json
{
  "place_type_available": 0,
  "activity_state_available": 0,
  "heart_rate_available": 0,
  "noise_available": 0,
  "calendar_available": 0
}
```

### 4.2 缺失不是负证据

mask 后的缺失字段应该被后端理解为 missing：

```text
没有 heart_rate != 用户没有运动
没有 calendar != 用户没有安排
没有 location != 用户没有出行
没有 noise != 当前环境安静
```

### 4.3 不要制造过强假信号

如果某权限被 mask 掉，不应该继续保留该权限才能得到的强特征。

例如：

```text
location=none 时，不应保留真实 `lat/lon`，上传 context 也不应包含 `latitude/longitude`。
health=none 时，不应保留 heart_rate_zone。
calendar=none 时，不应保留 calendar_title。
```

### 4.4 可以保留低权限基础字段

所有虚拟用户默认保留：

```text
timestamp
timezone
hour
weekday
network
bluetooth，除非 audio_route=unknown
app_event
```

### 4.5 问卷 intent 按软授权处理

问卷字段来自用户主动填写，不是系统权限，但在实验中要像权限一样模拟“有/无”：

```text
questionnaire=full  -> 有 intent + 可能有多选需求、标签、性别等
questionnaire=basic -> 只有一个主 intent / initial_need
questionnaire=none  -> 用户跳过问卷或拒绝提供意图
```

问卷缺失时建议输出：

```json
{
  "questionnaire_available": 0,
  "intent_available": 0
}
```

如果后端暂时不接受 `intent_available`，前端可以只在本地 mask 日志中保留该标记，上传 context 时省略 `intent` / `initial_need` / `initial_needs`。

---

## 5. 具体 Mask 规则

### 5.1 `location=full`

采集层保留：

```text
lat
lon
horizontal_accuracy_m
location_timestamp
place_type
place_type_available = 1
place_type_confidence
place_type_quality
```

上传 context 时映射为：

```text
latitude
longitude
location_accuracy_m
place_type
place_type_available = 1
place_type_confidence
place_type_quality
```

适用用户：

```text
u_full_permission
u_location_only_no_health
```

### 5.2 `location=approximate`

模拟用户只允许大致位置，或 MapKit / POI 映射低置信。

建议处理：

```text
lat/lon 降精度或替换为 coarse location
horizontal_accuracy_m 设置为较大值，例如 1000m-5000m；上传层可选择不传经纬度，或传递并让后端因 `location_accuracy_m > 250` 跳过 geo 聚类
place_type_confidence 降低，例如 0.25-0.55
place_type_quality = noisy_mapping
```

示例输出：

```json
{
  "lat": 31.23,
  "lon": 121.47,
  "horizontal_accuracy_m": 3000,
  "latitude": 31.23,
  "longitude": 121.47,
  "location_accuracy_m": 3000,
  "location_accuracy_authorization": "reducedAccuracy",
  "place_type": "任意",
  "place_type_available": 1,
  "place_type_confidence": 0.35,
  "place_type_quality": "noisy_mapping"
}
```

适用用户：

```text
u_approx_location
```

### 5.3 `location=none`

删除或不输出：

```text
lat
lon
horizontal_accuracy_m
latitude
longitude
location_accuracy_m
location_timestamp
```

输出：

```json
{
  "place_type": "任意",
  "place_type_available": 0,
  "place_type_confidence": 0.0,
  "place_type_quality": "unavailable"
}
```

适用用户：

```text
u_no_location
u_minimal_context
```

### 5.4 `motion=full`

保留：

```text
activity_state
activity_state_available = 1
```

示例：

```json
{
  "activity_state": "慢速",
  "activity_state_available": 1
}
```

### 5.5 `motion=none`

输出：

```json
{
  "activity_state": "任意",
  "activity_state_available": 0
}
```

### 5.6 `health=full`

保留：

```text
heart_rate_zone
heart_rate_available = 1
heart_rate_quality
steps_last_10min
recent_workout_minutes_24h
sleep_quality
```

### 5.7 `health=steps_only`

保留：

```text
steps_last_10min
```

删除或不输出：

```text
heart_rate_zone
heart_rate_quality
recent_workout_minutes_24h，可按实验需要决定是否保留
sleep_quality
```

输出：

```json
{
  "heart_rate_available": 0
}
```

适用用户：

```text
u_steps_only_no_hr_sleep
```

### 5.8 `health=no_watch`

模拟用户授权 HealthKit，但没有 Apple Watch 或没有实时心率。

保留：

```text
steps_last_10min
recent_workout_minutes_24h，可选
sleep_quality，可选
```

删除：

```text
heart_rate_zone
heart_rate_quality
```

输出：

```json
{
  "heart_rate_available": 0
}
```

适用用户：

```text
u_no_watch_health_partial
```

### 5.9 `health=none`

删除或不输出：

```text
heart_rate_zone
heart_rate_quality
steps_last_10min
recent_workout_minutes_24h
sleep_quality
```

输出：

```json
{
  "heart_rate_available": 0
}
```

适用用户：

```text
u_location_only_no_health
u_motion_only_no_health
u_minimal_context
```

### 5.10 `microphone=none`

删除：

```text
noise_class
noise_db
```

输出：

```json
{
  "noise_available": 0
}
```

第一版建议大部分虚拟用户都使用该 mask。

### 5.11 `calendar=none`

删除：

```text
calendar_title
calendar_keyword
```

输出：

```json
{
  "calendar_available": 0
}
```

第一版建议大部分虚拟用户都使用该 mask。

### 5.12 `audio_route=unknown`

输出：

```json
{
  "bluetooth": "任意"
}
```

适合模拟用户没有连接耳机、车载蓝牙、家用音响，或者系统路由无法稳定识别。

### 5.13 `questionnaire=full`

保留：

```text
intent
initial_need
initial_needs
user_tag，可选
gender，可选
questionnaire_submitted_at
```

输出：

```json
{
  "questionnaire_available": 1,
  "intent_available": 1
}
```

说明：

- `intent` 是前端语义名，表示用户通过问卷表达的需求。
- 当前后端可用 `initial_need` / `initial_needs` 接收相同信息。
- `gender` 不建议强制采集；即使 `questionnaire=full`，也可以为空。

### 5.14 `questionnaire=basic`

只保留一个主意图：

```text
intent
initial_need
```

输出：

```json
{
  "questionnaire_available": 1,
  "intent_available": 1
}
```

适合模拟用户只愿意回答“你现在/通常想要什么”这一题。

### 5.15 `questionnaire=none`

删除或不输出：

```text
intent
initial_need
initial_needs
user_tag
gender
questionnaire_submitted_at
```

输出：

```json
{
  "questionnaire_available": 0,
  "intent_available": 0
}
```

---

## 6. 建议一次性内置的虚拟用户

### 6.1 总表

| 虚拟用户 | 目标 | location | motion | health | microphone | calendar | questionnaire | 说明 |
|---|---|---|---|---|---|---|---|---|
| `u_full_permission` | 全权限上限基线 | full | full | full | full | full | full | 验证完整上下文效果 |
| `u_minimal_context` | 极简隐私用户 | none | none | none | none | none | none | 只保留时间、网络、蓝牙、App 行为 |
| `u_no_location` | 拒绝定位 | none | full | full | none | none | basic | 健康/运动可用，靠问卷补地点缺失 |
| `u_approx_location` | 大致位置 / 地点低置信 | approximate | full | full | none | none | basic | 测试地点降权 + intent 兜底 |
| `u_location_only_no_health` | 给定位，不给健康 | full | none 或 full | none | none | none | basic | 常见普通用户组合 |
| `u_motion_only_no_health` | 有运动状态，无 HealthKit | none 或 full | full | none | none | none | none | 只靠 CoreMotion |
| `u_steps_only_no_hr_sleep` | HealthKit 细粒度授权 | full | full | steps_only | none | none | basic | 只给步数，不给心率/睡眠 |
| `u_no_watch_health_partial` | 有健康权限但无手表心率 | full | full | no_watch | none | none | none | iPhone-only 或无心率设备 |
| `u_no_calendar_no_microphone` | 拒绝高隐私增强 | full | full | full | none | none | full | 核心权限可用，但不给麦克风/日历 |
| `u_calendar_enabled` | 只测试日历增强 | full | full | full | none | full | basic | 验证日历是否提升特定场景 |
| `u_noise_enabled` | 只测试噪音增强 | full | full | full | full | none | basic | 验证环境噪音是否有用 |
| `u_no_bluetooth_route` | 蓝牙/音频路由缺失 | full | full | full | none | none | none | `bluetooth=任意` |
| `u_weak_cellular_commuter` | 蜂窝弱网通勤 | full | full | none 或 no_watch | none | none | basic | 通勤/在途弱网场景 |
| `u_home_speaker_no_health` | 家用音响 + 无健康 | full | none | none | none | none | basic | 家庭/睡眠/照护类弱信号 |
| `u_full_no_questionnaire` | 全传感器但无问卷 | full | full | full | full | full | none | 测试没有 intent 时传感器是否足够 |
| `u_intent_only_minimal_context` | 极简权限但有问卷 | none | none | none | none | none | full | 测试 intent 对冷启动的兜底能力 |

### 6.2 `u_full_permission`

用途：

```text
完整上下文上限
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "full",
  "microphone": "full",
  "calendar": "full",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "full"
}
```

说明：

- 这是完整上下文上限用户。
- 如果某台测试设备暂时没有实现麦克风或日历采集，可以先让对应字段按 `*_available=0` 退化，但用户类别仍保留。

### 6.3 `u_minimal_context`

用途：

```text
低权限下限
只靠时间、网络、蓝牙、App 行为和历史反馈
```

mask：

```json
{
  "location": "none",
  "motion": "none",
  "health": "none",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "none"
}
```

关键输出：

```json
{
  "place_type": "任意",
  "place_type_available": 0,
  "place_type_confidence": 0.0,
  "place_type_quality": "unavailable",
  "activity_state": "任意",
  "activity_state_available": 0,
  "heart_rate_available": 0,
  "noise_available": 0,
  "calendar_available": 0
}
```

### 6.4 `u_no_location`

用途：

```text
测试健康/运动足够完整，但位置完全缺失时推荐是否稳定
```

mask：

```json
{
  "location": "none",
  "motion": "full",
  "health": "full",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "basic"
}
```

重点观察：

```text
通勤、图书馆、写字楼、住宅区、商场等依赖地点的场景是否过度退化
运动/跑步/健身是否还能靠 activity + health 识别
```

### 6.5 `u_approx_location`

用途：

```text
测试大致位置和 noisy place_type 的降权逻辑
```

mask：

```json
{
  "location": "approximate",
  "motion": "full",
  "health": "full",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "basic"
}
```

关键输出：

```json
{
  "place_type_available": 1,
  "place_type_confidence": 0.25,
  "place_type_quality": "noisy_mapping"
}
```

重点观察：

```text
低置信地点是否被正确弱化
历史 bucket 是否避免使用 noisy place_type 造成污染
```

### 6.6 `u_location_only_no_health`

用途：

```text
模拟给定位但不给健康的普通用户
```

mask：

```json
{
  "location": "full",
  "motion": "none",
  "health": "none",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "basic"
}
```

重点观察：

```text
推荐是否过度依赖 HealthKit
地点 + 时间 + 蓝牙 + 网络是否足以支撑通勤/专注/睡眠/放松等场景
```

### 6.7 `u_motion_only_no_health`

用途：

```text
模拟只给 Motion/Fitness，不给 HealthKit 的用户
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "none",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "none"
}
```

重点观察：

```text
仅靠 activity_state 能否辅助跑步/通勤/静止场景
没有 heart_rate 时是否仍能推荐运动相关场景
```

### 6.8 `u_steps_only_no_hr_sleep`

用途：

```text
模拟 HealthKit 细粒度授权，只给步数，不给心率和睡眠
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "steps_only",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "basic"
}
```

关键输出：

```json
{
  "steps_last_10min": 850,
  "heart_rate_available": 0
}
```

重点观察：

```text
步数是否能补足 activity_state
没有心率/睡眠时，健身/跑步/睡眠场景是否仍有合理排序
```

### 6.9 `u_no_watch_health_partial`

用途：

```text
模拟用户有 HealthKit，但没有 Apple Watch 或没有实时心率
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "no_watch",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "none"
}
```

关键输出：

```json
{
  "heart_rate_available": 0,
  "steps_last_10min": 500,
  "recent_workout_minutes_24h": 30
}
```

重点观察：

```text
没有心率但有步数/workout 时，推荐系统是否能避免把用户误判为静止
```

---

## 7. 补充虚拟用户定义

以下用户和第 6 节用户一起内置。它们主要用于覆盖日历、麦克风、蓝牙路由、弱网和家庭音响等辅助信号。

### 7.1 `u_no_calendar_no_microphone`

用途：

```text
模拟核心权限可用，但拒绝日历和麦克风的用户
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "full",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "full"
}
```

关键输出：

```json
{
  "noise_available": 0,
  "calendar_available": 0
}
```

### 7.2 `u_calendar_enabled`

用途：

```text
单独验证日历增强信号
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "full",
  "microphone": "none",
  "calendar": "full",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "basic"
}
```

重点观察：

```text
会议、瑜伽课、健身课、宝宝睡觉、产检、遛宠等日历关键词是否能改善推荐
日历缺失时是否不会被当作负证据
```

### 7.3 `u_noise_enabled`

用途：

```text
单独验证噪音环境增强信号
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "full",
  "microphone": "full",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "basic"
}
```

重点观察：

```text
安静/普通/嘈杂是否能辅助图书馆、阅读、睡眠、通勤等场景
噪音是否被错误当作硬规则
```

### 7.4 `u_no_bluetooth_route`

用途：

```text
模拟音频输出路由不可识别或未连接蓝牙设备
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "full",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "unknown",
  "network": "full",
  "questionnaire": "none"
}
```

关键输出：

```json
{
  "bluetooth": "任意"
}
```

### 7.5 `u_weak_cellular_commuter`

用途：

```text
模拟在途/通勤时蜂窝弱网，并观察网络弱信号是否辅助通勤场景
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "no_watch",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "weak_cellular",
  "questionnaire": "basic"
}
```

建议派生时覆盖：

```json
{
  "network": "蜂窝数据（弱）",
  "bluetooth": "耳机"
}
```

### 7.6 `u_home_speaker_no_health`

用途：

```text
模拟家庭/睡眠/照护类场景中，有家用音响但无健康权限的用户
```

mask：

```json
{
  "location": "full",
  "motion": "none",
  "health": "none",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "basic"
}
```

建议派生时覆盖：

```json
{
  "bluetooth": "家用音响",
  "activity_state": "任意",
  "activity_state_available": 0,
  "heart_rate_available": 0
}
```

### 7.7 `u_full_no_questionnaire`

用途：

```text
模拟所有系统权限都可用，但用户跳过问卷/不提供 intent
```

mask：

```json
{
  "location": "full",
  "motion": "full",
  "health": "full",
  "microphone": "full",
  "calendar": "full",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "none"
}
```

关键输出：

```json
{
  "questionnaire_available": 0,
  "intent_available": 0
}
```

重点观察：

```text
没有显式 intent 时，传感器和历史反馈是否足以完成推荐
```

### 7.8 `u_intent_only_minimal_context`

用途：

```text
模拟系统权限极少，但用户愿意填写问卷 intent
```

mask：

```json
{
  "location": "none",
  "motion": "none",
  "health": "none",
  "microphone": "none",
  "calendar": "none",
  "audio_route": "full",
  "network": "full",
  "questionnaire": "full"
}
```

关键输出：

```json
{
  "place_type_available": 0,
  "activity_state_available": 0,
  "heart_rate_available": 0,
  "noise_available": 0,
  "calendar_available": 0,
  "questionnaire_available": 1,
  "intent_available": 1
}
```

重点观察：

```text
当 sensor 很少时，问卷 intent 对冷启动推荐的兜底能力
```

---

## 8. Permission Mask 到 VirtualContext 的伪代码

```swift
struct PermissionMask {
    enum LocationMode { case full, approximate, none }
    enum MotionMode { case full, none }
    enum HealthMode { case full, stepsOnly, noWatch, none }
    enum BinaryMode { case full, none }
    enum AudioRouteMode { case full, unknown }
    enum NetworkMode { case full, weakCellular }
    enum QuestionnaireMode { case full, basic, none }

    let location: LocationMode
    let motion: MotionMode
    let health: HealthMode
    let microphone: BinaryMode
    let calendar: BinaryMode
    let audioRoute: AudioRouteMode
    let network: NetworkMode
    let questionnaire: QuestionnaireMode
}
```

派生流程：

```swift
func makeVirtualContext(
    from raw: RawSensorSnapshot,
    mask: PermissionMask
) -> VirtualContext {
    var context = VirtualContext()

    // Always keep base fields.
    context.timestamp = raw.timestamp
    context.timezone = raw.timezone
    context.hour = raw.hour
    context.weekday = raw.weekday
    context.appEvent = raw.appEvent
    context.appEventAvailable = raw.appEvent == nil ? 0 : 1

    // Network.
    context.network = mask.network == .weakCellular
        ? "蜂窝数据（弱）"
        : raw.network

    // Audio route.
    context.bluetooth = mask.audioRoute == .unknown
        ? "任意"
        : raw.bluetooth

    // Location.
    applyLocationMask(raw: raw, context: &context, mode: mask.location)

    // Motion.
    applyMotionMask(raw: raw, context: &context, mode: mask.motion)

    // Health.
    applyHealthMask(raw: raw, context: &context, mode: mask.health)

    // Microphone.
    applyMicrophoneMask(raw: raw, context: &context, mode: mask.microphone)

    // Calendar.
    applyCalendarMask(raw: raw, context: &context, mode: mask.calendar)

    // Questionnaire / intent.
    applyQuestionnaireMask(raw: raw, context: &context, mode: mask.questionnaire)

    return context
}
```

---

## 9. 实验记录建议

每次生成 virtual context 时，建议本地日志记录：

```text
real_sample_id
virtual_user_id
mask_name
questionnaire_mask
timestamp
raw_snapshot_hash
virtual_context_json
mask_version
```

这样后续可以复盘：

```text
同一个真实上下文，在不同权限组合下，推荐结果如何变化
哪些字段缺失会导致推荐明显退化
是否有某类缺失造成错误场景偏置
```

---

## 10. 实施建议：一批一起做

不再拆分批次。前端 PoC 直接一次性内置以下全部虚拟用户：

```text
u_full_permission
u_minimal_context
u_no_location
u_approx_location
u_location_only_no_health
u_motion_only_no_health
u_steps_only_no_hr_sleep
u_no_watch_health_partial
u_no_calendar_no_microphone
u_calendar_enabled
u_noise_enabled
u_no_bluetooth_route
u_weak_cellular_commuter
u_home_speaker_no_health
u_full_no_questionnaire
u_intent_only_minimal_context
```

理由：

1. mask 引擎一旦实现，多派生几个虚拟用户的成本很低。
2. 一次性覆盖地点、运动、健康、日历、麦克风、蓝牙、网络弱信号和问卷 intent，便于横向比较。
3. 日历和麦克风虽然不应作为主链路，但可以通过 `u_calendar_enabled` / `u_noise_enabled` 单独观察边际收益。
4. 问卷 intent 不是系统权限，但用户可能跳过或拒绝填写，所以需要通过 `u_full_no_questionnaire` / `u_intent_only_minimal_context` 单独验证。
5. 所有虚拟用户都应使用同一份 `RawSensorSnapshot` 派生，避免真实采样差异干扰权限缺失实验。
