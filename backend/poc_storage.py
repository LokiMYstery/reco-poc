"""SQLite storage for the music scene recommendation POC API."""

import json
import os
import sqlite3
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


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
        return {
            "user_id": user_id,
            "feedback_events": total,
            "top_accepted_scenes": [dict(row) for row in rows],
            "recent_feedback": [dict(row) for row in recent],
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
