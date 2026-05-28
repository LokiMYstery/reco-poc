# poc/semantic_scorer.py
"""语义匹配分通道 - 方案B：离线向量化 + 在线余弦相似度"""

import os
import json
import numpy as np
from typing import Dict, List, Optional, Tuple
from scenes import SCENES, SCENE_NAMES

# 使用 sentence-transformers 作为嵌入模型
# pip install sentence-transformers


class SemanticScorer:
    """
    方案B：将18个场景描述离线转为向量存入向量库，
    在线将用户上下文摘要转为同一向量，计算余弦相似度。
    """

    def __init__(self, model_name: str = "paraphrase-multilingual-MiniLM-L12-v2",
                 cache_path: str = "poc/data/scene_vectors.npy",
                 use_cache: bool = True,
                 query_instruction: str = None,
                 document_instruction: str = None,
                 local_files_only: bool = False):
        self.cache_path = cache_path
        self.scene_names = SCENE_NAMES
        self.use_cache = use_cache
        self.query_instruction = query_instruction
        self.document_instruction = document_instruction
        self.local_files_only = local_files_only

        # 延迟加载模型
        self._model = None
        self._model_name = model_name

        # 加载或生成场景向量
        if use_cache and os.path.exists(cache_path):
            self.scene_vectors = np.load(cache_path)
            print(f"从缓存加载场景向量: {cache_path}, shape={self.scene_vectors.shape}")
        else:
            self.scene_vectors = self._build_scene_vectors()
            if use_cache:
                os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                np.save(cache_path, self.scene_vectors)
                print(f"场景向量已保存到: {cache_path}")

    @property
    def model(self):
        if self._model is None:
            from sentence_transformers import SentenceTransformer
            print(f"加载嵌入模型: {self._model_name}")
            self._model = SentenceTransformer(self._model_name, local_files_only=self.local_files_only)
        return self._model

    def _build_scene_vectors(self) -> np.ndarray:
        """离线构建18个场景描述的嵌入向量"""
        texts = [self._scene_to_text(s) for s in SCENES]
        vectors = self._encode_documents(texts, show_progress_bar=True)
        return vectors  # shape: (18, dim)

    def _encode_queries(self, texts: List[str], show_progress_bar: bool = False) -> np.ndarray:
        kwargs = {
            "normalize_embeddings": True,
            "show_progress_bar": show_progress_bar,
        }
        if self.query_instruction:
            kwargs["prompt"] = self.query_instruction
        return self.model.encode(texts, **kwargs)

    def _encode_documents(self, texts: List[str], show_progress_bar: bool = False) -> np.ndarray:
        kwargs = {
            "normalize_embeddings": True,
            "show_progress_bar": show_progress_bar,
        }
        if self.document_instruction:
            kwargs["prompt"] = self.document_instruction
        return self.model.encode(texts, **kwargs)

    # semantic_scorer.py 中的 _scene_to_text 方法需要适配列表格式
    def _scene_to_text(self, scene: Dict) -> str:
        return (
            f"场景：{scene['name']}。"
            f"{scene['description']}"
            f"典型活动：{scene['typical_activity']}。"
            f"典型地点：{scene['typical_location']}。"
            f"典型时间：{scene['typical_time']}。"
            f"心率区间：{scene['typical_heart_rate_zone']}。"
            f"标签：{'、'.join(scene['tags'])}。"
        )

    def _context_to_text(self, context: Dict) -> str:
        """
        将用户上下文转为自然语言摘要
        
        context 示例:
        {
            "hour": 14,
            "weekday": "周二",
            "is_weekend": False,
            "location_type": "office",
            "activity": "still",
            "heart_rate": 72,
            "heart_rate_variability": 0.1,
            "noise_level": "quiet",
            "weather": "sunny",
            "bluetooth_device": "headphone",
            "calendar_keyword": "free"
        }
        """
        parts = []
        
        # 时间信息
        if context.get("weekday"):
            parts.append(f"{context['weekday']}")
        if context.get("hour") is not None:
            hour = int(float(context['hour']))
            if hour < 6:
                time_desc = "凌晨"
            elif hour < 9:
                time_desc = "早晨"
            elif hour < 12:
                time_desc = "上午"
            elif hour < 14:
                time_desc = "中午"
            elif hour < 18:
                time_desc = "下午"
            elif hour < 22:
                time_desc = "晚上"
            else:
                time_desc = "深夜"
            parts.append(f"{time_desc}{hour}点")
        
        # 地点信息，兼容旧英文字段和新版中文CSV字段
        location_map = {
            "home": "在家",
            "office": "在公司",
            "gym": "在健身房",
            "cafe": "在咖啡厅",
            "car": "在车里或在途",
            "outdoor": "在户外",
            "library": "在图书馆",
            "other": "在某处",
            "住宅区": "在住宅区或家中",
            "写字楼": "在写字楼或办公室",
            "商场": "在商场",
            "酒店": "在酒店",
            "餐厅": "在餐厅",
            "公园": "在公园",
            "机场": "在机场",
            "图书馆": "在图书馆",
            "海边": "在海边",
            "户外": "在户外",
            "在途": "正在路上",
            "高铁站": "在高铁站",
            "地铁站": "在地铁站",
        }
        loc = context.get("place_type", context.get("location_type", "other"))
        parts.append(location_map.get(loc, f"地点类型是{loc}"))
        
        # 活动状态
        activity_map = {
            "still": "静止状态",
            "walking": "走路中",
            "running": "跑步中",
            "exercising": "锻炼中",
            "driving": "驾车中",
            "cycling": "骑行中"
        }
        activity_map.update({
            "静止": "静止状态",
            "慢速": "低速移动",
            "中速": "中速运动",
            "高速": "高速运动",
            "任意": "活动状态未知",
        })
        act = context.get("activity_state", context.get("activity", "still"))
        parts.append(activity_map.get(act, "活动中"))
        
        # 生理状态
        hr_zone = context.get("heart_rate_zone")
        if hr_zone:
            parts.append(f"心率{hr_zone}")
        hr = context.get("heart_rate", context.get("heart_rate_bpm"))
        if hr:
            hr = int(float(hr))
            if hr < 70:
                hr_desc = "心率偏低"
            elif hr < 100:
                hr_desc = "心率正常"
            elif hr < 130:
                hr_desc = "心率较高"
            else:
                hr_desc = "心率很高"
            parts.append(hr_desc)
        
        # 环境信息
        noise = context.get("noise_class", context.get("noise_level"))
        if noise:
            noise_map = {"quiet": "环境安静", "moderate": "环境一般", "loud": "环境嘈杂", "安静": "环境安静", "普通": "环境一般", "嘈杂": "环境嘈杂"}
            parts.append(noise_map.get(noise, ""))

        light = context.get("light_class")
        if light:
            parts.append(f"光线{light}")
        
        weather = context.get("weather")
        if weather:
            weather_map = {"sunny": "天气晴朗", "rainy": "下雨天", "cloudy": "阴天", "snow": "下雪天", "晴": "天气晴朗", "多云": "天气多云", "小雨": "下雨天", "大雪": "下雪天", "阴": "阴天", "雾": "有雾"}
            parts.append(weather_map.get(weather, ""))
        
        # 设备信息
        bluetooth = context.get("bluetooth", context.get("bluetooth_device"))
        if bluetooth and bluetooth != "none":
            device_map = {"headphone": "戴着耳机", "car": "连接车载", "speaker": "连接音箱", "耳机": "戴着耳机", "车载蓝牙": "连接车载蓝牙", "家用音响": "连接家用音响", "任意": ""}
            parts.append(device_map.get(bluetooth, ""))
        
        # 日历信息
        calendar = context.get("calendar_title", context.get("calendar_keyword"))
        if calendar and calendar != "free":
            if calendar == "meeting":
                parts.append("有会议")
            elif calendar == "deadline":
                parts.append("有截止任务")
            elif calendar == "stress":
                parts.append("压力较大")
            else:
                parts.append(f"日历显示{calendar}")

        app_event = context.get("app_event")
        if app_event:
            parts.append(f"后续App行为是{app_event}")

        user_tag = context.get("user_tag")
        if user_tag:
            parts.append(f"用户标签是{user_tag}")
        
        # 过滤空字符串，用逗号连接
        parts = [p for p in parts if p]
        return "，".join(parts) + "。"

    def score_single(self, context: Dict) -> float:
        """已废弃，使用 score_all 代替"""
        scores = self.score_all(context)
        return max(scores.values()) if scores else 0.0

    def score_all(self, context: Dict) -> Dict[str, float]:
        """
        计算所有场景的语义匹配分
        
        Args:
            context: 用户上下文字典
            
        Returns:
            {scene_id: score} 字典，score范围0-1
        """
        # 将上下文转为文本
        context_text = self._context_to_text(context)
        
        # 将上下文文本转为向量（归一化）
        context_vector = self._encode_queries([context_text])[0]
        
        # 计算余弦相似度（向量已归一化，点积即余弦相似度）
        similarities = np.dot(self.scene_vectors, context_vector)
        
        # 将相似度从[-1,1]映射到[0,1]
        scores = (similarities + 1) / 2
        
        # 构建返回字典
        result = {}
        for i, scene in enumerate(SCENES):
            scene_id = scene['name']
            result[scene_id] = float(scores[i])
        
        return result

    def get_top_k(self, context: Dict, k: int = 3) -> List[Tuple[str, float]]:
        """
        获取语义匹配分最高的k个场景
        
        Args:
            context: 用户上下文字典
            k: 返回数量
            
        Returns:
            [(scene_id, score), ...] 列表，按分数降序排列
        """
        scores = self.score_all(context)
        sorted_items = sorted(scores.items(), key=lambda x: x[1], reverse=True)
        return sorted_items[:k]

    def refresh_cache(self):
        """手动刷新场景向量缓存"""
        self.scene_vectors = self._build_scene_vectors()
        os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
        np.save(self.cache_path, self.scene_vectors)
        print(f"场景向量缓存已刷新: {self.cache_path}")
