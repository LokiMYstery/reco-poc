# iPhone Mini App 上下文字段对齐文档

这份文档用于前后端对齐：iPhone 侧实际能采集哪些 raw context，后端 POC 接收哪些字段，以及哪些字段是必填、可选、经常缺失或需要授权。

原则：

1. 前端不需要判断“用户正在做什么”，只上传可观测原始上下文。
2. 可选字段拿不到就不要传，或传 `*_available=0`。
3. 后端把缺失视为 missing，不会当作负证据。
4. `ground_truth` 不允许前端上传，它只存在于离线评测数据。

## 1. 最小必填字段

| 字段 | 类型 | 是否必填 | 示例 | 说明 |
|---|---|---:|---|---|
| `user_id` | string | 是 | `u_001` | 匿名稳定 ID，用于个性化历史 |
| `timestamp` | string | 是 | `2026-05-26T08:35:00+08:00` | 推荐触发时间 |
| `top_k` | int | 否 | `3` | 默认 3 |
| `request_id` | string | 否 | `req_001` | 可由前端生成；不传则后端生成 |

建议前端生成稳定匿名 `user_id`，不要上传手机号、邮箱、姓名等 PII。

## 2. 时间字段

| 字段 | 类型 | 是否建议传 | 示例 | 后端处理 |
|---|---|---:|---|---|
| `timestamp` | string | 必传 | `2026-05-26T08:35:00+08:00` | 可自动解析 hour/date/weekday |
| `timezone` | string | 建议 | `Asia/Shanghai` | debug 和日志使用 |
| `hour` | int | 建议 | `8` | 如果不传，后端从 timestamp 解析 |
| `weekday` | int/string | 建议 | `1` / `周二` | 0=周一，6=周日 |
| `time_slot` | string | 可选 | `早晨` / `中午` / `下午` / `傍晚` / `夜晚` / `深夜` | 不传也可以，后端可根据 `hour` 自动补 |

时间是低权限、高稳定信号，建议必做。

`time_slot` 建议统一按下面的小时映射。前端可以不传，后端会按 `hour` 自动补；如果前端传，建议严格使用同一套枚举。

```text
05:00-10:59 -> 早晨
11:00-13:59 -> 中午
14:00-16:59 -> 下午
17:00-19:59 -> 傍晚
20:00-22:59 -> 夜晚
23:00-04:59 -> 深夜
```

## 3. 地点字段

| 字段 | 类型 | 是否建议传 | 示例 | 风险 |
|---|---|---:|---|---|
| `place_type` | string | 建议 | `住宅区` / `写字楼` / `在途` | POI 映射可能不准 |
| `place_type_available` | int | 建议 | `1` / `0` | 0 表示拿不到 |
| `place_type_confidence` | float | 强烈建议 | `0.72` | 0-1，低置信后端会降权 |
| `place_type_quality` | string | 建议 | `exact_or_good_mapping` / `noisy_mapping` | 标记映射质量 |
| `latitude` | float | 可选 | `31.2304` | 可选增强，用于用户自己的常去地点聚类 |
| `longitude` | float | 可选 | `121.4737` | 可选增强，用于用户自己的常去地点聚类 |
| `location_accuracy_m` | float | 可选 | `35.0` | 定位水平精度，过低精度会跳过聚类 |

内部枚举建议：

```text
任意、住宅区、商场、酒店、餐厅、公园、写字楼、机场、图书馆、海边、户外、在途、高铁站、地铁站
```

建议前端/地图侧传：

```text
place_type = 内部映射后的类型
place_type_confidence = 地图/定位/POI 映射置信度
place_type_quality = exact_or_good_mapping / noisy_mapping / unavailable
```

后端处理：

- `place_type_confidence < 0.55`：地点只作为弱信号。
- `place_type_quality=noisy_mapping`：不进入细分历史 bucket。
- `place_type_available=0`：按缺失处理。

经纬度增强说明：

- 经纬度不是必填，第一版只传 `place_type` 也可以跑。
- 如果前端能拿到经纬度，建议只在用户授权后传 `latitude`、`longitude`、`location_accuracy_m`。
- 后端不会把原始经纬度作为硬规则，而是按 `user_id` 聚成用户自己的常去地点簇，例如 `geo_1`、`geo_2`。
- `location_accuracy_m > 250` 时后端会跳过聚类，避免低精度污染历史。
- `geo_cluster_id` 会参与长期 history bucket，用来学习“这个用户在这个常去地点通常听什么”。
- 出差/新地点通常会形成 `geo_cluster_status=new`，可作为 routine 偏离的 debug 信号。

