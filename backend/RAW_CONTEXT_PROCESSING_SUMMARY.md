# 音乐场景推荐：原始上下文数据处理方法汇总

本文档汇总“音乐场景推荐”中常见原始数据如何处理成可用于推荐算法的上下文标签。

核心原则：

1. **只使用真实可获取或可推断的信号**，不要把“用户正在干嘛”直接作为输入。
2. **所有传感器/权限字段都要带可用性和置信度**，例如 `heart_rate_available`、`place_type_confidence`。
3. **缺失不是负证据**，比如没有日历不等于用户没有安排，没有心率不等于没有运动。
4. **场景标签用于离线评测，线上输入只能用原始上下文和历史反馈。**

## 参考资料

### 上下文音乐推荐

- Context-aware music recommender 系统综述指出，音乐推荐中常用上下文包括时间、位置、活动、情绪、天气、环境因素等；这些信息一般来自手机、可穿戴设备和 IoT 设备。  
  https://www.mdpi.com/2079-9292/10/13/1555

- Contextual music information retrieval survey 讨论了音乐推荐中的上下文异构性，包括情绪、时间、位置、多媒体等。  
  https://www.sciencedirect.com/science/article/pii/S1574013712000135

- Context-aware Mobile Music Recommendation 采用“两步法”：先从传感器特征推断 context category，再根据 context 推荐歌曲；论文也提到仅靠手机传感器有时很难区分 working 和 studying。  
  https://smcnus.comp.nus.edu.sg/archive/pdf/2012-2013/2012_Context.pdf

- Large in-situ dataset for smartphone music recommendation 收集真实听歌记录，并计算 location、time、acceleration、proximity 等手机传感器特征。  
  https://scholars.lib.ntu.edu.tw/entities/publication/462417ac-f856-47aa-a514-3238fb96574e

- MusicalHeart 使用心率和活动水平做 biofeedback music recommendation，说明心率/活动可以作为音乐推荐上下文，但依赖设备和测量质量。  
  https://www.researchgate.net/publication/255568687_MusicalHeart_A_Hearty_Way_of_Listening_to_Music

### 用户长期行为日志

- PIMP / Why Context Matters：包含用户问卷、session start/end state、tracks、completion status。适合参考“听歌 session + 用户状态 + 问卷”的结构。  
  https://github.com/hcai-mms/PIMP

- Yambda：音乐推荐大规模多事件数据集，包含 `uid`、`item_id`、`timestamp`、`event_type`、`played_ratio_pct`、`track_length_seconds`、`is_organic`，以及 listen / like / dislike 等事件。适合参考我们的长期反馈日志格式。  
  https://huggingface.co/datasets/yandex/yambda

- Deezer listening events dataset：包含长时间跨度 timestamped listening events，适合参考长期时序和 repeat consumption。  
  https://zenodo.org/records/13890194

- MLHD：大规模 Last.fm timestamped listening histories，适合参考用户长期听歌历史的建模方式。  
  https://ddmal.ca/research/The_Music_Listening_Histories_Dataset_(MLHD)/

- Spotify Sequential Skip Prediction Challenge / Music Streaming Sessions Dataset：使用约 1.3 亿个 listening sessions，任务是根据 session 前半段的用户交互、track metadata 和 acoustic descriptors 预测后半段是否 skip。适合参考“session 内行为特征”和“跳过/完成率”如何成为推荐信号。  
  https://www.aicrowd.com/challenges/spotify-sequential-skip-prediction-challenge

- Spotify Research 的 contextual and sequential user embeddings：提到用当前 session embedding、用户长期 embedding，以及 session skip rate 等信号刻画当前听歌上下文。适合参考“长期用户画像 + 当前 session 状态”的组合。  
  https://research.atspotify.com/2021/04/contextual-and-sequential-user-embeddings-for-music-recommendation/

- The skipping behavior of users of music streaming services：研究 streaming service 中用户在歌曲播放过程中的 skip 时间点，说明 early skip、skip position、skip profile 是重要的隐式负反馈。  
  https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0239418

### 原始信号来源

- Google Places API place types：可用于将 POI / 地点类型映射到内部 `place_type`。  
  https://developers.google.cn/maps/documentation/places/web-service/place-types

