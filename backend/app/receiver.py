import json
import time
from pathlib import Path
from typing import Any


def load_receiver_status(status_file: Path, stale_seconds: int = 10) -> dict[str, Any]:
    base: dict[str, Any] = {
        "healthy": False,
        "state": "unavailable",
        "receiver_name": None,
        "engine": "UxPlay",
        "engine_version": None,
        "timestamp": None,
        "age_seconds": None,
        "airplay_port": None,
        "video_rtp_port": None,
        "audio_rtp_port": None,
        "message": "Receiver 状态文件尚未生成",
    }

    try:
        raw = json.loads(status_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return base
    except (OSError, json.JSONDecodeError) as exc:
        base["state"] = "invalid"
        base["message"] = f"无法读取 Receiver 状态: {exc}"
        return base

    timestamp_epoch = raw.get("timestamp_epoch")
    age_seconds: float | None = None
    if isinstance(timestamp_epoch, (int, float)):
        age_seconds = max(0.0, time.time() - float(timestamp_epoch))

    state = str(raw.get("state") or "unknown")
    fresh = age_seconds is not None and age_seconds <= stale_seconds
    healthy = state == "ready" and fresh

    message = "Receiver 已就绪" if healthy else "Receiver 状态异常"
    if state == "ready" and not fresh:
        message = "Receiver 心跳已过期"
    elif state == "stopped":
        message = "Receiver 已停止"

    return {
        "healthy": healthy,
        "state": state,
        "receiver_name": raw.get("receiver_name"),
        "engine": raw.get("engine", "UxPlay"),
        "engine_version": raw.get("engine_version"),
        "timestamp": raw.get("timestamp"),
        "age_seconds": round(age_seconds, 1) if age_seconds is not None else None,
        "airplay_port": raw.get("airplay_port"),
        "video_rtp_port": raw.get("video_rtp_port"),
        "audio_rtp_port": raw.get("audio_rtp_port"),
        "message": message,
    }