## 4. 运动与健康字段

| 字段 | 类型 | 是否建议传 | 示例 | 权限 |
|---|---|---:|---|---|
| `activity_state` | string | 有权限则传 | `静止` / `慢速` / `中速` / `高速` | 运动/健康权限 |
| `activity_state_available` | int | 建议 | `1` / `0` | 标记是否可用 |
| `heart_rate_zone` | string | 有权限则传 | `静息` / `稍高` / `高` / `波动` | 健康权限/手表 |
| `heart_rate_available` | int | 建议 | `1` / `0` | 标记是否可用 |
| `heart_rate_quality` | string | 可选 | `fresh` / `stale_before_activity` | 心率是否滞后 |
| `steps_last_10min` | int | 有则传 | `850` | 健康权限 |
| `recent_workout_minutes_24h` | int | 有则传 | `35` | 健康权限 |
| `sleep_quality` | string | 可选 | `好` / `一般` / `差` | 睡眠权限 |

运动枚举：

```text
任意、静止、慢速、中速、高速
```

心率枚举：

```text
任意、静息、稍高、高、波动
```

关键说明：

- 运动/心率拿不到很正常，传 `*_available=0` 即可。
- 用户刚打开 App 时可能还没开始运动，心率不一定升高。
- 后端不会因为没有心率而否定跑步/健身。

## 5. 环境字段

| 字段 | 类型 | 是否建议传 | 示例 | 说明 |
|---|---|---:|---|---|
| `weather` | string | 可选 | `晴` / `多云` / `小雨` | 弱信号 |
| `light_class` | string | 可选 | `暗光` / `室内柔光` / `明亮` / `强光` | 睡眠/午睡辅助 |
| `noise_class` | string | 可选 | `安静` / `普通` / `嘈杂` | 不上传音频，只上传分类 |
| `noise_available` | int | 可选 | `1` / `0` | 麦克风权限相关 |

噪音建议只在本地计算分类，不上传原始音频。

## 6. 连接字段

| 字段 | 类型 | 是否建议传 | 示例 | 说明 |
|---|---|---:|---|---|
| `bluetooth` | string | 建议 | `耳机` / `车载蓝牙` / `家用音响` | 通勤/运动/睡眠辅助 |
| `network` | string | 建议 | `wifi` / `蜂窝数据` / `蜂窝数据（弱）` | App 可用性和在途弱信号 |

蓝牙枚举：

```text
任意、耳机、车载蓝牙、家用音响
```

网络枚举：

```text
wifi、蜂窝数据、蜂窝数据（弱）
```

说明：如果 App 必须联网才能打开，推荐触发时通常不应出现 `无网络` / `飞行模式`。

## 7. 日历与 App 行为字段

| 字段 | 类型 | 是否建议传 | 示例 | 说明 |
|---|---|---:|---|---|
| `calendar_title` | string | 可选 | `瑜伽课` / `会议` | 权限较大，不作为主链路 |
| `calendar_available` | int | 可选 | `1` / `0` | 标记是否可用 |
| `app_event` | string | 可选 | `用户打开冥想页` | 只建议自家 App 内事件 |
| `app_event_available` | int | 可选 | `1` / `0` | 标记是否可用 |

可以先传App 内行为：

```text
打开推荐页
点击某场景
搜索关键词
播放
跳过
收藏
切换场景
```

## 8. 用户 profile 字段

| 字段 | 类型 | 是否建议传 | 示例 | 来源 |
|---|---|---:|---|---|
| `user_tag` | string | 可选 | `学生` / `母婴用户` / `养宠物` | 问卷 |
| `gender` | string | 可选 | `女性` | 问卷 |
| `initial_need` | string | 可选 | `学习专注` / `睡眠照护` | 问卷 |
| `initial_needs` | array | 可选 | `["睡眠/午休", "放松/减压"]` | 多选问卷 |

这些只作为冷启动弱先验，不覆盖实时上下文和用户真实反馈。