- Apple Core Motion `CMMotionActivity`：可获取 stationary、walking、running、automotive、cycling、unknown 等运动状态。  
  https://developer.apple.com/documentation/coremotion/cmmotionactivity/1615430-stationary

- Apple HealthKit `HKWorkoutActivityType`：可识别 running、cycling、yoga、mindAndBody、traditionalStrengthTraining 等 workout 类型。  
  https://developer.apple.com/documentation/healthkit/hkworkoutactivitytype/mindandbody

- OpenWeather weather condition codes：天气可映射为 Clear / Clouds / Rain / Snow / Thunderstorm / Drizzle / Atmosphere 等大类。  
  https://docs.openweather.co.uk/weather-conditions

- Apple WeatherKit `WeatherCondition`：Apple 侧天气条件枚举，包含 clear、cloudy、foggy、rain、heavyRain、snow 等。  
  https://developer.apple.com/documentation/weatherkit/weathercondition

- CDC/NIOSH 噪声资料：85 dBA 是职业噪声暴露常用风险阈值；手机可以用声级计 App 做 screening，但精度受设备姿态、位置等影响。  
  https://www.cdc.gov/niosh/noise/prevent/understand.html

- NIDCD 声音测量说明：30 dBA 接近 whisper，60-70 dBA 接近 normal conversation，85 dBA 以上需要注意听力风险。  
  https://www.nidcd.nih.gov/health/how-sound-measured

- DOE lighting terms：家庭/办公任务通常需要约 30-50 footcandles，约 323-538 lux，可用于划分室内明亮/工作光照。  
  https://www.energy.gov/energysaver/lighting-principles-and-terms

- American Heart Association heart rate zones：中等强度约 50-70% 最大心率，剧烈活动约 70-85% 最大心率；最大心率可粗略用 `220 - age`。  
  https://www.heart.org/en/healthy-living/exercise-and-physical-activity/fitness-basics/target-heart-rates

## 推荐原始数据处理方案

### 1. 时间与日期

原始字段：

```text
timestamp
timezone
```

处理字段：

```text
date
hour
weekday
date_type
time_slot
time_window
```

建议映射：

```text
00:00-05:59 -> 凌晨
06:00-08:59 -> 早晨
09:00-11:59 -> 上午
12:00-13:59 -> 中午
14:00-17:59 -> 下午
18:00-21:59 -> 晚上
22:00-23:59 -> 深夜
```

注意：

- 时间是低权限、高稳定信号。
- 可以额外保留 `hour_sin/hour_cos` 做模型特征，避免 23 点和 0 点被视为距离很远。

### 2. 地点 / POI 到 place_type

原始字段：

```text
lat
lon
horizontal_accuracy
poi_candidates
provider_place_types
distance_to_poi
dwell_time
```

处理字段：

```text
place_type
place_type_confidence
place_type_quality
place_type_available
original_place_type_for_eval_only
```

推荐流程：

1. GPS / Wi-Fi / Cell 定位得到 `lat/lon + accuracy`。
2. 请求 POI 服务，例如 Google Places / Apple MapKit / 高德 / 腾讯地图。
3. 获取候选 POI 的 type、距离、provider confidence。
4. 将 provider type 映射到内部 place_type。
5. 根据定位精度、候选距离、停留时长、时间稳定性计算 `place_type_confidence`。
6. 低置信时输出 `任意` 或 `place_type_quality=noisy_mapping`。

示例映射：

```text
airport -> 机场
train_station / transit_station -> 高铁站 / 地铁站 / 在途
subway_station -> 地铁站
library -> 图书馆
park -> 公园
restaurant / cafe / meal_takeaway -> 餐厅
shopping_mall / department_store / store -> 商场
lodging -> 酒店
office / corporate_office / coworking_space -> 写字楼
residential / premise / apartment -> 住宅区
tourist_attraction / natural_feature / beach -> 户外 / 海边
```

建议置信度：

```text
定位精度 < 50m 且 POI距离 < 80m -> 高置信
定位精度 50-150m 或 多个POI竞争 -> 中置信
定位精度 > 150m 或 POI类型冲突 -> 低置信 / 任意
```

注意：

- `place_type` 不应作为硬规则，只应作为加权信号。
- 写死映射容易错，必须保留 `place_type_confidence`。
- 长停留可以提升住宅区/写字楼/酒店等判断置信度。

### 3. 运动状态

原始字段：

