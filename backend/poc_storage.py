"""SQLite storage for the music scene recommendation POC API."""

import json
import math
import os
import sqlite3
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


class POCStorage:
    def __init__(self, db_path: str = "data/poc_music_scene.db"):
        self.db_path = db_path
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self._init_db()

    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self):
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS recommendation_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    request_id TEXT,
                    user_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    context_json TEXT NOT NULL,
                    result_json TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS feedback_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    request_id TEXT,
                    user_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    recommended_scene TEXT,
                    accepted_scene TEXT,
                    dwell_time_sec INTEGER,
                    played_ratio_pct REAL,
                    event_type TEXT,
                    next_action TEXT,
                    context_json TEXT NOT NULL,
                    raw_json TEXT NOT NULL
                )
                """
            )
            conn.execute("CREATE INDEX IF NOT EXISTS idx_rec_user_time ON recommendation_events(user_id, created_at)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_feedback_user_time ON feedback_events(user_id, created_at)")
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS geo_clusters (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    center_lat REAL NOT NULL,
                    center_lon REAL NOT NULL,
                    count INTEGER NOT NULL,
                    avg_accuracy_m REAL,
                    created_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                )
                """
            )
            conn.execute("CREATE INDEX IF NOT EXISTS idx_geo_clusters_user ON geo_clusters(user_id)")

    def assign_geo_cluster(
        self,
        user_id: str,
        lat: Any,
        lon: Any,
        accuracy_m: Any = None,
        radius_m: float = 200.0,
        max_accuracy_m: float = 250.0,
    ) -> Dict[str, Any]:
        try:
            lat_f = float(lat)
            lon_f = float(lon)
        except (TypeError, ValueError):
            return {"geo_cluster_status": "unavailable"}
        if not (-90 <= lat_f <= 90 and -180 <= lon_f <= 180):
            return {"geo_cluster_status": "invalid"}

        try:
            accuracy_f = float(accuracy_m) if accuracy_m not in (None, "") else None
        except (TypeError, ValueError):
            accuracy_f = None
        if accuracy_f is not None and accuracy_f > max_accuracy_m:
            return {"geo_cluster_status": "low_accuracy", "location_accuracy_m": round(accuracy_f, 1)}

        now = utc_now_iso()
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, center_lat, center_lon, count, avg_accuracy_m
                FROM geo_clusters
                WHERE user_id = ?
                """,
                (user_id,),
            ).fetchall()
            best_row = None
            best_distance = None
            for row in rows:
                d = distance_m(lat_f, lon_f, row["center_lat"], row["center_lon"])
                if best_distance is None or d < best_distance:
                    best_row = row
                    best_distance = d

            match_radius = max(radius_m, (accuracy_f or 0.0) * 1.5)
            if best_row is not None and best_distance is not None and best_distance <= match_radius:
                old_count = int(best_row["count"])
                new_count = old_count + 1
                new_lat = (float(best_row["center_lat"]) * old_count + lat_f) / new_count
                new_lon = (float(best_row["center_lon"]) * old_count + lon_f) / new_count
                old_acc = best_row["avg_accuracy_m"]
                if accuracy_f is not None:
                    new_acc = ((float(old_acc or accuracy_f) * old_count) + accuracy_f) / new_count
                else:
                    new_acc = old_acc
                conn.execute(
                    """
                    UPDATE geo_clusters
                    SET center_lat = ?, center_lon = ?, count = ?, avg_accuracy_m = ?, last_seen_at = ?
                    WHERE id = ?
                    """,
                    (new_lat, new_lon, new_count, new_acc, now, best_row["id"]),
                )
                return {
                    "geo_cluster_id": f"geo_{best_row['id']}",
                    "geo_cluster_status": "known",
                    "geo_cluster_distance_m": round(best_distance, 1),
                    "location_accuracy_m": round(accuracy_f, 1) if accuracy_f is not None else None,
                }

            cur = conn.execute(
                """
                INSERT INTO geo_clusters(user_id, center_lat, center_lon, count, avg_accuracy_m, created_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (user_id, lat_f, lon_f, 1, accuracy_f, now, now),
            )
            return {
                "geo_cluster_id": f"geo_{cur.lastrowid}",
                "geo_cluster_status": "new",
                "geo_cluster_distance_m": 0.0,
                "location_accuracy_m": round(accuracy_f, 1) if accuracy_f is not None else None,
            }

    def save_recommendation(self, request_id: str, user_id: str, context: Dict[str, Any], result: Dict[str, Any]):
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO recommendation_events(request_id, user_id, created_at, context_json, result_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    request_id,
                    user_id,
                    utc_now_iso(),
                    json.dumps(context, ensure_ascii=False),
                    json.dumps(result, ensure_ascii=False),
                ),
            )

    def save_feedback(self, feedback: Dict[str, Any], context: Dict[str, Any]):
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO feedback_events(
                    request_id, user_id, created_at, recommended_scene, accepted_scene,
                    dwell_time_sec, played_ratio_pct, event_type, next_action, context_json, raw_json
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    feedback.get("request_id", ""),
                    feedback["user_id"],
                    utc_now_iso(),
                    feedback.get("recommended_scene", ""),
                    feedback.get("accepted_scene", ""),
                    int(feedback.get("dwell_time_sec") or 0),
                    float(feedback.get("played_ratio_pct") or 0.0),
                    feedback.get("event_type", ""),
                    feedback.get("next_action", ""),
                    json.dumps(context, ensure_ascii=False),
                    json.dumps(feedback, ensure_ascii=False),
                ),
            )

    def latest_context_for_request(self, request_id: str, user_id: str) -> Optional[Dict[str, Any]]:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT context_json
                FROM recommendation_events
                WHERE request_id = ? AND user_id = ?
                ORDER BY id DESC
                LIMIT 1
                """,
                (request_id, user_id),
            ).fetchone()
        if not row:
            return None
        return json.loads(row["context_json"])

    def feedback_summary(self, user_id: str, limit: int = 20) -> Dict[str, Any]:
        with self._connect() as conn:
            total = conn.execute(
                "SELECT COUNT(*) AS n FROM feedback_events WHERE user_id = ?",
                (user_id,),
            ).fetchone()["n"]
            rows = conn.execute(
                """
                SELECT accepted_scene, COUNT(*) AS n
                FROM feedback_events
                WHERE user_id = ? AND accepted_scene != ''
                GROUP BY accepted_scene
                ORDER BY n DESC
                LIMIT ?
                """,
                (user_id, limit),
            ).fetchall()
            recent = conn.execute(
                """
                SELECT created_at, recommended_scene, accepted_scene, dwell_time_sec, event_type, next_action
                FROM feedback_events
                WHERE user_id = ?
                ORDER BY id DESC
                LIMIT ?
                """,
                (user_id, limit),
            ).fetchall()
            clusters = conn.execute(
                """
                SELECT id, center_lat, center_lon, count, avg_accuracy_m, last_seen_at
                FROM geo_clusters
                WHERE user_id = ?
                ORDER BY count DESC, last_seen_at DESC
                LIMIT ?
                """,
                (user_id, limit),
            ).fetchall()
        return {
            "user_id": user_id,
            "feedback_events": total,
            "top_accepted_scenes": [dict(row) for row in rows],
            "recent_feedback": [dict(row) for row in recent],
            "geo_clusters": [
                {
                    "geo_cluster_id": f"geo_{row['id']}",
                    "count": row["count"],
                    "avg_accuracy_m": row["avg_accuracy_m"],
                    "last_seen_at": row["last_seen_at"],
                }
                for row in clusters
            ],
        }

    def load_history_rows(self, limit: int = 50000) -> List[Dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT user_id, accepted_scene, context_json
                FROM feedback_events
                WHERE accepted_scene != ''
                ORDER BY id DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        history_rows = []
        for row in rows:
            context = json.loads(row["context_json"])
            context["user_id"] = row["user_id"]
            context["ground_truth"] = row["accepted_scene"]
            context["event_type"] = "listen"
            history_rows.append(context)
        return history_rows

