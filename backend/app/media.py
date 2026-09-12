import json
import time
from pathlib import Path
from typing import Any


def load_media_status(status_file: Path, stale_seconds: int = 5) -> dict[str, Any]:
    base: dict[str, Any] = {
        "healthy": False,
        "streaming": False,
        "state": "unavailable",
        "engine": "GStreamer/webrtcbin",
        "timestamp": None,
        "age_seconds": None,
        "video_rtp_port": None,
        "jitter_latency_ms": None,
        "retime_mode": None,
        "retimed_au_buffers": 0,
        "retime_push_failures": 0,
        "source_idr_count": 0,
        "source_sps_count": 0,
        "source_pps_count": 0,
        "last_idr_age_seconds": None,
        "force_key_unit_events": 0,
        "input_fps": 0.0,
        "input_mbps": 0.0,
        "input_rtp_clock_ratio": 0.0,
        "output_rtp_clock_ratio": 0.0,
        "parser_pts_clock_ratio": 0.0,
        "input_rtp_timestamp_changes": 0,
        "output_rtp_timestamp_changes": 0,
        "parser_pts_valid_buffers": 0,
        "signaling_connected": False,
        "active_viewer": None,
        "peer_state": "idle",
        "video_active": False,
        "video_age_seconds": None,
        "buffers": 0,
        "bytes": 0,
        "error": None,
        "message": "Media Bridge 状态文件尚未生成",
    }

    try:
        raw = json.loads(status_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return base
    except (OSError, json.JSONDecodeError) as exc:
        base["state"] = "invalid"
        base["message"] = f"无法读取 Media Bridge 状态: {exc}"
        return base

    timestamp_epoch = raw.get("timestamp_epoch")
    age_seconds: float | None = None
    if isinstance(timestamp_epoch, (int, float)):
        age_seconds = max(0.0, time.time() - float(timestamp_epoch))

    state = str(raw.get("state") or "unknown")
    fresh = age_seconds is not None and age_seconds <= stale_seconds
    healthy = fresh and state in {"waiting", "negotiating", "streaming"}
    streaming = healthy and bool(raw.get("video_active"))

    if not fresh:
        message = "Media Bridge 心跳已过期"
    elif state == "error":
        message = str(raw.get("error") or "Media Bridge 异常")
    elif streaming:
        message = "H.264 RTP 正在通过 WebRTC 转发"
    elif raw.get("active_viewer"):
        message = "浏览器已连接，正在协商 WebRTC"
    elif raw.get("signaling_connected"):
        message = "Media Bridge 已就绪，等待浏览器"
    else:
        message = "Media Bridge 等待信令连接"

    return {
        "healthy": healthy,
        "streaming": streaming,
        "state": state,
        "engine": raw.get("engine", "GStreamer/webrtcbin"),
        "timestamp": raw.get("timestamp"),
        "age_seconds": round(age_seconds, 1) if age_seconds is not None else None,
        "video_rtp_port": raw.get("video_rtp_port"),
        "jitter_latency_ms": raw.get("jitter_latency_ms"),
        "retime_mode": raw.get("retime_mode"),
        "retimed_au_buffers": int(raw.get("retimed_au_buffers") or 0),
        "retime_push_failures": int(raw.get("retime_push_failures") or 0),
        "source_idr_count": int(raw.get("source_idr_count") or 0),
        "source_sps_count": int(raw.get("source_sps_count") or 0),
        "source_pps_count": int(raw.get("source_pps_count") or 0),
        "last_idr_age_seconds": (
            float(raw["last_idr_age_seconds"])
            if isinstance(raw.get("last_idr_age_seconds"), (int, float))
            else None
        ),
        "force_key_unit_events": int(raw.get("force_key_unit_events") or 0),
        "input_fps": float(raw.get("input_fps") or 0.0),
        "input_mbps": float(raw.get("input_mbps") or 0.0),
        "input_rtp_clock_ratio": float(raw.get("input_rtp_clock_ratio") or 0.0),
        "output_rtp_clock_ratio": float(raw.get("output_rtp_clock_ratio") or 0.0),
        "parser_pts_clock_ratio": float(raw.get("parser_pts_clock_ratio") or 0.0),
        "input_rtp_timestamp_changes": int(raw.get("input_rtp_timestamp_changes") or 0),
        "output_rtp_timestamp_changes": int(raw.get("output_rtp_timestamp_changes") or 0),
        "parser_pts_valid_buffers": int(raw.get("parser_pts_valid_buffers") or 0),
        "signaling_connected": bool(raw.get("signaling_connected")),
        "active_viewer": raw.get("active_viewer"),
        "peer_state": raw.get("peer_state", "idle"),
        "video_active": bool(raw.get("video_active")),
        "video_age_seconds": raw.get("video_age_seconds"),
        "buffers": int(raw.get("buffers") or 0),
        "bytes": int(raw.get("bytes") or 0),
        "error": raw.get("error"),
        "message": message,
    }