```text
Core Motion activity
HealthKit workout
steps_last_10min
distance_delta
speed
cadence
```

处理字段：

```text
activity_state
activity_state_available
activity_confidence
workout_type
```

推荐映射：

```text
stationary -> 静止
walking -> 慢速
running -> 高速
automotive -> 在途 / 通勤辅助信号
cycling -> 中速
unknown -> 任意
```

结合步数：

```text
steps_last_10min < 100 -> 静止
100-600 -> 慢速
600-1200 -> 中速
>1200 -> 高速
```

注意：

- activity_state 依赖健康/运动权限，必须允许缺失。
- 如果用户刚打开 App，运动还没开始，不能要求心率已经上升。
- HealthKit workout 如果存在，是强信号；没有 workout 不代表没有运动。

### 4. 心率与趋势

原始字段：

```text
heart_rate_bpm
resting_heart_rate
age
heart_rate_samples_window
```

处理字段：

```text
heart_rate_zone
heart_rate_trend
heart_rate_quality
heart_rate_available
```

推荐处理：

1. 有个人 resting HR 时优先用个人基线。
2. 没有个人基线时，用年龄估计最大心率：`max_hr = 220 - age`。
3. AHA 建议中等强度约 50-70% 最大心率，剧烈强度约 70-85% 最大心率。

工程映射示例：

```text
缺失 -> 任意
接近 resting HR -> 静息
高于 resting HR 10-30 bpm 或 50-70% maxHR -> 稍高
70-85% maxHR -> 高
短时间标准差/斜率较大 -> 波动
```

趋势计算：

```text
最近 3-5 分钟线性斜率 > 阈值 -> 上升
最近 3-5 分钟线性斜率 < -阈值 -> 下降
标准差较大 -> 波动
否则 -> 稳定
```

注意：

- 心率是强但滞后的信号。
- 推荐发生在运动开始前时，心率可能仍然静息。
- 因此心率只应加分，不应作为运动场景的必要条件。

### 5. 噪音 / 分贝

原始字段：

```text
microphone_db_a
sample_window
device_position_quality
```

处理字段：

```text
noise_db
noise_class
noise_available
```

推荐处理：

1. 使用 A-weighted dB，如果可能记录 LAeq。
2. 在 5-30 秒窗口内取 median 或 trimmed mean，避免瞬时尖峰。
3. 如果麦克风权限不可用，则输出缺失。

工程映射示例：

```text
<45 dBA -> 安静
45-68 dBA -> 普通
>=69 dBA -> 嘈杂
>=85 dBA -> 高噪/风险提示，不一定进入推荐特征
```

依据：

- WHO 夜间噪声建议低于约 40 dB(A)。
- NIDCD 示例中 whisper 约 30 dBA，normal conversation 约 60-70 dBA。
- NIOSH/CDC 常用 85 dBA 作为职业噪声风险阈值。

注意：

- 手机麦克风受口袋、包、手持方向影响。
- 噪音用于区分图书馆/阅读/睡眠/通勤等，不应单独决定场景。
- 需要注意隐私，最好只上传统计值，不上传音频。

### 6. 光线 / Lux

原始字段：

```text
ambient_light_lux
screen_brightness
is_daylight
```

处理字段：

```text
light_lux
light_class
light_available
```

工程映射示例：

```text
0-50 lux -> 暗光
51-300 lux -> 室内柔光
301-1200 lux -> 明亮
>1200 lux -> 强光 / 户外强光
```

依据：

- DOE 指出普通家庭/办公任务约 30-50 footcandles，约 323-538 lux。
- 住宅卧室/休息空间通常远低于办公任务照明，阅读/工作需要更高照度。

注意：

- 手机没有稳定环境光 API 时，可用屏幕亮度、时间、是否日出后作为弱代理。
- 光线用于区分睡眠/午睡/深夜EMO/专注等，但不应作为硬条件。

### 7. 天气

原始字段：

```text
weather_condition_code
weather_main
temperature
precipitation
is_daylight
```

处理字段：

```text
weather
weather_available
```

OpenWeather 映射示例：

```text
Clear -> 晴
Clouds -> 多云 / 阴
Rain / Drizzle -> 小雨 / 雨
Snow -> 雪
Thunderstorm -> 雷雨
Mist / Fog / Haze / Dust -> 雾 / 霾
```

