"""Export POC recommendation logs from SQLite to analysis-friendly CSV files.

Default export is privacy-minimized:
  - user_id is replaced by a stable hash
  - precise latitude/longitude are not exported
  - calendar_title is not exported, only availability/presence

Usage:
    python3 export_poc_logs.py
    python3 export_poc_logs.py --db data/poc_music_scene.db --out-dir data/exports/friday_test
"""

import argparse
import csv
import hashlib
import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


DEFAULT_DB = "data/poc_music_scene.db"
PLACE_CANDIDATE_COUNT = 3
RECOMMENDATION_COUNT = 3

CONTEXT_FIELDS = [
    "timestamp",
    "timezone",
    "date",
    "hour",
    "weekday",
    "time_slot",
    "network",
    "bluetooth",
    "activity_state",
    "activity_state_available",
    "heart_rate_zone",
    "heart_rate_available",
    "heart_rate_quality",
    "steps_last_10min",
    "recent_workout_minutes_24h",
    "sleep_quality",
    "weather",
    "light_class",
    "noise_class",
    "noise_available",
    "place_type",
    "place_type_available",
    "place_type_confidence",
    "place_type_quality",
    "place_candidates_margin",
    "geo_cluster_id",
    "geo_cluster_status",
    "geo_cluster_distance_m",
    "location_accuracy_m",
    "user_tag",
    "gender",
    "initial_need",
    "app_event",
    "app_event_available",
    "calendar_available",
]

SENSITIVE_CONTEXT_FIELDS = [
    "latitude",
    "longitude",
    "lat",
    "lon",
    "calendar_title",
]


def parse_json(text: Any) -> Dict[str, Any]:
    if not text:
        return {}
    try:
        value = json.loads(text)
    except (TypeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def stable_user_key(user_id: str, include_user_id: bool, salt: str = "") -> str:
    if include_user_id:
        return user_id
    digest = hashlib.sha256(f"{salt}:{user_id}".encode("utf-8")).hexdigest()
    return f"user_{digest[:16]}"


def scalar(value: Any) -> Any:
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return value


def write_csv(path: Path, rows: Iterable[Dict[str, Any]], fieldnames: List[str]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: scalar(row.get(key, "")) for key in fieldnames})
            count += 1
    return count


def fetch_rows(conn: sqlite3.Connection, table: str) -> List[sqlite3.Row]:
    return conn.execute(f"SELECT * FROM {table} ORDER BY id ASC").fetchall()


def recommendation_columns(include_sensitive: bool) -> List[str]:
    columns = ["event_id", "created_at", "request_id", "user_key"]
    columns += CONTEXT_FIELDS
    if include_sensitive:
        columns += SENSITIVE_CONTEXT_FIELDS
    for index in range(1, PLACE_CANDIDATE_COUNT + 1):
        columns += [
            f"place_candidate_{index}_type",
            f"place_candidate_{index}_confidence",
            f"place_candidate_{index}_distance_m",
            f"place_candidate_{index}_source",
            f"place_candidate_{index}_quality",
        ]
    for index in range(1, RECOMMENDATION_COUNT + 1):
        columns += [
            f"rec_{index}_scene",
            f"rec_{index}_scene_id",
            f"rec_{index}_score",
            f"rec_{index}_rule",
            f"rec_{index}_semantic",
            f"rec_{index}_preference",
            f"rec_{index}_history",
        ]
    columns += ["model_version", "semantic_mode", "availability_notes"]
    return columns


def feedback_columns(include_sensitive: bool) -> List[str]:
    columns = [
        "event_id",
        "created_at",
        "request_id",
        "user_key",
        "recommended_scene",
        "accepted_scene",
        "event_type",
        "dwell_time_sec",
        "played_ratio_pct",
        "next_action",
        "reward",
    ]
    columns += CONTEXT_FIELDS
    if include_sensitive:
        columns += SENSITIVE_CONTEXT_FIELDS
    for index in range(1, PLACE_CANDIDATE_COUNT + 1):
        columns += [
            f"place_candidate_{index}_type",
            f"place_candidate_{index}_confidence",
            f"place_candidate_{index}_distance_m",
            f"place_candidate_{index}_source",
            f"place_candidate_{index}_quality",
        ]
    return columns