### 8.1 Profile 枚举建议

`user_tag` 第一版只用单选主标签，避免 profile 过细导致样本稀疏：

```text
任意
学生
母婴用户
女性
养宠物
```

如果产品上允许多选，可以前端先多选，但后端 POC 第一版建议先传一个最主要标签；多选标签后续可以扩展成 `user_tags: []`。

`gender` 建议枚举：

```text
任意
女性
男性
不便透露
```

`initial_need` / `initial_needs` 建议使用较粗的大类，避免问卷太长：

```text
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

如果需要更细，也可以兼容以下枚举：

```text
任意
学习专注
工作专注
睡眠改善
放松减压
运动健身
通勤陪伴
阅读陪伴
冥想正念
情绪舒缓
睡眠照护
母婴照护
宠物陪伴
经期舒缓
胎教
游戏娱乐
```

后端当前会重点使用这些关键词做弱先验：

```text
学习 / 工作 / 专注 -> 专注、图书馆、阅读
情绪 / 舒缓 / 减压 -> 减压、放松、经期舒缓
睡眠 / 睡眠照护 / 家庭 -> 深睡眠、睡午觉、婴儿安睡
陪伴 / 宠物 -> 宠物陪伴、放松
运动 / 健身 -> 健身、跑步、瑜伽
母婴 / 胎教 -> 婴儿安睡、胎教
游戏 -> 游戏
```

注意：

- Profile 是冷启动辅助，不是强规则。
- 用户不填也没关系，传 `任意` 或不传即可。
- 不建议采集过细敏感信息；能用播放反馈学习的，就优先用真实反馈学习。

## 9. 推荐请求完整示例

```json
{
  "user_id": "u_001",
  "request_id": "req_001",
  "top_k": 3,
  "context": {
    "timestamp": "2026-05-26T22:40:00+08:00",
    "timezone": "Asia/Shanghai",
    "hour": 22,
    "weekday": 1,
    "place_type": "住宅区",
    "place_type_available": 1,
    "place_type_confidence": 0.81,
    "place_type_quality": "exact_or_good_mapping",
    "activity_state": "静止",
    "activity_state_available": 1,
    "heart_rate_zone": "静息",
    "heart_rate_available": 1,
    "noise_class": "安静",
    "light_class": "暗光",
    "bluetooth": "家用音响",
    "network": "wifi",
    "user_tag": "任意"
  }
}
```

## 10. 反馈事件字段

用户行为发生后，调用 `/v1/feedback`。

| 字段 | 类型 | 是否必填 | 示例 | 说明 |
|---|---|---:|---|---|
| `user_id` | string | 是 | `u_001` | 同推荐请求 |
| `request_id` | string | 建议 | `req_001` | 用于关联推荐上下文 |
| `recommended_scene` | string | 是 | `通勤` | 后端推荐的场景 |
| `accepted_scene` | string | 否 | `跑步` | 用户实际接受/切换后的场景 |
| `event_type` | string | 是 | `listen` / `like` / `skip` / `correction` | 用户行为 |
| `dwell_time_sec` | int | 建议 | `420` | 停留时长 |
| `played_ratio_pct` | float | 可选 | `0.82` | 播放完成比例，0-1 |
| `next_action` | string | 可选 | `继续播放` / `关闭` / `用户切换场景` | 后续行为 |
| `context` | object | 可选 | 同推荐 context | request_id 找不到时建议传 |

event_type 建议：

```text
impression -> 推荐曝光
listen -> 实际播放/收听
like -> 收藏/喜欢
dislike -> 负反馈
skip -> 跳过
correction -> 用户主动切换场景
```

注意：`impression` 只记录曝光，不会更新用户偏好；真正用于学习的是 `listen`、`like`、`dislike`、`skip`、`correction` 等后续行为。

## 11. 第一版前端可以先做到什么

最小闭环：

1. App 打开推荐页时，生成 `request_id`。
2. 采集时间、网络、蓝牙、地点类型及置信度。
3. 如果用户授权，附加 activity / heart rate。
4. 调 `/v1/recommend` 展示 Top-3。
5. 用户播放/停留/跳过/切换后，调 `/v1/feedback`。

这样即使不接日历、不接外部 App、不接完整健康权限，也可以开始 POC。