Apple WeatherKit 映射示例：

```text
clear / mostlyClear -> 晴
cloudy / mostlyCloudy / partlyCloudy -> 多云 / 阴
drizzle / rain / heavyRain -> 雨
snow / flurries / sleet -> 雪
foggy / haze -> 雾
```

注意：

- 天气是弱信号，更多影响跑步/户外/通勤/放松，不应单独决定音乐场景。

### 8. 蓝牙与网络

原始字段：

```text
bluetooth_device_type
network_type
network_quality
```

处理字段：

```text
bluetooth
network
network_available
```

推荐映射：

```text
AirPods / headphone / headset -> 耳机
car audio / vehicle bluetooth -> 车载蓝牙
speaker / homepod / soundbar -> 家用音响
unknown / none -> 任意
```

网络：

```text
wifi
蜂窝数据
蜂窝数据（弱）
```

注意：

- 如果 App 必须联网才能打开，则测试数据里不应出现“无网络/飞行模式”作为推荐触发时刻。
- 车载蓝牙是通勤强辅助信号。
- 家用音响可辅助判断家庭/睡眠/婴儿安睡，但不是硬条件。

### 9. 日历和 App 行为

原始字段：

```text
calendar_title
calendar_location
calendar_note
in_app_events
```

处理字段：

```text
calendar_available
calendar_keyword
app_event_available
app_event
```

处理建议：

```text
会议/提交/截止/考试/复习 -> 专注/减压弱信号
瑜伽课/健身课/跑步训练 -> 运动类弱信号
宝宝睡觉/哄睡 -> 婴儿安睡强信号
经期提醒 -> 经期舒缓强信号
产检/胎教 -> 胎教强信号
遛宠 -> 宠物陪伴强信号
```

注意：

- 日历权限大，很多用户没有日程习惯，不能作为主链路。
- 外部 App 行为通常拿不到，除非系统允许或是自家 App 内行为。
- 可用时作为增强信号；不可用时不能当作负证据。

### 10. 长期反馈事件

参考 Yambda/PIMP，推荐事件结构：

```text
user_id
timestamp
session_id
event_type
is_organic
played_ratio_pct
track_length_seconds
dwell_time_sec
liked
disliked
user_correction_from
user_correction_to
```

event_type 建议：

```text
impression -> 推荐曝光
listen -> 实际播放/收听
like -> 收藏/喜欢
dislike -> 负反馈
correction -> 用户主动纠错/切换场景
```

反馈强度：

```text
listen + 高 played_ratio + 长 dwell -> 正反馈
like -> 强正反馈
dislike -> 强负反馈
correction_from -> 原场景负反馈
correction_to -> 目标场景强正反馈
短 dwell / 立即切换 -> 弱负反馈
```

长期习惯特征：

```text
user_top_scene_before
user_top_scene_ratio_before
bucket_top_scene_before
bucket_top_scene_ratio_before
recent_7d_bucket_top_scene_before
recent_7d_bucket_top_scene_ratio_before
```

注意：

- 训练/测试必须按时间切分，避免未来历史泄漏。
- 可以加入 disruption week 测试“长期习惯 vs 最近异常”的边界。

### 11. 行为派生因子 / 特殊 factor

除了时间、地点、运动、天气这类外部上下文，音乐推荐里经常会把用户在 App 内的行为日志加工成更高阶的 factor。它们不是直接问“用户在干嘛”，而是从真实可记录的播放行为中推断“这次推荐是否合适”。

#### 11.1 每周 / 每日打开和收听强度

原始字段：

```text
app_open_timestamp
session_start
session_end
listen_start
listen_end
played_ratio_pct
```

处理字段：

```text
weekly_open_count
weekly_listen_minutes
weekly_active_days
avg_session_minutes_7d
avg_session_minutes_30d
time_slot_open_count_30d
time_slot_listen_minutes_30d
```

处理方式：

```text
weekly_listen_minutes = 最近7天 listen 时长求和
weekly_active_days = 最近7天有 listen 的不同日期数
time_slot_open_count_30d = 最近30天同一 time_slot 打开次数
time_slot_listen_minutes_30d = 最近30天同一 time_slot 收听总时长
```

用途：

- 判断用户在某个时间段是否有稳定使用习惯。
- 作为 bucket 个性化偏好分的可靠性权重。
- 区分“偶然一次点击”和“长期稳定场景”。