def geo_columns(include_sensitive: bool) -> List[str]:
    columns = [
        "geo_cluster_id",
        "user_key",
        "count",
        "avg_accuracy_m",
        "created_at",
        "last_seen_at",
    ]
    if include_sensitive:
        columns += ["center_lat", "center_lon"]
    return columns


def add_context_fields(out: Dict[str, Any], context: Dict[str, Any], include_sensitive: bool) -> None:
    for field in CONTEXT_FIELDS:
        if field == "calendar_available":
            out[field] = context.get(field, 1 if context.get("calendar_title") else "")
        else:
            out[field] = context.get(field, "")
    if not include_sensitive:
        out["calendar_title_present"] = 1 if context.get("calendar_title") else 0
    else:
        for field in SENSITIVE_CONTEXT_FIELDS:
            out[field] = context.get(field, "")


def add_place_candidates(out: Dict[str, Any], context: Dict[str, Any]) -> None:
    candidates = context.get("place_candidates")
    if not isinstance(candidates, list):
        candidates = []
    for index in range(PLACE_CANDIDATE_COUNT):
        candidate = candidates[index] if index < len(candidates) and isinstance(candidates[index], dict) else {}
        prefix = f"place_candidate_{index + 1}"
        out[f"{prefix}_type"] = candidate.get("place_type", "")
        out[f"{prefix}_confidence"] = candidate.get("confidence", "")
        out[f"{prefix}_distance_m"] = candidate.get("distance_m", "")
        out[f"{prefix}_source"] = candidate.get("source", "")
        out[f"{prefix}_quality"] = candidate.get("quality", "")


def add_recommendations(out: Dict[str, Any], result: Dict[str, Any]) -> None:
    recommendations = result.get("recommendations")
    if not isinstance(recommendations, list):
        recommendations = []
    for index in range(RECOMMENDATION_COUNT):
        item = recommendations[index] if index < len(recommendations) and isinstance(recommendations[index], dict) else {}
        components = item.get("components") if isinstance(item.get("components"), dict) else {}
        prefix = f"rec_{index + 1}"
        out[f"{prefix}_scene"] = item.get("scene", "")
        out[f"{prefix}_scene_id"] = item.get("scene_id", "")
        out[f"{prefix}_score"] = item.get("score", "")
        out[f"{prefix}_rule"] = components.get("rule", "")
        out[f"{prefix}_semantic"] = components.get("semantic", "")
        out[f"{prefix}_preference"] = components.get("preference", "")
        out[f"{prefix}_history"] = components.get("history", "")


def iter_recommendations(
    rows: Iterable[sqlite3.Row],
    include_user_id: bool,
    include_sensitive: bool,
    salt: str,
) -> Iterable[Dict[str, Any]]:
    for row in rows:
        context = parse_json(row["context_json"])
        result = parse_json(row["result_json"])
        out = {
            "event_id": row["id"],
            "created_at": row["created_at"],
            "request_id": row["request_id"],
            "user_key": stable_user_key(row["user_id"], include_user_id, salt),
            "model_version": result.get("model_version", ""),
            "semantic_mode": result.get("semantic_mode", ""),
            "availability_notes": " | ".join(result.get("availability_notes", []) or []),
        }
        add_context_fields(out, context, include_sensitive)
        add_place_candidates(out, context)
        add_recommendations(out, result)
        yield out


def iter_feedback(
    rows: Iterable[sqlite3.Row],
    include_user_id: bool,
    include_sensitive: bool,
    salt: str,
) -> Iterable[Dict[str, Any]]:
    for row in rows:
        context = parse_json(row["context_json"])
        raw = parse_json(row["raw_json"])
        out = {
            "event_id": row["id"],
            "created_at": row["created_at"],
            "request_id": row["request_id"],
            "user_key": stable_user_key(row["user_id"], include_user_id, salt),
            "recommended_scene": row["recommended_scene"],
            "accepted_scene": row["accepted_scene"],
            "event_type": row["event_type"],
            "dwell_time_sec": row["dwell_time_sec"],
            "played_ratio_pct": row["played_ratio_pct"],
            "next_action": row["next_action"],
            "reward": raw.get("reward", ""),
        }
        add_context_fields(out, context, include_sensitive)
        add_place_candidates(out, context)
        yield out