注意：

- 只能使用推荐时刻之前的历史，不能把当天后续行为泄漏进当前样本。
- 打开时长和收听时长要区分：打开了 App 不代表接受了推荐。

#### 11.2 播放完成率、跳过率、重复收听

Spotify skip prediction 相关资料里，skip / not skipped、session position、当前 session 前半段交互、track metadata 和 acoustic descriptors 都被用于预测后续歌曲是否会被跳过。对我们来说，不一定要预测下一首歌，但可以把这些信号转成场景推荐的偏好反馈。

原始字段：

```text
track_length_seconds
play_duration_seconds
skip_timestamp
is_skipped
repeat_play_count
session_position
```

处理字段：

```text
played_ratio_pct
early_skip_flag
skip_rate_7d
skip_rate_by_scene_30d
completion_rate_by_scene_30d
repeat_rate_by_scene_30d
```

处理方式：

```text
played_ratio_pct = play_duration_seconds / track_length_seconds
early_skip_flag = play_duration_seconds < min(30秒, track_length_seconds * 0.2)
completion = played_ratio_pct >= 0.7
repeat = 同一 track / 同一 scene 在短窗口内重复播放
```

用途：

- `early_skip_flag` 是较强负反馈。
- `completion_rate_by_scene_30d` 是较强正反馈。
- `repeat_rate_by_scene_30d` 可以表示用户在该场景下有稳定喜好。
- `session_position` 可以区分“刚打开时跳过”和“听了很久后换歌”，两者负反馈强度不一样。

注意：

- 短音频天然更容易完成，长音频天然更难完成，所以最好同时看绝对时长和百分比。
- 用户主动切换不一定是不喜欢，也可能是场景变化；要结合 `activity_state`、`time_slot`、`bluetooth`。

#### 11.3 音量与音量变化

音量不是音乐推荐数据集里最常见的公开字段，但在真实 App 里如果能拿到播放器音量或系统媒体音量，它是一个很有用的弱上下文信号。

原始字段：

```text
media_volume_level
volume_change_events
output_device_type
system_volume_available
```

处理字段：

```text
volume_class
volume_trend
avg_volume_by_scene_30d
volume_preference_by_device
```

建议映射：

```text
0-20% -> 低音量
21-60% -> 中音量
61-100% -> 高音量
短时间连续调高 -> 当前内容可能不够清晰 / 用户想沉浸
短时间连续调低 -> 环境变化 / 内容过强 / 睡眠或安静场景
```

用途：

- 用户长期在睡眠/午睡/婴儿安睡场景使用低音量，可以作为该场景偏好增强。
- 车载蓝牙 + 高音量 + 在途，可增强通勤。
- 耳机 + 中高音量 + 深夜，不一定是睡眠，也可能是深夜EMO/游戏，需要结合时间和活动。

注意：

- iOS/Android 对系统音量可访问性不同，且可能涉及权限或系统限制。
- 绝对音量受耳机、音箱、车载设备影响很大，应按 `output_device_type` 分桶。
- 音量不应作为硬规则，只适合做个性化偏好和场景强度辅助。

#### 11.4 设备、播放来源与控制方式

原始字段：

```text
output_device_type
playback_source
recommendation_source
manual_search_flag
playlist_entry_flag
notification_entry_flag
```

处理字段：

```text
device_scene_prior
source_intent
manual_intent_strength
```

示例：

```text
车载蓝牙 + 自动播放 -> 通勤先验增强
家用音响 + 夜间 + 低音量 -> 睡眠/放松/婴儿安睡先验增强
耳机 + 工作日白天 + 长时收听 -> 专注/阅读先验增强
用户主动搜索某类内容 -> 强意图，高于被动曝光
通知进入后快速退出 -> 弱负反馈
```

注意：

- `manual_search_flag` 和 `playlist_entry_flag` 如果来自自家 App 内部行为，通常比外部 app_event 更可靠。
- 不建议依赖外部 App 使用记录，系统限制和隐私风险都比较高。

#### 11.5 Session 内上下文漂移

一个 session 不一定只对应一个场景。比如用户先通勤，到了办公室后继续听，场景可能从通勤变成专注。

原始字段：

```text
session_start_context
context_samples_during_session
scene_switch_events
activity_state_changes
place_type_changes
bluetooth_changes
```

处理字段：

```text
context_stability_score
scene_transition_candidate
session_segment_index
```

处理方式：

```text
如果 activity/place/bluetooth 在 session 中变化明显 -> 切分 session segment
如果 context_stability_score 高 -> 该 segment 的反馈更可靠
如果 context_stability_score 低 -> 降低该段对长期偏好的训练权重
```

用途：

- 避免把“通勤结束后听的专注音乐”错误学习成通勤偏好。
- 支持“同一个 session 多个场景”的真实情况。

#### 11.6 问卷和显式状态

PIMP / Why Context Matters 里包含用户问卷、音乐偏好、session start/end state 等信息。例如本地 PIMP 代码中有 happy、sad、stressed、energy、focus listening，以及 wake up、bathing、exercising、working、housework、relaxing、eating、socializing、romantic、reading、sleep、driving、train 等听歌场景倾向。

可用字段：

```text
listen_hours
preferred_listening_contexts
music_education
happy_start / happy_end
sad_start / sad_end
stressed_start / stressed_end
energy_start / energy_end
focus_listening
```

用途：

- 冷启动时作为 profile prior。
- session 结束状态可以作为离线分析和标注辅助。
- 长期看可以学习“用户在压力高时是否更接受减压/冥想/深夜EMO”。

注意：

- 这些通常需要用户主动填写，不应假设线上每次都有。
- 显式问卷可能有社会期望偏差，要和真实播放行为一起校准。

## 推荐字段表

| 原始数据 | 处理后字段 | 权限/风险 | 作用 |
|---|---|---|---|
| timestamp | hour, weekday, time_slot | 低 | 主干信号 |
| lat/lon + POI | place_type, confidence | 中/高 | 场景细分，需降权 |
| Core Motion / HealthKit | activity_state | 高 | 运动/通勤/静止区分 |
| HR samples | heart_rate_zone, trend | 高 | 运动/压力/睡眠辅助 |
| mic dBA | noise_class | 高/隐私 | 安静/嘈杂区分 |
| ambient lux | light_class | 中 | 睡眠/午睡/深夜辅助 |
| weather API | weather | 中 | 户外/跑步/通勤弱信号 |
| Bluetooth | bluetooth | 中 | 耳机/车载/音响 |
| network | network | 低 | App 可用性和通勤弱信号 |
| calendar | calendar_keyword | 高 | 强增强信号，不可依赖 |
| app internal log | event_type, dwell, correction | 低/中 | 个性化学习核心 |
| playback log | completion, skip, repeat | 低/中 | 强隐式反馈 |
| app usage log | weekly_open_count, weekly_listen_minutes | 低/中 | 长期习惯可靠性 |
| media volume | volume_class, volume_trend | 中 | 场景强度和设备偏好辅助 |
| playback source | source_intent, manual_intent_strength | 低/中 | 主动意图强度 |
| session context samples | context_stability_score, segment_index | 中 | 防止跨场景污染训练 |
| questionnaire | profile_prior, explicit_state | 中/高 | 冷启动和离线标注辅助 |

## 建议评估方法

1. **完整数据 vs sparse 数据**：先看理想上限，再看真实缺失下限。
2. **字段消融**：只用时间/运动/心率；再逐步加入地点、环境、连接、历史。
3. **置信度消融**：比较 `place_type` 硬映射 vs 带置信度降权。
4. **长期习惯验证**：前 90 天训练，后 30 天测试。
5. **disruption week**：测试长期习惯强但最近一周偏离时是否被短期异常带偏。
6. **权限分层**：
   - 无健康授权：时间 + 地点弱信号 + 蓝牙 + 网络 + 历史反馈。
   - 有健康授权：加入 activity / heart rate / step / sleep。
   - 有日历或 App 内事件：作为增强信号。

## 对当前项目的建议

当前数据生成和算法应保留这些字段：

```text
*_available
*_confidence
*_quality
```

尤其是：

```text
place_type_available
place_type_confidence
place_type_quality
activity_state_available
heart_rate_available
heart_rate_quality
calendar_available
app_event_available
```

最终推荐不应是“单字段硬判断”，而应是：

```text
missing-aware rule
+ semantic retrieval / rerank
+ long-term preference
+ feedback correction
```