def iter_geo_clusters(rows: Iterable[sqlite3.Row], include_user_id: bool, include_sensitive: bool, salt: str):
    for row in rows:
        out = {
            "geo_cluster_id": f"geo_{row['id']}",
            "user_key": stable_user_key(row["user_id"], include_user_id, salt),
            "count": row["count"],
            "avg_accuracy_m": row["avg_accuracy_m"],
            "created_at": row["created_at"],
            "last_seen_at": row["last_seen_at"],
        }
        if include_sensitive:
            out["center_lat"] = row["center_lat"]
            out["center_lon"] = row["center_lon"]
        yield out


def connect(db_path: Path) -> sqlite3.Connection:
    if not db_path.exists():
        raise FileNotFoundError(f"SQLite DB not found: {db_path}")
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def export_logs(
    db_path: Path,
    out_dir: Path,
    include_user_id: bool = False,
    include_sensitive: bool = False,
    salt: str = "",
) -> Dict[str, Any]:
    with connect(db_path) as conn:
        recommendation_rows = fetch_rows(conn, "recommendation_events")
        feedback_rows = fetch_rows(conn, "feedback_events")
        geo_rows = fetch_rows(conn, "geo_clusters")

    recommendation_count = write_csv(
        out_dir / "recommendation_events.csv",
        iter_recommendations(recommendation_rows, include_user_id, include_sensitive, salt),
        recommendation_columns(include_sensitive) + ([] if include_sensitive else ["calendar_title_present"]),
    )
    feedback_count = write_csv(
        out_dir / "feedback_events.csv",
        iter_feedback(feedback_rows, include_user_id, include_sensitive, salt),
        feedback_columns(include_sensitive) + ([] if include_sensitive else ["calendar_title_present"]),
    )
    geo_count = write_csv(
        out_dir / "geo_clusters.csv",
        iter_geo_clusters(geo_rows, include_user_id, include_sensitive, salt),
        geo_columns(include_sensitive),
    )

    summary = {
        "db_path": str(db_path),
        "out_dir": str(out_dir),
        "recommendation_events": recommendation_count,
        "feedback_events": feedback_count,
        "geo_clusters": geo_count,
        "user_id_export": "raw" if include_user_id else "sha256_16char_hash",
        "sensitive_context_exported": include_sensitive,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "files": [
            "recommendation_events.csv",
            "feedback_events.csv",
            "geo_clusters.csv",
        ],
    }
    with (out_dir / "export_summary.json").open("w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    return summary


def default_out_dir() -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return Path("data") / "exports" / f"poc_export_{stamp}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Export POC SQLite logs to privacy-minimized CSV files.")
    parser.add_argument("--db", default=os.getenv("POC_SQLITE_PATH", DEFAULT_DB), help="SQLite DB path")
    parser.add_argument("--out-dir", default="", help="Output directory. Defaults to data/exports/poc_export_<timestamp>")
    parser.add_argument("--include-user-id", action="store_true", help="Export raw user_id instead of a stable hash")
    parser.add_argument(
        "--include-sensitive-context",
        action="store_true",
        help="Also export precise lat/lon and calendar_title. Not recommended for sharing.",
    )
    parser.add_argument("--hash-salt", default=os.getenv("POC_EXPORT_HASH_SALT", ""), help="Optional salt for user hash")
    args = parser.parse_args()

    db_path = Path(args.db)
    out_dir = Path(args.out_dir) if args.out_dir else default_out_dir()
    summary = export_logs(
        db_path=db_path,
        out_dir=out_dir,
        include_user_id=args.include_user_id,
        include_sensitive=args.include_sensitive_context,
        salt=args.hash_salt,
    )

    print("Export complete")
    print(f"  output: {summary['out_dir']}")
    print(f"  recommendation_events: {summary['recommendation_events']}")
    print(f"  feedback_events: {summary['feedback_events']}")
    print(f"  geo_clusters: {summary['geo_clusters']}")
    if not args.include_sensitive_context:
        print("  privacy: raw lat/lon and calendar_title were not exported")


if __name__ == "__main__":
    main()
